using System.Security.Claims;

namespace PosApi.Auth;

public interface ICurrentUser
{
    bool IsAuthenticated { get; }
    string TenantId { get; }
    string UserId { get; }
    string Username { get; }
    string RoleId { get; }
    IReadOnlySet<string> Permissions { get; }
    IReadOnlySet<string> BranchIds { get; }
    bool Can(string permission);
    bool CanSeeBranch(string? branchId);
}

public sealed class CurrentUser : ICurrentUser
{
    private readonly IHttpContextAccessor _accessor;

    public CurrentUser(IHttpContextAccessor accessor) => _accessor = accessor;

    /*
     * Read on every access, never captured in the constructor.
     *
     * The audit middleware runs before authentication and asks for this
     * service, so a scoped instance is built while the request is still
     * anonymous. Capturing the principal then froze that anonymous user for the
     * whole request: /me returned 401, every actor was blank, and an empty
     * branch set made CanSeeBranch allow every branch.
     */
    private ClaimsPrincipal? Principal => _accessor.HttpContext?.User;

    public bool IsAuthenticated => Principal?.Identity?.IsAuthenticated ?? false;

    /* Inbound claim mapping is off, so these are the names the token actually
       carries. The ClaimTypes fallbacks cover a token minted before that
       change, so an existing session does not break on deploy. */
    public string UserId =>
        Principal?.FindFirstValue("sub")
        ?? Principal?.FindFirstValue(ClaimTypes.NameIdentifier)
        ?? string.Empty;

    public string Username =>
        Principal?.FindFirstValue("unique_name")
        ?? Principal?.FindFirstValue(ClaimTypes.Name)
        ?? string.Empty;

    public string RoleId =>
        Principal?.FindFirstValue(ClaimTypes.Role)
        ?? Principal?.FindFirstValue("role")
        ?? string.Empty;

    public string TenantId => Principal?.FindFirstValue(PosApi.Tenancy.TenantMiddleware.TenantClaim) ?? string.Empty;

    public IReadOnlySet<string> Permissions => ClaimSet(JwtTokenService.PermissionClaim);
    public IReadOnlySet<string> BranchIds => ClaimSet(JwtTokenService.BranchClaim);

    private HashSet<string> ClaimSet(string type) =>
        Principal?.FindAll(type).Select(c => c.Value).ToHashSet(StringComparer.OrdinalIgnoreCase)
        ?? new HashSet<string>();

    public bool Can(string permission) => Permissions.Contains(permission);

    /// <summary>
    /// A null branch means the record is not branch-specific and is visible
    /// everywhere — the same rule the frontend applies, kept identical so a
    /// record cannot be visible in one layer and hidden in the other.
    /// </summary>
    public bool CanSeeBranch(string? branchId)
        => branchId is null || BranchIds.Count == 0 || BranchIds.Contains(branchId);
}
