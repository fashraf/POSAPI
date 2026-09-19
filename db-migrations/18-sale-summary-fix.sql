/*==============================================================================
  Nazad POS — 18 · Complete the sale summary view

  sales.vw_SaleSummary omitted TenderedH and ChangeH. Both are on the sale row;
  the view simply never selected them.

  The receipt needs them: a cash sale shows what was handed over and what came
  back. Reading an absent column gives undefined, and `undefined - number` is
  NaN — which reached the screen as "SAR NaN" rather than as an error naming the
  missing field.

  CashierName and SoldAt are added for the same reason: the type the client
  builds expects them, and a column that is merely absent fails silently.
==============================================================================*/

USE POSMAIN;
GO

/* ALTER rather than DROP: dropping would break anything referencing it, and the
   column list is the only thing changing. */
ALTER VIEW sales.vw_SaleSummary
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

    (SELECT COUNT(*) FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId) AS LineCount
FROM sales.Sale AS s
LEFT JOIN core.Branch   AS b ON b.BranchId   = s.BranchId
LEFT JOIN core.Customer AS c ON c.CustomerId = s.CustomerId
LEFT JOIN core.AppUser  AS u ON u.UserId     = s.ServedByUserId;
GO

PRINT N'18 · Sale summary view completed.';
GO

/*------------------------------------------------------------------ check */

/* Every field the receipt reads must now be present. */
SELECT
    CASE WHEN COUNT(*) = 6 THEN N'PASS' ELSE N'FAIL' END
    + N'  Receipt columns present (' + CAST(COUNT(*) AS NVARCHAR(10)) + N'/6)' AS Result
FROM sys.columns
WHERE object_id = OBJECT_ID(N'sales.vw_SaleSummary')
  AND name IN (N'TenderedH', N'ChangeH', N'CashierName', N'SoldAt', N'TotalH', N'InvoiceNumber');
GO
