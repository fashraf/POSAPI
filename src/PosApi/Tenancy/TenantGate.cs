using Dapper;
using PosApi.Common;

namespace PosApi.Tenancy;

/// <summary>
/// Binds an anonymous request to a tenant once the endpoint has worked out
/// which one — sign-in from the login directory, a refresh token or OTP
/// challenge from its prefix, a device from its code or serial.
///
/// Returns the refusal to send when the tenant cannot be used, so a suspended
/// business is refused at sign-in with the same message the middleware gives
/// its signed-in sessions.
/// </summary>
public sealed class TenantGate
{
    private static string? _legacyTenantId;

    private readonly ITenantContext _context;
    private readonly TenantCatalog _catalog;

    public TenantGate(ITenantContext context, TenantCatalog catalog)
    {
        _context = context;
        _catalog = catalog;
    }

    /// <summary>
    /// Enter a tenant. A null id means a value minted before tenancy (an old
    /// refresh token, a pending OTP); those belong to the adopted database.
    /// </summary>
    public async Task<IResult?> EnterAsync(string? tenantId, CancellationToken ct, bool enforce = true)
    {
        tenantId ??= await LegacyTenantAsync(ct);

        var tenant = tenantId is null ? null : await _catalog.GetAsync(tenantId, ct);

        if (tenant is null)
            return Results.Json(ApiError.Create("invalid_credentials",
                "That sign-in is not valid.", "بيانات الدخول غير صحيحة."), statusCode: StatusCodes.Status401Unauthorized);

        if (enforce && TenantCatalog.Refusal(tenant) is { } refusal)
            return Results.Json(refusal, statusCode: StatusCodes.Status403Forbidden);

        _context.Use(tenant);
        return null;
    }

    public TenantInfo Current => _context.Tenant ?? throw new TenantNotResolvedException();

    private async Task<string?> LegacyTenantAsync(CancellationToken ct)
    {
        if (_legacyTenantId is not null) return _legacyTenantId;

        await using var control = _catalog.Control();
        _legacyTenantId = await control.QueryFirstOrDefaultAsync<string>(new CommandDefinition(
            """
            SELECT TOP (1) TenantId FROM ctl.Tenant
            WHERE Status = N'active'
            ORDER BY CASE WHEN Source = N'adopted' THEN 0 ELSE 1 END, CreatedAtUtc;
            """,
            cancellationToken: ct));

        return _legacyTenantId;
    }
}
