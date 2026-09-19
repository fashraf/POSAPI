using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Localization;

namespace PosApi.Features.Catalog;

public sealed record CatalogItemDto(
    string ItemId,
    string Kind,
    string NameAr,
    string NameEn,
    string Name,
    string? Sku,
    string? Barcode,
    string? CategoryId,
    string? PrintGroupId,
    long PriceH,
    long CostH,
    bool TracksStock,
    decimal Quantity,
    int ReorderLevel,
    bool RequiresPreparation,
    bool IsActive);

public static class CatalogEndpoints
{
    public static void MapCatalogEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/catalog")
            .WithTags("Catalog")
            .RequireAuthorization();

        group.MapGet("/items", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("products.view"));

        group.MapGet("/categories", CategoriesAsync)
             .RequireAuthorization(PermissionPolicy.For("products.view"));

        group.MapGet("/print-groups", PrintGroupsAsync)
             .RequireAuthorization(PermissionPolicy.For("products.view"));
    }

    /// <summary>
    /// The POS product grid.
    ///
    /// Stock is joined per branch, because a product exists once for the
    /// business but its quantity is physical and belongs where the shelf is.
    /// </summary>
    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db,
        ILanguageContext language,
        string? search,
        string? categoryId,
        string? kind,
        string? branchId,
        bool? activeOnly,
        int page = 1,
        int pageSize = 25,
        CancellationToken ct = default)
    {
        var paging = new PageQuery { Page = page <= 0 ? 1 : page, PageSize = pageSize };

        await using var connection = db.Create();

        // Parameterised throughout. The search term reaches SQL as a value, so
        // a customer named O'Brien is a name and not a syntax error.
        const string sql = """
            SELECT COUNT(*)
            FROM core.CatalogItem AS i
            WHERE (@Search IS NULL
                   OR i.NameAr  LIKE N'%' + @Search + N'%'
                   OR i.NameEn  LIKE N'%' + @Search + N'%'
                   OR i.Sku     = @Search
                   OR i.Barcode = @Search)
              AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
              AND (@Kind IS NULL OR i.Kind = @Kind)
              AND (@ActiveOnly = 0 OR i.IsActive = 1);

            SELECT
                i.ItemId, i.Kind, i.NameAr, i.NameEn, i.Sku, i.Barcode,
                i.CategoryId, i.PrintGroupId, i.PriceH, i.CostH,
                i.TracksStock, i.ReorderLevel, i.RequiresPreparation, i.IsActive,
                ISNULL(s.Quantity, 0) AS Quantity
            FROM core.CatalogItem AS i
            LEFT JOIN inv.StockLevel AS s
                   ON s.ItemId = i.ItemId AND s.BranchId = @BranchId
            WHERE (@Search IS NULL
                   OR i.NameAr  LIKE N'%' + @Search + N'%'
                   OR i.NameEn  LIKE N'%' + @Search + N'%'
                   OR i.Sku     = @Search
                   OR i.Barcode = @Search)
              AND (@CategoryId IS NULL OR i.CategoryId = @CategoryId)
              AND (@Kind IS NULL OR i.Kind = @Kind)
              AND (@ActiveOnly = 0 OR i.IsActive = 1)
            ORDER BY i.Kind, i.NameEn
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(sql,
            new
            {
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                CategoryId = categoryId,
                Kind = kind,
                BranchId = branchId,
                ActiveOnly = activeOnly ?? true,
                paging.Offset,
                paging.PageSize
            },
            cancellationToken: ct));

        var total = await multi.ReadSingleAsync<int>();
        var rows = (await multi.ReadAsync<ItemRow>()).ToList();

        var items = rows.Select(r => new CatalogItemDto(
            r.ItemId, r.Kind, r.NameAr, r.NameEn,
            language.Pick(r.NameAr, r.NameEn),
            r.Sku, r.Barcode, r.CategoryId, r.PrintGroupId,
            r.PriceH, r.CostH, r.TracksStock, r.Quantity,
            r.ReorderLevel, r.RequiresPreparation, r.IsActive)).ToList();

        return Results.Ok(new PagedResult<CatalogItemDto>
        {
            Items = items,
            Page = paging.Page,
            PageSize = paging.PageSize,
            TotalCount = total
        });
    }

    private static async Task<IResult> CategoriesAsync(
        ISqlConnectionFactory db, ILanguageContext language, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync<NamedRow>(new CommandDefinition(
            "SELECT CategoryId AS Id, NameAr, NameEn, SortOrder FROM core.Category WHERE IsActive = 1 ORDER BY SortOrder;",
            cancellationToken: ct));

        return Results.Ok(rows.Select(r => new
        {
            id = r.Id,
            nameAr = r.NameAr,
            nameEn = r.NameEn,
            name = language.Pick(r.NameAr, r.NameEn)
        }));
    }

    private static async Task<IResult> PrintGroupsAsync(
        ISqlConnectionFactory db, ILanguageContext language, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync<NamedRow>(new CommandDefinition(
            "SELECT PrintGroupId AS Id, NameAr, NameEn, SortOrder FROM core.PrintGroup WHERE IsActive = 1 ORDER BY SortOrder;",
            cancellationToken: ct));

        return Results.Ok(rows.Select(r => new
        {
            id = r.Id,
            nameAr = r.NameAr,
            nameEn = r.NameEn,
            name = language.Pick(r.NameAr, r.NameEn)
        }));
    }

    private sealed record ItemRow
    {
        public string ItemId { get; init; } = string.Empty;
        public string Kind { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? Sku { get; init; }
        public string? Barcode { get; init; }
        public string? CategoryId { get; init; }
        public string? PrintGroupId { get; init; }
        public long PriceH { get; init; }
        public long CostH { get; init; }
        public bool TracksStock { get; init; }
        public decimal Quantity { get; init; }
        public int ReorderLevel { get; init; }
        public bool RequiresPreparation { get; init; }
        public bool IsActive { get; init; }
    }

    private sealed record NamedRow
    {
        public string Id { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public int SortOrder { get; init; }
    }
}
