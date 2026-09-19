using Dapper;
using PosApi.Auth;
using PosApi.Data;

namespace PosApi.Features.Access;

public static class UserEndpoints
{
    public static void MapUserEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/users")
            .WithTags("Users")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("users.view"));

        group.MapGet("/roles", RolesAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.view"));

        group.MapGet("/permissions", PermissionsAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.view"));
    }

    /// <summary>
    /// Staff.
    ///
    /// Password hashes are never selected. A field that is never read cannot be
    /// leaked by a logging change or a serialisation mistake later.
    /// </summary>
    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, string? search, bool? activeOnly, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT u.UserId, u.Username, u.NameAr, u.NameEn, u.Email, u.Phone,
                   u.RoleId, r.NameAr AS RoleNameAr, r.NameEn AS RoleNameEn,
                   u.Status, u.IsExternal, u.AccessExpiresOn, u.BaseSalaryH,
                   u.LastLoginAtUtc, u.CreatedAtUtc, u.UpdatedAtUtc
            FROM core.AppUser AS u
            JOIN core.Role AS r ON r.RoleId = u.RoleId
            WHERE (@Search IS NULL OR u.NameAr LIKE N'%' + @Search + N'%'
                                   OR u.NameEn LIKE N'%' + @Search + N'%'
                                   OR u.Email  LIKE N'%' + @Search + N'%')
              AND (@ActiveOnly = 0 OR u.Status = N'active')
            ORDER BY u.NameEn;
            """,
            new
            {
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                ActiveOnly = activeOnly ?? false
            },
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> RolesAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT RoleId, NameAr, NameEn, DescriptionAr, DescriptionEn, IsBuiltIn, IsExternal
            FROM core.Role ORDER BY NameEn;

            SELECT RoleId, PermissionKey FROM core.RolePermission;
            """,
            cancellationToken: ct));

        var roles = (await multi.ReadAsync()).ToList();
        var permissions = (await multi.ReadAsync()).ToList();

        return Results.Ok(new { roles, permissions });
    }

    private static async Task<IResult> PermissionsAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            "SELECT PermissionKey, Module, Action, Sensitivity FROM core.Permission ORDER BY Module, Action;",
            cancellationToken: ct));

        return Results.Ok(rows);
    }
}
