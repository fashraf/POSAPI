using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using Microsoft.Extensions.Options;
using PosApi.Data;
using PosApi.Tenancy;

namespace PosApi.Features.Access;

public sealed record LoginRequest(string Identifier, string? Password);

public sealed record RegistrationOwner(
    string FirstName,
    string LastName,
    string Email,
    string Mobile,
    string? Password);

public sealed record RegistrationBusiness(
    string NameEn,
    string NameAr,
    string? BusinessType,
    string? BusinessCategory,
    string? Country,
    string? City,
    string? District,
    string? Address);

public sealed record RegistrationTax(
    string? CrNumber,
    string? VatNumber,
    string? TaxStartDate,
    bool IsVatRegistered);

public sealed record RegisterRequest(
    RegistrationOwner Owner,
    RegistrationBusiness Business,
    RegistrationTax Tax);
public sealed record OtpRequest(string ChallengeId, string Code);
public sealed record RefreshRequest(string RefreshToken);

public sealed record SessionResponse(
    string AccessToken,
    string RefreshToken,
    DateTime ExpiresAtUtc,
    UserSummary User);

public sealed record UserSummary(
    string UserId,
    string Username,
    string NameAr,
    string NameEn,
    string RoleId,
    IReadOnlyList<string> Permissions,
    IReadOnlyList<string> BranchIds);

public static class AuthEndpoints
{
    public static void MapAuthEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/auth")
            .WithTags("Auth")
            .RequireRateLimiting("auth");

