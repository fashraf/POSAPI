using System.Security.Cryptography;
using System.Text;
using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Tenancy;

namespace PosApi.Features.Devices;

/// <summary>
/// Finding a terminal without typing its address.
///
/// The server cannot scan a shop's network — it runs on a public host with no
/// route into a customer's subnet. So the direction is reversed: an unregistered
/// terminal announces itself, and the admin sees it appear.
///
/// The outcome the brief asks for is unchanged. The admin never types an IP, and
/// this works from any network the terminal can reach the internet on rather
/// than only from the same Wi-Fi.
/// </summary>
public static class DiscoveryEndpoints
{
    public static void MapDiscoveryEndpoints(this IEndpointRouteBuilder app)
    {
        var admin = app.MapGroup("/api/devices/discovery")
            .WithTags("Device discovery")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        admin.MapGet("", DiscoverAsync)
             .RequireAuthorization(PermissionPolicy.For("devices.discover"));

        admin.MapPost("/challenge", IssueChallengeAsync)
             .RequireAuthorization(PermissionPolicy.For("devices.discover"));

        admin.MapGet("/challenge/{challengeId}", ChallengeStatusAsync)
             .RequireAuthorization(PermissionPolicy.For("devices.discover"));

        admin.MapPost("/connect", ConnectAsync)
             .RequireAuthorization(PermissionPolicy.For("devices.manage"));

        /* The terminal's side. Anonymous, because a device announcing itself has
           no credential yet — and rate limited as auth, because this faces the
           open internet. */
        var device = app.MapGroup("/api/device/discovery")
            .WithTags("Device (terminal)")
            .AllowAnonymous()
            .RequireRateLimiting("auth");

        device.MapPost("/announce", AnnounceAsync);
        device.MapPost("/challenge/{challengeId}/answer", AnswerChallengeAsync);
    }

    /*======================================================= admin handlers */

    private static async Task<IResult> DiscoverAsync(
        ISqlConnectionFactory db, int withinSeconds = 120, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            "device.usp_DiscoverDevices",
            new { WithinSeconds = withinSeconds <= 0 ? 120 : Math.Min(withinSeconds, 900) },
            commandType: System.Data.CommandType.StoredProcedure,
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    /// <summary>
    /// Ask a terminal to prove it is what it claims.
    ///
    /// Discovery is not authentication. An announcement is an assertion by an
    /// unauthenticated stranger — anyone can post a serial number. The nonce is
    /// what turns a claim into evidence.
    /// </summary>
    private static async Task<IResult> IssueChallengeAsync(
        ChallengeRequest request, ISqlConnectionFactory db, CancellationToken ct = default)
    {
        var challengeId = $"chl_{Guid.NewGuid():N}"[..36];
        var nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));

