using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using PosApi.Features.Zatca;
using Xunit;

namespace PosApi.Tests.Zatca;

/// <summary>
/// The certificate request as ZATCA's SDK writes it (fatooraNet csr, compared
/// field by field on 2026-11-18): this pins the parts a silent change would break.
/// </summary>
public sealed class ZatcaCsrTests
{
    private static readonly ZatcaCsrSubject Subject = new(
        "TST-886431145-399999999900003", "1-TST|2-TST|3-ed22f1d8-e6a2-1118-9b58-d9a8f11e445f",
        "399999999900003", "Riyadh Branch", "Maximum Speed Tech Supply LTD", "1100", "RRRD2929", "Supply activities");

    [Theory]
    [InlineData("developer-portal", "TSTZATCA-Code-Signing")]
    [InlineData("simulation", "PREZATCA-Code-Signing")]
    [InlineData("core", "ZATCA-Code-Signing")]
    public void Request_is_signed_and_carries_the_template_and_directory_name(string environment, string template)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var der = ZatcaCsr.Build(Subject, environment, key);

        /* Loading verifies the request's own signature. */
        var request = CertificateRequest.LoadSigningRequest(der, HashAlgorithmName.SHA256,
            CertificateRequestLoadOptions.UnsafeLoadCertificateExtensions);
        Assert.Equal("CN=TST-886431145-399999999900003, O=Maximum Speed Tech Supply LTD, OU=Riyadh Branch, C=SA",
            request.SubjectName.Name);

        /* The template name is a PrintableString (0x13), as the SDK writes it. */
        var templateExtension = request.CertificateExtensions.Single(e => e.Oid!.Value == "1.3.6.1.4.1.311.20.2");
        Assert.Equal(0x13, templateExtension.RawData[0]);
        Assert.Equal(template, Encoding.ASCII.GetString(templateExtension.RawData[2..]));

        /* One directory name: SN (the EGS serial), UID, title, registeredAddress, businessCategory. */
        var san = request.CertificateExtensions.Single(e => e.Oid!.Value == "2.5.29.17");
        var names = new AsnReader(san.RawData, AsnEncodingRules.DER).ReadSequence();
        var directory = names.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 4, true)).ReadSequence();
        var attributes = new List<(string, string)>();
        while (directory.HasData)
        {
            var pair = directory.ReadSetOf().ReadSequence();
            attributes.Add((pair.ReadObjectIdentifier(), pair.ReadCharacterString(UniversalTagNumber.UTF8String)));
        }
        Assert.Equal(
            new[]
            {
                ("2.5.4.4", Subject.SerialNumber), ("0.9.2342.19200300.100.1.1", "399999999900003"), ("2.5.4.12", "1100"),
                ("2.5.4.26", "RRRD2929"), ("2.5.4.15", "Supply activities")
            }, attributes);
    }

    [Fact]
    public void The_api_form_is_base64_of_the_pem_text()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var der = ZatcaCsr.Build(Subject, "simulation", key);
        var text = Encoding.UTF8.GetString(Convert.FromBase64String(ZatcaCsr.ForApi(der)));
        Assert.StartsWith("-----BEGIN CERTIFICATE REQUEST-----", text, StringComparison.Ordinal);
    }

    [Fact]
    public void A_bad_subject_is_refused()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        Assert.Throws<ArgumentException>(() => ZatcaCsr.Build(Subject with { VatNumber = "123" }, "core", key));
        Assert.Throws<ArgumentException>(() => ZatcaCsr.Build(Subject with { SerialNumber = "x" }, "core", key));
        Assert.Throws<ArgumentException>(() => ZatcaCsr.Build(Subject with { InvoiceTypes = "1111" }, "core", key));
        Assert.Throws<ArgumentException>(() => ZatcaCsr.Build(Subject with { CommonName = "NZD-brn_001-399999999900003" }, "core", key));
    }

    [Fact]
    public void The_common_name_drops_what_ZATCA_refuses()
    {
        Assert.Equal("NZD-brn001-399999999900003", ZatcaCsr.CommonName("brn_001", "399999999900003"));
        Assert.Equal("NZD-b2Riyadh-399999999900003", ZatcaCsr.CommonName("b2 Riyadh!@#$%&*", "399999999900003"));
    }
}
