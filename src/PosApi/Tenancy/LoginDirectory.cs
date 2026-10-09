using System.Data.Common;
using Dapper;
using Microsoft.Data.SqlClient;

namespace PosApi.Tenancy;

/// <summary>
/// Which tenant a sign-in identifier belongs to.
///
/// Sign-in happens before the tenant is known, and searching every tenant
/// database for an email would be slow and would leak timing. Instead the
/// control database keeps identifier → tenant for every user's email, mobile
/// and username, which also makes them unique across the platform: two
/// businesses cannot both have an "ahmed", or the sign-in could not tell them
/// apart.
/// </summary>
public sealed class LoginDirectory
{
    private readonly TenantCatalog _catalog;
    private readonly ILogger<LoginDirectory> _logger;

    public LoginDirectory(TenantCatalog catalog, ILogger<LoginDirectory> logger)
    {
        _catalog = catalog;
        _logger = logger;
    }

    public static string Normalize(string identifier) => identifier.Trim().ToLowerInvariant();

    /// <summary>The tenant an identifier signs in to, or null.</summary>
    public async Task<string?> FindTenantAsync(string identifier, CancellationToken ct)
    {
        await using var connection = _catalog.Control();
        return await connection.QuerySingleOrDefaultAsync<string>(new CommandDefinition(
            "SELECT TenantId FROM ctl.LoginDirectory WHERE Identifier = @Identifier;",
            new { Identifier = Normalize(identifier) }, cancellationToken: ct));
    }

    /// <summary>
    /// The first identifier already used by someone else on the platform, or
    /// null when all are free. "Someone else" excludes this same user, so an
    /// edit that keeps the user's own email is not a conflict.
    /// </summary>
    public async Task<string?> FirstTakenAsync(
        string tenantId, string? userId, IEnumerable<string?> identifiers, CancellationToken ct)
    {
        var wanted = identifiers.Where(i => !string.IsNullOrWhiteSpace(i)).Select(i => Normalize(i!)).Distinct().ToList();
        if (wanted.Count == 0) return null;

        await using var connection = _catalog.Control();
        return await connection.QueryFirstOrDefaultAsync<string>(new CommandDefinition(
            """
            SELECT TOP (1) Identifier FROM ctl.LoginDirectory
            WHERE Identifier IN @Wanted
              AND NOT (TenantId = @TenantId AND UserId = ISNULL(@UserId, N''));
            """,
            new { Wanted = wanted, TenantId = tenantId, UserId = userId }, cancellationToken: ct));
    }

    /// <summary>Make one user's directory entries match their row in the tenant database.</summary>
    public async Task SyncUserAsync(string tenantId, DbConnection tenant, string userId, CancellationToken ct)
    {
        var user = await tenant.QuerySingleOrDefaultAsync<(string Username, string? Email, string? Phone)>(
            new CommandDefinition(
                "SELECT Username, Email, Phone FROM core.AppUser WHERE UserId = @UserId;",
                new { UserId = userId }, cancellationToken: ct));

        await using var connection = _catalog.Control();
        await connection.OpenAsync(ct);
        await using var tx = await connection.BeginTransactionAsync(ct);

        await connection.ExecuteAsync(new CommandDefinition(
            "DELETE FROM ctl.LoginDirectory WHERE TenantId = @TenantId AND UserId = @UserId;",
            new { TenantId = tenantId, UserId = userId }, tx, cancellationToken: ct));

        if (user.Username is not null)
        {
            foreach (var (identifier, kind) in Entries(user.Username, user.Email, user.Phone))
                await InsertAsync(connection, tx, tenantId, userId, identifier, kind, ct);
        }

        await tx.CommitAsync(ct);
    }

    /// <summary>
    /// Rebuild a whole tenant's entries from its database — after provisioning,
    /// or when adopting a database that predates the directory. An identifier
    /// another tenant already holds is skipped and logged, never stolen.
    /// </summary>
    public async Task<int> RebuildTenantAsync(string tenantId, string tenantConnection, CancellationToken ct)
    {
        await using var tenant = new SqlConnection(tenantConnection);
        var users = (await tenant.QueryAsync<(string UserId, string Username, string? Email, string? Phone)>(
            new CommandDefinition("SELECT UserId, Username, Email, Phone FROM core.AppUser;", cancellationToken: ct))).ToList();

        await using var connection = _catalog.Control();
        await connection.OpenAsync(ct);
        await using var tx = await connection.BeginTransactionAsync(ct);

        await connection.ExecuteAsync(new CommandDefinition(
            "DELETE FROM ctl.LoginDirectory WHERE TenantId = @TenantId;",
            new { TenantId = tenantId }, tx, cancellationToken: ct));

        var count = 0;
        foreach (var user in users)
        {
            foreach (var (identifier, kind) in Entries(user.Username, user.Email, user.Phone))
            {
                if (await InsertAsync(connection, tx, tenantId, user.UserId, identifier, kind, ct)) count++;
            }
        }

        await tx.CommitAsync(ct);
        return count;
    }

    private static IEnumerable<(string Identifier, string Kind)> Entries(string username, string? email, string? phone)
    {
        var seen = new HashSet<string>();
        foreach (var (value, kind) in new[] { (username, "username"), (email, "email"), (phone, "phone") })
        {
            if (string.IsNullOrWhiteSpace(value)) continue;
            var normalized = Normalize(value);
            if (seen.Add(normalized)) yield return (normalized, kind);
        }
    }

    private async Task<bool> InsertAsync(
        SqlConnection connection, DbTransaction tx, string tenantId, string userId,
        string identifier, string kind, CancellationToken ct)
    {
        var inserted = await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO ctl.LoginDirectory (Identifier, TenantId, UserId, Kind)
            SELECT @Identifier, @TenantId, @UserId, @Kind
            WHERE NOT EXISTS (SELECT 1 FROM ctl.LoginDirectory WHERE Identifier = @Identifier);
            """,
            new { Identifier = identifier, TenantId = tenantId, UserId = userId, Kind = kind },
            tx, cancellationToken: ct));

        if (inserted == 0)
        {
            _logger.LogWarning(
                "Sign-in identifier {Identifier} of {TenantId}/{UserId} is already used by another tenant; that user cannot sign in with it.",
                identifier, tenantId, userId);
        }

        return inserted > 0;
    }
}

/// <summary>
/// Opaque values handed to a client (refresh tokens, OTP challenge ids,
/// device tokens) carry their tenant as a prefix, "CL-00002.secret", so the
/// anonymous call that brings one back can find the database to check it in.
/// The prefix only routes; the value is still verified in that tenant's own
/// database, so editing the prefix just sends it somewhere it is not found.
/// </summary>
public static class TenantKey
{
    public static string Compose(string tenantId, string secret) => $"{tenantId}.{secret}";

    /// <summary>The tenant prefix, or null for a value minted before tenancy.</summary>
    public static string? TenantOf(string? value)
    {
        if (string.IsNullOrEmpty(value)) return null;
        var dot = value.IndexOf('.');
        return dot is > 0 and <= 20 && value.StartsWith("CL-", StringComparison.Ordinal) ? value[..dot] : null;
    }
}