        await using var connection = db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO device.DeviceChallenge (ChallengeId, SerialNumber, Nonce, ExpiresAtUtc)
            VALUES (@ChallengeId, @SerialNumber, @Nonce,
                    DATEADD(SECOND, 120, SYSUTCDATETIME()));
            """,
            new { ChallengeId = challengeId, request.SerialNumber, Nonce = nonce },
            cancellationToken: ct));

        /* The nonce goes to the device, not back to the browser. The admin panel
           only needs to know the exchange is under way. */
        return Results.Ok(new { challengeId, status = "issued", expiresInSeconds = 120 });
    }

    private static async Task<IResult> ChallengeStatusAsync(
        string challengeId, ISqlConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var row = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT ChallengeId, SerialNumber, Verified, AnsweredAtUtc, ExpiresAtUtc,
                   CASE WHEN AnsweredAtUtc IS NOT NULL THEN N'answered'
                        WHEN ExpiresAtUtc < SYSUTCDATETIME() THEN N'expired'
                        ELSE N'waiting' END AS Status
            FROM device.DeviceChallenge WHERE ChallengeId = @ChallengeId;
            """,
            new { ChallengeId = challengeId }, cancellationToken: ct));

        return row is null ? Results.NotFound() : Results.Ok(row);
    }

    private static async Task<IResult> ConnectAsync(
        ConnectRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ITenantContext tenant, DeviceDirectory devices, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        /*
         * Re-check the proof.
         *
         * A verification that happened is not a verification that still applies:
         * the exchange may have expired, or a different serial may have answered
         * since. Trusting a flag the caller passed would make the challenge
         * decorative.
         */
        var verified = await connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT COUNT(*) FROM device.DeviceChallenge
            WHERE SerialNumber = @SerialNumber
              AND Verified = 1
              AND AnsweredAtUtc IS NOT NULL
              AND DATEDIFF(MINUTE, AnsweredAtUtc, SYSUTCDATETIME()) <= 10;
            """,
            new { request.SerialNumber }, cancellationToken: ct));

        if (verified == 0)
        {
            return Results.Conflict(ApiError.Create(
                "not_verified",
                "This terminal has not proved its identity, or the proof has expired. Verify it again.",
                "لم يُثبت هذا الجهاز هويته أو انتهت صلاحية الإثبات. أعد التحقق."));
        }

        var parameters = new DynamicParameters();
        parameters.Add("@SerialNumber", request.SerialNumber);
        parameters.Add("@DeviceId", request.DeviceId);
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@Location", request.Location);
        parameters.Add("@DeviceName", request.DeviceName);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@Blocked", dbType: System.Data.DbType.String,
                       direction: System.Data.ParameterDirection.Output, size: 400);

        await connection.ExecuteAsync(new CommandDefinition(
            "device.usp_ConnectDiscovered", parameters,
            commandType: System.Data.CommandType.StoredProcedure,
            cancellationToken: ct));

        var blocked = parameters.Get<string?>("@Blocked");

        if (!string.IsNullOrWhiteSpace(blocked))
        {
            return Results.Conflict(ApiError.Create("connect_blocked", blocked, blocked));
        }

        /* The procedure made the code; the control database must know it, or
           the terminal's registration (anonymous) cannot find this business. */
        var code = await connection.QuerySingleOrDefaultAsync<string?>(new CommandDefinition(
            "SELECT RegistrationCode FROM device.PosDevice WHERE DeviceId = @DeviceId;",
            new { request.DeviceId }, cancellationToken: ct));

        if (code is not null && !await devices.TryRecordCodeAsync(tenant.Tenant!.TenantId, request.DeviceId, code, ct))
        {
            return Results.Conflict(ApiError.Create("connect_blocked",
                "Please try connecting again.", "يرجى إعادة محاولة الربط."));
        }

        return Results.Ok(new
        {
            success = true,
            deviceId = request.DeviceId,
            registrationStatus = "awaiting_device",
            /* The terminal completes registration itself on its next
               announcement — it is listening for exactly this. */
            note = "The terminal will finish registering within a few seconds."
        });
    }

    /*====================================================== device handlers */

    /// <summary>
    /// A terminal saying it exists.
    ///
    /// Deliberately carries nothing secret. Announcement data is visible to an
    /// admin before any trust is established, so a token here would be a
    /// credential handed to whoever asks.
    /// </summary>
    private static async Task<IResult> AnnounceAsync(
        AnnounceRequest request, ISqlConnectionFactory db, HttpContext http,
        TenantGate gate, DeviceDirectory devices, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(request.SerialNumber))
        {
            return Results.BadRequest(ApiError.Create(
                "required", "A serial number is required.", "الرقم التسلسلي مطلوب."));
        }

        /* A terminal is discoverable only by the business the hardware register
           assigns its serial to. Unassigned, it is acknowledged and nothing is
           stored: there is no business it could be shown to. */
        var tenantId = await devices.TenantForSerialAsync(request.SerialNumber, ct);
        if (tenantId is null)
            return Results.Ok(new { acknowledged = false, reason = "unassigned", nextAnnounceMs = 30000 });

        if (await gate.EnterAsync(tenantId, ct) is { } refused) return refused;

        await using var connection = db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            "device.usp_RecordAnnouncement",
            new
            {
                request.SerialNumber, request.ClaimedDeviceId, request.DeviceName,
                request.Manufacturer, request.DeviceModel, request.AndroidId,
                request.AppVersion, request.LocalIpAddress, request.NetworkName,
                SourceIpAddress = http.Connection.RemoteIpAddress?.ToString()
            },
            commandType: System.Data.CommandType.StoredProcedure,
            cancellationToken: ct));

        /* Anything waiting for this terminal: a challenge to answer, or a
           registration code created for it while it was announcing. */
        var pending = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT TOP (1) c.ChallengeId, c.Nonce
            FROM device.DeviceChallenge AS c
            WHERE c.SerialNumber = @SerialNumber
              AND c.AnsweredAtUtc IS NULL
              AND c.ExpiresAtUtc > SYSUTCDATETIME()
            ORDER BY c.IssuedAtUtc DESC;

            """,
            new { request.SerialNumber }, cancellationToken: ct));

        var code = await connection.QuerySingleOrDefaultAsync<string?>(new CommandDefinition(
            """
            SELECT RegistrationCode FROM device.PosDevice
            WHERE SerialNumber = @SerialNumber
              AND RegisteredAtUtc IS NULL
              AND RegistrationCode IS NOT NULL
              AND CodeExpiresAtUtc > SYSUTCDATETIME();
            """,
            new { request.SerialNumber }, cancellationToken: ct));

        return Results.Ok(new
        {
            acknowledged = true,
            challenge = pending,
            /* Present once an admin has connected this terminal, so it can
               complete registration without anyone reading a code aloud. */
            registrationCode = code,
            nextAnnounceMs = 5000
        });
    }

    /// <summary>
    /// The terminal's answer to a challenge.
    ///
    /// A device that has registered before holds a token and signs the nonce
    /// with it, which is real proof. A device that has never registered has no
    /// credential and cannot prove anything — its answer is recorded as
    /// unverified, and the admin still needs the registration code.
    ///
    /// That limit is inherent, not an implementation shortcut: identity has to
    /// come from somewhere, and a brand-new terminal shares no secret with this
    /// server yet.
    /// </summary>
    private static async Task<IResult> AnswerChallengeAsync(
        string challengeId, ChallengeAnswerRequest request, ISqlConnectionFactory db,
        TenantGate gate, DeviceDirectory devices, ILogger<Program> logger, CancellationToken ct = default)
    {
        var tenantId = string.IsNullOrWhiteSpace(request.SerialNumber)
            ? null : await devices.TenantForSerialAsync(request.SerialNumber, ct);
        if (tenantId is null) return Results.NotFound();

        if (await gate.EnterAsync(tenantId, ct) is { } refused) return refused;

        await using var connection = db.Create();

        var challenge = await connection.QuerySingleOrDefaultAsync<ChallengeRow>(
            new CommandDefinition(
                """
                SELECT ChallengeId, SerialNumber, Nonce, ExpiresAtUtc, ConsumedAtUtc
                FROM device.DeviceChallenge WHERE ChallengeId = @ChallengeId;
                """,
                new { ChallengeId = challengeId }, cancellationToken: ct));

        if (challenge is null) return Results.NotFound();

        /* Single use. A nonce that can be answered twice is a replay. */
        if (challenge.ConsumedAtUtc is not null || challenge.ExpiresAtUtc < DateTime.UtcNow)
        {
            return Results.BadRequest(ApiError.Create(
                "challenge_spent", "That challenge has expired or was already used.",
                "انتهت صلاحية هذا التحدي أو استُخدم من قبل."));
        }

        if (challenge.SerialNumber != request.SerialNumber)
        {
            /* A different terminal answering is worth knowing about. */
            logger.LogWarning(
                "Challenge {ChallengeId} answered by a different serial.", challengeId);

            return Results.BadRequest(ApiError.Create(
                "serial_mismatch", "That challenge was issued for another terminal.",
                "صدر هذا التحدي لجهاز آخر."));
        }

        /* Does this terminal hold a token we already trust? */
        var tokenHash = await connection.QuerySingleOrDefaultAsync<string?>(
            new CommandDefinition(
                """
                SELECT TokenHash FROM device.PosDevice
                WHERE SerialNumber = @SerialNumber AND TokenHash IS NOT NULL;
                """,
                new { request.SerialNumber }, cancellationToken: ct));

        var verified = false;

        if (tokenHash is not null && !string.IsNullOrWhiteSpace(request.Signature))
        {
            /* HMAC over the nonce, keyed by the device token. Compared in
               constant time — a comparison that returns early leaks how much of
               a guess was right. */
            var expected = Convert.ToHexString(HMACSHA256.HashData(
                Encoding.UTF8.GetBytes(tokenHash),
                Encoding.UTF8.GetBytes(challenge.Nonce)));

            verified = CryptographicOperations.FixedTimeEquals(
                Encoding.UTF8.GetBytes(expected),
                Encoding.UTF8.GetBytes(request.Signature));
        }

        await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE device.DeviceChallenge
            SET AnsweredAtUtc = SYSUTCDATETIME(),
                ConsumedAtUtc = SYSUTCDATETIME(),
                Verified = @Verified
            WHERE ChallengeId = @ChallengeId;
            """,
            new { ChallengeId = challengeId, Verified = verified },
            cancellationToken: ct));

        return Results.Ok(new { challengeId, verified });
    }

    private sealed record ChallengeRow
    {
        public string ChallengeId { get; init; } = string.Empty;
        public string SerialNumber { get; init; } = string.Empty;
        public string Nonce { get; init; } = string.Empty;
        public DateTime ExpiresAtUtc { get; init; }
        public DateTime? ConsumedAtUtc { get; init; }
    }
}

public sealed record ChallengeRequest(string SerialNumber);

public sealed record ChallengeAnswerRequest(string SerialNumber, string? Signature);

public sealed record ConnectRequest(
    string SerialNumber, string DeviceId, string BranchId,
    string? Location, string DeviceName);

public sealed record AnnounceRequest(
    string SerialNumber, string? ClaimedDeviceId, string? DeviceName,
    string? Manufacturer, string? DeviceModel, string? AndroidId,
    string? AppVersion, string? LocalIpAddress, string? NetworkName);
