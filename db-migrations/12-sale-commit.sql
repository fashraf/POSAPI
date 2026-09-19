/*==============================================================================
  Nazad POS — 12 · Sale commit

  One procedure, one transaction.

  Committing a sale is six writes that must all happen or none of them: the
  sale, its lines, its payments, the stock movement, the frozen commission and
  the ledger entry. Doing this from the API in six calls means a network blip
  between calls three and four leaves stock reduced for a sale that does not
  exist. Here, either the whole thing lands or nothing does.
==============================================================================*/

USE POSMAIN;
GO

/* Line and payment input, so a whole basket arrives in one round trip. */
CREATE TYPE sales.SaleLineTable AS TABLE
(
    ItemId          NVARCHAR(40)   NOT NULL,
    Quantity        DECIMAL(18,3)  NOT NULL,
    UnitPriceH      BIGINT         NOT NULL,
    LineDiscountH   BIGINT         NOT NULL DEFAULT (0),
    Note            NVARCHAR(400)  NULL
);
GO

CREATE TYPE sales.SalePaymentTable AS TABLE
(
    Method          NVARCHAR(20)   NOT NULL,
    AmountH         BIGINT         NOT NULL,
    Reference       NVARCHAR(80)   NULL
);
GO

CREATE SEQUENCE sales.InvoiceSequence AS BIGINT START WITH 1001 INCREMENT BY 1;
GO

