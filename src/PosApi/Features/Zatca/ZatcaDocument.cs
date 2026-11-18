namespace PosApi.Features.Zatca;

/// <summary>Invoice type code (UNTDID 1001): what kind of tax document it is.</summary>
public enum ZatcaDocumentType
{
    Invoice = 388,
    DebitNote = 383,
    CreditNote = 381
}

/// <summary>
/// The seller as every document states it. Name and VAT number also go into
/// the QR; the name is at most 127 UTF-8 bytes so the QR's TLV length stays
/// one byte (see <see cref="ZatcaTlv"/>).
/// </summary>
public sealed record ZatcaSeller(
    string RegistrationName,
    string VatNumber,
    /* Commercial registration number (schemeID CRN), the seller id ZATCA requires (BR-KSA-08). */
    string CrNumber,
    ZatcaAddress Address);

/// <summary>A Saudi national address (or a foreign one, for a buyer).</summary>
public sealed record ZatcaAddress(
    string? Street,
    string? BuildingNumber,
    /* The national address's additional number (PlotIdentification). */
    string? AdditionalNumber,
    string? District,
    string? City,
    string? PostalCode,
    string CountryCode = "SA");

/// <summary>
/// The buyer of a standard (B2B) document. A simplified document has none.
/// A buyer without a VAT number is identified by <see cref="IdScheme"/> and
/// <see cref="Id"/> (CRN, NAT, IQA, ...).
/// </summary>
public sealed record ZatcaBuyer(
    string RegistrationName,
    string? VatNumber,
    string? IdScheme,
    string? Id,
    ZatcaAddress Address);

/// <summary>
/// One line, in the figures the database stores (migration 023): the line
/// without VAT and its VAT, in halalas. The line's discount is already inside
/// <see cref="NetH"/>, so the XML states the price as the line's net amount
/// for the whole quantity (PriceAmount = NetH, BaseQuantity = Quantity),
/// which keeps a weighed quantity's price exact.
/// </summary>
public sealed record ZatcaLine(
    string Name,
    decimal Quantity,
    long NetH,
    long VatH,
    decimal VatRate = 15.00m,
    string VatCategory = "S");

/// <summary>
/// A tax document ready to be written and signed.
///
/// <see cref="AllowanceH"/> is the document-level discount without VAT
/// (Sale.DiscountH); <see cref="TaxH"/> the document's VAT (Sale.TaxH). They
/// are stated as stored, never recomputed, so the XML says exactly what the
/// receipt and the ledger say: sum(NetH) - AllowanceH + TaxH must be the
/// amount paid.
/// </summary>
public sealed record ZatcaDocument
{
    public required ZatcaDocumentType Type { get; init; }
    /// <summary>Simplified (B2C, reported) or standard (B2B, cleared).</summary>
    public required bool Simplified { get; init; }
    /// <summary>The document's own number, e.g. INV-1042 or CN-207.</summary>
    public required string Number { get; init; }
    public required Guid Uuid { get; init; }
    /// <summary>When it was issued, in Saudi time (no offset is written).</summary>
    public required DateTime IssuedAtLocal { get; init; }
    /// <summary>Invoice counter value: this EGS unit's chain position.</summary>
    public required long Icv { get; init; }
    /// <summary>The previous document's hash, in the chain's 88-character form (<see cref="ZatcaHash.ChainValue"/>).</summary>
    public required string PreviousHash { get; init; }
    public required ZatcaSeller Seller { get; init; }
    public ZatcaBuyer? Buyer { get; init; }
    /// <summary>UNTDID 4461: 10 cash, 48 card, 42 bank account, 30 credit transfer, 1 not defined (split, on account).</summary>
    public string PaymentMeansCode { get; init; } = "10";
    /// <summary>A credit or debit note: the invoice it corrects (BillingReference).</summary>
    public string? BillingReference { get; init; }
    /// <summary>A credit or debit note: why it was issued (KSA-10, PaymentMeans/InstructionNote).</summary>
    public string? Reason { get; init; }
    public required IReadOnlyList<ZatcaLine> Lines { get; init; }
    public long AllowanceH { get; init; }
    public required long TaxH { get; init; }
}
