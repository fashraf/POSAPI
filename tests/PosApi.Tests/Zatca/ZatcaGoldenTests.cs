using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using PosApi.Features.Zatca;
using Xunit;

namespace PosApi.Tests.Zatca;

/// <summary>
/// Our hash, digests and QR against documents ZATCA's validator already
/// accepted: the developer kit's chains (tools/zatca/golden) and, when the
/// SDK is unpacked beside POSAPI, ZATCA's own samples. Each figure is
/// recomputed from the document and compared with what the document states.
/// </summary>
public sealed class ZatcaGoldenTests
{
    public static IEnumerable<object[]> SignedDocuments() =>
        Paths.GoldenFiles()
            .Concat(Paths.SdkSamples())
            .Where(f => File.ReadAllText(f).Contains("Id=\"invoiceSignedData\"", StringComparison.Ordinal))
            .Select(f => new object[] { f });

    [Theory]
    [MemberData(nameof(SignedDocuments))]
    public void Invoice_hash_reproduces_the_stated_digest(string file)
    {
        var xml = File.ReadAllText(file);
        Assert.Equal(Stated(xml, "invoiceSignedData"), ZatcaHash.InvoiceHash(xml));
    }

    [Theory]
    [MemberData(nameof(SignedDocuments))]
    public void Signed_properties_digest_reproduces_the_stated_digest(string file)
    {
        var xml = File.ReadAllText(file);
        var stated = Regex.Match(xml,
            @"URI=""#xadesSignedProperties"">\s*<ds:DigestMethod[^>]*/>\s*<ds:DigestValue>([^<]+)<").Groups[1].Value;
        Assert.Equal(stated, ZatcaSigner.SignedPropertiesDigest(xml));
    }

    [Theory]
    [MemberData(nameof(SignedDocuments))]
    public void Certificate_digest_issuer_and_serial_match_the_document(string file)
    {
        var xml = File.ReadAllText(file);
        var certificateText = Field(xml, "ds:X509Certificate");
        using var certificate = new X509Certificate2(Convert.FromBase64String(certificateText));

        var certDigest = Regex.Match(xml, @"<xades:CertDigest>\s*<ds:DigestMethod[^>]*/>\s*<ds:DigestValue>([^<]+)<").Groups[1].Value;
        Assert.Equal(certDigest, ZatcaHash.HexThenBase64(Encoding.ASCII.GetBytes(certificateText)));
        Assert.Equal(Field(xml, "ds:X509IssuerName"), ZatcaSigner.IssuerName(certificate));
        Assert.Equal(Field(xml, "ds:X509SerialNumber"), ZatcaSigner.SerialNumber(certificate));
    }

    /// <summary>Tags 6 to 9 of a simplified document's QR, rebuilt from the document.</summary>
    [Theory]
    [MemberData(nameof(SignedDocuments))]
    public void Qr_tags_six_to_nine_match_the_document(string file)
    {
        var xml = File.ReadAllText(file);
        if (!xml.Contains("name=\"02", StringComparison.Ordinal)) return; // standard: ZATCA writes the QR

        var qr = Regex.Match(xml, @"<cbc:ID>QR</cbc:ID>\s*<cac:Attachment>\s*<cbc:EmbeddedDocumentBinaryObject[^>]*>([^<]+)<").Groups[1].Value;
        var tags = ZatcaTlv.Decode(qr).ToDictionary(t => t.Tag, t => t.Value);
        using var certificate = new X509Certificate2(Convert.FromBase64String(Field(xml, "ds:X509Certificate")));

        Assert.Equal(Stated(xml, "invoiceSignedData"), Encoding.ASCII.GetString(tags[6]));
        Assert.Equal(Field(xml, "ds:SignatureValue"), Encoding.ASCII.GetString(tags[7]));
        Assert.Equal(certificate.PublicKey.ExportSubjectPublicKeyInfo(), tags[8]);
        Assert.Equal(ZatcaSigner.CertificateSignature(certificate), tags[9]);
    }

