using System.Data;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Tenancy;
using PosApi.Localization;

namespace PosApi.Features.Access;

/// <summary>
/// A staff account as the user screen shows it.
///
/// Status is "invited" for an active account that has never signed in — the
/// database only knows active/suspended/expired, and "has this person ever
/// actually used it" is the question the screen is asking.
/// </summary>
public sealed record UserDto(
    string Id,
    string Username,
    string FirstName,
    string LastName,
    string NameAr,
    string NameEn,
    string Email,
    string Phone,
    string Address,
    string EmployeeId,
    string? AvatarUrl,
    string RoleId,
    string RoleNameAr,
    string RoleNameEn,
    string? DefaultBranchId,
    IReadOnlyList<string> BranchIds,
    string Status,
    IReadOnlyList<string> ExtraPermissions,
    IReadOnlyList<string> DeniedPermissions,
    DateTime? LastActiveAt,
    DateOnly? AccessExpiresAt,
    string? TicketReference,
    bool IsExternal,
    long BaseSalaryH,
    bool HasPassword,
    DateTime CreatedAt,
    DateTime UpdatedAt);

/// <summary>
/// Create or edit an account.
///
/// Password is optional. Given, it is hashed here with the same hasher sign-in
/// verifies against, and never stored or logged in clear. Left out on create,
/// the account has no password and can only sign in through the one-time-code
/// flow; left out on edit, the current password stays.
/// </summary>
public sealed record SaveUserRequest(
    string Username,
    string? FirstName,
    string? LastName,
    string NameAr,
    string? NameEn,
    string? Email,
    string? Phone,
    string? Address,
    string? EmployeeId,
    string RoleId,
    string? DefaultBranchId,
    IReadOnlyList<string>? BranchIds,
    string? Status,
    IReadOnlyList<string>? ExtraPermissions,
    IReadOnlyList<string>? DeniedPermissions,
    DateTime? AccessExpiresAt,
    string? TicketReference,
    long? BaseSalaryH,
    string? Password);

public sealed record SetUserStatusRequest(string Status);

public sealed record RoleDto(
    string Id,
    string Kind,
    string NameAr,
    string NameEn,
    string Name,
    string? DescriptionAr,
    string? DescriptionEn,
    string Description,
    IReadOnlyList<string> Permissions,
    string Status,
    bool BuiltIn,
    bool External,
    int UserCount,
    DateTime CreatedAt,
    DateTime UpdatedAt);

/// <summary>
/// Create or edit a role. <c>Description</c> fills whichever language column is
/// not given separately, because the screen has one description box.
/// <c>External</c> is read on create only: turning a role external after the
/// fact would leave its holders breaking the rule on the day it changed.
/// </summary>
public sealed record SaveRoleRequest(
    string NameAr,
    string NameEn,
    string? Description,
    string? DescriptionAr,
    string? DescriptionEn,
    IReadOnlyList<string>? Permissions,
    string? Status,
    bool External);

