using System.Security.Cryptography;
using System.Text;

namespace PosApi.Features.Zatca;

/// <summary>
/// Encrypts the EGS units' private keys and CSID secrets before they reach
/// the database.
///
/// AES-256-GCM, a fresh 12-byte nonce per value, and associated data naming
/// the tenant, branch and field, so a value copied to another row or tenant
/// does not decrypt. The key-encryption key (KEK) is 32 random bytes that are
/// never stored in the database:
///
///   Zatca:KekFile   a file holding the 32 bytes, raw or as base64 (production:
///                   root-owned, mode 0400, with an offline backup; losing it
///                   means onboarding every branch again)
///   Zatca:Kek       the same as base64 in configuration (development, via
///                   user-secrets or an environment variable)
///
/// With neither, the vault is unavailable: nothing is signed and every branch
/// keeps the Phase 1 QR, rather than storing a key in the clear.
/// </summary>
public sealed class ZatcaVault
{
    private const string Version = "v1";
    private readonly byte[]? _kek;

    public ZatcaVault(IConfiguration configuration, ILogger<ZatcaVault> logger)
    {
        var file = configuration["Zatca:KekFile"];
        var inline = configuration["Zatca:Kek"];

        try
        {
            if (!string.IsNullOrWhiteSpace(file))
                _kek = Parse(File.ReadAllBytes(file));
            else if (!string.IsNullOrWhiteSpace(inline))
                _kek = Convert.FromBase64String(inline.Trim());
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or FormatException)
        {
            logger.LogError(ex, "The ZATCA key-encryption key could not be read; ZATCA signing is off.");
            _kek = null;
        }

        if (_kek is not null && _kek.Length != 32)
        {
            logger.LogError("The ZATCA key-encryption key must be 32 bytes; ZATCA signing is off.");
            _kek = null;
        }

        if (_kek is null)
            logger.LogWarning("No ZATCA key-encryption key (Zatca:KekFile or Zatca:Kek). Invoices are not signed; receipts carry the Phase 1 QR.");

        KekId = _kek is null ? "none" : "kek-" + Convert.ToHexString(SHA256.HashData(_kek))[..12].ToLowerInvariant();
    }

    public bool IsAvailable => _kek is not null;

    /// <summary>Names the KEK (a digest prefix, not the key), stored beside each value.</summary>
    public string KekId { get; }

    public string Seal(byte[] plaintext, string context)
    {
        var kek = _kek ?? throw new InvalidOperationException("The ZATCA vault has no key.");
        var nonce = RandomNumberGenerator.GetBytes(12);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];

        using (var aes = new AesGcm(kek, 16))
            aes.Encrypt(nonce, plaintext, ciphertext, tag, Encoding.UTF8.GetBytes(context));

        return $"{Version}:{Convert.ToBase64String([.. nonce, .. ciphertext, .. tag])}";
    }

    public byte[] Open(string sealedValue, string context)
    {
        var kek = _kek ?? throw new InvalidOperationException("The ZATCA vault has no key.");
        if (!sealedValue.StartsWith(Version + ":", StringComparison.Ordinal))
            throw new CryptographicException("Unknown sealed value format.");

        var blob = Convert.FromBase64String(sealedValue[(Version.Length + 1)..]);
        if (blob.Length < 28) throw new CryptographicException("Sealed value too short.");

        var plaintext = new byte[blob.Length - 28];
        using var aes = new AesGcm(kek, 16);
        aes.Decrypt(blob.AsSpan(0, 12), blob.AsSpan(12, plaintext.Length), blob.AsSpan(blob.Length - 16), plaintext,
                    Encoding.UTF8.GetBytes(context));
        return plaintext;
    }

    /// <summary>What a value is bound to.</summary>
    public static string Context(string tenantId, string branchId, string field) => $"{tenantId}|{branchId}|{field}";

    private static byte[] Parse(byte[] content)
    {
        if (content.Length == 32) return content;
        return Convert.FromBase64String(Encoding.ASCII.GetString(content).Trim());
    }
}
