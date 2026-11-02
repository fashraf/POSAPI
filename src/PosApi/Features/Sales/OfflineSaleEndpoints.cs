using System.Text.Json;
using Dapper;
using Npgsql;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Sales;

/// <summary>A sale the phone took offline and the server then refused.</summary>
public sealed record OfflineIssueRequest(
    string LocalId,
    string BranchId,
    /* The POST /api/sales body the phone sent, unchanged. */
    JsonElement Sale,
    string? ErrorCode,
    string? ErrorMessage,
    DateTime? OccurredAt);

public sealed record ResolveOfflineIssueRequest(string? Reason, string? Note);

/// <summary>
/// Offline sales the server refused at sync.
///
/// The customer paid and left with a receipt while the phone was offline; at
/// sync the server said no (the stock was sold meanwhile, the drawer was
/// closed, a price changed). Dropping it would leave money taken with no
/// invoice, no VAT and no drawer entry, and nobody told. Instead the phone
/// reports it here, managers are notified, and a manager either posts it
/// anyway — on their authority, stock may go below zero — or records that the
/// customer was refunded. The phone keeps the order and shows its outcome.
/// </summary>
public static class OfflineSaleEndpoints
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static void MapOfflineSaleEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/sales/offline-issues")
            .WithTags("Sales")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapPost("", ReportAsync)
             .RequireAuthorization(PermissionPolicy.For("pos.create_sale"));

        /* The phone asks after its own orders; any signed-in user. */
        group.MapGet("/by-local", ByLocalAsync);

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("sales.resolve_offline"));

        group.MapPost("/{issueId}/post", PostAsync)
             .RequireAuthorization(PermissionPolicy.For("sales.resolve_offline"));

        group.MapPost("/{issueId}/refund", RefundAsync)
             .RequireAuthorization(PermissionPolicy.For("sales.resolve_offline"));
    }

    private sealed record IssueRow
    {
        public string IssueId { get; init; } = "";
        public string LocalId { get; init; } = "";
        public string BranchId { get; init; } = "";
        public string? BranchNameAr { get; init; }
        public string? BranchNameEn { get; init; }
        public string? CashierUserId { get; init; }
        public string CashierName { get; init; } = "";
        public string Request { get; init; } = "{}";
        public long TotalH { get; init; }
        public string? ErrorCode { get; init; }
        public string? ErrorMessage { get; init; }
        public DateTime OccurredAtUtc { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string Status { get; init; } = "open";
        public string? SaleId { get; init; }
        public string? InvoiceNumber { get; init; }
        public string? ResolvedBy { get; init; }
        public DateTime? ResolvedAtUtc { get; init; }
        public string? Note { get; init; }
    }

    private const string Select = """
        SELECT o.IssueId, o.LocalId, o.BranchId, b.NameAr AS BranchNameAr, b.NameEn AS BranchNameEn,
               o.CashierUserId, o.CashierName, o.Request::text AS Request, o.TotalH,
               o.ErrorCode, o.ErrorMessage, o.OccurredAtUtc, o.CreatedAtUtc, o.Status,
               o.SaleId, o.InvoiceNumber, o.ResolvedBy, o.ResolvedAtUtc, o.Note
        FROM sales.OfflineSaleIssue AS o
        LEFT JOIN core.Branch AS b ON b.BranchId = o.BranchId
        """;

    private static CommitSaleRequest? ReadSale(string json)
    {
        try { return JsonSerializer.Deserialize<CommitSaleRequest>(json, Json); }
        catch (JsonException) { return null; }
    }

    /* What the customer paid: the lines less their discounts and the invoice
       discount, cut to whole halalas as the till cut them. */
    private static long TotalOf(CommitSaleRequest sale) =>
        (long)Math.Truncate(sale.Lines.Sum(l => l.UnitPriceH * l.Quantity - l.LineDiscountH)) - sale.DiscountH;

    /* The till's own error codes, in both languages — the phone reports the
       message in whichever language it was showing. */
    private static readonly Dictionary<string, ApiError> Messages =
        new[] { 52000, 52001, 52002, 52003, 52004, 52005, 52006, 52007, 52008, 52030, 52031,
                52040, 52041, 52042, 52043, 52044, 52045, 52050, 63050, 63051 }
            .Select(n => SalesEndpoints.Translate(n, ""))
            .GroupBy(e => e.Code)
            .ToDictionary(g => g.Key, g => g.First());

    private static object Shape(IssueRow r, IReadOnlyDictionary<string, (string NameAr, string NameEn)> names)
    {
        var sale = ReadSale(r.Request);
        var message = r.ErrorCode is not null && Messages.TryGetValue(r.ErrorCode, out var known) ? known : null;
        return new
        {
            r.IssueId,
            r.LocalId,
            r.BranchId,
            r.BranchNameAr,
            r.BranchNameEn,
            r.CashierName,
            r.TotalH,
            r.ErrorCode,
            errorMessageEn = message?.MessageEn ?? r.ErrorMessage,
            errorMessageAr = message?.MessageAr ?? r.ErrorMessage,
            occurredAt = r.OccurredAtUtc,
            createdAt = r.CreatedAtUtc,
            r.Status,
            r.SaleId,
            r.InvoiceNumber,
            r.ResolvedBy,
            resolvedAt = r.ResolvedAtUtc,
            r.Note,
            lines = sale?.Lines.Select(l => new
            {
                l.ItemId,
                nameAr = names.TryGetValue(l.ItemId, out var n) ? n.NameAr : l.ItemId,
                nameEn = names.TryGetValue(l.ItemId, out var m) ? m.NameEn : l.ItemId,
                l.Quantity, l.UnitPriceH, l.LineDiscountH
            }).ToList(),
            payments = sale?.Payments?.Select(p => new { p.Method, p.AmountH }).ToList()
        };
    }

    /* The bell shows the change now, not at its next scheduled refresh. */
    private static async Task RefreshNotificationsAsync(NpgsqlConnection connection, ILogger logger, CancellationToken ct)
    {
        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "SELECT core.usp_RefreshNotifications();", cancellationToken: ct));
        }
        catch (PostgresException ex)
        {
            logger.LogWarning(ex, "Refreshing notifications after an offline sale change failed.");
        }
    }

    private static async Task<IResult> ReportAsync(
        OfflineIssueRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        var localId = ProcErrors.Blank(request.LocalId);
        var sale = request.Sale.ValueKind == JsonValueKind.Object ? ReadSale(request.Sale.GetRawText()) : null;

        if (localId is null || localId.Length > 64 || sale?.Lines is not { Count: > 0 })
        {
            return Results.UnprocessableEntity(ApiError.Create(
                "invalid_issue", "An offline sale needs its reference and its lines.",
                "يحتاج البيع غير المتصل إلى مرجعه وأصنافه."));
        }

        if (!current.CanSeeBranch(request.BranchId))
        {
            return Results.Json(ApiError.Create("branch_forbidden",
                "You cannot report a sale for that branch.", "لا يمكنك الإبلاغ عن فاتورة لهذا الفرع."),
                statusCode: StatusCodes.Status403Forbidden);
        }

        await using var connection = db.Create();

        /* The reference is the sale's idempotency key, so the issue cannot be
           recorded twice — and if the sale did land after all (the refusal
           raced a retry), there is nothing to resolve. */
        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO sales.OfflineSaleIssue
                (IssueId, LocalId, BranchId, CashierUserId, CashierName, Request, TotalH,
                 ErrorCode, ErrorMessage, OccurredAtUtc, Status, SaleId, InvoiceNumber, ResolvedAtUtc)
            SELECT core.fn_NewId('ofl_'), @LocalId, @BranchId, @UserId, @Username, @Request::jsonb, @TotalH,
                   left(@ErrorCode, 60), left(@ErrorMessage, 600),
                   COALESCE(@OccurredAt, now() AT TIME ZONE 'utc'),
                   CASE WHEN s.SaleId IS NULL THEN 'open' ELSE 'posted' END,
                   s.SaleId, s.InvoiceNumber,
                   CASE WHEN s.SaleId IS NULL THEN NULL ELSE now() AT TIME ZONE 'utc' END
            FROM (SELECT 1) AS one
            LEFT JOIN sales.Sale AS s ON s.IdempotencyKey = @LocalId
            ON CONFLICT (LocalId) DO NOTHING;
            """,
            new
            {
                LocalId = localId,
                request.BranchId,
                current.UserId,
                current.Username,
                Request = request.Sale.GetRawText(),
                TotalH = TotalOf(sale),
                request.ErrorCode,
                request.ErrorMessage,
                OccurredAt = request.OccurredAt?.ToUniversalTime()
            },
            cancellationToken: ct));

        var row = await connection.QuerySingleAsync<IssueRow>(new CommandDefinition(
            Select + " WHERE o.LocalId = @LocalId;", new { LocalId = localId }, cancellationToken: ct));

        logger.LogWarning("Offline sale {LocalId} refused at sync ({Code}); recorded as {IssueId}.",
            localId, request.ErrorCode, row.IssueId);

        await RefreshNotificationsAsync(connection, logger, ct);

        return Results.Created($"/api/sales/offline-issues/{row.IssueId}",
            new { row.IssueId, row.Status, row.SaleId, row.InvoiceNumber });
    }

    private static async Task<IResult> ByLocalAsync(
        string? ids, ISqlConnectionFactory db, CancellationToken ct)
    {
        var wanted = (ids ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct().Take(100).ToArray();
        if (wanted.Length == 0) return Results.Ok(Array.Empty<object>());

        await using var connection = db.Create();

        var rows = await connection.QueryAsync<IssueRow>(new CommandDefinition(
            Select + " WHERE o.LocalId = ANY(@Ids);", new { Ids = wanted }, cancellationToken: ct));

        return Results.Ok(rows.Select(r => new { r.LocalId, r.IssueId, r.Status, r.SaleId, r.InvoiceNumber, r.Note }));
    }

    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, ICurrentUser current, string? status, string? branchId,
        CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync<IssueRow>(new CommandDefinition(
            Select + """
                 WHERE (@All OR o.Status = 'open')
                   AND (@BranchId IS NULL OR o.BranchId = @BranchId)
                   AND (cardinality(@Branches) = 0 OR o.BranchId = ANY(@Branches))
                 ORDER BY o.CreatedAtUtc DESC
                 LIMIT 200;
                """,
            new
            {
                All = status == "all",
                BranchId = ProcErrors.Blank(branchId),
                Branches = current.BranchIds.ToArray()
            },
            cancellationToken: ct));

        var list = rows.ToList();
        var itemIds = list.Select(r => ReadSale(r.Request)).Where(x => x?.Lines is not null)
            .SelectMany(x => x!.Lines.Select(l => l.ItemId)).Distinct().ToArray();

        var names = (await connection.QueryAsync<(string ItemId, string NameAr, string NameEn)>(new CommandDefinition(
                "SELECT ItemId, NameAr, NameEn FROM core.CatalogItem WHERE ItemId = ANY(@Ids);",
                new { Ids = itemIds }, cancellationToken: ct)))
            .ToDictionary(x => x.ItemId, x => (x.NameAr, x.NameEn), StringComparer.OrdinalIgnoreCase);

        return Results.Ok(list.Select(r => Shape(r, names)));
    }

    private static async Task<IssueRow?> OpenIssueAsync(
        NpgsqlConnection connection, NpgsqlTransaction tx, string issueId, CancellationToken ct) =>
        await connection.QuerySingleOrDefaultAsync<IssueRow>(new CommandDefinition(
            Select + " WHERE o.IssueId = @IssueId FOR UPDATE OF o;", new { IssueId = issueId }, tx, cancellationToken: ct));

    private static IResult? Refuse(IssueRow? issue, ICurrentUser current)
    {
        if (issue is null || !current.CanSeeBranch(issue.BranchId))
            return ProcErrors.NotFound("Offline sale not found.", "البيع غير المتصل غير موجود.");

        if (issue.Status != "open")
            return ProcErrors.Conflict("already_resolved",
                "This offline sale has already been resolved.", "تمت معالجة هذا البيع غير المتصل مسبقًا.");

        return null;
    }

    /// <summary>
    /// Post the sale anyway. The original sale goes through the same function as
    /// a till sale, under its own reference, with the cashier who took it — only
    /// the stock and drawer checks give way, and anything that differs from the
    /// catalog is recorded as this manager's override with their reason.
    /// </summary>
    private static async Task<IResult> PostAsync(
        string issueId, ResolveOfflineIssueRequest request,
        ISqlConnectionFactory db, ICurrentUser current, ILogger<Program> logger, CancellationToken ct)
    {
        var reason = ProcErrors.Blank(request.Reason);
        if (reason is null)
            return ProcErrors.Field("reason", "Say why the sale is being posted.", "اذكر سبب تسجيل البيع.");

        await using var connection = await db.CreateOpenAsync(ct);
        await using var tx = await connection.BeginTransactionAsync(ct);

        var issue = await OpenIssueAsync(connection, tx, issueId, ct);
        if (Refuse(issue, current) is { } refusal) return refusal;

        var sale = ReadSale(issue!.Request);
        if (sale?.Lines is not { Count: > 0 })
            return ProcErrors.Conflict("unreadable_sale", "The offline sale's contents cannot be read.",
                "تعذّرت قراءة محتوى البيع غير المتصل.");

        string saleId, invoiceNumber;

        try
        {
            (saleId, invoiceNumber) = await SalesEndpoints.CommitSaleAsync(
                connection, tx, sale with { IdempotencyKey = issue.LocalId, BranchId = issue.BranchId },
                issue.CashierName, issue.CashierUserId, approverId: null,
                forcedByUserId: current.UserId, forceReason: reason, ct);
        }
        catch (PostgresException ex) when (ex.ErrorNumber() is (>= 52000 and < 53000) or 63050 or 63051)
        {
            return Results.Json(SalesEndpoints.Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE sales.OfflineSaleIssue
            SET Status = 'posted', SaleId = @SaleId, InvoiceNumber = @InvoiceNumber,
                ResolvedBy = @Username, ResolvedAtUtc = now() AT TIME ZONE 'utc', Note = @Reason
            WHERE IssueId = @IssueId;
            """,
            new { SaleId = saleId, InvoiceNumber = invoiceNumber, current.Username, Reason = reason, IssueId = issueId },
            tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
        await RefreshNotificationsAsync(connection, logger, ct);

        logger.LogInformation("Offline sale {LocalId} posted by {User} as {Invoice}.", issue.LocalId, current.Username, invoiceNumber);

        return Results.Ok(new { saleId, invoiceNumber });
    }

    /// <summary>
    /// The customer was given their money back. Nothing is posted: the cash came
    /// in and went out again while the phone was offline. The issue records who
    /// settled it and how.
    /// </summary>
    private static async Task<IResult> RefundAsync(
        string issueId, ResolveOfflineIssueRequest request,
        ISqlConnectionFactory db, ICurrentUser current, ILogger<Program> logger, CancellationToken ct)
    {
        var note = ProcErrors.Blank(request.Note) ?? ProcErrors.Blank(request.Reason);
        if (note is null)
            return ProcErrors.Field("note", "Describe the refund.", "صف عملية الاسترداد.");

        await using var connection = await db.CreateOpenAsync(ct);
        await using var tx = await connection.BeginTransactionAsync(ct);

        var issue = await OpenIssueAsync(connection, tx, issueId, ct);
        if (Refuse(issue, current) is { } refusal) return refusal;

        await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE sales.OfflineSaleIssue
            SET Status = 'refunded', ResolvedBy = @Username,
                ResolvedAtUtc = now() AT TIME ZONE 'utc', Note = left(@Note, 600)
            WHERE IssueId = @IssueId;
            """,
            new { current.Username, Note = note, IssueId = issueId }, tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
        await RefreshNotificationsAsync(connection, logger, ct);

        logger.LogInformation("Offline sale {LocalId} recorded as refunded by {User}.", issue!.LocalId, current.Username);

        return Results.Ok(new { status = "refunded" });
    }
}
