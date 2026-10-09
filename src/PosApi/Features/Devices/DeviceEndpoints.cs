using System.Security.Cryptography;
using System.Text;
using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Tenancy;

namespace PosApi.Features.Devices;

/// <summary>
/// POS device management.
///
/// Two groups on purpose. The admin routes use a staff token and a permission.
/// The device routes use a device token, issued at registration and scoped to
/// one terminal, which can do nothing but heartbeat and answer commands — a
/// till on a shop counter should not carry credentials that could read the
/// ledger.
/// </summary>
public static class DeviceEndpoints
{
    public static void MapDeviceEndpoints(this IEndpointRouteBuilder app)
    {
        /*------------------------------------------------------------ admin */

        var admin = app.MapGroup("/api/devices")
            .WithTags("Devices")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        admin.MapGet("", ListAsync).RequireAuthorization(PermissionPolicy.For("devices.view"));
        admin.MapGet("/{deviceId}", GetAsync).RequireAuthorization(PermissionPolicy.For("devices.view"));
        admin.MapGet("/{deviceId}/events", EventsAsync).RequireAuthorization(PermissionPolicy.For("devices.view"));

        admin.MapPost("", CreateAsync).RequireAuthorization(PermissionPolicy.For("devices.manage"));
        admin.MapPatch("/{deviceId}", UpdateAsync).RequireAuthorization(PermissionPolicy.For("devices.manage"));
        admin.MapPost("/{deviceId}/code", RegenerateCodeAsync)
             .RequireAuthorization(PermissionPolicy.For("devices.manage"));

        admin.MapPost("/{deviceId}/commands", QueueCommandAsync)
             .RequireAuthorization(PermissionPolicy.For("devices.command"));
        admin.MapGet("/{deviceId}/commands/{commandId}", CommandStatusAsync)
             .RequireAuthorization(PermissionPolicy.For("devices.command"));

        /*----------------------------------------------------------- device */

        /*
         * The terminal's own routes.
         *
         * Anonymous at the framework level because a device carries no staff
         * token — each handler authenticates the device itself against its
         * stored token hash. Rate limited as auth endpoints: these face the
         * network and a registration code is guessable given enough attempts.
         */
        var device = app.MapGroup("/api/device")
            .WithTags("Device (terminal)")
            .AllowAnonymous()
            .RequireRateLimiting("auth");

        device.MapPost("/register", RegisterAsync);
        device.MapPost("/heartbeat", HeartbeatAsync);
        device.MapPost("/commands/{commandId}/result", CommandResultAsync);
    }

    /*======================================================= admin handlers */

    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, string? branchId, string? status, string? deviceType,
        string? search, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT * FROM device.vw_DeviceStatus
            WHERE (@BranchId   IS NULL OR BranchId = @BranchId)
              AND (@Status     IS NULL OR ConnectionStatus = @Status)
              AND (@DeviceType IS NULL OR DeviceType = @DeviceType)
              AND (@Search     IS NULL
                   OR DeviceName   LIKE N'%' + @Search + N'%'
                   OR DeviceId     LIKE N'%' + @Search + N'%'
                   OR SerialNumber LIKE N'%' + @Search + N'%'
                   OR Location     LIKE N'%' + @Search + N'%')
            ORDER BY BranchId, DeviceName;
            """,
            new
            {
                BranchId = branchId, Status = status, DeviceType = deviceType,
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim()
            },
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> GetAsync(
        string deviceId, ISqlConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var device = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            "SELECT * FROM device.vw_DeviceStatus WHERE DeviceId = @DeviceId;",
            new { DeviceId = deviceId }, cancellationToken: ct));

        return device is null ? Results.NotFound() : Results.Ok(device);
    }

    private static async Task<IResult> EventsAsync(
        string deviceId, ISqlConnectionFactory db, int take = 50, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (@Take) EventId, EventType, Severity, MessageEn, MessageAr, OccurredAtUtc
            FROM device.DeviceEvent
            WHERE DeviceId = @DeviceId
            ORDER BY OccurredAtUtc DESC;
            """,
            new { DeviceId = deviceId, Take = take <= 0 ? 50 : Math.Min(take, 200) },
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> CreateAsync(
        CreateDeviceRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ITenantContext tenant, DeviceDirectory directory, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(request.DeviceId) ||
            string.IsNullOrWhiteSpace(request.DeviceName))
        {
            return Results.BadRequest(ApiError.Create(
                "required", "A device id and name are required.",
                "معرّف الجهاز واسمه مطلوبان."));
        }

        await using var connection = db.Create();

