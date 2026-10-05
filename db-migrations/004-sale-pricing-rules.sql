/*==============================================================================
  Nazad POS — 004 · The server prices the sale

  Three faults in sales.usp_CommitSale, fixed together because they are all in
  how a sale's figures are worked out:

  1. It trusted the till's prices and discounts. A line at 0.01 (INV-1007) and
     a 93% invoice discount (INV-1008) went through. Now:
       - the unit price is the catalog price. A different price is an
         override: it needs a reason (@OverrideReason) and someone holding
         pos.override_price — the cashier, or the approver whose password the
         API has just checked (@ApprovedByUserId). Without a reason a
         different price is refused as stale (52040), so a till holding an
         old price list cannot override by accident;
       - a line discount is always an override;
       - the invoice discount must come from a discount rule that is live for
         this branch, cashier, day and basket (type, value, cap, minimum,
         scope), and match what that rule gives within a halala. Anything
         else — no rule, or more than the rule gives — is an override.
     Who authorised an override and why is kept on the sale
     (OverrideApprovedBy, OverrideReason), and each line keeps the catalog
     price it was sold against (ListPriceH), so an override is visible on the
     record rather than inferred. Discount approval above a rule's threshold
     (discounts.approve) works as before.

  2. Invoice numbers skipped when a sale rolled back (see 003). The number is
     now taken from sales.InvoiceCounter inside the transaction.

  3. SubtotalH mixed bases: NetOfDiscount − VAT + Discount added a
     VAT-inclusive discount to a VAT-exclusive figure (INV-1003 showed 75.02
     where 85.00 gross is 73.91 ex-VAT, discount 7.39). The stored figures are
     now one basis:
        SubtotalH  ex-VAT, after line discounts, before the invoice discount
        DiscountH  the invoice discount, ex-VAT
        TaxH       VAT on what the customer pays
        TotalH     what the customer pays, VAT inclusive
     so SubtotalH − DiscountH + TaxH = TotalH exactly. The rounding halala, if
     any, lands in DiscountH. The ledger is unchanged: 4100 was already
     credited TotalH − TaxH, and still is.

     sales.usp_IssueReturn shared out Sale.DiscountH as a VAT-inclusive
     amount. It now derives the inclusive discount from the lines
     (Σ line gross − TotalH), which is right for rows written before and after
     this change.

     Existing sales are restated the same way (bottom of this file). Only
     SubtotalH and DiscountH change; TaxH, TotalH, payments and the journal
     already agreed and are not touched.
==============================================================================*/

USE POSMAIN;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*----------------------------------------------------------- record overrides */

IF COL_LENGTH(N'sales.SaleLine', N'ListPriceH') IS NULL
    ALTER TABLE sales.SaleLine ADD ListPriceH BIGINT NULL;   -- catalog price at sale; null before 004
GO

IF COL_LENGTH(N'sales.Sale', N'OverrideApprovedBy') IS NULL
    ALTER TABLE sales.Sale ADD OverrideApprovedBy NVARCHAR(40) NULL;
GO

IF COL_LENGTH(N'sales.Sale', N'OverrideReason') IS NULL
    ALTER TABLE sales.Sale ADD OverrideReason NVARCHAR(400) NULL;
GO