CREATE PROCEDURE sales.usp_CommitSale
    @BranchId        NVARCHAR(40),
    @CustomerId      NVARCHAR(40) = NULL,
    @ServedByUserId  NVARCHAR(40) = NULL,
    @CashierName     NVARCHAR(160),
    @DiscountId      NVARCHAR(40) = NULL,
    @DiscountH       BIGINT = 0,
    @TenderedH       BIGINT = NULL,
    @Lines           sales.SaleLineTable    READONLY,
    @Payments        sales.SalePaymentTable READONLY,
    @SaleId          NVARCHAR(40) OUTPUT,
    @InvoiceNumber   NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- any error rolls the whole thing back

    /*-------------------------------------------------- validate before writing */

    IF NOT EXISTS (SELECT 1 FROM @Lines)
        THROW 52000, N'A sale needs at least one line.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE Quantity <= 0)
        THROW 52001, N'Quantities must be above zero.', 1;

    IF EXISTS (SELECT 1 FROM @Lines AS l
               WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem AS i
                                 WHERE i.ItemId = l.ItemId AND i.IsActive = 1))
        THROW 52002, N'A line refers to an item that does not exist or is inactive.', 1;

    DECLARE @VatRate DECIMAL(5,2) =
        ISNULL((SELECT VatRatePercent FROM core.BranchSettings WHERE BranchId = @BranchId), 15.00);

    DECLARE @AllowNegative BIT =
        ISNULL((SELECT AllowNegativeStock FROM core.BranchSettings WHERE BranchId = @BranchId), 0);

    /* Refuse to oversell unless the branch permits it. Checked before any write
       so the basket is rejected whole rather than half-committed. */
    IF @AllowNegative = 0 AND EXISTS (
        SELECT 1
        FROM @Lines AS l
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
        LEFT JOIN inv.StockLevel AS s ON s.ItemId = l.ItemId AND s.BranchId = @BranchId
        WHERE i.TracksStock = 1 AND ISNULL(s.Quantity, 0) < l.Quantity)
    BEGIN
        THROW 52003, N'Not enough stock for one or more items.', 1;
    END

    DECLARE @GrossH BIGINT =
        (SELECT SUM(l.UnitPriceH * l.Quantity - l.LineDiscountH) FROM @Lines AS l);

    IF @DiscountH < 0 OR @DiscountH > @GrossH
        THROW 52004, N'The discount cannot exceed the basket total.', 1;

    DECLARE @NetOfDiscountH BIGINT = @GrossH - @DiscountH;

    /* VAT is extracted from the gross: Saudi retail quotes prices inclusive. */
    DECLARE @TaxH      BIGINT = fin.fn_VatFromGross(@NetOfDiscountH, @VatRate);
    DECLARE @SubtotalH BIGINT = @NetOfDiscountH - @TaxH + @DiscountH;
    DECLARE @TotalH    BIGINT = @NetOfDiscountH;

    DECLARE @PaidH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments), 0);

    IF @PaidH < @TotalH
        THROW 52005, N'Payments do not cover the total.', 1;

    DECLARE @CreditH BIGINT =
        ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'credit'), 0);

    /* A credit sale needs a customer with room on their limit. */
    IF @CreditH > 0
    BEGIN
        IF @CustomerId IS NULL
            THROW 52006, N'A credit sale needs a customer.', 1;

        IF EXISTS (SELECT 1 FROM core.Customer
                   WHERE CustomerId = @CustomerId
                     AND BalanceH + @CreditH > CreditLimitH)
            THROW 52007, N'This sale would take the customer over their credit limit.', 1;
    END

    /*----------------------------------------------------------------- write */

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR sales.InvoiceSequence;
        SET @SaleId = CONCAT(N'sal_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @InvoiceNumber = CONCAT(N'INV-', @Seq);

        DECLARE @ChangeH BIGINT =
            CASE WHEN @TenderedH IS NULL THEN 0 ELSE CASE WHEN @TenderedH > @TotalH THEN @TenderedH - @TotalH ELSE 0 END END;

        INSERT INTO sales.Sale
            (SaleId, InvoiceNumber, BranchId, CustomerId, ServedByUserId, CashierName,
             SubtotalH, DiscountH, TaxH, TotalH, TenderedH, ChangeH, DiscountId,
             Status, SoldAtUtc, CreatedBy)
        VALUES
            (@SaleId, @InvoiceNumber, @BranchId, @CustomerId, @ServedByUserId, @CashierName,
             @SubtotalH, @DiscountH, @TaxH, @TotalH, @TenderedH, @ChangeH, @DiscountId,
             N'completed', SYSUTCDATETIME(), @CashierName);

        /* Names and costs are copied onto the line. An invoice must still read
           correctly after the product is renamed, repriced or deleted. */
        INSERT INTO sales.SaleLine
            (SaleId, ItemId, NameAr, NameEn, Kind, PrintGroupId,
             Quantity, UnitPriceH, UnitCostH, LineDiscountH, Note)
        SELECT
            @SaleId, l.ItemId, i.NameAr, i.NameEn, i.Kind, i.PrintGroupId,
            l.Quantity, l.UnitPriceH, i.CostH, l.LineDiscountH, l.Note
        FROM @Lines AS l
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId;

        INSERT INTO sales.SalePayment (SaleId, Method, AmountH, Reference)
        SELECT @SaleId, Method, AmountH, Reference FROM @Payments WHERE AmountH > 0;

        /*-------------------------------------------------------------- stock */

        UPDATE s
        SET Quantity = s.Quantity - agg.Qty,
            UpdatedAtUtc = SYSUTCDATETIME()
        FROM inv.StockLevel AS s
        JOIN (SELECT l.ItemId, SUM(l.Quantity) AS Qty
              FROM @Lines AS l
              JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
              WHERE i.TracksStock = 1
              GROUP BY l.ItemId) AS agg ON agg.ItemId = s.ItemId
        WHERE s.BranchId = @BranchId;

        /* The ledger of movements, not just the running number: every change
           has to be explainable after the fact. */
        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, Actor)
        SELECT
            l.ItemId, @BranchId, N'sale', -SUM(l.Quantity),
            ISNULL(s.Quantity, 0), i.CostH,
            @InvoiceNumber, N'Sale', N'بيع', @CashierName
        FROM @Lines AS l
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
        LEFT JOIN inv.StockLevel AS s ON s.ItemId = l.ItemId AND s.BranchId = @BranchId
        WHERE i.TracksStock = 1
        GROUP BY l.ItemId, i.CostH, s.Quantity;

        /*----------------------------------------------------------- customer */

        IF @CreditH > 0
        BEGIN
            UPDATE core.Customer
            SET BalanceH = BalanceH + @CreditH,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE CustomerId = @CustomerId;
        END

        IF @DiscountId IS NOT NULL
        BEGIN
            UPDATE sales.Discount SET UsageCount = UsageCount + 1 WHERE DiscountId = @DiscountId;
        END

        /*------------------------------------------------------------- ledger */

        DECLARE @CashH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'cash'), 0);
        DECLARE @CardH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'card'), 0);
        DECLARE @CogsH BIGINT = ISNULL((
            SELECT SUM(i.CostH * l.Quantity)
            FROM @Lines AS l JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
            WHERE i.TracksStock = 1), 0);

        /* Cash reduces by any change given, otherwise the drawer expectation
           would be out by exactly the change handed back. */
        DECLARE @CashNetH BIGINT = CASE WHEN @CashH - @ChangeH > 0 THEN @CashH - @ChangeH ELSE 0 END;

        DECLARE @Entry fin.JournalLineTable;

        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1000', @CashNetH, 0, N'Cash'),
            (N'1150', @CardH,    0, N'Card clearing'),
            (N'1400', @CreditH,  0, N'Customer credit'),
            (N'4100', 0, @SubtotalH - @DiscountH, N'Sales'),
            (N'2100', 0, @TaxH,   N'Output VAT'),
            (N'5100', @CogsH, 0,  N'Cost of goods sold'),
            (N'1200', 0, @CogsH,  N'Inventory');

        DECLARE @EntryId NVARCHAR(40);

        EXEC fin.usp_PostJournalEntry
            @Kind            = N'sale',
            @DescriptionEn   = @InvoiceNumber,
            @DescriptionAr   = @InvoiceNumber,
            @SourceReference = @InvoiceNumber,
            @BranchId        = @BranchId,
            @Actor           = @CashierName,
            @Lines           = @Entry,
            @EntryId         = @EntryId OUTPUT;

        /*--------------------------------------------------------- commission */

        /* Frozen at this moment. A later rule change must not rewrite it. */
        EXEC fin.usp_RecordSaleCommission @SaleId = @SaleId;

        /*------------------------------------------------------- preparation */

        /* Only items flagged as needing preparation reach the board. */
        IF EXISTS (SELECT 1 FROM @Lines AS l
                   JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
                   WHERE i.RequiresPreparation = 1)
        BEGIN
            DECLARE @PrepId NVARCHAR(40) =
                CONCAT(N'prp_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

            INSERT INTO sales.PreparationOrder
                (PreparationId, OrderNumber, SaleId, BranchId, CustomerName, TotalH, Status)
            SELECT
                @PrepId, @InvoiceNumber, @SaleId, @BranchId,
                (SELECT NameEn FROM core.Customer WHERE CustomerId = @CustomerId),
                @TotalH, N'open';

            INSERT INTO sales.PreparationItem
                (PreparationId, ItemId, NameAr, NameEn, Quantity, Note)
            SELECT @PrepId, l.ItemId, i.NameAr, i.NameEn, l.Quantity, l.Note
            FROM @Lines AS l
            JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
            WHERE i.RequiresPreparation = 1;
        END

    COMMIT;
END
GO

/*------------------------------------------------------------------ returns */

CREATE PROCEDURE sales.usp_VoidSale
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

/*------------------------------------------------------------- collections */

CREATE PROCEDURE fin.usp_RecordCustomerCollection
    @CustomerId NVARCHAR(40),
    @AmountH    BIGINT,
    @Method     NVARCHAR(20),
    @Reference  NVARCHAR(80) = NULL,
    @BranchId   NVARCHAR(40) = NULL,
    @Actor      NVARCHAR(120),
    @EntryId    NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AmountH <= 0
        THROW 52020, N'A collection must be above zero.', 1;

    DECLARE @Balance BIGINT = (SELECT BalanceH FROM core.Customer WHERE CustomerId = @CustomerId);

    IF @Balance IS NULL
        THROW 52021, N'Customer not found.', 1;

    /* Collecting more than is owed would leave a negative balance, which reads
       as the business owing the customer — a different thing entirely. */
    IF @AmountH > @Balance
        THROW 52022, N'That is more than this customer owes.', 1;

    BEGIN TRAN;

        UPDATE core.Customer
        SET BalanceH = BalanceH - @AmountH, UpdatedAtUtc = SYSUTCDATETIME()
        WHERE CustomerId = @CustomerId;

        DECLARE @Lines fin.JournalLineTable;

        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (CASE WHEN @Method = N'cash' THEN N'1000' ELSE N'1100' END, @AmountH, 0, @Method),
            (N'1400', 0, @AmountH, N'Customer collection');

        EXEC fin.usp_PostJournalEntry
            @Kind            = N'customer_collection',
            @DescriptionEn   = N'Customer collection',
            @DescriptionAr   = N'تحصيل من عميل',
            @SourceReference = @CustomerId,
            @BranchId        = @BranchId,
            @Actor           = @Actor,
            @Lines           = @Lines,
            @EntryId         = @EntryId OUTPUT;

    COMMIT;
END
GO

PRINT N'12 · Sale commit ready.';
GO
