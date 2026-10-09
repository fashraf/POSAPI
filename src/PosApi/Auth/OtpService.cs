using System.Security.Cryptography;
using Dapper;
using Microsoft.Extensions.Options;
using PosApi.Data;

namespace PosApi.Auth;

public sealed record OtpChallenge(string ChallengeId, DateTime ExpiresAtUtc, bool IsDevCode);

public enum OtpResult { Valid, Invalid, Expired, TooManyAttempts, NotFound }

public interface IOtpService
{
    Task<OtpChallenge> IssueAsync(string identifier, string purpose, CancellationToken ct);
    Task<OtpResult> VerifyAsync(string challengeId, string code, CancellationToken ct);
}

/// <summary>
/// One-time codes.
///
/// The code is stored hashed, exactly like a password — an OTP sitting in
/// plaintext in a table is a credential anyone with read access can use before
/// it expires. Attempts are counted so a four-digit code cannot simply be
/// guessed: ten thousand possibilities fall in seconds without a limit.
/// </summary>
public sealed class OtpService : IOtpService
{
    private readonly ISqlConnectionFactory _db;
    private readonly PosApi.Tenancy.ITenantContext _tenant;
    private readonly IPasswordHasher _hasher;
    private readonly AuthOptions _options;
    private readonly IHostEnvironment _environment;
    private readonly ILogger<OtpService> _logger;

    public OtpService(
        ISqlConnectionFactory db,
        PosApi.Tenancy.ITenantContext tenant,
        IPasswordHasher hasher,
        IOptions<AuthOptions> options,
        IHostEnvironment environment,
        ILogger<OtpService> logger)
    {
        _db = db;
        _tenant = tenant;
        _hasher = hasher;
        _options = options.Value;
        _environment = environment;
        _logger = logger;
    }

    private bool UseDevCode => _options.UseFixedDevOtp && _environment.IsDevelopment();

    public async Task<OtpChallenge> IssueAsync(string identifier, string purpose, CancellationToken ct)
    {
        var code = UseDevCode ? _options.FixedDevOtp : GenerateCode(_options.OtpLength);
        var (hash, salt) = _hasher.Hash(code);

        /* Carries the tenant, so the verify call — anonymous — can find the
           database this challenge was written to. */
        var challengeId = PosApi.Tenancy.TenantKey.Compose(_tenant.Tenant!.TenantId, Guid.NewGuid().ToString("N"));
        var expiresAt = DateTime.UtcNow.AddMinutes(_options.OtpValidMinutes);

        await using var connection = _db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO core.OtpChallenge
                (ChallengeId, Identifier, Purpose, CodeHash, CodeSalt, ExpiresAtUtc, Attempts, ConsumedAtUtc)
            VALUES
                (@ChallengeId, @Identifier, @Purpose, @CodeHash, @CodeSalt, @ExpiresAtUtc, 0, NULL);
            """,
            new
            {
                ChallengeId = challengeId,
                Identifier = identifier,
                Purpose = purpose,
                CodeHash = hash,
                CodeSalt = salt,
                ExpiresAtUtc = expiresAt
            },
            cancellationToken: ct));

        if (UseDevCode)
        {
            _logger.LogWarning(
                "Development OTP in use for {Identifier}. This is an authentication bypass.",
                identifier);
        }
        else
        {
            // The code itself is never logged. Once an SMS provider is wired in,
            // this is where the send happens.
            _logger.LogInformation("OTP issued for {Identifier}, purpose {Purpose}.", identifier, purpose);
        }

        return new OtpChallenge(challengeId, expiresAt, UseDevCode);
    }

    public async Task<OtpResult> VerifyAsync(string challengeId, string code, CancellationToken ct)
    {
        await using var connection = _db.Create();

        var row = await connection.QuerySingleOrDefaultAsync<OtpRow>(new CommandDefinition(
            """
            SELECT ChallengeId, CodeHash, CodeSalt, ExpiresAtUtc, Attempts, ConsumedAtUtc
            FROM core.OtpChallenge
            WHERE ChallengeId = @ChallengeId;
            """,
            new { ChallengeId = challengeId },
            cancellationToken: ct));

        if (row is null || row.ConsumedAtUtc is not null) return OtpResult.NotFound;
        if (row.ExpiresAtUtc < DateTime.UtcNow) return OtpResult.Expired;
        if (row.Attempts >= _options.OtpMaxAttempts) return OtpResult.TooManyAttempts;

        // Count the attempt before checking it. Incrementing afterwards would
        // let a caller who abandons the request retry without cost.
        await connection.ExecuteAsync(new CommandDefinition(
            "UPDATE core.OtpChallenge SET Attempts = Attempts + 1 WHERE ChallengeId = @ChallengeId;",
            new { ChallengeId = challengeId },
            cancellationToken: ct));

        if (!_hasher.Verify(code, row.CodeHash, row.CodeSalt)) return OtpResult.Invalid;

        // Consume it. A one-time code that works twice is not one-time.
        await connection.ExecuteAsync(new CommandDefinition(
            "UPDATE core.OtpChallenge SET ConsumedAtUtc = SYSUTCDATETIME() WHERE ChallengeId = @ChallengeId;",
            new { ChallengeId = challengeId },
            cancellationToken: ct));

        return OtpResult.Valid;
    }

    private static string GenerateCode(int length)
    {
        // RandomNumberGenerator, not Random: a predictable OTP is no OTP.
        var max = (int)Math.Pow(10, length);
        var value = RandomNumberGenerator.GetInt32(0, max);
        return value.ToString(new string('0', length));
    }

    private sealed record OtpRow
    {
        public string ChallengeId { get; init; } = string.Empty;
        public string CodeHash { get; init; } = string.Empty;
        public string CodeSalt { get; init; } = string.Empty;
        public DateTime ExpiresAtUtc { get; init; }
        public int Attempts { get; init; }
        public DateTime? ConsumedAtUtc { get; init; }
    }
}
