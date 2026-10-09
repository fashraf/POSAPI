using System.Collections.Concurrent;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using Dapper;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Tenancy;

namespace PosApi.Features.SuperAdmin;

/// <summary>
/// Platform administrators: who runs the console.
///
/// Entirely separate from tenant users. Admins live in the control database,
/// sign in with their own scheme and audience, and a POS token can never call
/// a console route (or the other way round) — the audiences differ, so each
/// scheme rejects the other's tokens before any handler runs.
/// </summary>
public static class AdminAuth
{
    public const string Scheme = "SuperAdmin";
    public const string Policy = "superadmin";
    public const string Audience = "nazad-admin";
    public const string ScopeClaim = "scope";
    public const string SessionClaim = "sv";

    /// <summary>The admin bearer scheme; validates the version claim against the control database.</summary>
    public static void AddSuperAdminScheme(this Microsoft.AspNetCore.Authentication.AuthenticationBuilder builder,
        JwtOptions jwt, SigningKeyProvider key)
    {
        builder.AddJwtBearer(Scheme, options =>
        {
            options.MapInboundClaims = false;
            options.TokenValidationParameters = new TokenValidationParameters
            {
                ValidateIssuer = true,
                ValidateAudience = true,
                ValidateLifetime = true,
                ValidateIssuerSigningKey = true,
                ValidIssuer = jwt.Issuer,
                ValidAudience = Audience,
                IssuerSigningKey = key.Key,
                ClockSkew = TimeSpan.Zero
            };

            /* A reset password or a suspended admin ends every session now,
               not when the token runs out. */
            options.Events = new JwtBearerEvents
            {
                OnTokenValidated = async context =>
                {
                    var sessions = context.HttpContext.RequestServices.GetRequiredService<AdminSessions>();
                    var adminId = context.Principal?.FindFirstValue("sub");
                    var version = context.Principal?.FindFirstValue(SessionClaim);

                    if (adminId is null || !await sessions.IsCurrentAsync(adminId, version, context.HttpContext.RequestAborted))
                        context.Fail("This session has ended.");
                }
            };
        });
    }
}

/// <summary>Which admin sessions are still valid: status and session version, cached briefly.</summary>
public sealed class AdminSessions
{
    private readonly TenantCatalog _catalog;
    private readonly ConcurrentDictionary<string, (string Status, int Version, DateTime At)> _cache = new();

    public AdminSessions(TenantCatalog catalog) => _catalog = catalog;

    public async Task<bool> IsCurrentAsync(string adminId, string? version, CancellationToken ct)
    {
        if (!_cache.TryGetValue(adminId, out var hit) || DateTime.UtcNow - hit.At > TimeSpan.FromSeconds(30))
        {
            await using var control = _catalog.Control();
            var row = await control.QuerySingleOrDefaultAsync<(string Status, int SessionVersion)>(new CommandDefinition(
                "SELECT Status, SessionVersion FROM ctl.Admin WHERE AdminId = @AdminId;",
                new { AdminId = adminId }, cancellationToken: ct));

            hit = (row.Status ?? "missing", row.SessionVersion, DateTime.UtcNow);
            _cache[adminId] = hit;
        }

        return hit.Status == "active" && hit.Version.ToString() == version;
    }

    public void Evict(string adminId) => _cache.TryRemove(adminId, out _);
}

/// <summary>The signed-in administrator.</summary>
public sealed class CurrentAdmin
{
    private readonly IHttpContextAccessor _accessor;

    public CurrentAdmin(IHttpContextAccessor accessor) => _accessor = accessor;

    private ClaimsPrincipal? User => _accessor.HttpContext?.User;

    public string AdminId => User?.FindFirstValue("sub") ?? string.Empty;
    public string Name => User?.FindFirstValue("name") ?? string.Empty;
    public string Role => User?.FindFirstValue("role") ?? string.Empty;
}

public sealed record AdminLoginRequest(string Mobile, string Password);
public sealed record AdminVerifyRequest(string ChallengeId, string Code);
public sealed record AdminChangePasswordRequest(string CurrentPassword, string NewPassword);

