/*==============================================================================
  Nazad POS — 003 · Gap-free invoice numbers

  Invoice numbers came from sales.InvoiceSequence. A sequence hands out its
  next value outside the transaction: when the sale then rolls back (stock ran
  out between the check and the write, a credit limit, a deadlock, a refused
  approval), the number is gone and the next sale skips it. INV-1013 went
  missing that way. ZATCA expects simplified tax invoices to be numbered
  consecutively, so a skipped number reads as a deleted invoice.

  sales.InvoiceCounter replaces it: one row, read and incremented inside the
  commit transaction under UPDLOCK/HOLDLOCK (sales.usp_CommitSale, 004). A
  rollback undoes the increment along with the sale, so the number is reused
  by the next sale that succeeds. The row lock is held only for the commit
  transaction, which is all writes and no validation (that runs before it).

  One counter for the whole business, not one per branch: invoice numbers are
  unique across branches (UQ_Sale_Invoice) and carry no branch prefix, so a
  per-branch counter would collide on INV-1001 at the second branch.

  Seeded from the highest INV-number already issued, so numbering carries on
  from where it is. sales.InvoiceSequence is left in place but no longer read.
==============================================================================*/

USE POSMAIN;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'sales.InvoiceCounter', N'U') IS NULL
BEGIN
    CREATE TABLE sales.InvoiceCounter
    (
        CounterKey   NVARCHAR(20) NOT NULL,
        Prefix       NVARCHAR(10) NOT NULL,
        /* The number the next committed sale gets. */
        NextNumber   BIGINT       NOT NULL,
        UpdatedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_InvoiceCounter_Updated DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_InvoiceCounter PRIMARY KEY CLUSTERED (CounterKey),
        CONSTRAINT CK_InvoiceCounter_Next CHECK (NextNumber > 0)
    );
END
GO

/* Seed once: one past the highest number issued (numeric part of INV-nnnn),
   or 1001 — where the sequence started — on a database with no sales yet. */
IF NOT EXISTS (SELECT 1 FROM sales.InvoiceCounter WHERE CounterKey = N'invoice')
BEGIN
    DECLARE @Next BIGINT =
        ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(InvoiceNumber, 5, 40) AS BIGINT))
                FROM sales.Sale
                WHERE InvoiceNumber LIKE N'INV-%'), 1000) + 1;

    INSERT INTO sales.InvoiceCounter (CounterKey, Prefix, NextNumber)
    VALUES (N'invoice', N'INV-', @Next);
END
GO
