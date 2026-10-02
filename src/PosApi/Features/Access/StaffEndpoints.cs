using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Localization;

namespace PosApi.Features.Access;

/// <summary>
/// Someone who can be named as "served by" at the till. Deliberately thin:
/// no contact details, salary or permissions, because anyone who can ring up
/// a sale may read it.
/// </summary>
public sealed record StaffMemberDto(
    string Id,
    string NameAr,
    string NameEn,
    string Name,
    string RoleId,
    string RoleNameAr,
    string RoleNameEn);

public static class StaffEndpoints
{
    public static void MapStaffEndpoints(this IEndpointRouteBuilder app)
    {
        /* Under /api/users, next to the full user routes; the literal segment
           wins over /api/users/{userId}. */
        app.MapGet("/api/users/staff", StaffAsync)
           .WithTags("Users")
           .RequireAuthorization(PermissionPolicy.For("pos.create_sale"))
           .RequireRateLimiting("standard");
    }

    /// <summary>
    /// Active users who work at <c>branchId</c>, or — without one — at any
    /// branch the caller works at. External (time-limited) accounts whose
    /// access has expired are left out.
    /// </summary>
    private static async Task<IResult> StaffAsync(
        ISqlConnectionFactory db, ICurrentUser current, ILanguageContext language,
        string? branchId, CancellationToken ct)
    {
        var branch = ProcErrors.Blank(branchId);
        if (!current.CanSeeBranch(branch)) return Results.Forbid();

        await using var connection = db.Create();

        var rows = await connection.QueryAsync<StaffRow>(new CommandDefinition(
            """
            SELECT u.UserId, u.NameAr, u.NameEn, u.RoleId, r.NameAr AS RoleNameAr, r.NameEn AS RoleNameEn
            FROM core.AppUser AS u
            JOIN core.Role AS r ON r.RoleId = u.RoleId
            WHERE u.Status = N'active'
              AND (u.AccessExpiresOn IS NULL OR u.AccessExpiresOn >= CAST(SYSUTCDATETIME() AS DATE))
              AND EXISTS (
                    SELECT 1 FROM core.UserBranch AS ub
                    WHERE ub.UserId = u.UserId
                      AND (   (@BranchId IS NOT NULL AND ub.BranchId = @BranchId)
                           OR (@BranchId IS NULL AND ub.BranchId IN
                                  (SELECT mine.BranchId FROM core.UserBranch AS mine WHERE mine.UserId = @Me))))
            ORDER BY u.NameEn;
            """,
            new { BranchId = branch, Me = current.UserId }, cancellationToken: ct));

        return Results.Ok(rows.Select(r => new StaffMemberDto(
            r.UserId, r.NameAr, r.NameEn, language.Pick(r.NameAr, r.NameEn),
            r.RoleId, r.RoleNameAr, r.RoleNameEn)).ToList());
    }

    private sealed record StaffRow
    {
        public string UserId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string RoleId { get; init; } = string.Empty;
        public string RoleNameAr { get; init; } = string.Empty;
        public string RoleNameEn { get; init; } = string.Empty;
    }
}
