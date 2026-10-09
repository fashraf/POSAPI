namespace PosApi.Features.SuperAdmin;

/// <summary>
/// The SaaS console's API, /api/superadmin. Everything except sign-in needs a
/// platform administrator's token (the SuperAdmin scheme); a tenant's POS
/// token is refused here, and an admin token is refused by the POS routes.
/// </summary>
public static class SuperAdminEndpoints
{
    public static void MapSuperAdminEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api/superadmin")
            .RequireAuthorization(AdminAuth.Policy)
            .RequireRateLimiting("standard");

        api.MapClientEndpoints();
        api.MapPlatformEndpoints();
        api.MapBillingEndpoints();
        api.MapConfigEndpoints();
    }
}
