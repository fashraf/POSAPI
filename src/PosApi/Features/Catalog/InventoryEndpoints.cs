using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Catalog;

public sealed record PurchaseLineInput(string ItemId, decimal Quantity, long UnitCostH);

public sealed record ReceivePurchaseRequest(
    string VendorId,
    string BranchId,
    string? InvoiceNumber,
    decimal VatRate,
    bool PaidOnReceipt,
    IReadOnlyList<PurchaseLineInput> Lines);

public sealed record AdjustStockRequest(
    string BranchId,
    decimal NewQuantity,
    string ReasonEn,
    string? ReasonAr);

public static class InventoryEndpoints
{
    public static void MapInventoryEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/inventory")
            .WithTags("Inventory")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/levels", LevelsAsync)
             .RequireAuthorization(PermissionPolicy.For("inventory.view"));

        group.MapGet("/movements/{itemId}", MovementsAsync)
             .RequireAuthorization(PermissionPolicy.For("inventory.view"));

        group.MapPost("/purchases", ReceiveAsync)
             .RequireAuthorization(PermissionPolicy.For("inventory.restock"));

        group.MapPost("/items/{itemId}/adjust", AdjustAsync)
             .RequireAuthorization(PermissionPolicy.For("inventory.adjust"));

        group.MapGet("/vendors", VendorsAsync)
             .RequireAuthorization(PermissionPolicy.For("vendors.view"));
    }

    /// <summary>
    /// Stock by item for one branch, with what it is worth.
    ///
    /// Only items that track stock: a service has nothing to count, and listing
    /// it with a quantity of zero invites someone to "correct" it.
    /// </summary>
    private static async Task<IResult> LevelsAsync(
        ISqlConnectionFactory db, string? branchId, string? search,
        bool? lowOnly, int page = 1, int pageSize = 25, CancellationToken ct = default)
    {
        var paging = new PageQuery { Page = page <= 0 ? 1 : page, PageSize = pageSize };

        await using var connection = db.Create();

        const string sql = """
            SELECT COUNT(*)
            FROM core.CatalogItem AS i
            LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId
            WHERE i.TracksStock = 1 AND i.IsActive = 1
              AND (@Search IS NULL OR i.NameAr LIKE N'%' + @Search + N'%'
                                   OR i.NameEn LIKE N'%' + @Search + N'%')
              AND (@LowOnly = 0 OR ISNULL(s.Quantity, 0) <= i.ReorderLevel);

            SELECT
                i.ItemId, i.NameAr, i.NameEn, i.Sku, i.CategoryId,
                i.CostH, i.PriceH, i.ReorderLevel,
                ISNULL(s.Quantity, 0) AS Quantity,
                CAST(ISNULL(s.Quantity, 0) * i.CostH AS BIGINT) AS StockValueH,
                CASE WHEN ISNULL(s.Quantity, 0) <= 0 THEN N'out'
                     WHEN ISNULL(s.Quantity, 0) <= i.ReorderLevel THEN N'low'
                     ELSE N'ok' END AS StockStatus
            FROM core.CatalogItem AS i
            LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId
            WHERE i.TracksStock = 1 AND i.IsActive = 1
              AND (@Search IS NULL OR i.NameAr LIKE N'%' + @Search + N'%'
                                   OR i.NameEn LIKE N'%' + @Search + N'%')
              AND (@LowOnly = 0 OR ISNULL(s.Quantity, 0) <= i.ReorderLevel)
            ORDER BY i.NameEn
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(sql,
            new
            {
                BranchId = branchId,
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                LowOnly = lowOnly ?? false,
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

    private static async Task<IResult> MovementsAsync(
        string itemId, ISqlConnectionFactory db, string? branchId,
        int take = 50, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (@Take)
                MovementId, ItemId, BranchId, MovementType, Quantity, BalanceAfter,
                UnitCostH, Reference, ReasonAr, ReasonEn, OccurredAtUtc, Actor
            FROM inv.StockMovement
            WHERE ItemId = @ItemId
              AND (@BranchId IS NULL OR BranchId = @BranchId OR BranchId IS NULL)
            ORDER BY OccurredAtUtc DESC;
            """,
            new { ItemId = itemId, BranchId = branchId, Take = take <= 0 ? 100 : Math.Min(take, 500) },
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> ReceiveAsync(
        ReceivePurchaseRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        CancellationToken ct)
    {
        if (!current.CanSeeBranch(request.BranchId)) return Results.Forbid();

        var lines = new DataTable();
        lines.Columns.Add("ItemId", typeof(string));
        lines.Columns.Add("Quantity", typeof(decimal));
        lines.Columns.Add("UnitCostH", typeof(long));

        foreach (var line in request.Lines)
        {
            lines.Rows.Add(line.ItemId, line.Quantity, line.UnitCostH);
        }

        var parameters = new DynamicParameters();
        parameters.Add("@VendorId", request.VendorId);
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@InvoiceNumber", request.InvoiceNumber);
        parameters.Add("@VatRate", request.VatRate <= 0 ? 15.00m : request.VatRate);
        parameters.Add("@PaidOnReceipt", request.PaidOnReceipt);
        parameters.Add("@ReceivedBy", current.Username);
        parameters.Add("@Lines", lines.AsTableValuedParameter("inv.PurchaseLineTable"));
        parameters.Add("@PurchaseId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);
        parameters.Add("@Reference", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inv.usp_ReceivePurchase", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 54000 && ex.Number < 55000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new
        {
            purchaseId = parameters.Get<string>("@PurchaseId"),
            reference = parameters.Get<string>("@Reference")
        });
    }

    private static async Task<IResult> AdjustAsync(
        string itemId,
        AdjustStockRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        CancellationToken ct)
    {
        if (!current.CanSeeBranch(request.BranchId)) return Results.Forbid();

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "inv.usp_AdjustStock",
                new
                {
                    ItemId = itemId,
                    request.BranchId,
                    request.NewQuantity,
                    request.ReasonEn,
                    request.ReasonAr,
                    Actor = current.Username
                },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 54000 && ex.Number < 55000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.NoContent();
    }

    private static async Task<IResult> VendorsAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT v.VendorId, v.NameAr, v.NameEn, v.ContactPerson, v.Phone, v.Email,
                   v.VatNumber, v.PaymentTermDays, v.IsActive,
                   ISNULL(owed.BalanceH, 0) AS BalanceH
            FROM core.Vendor AS v
            OUTER APPLY (
                SELECT SUM(p.TotalH) AS BalanceH
                FROM inv.Purchase AS p
                WHERE p.VendorId = v.VendorId AND p.PaidOnReceipt = 0
            ) AS owed
            WHERE v.IsActive = 1
            ORDER BY v.NameEn;
            """,
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    internal static ApiError Translate(int number, string fallback) => number switch
    {
        54000 => ApiError.Create("empty_delivery",
            "A delivery needs at least one line.", "الاستلام يحتاج صنفًا واحدًا على الأقل."),
        54001 => ApiError.Create("bad_quantity",
            "Quantities must be above zero and costs cannot be negative.",
            "يجب أن تكون الكميات أكبر من صفر والتكاليف غير سالبة."),
        54002 => ApiError.Create("service_not_stocked",
            "A service cannot be received into stock.", "لا يمكن استلام خدمة في المخزون."),
        54010 => ApiError.Create("reason_required",
            "An adjustment needs a reason.", "التسوية تحتاج إلى سبب."),
        54011 => ApiError.Create("negative_stock",
            "Stock cannot be negative.", "لا يمكن أن يكون المخزون سالبًا."),
        54012 => ApiError.Create("not_stocked",
            "This item does not track stock.", "هذا الصنف لا يتتبّع المخزون."),
        54020 => ApiError.Create("bad_amount",
            "An expense must be above zero.", "يجب أن يكون المصروف أكبر من صفر."),
        54021 => ApiError.Create("bad_vat",
            "VAT cannot exceed the amount.", "الضريبة لا يمكن أن تتجاوز المبلغ."),
        54022 => ApiError.Create("bad_period",
            "The period must end after it starts.", "يجب أن تنتهي الفترة بعد بدايتها."),
        54023 => ApiError.Create("unknown_category",
            "Unknown expense category.", "تصنيف المصروف غير معروف."),
        _ => ApiError.Create("inventory_failed", fallback, "تعذّر إتمام العملية.")
    };
}