/*------------------------------------------------------------- commit a sale */

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
    @OrderType       NVARCHAR(20) = NULL,
    /* The signed-in user. Their role decides role-scoped discounts, and their
       permissions whether they may override a price themselves. */
    @CashierUserId   NVARCHAR(40) = NULL,
    /* Why a price or discount differs from what the catalog and the rules
       give. Present only when the till is deliberately overriding. */
    @OverrideReason  NVARCHAR(400) = NULL
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

    SET @OverrideReason = NULLIF(LTRIM(RTRIM(@OverrideReason)), N'');

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

    /*
      Who may override.

      pos.override_price, held right now by an active user: the cashier, or
      the approver the API vouched for (it checked their password when they
      are not the cashier). The cashier is preferred, so an approver is
      recorded only when their authority was actually needed.
    */
    DECLARE @OverrideBy NVARCHAR(40) =
        CASE
            WHEN EXISTS (SELECT 1 FROM core.vw_EffectivePermission AS ep
                         JOIN core.AppUser AS u ON u.UserId = ep.UserId
                         WHERE ep.UserId = @CashierUserId
                           AND ep.PermissionKey = N'pos.override_price'
                           AND u.Status = N'active')
                THEN @CashierUserId
            WHEN EXISTS (SELECT 1 FROM core.vw_EffectivePermission AS ep
                         JOIN core.AppUser AS u ON u.UserId = ep.UserId
                         WHERE ep.UserId = @ApprovedByUserId
                           AND ep.PermissionKey = N'pos.override_price'
                           AND u.Status = N'active')
                THEN @ApprovedByUserId
        END;

    DECLARE @Overridden BIT = 0;

    /*
      Prices come from the catalog.

      A line priced differently without a reason is a till with a stale price
      list (or a tampered request): refused, so the cashier reloads and sees
      the real total. With a reason it is an override, and needs authority.
    */
    IF EXISTS (SELECT 1 FROM @Lines AS l
               JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
               WHERE l.UnitPriceH <> i.PriceH)
    BEGIN
        IF @OverrideReason IS NULL
            THROW 52040, N'A price differs from the catalog. Reload the items and try again.', 1;

        IF @OverrideBy IS NULL
            THROW 52041, N'Changing a price needs someone holding pos.override_price.', 1;

        IF EXISTS (SELECT 1 FROM @Lines WHERE UnitPriceH < 0)
            THROW 52041, N'A price cannot be negative.', 1;

        SET @Overridden = 1;
    END

    /* A line discount has no rule behind it, so it is always an override. */
    IF EXISTS (SELECT 1 FROM @Lines WHERE LineDiscountH <> 0)
    BEGIN
        IF EXISTS (SELECT 1 FROM @Lines
                   WHERE LineDiscountH < 0 OR LineDiscountH > UnitPriceH * Quantity)
            THROW 52042, N'A line discount must be between zero and the line total.', 1;

        IF @OverrideReason IS NULL OR @OverrideBy IS NULL
            THROW 52042, N'A line discount needs a reason and someone holding pos.override_price.', 1;

        SET @Overridden = 1;
    END

    DECLARE @GrossH BIGINT =
        (SELECT SUM(l.UnitPriceH * l.Quantity - l.LineDiscountH) FROM @Lines AS l);

    IF @DiscountH IS NULL SET @DiscountH = 0;

    IF @DiscountH < 0 OR @DiscountH > @GrossH
        THROW 52004, N'The discount cannot exceed the basket total.', 1;

    /*
      The invoice discount must be what a rule gives.

      The rule is re-evaluated here exactly as the till evaluates it (and as
      GET /api/discounts/applicable filters it): active, today (UTC) within
      its dates and on one of its days, the basket at its minimum, this
      branch and this cashier's role in scope; then the amount on the lines
      it covers, clamped to them and to its cap. One halala either way is
      rounding. Less than the rule gives is the customer's loss, not a risk,
      and is accepted.
    */
    IF @DiscountId IS NOT NULL
    BEGIN
        DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
        /* 1900-01-07 was a Sunday: 0 = Sunday, as ActiveDays counts, whatever
           DATEFIRST the session has. */
        DECLARE @Weekday NVARCHAR(2) = CAST(DATEDIFF(DAY, '19000107', @Today) % 7 AS NVARCHAR(2));
        DECLARE @CashierRoleId NVARCHAR(40) =
            (SELECT RoleId FROM core.AppUser WHERE UserId = @CashierUserId);

        DECLARE @RuleType NVARCHAR(20), @RuleValue INT, @RuleCapH BIGINT, @RuleMinH BIGINT,
                @RuleAppliesTo NVARCHAR(20), @RuleActive BIT, @RuleStarts DATE, @RuleEnds DATE,
                @RuleDays NVARCHAR(20);

        SELECT @RuleType = DiscountType, @RuleValue = Value, @RuleCapH = MaxDiscountH,
               @RuleMinH = MinSubtotalH, @RuleAppliesTo = AppliesTo, @RuleActive = IsActive,
               @RuleStarts = StartsOn, @RuleEnds = EndsOn, @RuleDays = ISNULL(ActiveDays, N'')
        FROM sales.Discount
        WHERE DiscountId = @DiscountId;

        IF @RuleType IS NULL
           OR @RuleActive = 0
           OR (@RuleStarts IS NOT NULL AND @RuleStarts > @Today)
           OR (@RuleEnds IS NOT NULL AND @RuleEnds < @Today)
           OR (@RuleDays <> N'' AND NOT EXISTS (SELECT 1 FROM STRING_SPLIT(@RuleDays, N',')
                                               WHERE LTRIM(RTRIM(value)) = @Weekday))
           OR @GrossH < ISNULL(@RuleMinH, 0)
           OR (EXISTS (SELECT 1 FROM sales.DiscountScope
                       WHERE DiscountId = @DiscountId AND ScopeType = N'branch')
               AND NOT EXISTS (SELECT 1 FROM sales.DiscountScope
                               WHERE DiscountId = @DiscountId AND ScopeType = N'branch'
                                 AND ScopeKey = @BranchId))
           OR (EXISTS (SELECT 1 FROM sales.DiscountScope
                       WHERE DiscountId = @DiscountId AND ScopeType = N'role')
               AND NOT EXISTS (SELECT 1 FROM sales.DiscountScope
                               WHERE DiscountId = @DiscountId AND ScopeType = N'role'
                                 AND ScopeKey = @CashierRoleId))
            THROW 52044, N'That discount does not apply to this sale.', 1;

        /* The lines the rule covers. 'item' and 'category' are the old names
           for a selected scope. */
        DECLARE @BaseH BIGINT = ISNULL((
            SELECT SUM(l.UnitPriceH * l.Quantity - l.LineDiscountH)
            FROM @Lines AS l
            JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
            WHERE @RuleAppliesTo = N'all'
               OR (@RuleAppliesTo = N'products' AND i.Kind = N'product')
               OR (@RuleAppliesTo = N'services' AND i.Kind = N'service')
               OR (@RuleAppliesTo IN (N'selected', N'item', N'category') AND EXISTS (
                       SELECT 1 FROM sales.DiscountScope AS sc
                       WHERE sc.DiscountId = @DiscountId
                         AND ((sc.ScopeType = N'item' AND sc.ScopeKey = i.ItemId)
                           OR (sc.ScopeType = N'category' AND sc.ScopeKey = i.CategoryId))))
        ), 0);

        IF @BaseH <= 0
            THROW 52044, N'That discount does not apply to this sale.', 1;

        DECLARE @RuleH BIGINT =
            CASE WHEN @RuleType = N'percentage'
                 THEN CAST(ROUND(@BaseH * @RuleValue / 10000.0, 0) AS BIGINT)
                 ELSE @RuleValue END;

        IF @RuleH > @BaseH SET @RuleH = @BaseH;
        IF @RuleCapH > 0 AND @RuleH > @RuleCapH SET @RuleH = @RuleCapH;

        IF @DiscountH > @RuleH + 1
        BEGIN
            IF @OverrideReason IS NULL OR @OverrideBy IS NULL
                THROW 52045, N'The discount is more than its rule gives.', 1;

            SET @Overridden = 1;
        END
    END
    ELSE IF @DiscountH > 0
    BEGIN
        /* A typed amount with no rule behind it. */
        IF @OverrideReason IS NULL OR @OverrideBy IS NULL
            THROW 52043, N'A discount must come from a discount rule.', 1;

        SET @Overridden = 1;
    END

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

    IF @Overridden = 0
    BEGIN
        SET @OverrideBy = NULL;
        SET @OverrideReason = NULL;
    END

    IF @OrderType IS NOT NULL AND @OrderType NOT IN (N'dine_in', N'takeaway', N'delivery', N'other')
        THROW 52030, N'Order type is dine_in, takeaway, delivery or other.', 1;

    /*
      One basis for every stored figure (prices are VAT inclusive):
        TotalH     what the customer pays
        TaxH       the VAT inside it
        SubtotalH  the basket ex-VAT, before the invoice discount
        DiscountH  the invoice discount ex-VAT — whatever closes
                   SubtotalH − DiscountH + TaxH = TotalH, so a rounding
                   halala never leaves the invoice unbalanced.
    */
    DECLARE @TotalH    BIGINT = @GrossH - @DiscountH;
    DECLARE @TaxH      BIGINT = fin.fn_VatFromGross(@TotalH, @VatRate);
    DECLARE @NetH      BIGINT = @TotalH - @TaxH;
    DECLARE @SubtotalH BIGINT = @GrossH - fin.fn_VatFromGross(@GrossH, @VatRate);
    DECLARE @DiscountExH BIGINT = @SubtotalH - @NetH;

    /*
      Cash is the only tender that can exceed what it pays for.

      The till sends the cash line as the amount applied to the sale and
      @TenderedH as the notes handed over; an older client sends the cash line
      as the notes handed over. Both are accepted: the cash received is the
      larger of the two, the cash due is whatever the other tenders leave, and
      change is the difference. The ledger takes only the cash due, so the
      entry balances whichever way the client counted.
    */
    DECLARE @NonCashH BIGINT =
        ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method <> N'cash'), 0);
    DECLARE @CashLineH BIGINT =
        ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'cash'), 0);

    IF @NonCashH > @TotalH
        THROW 52031, N'Card, bank and credit payments cannot exceed the total; only cash gives change.', 1;

    DECLARE @CashDueH      BIGINT = @TotalH - @NonCashH;
    DECLARE @CashReceivedH BIGINT =
        CASE WHEN ISNULL(@TenderedH, 0) > @CashLineH THEN @TenderedH ELSE @CashLineH END;

    IF @CashReceivedH < @CashDueH
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

            /*
              The invoice number, gap-free.

              Taken from the counter row inside this transaction: the row lock
              (UPDLOCK, HOLDLOCK) makes concurrent commits queue here, and a
              rollback undoes the increment, so the next sale that succeeds
              gets the number this one would have had. A sequence gives its
              value away outside the transaction, which is how INV-1013 went
              missing.
            */
            DECLARE @Seq BIGINT, @Prefix NVARCHAR(10);

            UPDATE c
            SET @Seq = c.NextNumber,
                @Prefix = c.Prefix,
                NextNumber = c.NextNumber + 1,
                UpdatedAtUtc = SYSUTCDATETIME()
            FROM sales.InvoiceCounter AS c WITH (UPDLOCK, HOLDLOCK)
            WHERE c.CounterKey = N'invoice';

            IF @Seq IS NULL
                THROW 52046, N'The invoice counter is missing. Run migration 003.', 1;

            SET @SaleId = CONCAT(N'sal_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
            SET @InvoiceNumber = CONCAT(@Prefix, @Seq);

            DECLARE @ChangeH BIGINT = @CashReceivedH - @CashDueH;

            INSERT INTO sales.Sale
                (SaleId, InvoiceNumber, BranchId, CustomerId, ServedByUserId, CashierName,
                 SubtotalH, DiscountH, TaxH, TotalH, TenderedH, ChangeH, DiscountId,
                 Status, SoldAtUtc, CreatedBy, IdempotencyKey, DiscountApprovedBy, OrderType,
                 OverrideApprovedBy, OverrideReason)
            VALUES
                (@SaleId, @InvoiceNumber, @BranchId, @CustomerId, @ServedByUserId, @CashierName,
                 @SubtotalH, @DiscountExH, @TaxH, @TotalH, @TenderedH, @ChangeH, @DiscountId,
                 N'completed', SYSUTCDATETIME(), @CashierName, @IdempotencyKey,
                 @ApprovedByUserId, @OrderType,
                 @OverrideBy, @OverrideReason);

            INSERT INTO sales.SaleLine
                (SaleId, ItemId, NameAr, NameEn, Kind, PrintGroupId,
                 Quantity, UnitPriceH, UnitCostH, LineDiscountH, Note, ListPriceH)
            SELECT
                @SaleId, l.ItemId, i.NameAr, i.NameEn, i.Kind, i.PrintGroupId,
                l.Quantity, l.UnitPriceH, i.CostH, l.LineDiscountH, l.Note, i.PriceH
            FROM @Lines AS l
            JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId;

            /* Cash is stored as received, so cash less ChangeH is what the
               drawer kept — the rule the summary's payment mix applies. */
            INSERT INTO sales.SalePayment (SaleId, Method, AmountH, Reference)
            SELECT @SaleId, Method, AmountH, Reference
            FROM @Payments WHERE AmountH > 0 AND Method <> N'cash';

            IF @CashReceivedH > 0
                INSERT INTO sales.SalePayment (SaleId, Method, AmountH, Reference)
                VALUES (@SaleId, N'cash', @CashReceivedH,
                        (SELECT TOP (1) Reference FROM @Payments
                         WHERE Method = N'cash' AND Reference IS NOT NULL));

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

            DECLARE @CardH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'card'), 0);
            DECLARE @BankH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'bank'), 0);
            DECLARE @CogsH BIGINT = ISNULL((
                SELECT SUM(i.CostH * l.Quantity)
                FROM @Lines AS l JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
                WHERE i.TracksStock = 1), 0);

            DECLARE @CashNetH BIGINT = @CashDueH;

            DECLARE @Entry fin.JournalLineTable;

            /* 4100 takes the sale net of VAT and of every discount — the same
               figure as before 004 (SubtotalH − DiscountH = TotalH − TaxH). */
            INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                (N'1000', @CashNetH, 0, N'Cash'),
                (N'1150', @CardH,    0, N'Card clearing'),
                (N'1100', @BankH,    0, N'Bank'),
                (N'1400', @CreditH,  0, N'Customer credit'),
                (N'4100', 0, @NetH,  N'Sales'),
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
               @Invoice = InvoiceNumber, @SaleTotalH = TotalH, @SaleTaxH = TaxH
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

        /* The invoice discount, VAT inclusive, is what the lines came to less
           what was charged. Sale.DiscountH is ex-VAT from 004 on (and was
           inclusive before it), so it is derived rather than read — right for
           sales on either side of that change. */
        SET @SaleDiscountH = CASE WHEN @GrossH > @SaleTotalH THEN @GrossH - @SaleTotalH ELSE 0 END;

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

