using System.Formats.Asn1;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;

namespace PosApi.Features.Zatca;

/// <summary>An EGS unit's signing credential: its certificate (CSID) and private key.</summary>
public sealed class ZatcaCredential : IDisposable
{
    public ZatcaCredential(X509Certificate2 certificate, ECDsa privateKey)
    {
        Certificate = certificate;
        PrivateKey = privateKey;
    }

    public X509Certificate2 Certificate { get; }
    public ECDsa PrivateKey { get; }

    /// <summary>The certificate as base64 DER text, exactly as the document carries it.</summary>
    public string CertificateBase64 => Convert.ToBase64String(Certificate.RawData);

    /// <summary>From ZATCA's binarySecurityToken (base64 of the certificate's base64 text) and a PEM key.</summary>
    public static ZatcaCredential FromCsid(string binarySecurityToken, string privateKeyPem)
    {
        var der = Convert.FromBase64String(Encoding.ASCII.GetString(Convert.FromBase64String(binarySecurityToken)));
        var key = ECDsa.Create();
        key.ImportFromPem(privateKeyPem);
        return new ZatcaCredential(new X509Certificate2(der), key);
    }

    public void Dispose()
    {
        Certificate.Dispose();
        PrivateKey.Dispose();
    }
}

/// <summary>A signed document and what the chain and the reporting call need from it.</summary>
public sealed record ZatcaSignedDocument(
    string Xml,
    string InvoiceHash,   /* base64 of the raw SHA-256 (44 characters): the reporting call's invoiceHash */
    string ChainValue,    /* the next document's PIH (88 characters) */
    string QrBase64,
    string SignatureBase64);

