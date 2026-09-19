using Dapper;
using PosApi.Auth;
using PosApi.Data;

namespace PosApi.Features.Settings;

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
        group.MapGet("/languages", LanguagesAsync).AllowAnonymous();
    }

    /// <summary>
    /// Only the branches this person works at. Filtering here rather than in the
    /// client means a branch they cannot use never reaches the browser.
    /// </summary>
    private static async Task<IResult> BranchesAsync(
        ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT b.BranchId, b.Code, b.NameAr, b.NameEn, b.Phone, b.IsActive
            FROM core.Branch AS b
            WHERE b.IsActive = 1
              AND EXISTS (SELECT 1 FROM core.UserBranch AS ub
                          WHERE ub.BranchId = b.BranchId AND ub.UserId = @UserId)
            ORDER BY b.Code;
            """,
            new { current.UserId }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> SettingsAsync(
        string branchId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        if (!current.CanSeeBranch(branchId)) return Results.Forbid();

        await using var connection = db.Create();

        var settings = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            "SELECT * FROM core.BranchSettings WHERE BranchId = @BranchId;",
            new { BranchId = branchId }, cancellationToken: ct));

        return settings is null ? Results.NotFound() : Results.Ok(settings);
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