public static partial class UserEndpoints
{
    public static void MapUserEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/users")
            .WithTags("Users")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("users.view"));

        group.MapGet("/{userId}", GetAsync)
             .RequireAuthorization(PermissionPolicy.For("users.view"));

        group.MapPost("", CreateAsync)
             .RequireAuthorization(PermissionPolicy.For("users.create"));

        group.MapPut("/{userId}", UpdateAsync)
             .RequireAuthorization(PermissionPolicy.For("users.edit"));

        group.MapPatch("/{userId}/status", SetStatusAsync)
             .RequireAuthorization(PermissionPolicy.For("users.disable"));

        group.MapPost("/{userId}/revoke-access", RevokeAccessAsync)
             .RequireAuthorization(PermissionPolicy.For("users.disable"));

        group.MapGet("/roles", RolesAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.view"));

        group.MapGet("/roles/usage", RoleUsageAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.view"));

        group.MapGet("/roles/{roleId}", RoleAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.view"));

        group.MapPost("/roles", CreateRoleAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.create"));

        group.MapPut("/roles/{roleId}", UpdateRoleAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.edit"));

        group.MapDelete("/roles/{roleId}", DeleteRoleAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.delete"));

        group.MapGet("/permissions", PermissionsAsync)
             .RequireAuthorization(PermissionPolicy.For("roles.view"));
    }

    [GeneratedRegex("^[a-z0-9._-]{3,}$")]
    private static partial Regex UsernamePattern();

    [GeneratedRegex(@"^[^\s@]+@[^\s@]+\.[^\s@]+$")]
    private static partial Regex EmailPattern();

    /*=================================================================== users */

    /// <summary>
    /// Staff.
    ///
    /// Password hashes are never selected — only whether one exists. A field
    /// that is never read cannot be leaked by a logging change or a
    /// serialisation mistake later.
    /// </summary>
    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, string? search, bool? activeOnly, CancellationToken ct)
    {
        await using var connection = db.Create();

        var users = await LoadUsersAsync(connection, null,
            string.IsNullOrWhiteSpace(search) ? null : search.Trim(), activeOnly ?? false, ct);

        return Results.Ok(users);
    }

    private static async Task<IResult> GetAsync(
        string userId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var user = (await LoadUsersAsync(connection, userId, null, false, ct)).SingleOrDefault();

        return user is null
            ? ProcErrors.NotFound("No such user.", "لا يوجد مستخدم بهذا المعرف.")
            : Results.Ok(user);
    }

    private static Task<IResult> CreateAsync(
        SaveUserRequest request, ISqlConnectionFactory db, ICurrentUser current,
        IPasswordHasher hasher, LoginDirectory directory, ITenantContext tenant,
        HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveUserAsync(null, request, db, current, hasher, directory, tenant, http, logger, ct);

    private static Task<IResult> UpdateAsync(
        string userId, SaveUserRequest request, ISqlConnectionFactory db, ICurrentUser current,
        IPasswordHasher hasher, LoginDirectory directory, ITenantContext tenant,
        HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveUserAsync(userId, request, db, current, hasher, directory, tenant, http, logger, ct);

    /// <summary>
    /// Both create and edit go through core.usp_SaveUser, which writes the
    /// account, its branches and its overrides in one transaction.
    ///
    /// Three checks happen here rather than in SQL, because they are about the
    /// caller rather than the data:
    ///   - nobody hands out a permission they do not hold themselves, through a
    ///     role or a grant — otherwise users.edit is a path to everything;
    ///   - nobody edits an account that can do more than they can;
    ///   - changing someone's branches or overrides needs users.assign_branches
    ///     or users.override, the keys that already exist for exactly that.
    /// </summary>
    private static async Task<IResult> SaveUserAsync(
        string? userId,
        SaveUserRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        IPasswordHasher hasher,
        LoginDirectory directory,
        ITenantContext tenant,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        var username = (request.Username ?? string.Empty).Trim().ToLowerInvariant();
        var email = ProcErrors.Blank(request.Email)?.ToLowerInvariant();
        var branchIds = (request.BranchIds ?? []).Select(b => b.Trim()).Where(b => b.Length > 0)
                                                 .Distinct().ToList();
        var grants = (request.ExtraPermissions ?? []).Distinct().ToList();
        var denies = (request.DeniedPermissions ?? []).Distinct().ToList();

        var fieldErrors = new Dictionary<string, string[]>();

        if (!UsernamePattern().IsMatch(username))
            fieldErrors["username"] = ["At least 3 characters: letters, numbers, dot, dash, or underscore."];

        if (email is not null && !EmailPattern().IsMatch(email))
            fieldErrors["email"] = ["Enter a valid email address."];

        if (string.IsNullOrWhiteSpace(request.NameAr))
            fieldErrors["nameAr"] = ["Arabic name is required."];

        /* Required on create; on edit, blank keeps the current one. */
        if (userId is null && string.IsNullOrEmpty(request.Password))
        {
            /* Allowed: an account with no password signs in by one-time code. */
        }
        else if (!string.IsNullOrEmpty(request.Password) && request.Password.Length < 8)
        {
            fieldErrors["password"] = ["Use at least 8 characters."];
        }

        if (request.Status is not (null or "active" or "suspended" or "invited"))
            fieldErrors["status"] = ["Status must be active or suspended."];

        if (fieldErrors.Count > 0)
        {
            return Results.UnprocessableEntity(ApiError.Create(
                "validation_failed", "Some details need correcting.", "بعض البيانات تحتاج إلى تصحيح.",
                fieldErrors));
        }

        var nameEn = ProcErrors.Blank(request.NameEn)
                     ?? ProcErrors.Blank($"{request.FirstName} {request.LastName}")
                     ?? username;

        /* Sign-in identifiers are unique across the whole platform — the login
           directory is how sign-in finds a business — so another business's
           "ahmed" is as taken as this one's. */
        var tenantId = tenant.Tenant!.TenantId;
        var taken = await directory.FirstTakenAsync(tenantId, userId, [username, email, request.Phone], ct);
        if (taken is not null)
        {
            var field = taken == username ? "username" : taken == email ? "email" : "phone";
            return ProcErrors.Field(field,
                $"'{taken}' is already used by another account on the platform.",
                $"'{taken}' مستخدم لحساب آخر على المنصة.");
        }

        await using var connection = db.Create();

        /* The plan's user limit, counted on active accounts. */
        if (userId is null && tenant.Tenant.MaxUsers is { } maxUsers)
        {
            var activeUsers = await connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM core.AppUser WHERE Status = N'active';", cancellationToken: ct));

            if (activeUsers >= maxUsers)
            {
                return ProcErrors.Conflict("plan_limit_users",
                    $"Your plan allows {maxUsers} active users. Upgrade the plan or suspend someone first.",
                    $"باقتك تسمح بـ {maxUsers} مستخدمين نشطين. رقِّ الباقة أو أوقف مستخدمًا أولًا.");
            }
        }

        /*---------------------------------------------- checks about the caller */

        var rolePermissions = (await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT PermissionKey FROM core.RolePermission WHERE RoleId = @RoleId;",
            new { request.RoleId }, cancellationToken: ct))).ToList();

        if (rolePermissions.Concat(grants).FirstOrDefault(p => !current.Can(p)) is { } beyond)
        {
            return ProcErrors.Forbidden("exceeds_own_permissions",
                $"You cannot give someone a permission you do not hold yourself ({beyond}).",
                $"لا يمكنك منح صلاحية لا تملكها ({beyond}).");
        }

        if (userId is null)
        {
            if ((grants.Count > 0 || denies.Count > 0) && !current.Can("users.override"))
                return OverrideForbidden();

            if (branchIds.FirstOrDefault(b => !current.CanSeeBranch(b)) is not null
                && !current.Can("users.assign_branches"))
                return BranchesForbidden();
        }
        else
        {
            if (await OutranksCallerAsync(connection, userId, current, ct))
                return OutranksForbidden();

            var existingBranches = (await connection.QueryAsync<string>(new CommandDefinition(
                "SELECT BranchId FROM core.UserBranch WHERE UserId = @UserId;",
                new { UserId = userId }, cancellationToken: ct))).ToHashSet(StringComparer.OrdinalIgnoreCase);

            if (!existingBranches.SetEquals(branchIds) && !current.Can("users.assign_branches"))
                return BranchesForbidden();

            var existingOverrides = (await connection.QueryAsync<(string PermissionKey, string Effect)>(
                new CommandDefinition(
                    "SELECT PermissionKey, Effect FROM core.UserPermissionOverride WHERE UserId = @UserId;",
                    new { UserId = userId }, cancellationToken: ct))).ToList();

            var sameGrants = existingOverrides.Where(o => o.Effect == "grant").Select(o => o.PermissionKey)
                                              .ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(grants);
            var sameDenies = existingOverrides.Where(o => o.Effect == "deny").Select(o => o.PermissionKey)
                                              .ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(denies);

            if (!(sameGrants && sameDenies) && !current.Can("users.override"))
                return OverrideForbidden();
        }

        /*------------------------------------------------------------- save */

        string? hash = null, salt = null;
        if (!string.IsNullOrEmpty(request.Password))
            (hash, salt) = hasher.Hash(request.Password);

        var parameters = new DynamicParameters();
        parameters.Add("@UserId", userId);
        parameters.Add("@Username", username);
        parameters.Add("@FirstName", ProcErrors.Blank(request.FirstName));
        parameters.Add("@LastName", ProcErrors.Blank(request.LastName));
        parameters.Add("@NameAr", request.NameAr.Trim());
        parameters.Add("@NameEn", nameEn);
        parameters.Add("@Email", email);
        parameters.Add("@Phone", ProcErrors.Blank(request.Phone));
        parameters.Add("@Address", ProcErrors.Blank(request.Address));
        parameters.Add("@EmployeeId", ProcErrors.Blank(request.EmployeeId));
        parameters.Add("@RoleId", request.RoleId);
        /* "invited" is how the screen shows an account nobody has used yet;
           stored, it is simply active. */
        parameters.Add("@Status", request.Status is "suspended" ? "suspended" : "active");
        parameters.Add("@AccessExpiresOn",
            request.AccessExpiresAt is { } expires ? DateOnly.FromDateTime(expires) : (DateOnly?)null);
        parameters.Add("@TicketReference", ProcErrors.Blank(request.TicketReference));
        parameters.Add("@BaseSalaryH", request.BaseSalaryH);
        parameters.Add("@BranchIds", ProcErrors.Csv(branchIds));
        parameters.Add("@DefaultBranchId", ProcErrors.Blank(request.DefaultBranchId));
        parameters.Add("@Grants", ProcErrors.Csv(grants));
        parameters.Add("@Denies", ProcErrors.Csv(denies));
        parameters.Add("@PasswordHash", hash);
        parameters.Add("@PasswordSalt", salt);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SaveUser", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapUserError(ex) is { } mapped)
        {
            return mapped;
        }

        var savedId = parameters.Get<string>("@SavedId");

        await directory.SyncUserAsync(tenantId, connection, savedId, ct);

        /* Never the password, never the hash: the id and who did it. */
        logger.LogInformation("User {UserId} {Action} by {Actor}.",
            savedId, userId is null ? "created" : "updated", current.Username);

        http.Items["AuditEntityId"] = savedId;

        var user = (await LoadUsersAsync(connection, savedId, null, false, ct)).Single();

        return userId is null
            ? Results.Created($"/api/users/{savedId}", user)
            : Results.Ok(user);
    }

    /// <summary>
    /// Suspend or reactivate.
    ///
    /// Suspending rather than deleting keeps the account as the actor on every
    /// sale and audit row it produced.
    /// </summary>
    private static Task<IResult> SetStatusAsync(
        string userId, SetUserStatusRequest request, ISqlConnectionFactory db,
        ICurrentUser current, HttpContext http, CancellationToken ct) =>
        ChangeStatusAsync(userId, request.Status, revoke: false, db, current, http, ct);

    /// <summary>
    /// End an account's access now, ahead of its expiry date. Meant for the
    /// maintenance vendor once the job is done; it suspends the account and
    /// sets the expiry to today, so reactivating it later is a deliberate act
    /// that also needs a new end date.
    /// </summary>
    private static Task<IResult> RevokeAccessAsync(
        string userId, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, CancellationToken ct) =>
        ChangeStatusAsync(userId, "suspended", revoke: true, db, current, http, ct);

    private static async Task<IResult> ChangeStatusAsync(
        string userId, string? status, bool revoke, ISqlConnectionFactory db,
        ICurrentUser current, HttpContext http, CancellationToken ct)
    {
        if (status is not ("active" or "suspended"))
            return ProcErrors.Field("status", "Status must be active or suspended.", "الحالة إما نشط أو موقوف.");

        /* Locking yourself out is never what was meant, and nobody may be
           left to undo it. */
        if (status != "active" && string.Equals(userId, current.UserId, StringComparison.OrdinalIgnoreCase))
        {
            return ProcErrors.Conflict("cannot_suspend_self",
                "You cannot suspend your own account.", "لا يمكنك إيقاف حسابك.");
        }

        await using var connection = db.Create();

        if (await OutranksCallerAsync(connection, userId, current, ct))
            return OutranksForbidden();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SetUserStatus",
                new { UserId = userId, Status = status, RevokeAccess = revoke, Actor = current.Username },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapUserError(ex) is { } mapped)
        {
            return mapped;
        }

        http.Items["AuditEntityId"] = userId;
        http.Items["AuditNewValue"] = revoke ? "access revoked" : status;

        var user = (await LoadUsersAsync(connection, userId, null, false, ct)).Single();
        return Results.Ok(user);
    }

    private static IResult? MapUserError(SqlException ex) => ex.Number switch
    {
        61010 => ProcErrors.NotFound("No such user.", "لا يوجد مستخدم بهذا المعرف."),
        61009 => ProcErrors.Conflict("last_owner",
            "This is the only active owner. Appoint another first.",
            "هذا هو المالك النشط الوحيد. عيّن مالكًا آخر أولًا."),
        61000 => ProcErrors.Field("username", "A username is required.", "اسم المستخدم مطلوب."),
        61001 => ProcErrors.Field("username", "Another user already has this username.", "اسم المستخدم مستخدم من قبل."),
        61002 => ProcErrors.Field("email", "Another user already uses this email.", "البريد الإلكتروني مستخدم لحساب آخر."),
        61003 => ProcErrors.Field("phone", "That mobile number is already used by another account.", "رقم الجوال مستخدم لحساب آخر."),
        61004 => ProcErrors.Field("roleId", "Choose a role.", "اختر دورًا."),
        61005 => ProcErrors.Field("roleId", "That role is inactive.", "هذا الدور غير نشط."),
        61006 => ProcErrors.Field("accessExpiresAt", "A maintenance account needs an end date.", "حساب الصيانة يحتاج إلى تاريخ انتهاء."),
        61007 => ProcErrors.Field("ticketReference", "Record the ticket that justifies this access.", "سجّل رقم التذكرة التي تبرر هذا الوصول."),
        61008 => ProcErrors.Field("extraPermissions",
            "A maintenance account cannot hold financial or customer permissions.",
            "لا يمكن لحساب الصيانة امتلاك صلاحيات مالية أو بيانات العملاء."),
        61011 => ProcErrors.Field("branchIds", "Assign at least one branch.", "عيّن فرعًا واحدًا على الأقل."),
        61012 => ProcErrors.Field("branchIds", "One of those branches does not exist.", "أحد هذه الفروع غير موجود."),
        61013 => ProcErrors.Field("defaultBranchId",
            "The default branch must be one of the assigned branches.",
            "يجب أن يكون الفرع الافتراضي من الفروع المعيّنة."),
        61014 => ProcErrors.Field("extraPermissions", "One of those permissions does not exist.", "إحدى هذه الصلاحيات غير موجودة."),
        61015 => ProcErrors.Field("deniedPermissions",
            "A permission cannot be granted and denied at once.", "لا يمكن منح صلاحية ومنعها في الوقت نفسه."),
        61016 => ProcErrors.Field("deniedPermissions",
            "An owner cannot be denied user management.", "لا يمكن منع المالك من إدارة المستخدمين."),
        61017 => ProcErrors.Field("nameEn", "Both names are required.", "الاسمان العربي والإنجليزي مطلوبان."),
        61018 => ProcErrors.Field("branchIds", ex.Message, ex.Message),
        61019 => ProcErrors.Field("status", "Status must be active or suspended.", "الحالة إما نشط أو موقوف."),
        _ => null
    };

    private static IResult OverrideForbidden() => ProcErrors.Forbidden("override_forbidden",
        "Changing someone's individual permissions needs the users.override permission.",
        "تعديل صلاحيات المستخدم الفردية يتطلب صلاحية users.override.");

    private static IResult BranchesForbidden() => ProcErrors.Forbidden("branches_forbidden",
        "Changing which branches someone works in needs the users.assign_branches permission.",
        "تعديل فروع المستخدم يتطلب صلاحية users.assign_branches.");

    private static IResult OutranksForbidden() => ProcErrors.Forbidden("outranks_you",
        "That account can do things you cannot, so you cannot change it.",
        "هذا الحساب يملك صلاحيات لا تملكها، لذا لا يمكنك تعديله.");

    /// <summary>
    /// Whether the account holds any permission the caller does not. Uses the
    /// same effective-permission view sign-in does, so "more powerful" means
    /// what the token would actually carry.
    /// </summary>
    private static async Task<bool> OutranksCallerAsync(
        SqlConnection connection, string userId, ICurrentUser current, CancellationToken ct)
    {
        var theirs = await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT PermissionKey FROM core.vw_EffectivePermission WHERE UserId = @UserId;",
            new { UserId = userId }, cancellationToken: ct));

        return theirs.Any(p => !current.Can(p));
    }

    private static async Task<List<UserDto>> LoadUsersAsync(
        SqlConnection connection, string? userId, string? search, bool activeOnly, CancellationToken ct)
    {
        const string filter = """
            WHERE (@UserId IS NULL OR u.UserId = @UserId)
              AND (@Search IS NULL OR u.NameAr LIKE N'%' + @Search + N'%'
                                   OR u.NameEn LIKE N'%' + @Search + N'%'
                                   OR u.Username LIKE N'%' + @Search + N'%'
                                   OR u.Email  LIKE N'%' + @Search + N'%')
              AND (@ActiveOnly = 0 OR u.Status = N'active')
            """;

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            $"""
            SELECT u.UserId, u.Username, u.FirstName, u.LastName, u.NameAr, u.NameEn,
                   u.Email, u.Phone, u.Address, u.EmployeeId, u.AvatarUrl,
                   u.RoleId, r.NameAr AS RoleNameAr, r.NameEn AS RoleNameEn,
                   u.DefaultBranchId, u.Status, u.IsExternal, u.AccessExpiresOn,
                   u.TicketReference, u.BaseSalaryH, u.LastLoginAtUtc,
                   CAST(CASE WHEN u.PasswordHash IS NULL THEN 0 ELSE 1 END AS BIT) AS HasPassword,
                   u.CreatedAtUtc, u.UpdatedAtUtc
            FROM core.AppUser AS u
            JOIN core.Role AS r ON r.RoleId = u.RoleId
            {filter}
            ORDER BY u.NameEn;

            SELECT ub.UserId, ub.BranchId
            FROM core.UserBranch AS ub
            JOIN core.AppUser AS u ON u.UserId = ub.UserId
            {filter};

            SELECT o.UserId, o.PermissionKey, o.Effect
            FROM core.UserPermissionOverride AS o
            JOIN core.AppUser AS u ON u.UserId = o.UserId
            {filter};
            """,
            new { UserId = userId, Search = search, ActiveOnly = activeOnly },
            cancellationToken: ct));

        var rows = (await multi.ReadAsync<UserRow>()).ToList();
        var branches = (await multi.ReadAsync<(string UserId, string BranchId)>())
            .ToLookup(b => b.UserId, b => b.BranchId);
        var overrides = (await multi.ReadAsync<(string UserId, string PermissionKey, string Effect)>())
            .ToLookup(o => o.UserId);

        return rows.Select(r => new UserDto(
            r.UserId, r.Username, r.FirstName ?? string.Empty, r.LastName ?? string.Empty,
            r.NameAr, r.NameEn, r.Email ?? string.Empty, r.Phone ?? string.Empty,
            r.Address ?? string.Empty, r.EmployeeId ?? string.Empty, r.AvatarUrl,
            r.RoleId, r.RoleNameAr, r.RoleNameEn, r.DefaultBranchId,
            branches[r.UserId].OrderBy(b => b).ToList(),
            r.Status == "active" && r.LastLoginAtUtc is null ? "invited" : r.Status,
            overrides[r.UserId].Where(o => o.Effect == "grant").Select(o => o.PermissionKey).ToList(),
            overrides[r.UserId].Where(o => o.Effect == "deny").Select(o => o.PermissionKey).ToList(),
            r.LastLoginAtUtc, r.AccessExpiresOn, r.TicketReference, r.IsExternal,
            r.BaseSalaryH, r.HasPassword, r.CreatedAtUtc, r.UpdatedAtUtc)).ToList();
    }

    /*=================================================================== roles */

    /// <summary>
    /// Every role with its permissions and how many people hold it.
    ///
    /// The flat <c>permissions</c> pairs are kept beside the nested arrays so a
    /// client written against the first version of this route still works.
    /// </summary>
    private static async Task<IResult> RolesAsync(
        ISqlConnectionFactory db, ILanguageContext language, CancellationToken ct)
    {
        await using var connection = db.Create();

        var roles = await LoadRolesAsync(connection, null, language, ct);

        var permissions = roles.SelectMany(r => r.Permissions.Select(p => new { roleId = r.Id, permissionKey = p }));

        return Results.Ok(new { roles, permissions });
    }

    private static async Task<IResult> RoleAsync(
        string roleId, ISqlConnectionFactory db, ILanguageContext language, CancellationToken ct)
    {
        await using var connection = db.Create();

        var role = (await LoadRolesAsync(connection, roleId, language, ct)).SingleOrDefault();

        return role is null
            ? ProcErrors.NotFound("No such role.", "لا يوجد دور بهذا المعرف.")
            : Results.Ok(role);
    }

    /// <summary>How many users hold each role: { "rol_cashier": 2, ... }.</summary>
    private static async Task<IResult> RoleUsageAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync<(string RoleId, int Count)>(new CommandDefinition(
            "SELECT RoleId, COUNT(*) FROM core.AppUser GROUP BY RoleId;", cancellationToken: ct));

        return Results.Ok(rows.ToDictionary(r => r.RoleId, r => r.Count));
    }

    private static Task<IResult> CreateRoleAsync(
        SaveRoleRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveRoleAsync(null, request, db, current, language, http, logger, ct);

    private static Task<IResult> UpdateRoleAsync(
        string roleId, SaveRoleRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveRoleAsync(roleId, request, db, current, language, http, logger, ct);

    /// <summary>
    /// Create or edit a role through core.usp_SaveRole, which replaces its
    /// permission set wholesale. As with users, nobody puts a permission into a
    /// role that they do not hold themselves.
    /// </summary>
    private static async Task<IResult> SaveRoleAsync(
        string? roleId,
        SaveRoleRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        var permissions = (request.Permissions ?? []).Distinct().ToList();

        if (request.Status is not (null or "active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        if (permissions.FirstOrDefault(p => !current.Can(p)) is { } beyond)
        {
            return ProcErrors.Forbidden("exceeds_own_permissions",
                $"You cannot put a permission you do not hold into a role ({beyond}).",
                $"لا يمكنك إضافة صلاحية لا تملكها إلى دور ({beyond}).");
        }

        var description = ProcErrors.Blank(request.Description);

        var parameters = new DynamicParameters();
        parameters.Add("@RoleId", roleId);
        parameters.Add("@NameAr", request.NameAr?.Trim());
        parameters.Add("@NameEn", request.NameEn?.Trim());
        parameters.Add("@DescriptionAr", ProcErrors.Blank(request.DescriptionAr) ?? description);
        parameters.Add("@DescriptionEn", ProcErrors.Blank(request.DescriptionEn) ?? description);
        parameters.Add("@IsExternal", request.External);
        parameters.Add("@IsActive", request.Status != "inactive");
        parameters.Add("@Permissions", ProcErrors.Csv(permissions));
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SaveRole", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapRoleError(ex) is { } mapped)
        {
            return mapped;
        }

        var savedId = parameters.Get<string>("@SavedId");

        logger.LogInformation("Role {RoleId} {Action} by {Actor}.",
            savedId, roleId is null ? "created" : "updated", current.Username);

        http.Items["AuditEntityId"] = savedId;

        var role = (await LoadRolesAsync(connection, savedId, language, ct)).Single();

        return roleId is null
            ? Results.Created($"/api/users/roles/{savedId}", role)
            : Results.Ok(role);
    }

    /// <summary>
    /// A real delete: a role is configuration, and nothing historical records
    /// which role an actor held. Built-in roles and roles still assigned are
    /// refused with 409 and a message naming why.
    /// </summary>
    private static async Task<IResult> DeleteRoleAsync(
        string roleId, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct)
    {
        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_DeleteRole", new { RoleId = roleId },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapRoleError(ex) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Role {RoleId} deleted by {Actor}.", roleId, current.Username);
        http.Items["AuditEntityId"] = roleId;

        return Results.NoContent();
    }

    private static IResult? MapRoleError(SqlException ex) => ex.Number switch
    {
        61056 => ProcErrors.NotFound("No such role.", "لا يوجد دور بهذا المعرف."),
        61055 => ProcErrors.Conflict("owner_role_immutable",
            "The owner role always holds every permission and cannot be edited.",
            "دور المالك يملك كل الصلاحيات دائمًا ولا يمكن تعديله."),
        61057 => ProcErrors.Conflict("builtin_role",
            "Built-in roles cannot be deleted.", "لا يمكن حذف الأدوار الأساسية."),
        /* The message carries the count, so it is passed through. */
        61058 => ProcErrors.Conflict("role_in_use", ex.Message,
            "ما زال هناك مستخدمون بهذا الدور. انقلهم إلى دور آخر أولًا."),
        61059 => ProcErrors.Conflict("role_in_use",
            "Users still hold this role. Move them to another role first.",
            "ما زال هناك مستخدمون بهذا الدور. انقلهم إلى دور آخر أولًا."),
        61050 => ProcErrors.Field("nameEn", "Both names are required.", "الاسمان العربي والإنجليزي مطلوبان."),
        61051 => ProcErrors.Field("nameEn", "Another role already uses this name.", "يوجد دور آخر بهذا الاسم."),
        61052 => ProcErrors.Field("permissions",
            "Give the role at least one permission, or nobody can use it.",
            "امنح الدور صلاحية واحدة على الأقل، وإلا فلن يستفيد منه أحد."),
        61053 => ProcErrors.Field("permissions", "One of those permissions does not exist.", "إحدى هذه الصلاحيات غير موجودة."),
        61054 => Results.UnprocessableEntity(ApiError.Create("external_permission_forbidden",
            "A maintenance account cannot be given access to financial or customer data. Remove those permissions first.",
            "لا يمكن منح حساب الصيانة وصولًا إلى البيانات المالية أو بيانات العملاء. أزل هذه الصلاحيات أولًا.",
            new Dictionary<string, string[]> { ["permissions"] = ["Financial or personal-data permission."] })),
        _ => null
    };

    private static async Task<List<RoleDto>> LoadRolesAsync(
        SqlConnection connection, string? roleId, ILanguageContext language, CancellationToken ct)
    {
        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT r.RoleId, r.NameAr, r.NameEn, r.DescriptionAr, r.DescriptionEn,
                   r.IsBuiltIn, r.IsExternal, r.IsActive, r.CreatedAtUtc, r.UpdatedAtUtc,
                   (SELECT COUNT(*) FROM core.AppUser AS u WHERE u.RoleId = r.RoleId) AS UserCount
            FROM core.Role AS r
            WHERE @RoleId IS NULL OR r.RoleId = @RoleId
            ORDER BY r.NameEn;

            SELECT RoleId, PermissionKey FROM core.RolePermission
            WHERE @RoleId IS NULL OR RoleId = @RoleId
            ORDER BY PermissionKey;
            """,
            new { RoleId = roleId }, cancellationToken: ct));

        var rows = (await multi.ReadAsync<RoleRow>()).ToList();
        var permissions = (await multi.ReadAsync<(string RoleId, string PermissionKey)>())
            .ToLookup(p => p.RoleId, p => p.PermissionKey);

        return rows.Select(r => new RoleDto(
            r.RoleId, KindOf(r.RoleId), r.NameAr, r.NameEn,
            language.Pick(r.NameAr, r.NameEn),
            r.DescriptionAr, r.DescriptionEn,
            language.Pick(r.DescriptionAr ?? r.DescriptionEn ?? string.Empty,
                          r.DescriptionEn ?? r.DescriptionAr ?? string.Empty),
            permissions[r.RoleId].ToList(),
            r.IsActive ? "active" : "inactive",
            r.IsBuiltIn, r.IsExternal, r.UserCount, r.CreatedAtUtc, r.UpdatedAtUtc)).ToList();
    }

    /// <summary>
    /// The screen's role "kind". Built-in roles are known by id; anything an
    /// owner created is custom.
    /// </summary>
    private static string KindOf(string roleId) => roleId switch
    {
        "rol_owner" => "owner",
        "rol_manager" => "manager",
        "rol_cashier" => "cashier",
        "rol_accountant" => "accountant",
        "rol_inventory" => "inventory_manager",
        "rol_maintenance" => "maintenance",
        _ => "custom"
    };

    private static async Task<IResult> PermissionsAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            "SELECT PermissionKey, Module, Action, Sensitivity FROM core.Permission ORDER BY Module, Action;",
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    private sealed record UserRow
    {
        public string UserId { get; init; } = string.Empty;
        public string Username { get; init; } = string.Empty;
        public string? FirstName { get; init; }
        public string? LastName { get; init; }
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? Email { get; init; }
        public string? Phone { get; init; }
        public string? Address { get; init; }
        public string? EmployeeId { get; init; }
        public string? AvatarUrl { get; init; }
        public string RoleId { get; init; } = string.Empty;
        public string RoleNameAr { get; init; } = string.Empty;
        public string RoleNameEn { get; init; } = string.Empty;
        public string? DefaultBranchId { get; init; }
        public string Status { get; init; } = string.Empty;
        public bool IsExternal { get; init; }
        public DateOnly? AccessExpiresOn { get; init; }
        public string? TicketReference { get; init; }
        public long BaseSalaryH { get; init; }
        public DateTime? LastLoginAtUtc { get; init; }
        public bool HasPassword { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
    }

    private sealed record RoleRow
    {
        public string RoleId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? DescriptionAr { get; init; }
        public string? DescriptionEn { get; init; }
        public bool IsBuiltIn { get; init; }
        public bool IsExternal { get; init; }
        public bool IsActive { get; init; }
        public int UserCount { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
    }
}
