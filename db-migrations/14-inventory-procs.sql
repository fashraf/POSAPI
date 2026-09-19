/*==============================================================================
  Nazad POS — 14 · Inventory and expenses

  Receiving stock and adjusting it both touch several tables at once, so both
  are procedures rather than a sequence of API calls.
==============================================================================*/

USE POSMAIN;
GO

CREATE TYPE inv.PurchaseLineTable AS TABLE
(
    ItemId    NVARCHAR(40)  NOT NULL,
    Quantity  DECIMAL(18,3) NOT NULL,
    UnitCostH BIGINT        NOT NULL
);
GO

CREATE SEQUENCE inv.PurchaseSequence AS BIGINT START WITH 500 INCREMENT BY 1;
GO

/*
  Receive a delivery.

  Cost is recalculated as a weighted average rather than overwritten. Taking the
  latest supplier price as the cost makes reported margin lurch every time a
  supplier changes their price, even on stock bought months earlier.
*/
CREATE PROCEDURE inv.usp_ReceivePurchase
    @VendorId      NVARCHAR(40),
    @BranchId      NVARCHAR(40),
    @InvoiceNumber NVARCHAR(60) = NULL,
    @VatRate       DECIMAL(5,2) = 15.00,
    @PaidOnReceipt BIT = 0,
    @ReceivedBy    NVARCHAR(120),
    @Lines         inv.PurchaseLineTable READONLY,
    @PurchaseId    NVARCHAR(40) OUTPUT,
    @Reference     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Lines)
        THROW 54000, N'A delivery needs at least one line.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE Quantity <= 0 OR UnitCostH < 0)
        THROW 54001, N'Quantities must be above zero and costs cannot be negative.', 1;

    IF EXISTS (SELECT 1 FROM @Lines AS l
               JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
               WHERE i.TracksStock = 0)
        THROW 54002, N'A service cannot be received into stock.', 1;

    /* Purchase VAT is added on top of the net supplier price — the opposite
       direction to a retail sale, where it is extracted from the gross. */
    DECLARE @SubtotalH BIGINT = (SELECT SUM(Quantity * UnitCostH) FROM @Lines);
    DECLARE @TaxH      BIGINT = CAST(ROUND(@SubtotalH * @VatRate / 100.0, 0) AS BIGINT);
    DECLARE @TotalH    BIGINT = @SubtotalH + @TaxH;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR inv.PurchaseSequence;
        SET @PurchaseId = CONCAT(N'pur_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @Reference  = CONCAT(N'PO-', @Seq);

        INSERT INTO inv.Purchase
            (PurchaseId, Reference, VendorId, BranchId, InvoiceNumber,
             SubtotalH, TaxH, TotalH, PaidOnReceipt, ReceivedBy)
        VALUES
            (@PurchaseId, @Reference, @VendorId, @BranchId, @InvoiceNumber,
             @SubtotalH, @TaxH, @TotalH, @PaidOnReceipt, @ReceivedBy);

        INSERT INTO inv.PurchaseLine (PurchaseId, ItemId, Quantity, UnitCostH)
        SELECT @PurchaseId, ItemId, Quantity, UnitCostH FROM @Lines;

        /* Weighted average: (existing value + incoming value) / total units. */
        UPDATE i
        SET CostH = CASE
                        WHEN ISNULL(s.Quantity, 0) + agg.Qty = 0 THEN agg.AvgCost
                        ELSE CAST(
                            (ISNULL(s.Quantity, 0) * i.CostH + agg.Qty * agg.AvgCost)
                            / (ISNULL(s.Quantity, 0) + agg.Qty) AS BIGINT)
                    END,
            UpdatedAtUtc = SYSUTCDATETIME()
        FROM core.CatalogItem AS i
        JOIN (SELECT ItemId, SUM(Quantity) AS Qty,
                     SUM(Quantity * UnitCostH) / NULLIF(SUM(Quantity), 0) AS AvgCost
              FROM @Lines GROUP BY ItemId) AS agg ON agg.ItemId = i.ItemId
        LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId;

        /* Create the stock row if this branch has never held the item. */
        INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
        SELECT DISTINCT l.ItemId, @BranchId, 0
        FROM @Lines AS l
        WHERE NOT EXISTS (SELECT 1 FROM inv.StockLevel AS s
                          WHERE s.ItemId = l.ItemId AND s.BranchId = @BranchId);

        UPDATE s
        SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = SYSUTCDATETIME()
        FROM inv.StockLevel AS s
        JOIN (SELECT ItemId, SUM(Quantity) AS Qty FROM @Lines GROUP BY ItemId) AS agg
             ON agg.ItemId = s.ItemId
        WHERE s.BranchId = @BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, Actor)
        SELECT
            agg.ItemId, @BranchId, N'purchase', agg.Qty, s.Quantity, agg.AvgCost,
            @Reference, N'Delivery received', N'استلام بضاعة', @ReceivedBy
        FROM (SELECT ItemId, SUM(Quantity) AS Qty,
                     SUM(Quantity * UnitCostH) / NULLIF(SUM(Quantity), 0) AS AvgCost
              FROM @Lines GROUP BY ItemId) AS agg
        JOIN inv.StockLevel AS s ON s.ItemId = agg.ItemId AND s.BranchId = @BranchId;

        /* Stock arriving is an asset swap, not a cost. It becomes a cost when
           it is sold, through COGS. */
        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1200', @SubtotalH, 0, N'Inventory'),
            (N'1300', @TaxH, 0, N'Input VAT'),
            (CASE WHEN @PaidOnReceipt = 1 THEN N'1000' ELSE N'2000' END, 0, @TotalH, N'Supplier');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'purchase', @DescriptionEn = N'Delivery received',
            @DescriptionAr = N'استلام بضاعة', @SourceReference = @Reference,
            @BranchId = @BranchId, @Actor = @ReceivedBy,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

    COMMIT;
