using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
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

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT i.ItemId, i.NameAr, i.NameEn, i.Sku, i.Barcode, i.CategoryId, i.CostH,
                   ISNULL(s.Quantity, 0) AS SystemQuantity
            FROM core.CatalogItem AS i
            LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId
            WHERE i.TracksStock = 1 AND i.IsActive = 1
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

        var lines = new DataTable();
        lines.Columns.Add("ItemId", typeof(string));
        lines.Columns.Add("CountedQuantity", typeof(decimal));

        foreach (var line in request.Lines ?? [])
        {
            /* An id that cannot exist is the same answer as an unknown item,
               not a truncation error from the table parameter. */
            if (string.IsNullOrWhiteSpace(line.ItemId) || line.ItemId.Length > 40)
                return ProcErrors.Field("lines",
                    "Only items that track stock can be counted.", "يمكن جرد الأصناف التي تتتبّع المخزون فقط.");

            lines.Rows.Add(line.ItemId, line.CountedQuantity);
        }

        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@Lines", lines.AsTableValuedParameter("inv.StocktakeLineTable"));
        parameters.Add("@Note", ProcErrors.Blank(request.Note));
        parameters.Add("@Actor", current.Username);
        parameters.Add("@Reference", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        List<StocktakeLineResult> changed;

        try
        {
            changed = (await connection.QueryAsync<StocktakeLineResult>(new CommandDefinition(
                "inv.usp_PostStocktake", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct))).ToList();
        }
        catch (SqlException ex) when (ex.Number is >= 54030 and <= 54034)
        {
            return ex.Number switch
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

        var reference = parameters.Get<string>("@Reference");

        logger.LogInformation("Stocktake {Reference} posted for {BranchId} by {User}: {Lines} lines changed.",
            reference, request.BranchId, current.Username, changed.Count);

        http.Items["AuditEntityId"] = reference;

        return Results.Ok(new StocktakeResult(
            reference, request.BranchId, changed.Count, changed.Sum(l => l.ValueH), changed));
    }
}