/// <summary>
/// Signs a document the way ZATCA's validator checks it (XAdES enveloped,
/// ZATCA's own template). The facts below were measured on ZATCA's samples by
/// the developer kit and hold for every golden document in tools/zatca/golden:
///
///  - the signature is SHA256withECDSA over the 32 raw bytes of the invoice
///    hash (not over SignedInfo);
///  - the certificate digest is SHA-256 of the certificate's base64 TEXT, as
///    hex, then base64;
///  - the signed-properties digest is SHA-256 of the xades:SignedProperties
///    element's text as the validator re-serialises it (xades namespace before
///    Id, ds namespace on every ds: child, whitespace as written), as hex,
///    then base64. The template's indentation is therefore part of what is
///    signed, and it is written here once, never re-indented;
///  - QR tags 6 and 7 carry the hash and signature as base64 TEXT; tag 8 is
///    the public key (DER SubjectPublicKeyInfo), tag 9 the certificate's own
///    signature bytes; tag 3 is the issue time without "Z".
/// </summary>
public static partial class ZatcaSigner
{
    public static ZatcaSignedDocument Sign(ZatcaDocument doc, ZatcaCredential credential, DateTime? signingTimeLocal = null)
    {
        var unsigned = ZatcaXml.Write(doc);
        var hashBytes = ZatcaHash.InvoiceHashBytes(unsigned);
        var invoiceHash = Convert.ToBase64String(hashBytes);

        var signature = Convert.ToBase64String(
            credential.PrivateKey.SignData(hashBytes, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence));

        var certificate = credential.Certificate;
        var certificateText = credential.CertificateBase64;
        var signingTime = (signingTimeLocal ?? doc.IssuedAtLocal).ToString("yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture);

        /* Each slot exactly once: a certificate whose names carried a slot's
           text would fail here rather than sign the wrong bytes. The issuer
           name is the only free text, so it goes in last before the digest. */
        var block = Template;
        block = ReplaceOnce(block, "SIGNING-TIME", signingTime);
        block = ReplaceOnce(block, "CERTIFICATE-DIGEST", ZatcaHash.HexThenBase64(Encoding.ASCII.GetBytes(certificateText)));
        block = ReplaceOnce(block, "SERIAL-NUMBER", SerialNumber(certificate));
        block = ReplaceOnce(block, "ISSUER-NAME", System.Security.SecurityElement.Escape(IssuerName(certificate)));
        block = ReplaceOnce(block, "SIGNED-PROPERTIES-DIGEST", SignedPropertiesDigest(block));
        block = ReplaceOnce(block, "INVOICE-DIGEST", invoiceHash);
        block = ReplaceOnce(block, "SIGNATURE-VALUE", signature);
        block = ReplaceOnce(block, "CERTIFICATE-BASE64", certificateText);

        var qr = ZatcaTlv.Encode(
            ZatcaTlv.Field(1, doc.Seller.RegistrationName),
            ZatcaTlv.Field(2, doc.Seller.VatNumber),
            ZatcaTlv.Field(3, doc.IssuedAtLocal.ToString("yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture)),
            ZatcaTlv.Field(4, ZatcaXml.Money(ZatcaXml.PayableH(doc))),
            ZatcaTlv.Field(5, ZatcaXml.Money(doc.TaxH)),
            ZatcaTlv.Field(6, invoiceHash),
            ZatcaTlv.Field(7, signature),
            ZatcaTlv.Field(8, certificate.PublicKey.ExportSubjectPublicKeyInfo()),
            ZatcaTlv.Field(9, CertificateSignature(certificate)));

        if (qr.Length > ZatcaTlv.MaxBase64Length)
            throw new InvalidOperationException($"The QR is {qr.Length} characters; ZATCA allows {ZatcaTlv.MaxBase64Length}.");

        var signed = ReplaceOnce(ReplaceOnce(unsigned, ZatcaXml.ExtensionsPlaceholder, block), ZatcaXml.QrPlaceholder, qr);

        /* Filling the excluded nodes must not move the hash. */
        if (ZatcaHash.InvoiceHash(signed) != invoiceHash)
            throw new InvalidOperationException("Signing changed the invoice hash.");

        return new ZatcaSignedDocument(signed, invoiceHash, ZatcaHash.ChainValue(invoiceHash), qr, signature);
    }

    /// <summary>The issuer as the document names it: most specific first, ", " between parts (CN=…, DC=…).</summary>
    public static string IssuerName(X509Certificate2 certificate) =>
        certificate.IssuerName.Name;

    /// <summary>The serial number in decimal.</summary>
    public static string SerialNumber(X509Certificate2 certificate) =>
        new BigInteger(certificate.SerialNumberBytes.Span, isUnsigned: true, isBigEndian: true)
            .ToString(CultureInfo.InvariantCulture);

    /// <summary>The certificate's own signature (its last field), for QR tag 9.</summary>
    public static byte[] CertificateSignature(X509Certificate2 certificate)
    {
        var reader = new AsnReader(certificate.RawData, AsnEncodingRules.DER);
        var sequence = reader.ReadSequence();
        sequence.ReadEncodedValue(); // tbsCertificate
        sequence.ReadEncodedValue(); // signatureAlgorithm
        return sequence.ReadBitString(out _);
    }

    /// <summary>The signed-properties digest of a document or signature block (see the class remarks).</summary>
    public static string SignedPropertiesDigest(string xml)
    {
        var start = xml.IndexOf(SignedPropertiesOpen, StringComparison.Ordinal);
        var end = xml.IndexOf(SignedPropertiesClose, start + 1, StringComparison.Ordinal);
        if (start < 0 || end < 0) throw new ArgumentException("No signed properties.", nameof(xml));

        var element = xml[start..(end + SignedPropertiesClose.Length)];
        var asValidatorWritesIt = DsElement().Replace(
            element.Replace(SignedPropertiesOpen,
                "<xades:SignedProperties xmlns:xades=\"http://uri.etsi.org/01903/v1.3.2#\" Id=\"xadesSignedProperties\">",
                StringComparison.Ordinal),
            m => $"<ds:{m.Groups[1].Value} xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\"" + (m.Groups[2].Value == ">" ? ">" : " "));

        return ZatcaHash.HexThenBase64(Encoding.UTF8.GetBytes(asValidatorWritesIt));
    }

    private const string SignedPropertiesOpen = "<xades:SignedProperties Id=\"xadesSignedProperties\">";
    private const string SignedPropertiesClose = "</xades:SignedProperties>";

    [GeneratedRegex(@"<ds:(\w+)(\s|>)")]
    private static partial Regex DsElement();

    private static string ReplaceOnce(string text, string slot, string value)
    {
        var at = text.IndexOf(slot, StringComparison.Ordinal);
        if (at < 0 || text.IndexOf(slot, at + slot.Length, StringComparison.Ordinal) >= 0)
            throw new InvalidOperationException($"The document must carry {slot} exactly once.");
        return string.Concat(text.AsSpan(0, at), value, text.AsSpan(at + slot.Length));
    }

    /* ZATCA's SDK template (xml/ubl.xml + signature.xml), character for
       character as its samples carry it. Do not re-indent: the signed
       properties are digested as text. */
    private const string Template = """
<ext:UBLExtensions>
    <ext:UBLExtension>
        <ext:ExtensionURI>urn:oasis:names:specification:ubl:dsig:enveloped:xades</ext:ExtensionURI>
        <ext:ExtensionContent>
            <sig:UBLDocumentSignatures xmlns:sig="urn:oasis:names:specification:ubl:schema:xsd:CommonSignatureComponents-2" xmlns:sac="urn:oasis:names:specification:ubl:schema:xsd:SignatureAggregateComponents-2" xmlns:sbc="urn:oasis:names:specification:ubl:schema:xsd:SignatureBasicComponents-2">
                <sac:SignatureInformation>
                    <cbc:ID>urn:oasis:names:specification:ubl:signature:1</cbc:ID>
                    <sbc:ReferencedSignatureID>urn:oasis:names:specification:ubl:signature:Invoice</sbc:ReferencedSignatureID>
                    <ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#" Id="signature">
                        <ds:SignedInfo>
                            <ds:CanonicalizationMethod Algorithm="http://www.w3.org/2006/12/xml-c14n11"/>
                            <ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256"/>
                            <ds:Reference Id="invoiceSignedData" URI="">
                                <ds:Transforms>
                                    <ds:Transform Algorithm="http://www.w3.org/TR/1999/REC-xpath-19991116">
                                        <ds:XPath>not(//ancestor-or-self::ext:UBLExtensions)</ds:XPath>
                                    </ds:Transform>
                                    <ds:Transform Algorithm="http://www.w3.org/TR/1999/REC-xpath-19991116">
                                        <ds:XPath>not(//ancestor-or-self::cac:Signature)</ds:XPath>
                                    </ds:Transform>
                                    <ds:Transform Algorithm="http://www.w3.org/TR/1999/REC-xpath-19991116">
                                        <ds:XPath>not(//ancestor-or-self::cac:AdditionalDocumentReference[cbc:ID='QR'])</ds:XPath>
                                    </ds:Transform>
                                    <ds:Transform Algorithm="http://www.w3.org/2006/12/xml-c14n11"/>
                                </ds:Transforms>
                                <ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>
                                <ds:DigestValue>INVOICE-DIGEST</ds:DigestValue>
                            </ds:Reference>
                            <ds:Reference Type="http://www.w3.org/2000/09/xmldsig#SignatureProperties" URI="#xadesSignedProperties">
                                <ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>
                                <ds:DigestValue>SIGNED-PROPERTIES-DIGEST</ds:DigestValue>
                            </ds:Reference>
                        </ds:SignedInfo>
                        <ds:SignatureValue>SIGNATURE-VALUE</ds:SignatureValue>
                        <ds:KeyInfo>
                            <ds:X509Data>
                                <ds:X509Certificate>CERTIFICATE-BASE64</ds:X509Certificate>
                            </ds:X509Data>
                        </ds:KeyInfo>
                        <ds:Object>
                            <xades:QualifyingProperties xmlns:xades="http://uri.etsi.org/01903/v1.3.2#" Target="signature">
                                <xades:SignedProperties Id="xadesSignedProperties">
                                    <xades:SignedSignatureProperties>
                                        <xades:SigningTime>SIGNING-TIME</xades:SigningTime>
                                        <xades:SigningCertificate>
                                            <xades:Cert>
                                                <xades:CertDigest>
                                                    <ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>
                                                    <ds:DigestValue>CERTIFICATE-DIGEST</ds:DigestValue>
                                                </xades:CertDigest>
                                                <xades:IssuerSerial>
                                                    <ds:X509IssuerName>ISSUER-NAME</ds:X509IssuerName>
                                                    <ds:X509SerialNumber>SERIAL-NUMBER</ds:X509SerialNumber>
                                                </xades:IssuerSerial>
                                            </xades:Cert>
                                        </xades:SigningCertificate>
                                    </xades:SignedSignatureProperties>
                                </xades:SignedProperties>
                            </xades:QualifyingProperties>
                        </ds:Object>
                    </ds:Signature>
                </sac:SignatureInformation>
            </sig:UBLDocumentSignatures>
        </ext:ExtensionContent>
    </ext:UBLExtension>
</ext:UBLExtensions>
""";
}
