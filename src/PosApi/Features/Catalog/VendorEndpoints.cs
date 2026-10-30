using System.Text.RegularExpressions;
using Dapper;
using Npgsql;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Localization;

namespace PosApi.Features.Catalog;

/// <summary>
/// A vendor with what is owed and what has been bought.
///
/// Keeps the field names GET /api/inventory/vendors always returned
/// (<c>vendorId</c>, <c>isActive</c>, <c>balanceH</c>) and adds the rest.
/// <c>BalanceH</c> is the unsettled part of purchases not paid on receipt;
/// <c>PurchasedH</c> is every purchase, paid on receipt or not, lifetime.
/// </summary>
public sealed record VendorDto(
    string VendorId,
    string NameAr,
    string NameEn,
    string Name,
    string ContactPerson,
    string Phone,
    string Email,
    string VatNumber,
    string City,
    int PaymentTermDays,
    bool IsActive,
    string Status,
    long BalanceH,
    long PurchasedH,
    long PaidH,
    int PurchaseCount,
    DateTime? LastPurchaseAt,
    DateTime CreatedAt,
    DateTime UpdatedAt);

public sealed record SaveVendorRequest(
    string NameAr,
    string NameEn,
    string? ContactPerson,
    string? Phone,
    string? Email,
    string? VatNumber,
    string? City,
    int? PaymentTermDays,
    string? Status);

public sealed record VendorPaymentRequest(
    long AmountH,
    string Method,
    string? Note,
    string? PurchaseId,
    string? BranchId);

public sealed record VendorPaymentAllocationDto(string PurchaseId, string Reference, long AmountH);

public sealed record VendorPaymentDto(
    string Id,
    string Reference,
    string VendorId,
    long AmountH,
    string Method,
    string Note,
    string PaidBy,
    DateTime PaidAt,
    string? BranchId,
    string? EntryId,
    IReadOnlyList<VendorPaymentAllocationDto> Allocations,
    DateTime CreatedAt,
    DateTime UpdatedAt);

/// <summary>
/// One line of a vendor's account, signed from the business's side: a
/// purchase on credit is positive (owed more), a payment negative.
/// </summary>
public sealed record VendorLedgerEntryDto(
    string Id,
    string Kind,
    string Reference,
    DateTime Date,
    long AmountH,
    long BalanceH,
    string? PurchaseId,
    string? PaymentId,
    string? Method,
    string? VendorInvoiceNumber,
    string? Note);

public sealed record PurchaseLineDto(
    string ItemId,
    string NameAr,
    string NameEn,
    decimal Quantity,
    long UnitCostH,
    long LineTotalH);

public sealed record PurchasePaymentDto(
    string PaymentId, string Reference, string Method, long AmountH, DateTime PaidAt);

public sealed record PurchaseDto(
    string Id,
    string Reference,
    string VendorId,
    string VendorNameAr,
    string VendorNameEn,
    string? BranchId,
    string VendorInvoiceNumber,
    IReadOnlyList<PurchaseLineDto> Lines,
    long SubtotalH,
    long TaxH,
    long TotalH,
    bool PaidOnReceipt,
    long PaidH,
    long OutstandingH,
    string PaymentStatus,
    string Status,
    string Note,
    string ReceivedBy,
    DateTime ReceivedAt,
    DateTime CreatedAt,
    DateTime UpdatedAt,
    IReadOnlyList<PurchasePaymentDto>? Payments);

