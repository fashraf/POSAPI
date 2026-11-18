using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PosApi.Features.Zatca;
using Xunit;

namespace PosApi.Tests.Zatca;

public sealed class ZatcaVaultTests
{
    private static ZatcaVault Vault(string? kek) =>
        new(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Zatca:Kek"] = kek }).Build(),
            NullLogger<ZatcaVault>.Instance);

    [Fact]
    public void A_sealed_value_opens_only_in_its_own_context()
    {
        var vault = Vault(Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)));
        var context = ZatcaVault.Context("CL-00001", "brn_001", "privateKey");
        var sealedValue = vault.Seal("secret key"u8.ToArray(), context);

        Assert.DoesNotContain("secret", sealedValue, StringComparison.Ordinal);
        Assert.Equal("secret key", Encoding.UTF8.GetString(vault.Open(sealedValue, context)));
        Assert.ThrowsAny<CryptographicException>(() =>
            vault.Open(sealedValue, ZatcaVault.Context("CL-00002", "brn_001", "privateKey")));
        Assert.ThrowsAny<CryptographicException>(() =>
            Vault(Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))).Open(sealedValue, context));
    }

    [Fact]
    public void Without_a_key_nothing_is_sealed()
    {
        Assert.False(Vault(null).IsAvailable);
        Assert.False(Vault(Convert.ToBase64String(new byte[16])).IsAvailable);
        Assert.Throws<InvalidOperationException>(() => Vault(null).Seal([1], "x"));
    }
}
