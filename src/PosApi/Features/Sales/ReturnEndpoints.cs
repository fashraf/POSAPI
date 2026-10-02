using System.Data;
using System.Globalization;
using System.Text.Json;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Sales;

/// <summary>
/// One line to return. <c>SaleLineId</c> is the sale line's id as GET
/// /api/sales/{id} returns it (a number); a numeric string is accepted too.
/// </summary>
public sealed record ReturnLineRequest(JsonElement SaleLineId, decimal Quantity);

public sealed record IssueReturnRequest(
    IReadOnlyList<ReturnLineRequest>? Lines,
    string Reason,
    string? Note,
    string RefundMethod);

public sealed record CreditNoteLineDto(
    string SaleLineId,
    string ItemId,
    string NameAr,
    string NameEn,
    decimal Quantity,
    long UnitPriceH,
    long AmountH);

/// <summary>
/// A credit note, in the frontend CreditNote's names. <c>TotalH</c> is what
/// was refunded (VAT inclusive), <c>TaxH</c> its VAT, <c>SubtotalH</c> the
/// rest. <c>AmountH</c> on a line is that line's share of the refund, after
/// its share of any invoice discount.
/// </summary>
public sealed record CreditNoteDto(
    string Id,
    string NoteNumber,
    string SaleId,
    string SaleInvoiceNumber,
    IReadOnlyList<CreditNoteLineDto> Lines,
    string Reason,
    string Note,
    long SubtotalH,
    long TaxH,
    long TotalH,
    long CogsH,
    string RefundMethod,
    string IssuedBy,
    DateTime IssuedAt,
    string? BranchId,
    string? CustomerId,
    string? EntryId,
    DateTime CreatedAt,
    DateTime UpdatedAt);

public static class ReturnEndpoints
{
    public static void MapReturnEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/sales")
            .WithTags("Returns")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/{saleId}/returns", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("sales.view_details"));

        group.MapGet("/{saleId}/returns/remaining", RemainingAsync)
             .RequireAuthorization(PermissionPolicy.For("sales.view_details"));

