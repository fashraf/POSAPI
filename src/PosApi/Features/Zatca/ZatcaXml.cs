using System.Globalization;
using System.Text;
using System.Xml;

namespace PosApi.Features.Zatca;

/// <summary>
/// Writes a <see cref="ZatcaDocument"/> as UBL 2.1 XML, in the element order
/// of ZATCA's XML Implementation Standard and its samples.
///
/// The document comes out with two placeholders the signer fills:
/// <see cref="ExtensionsPlaceholder"/> (the signature block) and
/// <see cref="QrPlaceholder"/> (the QR). Both sit inside the nodes the invoice
/// hash leaves out, so filling them never changes the hash.
///
/// Every amount is formatted once, here, from whole halalas: invariant
/// culture, two decimals, no grouping. Totals are derived from the stored
/// figures and must add up; a document that does not is refused rather than
/// written.
/// </summary>
public static class ZatcaXml
{
    public const string ExtensionsPlaceholder = "<ext:UBLExtensions />";
    public const string QrPlaceholder = "QR-TO-BE-REPLACED";

    private const string InvoiceNs = "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2";
    private const string Cac = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";
    private const string Cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";
    private const string Ext = "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2";

    public static string Write(ZatcaDocument doc)
    {
        Check(doc);

        var settings = new XmlWriterSettings
        {
            Encoding = new UTF8Encoding(false),
            Indent = true,
            IndentChars = "    ",
            NewLineChars = "\n",
            NewLineHandling = NewLineHandling.Replace
        };

        using var buffer = new MemoryStream();
        using (var w = XmlWriter.Create(buffer, settings))
        {
            w.WriteStartDocument();
            w.WriteStartElement("Invoice", InvoiceNs);
            w.WriteAttributeString("xmlns", "cac", null, Cac);
            w.WriteAttributeString("xmlns", "cbc", null, Cbc);
            w.WriteAttributeString("xmlns", "ext", null, Ext);

            w.WriteStartElement("ext", "UBLExtensions", Ext);
            w.WriteEndElement();

            Text(w, "ProfileID", "reporting:1.0");
            Text(w, "ID", doc.Number);
            Text(w, "UUID", doc.Uuid.ToString("D"));
            Text(w, "IssueDate", doc.IssuedAtLocal.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            Text(w, "IssueTime", doc.IssuedAtLocal.ToString("HH:mm:ss", CultureInfo.InvariantCulture));

            /* The 7-character subtype: 01 standard or 02 simplified, then the
               third-party, nominal, export, summary and self-billed flags. */
            w.WriteStartElement("cbc", "InvoiceTypeCode", Cbc);
            w.WriteAttributeString("name", doc.Simplified ? "0200000" : "0100000");
            w.WriteString(((int)doc.Type).ToString(CultureInfo.InvariantCulture));
            w.WriteEndElement();

            Text(w, "DocumentCurrencyCode", "SAR");
            Text(w, "TaxCurrencyCode", "SAR");

            if (doc.Type != ZatcaDocumentType.Invoice)
            {
                w.WriteStartElement("cac", "BillingReference", Cac);
                w.WriteStartElement("cac", "InvoiceDocumentReference", Cac);
                Text(w, "ID", doc.BillingReference!);
                w.WriteEndElement();
                w.WriteEndElement();
            }

            w.WriteStartElement("cac", "AdditionalDocumentReference", Cac);
            Text(w, "ID", "ICV");
            Text(w, "UUID", doc.Icv.ToString(CultureInfo.InvariantCulture));
            w.WriteEndElement();

            Attachment(w, "PIH", doc.PreviousHash);
            Attachment(w, "QR", QrPlaceholder);

            w.WriteStartElement("cac", "Signature", Cac);
            Text(w, "ID", "urn:oasis:names:specification:ubl:signature:Invoice");
            Text(w, "SignatureMethod", "urn:oasis:names:specification:ubl:dsig:enveloped:xades");
            w.WriteEndElement();

            Supplier(w, doc.Seller);
            Customer(w, doc.Buyer);

            /* The supply date (KSA-5): required on a standard document, and
               harmless on a simplified one. Supply and issue are the same day
               at a till. */
            w.WriteStartElement("cac", "Delivery", Cac);
            Text(w, "ActualDeliveryDate", doc.IssuedAtLocal.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            w.WriteEndElement();

            w.WriteStartElement("cac", "PaymentMeans", Cac);
            Text(w, "PaymentMeansCode", doc.PaymentMeansCode);
            if (doc.Type != ZatcaDocumentType.Invoice)
                Text(w, "InstructionNote", Clean(doc.Reason!));
            w.WriteEndElement();

            var (category, rate) = (doc.Lines[0].VatCategory, doc.Lines[0].VatRate);
            var lineNetH = doc.Lines.Sum(l => l.NetH);
            var taxableH = lineNetH - doc.AllowanceH;

            if (doc.AllowanceH > 0)
            {
                w.WriteStartElement("cac", "AllowanceCharge", Cac);
                Text(w, "ChargeIndicator", "false");
                Text(w, "AllowanceChargeReason", "discount");
                Amount(w, "Amount", doc.AllowanceH);
                TaxCategory(w, "TaxCategory", category, rate);
                w.WriteEndElement();
            }

            w.WriteStartElement("cac", "TaxTotal", Cac);
            Amount(w, "TaxAmount", doc.TaxH);
            w.WriteEndElement();

            w.WriteStartElement("cac", "TaxTotal", Cac);
            Amount(w, "TaxAmount", doc.TaxH);
            w.WriteStartElement("cac", "TaxSubtotal", Cac);
            Amount(w, "TaxableAmount", taxableH);
            Amount(w, "TaxAmount", doc.TaxH);
            TaxCategory(w, "TaxCategory", category, rate);
            w.WriteEndElement();
            w.WriteEndElement();

            w.WriteStartElement("cac", "LegalMonetaryTotal", Cac);
            Amount(w, "LineExtensionAmount", lineNetH);
            Amount(w, "TaxExclusiveAmount", taxableH);
            Amount(w, "TaxInclusiveAmount", taxableH + doc.TaxH);
            if (doc.AllowanceH > 0)
                Amount(w, "AllowanceTotalAmount", doc.AllowanceH);
            Amount(w, "PayableAmount", taxableH + doc.TaxH);
            w.WriteEndElement();

            for (var i = 0; i < doc.Lines.Count; i++)
                Line(w, i + 1, doc.Lines[i]);

            w.WriteEndElement();
            w.WriteEndDocument();
        }

        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>The amount paid: what the QR's tag 4 and the PayableAmount state.</summary>
    public static long PayableH(ZatcaDocument doc) => doc.Lines.Sum(l => l.NetH) - doc.AllowanceH + doc.TaxH;

    /// <summary>Halalas as ZATCA writes money: 1150 → "11.50".</summary>
    public static string Money(long halalas) =>
        (halalas / 100m).ToString("0.00", CultureInfo.InvariantCulture);

    private static void Check(ZatcaDocument doc)
    {
        if (doc.Lines.Count == 0)
            throw new ArgumentException("A document needs at least one line.");
        if (doc.Lines.Any(l => l.Quantity <= 0 || l.NetH < 0 || l.VatH < 0))
            throw new ArgumentException("Quantities must be above zero and amounts not negative.");
        if (doc.Lines.Select(l => (l.VatCategory, l.VatRate)).Distinct().Count() != 1)
            throw new NotSupportedException("Every line must share one VAT category and rate.");
        if (doc.AllowanceH < 0 || doc.TaxH < 0 || doc.AllowanceH > doc.Lines.Sum(l => l.NetH))
            throw new ArgumentException("The discount or VAT is out of range.");
        if (doc.Type != ZatcaDocumentType.Invoice
            && (string.IsNullOrWhiteSpace(doc.BillingReference) || string.IsNullOrWhiteSpace(doc.Reason)))
            throw new ArgumentException("A credit or debit note names the invoice it corrects and why.");
        if (!doc.Simplified && doc.Buyer is null)
            throw new ArgumentException("A standard document needs its buyer.");
        if (Encoding.UTF8.GetByteCount(doc.Seller.RegistrationName) > 127)
            throw new ArgumentException("The seller's name is longer than 127 bytes, which the QR cannot carry safely.");
        if (string.IsNullOrEmpty(doc.PreviousHash) || doc.Icv < 1)
            throw new ArgumentException("The document has no place in a chain.");
    }

    private static void Supplier(XmlWriter w, ZatcaSeller seller)
    {
        w.WriteStartElement("cac", "AccountingSupplierParty", Cac);
        w.WriteStartElement("cac", "Party", Cac);

        w.WriteStartElement("cac", "PartyIdentification", Cac);
        w.WriteStartElement("cbc", "ID", Cbc);
        w.WriteAttributeString("schemeID", "CRN");
        w.WriteString(seller.CrNumber);
        w.WriteEndElement();
        w.WriteEndElement();

        Address(w, seller.Address);
        TaxScheme(w, seller.VatNumber);
        LegalEntity(w, seller.RegistrationName);

        w.WriteEndElement();
        w.WriteEndElement();
    }

    private static void Customer(XmlWriter w, ZatcaBuyer? buyer)
    {
        w.WriteStartElement("cac", "AccountingCustomerParty", Cac);
        if (buyer is not null)
        {
            w.WriteStartElement("cac", "Party", Cac);
            if (!string.IsNullOrWhiteSpace(buyer.IdScheme) && !string.IsNullOrWhiteSpace(buyer.Id))
            {
                w.WriteStartElement("cac", "PartyIdentification", Cac);
                w.WriteStartElement("cbc", "ID", Cbc);
                w.WriteAttributeString("schemeID", buyer.IdScheme);
                w.WriteString(buyer.Id);
                w.WriteEndElement();
                w.WriteEndElement();
            }
            Address(w, buyer.Address);
            if (!string.IsNullOrWhiteSpace(buyer.VatNumber))
                TaxScheme(w, buyer.VatNumber);
            LegalEntity(w, buyer.RegistrationName);
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    private static void Address(XmlWriter w, ZatcaAddress a)
    {
        w.WriteStartElement("cac", "PostalAddress", Cac);
        Optional(w, "StreetName", a.Street);
        Optional(w, "BuildingNumber", a.BuildingNumber);
        Optional(w, "PlotIdentification", a.AdditionalNumber);
        Optional(w, "CitySubdivisionName", a.District);
        Optional(w, "CityName", a.City);
        Optional(w, "PostalZone", a.PostalCode);
        w.WriteStartElement("cac", "Country", Cac);
        Text(w, "IdentificationCode", a.CountryCode);
        w.WriteEndElement();
        w.WriteEndElement();
    }

    private static void TaxScheme(XmlWriter w, string vatNumber)
    {
        w.WriteStartElement("cac", "PartyTaxScheme", Cac);
        Text(w, "CompanyID", vatNumber);
        w.WriteStartElement("cac", "TaxScheme", Cac);
        Text(w, "ID", "VAT");
        w.WriteEndElement();
        w.WriteEndElement();
    }

    private static void LegalEntity(XmlWriter w, string name)
    {
        w.WriteStartElement("cac", "PartyLegalEntity", Cac);
        Text(w, "RegistrationName", Clean(name));
        w.WriteEndElement();
    }

    private static void Line(XmlWriter w, int id, ZatcaLine line)
    {
        var quantity = line.Quantity.ToString("0.###", CultureInfo.InvariantCulture);

        w.WriteStartElement("cac", "InvoiceLine", Cac);
        Text(w, "ID", id.ToString(CultureInfo.InvariantCulture));

        w.WriteStartElement("cbc", "InvoicedQuantity", Cbc);
        w.WriteAttributeString("unitCode", "PCE");
        w.WriteString(quantity);
        w.WriteEndElement();

        Amount(w, "LineExtensionAmount", line.NetH);

        w.WriteStartElement("cac", "TaxTotal", Cac);
        Amount(w, "TaxAmount", line.VatH);
        Amount(w, "RoundingAmount", line.NetH + line.VatH);
        w.WriteEndElement();

        w.WriteStartElement("cac", "Item", Cac);
        Text(w, "Name", Clean(line.Name));
        TaxCategory(w, "ClassifiedTaxCategory", line.VatCategory, line.VatRate);
        w.WriteEndElement();

        /* The whole line's net price for the whole quantity: price × quantity
           ÷ base quantity is the line amount exactly, whatever the quantity. */
        w.WriteStartElement("cac", "Price", Cac);
        Amount(w, "PriceAmount", line.NetH);
        w.WriteStartElement("cbc", "BaseQuantity", Cbc);
        w.WriteAttributeString("unitCode", "PCE");
        w.WriteString(quantity);
        w.WriteEndElement();
        w.WriteEndElement();

        w.WriteEndElement();
    }

    private static void TaxCategory(XmlWriter w, string element, string category, decimal rate)
    {
        w.WriteStartElement("cac", element, Cac);
        Text(w, "ID", category);
        Text(w, "Percent", rate.ToString("0.00", CultureInfo.InvariantCulture));
        w.WriteStartElement("cac", "TaxScheme", Cac);
        Text(w, "ID", "VAT");
        w.WriteEndElement();
        w.WriteEndElement();
    }

    private static void Attachment(XmlWriter w, string id, string value)
    {
        w.WriteStartElement("cac", "AdditionalDocumentReference", Cac);
        Text(w, "ID", id);
        w.WriteStartElement("cac", "Attachment", Cac);
        w.WriteStartElement("cbc", "EmbeddedDocumentBinaryObject", Cbc);
        w.WriteAttributeString("mimeCode", "text/plain");
        w.WriteString(value);
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteEndElement();
    }

    private static void Amount(XmlWriter w, string element, long halalas)
    {
        w.WriteStartElement("cbc", element, Cbc);
        w.WriteAttributeString("currencyID", "SAR");
        w.WriteString(Money(halalas));
        w.WriteEndElement();
    }

    private static void Text(XmlWriter w, string element, string value) =>
        w.WriteElementString("cbc", element, Cbc, value);

    private static void Optional(XmlWriter w, string element, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value)) Text(w, element, Clean(value));
    }

    /// <summary>
    /// Text as one line: control characters (a tab or line break typed into a
    /// name) become spaces. A parser may keep or fold them differently, and
    /// the hash must not depend on which.
    /// </summary>
    private static string Clean(string value) =>
        new string(value.Select(c => char.IsControl(c) ? ' ' : c).ToArray()).Trim();
}
