/*
  022 — ZATCA QR on every simplified tax invoice (Phase 1).

  A Saudi B2C receipt is a simplified tax invoice, and since December 2021 it
  must carry a QR code: base64 of five TLV fields (tag, length, UTF-8 value):

    1  seller's name           core.Company.NameAr (NameEn when it is blank)
    2  seller's VAT number     core.Company.VatNumber
    3  time of issue           SoldAtUtc in Riyadh time, yyyy-MM-ddTHH:mm:ss
                               (no "Z": ZATCA's validator warns on it)
    4  invoice total with VAT  TotalH as 0.00
    5  VAT total               TaxH as 0.00

  The payload is fixed when the sale is written, so a reprint shows exactly
  what the first print showed. sales.Sale.ZatcaQrPayload has been in the
  schema since 001 and nothing filled it. A sale written while the company has
  no VAT number gets none: without one the receipt is not a tax invoice.

  Phase 2 (signed XML) replaces the payload with the nine-tag one after the
  invoice is signed; the trigger only fills a payload nobody has set.
*/

/* One TLV field: tag byte, length, UTF-8 bytes. The length takes BER's long
   form from 128 bytes, as ZATCA's SDK writes it (one byte to 127, then 0x81 n,
   then 0x82 hi lo). */
CREATE OR REPLACE FUNCTION sales.fn_ZatcaTlv(p_Tag integer, p_Value text)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    v_Value  bytea   := convert_to(p_Value, 'UTF8');
    v_Length integer := length(v_Value);
    v_Prefix bytea;
BEGIN
    IF p_Tag < 1 OR p_Tag > 255 THEN
        RAISE EXCEPTION 'TLV tag % is out of range.', p_Tag;
    END IF;
    IF v_Length > 65535 THEN
        RAISE EXCEPTION 'TLV value is too long.';
    END IF;

    v_Prefix := CASE
        WHEN v_Length < 128 THEN set_byte('\x00'::bytea, 0, v_Length)
        WHEN v_Length < 256 THEN '\x81'::bytea || set_byte('\x00'::bytea, 0, v_Length)
        ELSE '\x82'::bytea || set_byte('\x00'::bytea, 0, v_Length >> 8)
                           || set_byte('\x00'::bytea, 0, v_Length & 255)
    END;

    RETURN set_byte('\x00'::bytea, 0, p_Tag) || v_Prefix || v_Value;
END $$;

/* Halalas as ZATCA writes money: 1150 -> '11.50'. */
CREATE OR REPLACE FUNCTION sales.fn_ZatcaAmount(p_AmountH bigint)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
AS $$ SELECT ((p_AmountH::numeric) / 100)::numeric(20, 2)::text $$;

/* The Phase 1 payload, or null when the seller has no VAT number. */
CREATE OR REPLACE FUNCTION sales.fn_ZatcaPhase1Qr(
    p_SellerName  text,
    p_VatNumber   text,
    p_IssuedAtUtc timestamp,
    p_TotalH      bigint,
    p_TaxH        bigint)
RETURNS varchar
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF COALESCE(btrim(p_VatNumber), '') = '' OR COALESCE(btrim(p_SellerName), '') = ''
       OR p_IssuedAtUtc IS NULL OR p_TotalH IS NULL OR p_TaxH IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN replace(encode(
           sales.fn_ZatcaTlv(1, btrim(p_SellerName))
        || sales.fn_ZatcaTlv(2, btrim(p_VatNumber))
        || sales.fn_ZatcaTlv(3, to_char((p_IssuedAtUtc AT TIME ZONE 'utc') AT TIME ZONE 'Asia/Riyadh',
                                        'YYYY-MM-DD"T"HH24:MI:SS'))
        || sales.fn_ZatcaTlv(4, sales.fn_ZatcaAmount(p_TotalH))
        || sales.fn_ZatcaTlv(5, sales.fn_ZatcaAmount(p_TaxH)),
        'base64'), E'\n', '')::varchar;
END $$;