public static partial class VendorEndpoints
{
    public static void MapVendorEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/inventory")
            .WithTags("Vendors & purchases")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/vendors", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.view"));

        group.MapGet("/vendors/summary", SummaryAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.view"));

        group.MapGet("/vendors/{vendorId}", GetAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.view"));

        group.MapPost("/vendors", CreateAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.create"));

        group.MapPut("/vendors/{vendorId}", UpdateAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.edit"));

        group.MapGet("/vendors/{vendorId}/ledger", LedgerAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.view"));

        group.MapGet("/vendors/{vendorId}/payments", PaymentsAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.view"));

        group.MapPost("/vendors/{vendorId}/payments", PayAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.pay"));

        group.MapGet("/purchases", PurchasesAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.view"));

        group.MapGet("/purchases/{purchaseId}", PurchaseAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.view"));
    }

    [GeneratedRegex(@"^[^\s@]+@[^\s@]+\.[^\s@]+$")]
    private static partial Regex EmailPattern();

    /*------------------------------------------------------------- vendors */

    /// <summary>Active vendors by default; <c>includeInactive=true</c> for all.</summary>
    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, ILanguageContext language, bool? includeInactive, CancellationToken ct)
    {
        await using var connection = db.Create();
        return Results.Ok(await LoadVendorsAsync(connection, null, includeInactive ?? false, language, ct));
    }

    private static async Task<IResult> GetAsync(
        string vendorId, ISqlConnectionFactory db, ILanguageContext language, CancellationToken ct)
    {
        await using var connection = db.Create();
        var vendor = (await LoadVendorsAsync(connection, vendorId, true, language, ct)).SingleOrDefault();
        return vendor is null ? VendorNotFound() : Results.Ok(vendor);
    }

    /// <summary>
    /// Headline figures for the vendors screen. <c>from</c>/<c>to</c> (dates)
    /// bound <c>purchasedH</c> and <c>paidH</c>; without them both are lifetime.
    /// <c>payableH</c> is always what is owed now.
    /// </summary>
    private static async Task<IResult> SummaryAsync(
        ISqlConnectionFactory db, DateOnly? from, DateOnly? to, CancellationToken ct)
    {
        await using var connection = db.Create();

        var row = await connection.QuerySingleAsync<SummaryRow>(new CommandDefinition(
            """
            SELECT
                COALESCE((SELECT SUM(TotalH - PaidH) FROM inv.Purchase WHERE NOT PaidOnReceipt), 0)::bigint AS PayableH,
                (SELECT COUNT(*) FROM core.Vendor WHERE IsActive)::int AS ActiveVendors,
                (SELECT COUNT(*) FROM core.Vendor AS v
                 WHERE EXISTS (SELECT 1 FROM inv.Purchase AS p
                               WHERE p.VendorId = v.VendorId AND NOT p.PaidOnReceipt AND p.PaidH < p.TotalH))::int AS WithBalance,
                COALESCE((SELECT SUM(TotalH) FROM inv.Purchase
                          WHERE (@From::date IS NULL OR ReceivedAtUtc::date >= @From::date)
                            AND (@To::date   IS NULL OR ReceivedAtUtc::date <= @To::date)), 0)::bigint AS PurchasedH,
                (SELECT COUNT(*) FROM inv.Purchase
                 WHERE (@From::date IS NULL OR ReceivedAtUtc::date >= @From::date)
                   AND (@To::date   IS NULL OR ReceivedAtUtc::date <= @To::date))::int AS PurchaseCount,
                COALESCE((SELECT SUM(AmountH) FROM inv.VendorPayment
                          WHERE (@From::date IS NULL OR PaidAtUtc::date >= @From::date)
                            AND (@To::date   IS NULL OR PaidAtUtc::date <= @To::date)), 0)::bigint AS PaidH;
            """,
            new { From = from, To = to }, cancellationToken: ct));

        return Results.Ok(new
        {
            payableH = row.PayableH,
            activeVendors = row.ActiveVendors,
            withBalance = row.WithBalance,
            purchasedH = row.PurchasedH,
            purchaseCount = row.PurchaseCount,
            paidH = row.PaidH,
            from,
            to
        });
    }

    private static Task<IResult> CreateAsync(
        SaveVendorRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveAsync(null, request, db, current, language, http, logger, ct);

    private static Task<IResult> UpdateAsync(
        string vendorId, SaveVendorRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveAsync(vendorId, request, db, current, language, http, logger, ct);

    /// <summary>Through core.usp_SaveVendor. Status inactive on PUT deactivates.</summary>
    private static async Task<IResult> SaveAsync(
        string? vendorId,
        SaveVendorRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (request.Status is not (null or "active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        var email = ProcErrors.Blank(request.Email);
        if (email is not null && !EmailPattern().IsMatch(email))
            return ProcErrors.Field("email", "Enter a valid email address, or leave it empty.",
                "أدخل بريدًا إلكترونيًا صحيحًا أو اتركه فارغًا.");

        await using var connection = db.Create();

        string savedId;

        try
        {
            savedId = await connection.QuerySingleAsync<string>(new CommandDefinition(
                """
                SELECT SavedId FROM core.usp_SaveVendor(
                    p_VendorId => @VendorId, p_NameAr => @NameAr, p_NameEn => @NameEn,
                    p_ContactPerson => @ContactPerson, p_Phone => @Phone, p_Email => @Email,
                    p_VatNumber => @VatNumber, p_City => @City,
                    p_PaymentTermDays => @PaymentTermDays, p_IsActive => @IsActive, p_Actor => @Actor);
                """,
                new
                {
                    VendorId = vendorId,
                    NameAr = request.NameAr?.Trim(),
                    NameEn = request.NameEn?.Trim(),
                    ContactPerson = ProcErrors.Blank(request.ContactPerson),
                    Phone = ProcErrors.Blank(request.Phone),
                    Email = email,
                    VatNumber = ProcErrors.Blank(request.VatNumber),
                    City = ProcErrors.Blank(request.City),
                    request.PaymentTermDays,
                    IsActive = request.Status is null ? (vendorId is null ? true : (bool?)null) : request.Status == "active",
                    Actor = current.Username
                },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (MapError(ex, request) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Vendor {VendorId} {Action} by {Actor}.",
            savedId, vendorId is null ? "created" : "updated", current.Username);
        http.Items["AuditEntityId"] = savedId;

        var vendor = (await LoadVendorsAsync(connection, savedId, true, language, ct)).Single();

        return vendorId is null
            ? Results.Created($"/api/inventory/vendors/{savedId}", vendor)
            : Results.Ok(vendor);
    }

    /*------------------------------------------------------------ payments */

    /// <summary>
    /// Pay a vendor. Settles the oldest unpaid purchases first, or only
    /// <c>purchaseId</c> when given. Posts Dr 2000 / Cr 1000 (cash) or 1100
    /// (bank, card) in the same transaction.
    /// </summary>
    private static async Task<IResult> PayAsync(
        string vendorId,
        VendorPaymentRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        var branchId = ProcErrors.Blank(request.BranchId);
        if (!current.CanSeeBranch(branchId)) return Results.Forbid();

        await using var connection = db.Create();

        string paymentId, reference;

        try
        {
            (paymentId, reference, _) = await connection.QuerySingleAsync<(string, string, string)>(new CommandDefinition(
                """
                SELECT PaymentId, Reference, EntryId FROM inv.usp_RecordVendorPayment(
                    p_VendorId => @VendorId, p_AmountH => @AmountH, p_Method => @Method,
                    p_PurchaseId => @PurchaseId, p_BranchId => @BranchId,
                    p_Note => @Note, p_Actor => @Actor);
                """,
                new
                {
                    VendorId = vendorId,
                    request.AmountH,
                    Method = request.Method?.Trim().ToLowerInvariant(),
                    PurchaseId = ProcErrors.Blank(request.PurchaseId),
                    BranchId = branchId,
                    Note = ProcErrors.Blank(request.Note),
                    Actor = current.Username
                },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (MapError(ex, null) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Vendor payment {Reference} of {AmountH} to {VendorId} by {Actor}.",
            reference, request.AmountH, vendorId, current.Username);
        http.Items["AuditEntityId"] = paymentId;

        var payment = (await LoadPaymentsAsync(connection, vendorId, paymentId, ct)).Single();

        return Results.Created($"/api/inventory/vendors/{vendorId}/payments/{paymentId}", payment);
    }

    private static async Task<IResult> PaymentsAsync(
        string vendorId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        if (!await VendorExistsAsync(connection, vendorId, ct)) return VendorNotFound();

        return Results.Ok(await LoadPaymentsAsync(connection, vendorId, null, ct));
    }

    /// <summary>
    /// Purchases on credit and payments, oldest first, with a running balance.
    /// Purchases paid on receipt never owed anything and are left out, so the
    /// last balance equals the vendor's <c>balanceH</c>.
    /// </summary>
    private static async Task<IResult> LedgerAsync(
        string vendorId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        if (!await VendorExistsAsync(connection, vendorId, ct)) return VendorNotFound();

        var rows = (await connection.QueryAsync<LedgerRow>(new CommandDefinition(
            """
            SELECT p.PurchaseId AS Id, 'purchase' AS Kind, p.Reference, p.ReceivedAtUtc AS OccurredAtUtc,
                   p.TotalH AS AmountH, p.PurchaseId, NULL::varchar AS PaymentId,
                   NULL::varchar AS Method, p.InvoiceNumber AS VendorInvoiceNumber, p.Note
            FROM inv.Purchase AS p
            WHERE p.VendorId = @VendorId AND NOT p.PaidOnReceipt

            UNION ALL

            SELECT y.PaymentId, 'payment', y.Reference, y.PaidAtUtc,
                   -y.AmountH, NULL, y.PaymentId, y.Method, NULL, y.Note
            FROM inv.VendorPayment AS y
            WHERE y.VendorId = @VendorId

            ORDER BY OccurredAtUtc, Reference;
            """,
            new { VendorId = vendorId }, cancellationToken: ct))).ToList();

        long running = 0;
        var entries = rows.Select(r =>
        {
            running += r.AmountH;
            return new VendorLedgerEntryDto(r.Id, r.Kind, r.Reference, r.OccurredAtUtc, r.AmountH, running,
                r.PurchaseId, r.PaymentId, r.Method, r.VendorInvoiceNumber, r.Note);
        }).ToList();

        return Results.Ok(entries);
    }

    /*----------------------------------------------------------- purchases */

    /// <summary>
    /// Deliveries, newest first, each with its lines. <c>paymentStatus</c>
    /// filters paid | partial | unpaid.
    /// </summary>
    private static async Task<IResult> PurchasesAsync(
        ISqlConnectionFactory db, ICurrentUser current,
        string? vendorId, string? branchId, DateOnly? from, DateOnly? to, string? paymentStatus,
        int page = 1, int pageSize = 25, CancellationToken ct = default)
    {
        if (!current.CanSeeBranch(ProcErrors.Blank(branchId))) return Results.Forbid();

        if (paymentStatus is not (null or "" or "paid" or "partial" or "unpaid"))
            return ProcErrors.Field("paymentStatus", "Payment status is paid, partial or unpaid.",
                "حالة السداد: مسدد أو جزئي أو غير مسدد.");

        var paging = new PageQuery { Page = page <= 0 ? 1 : page, PageSize = pageSize };

        await using var connection = db.Create();

        const string filter = """
            WHERE (@VendorId IS NULL OR p.VendorId = @VendorId)
              AND (@BranchId IS NULL OR p.BranchId = @BranchId)
              AND (@From::date IS NULL OR p.ReceivedAtUtc::date >= @From::date)
              AND (@To::date   IS NULL OR p.ReceivedAtUtc::date <= @To::date)
              AND (@Status IS NULL
                   OR (@Status = 'paid'    AND p.PaidH >= p.TotalH)
                   OR (@Status = 'partial' AND p.PaidH > 0 AND p.PaidH < p.TotalH)
                   OR (@Status = 'unpaid'  AND p.PaidH = 0 AND p.TotalH > 0))
            """;

        var args = new
        {
            VendorId = ProcErrors.Blank(vendorId),
            BranchId = ProcErrors.Blank(branchId),
            From = from,
            To = to,
            Status = ProcErrors.Blank(paymentStatus),
            paging.Offset,
            paging.PageSize
        };

        var total = await connection.ExecuteScalarAsync<int>(new CommandDefinition(
            $"SELECT COUNT(*)::int FROM inv.Purchase AS p {filter};", args, cancellationToken: ct));

        var rows = (await connection.QueryAsync<PurchaseRow>(new CommandDefinition(
            $"""
            {PurchaseSelect}
            {filter}
            ORDER BY p.ReceivedAtUtc DESC, p.Reference DESC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """, args, cancellationToken: ct))).ToList();

        var lines = await LoadPurchaseLinesAsync(connection, rows.Select(r => r.PurchaseId).ToList(), ct);

        return Results.Ok(new PagedResult<PurchaseDto>
        {
            Items = rows.Select(r => ToPurchase(r, lines[r.PurchaseId].ToList(), null)).ToList(),
            Page = paging.Page,
            PageSize = paging.PageSize,
            TotalCount = total
        });
    }

    private static async Task<IResult> PurchaseAsync(
        string purchaseId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        var row = await connection.QuerySingleOrDefaultAsync<PurchaseRow>(new CommandDefinition(
            $"{PurchaseSelect} WHERE p.PurchaseId = @PurchaseId;",
            new { PurchaseId = purchaseId }, cancellationToken: ct));

        if (row is null)
            return ProcErrors.NotFound("No such purchase.", "لا توجد عملية شراء بهذا المعرف.");

        if (!current.CanSeeBranch(row.BranchId)) return Results.Forbid();

        var lines = await LoadPurchaseLinesAsync(connection, [purchaseId], ct);

        var payments = (await connection.QueryAsync<PurchasePaymentRow>(new CommandDefinition(
            """
            SELECT y.PaymentId, y.Reference, y.Method, a.AmountH, y.PaidAtUtc
            FROM inv.VendorPaymentAllocation AS a
            JOIN inv.VendorPayment AS y ON y.PaymentId = a.PaymentId
            WHERE a.PurchaseId = @PurchaseId
            ORDER BY y.PaidAtUtc;
            """,
            new { PurchaseId = purchaseId }, cancellationToken: ct)))
            .Select(p => new PurchasePaymentDto(p.PaymentId, p.Reference, p.Method, p.AmountH, p.PaidAtUtc))
            .ToList();

        return Results.Ok(ToPurchase(row, lines[purchaseId].ToList(), payments));
    }

    /*------------------------------------------------------------- helpers */

    private const string PurchaseSelect = """
        SELECT p.PurchaseId, p.Reference, p.VendorId, v.NameAr AS VendorNameAr, v.NameEn AS VendorNameEn,
               p.BranchId, p.InvoiceNumber, p.SubtotalH, p.TaxH, p.TotalH, p.PaidOnReceipt, p.PaidH,
               p.Note, p.ReceivedBy, p.ReceivedAtUtc
        FROM inv.Purchase AS p
        JOIN core.Vendor AS v ON v.VendorId = p.VendorId
        """;

    private static PurchaseDto ToPurchase(
        PurchaseRow r, IReadOnlyList<PurchaseLineDto> lines, IReadOnlyList<PurchasePaymentDto>? payments) =>
        new(r.PurchaseId, r.Reference, r.VendorId, r.VendorNameAr, r.VendorNameEn, r.BranchId,
            r.InvoiceNumber ?? string.Empty, lines, r.SubtotalH, r.TaxH, r.TotalH, r.PaidOnReceipt,
            r.PaidH, r.TotalH - r.PaidH,
            r.PaidH >= r.TotalH ? "paid" : r.PaidH > 0 ? "partial" : "unpaid",
            "received", r.Note ?? string.Empty, r.ReceivedBy,
            r.ReceivedAtUtc, r.ReceivedAtUtc, r.ReceivedAtUtc, payments);

    private static async Task<ILookup<string, PurchaseLineDto>> LoadPurchaseLinesAsync(
        NpgsqlConnection connection, IReadOnlyList<string> purchaseIds, CancellationToken ct)
    {
        if (purchaseIds.Count == 0) return Array.Empty<PurchaseLineDto>().ToLookup(_ => string.Empty);

        var rows = await connection.QueryAsync<PurchaseLineRow>(new CommandDefinition(
            """
            SELECT l.PurchaseId, l.ItemId, i.NameAr, i.NameEn, l.Quantity, l.UnitCostH
            FROM inv.PurchaseLine AS l
            JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
            WHERE l.PurchaseId = ANY(@Ids)
            ORDER BY l.PurchaseLineId;
            """,
            new { Ids = purchaseIds.ToArray() }, cancellationToken: ct));

        return rows.ToLookup(r => r.PurchaseId, r => new PurchaseLineDto(
            r.ItemId, r.NameAr, r.NameEn, r.Quantity, r.UnitCostH,
            (long)Math.Round(r.Quantity * r.UnitCostH, MidpointRounding.AwayFromZero)));
    }

    private static async Task<bool> VendorExistsAsync(NpgsqlConnection connection, string vendorId, CancellationToken ct) =>
        await connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*)::int FROM core.Vendor WHERE VendorId = @VendorId;",
            new { VendorId = vendorId }, cancellationToken: ct)) > 0;

    internal static async Task<List<VendorDto>> LoadVendorsAsync(
        NpgsqlConnection connection, string? vendorId, bool includeInactive,
        ILanguageContext language, CancellationToken ct)
    {
        var rows = await connection.QueryAsync<VendorRow>(new CommandDefinition(
            """
            SELECT v.VendorId, v.NameAr, v.NameEn, v.ContactPerson, v.Phone, v.Email, v.VatNumber,
                   v.City, v.PaymentTermDays, v.IsActive, v.CreatedAtUtc, v.UpdatedAtUtc,
                   COALESCE(p.BalanceH, 0)::bigint AS BalanceH, COALESCE(p.PurchasedH, 0)::bigint AS PurchasedH,
                   COALESCE(p.PurchaseCount, 0)::int AS PurchaseCount, p.LastPurchaseAtUtc,
                   COALESCE(y.PaidH, 0)::bigint AS PaidH
            FROM core.Vendor AS v
            LEFT JOIN LATERAL (
                SELECT SUM(CASE WHEN NOT PaidOnReceipt THEN TotalH - PaidH ELSE 0 END) AS BalanceH,
                       SUM(TotalH) AS PurchasedH, COUNT(*) AS PurchaseCount,
                       MAX(ReceivedAtUtc) AS LastPurchaseAtUtc
                FROM inv.Purchase WHERE VendorId = v.VendorId
            ) AS p ON true
            LEFT JOIN LATERAL (
                SELECT SUM(AmountH) AS PaidH FROM inv.VendorPayment WHERE VendorId = v.VendorId
            ) AS y ON true
            WHERE (@VendorId IS NULL OR v.VendorId = @VendorId)
              AND (@IncludeInactive OR v.IsActive)
            ORDER BY v.NameEn;
            """,
            new { VendorId = vendorId, IncludeInactive = includeInactive }, cancellationToken: ct));

        return rows.Select(r => new VendorDto(
            r.VendorId, r.NameAr, r.NameEn, language.Pick(r.NameAr, r.NameEn),
            r.ContactPerson ?? string.Empty, r.Phone ?? string.Empty, r.Email ?? string.Empty,
            r.VatNumber ?? string.Empty, r.City ?? string.Empty, r.PaymentTermDays, r.IsActive,
            r.IsActive ? "active" : "inactive",
            r.BalanceH, r.PurchasedH, r.PaidH, r.PurchaseCount, r.LastPurchaseAtUtc,
            r.CreatedAtUtc, r.UpdatedAtUtc)).ToList();
    }

    private static async Task<List<VendorPaymentDto>> LoadPaymentsAsync(
        NpgsqlConnection connection, string vendorId, string? paymentId, CancellationToken ct)
    {
        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT PaymentId, Reference, VendorId, AmountH, Method, Note, PaidBy, PaidAtUtc,
                   BranchId, EntryId, CreatedAtUtc
            FROM inv.VendorPayment
            WHERE VendorId = @VendorId AND (@PaymentId IS NULL OR PaymentId = @PaymentId)
            ORDER BY PaidAtUtc DESC;

            SELECT a.PaymentId, a.PurchaseId, p.Reference, a.AmountH
            FROM inv.VendorPaymentAllocation AS a
            JOIN inv.VendorPayment AS y ON y.PaymentId = a.PaymentId
            JOIN inv.Purchase AS p ON p.PurchaseId = a.PurchaseId
            WHERE y.VendorId = @VendorId AND (@PaymentId IS NULL OR a.PaymentId = @PaymentId)
            ORDER BY p.ReceivedAtUtc;
            """,
            new { VendorId = vendorId, PaymentId = paymentId }, cancellationToken: ct));

        var payments = (await multi.ReadAsync<PaymentRow>()).ToList();
        var allocations = (await multi.ReadAsync<AllocationRow>()).ToLookup(a => a.PaymentId);

        return payments.Select(p => new VendorPaymentDto(
            p.PaymentId, p.Reference, p.VendorId, p.AmountH, p.Method, p.Note ?? string.Empty,
            p.PaidBy, p.PaidAtUtc, p.BranchId, p.EntryId,
            allocations[p.PaymentId].Select(a => new VendorPaymentAllocationDto(a.PurchaseId, a.Reference, a.AmountH)).ToList(),
            p.CreatedAtUtc, p.CreatedAtUtc)).ToList();
    }

    private static IResult VendorNotFound() =>
        ProcErrors.NotFound("No such vendor.", "لا يوجد مورد بهذا المعرف.");

    private static IResult? MapError(PostgresException ex, SaveVendorRequest? request) => ex.ErrorNumber() switch
    {
        66000 => ProcErrors.Field(string.IsNullOrWhiteSpace(request?.NameAr) ? "nameAr" : "nameEn",
            "Both names are required.", "الاسمان العربي والإنجليزي مطلوبان."),
        66001 => ProcErrors.Field("phone",
            "A phone number is required so you can chase a delivery.", "رقم الهاتف مطلوب لمتابعة التوريد."),
        66002 => ProcErrors.Field("vatNumber",
            "A Saudi VAT number is exactly 15 digits, or leave it empty.", "الرقم الضريبي ١٥ رقمًا بالضبط، أو اتركه فارغًا."),
        66003 => ProcErrors.Field("vatNumber",
            "Another vendor already uses this VAT number.", "يوجد مورد آخر بهذا الرقم الضريبي."),
        66004 => ProcErrors.Field("nameEn", "Another vendor already uses this name.", "يوجد مورد آخر بهذا الاسم."),
        66005 => ProcErrors.Field("paymentTermDays", "Payment terms cannot be negative.", "لا يمكن أن تكون مدة السداد سالبة."),
        66006 or 66011 => VendorNotFound(),
        66007 => ProcErrors.Conflict("vendor_has_balance",
            "This vendor still has unpaid deliveries. Settle them before deactivating.",
            "لدى هذا المورد توريدات غير مسددة. سددها قبل التعطيل."),
        66010 => ProcErrors.Field("amountH", "Enter an amount greater than zero.", "أدخل مبلغًا أكبر من صفر."),
        66012 => Results.UnprocessableEntity(ApiError.Create("overpayment",
            "That is more than you owe this vendor. Reduce the amount.",
            "المبلغ أكبر مما عليك لهذا المورد. خفّض المبلغ.",
            new Dictionary<string, string[]> { ["amountH"] = ["Cannot exceed the outstanding balance."] })),
        66013 => ProcErrors.Field("method", "Pay by cash, card or bank.", "الدفع نقدًا أو بالبطاقة أو تحويلًا بنكيًا."),
        66014 => ProcErrors.Field("purchaseId", "That purchase is not from this vendor.", "عملية الشراء هذه ليست من هذا المورد."),
        66015 => ProcErrors.Field("purchaseId", "That purchase is already settled.", "عملية الشراء هذه مسددة بالكامل."),
        _ => null
    };

    /*---------------------------------------------------------------- rows */

    private sealed record VendorRow
    {
        public string VendorId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? ContactPerson { get; init; }
        public string? Phone { get; init; }
        public string? Email { get; init; }
        public string? VatNumber { get; init; }
        public string? City { get; init; }
        public int PaymentTermDays { get; init; }
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
        public long BalanceH { get; init; }
        public long PurchasedH { get; init; }
        public int PurchaseCount { get; init; }
        public DateTime? LastPurchaseAtUtc { get; init; }
        public long PaidH { get; init; }
    }

    private sealed record SummaryRow
    {
        public long PayableH { get; init; }
        public int ActiveVendors { get; init; }
        public int WithBalance { get; init; }
        public long PurchasedH { get; init; }
        public int PurchaseCount { get; init; }
        public long PaidH { get; init; }
    }

    private sealed record LedgerRow
    {
        public string Id { get; init; } = string.Empty;
        public string Kind { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public DateTime OccurredAtUtc { get; init; }
        public long AmountH { get; init; }
        public string? PurchaseId { get; init; }
        public string? PaymentId { get; init; }
        public string? Method { get; init; }
        public string? VendorInvoiceNumber { get; init; }
        public string? Note { get; init; }
    }

    private sealed record PaymentRow
    {
        public string PaymentId { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public string VendorId { get; init; } = string.Empty;
        public long AmountH { get; init; }
        public string Method { get; init; } = string.Empty;
        public string? Note { get; init; }
        public string PaidBy { get; init; } = string.Empty;
        public DateTime PaidAtUtc { get; init; }
        public string? BranchId { get; init; }
        public string? EntryId { get; init; }
        public DateTime CreatedAtUtc { get; init; }
    }

    private sealed record AllocationRow
    {
        public string PaymentId { get; init; } = string.Empty;
        public string PurchaseId { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public long AmountH { get; init; }
    }

    private sealed record PurchaseRow
    {
        public string PurchaseId { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public string VendorId { get; init; } = string.Empty;
        public string VendorNameAr { get; init; } = string.Empty;
        public string VendorNameEn { get; init; } = string.Empty;
        public string? BranchId { get; init; }
        public string? InvoiceNumber { get; init; }
        public long SubtotalH { get; init; }
        public long TaxH { get; init; }
        public long TotalH { get; init; }
        public bool PaidOnReceipt { get; init; }
        public long PaidH { get; init; }
        public string? Note { get; init; }
        public string ReceivedBy { get; init; } = string.Empty;
        public DateTime ReceivedAtUtc { get; init; }
    }

    private sealed record PurchaseLineRow
    {
        public string PurchaseId { get; init; } = string.Empty;
        public string ItemId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public decimal Quantity { get; init; }
        public long UnitCostH { get; init; }
    }

    private sealed record PurchasePaymentRow
    {
        public string PaymentId { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public string Method { get; init; } = string.Empty;
        public long AmountH { get; init; }
        public DateTime PaidAtUtc { get; init; }
    }
}
