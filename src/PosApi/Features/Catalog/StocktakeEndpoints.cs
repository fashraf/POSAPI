using Dapper;
using Npgsql;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Catalog;

public sealed record StocktakeLineInput(string ItemId, decimal CountedQuantity);

/// <summary>A branch's count. Lines that match the system quantity may be sent; they are skipped.</summary>
public sealed record PostStocktakeRequest(
    string BranchId,
    IReadOnlyList<StocktakeLineInput>? Lines,
    string? Note = null);

public sealed record StocktakeLineResult(
    string ItemId,
    string NameAr,
    string NameEn,
    string? Sku,
    decimal SystemQuantity,
    decimal CountedQuantity,
    decimal Difference,
    long ValueH);

public sealed record StocktakeResult(
    string Reference,
    string BranchId,
    int ChangedLines,
    long NetValueH,
    IReadOnlyList<StocktakeLineResult> Lines);

public static class StocktakeEndpoints
{
    public static void MapStocktakeEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/inventory/stocktake")
            .WithTags("Inventory")
            .RequireAuthorization(PermissionPolicy.For("inventory.stocktake"))
            .RequireRateLimiting("standard");

        group.MapGet("/sheet", SheetAsync);
        group.MapPost("", PostAsync);
    }

    /// <summary>
    /// The count sheet for a branch: every active item that tracks stock, with
    /// the quantity the system holds there now (zero where it has never been
    /// stocked). Not paged — a count covers the whole shelf.
    /// </summary>
    private static async Task<IResult> SheetAsync(
        string? branchId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(branchId))
            return ProcErrors.Field("branchId", "Choose the branch being counted.", "اختر الفرع الذي يتم جرده.");

        if (!current.CanSeeBranch(branchId)) return Results.Forbid();

        await using var connection = db.Create();

        var rows = await connection.QueryRowsAsync(new CommandDefinition(
            """
            SELECT i.ItemId, i.NameAr, i.NameEn, i.Sku, i.Barcode, i.CategoryId, i.CostH,
                   COALESCE(s.Quantity, 0) AS SystemQuantity
            FROM core.CatalogItem AS i
            LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId
            WHERE i.TracksStock AND i.IsActive
            ORDER BY i.NameEn;
            """,
            new { BranchId = branchId }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    /// <summary>
    /// Post a count. Every line that differs becomes a stock movement under one
    /// stocktake reference, with one journal entry for the variance — all in a
    /// single transaction (inv.usp_PostStocktake), so a count is never half
    /// posted. Refused with 422 when nothing changed.
    /// </summary>
    private static async Task<IResult> PostAsync(
        PostStocktakeRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.BranchId))
            return ProcErrors.Field("branchId", "Choose the branch being counted.", "اختر الفرع الذي يتم جرده.");

        if (!current.CanSeeBranch(request.BranchId)) return Results.Forbid();

        var lines = new List<StocktakeLineInput>();

        foreach (var line in request.Lines ?? [])
        {
            /* An id that cannot exist is the same answer as an unknown item,
               not a truncation error from the list parameter. */
            if (string.IsNullOrWhiteSpace(line.ItemId) || line.ItemId.Length > 40)
                return ProcErrors.Field("lines",
                    "Only items that track stock can be counted.", "يمكن جرد الأصناف التي تتتبّع المخزون فقط.");

            lines.Add(line);
        }

        await using var connection = db.Create();

        List<StocktakeRow> rows;

        try
        {
            /* Every row carries the stocktake's reference; a posted count always
               changes at least one line (54033 otherwise). */
            rows = (await connection.QueryAsync<StocktakeRow>(new CommandDefinition(
                """
                SELECT Reference, ItemId, NameAr, NameEn, Sku, SystemQuantity,
                       CountedQuantity, Difference, ValueH
                FROM inv.usp_PostStocktake(
                    p_BranchId => @BranchId, p_Lines => @Lines::jsonb,
                    p_Note => @Note, p_Actor => @Actor);
                """,
                new
                {
                    request.BranchId,
                    Lines = DbList.Json(lines),
                    Note = ProcErrors.Blank(request.Note),
                    Actor = current.Username
                },
                cancellationToken: ct))).ToList();
        }
        catch (PostgresException ex) when (ex.ErrorNumber() is >= 54030 and <= 54034)
        {
            return ex.ErrorNumber() switch
            {
                54030 => ProcErrors.Field("lines",
                    "Enter at least one counted quantity.", "أدخل كمية معدودة واحدة على الأقل."),
                54031 => ProcErrors.Field("lines",
                    "Counts cannot be negative, and each item is counted once.",
                    "لا يمكن أن تكون الكميات سالبة، ويُعدّ كل صنف مرة واحدة."),
                54032 => ProcErrors.Field("lines",
                    "Only items that track stock can be counted.", "يمكن جرد الأصناف التي تتتبّع المخزون فقط."),
                54033 => Results.UnprocessableEntity(ApiError.Create("nothing_changed",
                    "Nothing changed: every count matches the system quantity.",
                    "لا يوجد تغيير: كل الكميات المعدودة تطابق كميات النظام.")),
                _ => ProcErrors.Field("branchId",
                    "Unknown or inactive branch.", "الفرع غير معروف أو غير نشط.")
            };
        }

        var reference = rows[0].Reference;
        var changed = rows.Select(r => new StocktakeLineResult(
            r.ItemId, r.NameAr, r.NameEn, r.Sku, r.SystemQuantity,
            r.CountedQuantity, r.Difference, r.ValueH)).ToList();

        logger.LogInformation("Stocktake {Reference} posted for {BranchId} by {User}: {Lines} lines changed.",
            reference, request.BranchId, current.Username, changed.Count);

        http.Items["AuditEntityId"] = reference;

        return Results.Ok(new StocktakeResult(
            reference, request.BranchId, changed.Count, changed.Sum(l => l.ValueH), changed));
    }

    private sealed record StocktakeRow
    {
        public string Reference { get; init; } = string.Empty;
        public string ItemId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? Sku { get; init; }
        public decimal SystemQuantity { get; init; }
        public decimal CountedQuantity { get; init; }
        public decimal Difference { get; init; }
        public long ValueH { get; init; }
    }
}
