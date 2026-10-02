using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Sales;

public sealed record CustomerInput(
    string NameAr,
    string NameEn,
    string? Phone,
    string? Email,
    string? VatNumber,
    string CustomerType,
    long CreditLimitH);

/// <summary>
/// Edit a customer. The balance is never written here. <c>CustomerType</c>
/// and <c>Status</c> left null keep what is stored.
/// </summary>
public sealed record UpdateCustomerRequest(
    string NameAr,
    string NameEn,
    string? Phone,
    string? Email,
    string? VatNumber,
    string? CustomerType,
    long CreditLimitH,
    string? Status);

public sealed record CollectionRequest(
    long AmountH,
    string Method,
    string? Reference,
    string? BranchId);

public static class CustomerEndpoints
{
    public static void MapCustomerEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/customers")
            .WithTags("Customers")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("customers.view"));

        group.MapGet("/{customerId}", GetAsync)
             .RequireAuthorization(PermissionPolicy.For("customers.view"));

        group.MapGet("/{customerId}/statement", StatementAsync)
             .RequireAuthorization(PermissionPolicy.For("customers.view"));

        group.MapPost("", CreateAsync)
             .RequireAuthorization(PermissionPolicy.For("customers.create"));

        group.MapPut("/{customerId}", UpdateAsync)
             .RequireAuthorization(PermissionPolicy.For("customers.edit"));

        group.MapPost("/{customerId}/collect", CollectAsync)
             .RequireAuthorization(PermissionPolicy.For("customers.credit"));

        group.MapGet("/receivables", ReceivablesAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapGet("/receivables/summary", ReceivablesSummaryAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));
    }

    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, string? search, bool? owingOnly,
        int page = 1, int pageSize = 25, CancellationToken ct = default)
    {
        var paging = new PageQuery { Page = page <= 0 ? 1 : page, PageSize = pageSize };

        await using var connection = db.Create();

        const string sql = """
            SELECT COUNT(*) FROM core.Customer
            WHERE (@Search IS NULL
                   OR NameAr LIKE N'%' + @Search + N'%'
                   OR NameEn LIKE N'%' + @Search + N'%'
                   OR Phone  LIKE N'%' + @Search + N'%')
              AND (@OwingOnly = 0 OR BalanceH > 0);

            SELECT CustomerId, NameAr, NameEn, Phone, Email, VatNumber,
                   CustomerType, CreditLimitH, BalanceH, IsActive,
                   CreatedAtUtc, UpdatedAtUtc
            FROM core.Customer
            WHERE (@Search IS NULL
                   OR NameAr LIKE N'%' + @Search + N'%'
                   OR NameEn LIKE N'%' + @Search + N'%'
                   OR Phone  LIKE N'%' + @Search + N'%')
              AND (@OwingOnly = 0 OR BalanceH > 0)
            ORDER BY NameEn
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(sql,
            new
            {
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                OwingOnly = owingOnly ?? false,
                paging.Offset,
                paging.PageSize
            },
            cancellationToken: ct));

        var total = await multi.ReadSingleAsync<int>();
        var rows = (await multi.ReadAsync()).ToList();

        return Results.Ok(new PagedResult<object>
        {
            Items = rows.Cast<object>().ToList(),
            Page = paging.Page,
            PageSize = paging.PageSize,
            TotalCount = total
        });
    }

    private static async Task<IResult> GetAsync(
        string customerId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var customer = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            "SELECT * FROM core.Customer WHERE CustomerId = @CustomerId;",
            new { CustomerId = customerId }, cancellationToken: ct));

        return customer is null ? Results.NotFound() : Results.Ok(customer);
    }

    /// <summary>
    /// The customer's account, oldest first.
    ///
    /// Credit sales and collections in one sequence, because "what do they owe
    /// and why" is a single question.
    /// </summary>
    private static async Task<IResult> StatementAsync(
        string customerId, ISqlConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT
                s.SaleId        AS Id,
                s.InvoiceNumber AS Reference,
                s.SoldAtUtc     AS OccurredAtUtc,
                N'credit_sale'  AS Kind,
                p.AmountH       AS AmountH
            FROM sales.Sale AS s
            JOIN sales.SalePayment AS p
                 ON p.SaleId = s.SaleId AND p.Method = N'credit'
            WHERE s.CustomerId = @CustomerId AND s.Status <> N'voided'

            UNION ALL

            SELECT
                e.EntryId       AS Id,
                e.Reference     AS Reference,
                e.PostedAtUtc   AS OccurredAtUtc,
                N'collection'   AS Kind,
                -l.CreditH      AS AmountH
            FROM fin.JournalEntry AS e
            JOIN fin.JournalLine  AS l
                 ON l.EntryId = e.EntryId AND l.AccountCode = N'1400'
            WHERE e.Kind = N'customer_collection'
              AND e.SourceReference = @CustomerId
              AND e.ReversesEntryId IS NULL
              AND e.ReversedByEntryId IS NULL

            UNION ALL

            /* A return refunded to the account lowers what is owed. */
            SELECT
                r.ReturnId      AS Id,
                r.NoteNumber    AS Reference,
                r.ReturnedAtUtc AS OccurredAtUtc,
                N'credit_note'  AS Kind,
                -r.RefundH      AS AmountH
            FROM sales.SaleReturn AS r
            WHERE r.CustomerId = @CustomerId AND r.RefundMethod = N'credit' AND r.RefundH > 0

            ORDER BY OccurredAtUtc;
            """,
            new { CustomerId = customerId }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> CreateAsync(
        CustomerInput input, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        // Both names are required. A customer with only an English name is
        // unreadable to half the staff who will serve them.
        if (string.IsNullOrWhiteSpace(input.NameAr) || string.IsNullOrWhiteSpace(input.NameEn))
        {
            return Results.BadRequest(ApiError.Create(
                "name_required",
                "Both the Arabic and English name are required.",
                "الاسم بالعربية والإنجليزية مطلوبان.",
                new Dictionary<string, string[]>
                {
                    ["nameAr"] = string.IsNullOrWhiteSpace(input.NameAr)
                        ? ["Arabic name is required."] : [],
                    ["nameEn"] = string.IsNullOrWhiteSpace(input.NameEn)
                        ? ["English name is required."] : []
                }));
        }

        var customerId = $"cus_{Guid.NewGuid():N}"[..24];

        await using var connection = db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO core.Customer
                (CustomerId, NameAr, NameEn, Phone, Email, VatNumber,
                 CustomerType, CreditLimitH, BalanceH, CreatedBy)
            VALUES
                (@CustomerId, @NameAr, @NameEn, @Phone, @Email, @VatNumber,
                 @CustomerType, @CreditLimitH, 0, @Actor);
            """,
            new
            {
                CustomerId = customerId,
                input.NameAr,
                input.NameEn,
                input.Phone,
                input.Email,
                input.VatNumber,
                input.CustomerType,
                input.CreditLimitH,
                Actor = current.Username
            },
            cancellationToken: ct));

        return Results.Created($"/api/customers/{customerId}", new { customerId });
    }

    private static async Task<IResult> CollectAsync(
        string customerId,
        CollectionRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        CancellationToken ct)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@CustomerId", customerId);
        parameters.Add("@AmountH", request.AmountH);
        parameters.Add("@Method", request.Method);
        parameters.Add("@Reference", request.Reference);
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@EntryId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_RecordCustomerCollection",
                parameters,
                commandType: CommandType.StoredProcedure,
                cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 52000 && ex.Number < 53000)
        {
            return Results.Json(SalesEndpoints.Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { entryId = parameters.Get<string>("@EntryId") });
    }

    /// <summary>
    /// Customers who owe, oldest debt first. Each row also carries
    /// <c>collectedH</c>: everything collected from that customer, lifetime
    /// (collections later reversed are left out).
    /// </summary>
    private static async Task<IResult> ReceivablesAsync(
        ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            $"""
            SELECT r.*, ISNULL(c.CollectedH, 0) AS CollectedH
            FROM fin.vw_Receivables AS r
            OUTER APPLY (
                SELECT SUM(l.CreditH) AS CollectedH
                FROM fin.JournalEntry AS e
                JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId AND l.AccountCode = N'1400'
                WHERE {CollectionFilter} AND e.SourceReference = r.CustomerId
            ) AS c
            ORDER BY r.AgeDays DESC;
            """,
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    /* A collection that stands: neither reversed nor itself a reversal. */
    private const string CollectionFilter =
        "e.Kind = N'customer_collection' AND e.ReversesEntryId IS NULL AND e.ReversedByEntryId IS NULL";

    /// <summary>
    /// The receivables cards. <c>collectedH</c> covers <c>from</c>..<c>to</c>
    /// (dates, inclusive), or all time when neither is given.
    /// </summary>
    private static async Task<IResult> ReceivablesSummaryAsync(
        ISqlConnectionFactory db, DateOnly? from, DateOnly? to, CancellationToken ct)
    {
        await using var connection = db.Create();

        var row = await connection.QuerySingleAsync(new CommandDefinition(
            $"""
            SELECT
                ISNULL((SELECT SUM(BalanceH) FROM core.Customer WHERE BalanceH > 0), 0) AS OutstandingH,
                (SELECT COUNT(*) FROM core.Customer WHERE BalanceH > 0) AS WithBalance,
                (SELECT COUNT(*) FROM core.Customer WHERE BalanceH > 0 AND BalanceH > CreditLimitH) AS OverLimit,
                ISNULL((SELECT SUM(l.CreditH)
                        FROM fin.JournalEntry AS e
                        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId AND l.AccountCode = N'1400'
                        WHERE {CollectionFilter}
                          AND (@From IS NULL OR CAST(e.PostedAtUtc AS DATE) >= @From)
                          AND (@To   IS NULL OR CAST(e.PostedAtUtc AS DATE) <= @To)), 0) AS CollectedH,
                (SELECT COUNT(*) FROM fin.JournalEntry AS e
                 WHERE {CollectionFilter}
                   AND (@From IS NULL OR CAST(e.PostedAtUtc AS DATE) >= @From)
                   AND (@To   IS NULL OR CAST(e.PostedAtUtc AS DATE) <= @To)) AS CollectionCount;
            """,
            new { From = from, To = to }, cancellationToken: ct));

        return Results.Ok(row);
    }

    /// <summary>
    /// Edit a customer through core.usp_UpdateCustomer. Returns the stored row,
    /// the same shape as GET /api/customers/{customerId}.
    /// </summary>
    private static async Task<IResult> UpdateAsync(
        string customerId,
        UpdateCustomerRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (request.Status is not (null or "active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        var email = ProcErrors.Blank(request.Email);
        if (email is not null && (!email.Contains('@', StringComparison.Ordinal) || email.Contains(' ', StringComparison.Ordinal)))
            return ProcErrors.Field("email", "Enter a valid email address, or leave it empty.",
                "أدخل بريدًا إلكترونيًا صحيحًا أو اتركه فارغًا.");

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_UpdateCustomer",
                new
                {
                    CustomerId = customerId,
                    NameAr = request.NameAr?.Trim(),
                    NameEn = request.NameEn?.Trim(),
                    Phone = ProcErrors.Blank(request.Phone),
                    Email = email,
                    VatNumber = ProcErrors.Blank(request.VatNumber),
                    CustomerType = ProcErrors.Blank(request.CustomerType),
                    request.CreditLimitH,
                    IsActive = request.Status is null ? (bool?)null : request.Status == "active",
                    Actor = current.Username
                },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapUpdateError(ex, request) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Customer {CustomerId} updated by {Actor}.", customerId, current.Username);
        http.Items["AuditEntityId"] = customerId;

        var customer = await connection.QuerySingleAsync(new CommandDefinition(
            "SELECT * FROM core.Customer WHERE CustomerId = @CustomerId;",
            new { CustomerId = customerId }, cancellationToken: ct));

        return Results.Ok(customer);
    }

    private static IResult? MapUpdateError(SqlException ex, UpdateCustomerRequest request) => ex.Number switch
    {
        68000 => ProcErrors.Field(string.IsNullOrWhiteSpace(request.NameAr) ? "nameAr" : "nameEn",
            "Both the Arabic and English name are required.", "الاسم بالعربية والإنجليزية مطلوبان."),
        68001 => ProcErrors.Field("creditLimitH", "A credit limit cannot be negative.", "لا يمكن أن يكون حد الائتمان سالبًا."),
        68002 => Results.UnprocessableEntity(ApiError.Create("limit_below_balance",
            "The new limit is below what this customer already owes. Collect a payment first, or set a higher limit.",
            "الحد الجديد أقل مما على العميل. حصّل دفعة أولًا أو ارفع الحد.",
            new Dictionary<string, string[]> { ["creditLimitH"] = ["Must be at least the current balance."] })),
        68003 => ProcErrors.NotFound("Customer not found.", "العميل غير موجود."),
        68004 => ProcErrors.Field("customerType", "A customer is an individual or a business.", "العميل فرد أو منشأة."),
        68005 => ProcErrors.Conflict("customer_has_balance",
            "This customer still owes money. Settle the balance before deactivating.",
            "على هذا العميل مبلغ مستحق. سدّد الرصيد قبل التعطيل."),
        _ => null
    };
}
