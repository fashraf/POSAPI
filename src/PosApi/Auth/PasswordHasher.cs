using System.Security.Cryptography;
using Microsoft.AspNetCore.Cryptography.KeyDerivation;

namespace PosApi.Auth;

/// <summary>
/// Password hashing.
///
/// Hashing, not encryption. Encryption is reversible, so a database leak would
/// expose every password in it; a hash cannot be turned back into the original.
/// PBKDF2-HMAC-SHA256 with a per-password salt and a high iteration count, so
/// an attacker who does obtain the hashes still has to spend real time on each
/// one rather than running a single dictionary pass over all of them.
/// </summary>
public interface IPasswordHasher
{
    (string Hash, string Salt) Hash(string password);
    bool Verify(string password, string hash, string salt);
}

public sealed class PasswordHasher : IPasswordHasher
{
    private const int SaltBytes = 16;
    private const int KeyBytes = 32;

    /// <summary>
    /// OWASP's 2023 floor for PBKDF2-SHA256. Raise it as hardware improves; the
    /// count travels with the hash, so old passwords keep working.
    /// </summary>
    private const int Iterations = 210_000;

    public (string Hash, string Salt) Hash(string password)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(password);

        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        var key = Derive(password, salt, Iterations);

        return ($"pbkdf2${Iterations}${Convert.ToBase64String(key)}",
                Convert.ToBase64String(salt));
    }

    public bool Verify(string password, string hash, string salt)
    {
        if (string.IsNullOrWhiteSpace(password) ||
            string.IsNullOrWhiteSpace(hash) ||
            string.IsNullOrWhiteSpace(salt))
        {
            return false;
        }

        var parts = hash.Split('$');
        if (parts.Length != 3 || parts[0] != "pbkdf2") return false;
        if (!int.TryParse(parts[1], out var iterations) || iterations < 1000) return false;

        byte[] expected;
        byte[] saltBytes;

        try
        {
            expected = Convert.FromBase64String(parts[2]);
            saltBytes = Convert.FromBase64String(salt);
        }
        catch (FormatException)
        {
            return false;
        }

        var actual = Derive(password, saltBytes, iterations);

        // Constant-time. A comparison that returns on the first differing byte
        // leaks how much of the hash matched, which is enough to rebuild it.
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }

    private static byte[] Derive(string password, byte[] salt, int iterations) =>
        KeyDerivation.Pbkdf2(
            password: password,
            salt: salt,
            prf: KeyDerivationPrf.HMACSHA256,
            iterationCount: iterations,
            numBytesRequested: KeyBytes);
}
