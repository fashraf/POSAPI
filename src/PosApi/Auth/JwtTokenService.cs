using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

namespace PosApi.Auth;

public sealed record TokenPair(
    string AccessToken,
    string RefreshToken,
    DateTime AccessExpiresAtUtc,
    DateTime RefreshExpiresAtUtc);

public interface IJwtTokenService
{
    TokenPair Issue(string tenantId, string userId, string username, string roleId,
                    IEnumerable<string> permissions, IEnumerable<string> branchIds);
    string HashRefreshToken(string refreshToken);
}

public sealed class JwtTokenService : IJwtTokenService
{
    public const string PermissionClaim = "perm";
    public const string BranchClaim = "branch";

    private readonly JwtOptions _options;
    private readonly SymmetricSecurityKey _key;

    public JwtTokenService(IOptions<JwtOptions> options, SigningKeyProvider signingKey)
    {
        _options = options.Value;

        /* The key comes from SigningKeyProvider, which resolved it once and
           already validated it. Reading configuration again here is what let
           signing and validation drift apart. */
        _key = signingKey.Key;
    }

    public TokenPair Issue(
        string tenantId,
        string userId,
        string username,
        string roleId,
        IEnumerable<string> permissions,
        IEnumerable<string> branchIds)
    {
        var now = DateTime.UtcNow;
        var accessExpires = now.AddMinutes(_options.AccessTokenMinutes);

        var claims = new List<Claim>
        {
            new(JwtRegisteredClaimNames.Sub, userId),
            new(JwtRegisteredClaimNames.UniqueName, username),
            new(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString("N")),
            new(ClaimTypes.Role, roleId),
            new("role", roleId),
            /* Which database this session works in. Checked against the
               control database on every request (TenantMiddleware). */
            new(PosApi.Tenancy.TenantMiddleware.TenantClaim, tenantId)
        };

        // Permissions ride in the token so an authorization check is a claim
        // lookup rather than a database round trip on every request. The short
        // access-token lifetime is what bounds how stale they can be.
        claims.AddRange(permissions.Select(p => new Claim(PermissionClaim, p)));
        claims.AddRange(branchIds.Select(b => new Claim(BranchClaim, b)));

        var token = new JwtSecurityToken(
            issuer: _options.Issuer,
            audience: _options.Audience,
            claims: claims,
            notBefore: now,
            expires: accessExpires,
            signingCredentials: new SigningCredentials(_key, SecurityAlgorithms.HmacSha256));

        return new TokenPair(
            new JwtSecurityTokenHandler().WriteToken(token),
            /* Prefixed with the tenant so the anonymous refresh call can find
               the database the token is stored in. */
            PosApi.Tenancy.TenantKey.Compose(tenantId, Convert.ToBase64String(RandomNumberGenerator.GetBytes(48))),
            accessExpires,
            now.AddDays(_options.RefreshTokenDays));
    }

    /// <summary>
    /// Refresh tokens are stored hashed. They are bearer credentials with a
    /// long life, so a leaked table should not hand out sessions.
    /// </summary>
    public string HashRefreshToken(string refreshToken)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(refreshToken));
        return Convert.ToBase64String(bytes);
    }
}
