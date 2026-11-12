/*
  021 — when an offline sale was really taken.

  A sale the device took offline reaches the server when the network comes
  back, and the server dates the invoice then: SoldAtUtc is the moment the
  invoice is issued and numbered. That stays the sale's date everywhere it
  counts (invoice, ZATCA, ledger, drawer session, reports).

  TakenAtUtc is the till's own clock at the moment the customer paid, kept
  beside it so the till and the sale screens can still show it. Null for
  every sale made online, and for an offline sale whose clock looked wrong.
*/

ALTER TABLE sales.Sale ADD COLUMN IF NOT EXISTS TakenAtUtc timestamp(3) NULL;

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
    s.TakenAtUtc    AS TakenAt
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
