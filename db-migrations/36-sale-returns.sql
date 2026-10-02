/*==============================================================================
  Nazad POS — 36 · Sale returns (credit notes)

  Backs POST/GET /api/sales/{saleId}/returns and
  GET /api/sales/{saleId}/returns/remaining.

  A return is a later, real transaction against a completed sale — unlike a
  void, which says the sale never happened. sales.usp_IssueReturn does all of
  it in one transaction:
    - checks every line against what is still returnable
      (SaleLine.Quantity - SaleLine.ReturnedQty) under a lock on the sale, so
      two returns at once cannot over-return;
    - prices the return from what the customer actually paid: the line's own
      net (after its line discount) pro rata to the quantity, less its share of
      the invoice discount. VAT is the sale's own VAT ratio. The return that
      takes the last unit refunds exactly what is left of the sale's total and
      VAT, so a fully returned sale nets to zero to the halala;
    - puts tracked stock back (inv.StockMovement 'return');
    - reduces unpaid commission on returned services in proportion;
    - refunds: cash 1000, card 1150, bank 1100, or credit 1400 (the customer's
      balance goes down; refused when it would go below zero — refund in cash
      instead);
    - posts one balanced 'return' entry:
          Dr 4100 sales (net of VAT)   Dr 2100 output VAT   Cr refund account
          Dr 1200 inventory            Cr 5100 COGS          (tracked items)
      Revenue is reversed on 4100 itself, as the finance screens expect
      ("returns reverse the revenue account").
    - marks the sale partially_returned or returned.

  sales.usp_VoidSale now refuses a sale that has returns: voiding it would
  restock and refund the returned units a second time.

  Schema
    - sales.SaleReturn gains NoteNumber, BranchId, CustomerId, ReasonCode,
      Note, SubtotalH, TaxH, CogsH, RefundMethod, EntryId.
    - sales.SaleReturnLine gains ItemId, UnitPriceH, UnitCostH, AmountH.
    - sales.CreditNoteSequence, sales.ReturnLineTable.
    - Permission sales.return is granted to the manager role (it already holds
      sales.refund).

  Error numbers 67000–67099.
==============================================================================*/

USE POSMAIN;
GO

/*---------------------------------------------------------------------- schema */

