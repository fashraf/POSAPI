using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Localization;

namespace PosApi.Features.Sales;

/// <summary>
/// A configured discount, in the discount screen's own names.
///
/// <c>Value</c> is basis points of a percent for a percentage (1000 = 10%) and
/// halalas for a fixed amount. Zero in <c>MaxAmountH</c> or
/// <c>RequiresApprovalAboveH</c> means "none", as the screen treats it.
/// </summary>
public sealed record DiscountDto(
    string Id,
    string NameAr,
    string NameEn,
    string Name,
    string Description,
    string Type,
    int Value,
    long MaxAmountH,
    long MinOrderH,
    string Applicability,
    IReadOnlyList<string> AppliesToIds,
    IReadOnlyList<string> BranchIds,
    IReadOnlyList<string> AllowedRoleIds,
    long RequiresApprovalAboveH,
    bool IsAutomatic,
    bool AllowStacking,
    IReadOnlyList<int> ActiveDays,
    DateOnly? StartsAt,
    DateOnly? EndsAt,
    string Status,
    int UsageCount,
    DateTime CreatedAt,
    DateTime UpdatedAt);

/// <summary>
/// Create or edit a discount. Dates are calendar days: send "YYYY-MM-DD". A
/// full timestamp is accepted, and its date part as sent is used.
/// </summary>
public sealed record SaveDiscountRequest(
    string NameAr,
    string NameEn,
    string? Description,
    string Type,
    int Value,
    long MaxAmountH,
    long MinOrderH,
    string? Applicability,
    IReadOnlyList<string>? AppliesToIds,
    IReadOnlyList<string>? BranchIds,
    IReadOnlyList<string>? AllowedRoleIds,
    long RequiresApprovalAboveH,
    bool IsAutomatic,
    bool AllowStacking,
    IReadOnlyList<int>? ActiveDays,
    DateTime? StartsAt,
    DateTime? EndsAt,
    string? Status);

