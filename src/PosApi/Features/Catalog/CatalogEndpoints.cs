using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
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
    string? DescriptionAr,
    string? DescriptionEn,
    string? Sku,
    string? Barcode,
    string? CategoryId,
    string? VendorId,
    string? PrintGroupId,
    long PriceH,
    long CostH,
    bool TracksStock,
    decimal Quantity,
    int ReorderLevel,
    bool RequiresPreparation,
    bool IsActive);

/// <summary>
/// Create or edit a catalog item.
///
/// Cost is accepted on create only. After that it is the weighted average
/// maintained by receiving, and the procedure ignores it on edit.
/// </summary>
public sealed record SaveCatalogItemRequest(
    string Kind,
    string NameAr,
    string NameEn,
    string? DescriptionAr,
    string? DescriptionEn,
    string? Sku,
    string? Barcode,
    string? CategoryId,
    string? VendorId,
    string? PrintGroupId,
    long PriceH,
    long CostH,
    bool TracksStock,
    int ReorderLevel,
    bool RequiresPreparation,
    bool IsActive);

/// <summary>
/// A category. <c>id</c>, <c>nameAr</c>, <c>nameEn</c> and <c>name</c> are the
/// fields this route always returned; the rest were added for the catalog
/// screen's category manager.
/// </summary>
public sealed record CategoryDto(
    string Id,
    string NameAr,
    string NameEn,
    string Name,
    string AppliesTo,
    int SortOrder,
    string Status,
    int ItemCount,
    DateTime CreatedAt,
    DateTime UpdatedAt);

/// <summary>Create or edit a category. A null sort order goes after the last one (or keeps its place).</summary>
public sealed record SaveCategoryRequest(
    string NameAr,
    string NameEn,
    string? AppliesTo,
    int? SortOrder,
    string? Status);

public sealed record PrintGroupDto(
    string Id,
    string NameAr,
    string NameEn,
    string Name,
    string TicketTitle,
    int SortOrder,
    string Status,
    int ItemCount,
    DateTime CreatedAt,
    DateTime UpdatedAt);

/// <summary>Create or edit a print group. A blank ticket title prints the English name.</summary>
public sealed record SavePrintGroupRequest(
    string NameAr,
    string NameEn,
    string? TicketTitle,
    int? SortOrder,
    string? Status);

public static class CatalogEndpoints
{
    public static void MapCatalogEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/catalog")
            .WithTags("Catalog")
            .RequireAuthorization();

        group.MapGet("/items", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("products.view"));

        group.MapGet("/items/{itemId}", GetAsync)
             .RequireAuthorization(PermissionPolicy.For("products.view"));

        group.MapPost("/items", CreateAsync)
             .RequireAuthorization(PermissionPolicy.For("products.create"))
             .RequireRateLimiting("standard");

        group.MapPut("/items/{itemId}", UpdateAsync)
             .RequireAuthorization(PermissionPolicy.For("products.edit"))
             .RequireRateLimiting("standard");

        group.MapGet("/categories", CategoriesAsync)
             .RequireAuthorization(PermissionPolicy.For("products.view"));

        group.MapGet("/categories/usage", CategoryUsageAsync)
             .RequireAuthorization(PermissionPolicy.For("products.view"));

        group.MapPost("/categories", CreateCategoryAsync)
             .RequireAuthorization(PermissionPolicy.For("products.create"))
             .RequireRateLimiting("standard");

        group.MapPut("/categories/{categoryId}", UpdateCategoryAsync)
             .RequireAuthorization(PermissionPolicy.For("products.edit"))
             .RequireRateLimiting("standard");

        group.MapGet("/print-groups", PrintGroupsAsync)
             .RequireAuthorization(PermissionPolicy.For("products.view"));

        group.MapPost("/print-groups", CreatePrintGroupAsync)
             .RequireAuthorization(PermissionPolicy.For("products.create"))
             .RequireRateLimiting("standard");

        group.MapPut("/print-groups/{printGroupId}", UpdatePrintGroupAsync)
             .RequireAuthorization(PermissionPolicy.For("products.edit"))
             .RequireRateLimiting("standard");
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
        string? status,
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
              AND (@Status IS NOT NULL OR @ActiveOnly = 0 OR i.IsActive = 1)
              AND (@Status IS NULL OR i.IsActive = CASE WHEN @Status = N'active' THEN 1 ELSE 0 END);