        group.MapPost("/register", RegisterAsync);
        group.MapPost("/login", RequestOtpAsync);
        group.MapPost("/verify", VerifyOtpAsync);
        group.MapPost("/refresh", RefreshAsync);
        group.MapPost("/logout", LogoutAsync).RequireAuthorization();
        group.MapGet("/me", MeAsync).RequireAuthorization();
    }

    /// <summary>
    /// Create a business and its owner.
    ///
    /// One stored procedure call: the company, the branch, its settings and the
    /// owner account are created together. Half of that succeeding leaves an
    /// account nobody can sign in to and nobody can remove from the UI.
    ///
    /// No session is issued here. Registration ends at the OTP step, so an
    /// address nobody controls cannot become a working account.
    /// </summary>
    /* Names the wizard field a refusal belongs to, so the form can take the
       person back to the step that holds it instead of failing silently. */
    private static Dictionary<string, string[]> Field(string field, string message) =>
        new() { [field] = [message] };

    private static async Task<IResult> RegisterAsync(
        RegisterRequest request,
        TenantProvisioner provisioner,
        TenantGate gate,
        IOtpService otp,
        IPasswordHasher hasher,
        IOptions<AuthOptions> authOptions,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        var fieldErrors = new Dictionary<string, string[]>();

        if (string.IsNullOrWhiteSpace(request.Business.NameAr))
            fieldErrors["business.nameAr"] = ["The Arabic business name is required."];

        if (string.IsNullOrWhiteSpace(request.Business.NameEn))
            fieldErrors["business.nameEn"] = ["The English business name is required."];

        if (string.IsNullOrWhiteSpace(request.Owner.Email))
            fieldErrors["owner.email"] = ["An email address is required."];

        /* In single-password mode the password is the only way in, so an owner
           registered without one would be locked out of their own business. */
        var password = request.Owner.Password;
        if (string.IsNullOrEmpty(password))
        {
            if (authOptions.Value.LoginMode == LoginMode.SinglePassword)
                fieldErrors["owner.password"] = ["A password is required."];
        }
        else if (password.Length < 8)
        {
            fieldErrors["owner.password"] = ["The password needs at least 8 characters."];
        }

        if (fieldErrors.Count > 0)
        {
            return Results.BadRequest(ApiError.Create(
                "validation_failed",
                "Some details are missing.",
                "بعض البيانات ناقصة.",
                fieldErrors));
        }

        var ownerName = $"{request.Owner.FirstName} {request.Owner.LastName}".Trim();

        string? hash = null, salt = null;
        if (!string.IsNullOrEmpty(password))
            (hash, salt) = hasher.Hash(password);

        /*
         * A new business is a new tenant: its own database, a free trial, and
         * its owner in the login directory. The provisioner does all of it or
         * none of it, so a failed sign-up leaves nothing behind.
         */
        ProvisionResult provisioned;
        try
        {
            provisioned = await provisioner.ProvisionAsync(new ProvisionRequest
            {
                Name = request.Business.NameEn.Trim(),
                NameAr = request.Business.NameAr.Trim(),
                BusinessType = request.Business.BusinessType,
                City = request.Business.City,
                Country = request.Business.Country,
                CrNumber = request.Tax.IsVatRegistered ? request.Tax.CrNumber : null,
                VatNumber = request.Tax.IsVatRegistered ? request.Tax.VatNumber : null,
                Email = request.Owner.Email.Trim(),
                Phone = string.IsNullOrWhiteSpace(request.Owner.Mobile) ? null : request.Owner.Mobile.Trim(),
                OwnerName = ownerName,
                OwnerEmail = request.Owner.Email.Trim(),
                OwnerPhone = string.IsNullOrWhiteSpace(request.Owner.Mobile) ? null : request.Owner.Mobile.Trim(),
                OwnerPasswordHash = hash,
                OwnerPasswordSalt = salt,
                BranchName = request.Business.NameEn.Trim(),
                BranchAddress = request.Business.Address,
                PlanKey = "Trial",
                Trial = true,
                Source = "self-signup",
                RegisteredBy = ownerName
            }, ct);
        }
        catch (ProvisionException ex)
        {
            var field = ex.Field switch { "mobile" => "mobile", "vatNumber" => "vatNumber", "username" or "email" => "email", _ => null };
            return Results.Json(ApiError.Create(ex.Code, ex.Message, ex.MessageAr,
                field is null ? null : Field(field, ex.Message)), statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        var userId = provisioned.OwnerUserId;
        logger.LogInformation("Business registered as tenant {TenantId}, owner {UserId}.", provisioned.TenantId, userId);

        if (await gate.EnterAsync(provisioned.TenantId, ct) is { } refused) return refused;

        var challenge = await otp.IssueAsync(request.Owner.Email.Trim(), "register", ct);

        return Results.Ok(new
        {
            userId,
            branchId = provisioned.BranchId,
            tenantId = provisioned.TenantId,
            challengeId = challenge.ChallengeId,
            expiresAtUtc = challenge.ExpiresAtUtc,
            devMode = challenge.IsDevCode
        });
    }

    /// <summary>
    /// Step one.
    ///
    /// In two-step mode this sends a code. In single-step mode it verifies a
    /// password and returns tokens directly. Which one runs is configuration,
    /// so switching back is a settings change rather than a code change.
    ///
    /// In both modes the response is deliberately the same whether or not the
    /// account exists. Saying "no such user" turns the login form into a tool
    /// for discovering which addresses are registered.
    /// </summary>
    private static async Task<IResult> RequestOtpAsync(
        LoginRequest request,
        ISqlConnectionFactory db,
        LoginDirectory directory,
        TenantGate gate,
        IOtpService otp,
        IPasswordHasher hasher,
        IJwtTokenService tokens,
        IOptions<AuthOptions> authOptions,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Identifier))
        {
            return Results.BadRequest(ApiError.Create(
                "identifier_required",
                "Enter your email or mobile number.",
                "أدخل بريدك الإلكتروني أو رقم جوالك."));
        }

        var identifier = request.Identifier.Trim();

        /* Which business this identifier belongs to. Unknown is answered
           exactly like a wrong password, so the form cannot be used to find
           out which addresses are registered on the platform. */
        var tenantId = await directory.FindTenantAsync(identifier, ct);

        if (tenantId is null)
        {
            logger.LogInformation("Sign-in for an identifier no tenant holds.");

            if (authOptions.Value.LoginMode == LoginMode.SinglePassword)
                return await SignInWithPasswordAsync(null!, hasher, tokens, gate, null, request.Password, logger, ct);

            return Results.Ok(new
            {
                challengeId = Guid.NewGuid().ToString("N"),
                expiresAtUtc = DateTime.UtcNow.AddMinutes(authOptions.Value.OtpValidMinutes),
                devMode = false
            });
        }

        /* Not enforced yet: a suspended business is told so only after the
           password (or code) proves the caller is one of its people. */
        if (await gate.EnterAsync(tenantId, ct, enforce: false) is { } unknown) return unknown;

        await using var connection = db.Create();

        var user = await connection.QuerySingleOrDefaultAsync<AuthUserRow>(new CommandDefinition(
            """
            SELECT UserId, Username, NameAr, NameEn, RoleId, Status, AccessExpiresOn,
                   PasswordHash, PasswordSalt
            FROM core.AppUser
            WHERE Email = @Identifier OR Phone = @Identifier OR Username = @Identifier;
            """,
            new { Identifier = identifier },
            cancellationToken: ct));

        if (authOptions.Value.LoginMode == LoginMode.SinglePassword)
        {
            return await SignInWithPasswordAsync(
                connection, hasher, tokens, gate, user, request.Password, logger, ct);
        }

        /*----------------------------------------------- two-step: send a code */

        var challenge = await otp.IssueAsync(identifier, "login", ct);

        if (user is null)
        {
            logger.LogInformation("OTP requested for an unknown identifier.");
        }

        return Results.Ok(new
        {
            challengeId = challenge.ChallengeId,
            expiresAtUtc = challenge.ExpiresAtUtc,
            devMode = challenge.IsDevCode
        });
    }

    /// <summary>
    /// Single-step sign-in: a real password check, then tokens.
    ///
    /// This skips the second factor, not the first. The password is verified
    /// against the stored PBKDF2 hash exactly as it would be anywhere else, and
    /// an account with no password set cannot sign in this way at all — which
    /// is what stops a production database, where those hashes are NULL, from
    /// quietly accepting anyone should this mode ever be switched on there.
    /// </summary>
    private static async Task<IResult> SignInWithPasswordAsync(
        System.Data.Common.DbConnection connection,
        IPasswordHasher hasher,
        IJwtTokenService tokens,
        TenantGate gate,
        AuthUserRow? user,
        string? password,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(password))
        {
            return Results.BadRequest(ApiError.Create(
                "password_required", "Enter your password.", "أدخل كلمة المرور."));
        }

        /* One message for "no such account" and "wrong password" alike. */
        var invalid = Results.Json(ApiError.Create(
            "invalid_credentials",
            "That email or password is not correct.",
            "البريد الإلكتروني أو كلمة المرور غير صحيحة."), statusCode: 401);

        if (user is null || string.IsNullOrWhiteSpace(user.PasswordHash)
                         || string.IsNullOrWhiteSpace(user.PasswordSalt))
        {
            /* Spend roughly the time a real verification costs, so a reply does
               not arrive noticeably sooner for an account that does not exist. */
            hasher.Verify(password,
                "pbkdf2$210000$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "AAAAAAAAAAAAAAAAAAAAAA==");

            logger.LogInformation("Failed sign-in: unknown account or no password set.");
            return invalid;
        }

        if (!hasher.Verify(password, user.PasswordHash, user.PasswordSalt))
        {
            logger.LogInformation("Failed sign-in for {UserId}.", user.UserId);
            return invalid;
        }

        if (RejectIfUnusable(user) is { } rejected) return rejected;

        if (TenantCatalog.Refusal(gate.Current) is { } tenantRefusal)
            return Results.Json(tenantRefusal, statusCode: StatusCodes.Status403Forbidden);

        var permissions = (await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT PermissionKey FROM core.vw_EffectivePermission WHERE UserId = @UserId;",
            new { user.UserId }, cancellationToken: ct))).ToList();

        var branches = (await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT BranchId FROM core.UserBranch WHERE UserId = @UserId;",
            new { user.UserId }, cancellationToken: ct))).ToList();

        logger.LogWarning(
            "Single-step password sign-in for {UserId}. The second factor was skipped.",
            user.UserId);

        return Results.Ok(await IssueSessionAsync(connection, tokens, gate.Current.TenantId, user, permissions, branches, ct));
    }

    /// <summary>Step two: verify the code and issue a session.</summary>
    private static async Task<IResult> VerifyOtpAsync(
        OtpRequest request,
        ISqlConnectionFactory db,
        TenantGate gate,
        IOtpService otp,
        IJwtTokenService tokens,
        CancellationToken ct)
    {
        /* A challenge for an identifier no tenant holds was never stored; it
           has no prefix and fails here like any wrong code. */
        if (await gate.EnterAsync(TenantKey.TenantOf(request.ChallengeId), ct) is { } refused) return refused;

        var result = await otp.VerifyAsync(request.ChallengeId, request.Code, ct);

        if (result != OtpResult.Valid)
        {
            var (code, en, ar) = result switch
            {
                OtpResult.Expired => ("otp_expired",
                    "That code has expired. Request a new one.",
                    "انتهت صلاحية الرمز. اطلب رمزًا جديدًا."),
                OtpResult.TooManyAttempts => ("otp_attempts",
                    "Too many attempts. Request a new code.",
                    "محاولات كثيرة. اطلب رمزًا جديدًا."),
                _ => ("otp_invalid",
                    "That code is not correct.",
                    "الرمز غير صحيح.")
            };

            return Results.Json(ApiError.Create(code, en, ar), statusCode: 401);
        }

        await using var connection = db.Create();

        var identifier = await connection.QuerySingleOrDefaultAsync<string>(new CommandDefinition(
            "SELECT Identifier FROM core.OtpChallenge WHERE ChallengeId = @ChallengeId;",
            new { request.ChallengeId },
            cancellationToken: ct));

        if (identifier is null) return Results.Unauthorized();

        var user = await connection.QuerySingleOrDefaultAsync<AuthUserRow>(new CommandDefinition(
            """
            SELECT UserId, Username, NameAr, NameEn, RoleId, Status, AccessExpiresOn
            FROM core.AppUser
            WHERE Email = @Identifier OR Phone = @Identifier OR Username = @Identifier;
            """,
            new { Identifier = identifier },
            cancellationToken: ct));

        if (user is null) return Results.Unauthorized();

        if (!string.Equals(user.Status, "active", StringComparison.OrdinalIgnoreCase))
        {
            return Results.Json(ApiError.Create(
                "account_suspended",
                "This account is not active. Speak to your manager.",
                "هذا الحساب غير نشط. راجع مديرك."), statusCode: 403);
        }

        // External accounts carry an expiry so a maintenance login does not
        // outlive the job it was created for.
        if (user.AccessExpiresOn is { } expires && expires < DateOnly.FromDateTime(DateTime.UtcNow))
        {
            return Results.Json(ApiError.Create(
                "account_expired",
                "Access for this account has expired.",
                "انتهت صلاحية الوصول لهذا الحساب."), statusCode: 403);
        }

        var permissions = (await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT PermissionKey FROM core.vw_EffectivePermission WHERE UserId = @UserId;",
            new { user.UserId }, cancellationToken: ct))).ToList();

        var branches = (await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT BranchId FROM core.UserBranch WHERE UserId = @UserId;",
            new { user.UserId }, cancellationToken: ct))).ToList();

        return Results.Ok(await IssueSessionAsync(connection, tokens, gate.Current.TenantId, user, permissions, branches, ct));
    }

    /// <summary>
    /// Mint a session and record the refresh token.
    ///
    /// Both login flows end here, so the response shape is identical whichever
    /// route the caller took and the frontend needs no branch of its own.
    /// </summary>
    private static async Task<SessionResponse> IssueSessionAsync(
        System.Data.Common.DbConnection connection,
        IJwtTokenService tokens,
        string tenantId,
        AuthUserRow user,
        IReadOnlyList<string> permissions,
        IReadOnlyList<string> branches,
        CancellationToken ct)
    {
        var pair = tokens.Issue(tenantId, user.UserId, user.Username, user.RoleId, permissions, branches);

        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO core.RefreshToken (TokenHash, UserId, ExpiresAtUtc)
            VALUES (@TokenHash, @UserId, @ExpiresAtUtc);

            UPDATE core.AppUser SET LastLoginAtUtc = SYSUTCDATETIME() WHERE UserId = @UserId;
            """,
            new
            {
                TokenHash = tokens.HashRefreshToken(pair.RefreshToken),
                user.UserId,
                ExpiresAtUtc = pair.RefreshExpiresAtUtc
            },
            cancellationToken: ct));

        return new SessionResponse(
            pair.AccessToken,
            pair.RefreshToken,
            pair.AccessExpiresAtUtc,
            new UserSummary(user.UserId, user.Username, user.NameAr, user.NameEn,
                            user.RoleId, permissions, branches));
    }

    /// <summary>
    /// Whether the account may sign in at all, whichever flow is in use.
    /// </summary>
    private static IResult? RejectIfUnusable(AuthUserRow user)
    {
        if (!string.Equals(user.Status, "active", StringComparison.OrdinalIgnoreCase))
        {
            return Results.Json(ApiError.Create(
                "account_suspended",
                "This account is not active. Speak to your manager.",
                "هذا الحساب غير نشط. راجع مديرك."), statusCode: 403);
        }

        if (user.AccessExpiresOn is { } expires && expires < DateOnly.FromDateTime(DateTime.UtcNow))
        {
            return Results.Json(ApiError.Create(
                "account_expired",
                "Access for this account has expired.",
                "انتهت صلاحية الوصول لهذا الحساب."), statusCode: 403);
        }

        return null;
    }

    private static async Task<IResult> RefreshAsync(
        RefreshRequest request,
        ISqlConnectionFactory db,
        TenantGate gate,
        IJwtTokenService tokens,
        CancellationToken ct)
    {
        /* Suspension and expiry are enforced here too: a refresh token is
           how a session outlives its access token. */
        if (await gate.EnterAsync(TenantKey.TenantOf(request.RefreshToken), ct) is { } refused) return refused;

        var hash = tokens.HashRefreshToken(request.RefreshToken);

        await using var connection = db.Create();

        var userId = await connection.QuerySingleOrDefaultAsync<string>(new CommandDefinition(
            """
            SELECT UserId FROM core.RefreshToken
            WHERE TokenHash = @Hash
              AND RevokedAtUtc IS NULL
              AND ExpiresAtUtc > SYSUTCDATETIME();
            """,
            new { Hash = hash },
            cancellationToken: ct));

        if (userId is null) return Results.Unauthorized();

        var user = await connection.QuerySingleAsync<AuthUserRow>(new CommandDefinition(
            "SELECT UserId, Username, NameAr, NameEn, RoleId, Status, AccessExpiresOn FROM core.AppUser WHERE UserId = @UserId;",
            new { UserId = userId }, cancellationToken: ct));

        if (!string.Equals(user.Status, "active", StringComparison.OrdinalIgnoreCase))
        {
            return Results.Unauthorized();
        }

        var permissions = (await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT PermissionKey FROM core.vw_EffectivePermission WHERE UserId = @UserId;",
            new { UserId = userId }, cancellationToken: ct))).ToList();

        var branches = (await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT BranchId FROM core.UserBranch WHERE UserId = @UserId;",
            new { UserId = userId }, cancellationToken: ct))).ToList();

        var pair = tokens.Issue(gate.Current.TenantId, user.UserId, user.Username, user.RoleId, permissions, branches);

        // Rotate: the old token is revoked as the new one is issued, so a
        // stolen refresh token is usable at most once before it stops working.
        await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE core.RefreshToken SET RevokedAtUtc = SYSUTCDATETIME() WHERE TokenHash = @OldHash;

            INSERT INTO core.RefreshToken (TokenHash, UserId, ExpiresAtUtc)
            VALUES (@NewHash, @UserId, @ExpiresAtUtc);
            """,
            new
            {
                OldHash = hash,
                NewHash = tokens.HashRefreshToken(pair.RefreshToken),
                UserId = userId,
                ExpiresAtUtc = pair.RefreshExpiresAtUtc
            },
            cancellationToken: ct));

        return Results.Ok(new SessionResponse(
            pair.AccessToken, pair.RefreshToken, pair.AccessExpiresAtUtc,
            new UserSummary(user.UserId, user.Username, user.NameAr, user.NameEn,
                            user.RoleId, permissions, branches)));
    }

    private static async Task<IResult> LogoutAsync(
        RefreshRequest request,
        ISqlConnectionFactory db,
        IJwtTokenService tokens,
        CancellationToken ct)
    {
        await using var connection = db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            "UPDATE core.RefreshToken SET RevokedAtUtc = SYSUTCDATETIME() WHERE TokenHash = @Hash;",
            new { Hash = tokens.HashRefreshToken(request.RefreshToken) },
            cancellationToken: ct));

        return Results.NoContent();
    }

    private static async Task<IResult> MeAsync(
        ICurrentUser current,
        ISqlConnectionFactory db,
        CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var user = await connection.QuerySingleOrDefaultAsync<AuthUserRow>(new CommandDefinition(
            "SELECT UserId, Username, NameAr, NameEn, RoleId, Status, AccessExpiresOn FROM core.AppUser WHERE UserId = @UserId;",
            new { current.UserId }, cancellationToken: ct));

        if (user is null) return Results.Unauthorized();

        return Results.Ok(new UserSummary(
            user.UserId, user.Username, user.NameAr, user.NameEn, user.RoleId,
            current.Permissions.ToList(), current.BranchIds.ToList()));
    }

    private sealed record AuthUserRow
    {
        public string UserId { get; init; } = string.Empty;
        public string Username { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string RoleId { get; init; } = string.Empty;
        public string Status { get; init; } = string.Empty;
        public DateOnly? AccessExpiresOn { get; init; }
        public string? PasswordHash { get; init; }
        public string? PasswordSalt { get; init; }
    }
}
