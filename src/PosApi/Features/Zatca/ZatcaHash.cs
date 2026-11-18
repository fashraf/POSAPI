using System.Security.Cryptography;
using System.Security.Cryptography.Xml;
using System.Text;
using System.Xml;

namespace PosApi.Features.Zatca;

/// <summary>
/// The invoice hash and the chain value.
///
/// The hash: parse the document keeping every whitespace node, remove the
/// signature extension (ext:UBLExtensions), the cac:Signature reference and
/// the QR's AdditionalDocumentReference, canonicalize the whole document
/// (C14N, no comments), SHA-256, base64 of the 32 raw bytes (44 characters).
///
/// Removal is DOM RemoveChild: the whitespace around a removed element stays,
/// exactly as ZATCA's invoice.xsl and SDK leave it (the kit reproduced all 19
/// sample digests this way, 2026-09-19). C14N 1.0 and 1.1 differ only on
/// document subsets; on a whole document they give the same bytes, so .NET's
/// C14N 1.0 transform is the 1.1 the signature names.
///
/// The chain value (PIH) is a different encoding of the same hash: base64 of
/// its lowercase hex text (88 characters). ZATCA's validator refuses the
/// 44-character form there (measured 2026-11-18, KSA-13).
/// </summary>
public static class ZatcaHash
{
    /// <summary>The chain value before the first document: base64(hex(SHA-256("0"))), as ZATCA ships it.</summary>
    public const string Genesis =
        "NWZlY2ViNjZmZmM4NmYzOGQ5NTI3ODZjNmQ2OTZjNzljMmRiYzIzOWRkNGU5MWI0NjcyOWQ3M2EyN2ZiNTdlOQ==";

    private const string Cac = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";
    private const string Cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";
    private const string Ext = "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2";

    /// <summary>The invoice hash of a document, base64 of the raw SHA-256 (44 characters).</summary>
    public static string InvoiceHash(string xml) => Convert.ToBase64String(InvoiceHashBytes(xml));

    public static byte[] InvoiceHashBytes(string xml)
    {
        var document = Load(xml);
        var root = document.DocumentElement ?? throw new ArgumentException("Empty document.", nameof(xml));

        var namespaces = new XmlNamespaceManager(document.NameTable);
        namespaces.AddNamespace("ext", Ext);
        namespaces.AddNamespace("cac", Cac);
        namespaces.AddNamespace("cbc", Cbc);

        foreach (var path in new[]
                 {
                     "/*/ext:UBLExtensions",
                     "/*/cac:Signature",
                     "/*/cac:AdditionalDocumentReference[cbc:ID='QR']"
                 })
        {
            foreach (var node in root.SelectNodes(path, namespaces)!.Cast<XmlNode>().ToList())
                node.ParentNode!.RemoveChild(node);
        }

        var transform = new XmlDsigC14NTransform(includeComments: false);
        transform.LoadInput(document);
        using var canonical = (Stream)transform.GetOutput(typeof(Stream));
        return SHA256.HashData(canonical);
    }

    /// <summary>The chain (PIH) form of an invoice hash: base64 of its hex text.</summary>
    public static string ChainValue(string invoiceHash) =>
        Convert.ToBase64String(Encoding.ASCII.GetBytes(
            Convert.ToHexString(Convert.FromBase64String(invoiceHash)).ToLowerInvariant()));

    /// <summary>SHA-256 as lowercase hex text, then base64: the encoding of the certificate and signed-properties digests.</summary>
    public static string HexThenBase64(byte[] data) =>
        Convert.ToBase64String(Encoding.ASCII.GetBytes(Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant()));

    /// <summary>Parse without DTDs or external resources, keeping whitespace.</summary>
    internal static XmlDocument Load(string xml)
    {
        var document = new XmlDocument { PreserveWhitespace = true, XmlResolver = null };
        using var reader = XmlReader.Create(new StringReader(xml), new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null
        });
        document.Load(reader);
        return document;
    }
}