        if (await connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM device.PosDevice WHERE DeviceId = @DeviceId;",
                new { request.DeviceId }, cancellationToken: ct)) > 0)
        {
            return Results.Conflict(ApiError.Create(
                "device_exists", "That device id is already in use.",
                "معرّف الجهاز مستخدم بالفعل."));
        }

        /* The plan's device limit, counted on active terminals. */
        if (tenant.Tenant!.MaxDevices is { } maxDevices &&
            await connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM device.PosDevice WHERE IsActive = 1;", cancellationToken: ct)) >= maxDevices)
        {
            return Results.Conflict(ApiError.Create(
                "plan_limit_devices",
                $"Your plan allows {maxDevices} active POS devices. Upgrade the plan or deactivate one first.",
                $"باقتك تسمح بـ {maxDevices} أجهزة نقاط بيع نشطة. رقِّ الباقة أو عطّل جهازًا أولًا."));
        }

        var code = await ClaimCodeAsync(directory, tenant.Tenant.TenantId, request.DeviceId, ct);

        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO device.PosDevice
                (DeviceId, DeviceName, DeviceType, DeviceModel, BranchId, Location,
                 Description, PaperWidth, PrinterKind, RegistrationCode,
                 CodeExpiresAtUtc, IsActive, CreatedBy)
            VALUES
                (@DeviceId, @DeviceName, @DeviceType, @DeviceModel, @BranchId, @Location,
                 @Description, @PaperWidth, @PrinterKind, @Code,
                 DATEADD(HOUR, 24, SYSUTCDATETIME()), @IsActive, @Actor);

            INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
            VALUES (@DeviceId, N'created', N'info', N'Device record created', N'تم إنشاء سجل الجهاز');
            """,
            new
            {
                request.DeviceId, request.DeviceName,
                DeviceType = request.DeviceType ?? "sunmi_v2",
                request.DeviceModel, request.BranchId, request.Location, request.Description,
                PaperWidth = request.PaperWidth == 58 ? 58 : 80,
                PrinterKind = request.PrinterKind ?? "sunmi_builtin",
                Code = code,
                IsActive = request.IsActive ?? true,
                Actor = current.Username
            },
            cancellationToken: ct));

        return Results.Created($"/api/devices/{request.DeviceId}", new
        {
            deviceId = request.DeviceId,
            registrationCode = code,
            expiresInHours = 24
        });
    }

    private static async Task<IResult> UpdateAsync(
        string deviceId, UpdateDeviceRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var affected = await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE device.PosDevice
            SET DeviceName  = ISNULL(@DeviceName, DeviceName),
                DeviceModel = ISNULL(@DeviceModel, DeviceModel),
                BranchId    = ISNULL(@BranchId, BranchId),
                Location    = ISNULL(@Location, Location),
                Description = ISNULL(@Description, Description),
                PaperWidth  = ISNULL(@PaperWidth, PaperWidth),
                IsActive    = ISNULL(@IsActive, IsActive),
                UpdatedAtUtc = SYSUTCDATETIME(),
                UpdatedBy    = @Actor
            WHERE DeviceId = @DeviceId;
            """,
            new
            {
                DeviceId = deviceId, request.DeviceName, request.DeviceModel,
                request.BranchId, request.Location, request.Description,
                request.PaperWidth, request.IsActive, Actor = current.Username
            },
            cancellationToken: ct));

        return affected == 0 ? Results.NotFound() : Results.Ok(new { deviceId });
    }

    /// <summary>
    /// A fresh registration code, invalidating the old one.
    ///
    /// Needed when a terminal is replaced or a code expires unused. It does not
    /// unregister the device — that is deliberate, so regenerating by accident
    /// cannot knock a working till offline.
    /// </summary>
    private static async Task<IResult> RegenerateCodeAsync(
        string deviceId, ISqlConnectionFactory db, ITenantContext tenant, DeviceDirectory directory,
        CancellationToken ct = default)
    {
        var code = await ClaimCodeAsync(directory, tenant.Tenant!.TenantId, deviceId, ct);

        await using var connection = db.Create();

        var affected = await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE device.PosDevice
            SET RegistrationCode = @Code,
                CodeExpiresAtUtc = DATEADD(HOUR, 24, SYSUTCDATETIME()),
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE DeviceId = @DeviceId;
            """,
            new { DeviceId = deviceId, Code = code }, cancellationToken: ct));

        return affected == 0
            ? Results.NotFound()
            : Results.Ok(new { deviceId, registrationCode = code, expiresInHours = 24 });
    }

    private static async Task<IResult> QueueCommandAsync(
        string deviceId, QueueCommandRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var registered = await connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM device.PosDevice WHERE DeviceId = @DeviceId AND RegisteredAtUtc IS NOT NULL;",
            new { DeviceId = deviceId }, cancellationToken: ct));

        if (registered == 0)
        {
            return Results.Conflict(ApiError.Create(
                "not_registered",
                "This device has not completed registration, so it cannot receive commands.",
                "لم يكتمل تسجيل هذا الجهاز، لذا لا يمكنه استقبال الأوامر."));
        }

        var commandId = $"cmd_{Guid.NewGuid():N}"[..36];

        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO device.DeviceCommand
                (CommandId, DeviceId, CommandType, Payload, ExpiresAtUtc, RequestedBy)
            VALUES
                (@CommandId, @DeviceId, @CommandType, @Payload,
                 DATEADD(SECOND, @TtlSeconds, SYSUTCDATETIME()), @Actor);
            """,
            new
            {
                CommandId = commandId, DeviceId = deviceId,
                CommandType = request.CommandType, request.Payload,
                /* Two minutes. Long enough for a device on a slow connection,
                   short enough that the screen can say "no answer" while the
                   person is still standing at the till. */
                TtlSeconds = 120,
                Actor = current.Username
            },
            cancellationToken: ct));

        return Results.Accepted($"/api/devices/{deviceId}/commands/{commandId}",
            new { commandId, status = "pending" });
    }

    private static async Task<IResult> CommandStatusAsync(
        string deviceId, string commandId, ISqlConnectionFactory db,
        CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var row = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT CommandId, CommandType, Status, Succeeded, ResultMessage, ResultData,
                   RoundTripMs, QueuedAtUtc, SentAtUtc, CompletedAtUtc, ExpiresAtUtc
            FROM device.DeviceCommand
            WHERE CommandId = @CommandId AND DeviceId = @DeviceId;
            """,
            new { CommandId = commandId, DeviceId = deviceId }, cancellationToken: ct));

        return row is null ? Results.NotFound() : Results.Ok(row);
    }

    /*====================================================== device handlers */

    private static async Task<IResult> RegisterAsync(
        RegisterDeviceRequest request, ISqlConnectionFactory db, TenantGate gate, DeviceDirectory directory,
        ILogger<Program> logger, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(request.RegistrationCode) ||
            string.IsNullOrWhiteSpace(request.SerialNumber))
        {
            return Results.BadRequest(ApiError.Create(
                "required", "A registration code and serial number are required.",
                "رمز التسجيل والرقم التسلسلي مطلوبان."));
        }

        /* The token is returned once and stored hashed, like a refresh token.
           A token readable from the table is a token anyone with a query window
           can use to impersonate a till. */
        /* The code names the business: the control database holds code → tenant. */
        var tenantId = await directory.TenantForCodeAsync(request.RegistrationCode, ct);
        if (tenantId is null)
        {
            return Results.BadRequest(ApiError.Create(
                "registration_refused", "That registration code is not valid or has expired.",
                "رمز التسجيل غير صحيح أو منتهي الصلاحية."));
        }

        if (await gate.EnterAsync(tenantId, ct) is { } refused) return refused;

        /* Prefixed with the tenant, so heartbeats — also anonymous — find the
           database the device is registered in. */
        var token = TenantKey.Compose(tenantId, Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)));

        var parameters = new DynamicParameters();
        parameters.Add("@RegistrationCode", request.RegistrationCode.Trim().ToUpperInvariant());
        parameters.Add("@SerialNumber", request.SerialNumber.Trim());
        parameters.Add("@AndroidId", request.AndroidId);
        parameters.Add("@DeviceModel", request.DeviceModel);
        parameters.Add("@AppVersion", request.AppVersion);
        parameters.Add("@TokenHash", HashToken(token));
        parameters.Add("@DeviceId", dbType: System.Data.DbType.String,
                       direction: System.Data.ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "device.usp_RegisterDevice", parameters,
                commandType: System.Data.CommandType.StoredProcedure,
                cancellationToken: ct));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 58000 and <= 58004)
        {
            logger.LogWarning("Device registration refused: {Message}", ex.Message);

            return Results.BadRequest(ApiError.Create(
                "registration_refused", ex.Message, ex.Message));
        }

        var deviceId = parameters.Get<string>("@DeviceId");

        var device = await connection.QuerySingleAsync(new CommandDefinition(
            "SELECT * FROM device.vw_DeviceStatus WHERE DeviceId = @DeviceId;",
            new { DeviceId = deviceId }, cancellationToken: ct));

        logger.LogInformation("Device {DeviceId} registered for {TenantId}.", deviceId, tenantId);

        await directory.PairedAsync(tenantId, request.RegistrationCode, deviceId, request.SerialNumber, ct);

        return Results.Ok(new { deviceToken = token, device });
    }

    private static async Task<IResult> HeartbeatAsync(
        HeartbeatRequest request, ISqlConnectionFactory db, TenantGate gate, CancellationToken ct = default)
    {
        /* A suspended business's tills stop here: refused, not acknowledged. */
        if (await gate.EnterAsync(TenantKey.TenantOf(request.DeviceToken), ct) is { } refused) return refused;

        await using var connection = db.Create();

        var deviceId = await AuthenticateDeviceAsync(connection, request.DeviceToken, ct);
        if (deviceId is null) return Results.Unauthorized();

        var parameters = new DynamicParameters();
        parameters.Add("@DeviceId", deviceId);
        parameters.Add("@PrinterStatus", request.PrinterStatus ?? "unknown");
        parameters.Add("@PaperStatus", request.PaperStatus ?? "unknown");
        parameters.Add("@PrinterError", request.PrinterError);
        parameters.Add("@BatteryPercent", request.BatteryPercent);
        parameters.Add("@NetworkType", request.NetworkType);
        parameters.Add("@AppVersion", request.AppVersion);
        parameters.Add("@NextIntervalMs", dbType: System.Data.DbType.Int32,
                       direction: System.Data.ParameterDirection.Output);

        var commands = (await connection.QueryAsync(new CommandDefinition(
            "device.usp_RecordHeartbeat", parameters,
            commandType: System.Data.CommandType.StoredProcedure,
            cancellationToken: ct))).ToList();

        return Results.Ok(new
        {
            acknowledged = true,
            /* The server sets the pace: sooner while work is outstanding. */
            nextIntervalMs = parameters.Get<int>("@NextIntervalMs"),
            commands
        });
    }

    private static async Task<IResult> CommandResultAsync(
        string commandId, CommandResultRequest request, ISqlConnectionFactory db, TenantGate gate,
        CancellationToken ct = default)
    {
        if (await gate.EnterAsync(TenantKey.TenantOf(request.DeviceToken), ct) is { } refused) return refused;

        await using var connection = db.Create();

        var deviceId = await AuthenticateDeviceAsync(connection, request.DeviceToken, ct);
        if (deviceId is null) return Results.Unauthorized();

        await connection.ExecuteAsync(new CommandDefinition(
            "device.usp_CompleteCommand",
            new
            {
                CommandId = commandId, DeviceId = deviceId,
                request.Succeeded, request.ResultMessage, request.ResultData
            },
            commandType: System.Data.CommandType.StoredProcedure,
            cancellationToken: ct));

        return Results.Ok(new { commandId, recorded = true });
    }

    /*=============================================================== helpers */

    /// <summary>
    /// Which device this token belongs to, or null.
    ///
    /// Compared as a hash, so the stored value is useless to anyone who reads
    /// the table.
    /// </summary>
    private static async Task<string?> AuthenticateDeviceAsync(
        System.Data.Common.DbConnection connection, string? token, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(token)) return null;

        return await connection.QuerySingleOrDefaultAsync<string?>(new CommandDefinition(
            """
            SELECT DeviceId FROM device.PosDevice
            WHERE TokenHash = @TokenHash AND IsActive = 1 AND RegisteredAtUtc IS NOT NULL;
            """,
            new { TokenHash = HashToken(token) }, cancellationToken: ct));
    }

    private static string HashToken(string token) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));

    /// <summary>
    /// A code someone has to read off a screen and type on a terminal.
    ///
    /// Grouped in fours, and without I, O, 0 or 1 — those are the characters
    /// people mistype from a screen, and a registration that fails for that
    /// reason looks like a broken device.
    /// </summary>
    /// <summary>A fresh code, recorded against this tenant's device in the control database.</summary>
    private static async Task<string> ClaimCodeAsync(
        DeviceDirectory directory, string tenantId, string deviceId, CancellationToken ct)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            var code = NewRegistrationCode();
            if (await directory.TryRecordCodeAsync(tenantId, deviceId, code, ct)) return code;
        }

        throw new InvalidOperationException("Could not allocate a unique registration code.");
    }

    private static string NewRegistrationCode()
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        var chars = new char[8];

        for (var i = 0; i < chars.Length; i++)
        {
            chars[i] = alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)];
        }

        return $"{new string(chars, 0, 4)}-{new string(chars, 4, 4)}";
    }
}

/*=========================================================== request shapes */

public sealed record CreateDeviceRequest(
    string DeviceId, string DeviceName, string? DeviceType, string? DeviceModel,
    string BranchId, string? Location, string? Description,
    int? PaperWidth, string? PrinterKind, bool? IsActive);

public sealed record UpdateDeviceRequest(
    string? DeviceName, string? DeviceModel, string? BranchId, string? Location,
    string? Description, int? PaperWidth, bool? IsActive);

public sealed record QueueCommandRequest(string CommandType, string? Payload);

public sealed record RegisterDeviceRequest(
    string RegistrationCode, string SerialNumber, string? AndroidId,
    string? DeviceModel, string? AppVersion);

public sealed record HeartbeatRequest(
    string DeviceToken, string? PrinterStatus, string? PaperStatus, string? PrinterError,
    int? BatteryPercent, string? NetworkType, string? AppVersion);

public sealed record CommandResultRequest(
    string DeviceToken, bool Succeeded, string? ResultMessage, string? ResultData);