        group.MapPost("/{saleId}/returns", IssueAsync)
             .RequireAuthorization(PermissionPolicy.For("sales.return"));
    }

    private static async Task<IResult> ListAsync(
        string saleId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        var branch = await SaleBranchAsync(connection, saleId, ct);
        if (branch is null) return SaleNotFound();
        if (!current.CanSeeBranch(branch.BranchId)) return Results.Forbid();

        return Results.Ok(await LoadAsync(connection, saleId, null, ct));
    }

    /// <summary>What can still be returned, by sale line id: {"12": 2, "13": 0}.</summary>
    private static async Task<IResult> RemainingAsync(
        string saleId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        var branch = await SaleBranchAsync(connection, saleId, ct);
        if (branch is null) return SaleNotFound();
        if (!current.CanSeeBranch(branch.BranchId)) return Results.Forbid();

        var rows = await connection.QueryAsync<(long SaleLineId, decimal Remaining)>(new CommandDefinition(
            """
            SELECT sl.SaleLineId,
                   CASE WHEN s.Status = N'voided' THEN 0 ELSE sl.Quantity - sl.ReturnedQty END AS Remaining
            FROM sales.SaleLine AS sl
            JOIN sales.Sale AS s ON s.SaleId = sl.SaleId
            WHERE sl.SaleId = @SaleId
            ORDER BY sl.SaleLineId;
            """,
            new { SaleId = saleId }, cancellationToken: ct));

        return Results.Ok(rows.ToDictionary(
            r => r.SaleLineId.ToString(CultureInfo.InvariantCulture), r => r.Remaining));
    }

    /// <summary>
    /// Issue a credit note through sales.usp_IssueReturn: restock, reverse
    /// revenue, VAT and COGS, cut unpaid commission, refund, in one
    /// transaction. Money leaving the business (cash, card, bank) also needs
    /// sales.refund; a refund to the customer's account needs only sales.return.
    /// </summary>
    private static async Task<IResult> IssueAsync(
        string saleId,
        IssueReturnRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        var method = request.RefundMethod?.Trim().ToLowerInvariant();

        if (method is "cash" or "card" or "bank" && !current.Can("sales.refund"))
            return ProcErrors.Forbidden("refund_forbidden",
                "Refunding money needs the refund permission. Refund to the customer's account, or ask a manager.",
                "رد المبلغ يحتاج صلاحية الاسترداد. أعده إلى حساب العميل أو اطلب من المدير.");

        var lines = new DataTable();
        lines.Columns.Add("SaleLineId", typeof(long));
        lines.Columns.Add("Quantity", typeof(decimal));

        foreach (var line in request.Lines ?? [])
        {
            if (!TryLineId(line.SaleLineId, out var lineId))
                return Unprocessable("unknown_line", "lines",
                    "That line is not part of this invoice.", "هذا السطر ليس من هذه الفاتورة.");

            lines.Rows.Add(lineId, line.Quantity);
        }

        await using var connection = db.Create();

        var branch = await SaleBranchAsync(connection, saleId, ct);
        if (branch is null) return SaleNotFound();
        if (!current.CanSeeBranch(branch.BranchId)) return Results.Forbid();

        var parameters = new DynamicParameters();
        parameters.Add("@SaleId", saleId);
        parameters.Add("@ReasonCode", request.Reason?.Trim());
        parameters.Add("@Note", ProcErrors.Blank(request.Note));
        parameters.Add("@RefundMethod", method);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@Lines", lines.AsTableValuedParameter("sales.ReturnLineTable"));
        parameters.Add("@ReturnId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);
        parameters.Add("@NoteNumber", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "sales.usp_IssueReturn", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapError(ex) is { } mapped)
        {
            return mapped;
        }

        var returnId = parameters.Get<string>("@ReturnId");

        logger.LogInformation("Credit note {NoteNumber} issued against {SaleId} by {Actor}.",
            parameters.Get<string>("@NoteNumber"), saleId, current.Username);
        http.Items["AuditEntityId"] = returnId;

        var note = (await LoadAsync(connection, saleId, returnId, ct)).Single();

        return Results.Created($"/api/sales/{saleId}/returns/{returnId}", note);
    }

    private static bool TryLineId(JsonElement value, out long id)
    {
        id = 0;
        return value.ValueKind switch
        {
            JsonValueKind.Number => value.TryGetInt64(out id),
            JsonValueKind.String => long.TryParse(value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out id),
            _ => false
        };
    }

    private static Task<SaleRef?> SaleBranchAsync(
        SqlConnection connection, string saleId, CancellationToken ct) =>
        connection.QuerySingleOrDefaultAsync<SaleRef?>(new CommandDefinition(
            "SELECT BranchId, Status FROM sales.Sale WHERE SaleId = @SaleId;",
            new { SaleId = saleId }, cancellationToken: ct));

    internal static async Task<List<CreditNoteDto>> LoadAsync(
        SqlConnection connection, string saleId, string? returnId, CancellationToken ct)
    {
        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT r.ReturnId, r.NoteNumber, r.SaleId, s.InvoiceNumber, r.ReasonCode, r.Note, r.ReasonEn,
                   r.SubtotalH, r.TaxH, r.RefundH, r.CogsH, r.RefundMethod, r.ReturnedBy, r.ReturnedAtUtc,
                   r.BranchId, r.CustomerId, r.EntryId
            FROM sales.SaleReturn AS r
            JOIN sales.Sale AS s ON s.SaleId = r.SaleId
            WHERE r.SaleId = @SaleId AND (@ReturnId IS NULL OR r.ReturnId = @ReturnId)
            ORDER BY r.ReturnedAtUtc DESC;

            SELECT rl.ReturnId, rl.SaleLineId, ISNULL(rl.ItemId, sl.ItemId) AS ItemId, sl.NameAr, sl.NameEn,
                   rl.Quantity, CASE WHEN rl.UnitPriceH > 0 THEN rl.UnitPriceH ELSE sl.UnitPriceH END AS UnitPriceH,
                   rl.AmountH
            FROM sales.SaleReturnLine AS rl
            JOIN sales.SaleReturn AS r ON r.ReturnId = rl.ReturnId
            JOIN sales.SaleLine AS sl ON sl.SaleLineId = rl.SaleLineId
            WHERE r.SaleId = @SaleId AND (@ReturnId IS NULL OR r.ReturnId = @ReturnId)
            ORDER BY rl.ReturnLineId;
            """,
            new { SaleId = saleId, ReturnId = returnId }, cancellationToken: ct));

        var notes = (await multi.ReadAsync<NoteRow>()).ToList();
        var lines = (await multi.ReadAsync<NoteLineRow>()).ToLookup(l => l.ReturnId);

        return notes.Select(n => new CreditNoteDto(
            n.ReturnId, n.NoteNumber ?? n.ReturnId, n.SaleId, n.InvoiceNumber,
            lines[n.ReturnId].Select(l => new CreditNoteLineDto(
                l.SaleLineId.ToString(CultureInfo.InvariantCulture), l.ItemId, l.NameAr, l.NameEn,
                l.Quantity, l.UnitPriceH, l.AmountH)).ToList(),
            n.ReasonCode ?? "other", n.Note ?? (n.ReasonCode is null ? n.ReasonEn : null) ?? string.Empty,
            n.SubtotalH, n.TaxH, n.RefundH, n.CogsH, n.RefundMethod ?? "cash",
            n.ReturnedBy, n.ReturnedAtUtc, n.BranchId, n.CustomerId, n.EntryId,
            n.ReturnedAtUtc, n.ReturnedAtUtc)).ToList();
    }

    private static IResult SaleNotFound() =>
        ProcErrors.NotFound("Sale not found.", "الفاتورة غير موجودة.");

    private static IResult Unprocessable(string code, string field, string en, string ar) =>
        Results.UnprocessableEntity(ApiError.Create(code, en, ar,
            new Dictionary<string, string[]> { [field] = [en] }));

    private static IResult? MapError(SqlException ex) => ex.Number switch
    {
        67000 => SaleNotFound(),
        67001 => ProcErrors.Conflict("sale_voided",
            "A voided sale has nothing left to return.", "الفاتورة الملغاة لا يوجد بها ما يُرتجع."),
        67002 => Unprocessable("nothing_to_return", "lines",
            "Choose at least one item to return.", "اختر صنفًا واحدًا على الأقل لإرجاعه."),
        67003 => Unprocessable("unknown_line", "lines",
            "That line is not part of this invoice.", "هذا السطر ليس من هذه الفاتورة."),
        67004 => Unprocessable("over_return", "lines",
            "You cannot return more than was sold and not already returned.",
            "لا يمكن إرجاع أكثر مما بيع ولم يُرجع بعد."),
        67005 => ProcErrors.Field("refundMethod",
            "Refund by cash, card, bank or to the customer's account.",
            "الاسترداد نقدًا أو بالبطاقة أو تحويلًا أو إلى حساب العميل."),
        67006 => Unprocessable("credit_needs_customer", "refundMethod",
            "A refund to account needs a customer on the sale.", "الاسترداد إلى الحساب يحتاج عميلًا على الفاتورة."),
        67007 => Unprocessable("refund_exceeds_balance", "refundMethod",
            "The refund is more than the customer owes. Refund it in cash or by card instead.",
            "مبلغ الاسترداد أكبر مما على العميل. استرده نقدًا أو بالبطاقة."),
        67008 => ProcErrors.Field("reason", "Choose a reason for the return.", "اختر سبب الإرجاع."),
        67009 => Unprocessable("note_required", "note",
            "Describe the reason when choosing \"Other\".", "اكتب السبب عند اختيار \"أخرى\"."),
        67010 => Unprocessable("bad_quantity", "lines",
            "Return quantities cannot be negative.", "لا يمكن أن تكون كميات الإرجاع سالبة."),
        _ => null
    };

    private sealed record SaleRef
    {
        public string? BranchId { get; init; }
        public string Status { get; init; } = string.Empty;
    }

    private sealed record NoteRow
    {
        public string ReturnId { get; init; } = string.Empty;
        public string? NoteNumber { get; init; }
        public string SaleId { get; init; } = string.Empty;
        public string InvoiceNumber { get; init; } = string.Empty;
        public string? ReasonCode { get; init; }
        public string? Note { get; init; }
        public string? ReasonEn { get; init; }
        public long SubtotalH { get; init; }
        public long TaxH { get; init; }
        public long RefundH { get; init; }
        public long CogsH { get; init; }
        public string? RefundMethod { get; init; }
        public string ReturnedBy { get; init; } = string.Empty;
        public DateTime ReturnedAtUtc { get; init; }
        public string? BranchId { get; init; }
        public string? CustomerId { get; init; }
        public string? EntryId { get; init; }
    }

    private sealed record NoteLineRow
    {
        public string ReturnId { get; init; } = string.Empty;
        public long SaleLineId { get; init; }
        public string ItemId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public decimal Quantity { get; init; }
        public long UnitPriceH { get; init; }
        public long AmountH { get; init; }
    }
}