END
GO

/*
  Adjust stock.

  A correction, a stocktake or a write-off. The difference against the expected
  quantity posts to stock variance rather than disappearing, because unexplained
  shrinkage is the thing an owner most needs to see.
*/
CREATE PROCEDURE inv.usp_AdjustStock
    @ItemId      NVARCHAR(40),
    @BranchId    NVARCHAR(40),
    @NewQuantity DECIMAL(18,3),
    @ReasonEn    NVARCHAR(400),
    @ReasonAr    NVARCHAR(400) = NULL,
    @Actor       NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@ReasonEn, N''))) = N''
        THROW 54010, N'An adjustment needs a reason on the record.', 1;

    IF @NewQuantity < 0
        THROW 54011, N'Stock cannot be negative.', 1;

    IF NOT EXISTS (SELECT 1 FROM core.CatalogItem
                   WHERE ItemId = @ItemId AND TracksStock = 1)
        THROW 54012, N'This item does not track stock.', 1;

    BEGIN TRAN;

        INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
        SELECT @ItemId, @BranchId, 0
        WHERE NOT EXISTS (SELECT 1 FROM inv.StockLevel
                          WHERE ItemId = @ItemId AND BranchId = @BranchId);

        DECLARE @Old DECIMAL(18,3) = (SELECT Quantity FROM inv.StockLevel
                                      WHERE ItemId = @ItemId AND BranchId = @BranchId);
        DECLARE @Delta DECIMAL(18,3) = @NewQuantity - @Old;

        IF @Delta <> 0
        BEGIN
            UPDATE inv.StockLevel
            SET Quantity = @NewQuantity, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE ItemId = @ItemId AND BranchId = @BranchId;

            INSERT INTO inv.StockMovement
                (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
                 ReasonEn, ReasonAr, Actor)
            SELECT @ItemId, @BranchId, N'adjustment', @Delta, @NewQuantity, i.CostH,
                   @ReasonEn, ISNULL(@ReasonAr, @ReasonEn), @Actor
            FROM core.CatalogItem AS i WHERE i.ItemId = @ItemId;

            /* The value of what was gained or lost. */
            DECLARE @CostH BIGINT = (SELECT CostH FROM core.CatalogItem WHERE ItemId = @ItemId);
            DECLARE @ValueH BIGINT = CAST(ROUND(ABS(@Delta) * @CostH, 0) AS BIGINT);

            IF @ValueH > 0
            BEGIN
                DECLARE @Entry fin.JournalLineTable;

                IF @Delta < 0
                    INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                        (N'5200', @ValueH, 0, N'Stock variance'),
                        (N'1200', 0, @ValueH, N'Inventory');
                ELSE
                    INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                        (N'1200', @ValueH, 0, N'Inventory'),
                        (N'5200', 0, @ValueH, N'Stock variance');

                DECLARE @EntryId NVARCHAR(40);
                EXEC fin.usp_PostJournalEntry
                    @Kind = N'stock_adjustment', @DescriptionEn = @ReasonEn,
                    @DescriptionAr = @ReasonAr, @SourceReference = @ItemId,
                    @BranchId = @BranchId, @Actor = @Actor,
                    @Lines = @Entry, @EntryId = @EntryId OUTPUT;
            END
        END

    COMMIT;
END
GO

/*
  Record an expense and spread it across the months it covers.

  Wraps the existing recognition builder so the caller gets both in one call.
*/
CREATE SEQUENCE fin.ExpenseSequence AS BIGINT START WITH 400 INCREMENT BY 1;
GO