/*------------------------------------------------- restate existing sales

  Sales written before this file stored SubtotalH = (TotalH − TaxH) +
  inclusive discount, and DiscountH inclusive. Restated on the one basis
  above, from their own lines and the branch's VAT rate. TaxH and TotalH are
  kept exactly as charged, so the receipt total, the payments and the journal
  (4100 = TotalH − TaxH) do not move. Re-running restates nothing new: a row
  already on the new basis computes to the same two figures.
*/
;WITH Figures AS (
    SELECT s.SaleId,
           g.GrossH,
           g.GrossH - fin.fn_VatFromGross(g.GrossH, ISNULL(bs.VatRatePercent, 15.00)) AS SubtotalH
    FROM sales.Sale AS s
    LEFT JOIN core.BranchSettings AS bs ON bs.BranchId = s.BranchId
    CROSS APPLY (SELECT CAST(SUM(l.UnitPriceH * l.Quantity - l.LineDiscountH) AS BIGINT) AS GrossH
                 FROM sales.SaleLine AS l WHERE l.SaleId = s.SaleId) AS g
    WHERE g.GrossH IS NOT NULL
)
UPDATE s
SET SubtotalH = f.SubtotalH,
    DiscountH = f.SubtotalH - (s.TotalH - s.TaxH)
FROM sales.Sale AS s
JOIN Figures AS f ON f.SaleId = s.SaleId
WHERE f.SubtotalH - (s.TotalH - s.TaxH) >= 0      -- never a negative discount
  AND (s.SubtotalH <> f.SubtotalH OR s.DiscountH <> f.SubtotalH - (s.TotalH - s.TaxH));
GO