public static class DiscountEndpoints
{
    public static void MapDiscountEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/discounts")
            .WithTags("Discounts")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("discounts.view"));

        group.MapGet("/applicable", ApplicableAsync)
             .RequireAuthorization(PermissionPolicy.For("pos.apply_discount"));

        group.MapGet("/{discountId}", GetAsync)
             .RequireAuthorization(PermissionPolicy.For("discounts.view"));

        group.MapPost("", CreateAsync)
             .RequireAuthorization(PermissionPolicy.For("discounts.create"));

        group.MapPut("/{discountId}", UpdateAsync)
             .RequireAuthorization(PermissionPolicy.For("discounts.edit"));

        group.MapDelete("/{discountId}", DeleteAsync)
             .RequireAuthorization(PermissionPolicy.For("discounts.delete"));
    }

    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, ILanguageContext language, CancellationToken ct)
    {
        await using var connection = db.Create();
        return Results.Ok(await LoadAsync(connection, null, language, ct));
    }

    private static async Task<IResult> GetAsync(
        string discountId, ISqlConnectionFactory db, ILanguageContext language, CancellationToken ct)
    {
        await using var connection = db.Create();

        var discount = (await LoadAsync(connection, discountId, language, ct)).SingleOrDefault();

        return discount is null ? NotFound() : Results.Ok(discount);
    }

    private static Task<IResult> CreateAsync(
        SaveDiscountRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveAsync(null, request, db, current, language, http, logger, ct);

    private static Task<IResult> UpdateAsync(
        string discountId, SaveDiscountRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveAsync(discountId, request, db, current, language, http, logger, ct);

    /// <summary>
    /// Through sales.usp_SaveDiscount, which saves the discount and its item,
    /// category, branch and role sets together. Usage count is never written
    /// here: sales.usp_CommitSale increments it when a sale carrying the
    /// discount commits, so there is no separate "record usage" call.
    /// </summary>
    private static async Task<IResult> SaveAsync(
        string? discountId,
        SaveDiscountRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (request.Status is not (null or "active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        var days = (request.ActiveDays ?? []).Distinct().Order().ToList();
        if (days.Any(d => d is < 0 or > 6))
            return ProcErrors.Field("activeDays", "Days of the week are 0 (Sunday) to 6.", "أيام الأسبوع من ٠ (الأحد) إلى ٦.");

        var parameters = new DynamicParameters();
        parameters.Add("@DiscountId", discountId);
        parameters.Add("@NameAr", request.NameAr?.Trim());
        parameters.Add("@NameEn", request.NameEn?.Trim());
        parameters.Add("@Description", ProcErrors.Blank(request.Description));
        parameters.Add("@DiscountType", request.Type);
        parameters.Add("@Value", request.Value);
        /* Zero is "no cap" and "never needs approval" on the screen; stored, that is NULL. */
        parameters.Add("@MaxDiscountH", request.MaxAmountH == 0 ? null : request.MaxAmountH);
        parameters.Add("@MinSubtotalH", request.MinOrderH);
        parameters.Add("@ApprovalAboveH", request.RequiresApprovalAboveH == 0 ? null : request.RequiresApprovalAboveH);
        parameters.Add("@AppliesTo", request.Applicability ?? "all");
        parameters.Add("@AppliesToIds", ProcErrors.Csv(request.AppliesToIds));
        parameters.Add("@BranchIds", ProcErrors.Csv(request.BranchIds));
        parameters.Add("@RoleIds", ProcErrors.Csv(request.AllowedRoleIds));
        parameters.Add("@IsAutomatic", request.IsAutomatic);
        parameters.Add("@AllowStacking", request.AllowStacking);
        parameters.Add("@ActiveDays", string.Join(',', days));
        parameters.Add("@StartsOn", request.StartsAt is { } s ? DateOnly.FromDateTime(s) : (DateOnly?)null);
        parameters.Add("@EndsOn", request.EndsAt is { } e ? DateOnly.FromDateTime(e) : (DateOnly?)null);
        parameters.Add("@IsActive", request.Status != "inactive");
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "sales.usp_SaveDiscount", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapError(ex, request) is { } mapped)
        {
            return mapped;
        }

        var savedId = parameters.Get<string>("@SavedId");

        logger.LogInformation("Discount {DiscountId} {Action} by {Actor}.",
            savedId, discountId is null ? "created" : "updated", current.Username);
        http.Items["AuditEntityId"] = savedId;

        var discount = (await LoadAsync(connection, savedId, language, ct)).Single();

        return discountId is null
            ? Results.Created($"/api/discounts/{savedId}", discount)
            : Results.Ok(discount);
    }

    /// <summary>
    /// Delete a discount that was never used. One applied to a sale is named
    /// by that sale, so it is refused with 409 — deactivate it instead
    /// (PATCH /api/activation/discount/{id}).
    /// </summary>
    private static async Task<IResult> DeleteAsync(
        string discountId, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct)
    {
        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "sales.usp_DeleteDiscount", new { DiscountId = discountId },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapError(ex, null) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Discount {DiscountId} deleted by {Actor}.", discountId, current.Username);
        http.Items["AuditEntityId"] = discountId;

        return Results.NoContent();
    }

    private static IResult NotFound() =>
        ProcErrors.NotFound("No such discount.", "لا يوجد خصم بهذا المعرف.");

    private static IResult? MapError(SqlException ex, SaveDiscountRequest? request) => ex.Number switch
    {
        63015 => NotFound(),
        63016 => ProcErrors.Conflict("discount_in_use",
            "This discount has been used on real sales. Deactivate it instead so the history stays intact.",
            "استُخدم هذا الخصم في مبيعات فعلية. عطّله بدلًا من حذفه ليبقى السجل سليمًا."),
        63000 => ProcErrors.Field(string.IsNullOrWhiteSpace(request?.NameAr) ? "nameAr" : "nameEn",
            "Both names are required.", "الاسمان العربي والإنجليزي مطلوبان."),
        63014 => ProcErrors.Field("nameEn", "Another discount already uses this name.", "يوجد خصم آخر بهذا الاسم."),
        63001 => ProcErrors.Field("type", "A discount is either a percentage or a fixed amount.", "الخصم إما نسبة أو مبلغ ثابت."),
        63002 => ProcErrors.Field("value", "Enter a value above zero, or the discount does nothing.", "أدخل قيمة أكبر من صفر."),
        63003 => ProcErrors.Field("value", "A percentage discount cannot exceed 100%.", "لا يمكن أن تتجاوز نسبة الخصم ١٠٠٪."),
        63004 => ProcErrors.Field("maxAmountH", "A maximum cannot be negative.", "لا يمكن أن يكون الحد الأعلى سالبًا."),
        63005 => ProcErrors.Field("minOrderH", "A minimum cannot be negative.", "لا يمكن أن يكون الحد الأدنى سالبًا."),
        63006 => ProcErrors.Field("requiresApprovalAboveH", "An approval threshold cannot be negative.", "لا يمكن أن يكون حد الموافقة سالبًا."),
        63007 => ProcErrors.Field("endsAt", "The end date cannot be before the start date.", "لا يمكن أن يسبق تاريخ الانتهاء تاريخ البدء."),
        63008 => ProcErrors.Field("applicability", "Applies to all, products, services or selected.", "ينطبق على الكل أو المنتجات أو الخدمات أو المحدد."),
        63009 => ProcErrors.Field("appliesToIds",
            "Choose at least one item or category, or switch to \"All\".", "اختر صنفًا أو تصنيفًا واحدًا على الأقل، أو اختر \"الكل\"."),
        63010 => ProcErrors.Field("appliesToIds", "One of those items or categories does not exist.", "أحد هذه الأصناف أو التصنيفات غير موجود."),
        63011 => ProcErrors.Field("branchIds", "One of those branches does not exist.", "أحد هذه الفروع غير موجود."),
        63012 => ProcErrors.Field("allowedRoleIds", "One of those roles does not exist.", "أحد هذه الأدوار غير موجود."),
        63013 => ProcErrors.Field("activeDays", "Days of the week are 0 (Sunday) to 6.", "أيام الأسبوع من ٠ (الأحد) إلى ٦."),
        63017 => ProcErrors.Field("maxAmountH",
            "The maximum is below the discount itself, so it would always be clipped. Raise it or remove it.",
            "الحد الأعلى أقل من قيمة الخصم نفسها. ارفعه أو احذفه."),
        _ => null
    };

    private static async Task<List<DiscountDto>> LoadAsync(
        SqlConnection connection, string? discountId, ILanguageContext language, CancellationToken ct)
    {
        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT DiscountId, NameAr, NameEn, Description, DiscountType, Value, MaxDiscountH,
                   MinSubtotalH, ApprovalAboveH, AppliesTo, IsAutomatic, AllowStacking,
                   ActiveDays, StartsOn, EndsOn, UsageCount, IsActive, CreatedAtUtc, UpdatedAtUtc
            FROM sales.Discount
            WHERE @DiscountId IS NULL OR DiscountId = @DiscountId
            ORDER BY NameEn;

            SELECT DiscountId, ScopeType, ScopeKey FROM sales.DiscountScope
            WHERE @DiscountId IS NULL OR DiscountId = @DiscountId;
            """,
            new { DiscountId = discountId }, cancellationToken: ct));

        var rows = (await multi.ReadAsync<DiscountRow>()).ToList();
        var scopes = (await multi.ReadAsync<(string DiscountId, string ScopeType, string ScopeKey)>())
            .ToLookup(s => s.DiscountId);

        List<string> Keys(string id, params string[] types) =>
            scopes[id].Where(s => types.Contains(s.ScopeType)).Select(s => s.ScopeKey).Order().ToList();

        return rows.Select(r => new DiscountDto(
            r.DiscountId, r.NameAr, r.NameEn, language.Pick(r.NameAr, r.NameEn),
            r.Description ?? string.Empty, r.DiscountType, r.Value,
            r.MaxDiscountH ?? 0, r.MinSubtotalH,
            /* 'item' and 'category' predate 'selected'; the screen knows them as selected. */
            r.AppliesTo is "item" or "category" ? "selected" : r.AppliesTo,
            Keys(r.DiscountId, "item", "category"),
            Keys(r.DiscountId, "branch"),
            Keys(r.DiscountId, "role"),
            r.ApprovalAboveH ?? 0, r.IsAutomatic, r.AllowStacking,
            (r.ActiveDays ?? string.Empty).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(d => int.TryParse(d, out var n) ? n : -1).Where(n => n >= 0).ToList(),
            r.StartsOn, r.EndsOn,
            r.IsActive ? "active" : "inactive",
            r.UsageCount, r.CreatedAtUtc, r.UpdatedAtUtc)).ToList();
    }

    /// <summary>
    /// Discounts that could apply right now.
    ///
    /// Day-of-week and date windows are filtered here so the till never offers
    /// something that will be refused at commit. Note that `isAutomatic` is
    /// returned rather than acted on: only a discount flagged automatic may
    /// apply itself, and everything else waits to be chosen.
    /// </summary>
    /// <remarks>
    /// Returns <see cref="DiscountDto"/>s (the same shape as GET
    /// /api/discounts), automatic ones first. Filtered by: active; today
    /// (UTC) inside startsAt..endsAt; today's weekday in activeDays (empty =
    /// every day); minOrderH ≤ <c>subtotalH</c>; the branch scope — a discount
    /// with branchIds applies only at those branches, checked against
    /// <c>branchId</c> when it is given; and the role scope — a discount with
    /// allowedRoleIds is offered only to a caller holding one of those roles.
    /// </remarks>
    private static async Task<IResult> ApplicableAsync(
        ISqlConnectionFactory db, ICurrentUser current, ILanguageContext language,
        string? branchId, long subtotalH = 0, CancellationToken ct = default)
    {
        var branch = ProcErrors.Blank(branchId);
        if (!current.CanSeeBranch(branch)) return Results.Forbid();

        await using var connection = db.Create();

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var dayOfWeek = (int)today.DayOfWeek;   // 0 = Sunday, as activeDays counts

        var applicable = (await LoadAsync(connection, null, language, ct))
            .Where(d => d.Status == "active")
            .Where(d => d.StartsAt is null || d.StartsAt <= today)
            .Where(d => d.EndsAt is null || d.EndsAt >= today)
            .Where(d => d.ActiveDays.Count == 0 || d.ActiveDays.Contains(dayOfWeek))
            .Where(d => d.MinOrderH <= subtotalH)
            .Where(d => d.BranchIds.Count == 0 || branch is null
                        || d.BranchIds.Contains(branch, StringComparer.OrdinalIgnoreCase))
            .Where(d => d.AllowedRoleIds.Count == 0
                        || d.AllowedRoleIds.Contains(current.RoleId, StringComparer.OrdinalIgnoreCase))
            .OrderByDescending(d => d.IsAutomatic)
            .ThenBy(d => d.NameEn, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return Results.Ok(applicable);
    }

    private sealed record DiscountRow
    {
        public string DiscountId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? Description { get; init; }
        public string DiscountType { get; init; } = string.Empty;
        public int Value { get; init; }
        public long? MaxDiscountH { get; init; }
        public long MinSubtotalH { get; init; }
        public long? ApprovalAboveH { get; init; }
        public string AppliesTo { get; init; } = "all";
        public bool IsAutomatic { get; init; }
        public bool AllowStacking { get; init; }
        public string? ActiveDays { get; init; }
        public DateOnly? StartsOn { get; init; }
        public DateOnly? EndsOn { get; init; }
        public int UsageCount { get; init; }
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
    }
}