CREATE PROCEDURE fin.usp_RecordExpense
    @CategoryId    NVARCHAR(40),
    @BranchId      NVARCHAR(40) = NULL,
    @DescriptionEn NVARCHAR(400),
    @DescriptionAr NVARCHAR(400) = NULL,
    @AmountH       BIGINT,
    @VatH          BIGINT = 0,
    @PaymentMethod NVARCHAR(20),
    @PaidOn        DATE,
    @Recognition   NVARCHAR(20) = N'one_time',
    @PeriodStart   DATE = NULL,
    @PeriodEnd     DATE = NULL,
    @ExternalRef   NVARCHAR(80) = NULL,
    @Attachment    NVARCHAR(300) = NULL,
    @Actor         NVARCHAR(120),
    @ExpenseId     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AmountH <= 0 THROW 54020, N'An expense must be above zero.', 1;
    IF @VatH < 0 OR @VatH > @AmountH THROW 54021, N'VAT cannot exceed the amount.', 1;

    SET @PeriodStart = ISNULL(@PeriodStart, @PaidOn);
    SET @PeriodEnd   = ISNULL(@PeriodEnd, @PaidOn);

    IF @PeriodEnd < @PeriodStart THROW 54022, N'The period must end after it starts.', 1;

    DECLARE @AccountCode NVARCHAR(10) =
        (SELECT AccountCode FROM fin.ExpenseCategory WHERE CategoryId = @CategoryId);

    IF @AccountCode IS NULL THROW 54023, N'Unknown expense category.', 1;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR fin.ExpenseSequence;
        SET @ExpenseId = CONCAT(N'exp_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO fin.Expense
            (ExpenseId, Reference, CategoryId, BranchId, DescriptionAr, DescriptionEn,
             AmountH, VatH, PaymentMethod, PaidOn, Recognition, PeriodStart, PeriodEnd,
             ExternalRef, AttachmentName, CreatedBy)
        VALUES
            (@ExpenseId, CONCAT(N'EXP-', @Seq), @CategoryId, @BranchId,
             @DescriptionAr, @DescriptionEn, @AmountH, @VatH, @PaymentMethod,
             @PaidOn, @Recognition, @PeriodStart, @PeriodEnd,
             @ExternalRef, @Attachment, @Actor);

        DECLARE @NetH BIGINT = @AmountH - @VatH;
        DECLARE @Spreads BIT = CASE WHEN @Recognition = N'one_time' THEN 0 ELSE 1 END;
        DECLARE @PaymentAccount NVARCHAR(10) =
            CASE @PaymentMethod WHEN N'cash' THEN N'1000'
                                WHEN N'credit' THEN N'2000'
                                ELSE N'1100' END;

        /* The payment leaves on the date it left, whatever period the cost
           belongs to. Anything spread over time parks in prepaid first. */
        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (CASE WHEN @Spreads = 1 THEN N'1500' ELSE @AccountCode END, @NetH, 0, @DescriptionEn),
            (N'1300', @VatH, 0, N'Input VAT'),
            (@PaymentAccount, 0, @AmountH, @PaymentMethod);

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense', @DescriptionEn = @DescriptionEn, @DescriptionAr = @DescriptionAr,
            @SourceReference = @ExpenseId, @BranchId = @BranchId, @Actor = @Actor,
            @PostedAtUtc = @PaidOn, @Lines = @Entry, @EntryId = @EntryId OUTPUT;

        EXEC fin.usp_BuildExpenseRecognition @ExpenseId = @ExpenseId;

        /* Release prepaid into the expense account, month by month. */
        IF @Spreads = 1
        BEGIN
            DECLARE @Month CHAR(7), @Slice BIGINT;

            DECLARE slices CURSOR LOCAL FAST_FORWARD FOR
                SELECT PeriodMonth, AmountH FROM fin.ExpenseRecognition
                WHERE ExpenseId = @ExpenseId;

            OPEN slices;
            FETCH NEXT FROM slices INTO @Month, @Slice;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @Release fin.JournalLineTable;
                DELETE FROM @Release;

                INSERT INTO @Release (AccountCode, DebitH, CreditH, Memo) VALUES
                    (@AccountCode, @Slice, 0, @Month),
                    (N'1500', 0, @Slice, N'Prepaid release');

                DECLARE @RelId NVARCHAR(40);
                EXEC fin.usp_PostJournalEntry
                    @Kind = N'expense_recognition',
                    @DescriptionEn = @DescriptionEn, @DescriptionAr = @DescriptionAr,
                    @SourceReference = @ExpenseId, @BranchId = @BranchId, @Actor = @Actor,
                    @PostedAtUtc = @Month, @Lines = @Release, @EntryId = @RelId OUTPUT;

                FETCH NEXT FROM slices INTO @Month, @Slice;
            END

            CLOSE slices;
            DEALLOCATE slices;
        END

    COMMIT;
END
GO

PRINT N'14 · Inventory and expenses ready.';
GO