public static class AdminAuthEndpoints
{
    public static void MapAdminAuthEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/superadmin/auth")
            .WithTags("SuperAdmin · Auth")
            .RequireRateLimiting("auth");

        group.MapPost("/login", LoginAsync).AllowAnonymous();
        group.MapPost("/verify", VerifyAsync).AllowAnonymous();
        group.MapGet("/me", MeAsync).RequireAuthorization(AdminAuth.Policy);
        group.MapPost("/change-password", ChangePasswordAsync).RequireAuthorization(AdminAuth.Policy);
    }

    private static IResult Invalid() => Results.Json(new
    {
        code = "invalid_credentials",
        message = "That mobile number or password is not correct.",
        messageEn = "That mobile number or password is not correct.",
        messageAr = "رقم الجوال أو كلمة المرور غير صحيحة."
    }, statusCode: StatusCodes.Status401Unauthorized);

    /// <summary>
    /// Step one: the password. Answers with a one-time code challenge — an
    /// account that can lock every client out is never one factor deep.
    /// </summary>
    private static async Task<IResult> LoginAsync(
        AdminLoginRequest request, TenantCatalog catalog, IPasswordHasher hasher,
        IOptions<AuthOptions> authOptions, IHostEnvironment environment, ILogger<Program> logger,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Mobile) || string.IsNullOrEmpty(request.Password))
            return Invalid();

        var options = authOptions.Value;
        await using var control = catalog.Control();

        var admin = await control.QuerySingleOrDefaultAsync<AdminRow>(new CommandDefinition(
            """
            SELECT AdminId, Name, Mobile, Role, Permissions, PasswordHash, PasswordSalt, Status,
                   FailedLogins, LockedUntilUtc, SessionVersion, MustChangePassword
            FROM ctl.Admin WHERE Mobile = @Mobile;
            """, new { Mobile = request.Mobile.Trim() }, cancellationToken: ct));

        if (admin is null)
        {
            hasher.Verify(request.Password, "pbkdf2$210000$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "AAAAAAAAAAAAAAAAAAAAAA==");
            return Invalid();
        }

        if (admin.LockedUntilUtc is { } locked && locked > DateTime.UtcNow)
        {
            return Results.Json(new
            {
                code = "locked",
                message = $"Too many attempts. Try again after {locked:HH:mm} UTC.",
                messageAr = "محاولات كثيرة. حاول لاحقًا."
            }, statusCode: StatusCodes.Status423Locked);
        }

        if (!hasher.Verify(request.Password, admin.PasswordHash, admin.PasswordSalt))
        {
            await control.ExecuteAsync(new CommandDefinition(
                """
                UPDATE ctl.Admin
                SET FailedLogins = FailedLogins + 1,
                    LockedUntilUtc = CASE WHEN FailedLogins + 1 >= @Max
                                          THEN DATEADD(MINUTE, @Minutes, SYSUTCDATETIME()) ELSE LockedUntilUtc END
                WHERE AdminId = @AdminId;
                """,
                new { admin.AdminId, Max = options.MaxFailedLogins, Minutes = options.LockoutMinutes },
                cancellationToken: ct));

            logger.LogWarning("Failed console sign-in for {AdminId}.", admin.AdminId);
            return Invalid();
        }

        if (admin.Status != "active")
        {
            return Results.Json(new { code = "admin_suspended", message = "This administrator account is suspended." },
                statusCode: StatusCodes.Status403Forbidden);
        }

        var devCode = options.UseFixedDevOtp && environment.IsDevelopment();
        var code = devCode
            ? options.FixedDevOtp
            : RandomNumberGenerator.GetInt32(0, (int)Math.Pow(10, options.OtpLength)).ToString(new string('0', options.OtpLength));
        var (hash, salt) = hasher.Hash(code);
        var challengeId = Guid.NewGuid().ToString("N");
        var expires = DateTime.UtcNow.AddMinutes(options.OtpValidMinutes);

        await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Admin SET FailedLogins = 0, LockedUntilUtc = NULL WHERE AdminId = @AdminId;

            INSERT INTO ctl.AdminOtp (ChallengeId, AdminId, CodeHash, CodeSalt, ExpiresAtUtc)
            VALUES (@ChallengeId, @AdminId, @Hash, @Salt, @Expires);
            """,
            new { admin.AdminId, ChallengeId = challengeId, Hash = hash, Salt = salt, Expires = expires },
            cancellationToken: ct));

        /* Once an SMS provider is wired in, this is where the code is sent. */
        logger.LogInformation("Console OTP issued for {AdminId}{Dev}.", admin.AdminId,
            devCode ? " (development fixed code)" : "");

        return Results.Ok(new
        {
            otpRequired = true,
            challengeId,
            expiresAtUtc = expires,
            codeLength = options.OtpLength,
            devMode = devCode,
            devCode = devCode ? code : null
        });
    }

    /// <summary>Step two: the code. Issues the console session.</summary>
    private static async Task<IResult> VerifyAsync(
        AdminVerifyRequest request, TenantCatalog catalog, IPasswordHasher hasher,
        IOptions<AuthOptions> authOptions, IOptions<JwtOptions> jwt, SigningKeyProvider key,
        HttpContext http, CancellationToken ct)
    {
        await using var control = catalog.Control();

        var otp = await control.QuerySingleOrDefaultAsync<(string AdminId, string CodeHash, string CodeSalt, DateTime ExpiresAtUtc, int Attempts, DateTime? ConsumedAtUtc)>(
            new CommandDefinition(
                "SELECT AdminId, CodeHash, CodeSalt, ExpiresAtUtc, Attempts, ConsumedAtUtc FROM ctl.AdminOtp WHERE ChallengeId = @ChallengeId;",
                new { request.ChallengeId }, cancellationToken: ct));

        IResult Refuse(string message) => Results.Json(new { code = "otp_invalid", message }, statusCode: 401);

        if (otp.AdminId is null || otp.ConsumedAtUtc is not null) return Refuse("That code is not correct.");
        if (otp.ExpiresAtUtc < DateTime.UtcNow) return Refuse("That code has expired. Sign in again.");
        if (otp.Attempts >= authOptions.Value.OtpMaxAttempts) return Refuse("Too many attempts. Sign in again.");

        await control.ExecuteAsync(new CommandDefinition(
            "UPDATE ctl.AdminOtp SET Attempts = Attempts + 1 WHERE ChallengeId = @ChallengeId;",
            new { request.ChallengeId }, cancellationToken: ct));

        if (!hasher.Verify(request.Code ?? "", otp.CodeHash, otp.CodeSalt)) return Refuse("That code is not correct.");

        var admin = await control.QuerySingleAsync<AdminRow>(new CommandDefinition(
            """
            UPDATE ctl.AdminOtp SET ConsumedAtUtc = SYSUTCDATETIME() WHERE ChallengeId = @ChallengeId;
            UPDATE ctl.Admin SET LastLoginAtUtc = SYSUTCDATETIME() WHERE AdminId = @AdminId;

            SELECT AdminId, Name, Mobile, Role, Permissions, PasswordHash, PasswordSalt, Status,
                   FailedLogins, LockedUntilUtc, SessionVersion, MustChangePassword
            FROM ctl.Admin WHERE AdminId = @AdminId;
            """, new { request.ChallengeId, otp.AdminId }, cancellationToken: ct));

        var minutes = int.TryParse(await control.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT Value FROM ctl.Setting WHERE SettingKey = N'sessionMinutes';", cancellationToken: ct)), out var m) ? m : 60;

        var expires = DateTime.UtcNow.AddMinutes(minutes);
        var claims = new List<Claim>
        {
            new(JwtRegisteredClaimNames.Sub, admin.AdminId),
            new("name", admin.Name),
            new("role", admin.Role),
            new(AdminAuth.ScopeClaim, "superadmin"),
            new(AdminAuth.SessionClaim, admin.SessionVersion.ToString()),
            new(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString("N"))
        };

        var token = new JwtSecurityTokenHandler().WriteToken(new JwtSecurityToken(
            issuer: jwt.Value.Issuer, audience: AdminAuth.Audience, claims: claims,
            notBefore: DateTime.UtcNow, expires: expires,
            signingCredentials: new SigningCredentials(key.Key, SecurityAlgorithms.HmacSha256)));

        await control.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO ctl.AdminAudit (AdminId, AdminName, Action, Label, Method, Endpoint, TableName, Operation, IpAddress)
            VALUES (@AdminId, @Name, N'admin.login', N'Signed in to the console', N'POST', N'/api/superadmin/auth/verify', N'ctl.Admin', N'VIEW', @Ip);
            """, new { admin.AdminId, admin.Name, Ip = http.Connection.RemoteIpAddress?.ToString() }, cancellationToken: ct));

        return Results.Ok(new
        {
            accessToken = token,
            expiresAtUtc = expires,
            name = admin.Name,
            adminId = admin.AdminId,
            role = admin.Role,
            permissions = PermissionList(admin.Permissions),
            mustChangePassword = admin.MustChangePassword
        });
    }

    private static async Task<IResult> MeAsync(CurrentAdmin current, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var admin = await control.QuerySingleOrDefaultAsync<AdminRow>(new CommandDefinition(
            """
            SELECT AdminId, Name, Mobile, Role, Permissions, PasswordHash, PasswordSalt, Status,
                   FailedLogins, LockedUntilUtc, SessionVersion, MustChangePassword
            FROM ctl.Admin WHERE AdminId = @AdminId;
            """, new { current.AdminId }, cancellationToken: ct));

        return admin is null
            ? Results.Unauthorized()
            : Results.Ok(new
            {
                adminId = admin.AdminId, name = admin.Name, mobile = admin.Mobile, role = admin.Role,
                permissions = PermissionList(admin.Permissions), mustChangePassword = admin.MustChangePassword
            });
    }

    private static async Task<IResult> ChangePasswordAsync(
        AdminChangePasswordRequest request, CurrentAdmin current, TenantCatalog catalog,
        IPasswordHasher hasher, AdminSessions sessions, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(request.NewPassword) || request.NewPassword.Length < 8)
            return Results.BadRequest(new { code = "weak_password", message = "Use at least 8 characters." });

        await using var control = catalog.Control();
        var admin = await control.QuerySingleAsync<AdminRow>(new CommandDefinition(
            "SELECT AdminId, PasswordHash, PasswordSalt FROM ctl.Admin WHERE AdminId = @AdminId;",
            new { current.AdminId }, cancellationToken: ct));

        if (!hasher.Verify(request.CurrentPassword ?? "", admin.PasswordHash, admin.PasswordSalt))
            return Results.BadRequest(new { code = "wrong_password", message = "The current password is not correct." });

        var (hash, salt) = hasher.Hash(request.NewPassword);
        await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Admin
            SET PasswordHash = @Hash, PasswordSalt = @Salt, MustChangePassword = 0, SessionVersion = SessionVersion + 1
            WHERE AdminId = @AdminId;
            """, new { Hash = hash, Salt = salt, current.AdminId }, cancellationToken: ct));

        sessions.Evict(current.AdminId);
        return Results.Ok(new { ok = true, message = "Password changed. Sign in again." });
    }

    public static string[]? PermissionList(string? csv) =>
        string.IsNullOrWhiteSpace(csv) ? null
        : csv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private sealed record AdminRow
    {
        public string AdminId { get; init; } = "";
        public string Name { get; init; } = "";
        public string Mobile { get; init; } = "";
        public string Role { get; init; } = "";
        public string? Permissions { get; init; }
        public string PasswordHash { get; init; } = "";
        public string PasswordSalt { get; init; } = "";
        public string Status { get; init; } = "";
        public int FailedLogins { get; init; }
        public DateTime? LockedUntilUtc { get; init; }
        public int SessionVersion { get; init; }
        public bool MustChangePassword { get; init; }
    }
}
