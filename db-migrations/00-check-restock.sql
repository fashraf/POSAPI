/*==============================================================================
  Did the restock reach the database?

  Read-only. Run it after a restock and read down: the first empty result is
  where the chain stopped.
==============================================================================*/

USE POSMAIN;
GO

SET NOCOUNT ON;

PRINT N'';
PRINT N'--- 1. The purchase header ------------------------------------------';

SELECT TOP (5)
    p.Reference, p.InvoiceNumber, v.NameEn AS Vendor, p.BranchId,
    p.SubtotalH, p.TaxH, p.TotalH, p.PaidOnReceipt, p.ReceivedAtUtc, p.ReceivedBy
FROM inv.Purchase AS p
JOIN core.Vendor AS v ON v.VendorId = p.VendorId
ORDER BY p.ReceivedAtUtc DESC;

PRINT N'';
PRINT N'--- 2. Its lines ------------------------------------------------------';

SELECT TOP (10)
    p.Reference, i.NameEn AS Item, l.Quantity, l.UnitCostH,
    CAST(l.Quantity * l.UnitCostH AS BIGINT) AS LineTotalH
FROM inv.PurchaseLine AS l
JOIN inv.Purchase     AS p ON p.PurchaseId = l.PurchaseId
JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
ORDER BY p.ReceivedAtUtc DESC;

PRINT N'';
PRINT N'--- 3. Stock now, per branch -----------------------------------------';
PRINT N'    This is what the inventory grid shows. If the quantity did not move,';
PRINT N'    the receipt did not land - whatever the toast said.';

SELECT
    i.ItemId, i.NameEn, s.BranchId, s.Quantity,
    i.CostH AS WeightedAverageCostH, i.ReorderLevel, s.UpdatedAtUtc
FROM inv.StockLevel AS s
JOIN core.CatalogItem AS i ON i.ItemId = s.ItemId
WHERE i.TracksStock = 1
ORDER BY s.UpdatedAtUtc DESC;

PRINT N'';
PRINT N'--- 4. The movement --------------------------------------------------';
PRINT N'    Type should be "purchase" and BalanceAfter should equal the quantity above.';

SELECT TOP (10)
    m.OccurredAtUtc, i.NameEn, m.BranchId, m.MovementType,
    m.Quantity, m.BalanceAfter, m.UnitCostH, m.Reference, m.Actor
FROM inv.StockMovement AS m
JOIN core.CatalogItem AS i ON i.ItemId = m.ItemId
ORDER BY m.MovementId DESC;

PRINT N'';
PRINT N'--- 5. The ledger entry ----------------------------------------------';
PRINT N'    Inventory and Input VAT debited; Cash or Payables credited.';

SELECT TOP (10)
    e.Reference, e.Kind, e.SourceReference, e.PostedAtUtc,
    a.AccountCode, a.NameEn AS Account, l.DebitH, l.CreditH
FROM fin.JournalEntry AS e
JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
JOIN fin.Account      AS a ON a.AccountCode = l.AccountCode
WHERE e.Kind = N'purchase'
ORDER BY e.PostedAtUtc DESC, l.JournalLineId;

PRINT N'';
PRINT N'--- 6. Does the ledger still balance? --------------------------------';

SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM fin.vw_TrialBalanceCheck)
            THEN N'PASS  Ledger balances'
            ELSE N'FAIL  LEDGER DOES NOT BALANCE'
       END AS Result;

PRINT N'';
PRINT N'--- 7. Branch ids the API expects ------------------------------------';
PRINT N'    The grid reads stock for ONE branch. A row here with no matching';
PRINT N'    StockLevel row shows as zero, which looks like an empty shelf.';

SELECT b.BranchId, b.Code, b.NameEn,
       (SELECT COUNT(*) FROM inv.StockLevel AS s WHERE s.BranchId = b.BranchId) AS ItemsStocked
FROM core.Branch AS b
ORDER BY b.Code;
GO