            SELECT
                i.ItemId, i.Kind, i.NameAr, i.NameEn, i.DescriptionAr, i.DescriptionEn,
                i.Sku, i.Barcode, i.CategoryId, i.VendorId, i.PrintGroupId, i.PriceH, i.CostH,
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
              AND (@Status IS NOT NULL OR @ActiveOnly = 0 OR i.IsActive = 1)
              AND (@Status IS NULL OR i.IsActive = CASE WHEN @Status = N'active' THEN 1 ELSE 0 END)
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
                // An explicit status filter ("active" or "inactive") wins over
                // activeOnly, which the POS grid relies on defaulting to true.
                Status = status is "active" or "inactive" ? status : null,
                paging.Offset,
                paging.PageSize
            },
            cancellationToken: ct));

        var total = await multi.ReadSingleAsync<int>();
        var rows = (await multi.ReadAsync<ItemRow>()).ToList();

        var items = rows.Select(r => ToDto(r, language)).ToList();

        return Results.Ok(new PagedResult<CatalogItemDto>
        {
            Items = items,
            Page = paging.Page,
            PageSize = paging.PageSize,
            TotalCount = total
        });
    }

    /// <summary>
    /// One item by id.
    ///
    /// The list's search matches names, SKU and barcode, never the id, so
    /// fetching one item through it returned whichever row happened to be first.
    /// </summary>
    private static async Task<IResult> GetAsync(
        string itemId,
        ISqlConnectionFactory db,
        ILanguageContext language,
        string? branchId,
        CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var row = await LoadAsync(connection, itemId, branchId, ct);

        return row is null
            ? Results.NotFound(ApiError.Create("not_found", "No such item.", "لا يوجد صنف بهذا المعرف."))
            : Results.Ok(ToDto(row, language));
    }

    private static Task<IResult> CreateAsync(
        SaveCatalogItemRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        string? branchId,
        CancellationToken ct = default) =>
        SaveAsync(null, request, db, current, language, http, logger, branchId, ct);

    private static Task<IResult> UpdateAsync(
        string itemId,
        SaveCatalogItemRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        string? branchId,
        CancellationToken ct = default) =>
        SaveAsync(itemId, request, db, current, language, http, logger, branchId, ct);

    /// <summary>
    /// Both create and edit go through core.usp_SaveCatalogItem, so the
    /// uniqueness and price rules live in one place. The saved row is read back
    /// and returned, so the screen shows what the database holds rather than
    /// what was sent.
    /// </summary>
    private static async Task<IResult> SaveAsync(
        string? itemId,
        SaveCatalogItemRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        string? branchId,
        CancellationToken ct)
    {
        if (request.Kind is not ("product" or "service"))
        {
            return Results.BadRequest(ApiError.Create(
                "invalid_kind", "An item is either a product or a service.",
                "الصنف إما منتج أو خدمة.",
                new Dictionary<string, string[]> { ["kind"] = ["Choose product or service."] }));
        }

        var parameters = new DynamicParameters();
        parameters.Add("@ItemId", itemId);
        parameters.Add("@Kind", request.Kind);
        parameters.Add("@NameAr", request.NameAr?.Trim());
        parameters.Add("@NameEn", request.NameEn?.Trim());
        parameters.Add("@DescriptionAr", Blank(request.DescriptionAr));
        parameters.Add("@DescriptionEn", Blank(request.DescriptionEn));
        // An empty barcode or SKU is "none", not a value. Sent as '' it would
        // collide with every other item that has none and fail the uniqueness check.
        parameters.Add("@Sku", Blank(request.Sku));
        parameters.Add("@Barcode", Blank(request.Barcode));
        parameters.Add("@CategoryId", Blank(request.CategoryId));
        parameters.Add("@VendorId", Blank(request.VendorId));
        parameters.Add("@PrintGroupId", Blank(request.PrintGroupId));
        parameters.Add("@PriceH", request.PriceH);
        parameters.Add("@CostH", request.CostH);
        parameters.Add("@TracksStock", request.TracksStock);
        parameters.Add("@ReorderLevel", (decimal)request.ReorderLevel);
        parameters.Add("@RequiresPreparation", request.RequiresPreparation);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@SavedItemId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SaveCatalogItem",
                parameters,
                commandType: CommandType.StoredProcedure,
                cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number == 59005)
        {
            return Results.NotFound(ApiError.Create("not_found", "No such item.", "لا يوجد صنف بهذا المعرف."));
        }
        catch (SqlException ex) when (ex.Number is >= 59000 and < 59005)
        {
            var (field, messageEn, messageAr) = ex.Number switch
            {
                59000 => ("nameEn", "Both names are required.", "الاسمان العربي والإنجليزي مطلوبان."),
                59001 => ("priceH", "A price cannot be negative.", "لا يمكن أن يكون السعر سالبًا."),
                59002 => ("costH", "A cost cannot be negative.", "لا يمكن أن تكون التكلفة سالبة."),
                59003 => ("barcode", "That barcode is already used by another item.", "هذا الباركود مستخدم لصنف آخر."),
                _     => ("sku", "That SKU is already used by another item.", "رمز SKU هذا مستخدم لصنف آخر.")
            };

            return Results.UnprocessableEntity(ApiError.Create(
                "validation_failed", messageEn, messageAr,
                new Dictionary<string, string[]> { [field] = [messageEn] }));
        }

        var savedId = parameters.Get<string>("@SavedItemId");

        logger.LogInformation("Catalog item {ItemId} {Action} by {User}.",
            savedId, itemId is null ? "created" : "updated", current.Username);

        http.Items["AuditEntityId"] = savedId;

        var row = await LoadAsync(connection, savedId, branchId, ct);
        var dto = ToDto(row!, language);

        return itemId is null
            ? Results.Created($"/api/catalog/items/{savedId}", dto)
            : Results.Ok(dto);
    }

    private static Task<ItemRow?> LoadAsync(
        SqlConnection connection, string itemId, string? branchId, CancellationToken ct) =>
        connection.QuerySingleOrDefaultAsync<ItemRow>(new CommandDefinition(
            """
            SELECT
                i.ItemId, i.Kind, i.NameAr, i.NameEn, i.DescriptionAr, i.DescriptionEn,
                i.Sku, i.Barcode, i.CategoryId, i.VendorId, i.PrintGroupId, i.PriceH, i.CostH,
                i.TracksStock, i.ReorderLevel, i.RequiresPreparation, i.IsActive,
                ISNULL(s.Quantity, 0) AS Quantity
            FROM core.CatalogItem AS i
            LEFT JOIN inv.StockLevel AS s
                   ON s.ItemId = i.ItemId AND s.BranchId = @BranchId
            WHERE i.ItemId = @ItemId;
            """,
            new { ItemId = itemId, BranchId = branchId },
            cancellationToken: ct));

    private static CatalogItemDto ToDto(ItemRow r, ILanguageContext language) => new(
        r.ItemId, r.Kind, r.NameAr, r.NameEn,
        language.Pick(r.NameAr, r.NameEn),
        r.DescriptionAr, r.DescriptionEn,
        r.Sku, r.Barcode, r.CategoryId, r.VendorId, r.PrintGroupId,
        r.PriceH, r.CostH, r.TracksStock, r.Quantity,
        r.ReorderLevel, r.RequiresPreparation, r.IsActive);

    private static string? Blank(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    /// <summary>
    /// Categories, in rail order.
    ///
    /// Active only by default, because that is what the POS rail shows; the
    /// catalog screen passes includeInactive=true to manage the rest. Each
    /// carries its item count so the screen can say what a change affects.
    /// </summary>
    private static async Task<IResult> CategoriesAsync(
        ISqlConnectionFactory db, ILanguageContext language, bool? includeInactive, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await LoadCategoriesAsync(connection, null, includeInactive ?? false, ct);

        return Results.Ok(rows.Select(r => ToCategoryDto(r, language)));
    }

    /// <summary>How many catalog items point at each category: { "cat_food": 12, ... }.</summary>
    private static async Task<IResult> CategoryUsageAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync<(string CategoryId, int Count)>(new CommandDefinition(
            "SELECT CategoryId, COUNT(*) FROM core.CatalogItem WHERE CategoryId IS NOT NULL GROUP BY CategoryId;",
            cancellationToken: ct));

        return Results.Ok(rows.ToDictionary(r => r.CategoryId, r => r.Count));
    }

    private static Task<IResult> CreateCategoryAsync(
        SaveCategoryRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveCategoryAsync(null, request, db, current, language, http, logger, ct);

    private static Task<IResult> UpdateCategoryAsync(
        string categoryId, SaveCategoryRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveCategoryAsync(categoryId, request, db, current, language, http, logger, ct);

    /// <summary>
    /// Through core.usp_SaveCategory, which refuses to switch off a category
    /// that still holds active items — the same rule the activation toggle has.
    /// </summary>
    private static async Task<IResult> SaveCategoryAsync(
        string? categoryId,
        SaveCategoryRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (request.Status is not (null or "active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        var parameters = new DynamicParameters();
        parameters.Add("@CategoryId", categoryId);
        parameters.Add("@NameAr", request.NameAr?.Trim());
        parameters.Add("@NameEn", request.NameEn?.Trim());
        parameters.Add("@AppliesTo", request.AppliesTo ?? "both");
        parameters.Add("@SortOrder", request.SortOrder);
        parameters.Add("@IsActive", request.Status != "inactive");
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SaveCategory", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is >= 65000 and < 65010)
        {
            return ex.Number switch
            {
                65002 => ProcErrors.NotFound("No such category.", "لا يوجد تصنيف بهذا المعرف."),
                /* The message carries the item count, so it is passed through. */
                65003 => ProcErrors.Conflict("deactivation_blocked", ex.Message,
                    "ما زال هذا التصنيف يحتوي على أصناف نشطة. انقلها أو عطّلها أولًا."),
                65001 => ProcErrors.Field("appliesTo",
                    "A category holds products, services or both.", "التصنيف يضم منتجات أو خدمات أو كليهما."),
                _ => ProcErrors.Field(string.IsNullOrWhiteSpace(request.NameAr) ? "nameAr" : "nameEn",
                    "Both names are required.", "الاسمان العربي والإنجليزي مطلوبان.")
            };
        }

        var savedId = parameters.Get<string>("@SavedId");

        logger.LogInformation("Category {CategoryId} {Action} by {User}.",
            savedId, categoryId is null ? "created" : "updated", current.Username);
        http.Items["AuditEntityId"] = savedId;

        var dto = ToCategoryDto((await LoadCategoriesAsync(connection, savedId, true, ct)).Single(), language);

        return categoryId is null
            ? Results.Created($"/api/catalog/categories/{savedId}", dto)
            : Results.Ok(dto);
    }

    private static async Task<List<CategoryRow>> LoadCategoriesAsync(
        SqlConnection connection, string? categoryId, bool includeInactive, CancellationToken ct) =>
        (await connection.QueryAsync<CategoryRow>(new CommandDefinition(
            """
            SELECT c.CategoryId, c.NameAr, c.NameEn, c.AppliesTo, c.SortOrder, c.IsActive,
                   c.CreatedAtUtc, c.UpdatedAtUtc,
                   (SELECT COUNT(*) FROM core.CatalogItem AS i WHERE i.CategoryId = c.CategoryId) AS ItemCount
            FROM core.Category AS c
            WHERE (@CategoryId IS NULL OR c.CategoryId = @CategoryId)
              AND (@IncludeInactive = 1 OR c.IsActive = 1)
            ORDER BY c.SortOrder, c.NameEn;
            """,
            new { CategoryId = categoryId, IncludeInactive = includeInactive },
            cancellationToken: ct))).ToList();

    private static CategoryDto ToCategoryDto(CategoryRow r, ILanguageContext language) => new(
        r.CategoryId, r.NameAr, r.NameEn, language.Pick(r.NameAr, r.NameEn),
        r.AppliesTo, r.SortOrder, r.IsActive ? "active" : "inactive", r.ItemCount,
        r.CreatedAtUtc, r.UpdatedAtUtc);

    /// <summary>
    /// Print groups, in ticket order. Active only by default — the item form
    /// should not offer a group whose tickets will not print.
    /// </summary>
    private static async Task<IResult> PrintGroupsAsync(
        ISqlConnectionFactory db, ILanguageContext language, bool? includeInactive, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await LoadPrintGroupsAsync(connection, null, includeInactive ?? false, ct);

        return Results.Ok(rows.Select(r => ToPrintGroupDto(r, language)));
    }

    private static Task<IResult> CreatePrintGroupAsync(
        SavePrintGroupRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SavePrintGroupAsync(null, request, db, current, language, http, logger, ct);

    private static Task<IResult> UpdatePrintGroupAsync(
        string printGroupId, SavePrintGroupRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SavePrintGroupAsync(printGroupId, request, db, current, language, http, logger, ct);

    private static async Task<IResult> SavePrintGroupAsync(
        string? printGroupId,
        SavePrintGroupRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (request.Status is not (null or "active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        var parameters = new DynamicParameters();
        parameters.Add("@PrintGroupId", printGroupId);
        parameters.Add("@NameAr", request.NameAr?.Trim());
        parameters.Add("@NameEn", request.NameEn?.Trim());
        parameters.Add("@TicketTitle", Blank(request.TicketTitle));
        parameters.Add("@SortOrder", request.SortOrder);
        parameters.Add("@IsActive", request.Status != "inactive");
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SavePrintGroup", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is >= 65010 and < 65020)
        {
            return ex.Number switch
            {
                65011 => ProcErrors.NotFound("No such print group.", "لا توجد مجموعة طباعة بهذا المعرف."),
                65012 => ProcErrors.Conflict("deactivation_blocked",
                    "This print group is still used by active items. Reassign them first, or their tickets will not print.",
                    "ما زالت أصناف نشطة تستخدم مجموعة الطباعة هذه. انقلها أولًا وإلا فلن تُطبع تذاكرها."),
                _ => ProcErrors.Field(string.IsNullOrWhiteSpace(request.NameAr) ? "nameAr" : "nameEn",
                    "Both names are required.", "الاسمان العربي والإنجليزي مطلوبان.")
            };
        }

        var savedId = parameters.Get<string>("@SavedId");

        logger.LogInformation("Print group {PrintGroupId} {Action} by {User}.",
            savedId, printGroupId is null ? "created" : "updated", current.Username);
        http.Items["AuditEntityId"] = savedId;

        var dto = ToPrintGroupDto((await LoadPrintGroupsAsync(connection, savedId, true, ct)).Single(), language);

        return printGroupId is null
            ? Results.Created($"/api/catalog/print-groups/{savedId}", dto)
            : Results.Ok(dto);
    }

    private static async Task<List<PrintGroupRow>> LoadPrintGroupsAsync(
        SqlConnection connection, string? printGroupId, bool includeInactive, CancellationToken ct) =>
        (await connection.QueryAsync<PrintGroupRow>(new CommandDefinition(
            """
            SELECT g.PrintGroupId, g.NameAr, g.NameEn, g.TicketTitle, g.SortOrder, g.IsActive,
                   g.CreatedAtUtc, g.UpdatedAtUtc,
                   (SELECT COUNT(*) FROM core.CatalogItem AS i WHERE i.PrintGroupId = g.PrintGroupId) AS ItemCount
            FROM core.PrintGroup AS g
            WHERE (@PrintGroupId IS NULL OR g.PrintGroupId = @PrintGroupId)
              AND (@IncludeInactive = 1 OR g.IsActive = 1)
            ORDER BY g.SortOrder, g.NameEn;
            """,
            new { PrintGroupId = printGroupId, IncludeInactive = includeInactive },
            cancellationToken: ct))).ToList();

    private static PrintGroupDto ToPrintGroupDto(PrintGroupRow r, ILanguageContext language) => new(
        r.PrintGroupId, r.NameAr, r.NameEn, language.Pick(r.NameAr, r.NameEn), r.TicketTitle,
        r.SortOrder, r.IsActive ? "active" : "inactive", r.ItemCount, r.CreatedAtUtc, r.UpdatedAtUtc);

    private sealed record ItemRow
    {
        public string ItemId { get; init; } = string.Empty;
        public string Kind { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? DescriptionAr { get; init; }
        public string? DescriptionEn { get; init; }
        public string? Sku { get; init; }
        public string? Barcode { get; init; }
        public string? CategoryId { get; init; }
        public string? VendorId { get; init; }
        public string? PrintGroupId { get; init; }
        public long PriceH { get; init; }
        public long CostH { get; init; }
        public bool TracksStock { get; init; }
        public decimal Quantity { get; init; }
        public int ReorderLevel { get; init; }
        public bool RequiresPreparation { get; init; }
        public bool IsActive { get; init; }
    }

    private sealed record CategoryRow
    {
        public string CategoryId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string AppliesTo { get; init; } = "both";
        public int SortOrder { get; init; }
        public bool IsActive { get; init; }
        public int ItemCount { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
    }

    private sealed record PrintGroupRow
    {
        public string PrintGroupId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string TicketTitle { get; init; } = string.Empty;
        public int SortOrder { get; init; }
        public bool IsActive { get; init; }
        public int ItemCount { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
    }
}
