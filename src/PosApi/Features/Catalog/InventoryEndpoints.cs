using Dapper;
using Npgsql;
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
    IReadOnlyList<PurchaseLineInput> Lines,
    string? Note = null);

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

        /* Vendors and the purchase list: VendorEndpoints. */
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
            SELECT COUNT(*)::int
            FROM core.CatalogItem AS i
            LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId
            WHERE i.TracksStock AND i.IsActive
              AND (@Search IS NULL OR i.NameAr COLLATE "default" ILIKE '%' || @Search || '%'
                                   OR i.NameEn COLLATE "default" ILIKE '%' || @Search || '%')
              AND (NOT @LowOnly OR COALESCE(s.Quantity, 0) <= i.ReorderLevel);

            SELECT
                i.ItemId, i.NameAr, i.NameEn, i.Sku, i.CategoryId,
                i.CostH, i.PriceH, i.ReorderLevel,
                COALESCE(s.Quantity, 0) AS Quantity,
                trunc(COALESCE(s.Quantity, 0) * i.CostH)::bigint AS StockValueH,
                CASE WHEN COALESCE(s.Quantity, 0) <= 0 THEN 'out'
                     WHEN COALESCE(s.Quantity, 0) <= i.ReorderLevel THEN 'low'
                     ELSE 'ok' END AS StockStatus
            FROM core.CatalogItem AS i
            LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId
            WHERE i.TracksStock AND i.IsActive
              AND (@Search IS NULL OR i.NameAr COLLATE "default" ILIKE '%' || @Search || '%'
                                   OR i.NameEn COLLATE "default" ILIKE '%' || @Search || '%')
              AND (NOT @LowOnly OR COALESCE(s.Quantity, 0) <= i.ReorderLevel)
            ORDER BY i.NameEn
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;

        await using var multi = await connection.QueryMultipleNamedAsync(new CommandDefinition(sql,
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
        var rows = (await multi.ReadRowsAsync()).ToList();

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

        var rows = await connection.QueryRowsAsync(new CommandDefinition(
            """
            SELECT
                MovementId, ItemId, BranchId, MovementType, Quantity, BalanceAfter,
                UnitCostH, Reference, ReasonAr, ReasonEn, OccurredAtUtc, Actor
            FROM inv.StockMovement
            WHERE ItemId = @ItemId
              AND (@BranchId IS NULL OR BranchId = @BranchId OR BranchId IS NULL)
            ORDER BY OccurredAtUtc DESC
            LIMIT @Take;
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

        await using var connection = db.Create();

        string purchaseId, reference;

        try
        {
            (purchaseId, reference) = await connection.QuerySingleAsync<(string, string)>(new CommandDefinition(
                """
                SELECT PurchaseId, Reference FROM inv.usp_ReceivePurchase(
                    p_VendorId => @VendorId, p_BranchId => @BranchId,
                    p_InvoiceNumber => @InvoiceNumber, p_VatRate => @VatRate,
                    p_PaidOnReceipt => @PaidOnReceipt, p_ReceivedBy => @ReceivedBy,
                    p_Note => @Note, p_Lines => @Lines::jsonb);
                """,
                new
                {
                    request.VendorId,
                    request.BranchId,
                    request.InvoiceNumber,
                    VatRate = request.VatRate <= 0 ? 15.00m : request.VatRate,
                    request.PaidOnReceipt,
                    ReceivedBy = current.Username,
                    Note = ProcErrors.Blank(request.Note),
                    Lines = DbList.Json(request.Lines.Select(l => new { l.ItemId, l.Quantity, l.UnitCostH }))
                },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 54000 && ex.ErrorNumber() < 55000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new
        {
            purchaseId,
            reference
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
                """
                SELECT inv.usp_AdjustStock(
                    p_ItemId => @ItemId, p_BranchId => @BranchId, p_NewQuantity => @NewQuantity,
                    p_ReasonEn => @ReasonEn, p_ReasonAr => @ReasonAr, p_Actor => @Actor);
                """,
                new
                {
                    ItemId = itemId,
                    request.BranchId,
                    request.NewQuantity,
                    request.ReasonEn,
                    request.ReasonAr,
                    Actor = current.Username
                },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 54000 && ex.ErrorNumber() < 55000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.NoContent();
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