    /// <summary>Each document's PIH is the previous one's hash in the chain form.</summary>
    [Fact]
    public void Chain_values_link_the_golden_chains()
    {
        var chains = Directory.GetDirectories(Paths.Golden);
        Assert.NotEmpty(chains);

        foreach (var chain in chains)
        {
            var files = Directory.GetFiles(chain, "*.xml").Order(StringComparer.Ordinal).ToList();
            Assert.Equal(ZatcaHash.Genesis, Pih(File.ReadAllText(files[0])));
            for (var i = 1; i < files.Count; i++)
            {
                var previous = ZatcaHash.InvoiceHash(File.ReadAllText(files[i - 1]));
                Assert.Equal(ZatcaHash.ChainValue(previous), Pih(File.ReadAllText(files[i])));
            }
        }
    }

    [Fact]
    public void Tlv_lengths_switch_to_the_long_form_at_128_bytes()
    {
        Assert.Equal(new byte[] { 1, 127 }, ZatcaTlv.Field(1, new byte[127])[..2]);
        Assert.Equal(new byte[] { 1, 0x81, 128 }, ZatcaTlv.Field(1, new byte[128])[..3]);
        Assert.Equal(new byte[] { 1, 0x82, 1, 44 }, ZatcaTlv.Field(1, new byte[300])[..4]);

        var payload = ZatcaTlv.Encode(ZatcaTlv.Field(1, "متجر"), ZatcaTlv.Field(2, new byte[200]));
        var fields = ZatcaTlv.Decode(payload);
        Assert.Equal("متجر", Encoding.UTF8.GetString(fields[0].Value));
        Assert.Equal(200, fields[1].Value.Length);
    }

    [Fact]
    public void Genesis_is_the_hex_form_of_the_hash_of_zero()
    {
        var hashOfZero = Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData("0"u8.ToArray()));
        Assert.Equal(ZatcaHash.Genesis, ZatcaHash.ChainValue(hashOfZero));
    }

    private static string Stated(string xml, string referenceId) =>
        Regex.Match(xml, $@"Id=""{referenceId}""[\s\S]*?<ds:DigestValue>([^<]+)<").Groups[1].Value;

    private static string Field(string xml, string element) =>
        Regex.Match(xml, $@"<{element}>\s*([^<]*?)\s*</{element}>").Groups[1].Value;

    private static string Pih(string xml) =>
        Regex.Match(xml, @"<cbc:ID>PIH</cbc:ID>\s*<cac:Attachment>\s*<cbc:EmbeddedDocumentBinaryObject[^>]*>([^<]+)<").Groups[1].Value;
}

/// <summary>Where the golden files, the SDK and the script are.</summary>
internal static class Paths
{
    /// <summary>POSAPI, found by walking up to PosApi.sln.</summary>
    public static string Root { get; } = FindRoot();

    public static string Golden => Path.Combine(Root, "tools", "zatca", "golden");

    public static string ValidateScript => Path.Combine(Root, "tools", "zatca", "validate-chain.sh");

    /// <summary>The ZATCA .NET SDK, or null when it is not unpacked here.</summary>
    public static string? Sdk
    {
        get
        {
            var home = Environment.GetEnvironmentVariable("ZATCA_SDK_HOME")
                       ?? Path.Combine(Root, "..", "zatca-einvoicing-sdk-DotNet-238-R3.4.8");
            return File.Exists(Path.Combine(home, "Lib", "Dot-Net8", "Test", "fatooraNet.dll")) ? home : null;
        }
    }

    public static IEnumerable<string> GoldenFiles() =>
        Directory.GetFiles(Golden, "*.xml", SearchOption.AllDirectories).Order(StringComparer.Ordinal);

    public static IEnumerable<string> SdkSamples() =>
        Sdk is null
            ? []
            : Directory.GetFiles(Path.Combine(Sdk, "Data", "Samples"), "*.xml", SearchOption.AllDirectories)
                .Order(StringComparer.Ordinal);

    private static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "PosApi.sln"))) return dir.FullName;
        throw new InvalidOperationException("PosApi.sln not found above the test binaries.");
    }
}