IF COL_LENGTH(N'sales.SaleReturn', N'NoteNumber') IS NULL
    ALTER TABLE sales.SaleReturn ADD
        NoteNumber   NVARCHAR(40)  NULL,
        BranchId     NVARCHAR(40)  NULL,
        CustomerId   NVARCHAR(40)  NULL,
        ReasonCode   NVARCHAR(30)  NULL,
        Note         NVARCHAR(400) NULL,
        SubtotalH    BIGINT NOT NULL CONSTRAINT DF_SaleReturn_Subtotal DEFAULT (0),
        TaxH         BIGINT NOT NULL CONSTRAINT DF_SaleReturn_Tax DEFAULT (0),
        CogsH        BIGINT NOT NULL CONSTRAINT DF_SaleReturn_Cogs DEFAULT (0),
        RefundMethod NVARCHAR(20)  NULL,
        EntryId      NVARCHAR(40)  NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_SaleReturn_Method')
    ALTER TABLE sales.SaleReturn ADD CONSTRAINT CK_SaleReturn_Method
        CHECK (RefundMethod IS NULL OR RefundMethod IN (N'cash', N'card', N'credit', N'bank'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_SaleReturn_Reason')
    ALTER TABLE sales.SaleReturn ADD CONSTRAINT CK_SaleReturn_Reason
        CHECK (ReasonCode IS NULL OR ReasonCode IN
               (N'damaged', N'not_as_described', N'changed_mind', N'wrong_item', N'other'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_SaleReturn_NoteNumber')
    CREATE UNIQUE INDEX UX_SaleReturn_NoteNumber ON sales.SaleReturn (NoteNumber)
        WHERE NoteNumber IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SaleReturn_Sale')
    CREATE INDEX IX_SaleReturn_Sale ON sales.SaleReturn (SaleId);
GO

IF COL_LENGTH(N'sales.SaleReturnLine', N'ItemId') IS NULL
    ALTER TABLE sales.SaleReturnLine ADD
        ItemId     NVARCHAR(40) NULL,
        UnitPriceH BIGINT NOT NULL CONSTRAINT DF_SaleReturnLine_Price DEFAULT (0),
        UnitCostH  BIGINT NOT NULL CONSTRAINT DF_SaleReturnLine_Cost DEFAULT (0),
        AmountH    BIGINT NOT NULL CONSTRAINT DF_SaleReturnLine_Amount DEFAULT (0);
GO

IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = N'CreditNoteSequence'
                                            AND SCHEMA_NAME(schema_id) = N'sales')
    CREATE SEQUENCE sales.CreditNoteSequence AS BIGINT START WITH 200 INCREMENT BY 1;
GO

IF TYPE_ID(N'sales.ReturnLineTable') IS NULL
    CREATE TYPE sales.ReturnLineTable AS TABLE
    (
        SaleLineId BIGINT        NOT NULL,
        Quantity   DECIMAL(18,3) NOT NULL
    );
GO

/*------------------------------------------------------------- issue a return */

CREATE OR ALTER PROCEDURE sales.usp_IssueReturn
    @SaleId       NVARCHAR(40),
    @ReasonCode   NVARCHAR(30),
    @Note         NVARCHAR(400) = NULL,
    @RefundMethod NVARCHAR(20),
    @Actor        NVARCHAR(120),
    @Lines        sales.ReturnLineTable READONLY,
    @ReturnId     NVARCHAR(40) OUTPUT,
    @NoteNumber   NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    IF @ReasonCode IS NULL OR @ReasonCode NOT IN
       (N'damaged', N'not_as_described', N'changed_mind', N'wrong_item', N'other')
        THROW 67008, N'Choose a reason for the return.', 1;

    IF @ReasonCode = N'other' AND @Note IS NULL
        THROW 67009, N'Describe the reason when choosing "Other".', 1;

    IF @RefundMethod IS NULL OR @RefundMethod NOT IN (N'cash', N'card', N'credit', N'bank')
        THROW 67005, N'Refund by cash, card, bank or to the customer''s account.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE Quantity < 0)
        THROW 67010, N'Return quantities cannot be negative.', 1;

    DECLARE @Req TABLE (SaleLineId BIGINT PRIMARY KEY, Qty DECIMAL(18,3) NOT NULL);

    INSERT INTO @Req (SaleLineId, Qty)
    SELECT SaleLineId, SUM(Quantity) FROM @Lines WHERE Quantity > 0 GROUP BY SaleLineId;

    IF NOT EXISTS (SELECT 1 FROM @Req)
        THROW 67002, N'Choose at least one item to return.', 1;

    BEGIN TRAN;

        DECLARE @Status NVARCHAR(40), @BranchId NVARCHAR(40), @CustomerId NVARCHAR(40),
                @Invoice NVARCHAR(40), @SaleTotalH BIGINT, @SaleTaxH BIGINT, @SaleDiscountH BIGINT;

        /* The lock serialises returns against one sale. */
        SELECT @Status = Status, @BranchId = BranchId, @CustomerId = CustomerId,
               @Invoice = InvoiceNumber, @SaleTotalH = TotalH, @SaleTaxH = TaxH,
               @SaleDiscountH = DiscountH
        FROM sales.Sale WITH (UPDLOCK, HOLDLOCK)
        WHERE SaleId = @SaleId;

        IF @Invoice IS NULL
            THROW 67000, N'Sale not found.', 1;

        IF @Status = N'voided'
            THROW 67001, N'A voided sale has nothing left to return.', 1;

        IF EXISTS (SELECT 1 FROM @Req AS r
                   WHERE NOT EXISTS (SELECT 1 FROM sales.SaleLine AS sl
                                     WHERE sl.SaleLineId = r.SaleLineId AND sl.SaleId = @SaleId))
            THROW 67003, N'That line is not part of this invoice.', 1;

        IF EXISTS (SELECT 1 FROM @Req AS r
                   JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
                   WHERE r.Qty > sl.Quantity - sl.ReturnedQty)
            THROW 67004, N'You cannot return more than was sold and not already returned.', 1;

        /*------------------------------------------------------ price it */

        DECLARE @GrossH BIGINT = (SELECT SUM(UnitPriceH * Quantity - LineDiscountH)
                                  FROM sales.SaleLine WHERE SaleId = @SaleId);

        DECLARE @Calc TABLE
        (
            SaleLineId BIGINT PRIMARY KEY,
            ItemId     NVARCHAR(40),
            Qty        DECIMAL(18,3),
            UnitPriceH BIGINT,
            UnitCostH  BIGINT,
            Tracks     BIT,
            IsService  BIT,
            PortionH   BIGINT,
            AmountH    BIGINT
        );

        INSERT INTO @Calc (SaleLineId, ItemId, Qty, UnitPriceH, UnitCostH, Tracks, IsService, PortionH, AmountH)
        SELECT sl.SaleLineId, sl.ItemId, r.Qty, sl.UnitPriceH, sl.UnitCostH,
               ISNULL(ci.TracksStock, 0),
               CASE WHEN sl.Kind = N'service' THEN 1 ELSE 0 END,
               CAST(ROUND(CAST(sl.UnitPriceH * sl.Quantity - sl.LineDiscountH AS DECIMAL(38,6))
                          * r.Qty / sl.Quantity, 0) AS BIGINT),
               0
        FROM @Req AS r
        JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
        LEFT JOIN core.CatalogItem AS ci ON ci.ItemId = sl.ItemId;

        /* Each line gives back its share of the invoice discount. */
        UPDATE @Calc
        SET AmountH = PortionH - CASE WHEN @GrossH > 0
                                      THEN CAST(ROUND(CAST(@SaleDiscountH AS DECIMAL(38,6)) * PortionH / @GrossH, 0) AS BIGINT)
                                      ELSE 0 END;

        DECLARE @Completes BIT =
            CASE WHEN EXISTS (SELECT 1 FROM sales.SaleLine AS sl
                              LEFT JOIN @Req AS r ON r.SaleLineId = sl.SaleLineId
                              WHERE sl.SaleId = @SaleId
                                AND sl.Quantity - sl.ReturnedQty - ISNULL(r.Qty, 0) > 0)
                 THEN 0 ELSE 1 END;

        DECLARE @PriorTotalH BIGINT = ISNULL((SELECT SUM(RefundH) FROM sales.SaleReturn WHERE SaleId = @SaleId), 0);
        DECLARE @PriorTaxH   BIGINT = ISNULL((SELECT SUM(TaxH)    FROM sales.SaleReturn WHERE SaleId = @SaleId), 0);

        DECLARE @TotalH BIGINT = (SELECT SUM(AmountH) FROM @Calc);

        /* The last return takes exactly what is left, so rounding never leaves
           a halala behind (or refunds one too many). The difference lands on
           the largest line. */
        IF @Completes = 1
        BEGIN
            DECLARE @Residue BIGINT = (@SaleTotalH - @PriorTotalH) - @TotalH;

            IF @Residue <> 0
                UPDATE c SET AmountH = c.AmountH + @Residue
                FROM @Calc AS c
                WHERE c.SaleLineId = (SELECT TOP (1) SaleLineId FROM @Calc ORDER BY AmountH DESC, SaleLineId);

            SET @TotalH = @SaleTotalH - @PriorTotalH;
        END

        IF @TotalH < 0 SET @TotalH = 0;

        DECLARE @TaxH BIGINT =
            CASE WHEN @Completes = 1 THEN @SaleTaxH - @PriorTaxH
                 WHEN @SaleTotalH > 0
                      THEN CAST(ROUND(CAST(@TotalH AS DECIMAL(38,6)) * @SaleTaxH / @SaleTotalH, 0) AS BIGINT)
                 ELSE 0 END;

        IF @TaxH < 0 SET @TaxH = 0;
        IF @TaxH > @TotalH SET @TaxH = @TotalH;

        DECLARE @NetH  BIGINT = @TotalH - @TaxH;
        DECLARE @CogsH BIGINT = ISNULL((SELECT SUM(CAST(ROUND(Qty * UnitCostH, 0) AS BIGINT))
                                        FROM @Calc WHERE Tracks = 1), 0);

        /*------------------------------------------------- refund checks */

        IF @RefundMethod = N'credit'
        BEGIN
            IF @CustomerId IS NULL
                THROW 67006, N'A refund to account needs a customer on the sale.', 1;

            IF @TotalH > ISNULL((SELECT BalanceH FROM core.Customer WITH (UPDLOCK)
                                 WHERE CustomerId = @CustomerId), 0)
                THROW 67007, N'The refund is more than the customer owes. Refund it in cash or by card instead.', 1;
        END

        /*--------------------------------------------------------- write */

        DECLARE @Seq BIGINT = NEXT VALUE FOR sales.CreditNoteSequence;
        SET @ReturnId   = CONCAT(N'ret_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @NoteNumber = CONCAT(N'CN-', @Seq);

        INSERT INTO sales.SaleReturn
            (ReturnId, SaleId, ReasonAr, ReasonEn, RefundH, ReturnedBy,
             NoteNumber, BranchId, CustomerId, ReasonCode, Note,
             SubtotalH, TaxH, CogsH, RefundMethod)
        VALUES
            (@ReturnId, @SaleId, @Note, ISNULL(@Note, @ReasonCode), @TotalH, @Actor,
             @NoteNumber, @BranchId, @CustomerId, @ReasonCode, @Note,
             @NetH, @TaxH, @CogsH, @RefundMethod);

        INSERT INTO sales.SaleReturnLine (ReturnId, SaleLineId, Quantity, ItemId, UnitPriceH, UnitCostH, AmountH)
        SELECT @ReturnId, SaleLineId, Qty, ItemId, UnitPriceH, UnitCostH, AmountH FROM @Calc;

        /* Commission on returned work was not earned. Only what payroll has not
           yet paid is reduced, in proportion to what remains of the item. */
        DECLARE @Comm TABLE (ItemId NVARCHAR(40) PRIMARY KEY, BeforeQty DECIMAL(18,3), AfterQty DECIMAL(18,3));

        INSERT INTO @Comm (ItemId, BeforeQty, AfterQty)
        SELECT sl.ItemId,
               SUM(sl.Quantity - sl.ReturnedQty),
               SUM(sl.Quantity - sl.ReturnedQty - ISNULL(r.Qty, 0))
        FROM sales.SaleLine AS sl
        LEFT JOIN @Req AS r ON r.SaleLineId = sl.SaleLineId
        WHERE sl.SaleId = @SaleId
          AND sl.ItemId IN (SELECT ItemId FROM @Calc WHERE IsService = 1)
        GROUP BY sl.ItemId;

        DELETE ce
        FROM fin.CommissionEntry AS ce
        JOIN @Comm AS c ON c.ItemId = ce.ItemId
        WHERE ce.SaleId = @SaleId AND ce.PayrollRunId IS NULL AND c.AfterQty <= 0;

        UPDATE ce
        SET AmountH = CAST(ROUND(CAST(ce.AmountH AS DECIMAL(38,6)) * c.AfterQty / c.BeforeQty, 0) AS BIGINT)
        FROM fin.CommissionEntry AS ce
        JOIN @Comm AS c ON c.ItemId = ce.ItemId
        WHERE ce.SaleId = @SaleId AND ce.PayrollRunId IS NULL
          AND c.AfterQty > 0 AND c.BeforeQty > c.AfterQty;

        UPDATE sl
        SET ReturnedQty = sl.ReturnedQty + r.Qty
        FROM sales.SaleLine AS sl
        JOIN @Req AS r ON r.SaleLineId = sl.SaleLineId;

        UPDATE sales.Sale
        SET Status = CASE WHEN @Completes = 1 THEN N'returned' ELSE N'partially_returned' END,
            UpdatedAtUtc = SYSUTCDATETIME(),
            UpdatedBy = @Actor
        WHERE SaleId = @SaleId;

        /* Stock comes back to the branch that sold it. */
        IF @BranchId IS NOT NULL
        BEGIN
            INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
            SELECT DISTINCT c.ItemId, @BranchId, 0
            FROM @Calc AS c
            WHERE c.Tracks = 1
              AND NOT EXISTS (SELECT 1 FROM inv.StockLevel AS s
                              WHERE s.ItemId = c.ItemId AND s.BranchId = @BranchId);

            UPDATE s
            SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = SYSUTCDATETIME()
            FROM inv.StockLevel AS s
            JOIN (SELECT ItemId, SUM(Qty) AS Qty FROM @Calc WHERE Tracks = 1 GROUP BY ItemId) AS agg
                 ON agg.ItemId = s.ItemId
            WHERE s.BranchId = @BranchId;

            INSERT INTO inv.StockMovement
                (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
                 Reference, ReasonEn, ReasonAr, Actor)
            SELECT agg.ItemId, @BranchId, N'return', agg.Qty, s.Quantity, agg.UnitCostH,
                   @NoteNumber, CONCAT(N'Return against ', @Invoice), CONCAT(N'مرتجع على ', @Invoice), @Actor
            FROM (SELECT ItemId, SUM(Qty) AS Qty, MAX(UnitCostH) AS UnitCostH
                  FROM @Calc WHERE Tracks = 1 GROUP BY ItemId) AS agg
            JOIN inv.StockLevel AS s ON s.ItemId = agg.ItemId AND s.BranchId = @BranchId;
        END

        IF @RefundMethod = N'credit' AND @TotalH > 0
            UPDATE core.Customer
            SET BalanceH = BalanceH - @TotalH, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
            WHERE CustomerId = @CustomerId;

        IF @TotalH > 0 OR @CogsH > 0
        BEGIN
            DECLARE @Entry fin.JournalLineTable;
            INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                (N'4100', @NetH, 0, N'Sales returned'),
                (N'2100', @TaxH, 0, N'Output VAT reversed'),
                (CASE @RefundMethod WHEN N'cash' THEN N'1000'
                                    WHEN N'card' THEN N'1150'
                                    WHEN N'bank' THEN N'1100'
                                    ELSE N'1400' END, 0, @TotalH, CONCAT(N'Refund — ', @RefundMethod)),
                (N'1200', @CogsH, 0, N'Inventory returned'),
                (N'5100', 0, @CogsH, N'Cost of goods sold reversed');

            DECLARE @DescEn NVARCHAR(400) = CONCAT(N'Credit note ', @NoteNumber, N' for ', @Invoice);
            DECLARE @DescAr NVARCHAR(400) = CONCAT(N'إشعار دائن ', @NoteNumber, N' للفاتورة ', @Invoice);
            DECLARE @EntryId NVARCHAR(40);

            EXEC fin.usp_PostJournalEntry
                @Kind            = N'return',
                @DescriptionEn   = @DescEn,
                @DescriptionAr   = @DescAr,
                @SourceReference = @NoteNumber,
                @BranchId        = @BranchId,
                @Actor           = @Actor,
                @Lines           = @Entry,
                @EntryId         = @EntryId OUTPUT;

            UPDATE sales.SaleReturn SET EntryId = @EntryId WHERE ReturnId = @ReturnId;
        END

    COMMIT;
END
GO

/*--------------------------------------------------- void refuses a returned sale */

CREATE OR ALTER PROCEDURE sales.usp_VoidSale
    @SaleId NVARCHAR(40),
    @Reason NVARCHAR(400),
    @Actor  NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM sales.Sale WHERE SaleId = @SaleId)
        THROW 52010, N'Sale not found.', 1;

    IF EXISTS (SELECT 1 FROM sales.Sale WHERE SaleId = @SaleId AND Status = N'voided')
        THROW 52011, N'This sale is already voided.', 1;

    IF LTRIM(RTRIM(ISNULL(@Reason, N''))) = N''
        THROW 52012, N'A void needs a reason on the record.', 1;

    /* Returned units were already restocked and refunded. Voiding would do
       both again. */
    IF EXISTS (SELECT 1 FROM sales.SaleReturn WHERE SaleId = @SaleId)
        THROW 67012, N'This sale has returns against it and cannot be voided.', 1;

    DECLARE @BranchId NVARCHAR(40), @InvoiceNumber NVARCHAR(40), @CustomerId NVARCHAR(40);
    SELECT @BranchId = BranchId, @InvoiceNumber = InvoiceNumber, @CustomerId = CustomerId
    FROM sales.Sale WHERE SaleId = @SaleId;

    BEGIN TRAN;

        /* Stock comes back. */
        UPDATE s
        SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = SYSUTCDATETIME()
        FROM inv.StockLevel AS s
        JOIN (SELECT sl.ItemId, SUM(sl.Quantity) AS Qty
              FROM sales.SaleLine AS sl
              JOIN core.CatalogItem AS i ON i.ItemId = sl.ItemId
              WHERE sl.SaleId = @SaleId AND i.TracksStock = 1
              GROUP BY sl.ItemId) AS agg ON agg.ItemId = s.ItemId
        WHERE s.BranchId = @BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, Actor)
        SELECT
            sl.ItemId, @BranchId, N'return', SUM(sl.Quantity),
            ISNULL(st.Quantity, 0), sl.UnitCostH,
            @InvoiceNumber, @Reason, @Reason, @Actor
        FROM sales.SaleLine AS sl
        JOIN core.CatalogItem AS i ON i.ItemId = sl.ItemId
        LEFT JOIN inv.StockLevel AS st ON st.ItemId = sl.ItemId AND st.BranchId = @BranchId
        WHERE sl.SaleId = @SaleId AND i.TracksStock = 1
        GROUP BY sl.ItemId, sl.UnitCostH, st.Quantity;

        /* Any credit taken is released. */
        DECLARE @CreditH BIGINT = ISNULL((
            SELECT SUM(AmountH) FROM sales.SalePayment
            WHERE SaleId = @SaleId AND Method = N'credit'), 0);

        IF @CreditH > 0 AND @CustomerId IS NOT NULL
        BEGIN
            UPDATE core.Customer
            SET BalanceH = BalanceH - @CreditH, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE CustomerId = @CustomerId;
        END

        /* Commission earned on a voided sale was never earned. */
        DELETE FROM fin.CommissionEntry
        WHERE SaleId = @SaleId AND PayrollRunId IS NULL;

        /* Reverse the ledger entry rather than deleting it. */
        DECLARE @OriginalEntryId NVARCHAR(40) = (
            SELECT TOP (1) EntryId FROM fin.JournalEntry
            WHERE SourceReference = @InvoiceNumber AND Kind = N'sale'
              AND ReversedByEntryId IS NULL
            ORDER BY PostedAtUtc DESC);

        IF @OriginalEntryId IS NOT NULL
        BEGIN
            DECLARE @ReversalId NVARCHAR(40);
            EXEC fin.usp_ReverseJournalEntry
                @EntryId = @OriginalEntryId, @Reason = @Reason,
                @Actor = @Actor, @NewEntryId = @ReversalId OUTPUT;
        END

        UPDATE sales.Sale
        SET Status = N'voided', UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE SaleId = @SaleId;

    COMMIT;
END
GO

/*----------------------------------------------------------------- permission */

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT v.RoleId, N'sales.return'
FROM (VALUES (N'rol_owner'), (N'rol_manager')) AS v (RoleId)
WHERE EXISTS (SELECT 1 FROM core.Role WHERE RoleId = v.RoleId)
  AND EXISTS (SELECT 1 FROM core.Permission WHERE PermissionKey = N'sales.return')
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission
                  WHERE RoleId = v.RoleId AND PermissionKey = N'sales.return');
GO

PRINT N'36 · Sale returns ready.';
GO

SELECT
    CASE WHEN OBJECT_ID(N'sales.usp_IssueReturn') IS NULL THEN N'FAIL  return proc missing'
         WHEN COL_LENGTH(N'sales.SaleReturn', N'NoteNumber') IS NULL THEN N'FAIL  columns missing'
         WHEN TYPE_ID(N'sales.ReturnLineTable') IS NULL THEN N'FAIL  line type missing'
         ELSE N'PASS  Sale returns ready'
    END AS Result;
GO
