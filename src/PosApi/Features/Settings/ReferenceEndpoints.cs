using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Settings;

/// <summary>
/// Branch settings, in the settings screen's own names. <c>CreatedAt</c> is
/// the branch's; settings have no creation date of their own.
/// </summary>
public sealed record BranchSettingsDto(
    string BranchId,
    bool Configured,
    string DefaultCustomerMode,
    string ServedBy,
    bool AllowNegativeStock,
    string? DefaultBillTemplateId,
    bool AutoPrintCustomerBill,
    bool AutoPrintGroupTickets,
    decimal VatRatePercent,
    bool PricesIncludeVat,
    DateTime CreatedAt,
    DateTime UpdatedAt,
    string? UpdatedBy);

public sealed record SaveBranchSettingsRequest(
    string DefaultCustomerMode,
    string ServedBy,
    bool AllowNegativeStock,
    string? DefaultBillTemplateId,
    bool AutoPrintCustomerBill,
    bool AutoPrintGroupTickets,
    decimal VatRatePercent,
    bool PricesIncludeVat);

public sealed record CopyBranchSettingsRequest(string SourceBranchId);

/// <summary>
/// The lookups the app needs on load: branches, settings, languages.
/// </summary>
public static class ReferenceEndpoints
{
    public static void MapReferenceEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api")
            .WithTags("Reference")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/branches", BranchesAsync);
        group.MapGet("/branches/{branchId}/settings", SettingsAsync);
        group.MapPut("/branches/{branchId}/settings", SaveSettingsAsync)
             .RequireAuthorization(PermissionPolicy.For("settings.edit"));
        group.MapPost("/branches/{branchId}/settings/copy", CopySettingsAsync)
             .RequireAuthorization(PermissionPolicy.For("settings.edit"));
        group.MapGet("/languages", LanguagesAsync).AllowAnonymous();
    }

    /// <summary>
    /// Only the branches this person works at. Filtering here rather than in the
    /// client means a branch they cannot use never reaches the browser.
    /// </summary>
    /// <remarks>
    /// <c>all=true</c> returns every active branch instead — what the admin
    /// forms (users, discounts) need to offer. It requires branches.view or
    /// users.view, and answers 403 <c>branches_forbidden</c> otherwise. Rows
    /// carry <c>addressAr</c>/<c>addressEn</c> as well (core.Branch has no
    /// city column).
    /// </remarks>
    private static async Task<IResult> BranchesAsync(
        ISqlConnectionFactory db, ICurrentUser current, bool? all, CancellationToken ct)
    {
        var everyBranch = all ?? false;

        if (everyBranch && !current.Can("branches.view") && !current.Can("users.view"))
            return ProcErrors.Forbidden("branches_forbidden",
                "Listing every branch needs the branches or users view permission.",
                "عرض جميع الفروع يحتاج صلاحية عرض الفروع أو المستخدمين.");

        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT b.BranchId, b.Code, b.NameAr, b.NameEn, b.Phone, b.IsActive, b.AddressAr, b.AddressEn
            FROM core.Branch AS b
            WHERE b.IsActive = 1
              AND (@All = 1 OR EXISTS (SELECT 1 FROM core.UserBranch AS ub
                                       WHERE ub.BranchId = b.BranchId AND ub.UserId = @UserId))
            ORDER BY b.Code;
            """,
            new { current.UserId, All = everyBranch }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    /// <summary>
    /// A branch's settings, named as the settings screen names them.
    ///
    /// A branch never configured gets the defaults rather than a 404 — a new
    /// branch should work on day one. <c>configured</c> says which it is.
    /// </summary>
    private static async Task<IResult> SettingsAsync(
        string branchId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        if (!current.CanSeeBranch(branchId)) return Results.Forbid();

        await using var connection = db.Create();

        var settings = await LoadSettingsAsync(connection, branchId, ct);

        return settings is null ? BranchNotFound() : Results.Ok(settings);
    }

    /// <summary>Replace a branch's settings. Creates the row if it has none yet.</summary>
    private static async Task<IResult> SaveSettingsAsync(
        string branchId,
        SaveBranchSettingsRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (!current.CanSeeBranch(branchId)) return Results.Forbid();

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SaveBranchSettings",
                new
                {
                    BranchId = branchId,
                    request.DefaultCustomerMode,
                    ServedByRequirement = request.ServedBy,
                    request.AllowNegativeStock,
                    DefaultBillId = string.IsNullOrWhiteSpace(request.DefaultBillTemplateId)
                        ? null : request.DefaultBillTemplateId.Trim(),
                    AutoPrintCustomer = request.AutoPrintCustomerBill,
                    AutoPrintGroups = request.AutoPrintGroupTickets,
                    request.VatRatePercent,
                    request.PricesIncludeVat,
                    Actor = current.Username
                },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapSettingsError(ex) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Settings for {BranchId} updated by {Actor}.", branchId, current.Username);
        http.Items["AuditEntityId"] = branchId;

        return Results.Ok(await LoadSettingsAsync(connection, branchId, ct));
    }

    /// <summary>
    /// Copy another branch's settings onto this one. Both branches must be
    /// ones the caller works in: copying is reading one and writing the other.
    /// </summary>
    private static async Task<IResult> CopySettingsAsync(
        string branchId,
        CopyBranchSettingsRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (!current.CanSeeBranch(branchId) || !current.CanSeeBranch(request.SourceBranchId))
            return Results.Forbid();

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_CopyBranchSettings",
                new { request.SourceBranchId, TargetBranchId = branchId, Actor = current.Username },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapSettingsError(ex) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Settings copied from {Source} to {Target} by {Actor}.",
            request.SourceBranchId, branchId, current.Username);
        http.Items["AuditEntityId"] = branchId;
        http.Items["AuditNewValue"] = $"copied from {request.SourceBranchId}";

        return Results.Ok(await LoadSettingsAsync(connection, branchId, ct));
    }

    private static IResult BranchNotFound() =>
        ProcErrors.NotFound("No such branch.", "لا يوجد فرع بهذا المعرف.");

    private static IResult? MapSettingsError(SqlException ex) => ex.Number switch
    {
        62050 => BranchNotFound(),
        62051 => ProcErrors.Field("defaultCustomerMode",
            "The default customer mode is walkin or customer.", "وضع العميل الافتراضي walkin أو customer."),
        62052 => ProcErrors.Field("servedBy", "Served-by is off, optional or required.", "خيار مقدم الخدمة off أو optional أو required."),
        62053 => ProcErrors.Field("vatRatePercent", "Enter a VAT rate between 0 and 100.", "أدخل نسبة ضريبة بين ٠ و١٠٠."),
        62054 => ProcErrors.Field("defaultBillTemplateId",
            "The default bill must be an active customer template.", "يجب أن تكون الفاتورة الافتراضية قالب عميل نشطًا."),
        62055 => ProcErrors.Conflict("source_not_configured",
            "That branch has no settings to copy yet.", "لا توجد إعدادات لهذا الفرع لنسخها بعد."),
        62056 => ProcErrors.Field("sourceBranchId",
            "Choose a different branch to copy from.", "اختر فرعًا آخر للنسخ منه."),
        _ => null
    };

    private static async Task<BranchSettingsDto?> LoadSettingsAsync(
        SqlConnection connection, string branchId, CancellationToken ct)
    {
        var row = await connection.QuerySingleOrDefaultAsync<SettingsRow>(new CommandDefinition(
            """
            SELECT b.BranchId, b.CreatedAtUtc AS BranchCreatedAtUtc,
                   CAST(CASE WHEN s.BranchId IS NULL THEN 0 ELSE 1 END AS BIT) AS Configured,
                   ISNULL(s.DefaultCustomerMode, N'walkin')   AS DefaultCustomerMode,
                   ISNULL(s.ServedByRequirement, N'optional') AS ServedByRequirement,
                   ISNULL(s.AllowNegativeStock, 0)            AS AllowNegativeStock,
                   s.DefaultBillId,
                   ISNULL(s.AutoPrintCustomer, 1)             AS AutoPrintCustomer,
                   ISNULL(s.AutoPrintGroups, 1)               AS AutoPrintGroups,
                   ISNULL(s.VatRatePercent, 15.00)            AS VatRatePercent,
                   ISNULL(s.PricesIncludeVat, 1)              AS PricesIncludeVat,
                   s.UpdatedAtUtc, s.UpdatedBy
            FROM core.Branch AS b
            LEFT JOIN core.BranchSettings AS s ON s.BranchId = b.BranchId
            WHERE b.BranchId = @BranchId;
            """,
            new { BranchId = branchId }, cancellationToken: ct));

        return row is null ? null : new BranchSettingsDto(
            row.BranchId, row.Configured, row.DefaultCustomerMode, row.ServedByRequirement,
            row.AllowNegativeStock, row.DefaultBillId, row.AutoPrintCustomer, row.AutoPrintGroups,
            row.VatRatePercent, row.PricesIncludeVat,
            row.BranchCreatedAtUtc, row.UpdatedAtUtc ?? row.BranchCreatedAtUtc, row.UpdatedBy);
    }

    private sealed record SettingsRow
    {
        public string BranchId { get; init; } = string.Empty;
        public DateTime BranchCreatedAtUtc { get; init; }
        public bool Configured { get; init; }
        public string DefaultCustomerMode { get; init; } = string.Empty;
        public string ServedByRequirement { get; init; } = string.Empty;
        public bool AllowNegativeStock { get; init; }
        public string? DefaultBillId { get; init; }
        public bool AutoPrintCustomer { get; init; }
        public bool AutoPrintGroups { get; init; }
        public decimal VatRatePercent { get; init; }
        public bool PricesIncludeVat { get; init; }
        public DateTime? UpdatedAtUtc { get; init; }
        public string? UpdatedBy { get; init; }
    }

    private static async Task<IResult> LanguagesAsync(ISqlConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            "SELECT Code, NameNative, NameEn, IsRtl FROM core.Language WHERE IsActive = 1 ORDER BY SortOrder;",
            cancellationToken: ct));

        return Results.Ok(rows);
    }
}
