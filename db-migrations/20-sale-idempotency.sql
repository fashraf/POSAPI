/*==============================================================================
  Nazad POS — 20 · Idempotent sale commit

  A retry must not create a second sale.

  Today, if the connection drops after the transaction commits but before the
  response arrives, the client has no way to know the sale succeeded. Retrying
  produces two invoices, stock deducted twice and two balanced ledger entries —
  and both look entirely legitimate afterwards. Nothing in the data says which
  one was the accident.

  On a wireless till this is not an edge case. The fix is a key the client
  generates once per attempt: the first call does the work and records the key;
  a replay finds it and returns the original result.
==============================================================================*/

USE POSMAIN;
GO

/*------------------------------------------------------------------- column */

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID(N'sales.Sale') AND name = N'IdempotencyKey')
BEGIN
    ALTER TABLE sales.Sale ADD IdempotencyKey NVARCHAR(64) NULL;
END
GO

/*
  Unique, but only where a key exists.

  A filtered index lets historical sales keep a null key while making a
  duplicate key impossible going forward. Without the filter, every null would
  collide with every other null.

  This is the actual guarantee. The check inside the procedure is a courtesy
  that returns the original result; this index is what makes a second row
  impossible even under a race between two concurrent retries.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'UX_Sale_IdempotencyKey' AND object_id = OBJECT_ID(N'sales.Sale'))
BEGIN
    CREATE UNIQUE INDEX UX_Sale_IdempotencyKey
        ON sales.Sale (IdempotencyKey)
        WHERE IdempotencyKey IS NOT NULL;
END
GO

/*---------------------------------------------------------------- procedure */

ALTER PROCEDURE sales.usp_CommitSale
    @BranchId        NVARCHAR(40),
    @CustomerId      NVARCHAR(40) = NULL,
    @ServedByUserId  NVARCHAR(40) = NULL,
    @CashierName     NVARCHAR(160),
    @DiscountId      NVARCHAR(40) = NULL,
    @DiscountH       BIGINT = 0,
    @TenderedH       BIGINT = NULL,
    @IdempotencyKey  NVARCHAR(64) = NULL,
    @Lines           sales.SaleLineTable    READONLY,
    @Payments        sales.SalePaymentTable READONLY,
    @SaleId          NVARCHAR(40) OUTPUT,
    @InvoiceNumber   NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
      A replay returns the original sale.

      Checked before any validation: a retry of a sale that already succeeded
      must succeed again with the same answer, even if stock has since fallen
      below what that sale took. Re-validating would refuse a sale that has
      already happened.
    */
    IF @IdempotencyKey IS NOT NULL
    BEGIN
        SELECT @SaleId = SaleId, @InvoiceNumber = InvoiceNumber
        FROM sales.Sale
        WHERE IdempotencyKey = @IdempotencyKey;

        IF @SaleId IS NOT NULL RETURN;
    END

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
    DECLARE @TaxH      BIGINT = fin.fn_VatFromGross(@NetOfDiscountH, @VatRate);
    DECLARE @SubtotalH BIGINT = @NetOfDiscountH - @TaxH + @DiscountH;
    DECLARE @TotalH    BIGINT = @NetOfDiscountH;

    DECLARE @PaidH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments), 0);

    IF @PaidH < @TotalH
        THROW 52005, N'Payments do not cover the total.', 1;

    DECLARE @CreditH BIGINT =
        ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'credit'), 0);

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

    BEGIN TRY
        BEGIN TRAN;

            DECLARE @Seq BIGINT = NEXT VALUE FOR sales.InvoiceSequence;
            SET @SaleId = CONCAT(N'sal_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
            SET @InvoiceNumber = CONCAT(N'INV-', @Seq);

            DECLARE @ChangeH BIGINT =
                CASE WHEN @TenderedH IS NULL THEN 0
                     ELSE CASE WHEN @TenderedH > @TotalH THEN @TenderedH - @TotalH ELSE 0 END END;

            INSERT INTO sales.Sale
                (SaleId, InvoiceNumber, BranchId, CustomerId, ServedByUserId, CashierName,
                 SubtotalH, DiscountH, TaxH, TotalH, TenderedH, ChangeH, DiscountId,
                 Status, SoldAtUtc, CreatedBy, IdempotencyKey)
            VALUES
                (@SaleId, @InvoiceNumber, @BranchId, @CustomerId, @ServedByUserId, @CashierName,
                 @SubtotalH, @DiscountH, @TaxH, @TotalH, @TenderedH, @ChangeH, @DiscountId,
                 N'completed', SYSUTCDATETIME(), @CashierName, @IdempotencyKey);

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

            DECLARE @CashH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'cash'), 0);
            DECLARE @CardH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'card'), 0);
            DECLARE @CogsH BIGINT = ISNULL((
                SELECT SUM(i.CostH * l.Quantity)
                FROM @Lines AS l JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
                WHERE i.TracksStock = 1), 0);

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

            EXEC fin.usp_RecordSaleCommission @SaleId = @SaleId;

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
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;

        /*
          Two retries racing each other.

          Both passed the replay check before either committed, so the second
          hits the unique index. That is the index doing its job, not a fault —
          return the sale the winner created rather than an error, which is the
          same answer the replay check would have given a moment later.
        */
        IF ERROR_NUMBER() IN (2601, 2627) AND @IdempotencyKey IS NOT NULL
        BEGIN
            SELECT @SaleId = SaleId, @InvoiceNumber = InvoiceNumber
            FROM sales.Sale
            WHERE IdempotencyKey = @IdempotencyKey;

            IF @SaleId IS NOT NULL RETURN;
        END

        THROW;
    END CATCH
END
GO

PRINT N'20 · Sale commit is now idempotent.';
GO

/*------------------------------------------------------------------ check */

SELECT
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                      WHERE name = N'UX_Sale_IdempotencyKey')
         THEN N'PASS  Duplicate keys are impossible'
         ELSE N'FAIL  The unique index is missing'
    END AS Result;
GO
