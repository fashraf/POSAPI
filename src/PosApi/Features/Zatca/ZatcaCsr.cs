using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Text;

namespace PosApi.Features.Zatca;

/// <summary>What ZATCA asks about the EGS unit in its certificate request.</summary>
public sealed record ZatcaCsrSubject(
    string CommonName,
    /* 1-<solution>|2-<model>|3-<unit id> */
    string SerialNumber,
    string VatNumber,
    /* The branch's name (for a VAT group: the member's TIN). */
    string OrganizationUnit,
    string OrganizationName,
    /* Four digits: standard, simplified, then two unused. 0100 or 1100. */
    string InvoiceTypes,
    string LocationAddress,
    string BusinessCategory,
    string Country = "SA");

/// <summary>
/// The certificate request (PKCS #10) for an EGS unit, built as ZATCA's own
/// SDK builds it (compared field by field with fatooraNet csr, 2026-11-18):
///
///   subject      C (PrintableString), OU, O, CN (UTF8String), in that order
///   extensions   the Microsoft certificate-template name (1.3.6.1.4.1.311.20.2,
///                a PrintableString: TSTZATCA-, PREZATCA- or ZATCA-Code-Signing)
///                and a subject alternative name holding one directory name:
///                SN (2.5.4.4, the EGS serial), UID (the VAT number), title (the
///                invoice types), registeredAddress and businessCategory
///   signature    ecdsa-with-SHA256
///
/// The key is P-256: ZATCA's simulation issued and accepted it (developer kit,
/// 2026-08-08), and every platform .NET runs on supports it.
/// </summary>
public static class ZatcaCsr
{
    public static string TemplateName(string environment) => environment switch
    {
        "developer-portal" => "TSTZATCA-Code-Signing",
        "simulation" => "PREZATCA-Code-Signing",
        "core" => "ZATCA-Code-Signing",
        _ => throw new ArgumentOutOfRangeException(nameof(environment), environment, "Not a ZATCA environment.")
    };

    public static byte[] Build(ZatcaCsrSubject subject, string environment, ECDsa key)
    {
        Validate(subject);

        var info = new AsnWriter(AsnEncodingRules.DER);
        using (info.PushSequence())
        {
            info.WriteInteger(0);

            using (info.PushSequence())
            {
                Rdn(info, "2.5.4.6", subject.Country, UniversalTagNumber.PrintableString);
                Rdn(info, "2.5.4.11", subject.OrganizationUnit, UniversalTagNumber.UTF8String);
                Rdn(info, "2.5.4.10", subject.OrganizationName, UniversalTagNumber.UTF8String);
                Rdn(info, "2.5.4.3", subject.CommonName, UniversalTagNumber.UTF8String);
            }

            info.WriteEncodedValue(key.ExportSubjectPublicKeyInfo());

            /* attributes [0] IMPLICIT SET OF Attribute: the extension request. */
            using (info.PushSetOf(new Asn1Tag(TagClass.ContextSpecific, 0, isConstructed: true)))
            using (info.PushSequence())
            {
                info.WriteObjectIdentifier("1.2.840.113549.1.9.14");
                using (info.PushSetOf())
                using (info.PushSequence())
                {
                    var template = new AsnWriter(AsnEncodingRules.DER);
                    template.WriteCharacterString(UniversalTagNumber.PrintableString, TemplateName(environment));
                    Extension(info, "1.3.6.1.4.1.311.20.2", template.Encode());

                    var name = new AsnWriter(AsnEncodingRules.DER);
                    using (name.PushSequence())                                                     // GeneralNames
                    using (name.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 4, isConstructed: true))) // directoryName
                    using (name.PushSequence())                                                     // Name
                    {
                        Rdn(name, "2.5.4.4", subject.SerialNumber, UniversalTagNumber.UTF8String);
                        Rdn(name, "0.9.2342.19200300.100.1.1", subject.VatNumber, UniversalTagNumber.UTF8String);
                        Rdn(name, "2.5.4.12", subject.InvoiceTypes, UniversalTagNumber.UTF8String);
                        Rdn(name, "2.5.4.26", subject.LocationAddress, UniversalTagNumber.UTF8String);
                        Rdn(name, "2.5.4.15", subject.BusinessCategory, UniversalTagNumber.UTF8String);
                    }
                    Extension(info, "2.5.29.17", name.Encode());
                }
            }
        }

        var body = info.Encode();
        var signature = key.SignData(body, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);

        var request = new AsnWriter(AsnEncodingRules.DER);
        using (request.PushSequence())
        {
            request.WriteEncodedValue(body);
            using (request.PushSequence())
                request.WriteObjectIdentifier("1.2.840.10045.4.3.2");
            request.WriteBitString(signature);
        }
        return request.Encode();
    }

    public static string Pem(byte[] der) => PemEncoding.WriteString("CERTIFICATE REQUEST", der) + "\n";

    /// <summary>The request as ZATCA's API takes it: base64 of the PEM text, not of the DER.</summary>
    public static string ForApi(byte[] der) => Convert.ToBase64String(Encoding.UTF8.GetBytes(Pem(der)));

    private static void Validate(ZatcaCsrSubject s)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(s.SerialNumber, @"^1-[^|=]+\|2-[^|=]+\|3-[^|=]+$"))
            throw new ArgumentException("The EGS serial reads 1-…|2-…|3-….");
        if (!System.Text.RegularExpressions.Regex.IsMatch(s.VatNumber, "^3[0-9]{13}3$"))
            throw new ArgumentException("The VAT number is 15 digits, starting and ending with 3.");
        if (s.InvoiceTypes is not ("0100" or "1100"))
            throw new ArgumentException("Invoice types are 0100 (simplified) or 1100 (standard and simplified).");
        foreach (var (value, name) in new[]
                 {
                     (s.CommonName, "common name"), (s.OrganizationUnit, "branch name"), (s.OrganizationName, "company name"),
                     (s.LocationAddress, "address"), (s.BusinessCategory, "business category")
                 })
        {
            if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException($"The {name} is required.");
        }
    }

    private static void Rdn(AsnWriter writer, string oid, string value, UniversalTagNumber type)
    {
        using (writer.PushSetOf())
        using (writer.PushSequence())
        {
            writer.WriteObjectIdentifier(oid);
            writer.WriteCharacterString(type, value);
        }
    }

    private static void Extension(AsnWriter writer, string oid, byte[] value)
    {
        using (writer.PushSequence())
        {
            writer.WriteObjectIdentifier(oid);
            writer.WriteOctetString(value);
        }
    }
}