/* The seller's name and VAT number as the QR states them. */
CREATE OR REPLACE FUNCTION sales.fn_ZatcaSeller()
RETURNS TABLE (SellerName varchar, VatNumber varchar)
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(btrim(c.NameAr), ''), c.NameEn)::varchar,
           c.VatNumber::varchar
    FROM core.Company AS c
    ORDER BY c.CompanyId
    LIMIT 1
$$;

CREATE OR REPLACE FUNCTION sales.trg_Sale_ZatcaQr()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_Name varchar;
    v_Vat  varchar;
BEGIN
    IF NEW.ZatcaQrPayload IS NULL THEN
        SELECT s.SellerName, s.VatNumber INTO v_Name, v_Vat FROM sales.fn_ZatcaSeller() AS s;
        NEW.ZatcaQrPayload := sales.fn_ZatcaPhase1Qr(v_Name, v_Vat, NEW.SoldAtUtc, NEW.TotalH, NEW.TaxH);
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS TR_Sale_ZatcaQr ON sales.Sale;
CREATE TRIGGER TR_Sale_ZatcaQr
    BEFORE INSERT ON sales.Sale
    FOR EACH ROW EXECUTE FUNCTION sales.trg_Sale_ZatcaQr();

/* Sales written before this file: a reprint of one now carries its QR. */
UPDATE sales.Sale AS s
SET ZatcaQrPayload = sales.fn_ZatcaPhase1Qr(c.SellerName, c.VatNumber, s.SoldAtUtc, s.TotalH, s.TaxH)
FROM sales.fn_ZatcaSeller() AS c
WHERE s.ZatcaQrPayload IS NULL;

/* The sale screens and the receipt read the payload from the summary view.
   021's view, with ZatcaQrPayload added at the end. */
CREATE OR REPLACE VIEW sales.vw_SaleSummary AS
SELECT
    s.SaleId,
    s.InvoiceNumber,
    s.BranchId,
    b.NameAr        AS BranchNameAr,
    b.NameEn        AS BranchNameEn,
    s.CustomerId,
    c.NameAr        AS CustomerNameAr,
    c.NameEn        AS CustomerNameEn,
    s.ServedByUserId,
    u.NameAr        AS ServedByNameAr,
    u.NameEn        AS ServedByNameEn,
    s.CashierName,

    /* One basis: SubtotalH (ex-VAT, before the invoice discount)
       − DiscountH (ex-VAT) + TaxH = TotalH (VAT inclusive). */
    s.SubtotalH,
    s.DiscountH,
    s.TaxH,
    s.TotalH,

    /* The receipt's two missing figures.
       TenderedH is null for a sale with no cash leg, and null reaches the client
       as null rather than as a missing key — which it can test for. Change is
       never null: nothing tendered means nothing given back. */
    s.TenderedH,
    COALESCE(s.ChangeH, 0) AS ChangeH,

    s.DiscountId,
    s.Status,
    s.SoldAtUtc,
    /* The client's field is `soldAt`. Carrying both costs nothing and saves a
       rename on either side. */
    s.SoldAtUtc     AS SoldAt,

    (SELECT COUNT(*)::int FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId) AS LineCount,
    COALESCE((SELECT SUM(sl.Quantity) FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId), 0) AS ItemCount,

    /* The one method used, or 'mixed'. */
    pm.PaymentMethod,

    s.OverrideApprovedBy,
    s.OverrideReason,

    /* Offline sales only: when the till took it (021). */
    s.TakenAtUtc,
    s.TakenAtUtc    AS TakenAt,

    /* ZATCA QR payload (022): base64 TLV, printed as the receipt's QR. */
    s.ZatcaQrPayload
FROM sales.Sale AS s
LEFT JOIN core.Branch   AS b ON b.BranchId   = s.BranchId
LEFT JOIN core.Customer AS c ON c.CustomerId = s.CustomerId
LEFT JOIN core.AppUser  AS u ON u.UserId     = s.ServedByUserId
LEFT JOIN LATERAL (
    SELECT (CASE WHEN COUNT(DISTINCT p.Method) > 1 THEN 'mixed'
                 ELSE MAX(p.Method) END)::varchar AS PaymentMethod
    FROM sales.SalePayment AS p
    WHERE p.SaleId = s.SaleId AND p.AmountH > 0
) AS pm ON true;

