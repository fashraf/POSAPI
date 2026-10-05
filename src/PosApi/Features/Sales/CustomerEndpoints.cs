using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Sales;

/// <summary>
/// A new customer. <c>OpeningBalanceH</c> is what they already owed before
/// the system; it is posted to the ledger (Dr 1400 / Cr 3900) dated
/// <c>OpeningAsOf</c> (today when null) and tagged to <c>BranchId</c>.
/// </summary>
public sealed record CustomerInput(
    string NameAr,
    string NameEn,
    string? Phone,
    string? Email,
    string? VatNumber,
    string? CustomerType,
    long CreditLimitH,
    long OpeningBalanceH = 0,
    DateOnly? OpeningAsOf = null,
    string? BranchId = null);

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
    /// The customer's account, oldest first, ending on <c>core.Customer.BalanceH</c>.
    ///
    /// Every movement of what they owe, signed from the customer's side
    /// (positive raises the balance, negative lowers it), with the running
    /// balance after each:
    /// <list type="bullet">
    /// <item><c>opening_balance</c> — an opening receivable posted when the customer was created.</item>
    /// <item><c>credit_sale</c> — the part of a sale put on account (voided sales left out).</item>
    /// <item><c>collection</c> — a payment received; <c>collection_reversed</c> is its reversal,
    /// shown beside it so the account reads the way it happened.</item>
    /// <item><c>credit_note</c> — a return refunded to the account.</item>
    /// <item><c>balance_forward</c> — first line, only when the balance includes debt
    /// from before any of these records (seeded or imported balances), so the
    /// running balance still ends where the account does.</item>
    /// </list>
    /// </summary>
    private static async Task<IResult> StatementAsync(
        string customerId, ISqlConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var customer = await connection.QuerySingleOrDefaultAsync<(long BalanceH, DateTime CreatedAtUtc)?>(
            new CommandDefinition(
                "SELECT BalanceH, CreatedAtUtc FROM core.Customer WHERE CustomerId = @CustomerId;",
                new { CustomerId = customerId }, cancellationToken: ct));

        if (customer is null)
            return ProcErrors.NotFound("Customer not found.", "العميل غير موجود.");

        var movements = (await connection.QueryAsync<StatementRow>(new CommandDefinition(
            """
            SELECT Id, Reference, OccurredAtUtc, Kind, AmountH, SortOrder
            FROM (
                /* Opening receivable, and its reversal if it was taken back. */
                SELECT
                    e.EntryId       AS Id,
                    e.Reference     AS Reference,
                    e.PostedAtUtc   AS OccurredAtUtc,
                    CASE WHEN e.ReversesEntryId IS NULL THEN N'opening_balance'
                         ELSE N'opening_reversed' END AS Kind,
                    SUM(l.DebitH - l.CreditH) AS AmountH,
                    0               AS SortOrder
                FROM fin.JournalEntry AS e
                JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId AND l.AccountCode = N'1400'
                WHERE e.Kind = N'customer_opening' AND e.SourceReference = @CustomerId
                GROUP BY e.EntryId, e.Reference, e.PostedAtUtc, e.ReversesEntryId

                UNION ALL

                SELECT
                    s.SaleId        AS Id,
                    s.InvoiceNumber AS Reference,
                    s.SoldAtUtc     AS OccurredAtUtc,
                    N'credit_sale'  AS Kind,
                    SUM(p.AmountH)  AS AmountH,
                    1               AS SortOrder
                FROM sales.Sale AS s
                JOIN sales.SalePayment AS p
                     ON p.SaleId = s.SaleId AND p.Method = N'credit'
                WHERE s.CustomerId = @CustomerId AND s.Status <> N'voided'
                GROUP BY s.SaleId, s.InvoiceNumber, s.SoldAtUtc

                UNION ALL

                /* Collections net of their own 1400 lines: a collection is a
                   credit (negative here), its reversal a debit (positive). */
                SELECT
                    e.EntryId       AS Id,
                    e.Reference     AS Reference,
                    e.PostedAtUtc   AS OccurredAtUtc,
                    CASE WHEN e.ReversesEntryId IS NULL THEN N'collection'
                         ELSE N'collection_reversed' END AS Kind,
                    SUM(l.DebitH - l.CreditH) AS AmountH,
                    3               AS SortOrder
                FROM fin.JournalEntry AS e
                JOIN fin.JournalLine  AS l
                     ON l.EntryId = e.EntryId AND l.AccountCode = N'1400'
                WHERE e.Kind = N'customer_collection'
                  AND e.SourceReference = @CustomerId
                GROUP BY e.EntryId, e.Reference, e.PostedAtUtc, e.ReversesEntryId

                UNION ALL

                /* A return refunded to the account lowers what is owed. */
                SELECT
                    r.ReturnId      AS Id,
                    r.NoteNumber    AS Reference,
                    r.ReturnedAtUtc AS OccurredAtUtc,
                    N'credit_note'  AS Kind,
                    -r.RefundH      AS AmountH,
                    2               AS SortOrder
                FROM sales.SaleReturn AS r
                WHERE r.CustomerId = @CustomerId AND r.RefundMethod = N'credit' AND r.RefundH > 0
            ) AS m
            WHERE AmountH <> 0
            ORDER BY OccurredAtUtc, SortOrder, Reference;
            """,
            new { CustomerId = customerId }, cancellationToken: ct))).ToList();

        /* Whatever the records above do not explain was owed before them. It
           opens the statement, so every running balance after it is right. */
        var forwardH = customer.Value.BalanceH - movements.Sum(m => m.AmountH);
        if (forwardH != 0)
        {
            var first = movements.Count > 0 ? movements[0].OccurredAtUtc : customer.Value.CreatedAtUtc;
            var at = customer.Value.CreatedAtUtc < first ? customer.Value.CreatedAtUtc : first.AddMilliseconds(-1);
            movements.Insert(0, new StatementRow
            {
                Id = $"bf_{customerId}",
                Reference = string.Empty,
                OccurredAtUtc = at,
                Kind = "balance_forward",
                AmountH = forwardH
            });
        }

        var running = 0L;
        var rows = movements.Select(m =>
        {
            running += m.AmountH;
            return new
            {
                id = m.Id,
                reference = m.Reference,
                occurredAtUtc = DateTime.SpecifyKind(m.OccurredAtUtc, DateTimeKind.Utc),
                kind = m.Kind,
                amountH = m.AmountH,
                balanceH = running
            };
        }).ToList();

        return Results.Ok(rows);
    }

    private sealed record StatementRow
    {
        public string Id { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public DateTime OccurredAtUtc { get; init; }
        public string Kind { get; init; } = string.Empty;
        public long AmountH { get; init; }
        public int SortOrder { get; init; }
    }

    /// <summary>
    /// Create a customer through core.usp_CreateCustomer, which also posts an
    /// opening balance to the ledger. Returns the new id (and the opening
    /// entry, when one was posted).
    /// </summary>
    private static async Task<IResult> CreateAsync(
        CustomerInput input, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        // Both names are required. A customer with only an English name is
        // unreadable to half the staff who will serve them.
        if (string.IsNullOrWhiteSpace(input.NameAr) || string.IsNullOrWhiteSpace(input.NameEn))
        {
            return Results.UnprocessableEntity(ApiError.Create(
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

        if (CheckFields(input.NameAr, input.NameEn, input.Phone, input.Email, input.VatNumber,
                        input.CreditLimitH) is { } invalid)
            return invalid;

        if (input.OpeningBalanceH < 0)
            return ProcErrors.Field("openingBalanceH", "An opening balance cannot be negative.",
                "لا يمكن أن يكون الرصيد الافتتاحي سالبًا.");

        var branchId = ProcErrors.Blank(input.BranchId);
        if (branchId is not null && !current.CanSeeBranch(branchId)) return Results.Forbid();

        var parameters = new DynamicParameters();
        parameters.Add("@NameAr", input.NameAr.Trim());
        parameters.Add("@NameEn", input.NameEn.Trim());
        parameters.Add("@Phone", ProcErrors.Blank(input.Phone));
        parameters.Add("@Email", ProcErrors.Blank(input.Email));
        parameters.Add("@VatNumber", ProcErrors.Blank(input.VatNumber));
        parameters.Add("@CustomerType", ProcErrors.Blank(input.CustomerType));
        parameters.Add("@CreditLimitH", input.CreditLimitH);
        parameters.Add("@OpeningBalanceH", input.OpeningBalanceH);
        parameters.Add("@OpeningAsOf", input.OpeningAsOf);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@CustomerId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);
        parameters.Add("@EntryId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_CreateCustomer", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapCustomerError(ex.Number, input.NameAr) is { } mapped)
        {
            return mapped;
        }

        var customerId = parameters.Get<string>("@CustomerId");

        return Results.Created($"/api/customers/{customerId}",
            new { customerId, openingEntryId = parameters.Get<string?>("@EntryId") });
    }

    /// <summary>
    /// The checks that would otherwise reach the database as a constraint or
    /// truncation error (HTTP 500): column lengths and a negative limit.
    /// </summary>
    private static IResult? CheckFields(
        string? nameAr, string? nameEn, string? phone, string? email, string? vatNumber, long creditLimitH)
    {
        if (creditLimitH < 0)
            return ProcErrors.Field("creditLimitH", "A credit limit cannot be negative.", "لا يمكن أن يكون حد الائتمان سالبًا.");

        static bool TooLong(string? value, int max) => value is not null && value.Trim().Length > max;

        if (TooLong(nameAr, 160))
            return ProcErrors.Field("nameAr", "The name is too long (160 characters at most).", "الاسم طويل جدًا (160 حرفًا على الأكثر).");
        if (TooLong(nameEn, 160))
            return ProcErrors.Field("nameEn", "The name is too long (160 characters at most).", "الاسم طويل جدًا (160 حرفًا على الأكثر).");
        if (TooLong(phone, 30))
            return ProcErrors.Field("phone", "The phone number is too long (30 characters at most).", "رقم الجوال طويل جدًا (30 حرفًا على الأكثر).");
        if (TooLong(email, 160))
            return ProcErrors.Field("email", "The email is too long (160 characters at most).", "البريد الإلكتروني طويل جدًا (160 حرفًا على الأكثر).");
        if (TooLong(vatNumber, 15))
            return ProcErrors.Field("vatNumber", "A VAT number is 15 digits.", "الرقم الضريبي 15 رقمًا.");

        return null;
    }

    /* The THROW numbers core.usp_CreateCustomer and core.usp_UpdateCustomer share. */
    private static IResult? MapCustomerError(int number, string? nameAr) => number switch
    {
        68000 => ProcErrors.Field(string.IsNullOrWhiteSpace(nameAr) ? "nameAr" : "nameEn",
            "Both the Arabic and English name are required.", "الاسم بالعربية والإنجليزية مطلوبان."),
        68001 => ProcErrors.Field("creditLimitH", "A credit limit cannot be negative.", "لا يمكن أن يكون حد الائتمان سالبًا."),
        68004 => ProcErrors.Field("customerType", "A customer is an individual or a business.", "العميل فرد أو منشأة."),
        68006 => ProcErrors.Field("openingBalanceH", "An opening balance cannot be negative.",
            "لا يمكن أن يكون الرصيد الافتتاحي سالبًا."),
        68007 => ProcErrors.Field("openingBalanceH",
            "The opening balance is above the credit limit. Raise the limit to match.",
            "الرصيد الافتتاحي أعلى من حد الائتمان. ارفع الحد ليطابقه."),
        68008 => ProcErrors.Field("branchId", "Unknown branch.", "فرع غير معروف."),
        _ => null
    };

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

        if (CheckFields(request.NameAr, request.NameEn, request.Phone, email, request.VatNumber,
                        request.CreditLimitH) is { } invalid)
            return invalid;

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
