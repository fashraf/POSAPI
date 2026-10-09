using PosApi.Common;

namespace PosApi.Tenancy;

/// <summary>
/// The tenant this request belongs to.
///
/// Set once per request: by TenantMiddleware from the token's tenant claim, or
/// by an anonymous endpoint (sign-in, device registration) once it has looked
/// the tenant up. Every tenant database connection is opened through it, so a
/// request that never resolved a tenant cannot reach any tenant's data.
/// </summary>
public interface ITenantContext
{
    TenantInfo? Tenant { get; }
    bool IsResolved { get; }
    void Use(TenantInfo tenant);

    /// <summary>The tenant's connection string; throws if none was resolved.</summary>
    string ConnectionString { get; }
}

public sealed class TenantContext : ITenantContext
{
    public TenantInfo? Tenant { get; private set; }

    public bool IsResolved => Tenant is not null;

    public void Use(TenantInfo tenant)
    {
        /* Switching tenant half-way through a request would mix two businesses'
           data in one response. Re-setting the same one is harmless. */
        if (Tenant is not null && !string.Equals(Tenant.TenantId, tenant.TenantId, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The request is already bound to another tenant.");

        Tenant = tenant;
    }

    public string ConnectionString =>
        Tenant?.ConnectionString ?? throw new TenantNotResolvedException();
}

/// <summary>A tenant database was asked for before the tenant was known — a bug, not a user error.</summary>
public sealed class TenantNotResolvedException()
    : InvalidOperationException("No tenant was resolved for this request, so no tenant database can be opened.");

/// <summary>
/// Binds each authenticated POS request to its tenant and enforces the
/// tenant's state.
///
/// Runs after authentication. The token carries the tenant id ("tid"); the
/// tenant's current status comes from the control database (cached briefly),
/// so suspending a client stops its signed-in sessions within seconds rather
/// than when their tokens expire.
/// </summary>
public sealed class TenantMiddleware
{
    public const string TenantClaim = "tid";

    private readonly RequestDelegate _next;

    public TenantMiddleware(RequestDelegate next) => _next = next;

    public async Task InvokeAsync(HttpContext context, ITenantContext tenantContext, TenantCatalog catalog)
    {
        var user = context.User;

        /* The console has its own scheme and never touches a tenant database
           through this path. */
        if (context.Request.Path.StartsWithSegments("/api/superadmin")
            || user.Identity?.IsAuthenticated != true)
        {
            await _next(context);
            return;
        }

        var tenantId = user.FindFirst(TenantClaim)?.Value;

        if (string.IsNullOrEmpty(tenantId))
        {
            /* A token minted before tenancy. It expires within minutes; signing
               in again issues one that names its tenant. */
            await RefuseAsync(context, StatusCodes.Status401Unauthorized, ApiError.Create(
                "session_outdated", "Please sign in again.", "يرجى تسجيل الدخول مرة أخرى."));
            return;
        }

        var tenant = await catalog.GetAsync(tenantId, context.RequestAborted);

        if (tenant is null)
        {
            await RefuseAsync(context, StatusCodes.Status401Unauthorized, ApiError.Create(
                "tenant_not_found", "This business account no longer exists.", "حساب هذه المنشأة غير موجود."));
            return;
        }

        if (TenantCatalog.Refusal(tenant) is { } refusal)
        {
            await RefuseAsync(context, StatusCodes.Status403Forbidden, refusal);
            return;
        }

        tenantContext.Use(tenant);
        await _next(context);
    }

    private static Task RefuseAsync(HttpContext context, int status, ApiError error)
    {
        context.Response.StatusCode = status;
        return context.Response.WriteAsJsonAsync(error);
    }
}
