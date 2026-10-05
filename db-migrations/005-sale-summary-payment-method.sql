/*==============================================================================
  Nazad POS — 005 · How a sale was paid, on the sale summary

  The sales list reads sales.vw_SaleSummary, which carried no payments, and
  the screen fell back to "Cash" for every row: INV-1001 (card), INV-1016
  (credit) and INV-1018 (card + cash) all read as cash. The view now says how
  each sale was paid:

    PaymentMethod   cash | card | credit | bank, or mixed when more than one
                    method was used; null for a sale with no payment rows
    ItemCount       units sold (the list's Items column, which summed the
                    lines a list row does not carry and so always showed 0)

  Everything else is unchanged, so GET /api/sales/{id} and the list keep
  every field they had. Other columns from 004 (OverrideApprovedBy,
  OverrideReason) are added for the detail view.
==============================================================================*/

USE POSMAIN;
GO

CREATE OR ALTER VIEW sales.vw_SaleSummary
AS
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

    /* One basis since 004: SubtotalH (ex-VAT, before the invoice discount)
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
    ISNULL(s.ChangeH, 0) AS ChangeH,

    s.DiscountId,
    s.Status,
    s.SoldAtUtc,
    /* The client's field is `soldAt`. Carrying both costs nothing and saves a
       rename on either side. */
    s.SoldAtUtc     AS SoldAt,

    (SELECT COUNT(*) FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId) AS LineCount,
    ISNULL((SELECT SUM(sl.Quantity) FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId), 0) AS ItemCount,

    /* The one method used, or 'mixed'. */
    pm.PaymentMethod,

    s.OverrideApprovedBy,
    s.OverrideReason
FROM sales.Sale AS s
LEFT JOIN core.Branch   AS b ON b.BranchId   = s.BranchId
LEFT JOIN core.Customer AS c ON c.CustomerId = s.CustomerId
LEFT JOIN core.AppUser  AS u ON u.UserId     = s.ServedByUserId
OUTER APPLY (
    SELECT CASE WHEN COUNT(DISTINCT p.Method) > 1 THEN N'mixed'
                ELSE MAX(p.Method) END AS PaymentMethod
    FROM sales.SalePayment AS p
    WHERE p.SaleId = s.SaleId AND p.AmountH > 0
) AS pm;
GO
