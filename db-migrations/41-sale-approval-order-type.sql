/*==============================================================================
  Nazad POS — 41 · Sale commit: discount approval and order type

  sales.usp_CommitSale as in 20 (idempotency), plus:

  Discount approval, enforced on the server
    Until now the commit carried no approval data and only the browser stopped
    an unapproved discount. A discount whose approval threshold
    (sales.Discount.ApprovalAboveH) is exceeded by @DiscountH now needs
    @ApprovedByUserId: an active user who holds discounts.approve
    (core.vw_EffectivePermission). The API fills it — the cashier themself when
    they hold the permission, or another user after checking that user's
    password. Who approved is kept on the sale (sales.Sale.DiscountApprovedBy).
      63050 approval required, 63051 approver lacks discounts.approve.

  Order type
    The kitchen board filters dine-in / takeaway / delivery, but nothing
    carried it. sales.Sale.OrderType and sales.PreparationOrder.OrderType are
    added (NULL = not given); @OrderType fills both. 52030 bad value.

  Both new parameters are optional and last, so existing callers are
  unaffected.
==============================================================================*/

USE POSMAIN;
GO

IF COL_LENGTH(N'sales.Sale', N'DiscountApprovedBy') IS NULL
    ALTER TABLE sales.Sale ADD DiscountApprovedBy NVARCHAR(40) NULL;
GO

IF COL_LENGTH(N'sales.Sale', N'OrderType') IS NULL
    ALTER TABLE sales.Sale ADD OrderType NVARCHAR(20) NULL;
GO

IF COL_LENGTH(N'sales.PreparationOrder', N'OrderType') IS NULL
    ALTER TABLE sales.PreparationOrder ADD OrderType NVARCHAR(20) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Sale_OrderType')
    ALTER TABLE sales.Sale ADD CONSTRAINT CK_Sale_OrderType
        CHECK (OrderType IS NULL OR OrderType IN (N'dine_in', N'takeaway', N'delivery', N'other'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Preparation_OrderType')
    ALTER TABLE sales.PreparationOrder ADD CONSTRAINT CK_Preparation_OrderType
        CHECK (OrderType IS NULL OR OrderType IN (N'dine_in', N'takeaway', N'delivery', N'other'));
GO


CREATE OR ALTER PROCEDURE sales.usp_CommitSale
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
    @InvoiceNumber   NVARCHAR(40) OUTPUT,
    @ApprovedByUserId NVARCHAR(40) = NULL,
    @OrderType       NVARCHAR(20) = NULL
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

    /*
      Approval is enforced here, not only in the browser.

      A discount with an approval threshold that is exceeded needs an approver
      who holds discounts.approve right now (an active user, permissions as
      they stand). The API decides who the approver is — the cashier, or
      another user whose password it has just checked — and passes their id.
    */
    IF @DiscountId IS NOT NULL
    BEGIN
        DECLARE @ApprovalAboveH BIGINT =
            (SELECT ApprovalAboveH FROM sales.Discount WHERE DiscountId = @DiscountId);

        IF @ApprovalAboveH > 0 AND @DiscountH > @ApprovalAboveH
        BEGIN
            IF @ApprovedByUserId IS NULL
                THROW 63050, N'This discount needs approval from someone allowed to approve discounts.', 1;

            IF NOT EXISTS (SELECT 1
                           FROM core.vw_EffectivePermission AS ep
                           JOIN core.AppUser AS u ON u.UserId = ep.UserId
                           WHERE ep.UserId = @ApprovedByUserId
                             AND ep.PermissionKey = N'discounts.approve'
                             AND u.Status = N'active')
                THROW 63051, N'The approver is not allowed to approve discounts.', 1;
        END
        ELSE
            SET @ApprovedByUserId = NULL;   -- nothing needed approving
    END
    ELSE
        SET @ApprovedByUserId = NULL;

    IF @OrderType IS NOT NULL AND @OrderType NOT IN (N'dine_in', N'takeaway', N'delivery', N'other')
        THROW 52030, N'Order type is dine_in, takeaway, delivery or other.', 1;

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
                 Status, SoldAtUtc, CreatedBy, IdempotencyKey, DiscountApprovedBy, OrderType)
            VALUES
                (@SaleId, @InvoiceNumber, @BranchId, @CustomerId, @ServedByUserId, @CashierName,
                 @SubtotalH, @DiscountH, @TaxH, @TotalH, @TenderedH, @ChangeH, @DiscountId,
                 N'completed', SYSUTCDATETIME(), @CashierName, @IdempotencyKey,
                 @ApprovedByUserId, @OrderType);

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
                    (PreparationId, OrderNumber, SaleId, BranchId, CustomerName, TotalH, Status, OrderType)
                SELECT
                    @PrepId, @InvoiceNumber, @SaleId, @BranchId,
                    (SELECT NameEn FROM core.Customer WHERE CustomerId = @CustomerId),
                    @TotalH, N'open', @OrderType;

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
        END;  -- THROW requires the preceding statement to end with a semicolon

        THROW;
    END CATCH
END

GO

PRINT N'41 · Sale commit approval and order type ready.';
GO

SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'sales.usp_CommitSale')) NOT LIKE N'%@ApprovedByUserId%'
            THEN N'FAIL  commit proc not updated'
            WHEN COL_LENGTH(N'sales.PreparationOrder', N'OrderType') IS NULL THEN N'FAIL  OrderType missing'
            ELSE N'PASS  Sale commit approval and order type ready' END AS Result;
GO
