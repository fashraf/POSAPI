using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

namespace PosApi.Auth;

/// <summary>
/// The one signing key, resolved once.
///
/// Before this, the key was read from configuration twice — once by
/// JwtTokenService to sign, once by Program.cs to validate. Two reads of the
/// same setting normally agree, but nothing enforced it, and when they disagree
/// the symptom is a 401 that says nothing about the cause.
///
/// Resolving once and sharing the instance makes a mismatch structurally
/// impossible rather than merely unlikely.
/// </summary>
public sealed class SigningKeyProvider
{
    public SymmetricSecurityKey Key { get; }

    /// <summary>
    /// A short hash of the key, safe to log.
    ///
    /// It identifies which key is in use without revealing it, so "is the API
    /// validating with the key it signed that token with" is answerable by
    /// reading two log lines instead of inferring it from a 401.
    /// </summary>
    public string Fingerprint { get; }

    public SigningKeyProvider(IOptions<JwtOptions> options)
    {
        var configured = options.Value.SigningKey;

        /*
         * Fail here rather than let an empty key through.
         *
         * An empty string produces SymmetricSecurityKey(new byte[0]), which
         * IdentityModel reports as "the signature key was not found" — the
         * error that looks like a missing key but reads like a broken token.
         * Refusing to construct turns that runtime mystery into a startup
         * message naming the setting.
         */
        if (string.IsNullOrWhiteSpace(configured))
        {
            throw new InvalidOperationException(
                "Jwt:SigningKey is not set." + Environment.NewLine +
                "  Development: dotnet user-secrets set \"Jwt:SigningKey\" \"<64 random chars>\" " +
                "--project src/PosApi" + Environment.NewLine +
                "  Production:  set the JWT__SIGNINGKEY environment variable." + Environment.NewLine +
                "  Note that user-secrets are only loaded when ASPNETCORE_ENVIRONMENT=Development.");
        }

        /* HMAC-SHA256 needs at least 256 bits. A shorter key is rejected by
           IdentityModel at signing time, which is far from where it was set. */
        if (Encoding.UTF8.GetByteCount(configured) < 32)
        {
            throw new InvalidOperationException(
                $"Jwt:SigningKey is {Encoding.UTF8.GetByteCount(configured)} bytes. " +
                "HMAC-SHA256 requires at least 32. Use a longer key.");
        }

        Key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(configured));

        Fingerprint = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(configured)))[..12].ToLowerInvariant();
    }
}
