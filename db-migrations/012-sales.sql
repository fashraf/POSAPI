/*==============================================================================
  Nazad POS — 012 · Sales functions (sales)

  Committing, voiding and returning sales, and the discount rules. Conventions:
  README.md.
==============================================================================*/

/*------------------------------------------------------------- commit a sale */

CREATE OR REPLACE FUNCTION sales.usp_CommitSale(
    p_BranchId         text,
    p_CustomerId       text DEFAULT NULL,
    p_ServedByUserId   text DEFAULT NULL,
    p_CashierName      text DEFAULT NULL,
    p_DiscountId       text DEFAULT NULL,
    p_DiscountH        bigint DEFAULT 0,
    p_TenderedH        bigint DEFAULT NULL,
    p_IdempotencyKey   text DEFAULT NULL,
    p_Lines            jsonb DEFAULT '[]',
    p_Payments         jsonb DEFAULT '[]',
    p_ApprovedByUserId text DEFAULT NULL,
    p_OrderType        text DEFAULT NULL,
    /* The signed-in user. Their role decides role-scoped discounts, and their
       permissions whether they may override a price themselves. */
    p_CashierUserId    text DEFAULT NULL,
    /* Why a price or discount differs from what the catalog and the rules
       give. Present only when the till is deliberately overriding. */
    p_OverrideReason   text DEFAULT NULL)
RETURNS TABLE (SaleId varchar, InvoiceNumber varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Lines    sales.SaleLineTable[] :=
        ARRAY(SELECT jsonb_populate_recordset(NULL::sales.SaleLineTable, p_Lines));
    v_Payments sales.SalePaymentTable[] :=
        ARRAY(SELECT jsonb_populate_recordset(NULL::sales.SalePaymentTable, p_Payments));

    v_SaleId          varchar;
    v_InvoiceNumber   varchar;
    v_ApprovedBy      varchar := p_ApprovedByUserId;
    v_OverrideReason  varchar := NULLIF(trim(p_OverrideReason), '');
    v_DiscountH       bigint  := COALESCE(p_DiscountH, 0);

    v_VatRate         numeric(5,2);
    v_AllowNegative   boolean;
    v_OverrideBy      varchar;
    v_Overridden      boolean := false;
    v_GrossH          bigint;

    v_Today           date;
    v_Weekday         text;
    v_CashierRoleId   varchar;
    v_RuleType        varchar;
    v_RuleValue       integer;
    v_RuleCapH        bigint;
    v_RuleMinH        bigint;
    v_RuleAppliesTo   varchar;
    v_RuleActive      boolean;
    v_RuleStarts      date;
    v_RuleEnds        date;
    v_RuleDays        varchar;
    v_BaseH           bigint;
    v_RuleH           bigint;
    v_ApprovalAboveH  bigint;

    v_TotalH          bigint;
    v_TaxH            bigint;
    v_NetH            bigint;
    v_SubtotalH       bigint;
    v_DiscountExH     bigint;
    v_NonCashH        bigint;
    v_CashLineH       bigint;
    v_CashDueH        bigint;
    v_CashReceivedH   bigint;
    v_CreditH         bigint;

    v_Seq             bigint;
    v_Prefix          varchar;
    v_ChangeH         bigint;
    v_CardH           bigint;
    v_BankH           bigint;
    v_CogsH           bigint;
    v_Entry           fin.JournalLineTable[];
    v_PrepId          varchar;
BEGIN
    /*
      A replay returns the original sale.

      Checked before any validation: a retry of a sale that already succeeded
      must succeed again with the same answer, even if stock has since fallen
      below what that sale took. Re-validating would refuse a sale that has
      already happened.
    */
    IF p_IdempotencyKey IS NOT NULL THEN
        RETURN QUERY
            SELECT s.SaleId, s.InvoiceNumber FROM sales.Sale AS s
            WHERE s.IdempotencyKey = p_IdempotencyKey;
        IF FOUND THEN RETURN; END IF;
    END IF;

    /*-------------------------------------------------- validate before writing */

    IF cardinality(v_Lines) = 0 THEN
        RAISE EXCEPTION 'A sale needs at least one line.' USING DETAIL = '52000';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l WHERE l.Quantity <= 0) THEN
        RAISE EXCEPTION 'Quantities must be above zero.' USING DETAIL = '52001';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l
               WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem AS i
                                 WHERE i.ItemId = l.ItemId AND i.IsActive)) THEN
        RAISE EXCEPTION 'A line refers to an item that does not exist or is inactive.' USING DETAIL = '52002';
    END IF;

    v_VatRate := COALESCE((SELECT VatRatePercent FROM core.BranchSettings WHERE BranchId = p_BranchId), 15.00);
    v_AllowNegative := COALESCE((SELECT AllowNegativeStock FROM core.BranchSettings WHERE BranchId = p_BranchId), false);

    IF NOT v_AllowNegative AND EXISTS (
        SELECT 1
        FROM unnest(v_Lines) AS l
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
        LEFT JOIN inv.StockLevel AS s ON s.ItemId = l.ItemId AND s.BranchId = p_BranchId
        WHERE i.TracksStock AND COALESCE(s.Quantity, 0) < l.Quantity)
    THEN
        RAISE EXCEPTION 'Not enough stock for one or more items.' USING DETAIL = '52003';
    END IF;

    /*
      Who may override.

      pos.override_price, held right now by an active user: the cashier, or
      the approver the API vouched for (it checked their password when they
      are not the cashier). The cashier is preferred, so an approver is
      recorded only when their authority was actually needed.
    */
    v_OverrideBy :=
        CASE
            WHEN EXISTS (SELECT 1 FROM core.vw_EffectivePermission AS ep
                         JOIN core.AppUser AS u ON u.UserId = ep.UserId
                         WHERE ep.UserId = p_CashierUserId
                           AND ep.PermissionKey = 'pos.override_price'
                           AND u.Status = 'active')
                THEN p_CashierUserId
            WHEN EXISTS (SELECT 1 FROM core.vw_EffectivePermission AS ep
                         JOIN core.AppUser AS u ON u.UserId = ep.UserId
                         WHERE ep.UserId = p_ApprovedByUserId
                           AND ep.PermissionKey = 'pos.override_price'
                           AND u.Status = 'active')
                THEN p_ApprovedByUserId
        END;

    /*
      Prices come from the catalog.

      A line priced differently without a reason is a till with a stale price
      list (or a tampered request): refused, so the cashier reloads and sees
      the real total. With a reason it is an override, and needs authority.
    */
    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l
               JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
               WHERE l.UnitPriceH <> i.PriceH) THEN
        IF v_OverrideReason IS NULL THEN
            RAISE EXCEPTION 'A price differs from the catalog. Reload the items and try again.' USING DETAIL = '52040';
        END IF;

        IF v_OverrideBy IS NULL THEN
            RAISE EXCEPTION 'Changing a price needs someone holding pos.override_price.' USING DETAIL = '52041';
        END IF;

        IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l WHERE l.UnitPriceH < 0) THEN
            RAISE EXCEPTION 'A price cannot be negative.' USING DETAIL = '52041';
        END IF;

        v_Overridden := true;
    END IF;

    /* A line discount has no rule behind it, so it is always an override. */
    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l WHERE l.LineDiscountH <> 0) THEN
        IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l
                   WHERE l.LineDiscountH < 0 OR l.LineDiscountH > l.UnitPriceH * l.Quantity) THEN
            RAISE EXCEPTION 'A line discount must be between zero and the line total.' USING DETAIL = '52042';
        END IF;

        IF v_OverrideReason IS NULL OR v_OverrideBy IS NULL THEN
            RAISE EXCEPTION 'A line discount needs a reason and someone holding pos.override_price.' USING DETAIL = '52042';
        END IF;

        v_Overridden := true;
    END IF;

    /* Whole halalas, cut as SQL Server cut a decimal into BIGINT. */
    v_GrossH := (SELECT trunc(SUM(l.UnitPriceH * l.Quantity - l.LineDiscountH))::bigint FROM unnest(v_Lines) AS l);

    IF v_DiscountH < 0 OR v_DiscountH > v_GrossH THEN
        RAISE EXCEPTION 'The discount cannot exceed the basket total.' USING DETAIL = '52004';
    END IF;

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
    IF p_DiscountId IS NOT NULL THEN
        v_Today := (now() AT TIME ZONE 'utc')::date;
        /* 0 = Sunday, as ActiveDays counts. */
        v_Weekday := extract(dow FROM v_Today)::int::text;
        v_CashierRoleId := (SELECT RoleId FROM core.AppUser WHERE UserId = p_CashierUserId);

        SELECT DiscountType, Value, MaxDiscountH, MinSubtotalH, AppliesTo, IsActive,
               StartsOn, EndsOn, COALESCE(ActiveDays, '')
        INTO v_RuleType, v_RuleValue, v_RuleCapH, v_RuleMinH, v_RuleAppliesTo, v_RuleActive,
             v_RuleStarts, v_RuleEnds, v_RuleDays
        FROM sales.Discount
        WHERE DiscountId = p_DiscountId;

        IF v_RuleType IS NULL
           OR NOT v_RuleActive
           OR (v_RuleStarts IS NOT NULL AND v_RuleStarts > v_Today)
           OR (v_RuleEnds IS NOT NULL AND v_RuleEnds < v_Today)
           OR (v_RuleDays <> '' AND NOT EXISTS (SELECT 1 FROM unnest(string_to_array(v_RuleDays, ',')) AS d
                                                WHERE trim(d) = v_Weekday))
           OR v_GrossH < COALESCE(v_RuleMinH, 0)
           OR (EXISTS (SELECT 1 FROM sales.DiscountScope
                       WHERE DiscountId = p_DiscountId AND ScopeType = 'branch')
               AND NOT EXISTS (SELECT 1 FROM sales.DiscountScope
                               WHERE DiscountId = p_DiscountId AND ScopeType = 'branch'
                                 AND ScopeKey = p_BranchId))
           OR (EXISTS (SELECT 1 FROM sales.DiscountScope
                       WHERE DiscountId = p_DiscountId AND ScopeType = 'role')
               AND NOT EXISTS (SELECT 1 FROM sales.DiscountScope
                               WHERE DiscountId = p_DiscountId AND ScopeType = 'role'
                                 AND ScopeKey = v_CashierRoleId))
        THEN
            RAISE EXCEPTION 'That discount does not apply to this sale.' USING DETAIL = '52044';
        END IF;

        /* The lines the rule covers. 'item' and 'category' are the old names
           for a selected scope. */
        v_BaseH := COALESCE((
            SELECT trunc(SUM(l.UnitPriceH * l.Quantity - l.LineDiscountH))::bigint
            FROM unnest(v_Lines) AS l
            JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
            WHERE v_RuleAppliesTo = 'all'
               OR (v_RuleAppliesTo = 'products' AND i.Kind = 'product')
               OR (v_RuleAppliesTo = 'services' AND i.Kind = 'service')
               OR (v_RuleAppliesTo IN ('selected', 'item', 'category') AND EXISTS (
                       SELECT 1 FROM sales.DiscountScope AS sc
                       WHERE sc.DiscountId = p_DiscountId
                         AND ((sc.ScopeType = 'item' AND sc.ScopeKey = i.ItemId)
                           OR (sc.ScopeType = 'category' AND sc.ScopeKey = i.CategoryId))))
        ), 0);

        IF v_BaseH <= 0 THEN
            RAISE EXCEPTION 'That discount does not apply to this sale.' USING DETAIL = '52044';
        END IF;

        v_RuleH :=
            CASE WHEN v_RuleType = 'percentage'
                 THEN round(v_BaseH * v_RuleValue / 10000.0, 0)::bigint
                 ELSE v_RuleValue END;

        IF v_RuleH > v_BaseH THEN v_RuleH := v_BaseH; END IF;
        IF v_RuleCapH > 0 AND v_RuleH > v_RuleCapH THEN v_RuleH := v_RuleCapH; END IF;

        IF v_DiscountH > v_RuleH + 1 THEN
            IF v_OverrideReason IS NULL OR v_OverrideBy IS NULL THEN
                RAISE EXCEPTION 'The discount is more than its rule gives.' USING DETAIL = '52045';
            END IF;

            v_Overridden := true;
        END IF;
    ELSIF v_DiscountH > 0 THEN
        /* A typed amount with no rule behind it. */
        IF v_OverrideReason IS NULL OR v_OverrideBy IS NULL THEN
            RAISE EXCEPTION 'A discount must come from a discount rule.' USING DETAIL = '52043';
        END IF;

        v_Overridden := true;
    END IF;

    /*
      Approval is enforced here, not only in the browser.

      A discount with an approval threshold that is exceeded needs an approver
      who holds discounts.approve right now (an active user, permissions as
      they stand). The API decides who the approver is — the cashier, or
      another user whose password it has just checked — and passes their id.
    */
    IF p_DiscountId IS NOT NULL THEN
        v_ApprovalAboveH := (SELECT ApprovalAboveH FROM sales.Discount WHERE DiscountId = p_DiscountId);

        IF v_ApprovalAboveH > 0 AND v_DiscountH > v_ApprovalAboveH THEN
            IF v_ApprovedBy IS NULL THEN
                RAISE EXCEPTION 'This discount needs approval from someone allowed to approve discounts.' USING DETAIL = '63050';
            END IF;

            IF NOT EXISTS (SELECT 1
                           FROM core.vw_EffectivePermission AS ep
                           JOIN core.AppUser AS u ON u.UserId = ep.UserId
                           WHERE ep.UserId = v_ApprovedBy
                             AND ep.PermissionKey = 'discounts.approve'
                             AND u.Status = 'active') THEN
                RAISE EXCEPTION 'The approver is not allowed to approve discounts.' USING DETAIL = '63051';
            END IF;
        ELSE
            v_ApprovedBy := NULL;   -- nothing needed approving
        END IF;
    ELSE
        v_ApprovedBy := NULL;
    END IF;

    IF NOT v_Overridden THEN
        v_OverrideBy := NULL;
        v_OverrideReason := NULL;
    END IF;

    IF p_OrderType IS NOT NULL AND p_OrderType NOT IN ('dine_in', 'takeaway', 'delivery', 'other') THEN
        RAISE EXCEPTION 'Order type is dine_in, takeaway, delivery or other.' USING DETAIL = '52030';
    END IF;

    /*
      One basis for every stored figure (prices are VAT inclusive):
        TotalH     what the customer pays
        TaxH       the VAT inside it
        SubtotalH  the basket ex-VAT, before the invoice discount
        DiscountH  the invoice discount ex-VAT — whatever closes
                   SubtotalH − DiscountH + TaxH = TotalH, so a rounding
                   halala never leaves the invoice unbalanced.
    */
    v_TotalH      := v_GrossH - v_DiscountH;
    v_TaxH        := fin.fn_VatFromGross(v_TotalH, v_VatRate);
    v_NetH        := v_TotalH - v_TaxH;
    v_SubtotalH   := v_GrossH - fin.fn_VatFromGross(v_GrossH, v_VatRate);
    v_DiscountExH := v_SubtotalH - v_NetH;

    /*
      Cash is the only tender that can exceed what it pays for.

      The till sends the cash line as the amount applied to the sale and
      p_TenderedH as the notes handed over; an older client sends the cash line
      as the notes handed over. Both are accepted: the cash received is the
      larger of the two, the cash due is whatever the other tenders leave, and
      change is the difference. The ledger takes only the cash due, so the
      entry balances whichever way the client counted.
    */
    v_NonCashH  := COALESCE((SELECT SUM(p.AmountH)::bigint FROM unnest(v_Payments) AS p WHERE p.Method <> 'cash'), 0);
    v_CashLineH := COALESCE((SELECT SUM(p.AmountH)::bigint FROM unnest(v_Payments) AS p WHERE p.Method = 'cash'), 0);

    IF v_NonCashH > v_TotalH THEN
        RAISE EXCEPTION 'Card, bank and credit payments cannot exceed the total; only cash gives change.' USING DETAIL = '52031';
    END IF;

    v_CashDueH      := v_TotalH - v_NonCashH;
    v_CashReceivedH := CASE WHEN COALESCE(p_TenderedH, 0) > v_CashLineH THEN p_TenderedH ELSE v_CashLineH END;

    IF v_CashReceivedH < v_CashDueH THEN
        RAISE EXCEPTION 'Payments do not cover the total.' USING DETAIL = '52005';
    END IF;

    v_CreditH := COALESCE((SELECT SUM(p.AmountH)::bigint FROM unnest(v_Payments) AS p WHERE p.Method = 'credit'), 0);

    IF v_CreditH > 0 THEN
        IF p_CustomerId IS NULL THEN
            RAISE EXCEPTION 'A credit sale needs a customer.' USING DETAIL = '52006';
        END IF;

        IF EXISTS (SELECT 1 FROM core.Customer
                   WHERE CustomerId = p_CustomerId
                     AND BalanceH + v_CreditH > CreditLimitH) THEN
            RAISE EXCEPTION 'This sale would take the customer over their credit limit.' USING DETAIL = '52007';
        END IF;
    END IF;

    /*----------------------------------------------------------------- write */

    BEGIN
        /*
          The invoice number, gap-free.

          Taken from the counter row inside this transaction: the UPDATE locks
          the row, so concurrent commits queue here, and a rollback undoes the
          increment, so the next sale that succeeds gets the number this one
          would have had. A sequence gives its value away outside the
          transaction, which is how INV-1013 went missing.
        */
        UPDATE sales.InvoiceCounter AS c
        SET NextNumber = c.NextNumber + 1,
            UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE c.CounterKey = 'invoice'
        RETURNING c.NextNumber - 1, c.Prefix INTO v_Seq, v_Prefix;

        IF v_Seq IS NULL THEN
            RAISE EXCEPTION 'The invoice counter is missing. Run migration 002.' USING DETAIL = '52046';
        END IF;

        v_SaleId := core.fn_NewId('sal_');
        v_InvoiceNumber := v_Prefix || v_Seq;
        v_ChangeH := v_CashReceivedH - v_CashDueH;

        INSERT INTO sales.Sale
            (SaleId, InvoiceNumber, BranchId, CustomerId, ServedByUserId, CashierName,
             SubtotalH, DiscountH, TaxH, TotalH, TenderedH, ChangeH, DiscountId,
             Status, SoldAtUtc, CreatedBy, IdempotencyKey, DiscountApprovedBy, OrderType,
             OverrideApprovedBy, OverrideReason)
        VALUES
            (v_SaleId, v_InvoiceNumber, p_BranchId, p_CustomerId, p_ServedByUserId, p_CashierName,
             v_SubtotalH, v_DiscountExH, v_TaxH, v_TotalH, p_TenderedH, v_ChangeH, p_DiscountId,
             'completed', now() AT TIME ZONE 'utc', p_CashierName, p_IdempotencyKey,
             v_ApprovedBy, p_OrderType,
             v_OverrideBy, v_OverrideReason);

        INSERT INTO sales.SaleLine
            (SaleId, ItemId, NameAr, NameEn, Kind, PrintGroupId,
             Quantity, UnitPriceH, UnitCostH, LineDiscountH, Note, ListPriceH)
        SELECT
            v_SaleId, l.ItemId, i.NameAr, i.NameEn, i.Kind, i.PrintGroupId,
            l.Quantity, l.UnitPriceH, i.CostH, l.LineDiscountH, l.Note, i.PriceH
        FROM unnest(v_Lines) AS l
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId;

        /* Cash is stored as received, so cash less ChangeH is what the
           drawer kept — the rule the summary's payment mix applies. */
        INSERT INTO sales.SalePayment (SaleId, Method, AmountH, Reference)
        SELECT v_SaleId, p.Method, p.AmountH, p.Reference
        FROM unnest(v_Payments) AS p WHERE p.AmountH > 0 AND p.Method <> 'cash';

        IF v_CashReceivedH > 0 THEN
            INSERT INTO sales.SalePayment (SaleId, Method, AmountH, Reference)
            VALUES (v_SaleId, 'cash', v_CashReceivedH,
                    (SELECT p.Reference FROM unnest(v_Payments) AS p
                     WHERE p.Method = 'cash' AND p.Reference IS NOT NULL
                     LIMIT 1));
        END IF;

        UPDATE inv.StockLevel AS s
        SET Quantity = s.Quantity - agg.Qty,
            UpdatedAtUtc = now() AT TIME ZONE 'utc'
        FROM (SELECT l.ItemId, SUM(l.Quantity) AS Qty
              FROM unnest(v_Lines) AS l
              JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
              WHERE i.TracksStock
              GROUP BY l.ItemId) AS agg
        WHERE agg.ItemId = s.ItemId
          AND s.BranchId = p_BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, Actor)
        SELECT
            l.ItemId, p_BranchId, 'sale', -SUM(l.Quantity),
            COALESCE(s.Quantity, 0), i.CostH,
            v_InvoiceNumber, 'Sale', 'بيع', p_CashierName
        FROM unnest(v_Lines) AS l
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
        LEFT JOIN inv.StockLevel AS s ON s.ItemId = l.ItemId AND s.BranchId = p_BranchId
        WHERE i.TracksStock
        GROUP BY l.ItemId, i.CostH, s.Quantity;

        IF v_CreditH > 0 THEN
            UPDATE core.Customer
            SET BalanceH = BalanceH + v_CreditH,
                UpdatedAtUtc = now() AT TIME ZONE 'utc'
            WHERE CustomerId = p_CustomerId;
        END IF;

        IF p_DiscountId IS NOT NULL THEN
            UPDATE sales.Discount SET UsageCount = UsageCount + 1 WHERE DiscountId = p_DiscountId;
        END IF;

        v_CardH := COALESCE((SELECT SUM(p.AmountH)::bigint FROM unnest(v_Payments) AS p WHERE p.Method = 'card'), 0);
        v_BankH := COALESCE((SELECT SUM(p.AmountH)::bigint FROM unnest(v_Payments) AS p WHERE p.Method = 'bank'), 0);
        v_CogsH := COALESCE((
            SELECT trunc(SUM(i.CostH * l.Quantity))::bigint
            FROM unnest(v_Lines) AS l JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
            WHERE i.TracksStock), 0);

        /* 4100 takes the sale net of VAT and of every discount
           (SubtotalH − DiscountH = TotalH − TaxH). */
        v_Entry := ARRAY[
            ROW('1000', v_CashDueH, 0, 'Cash'),
            ROW('1150', v_CardH,    0, 'Card clearing'),
            ROW('1100', v_BankH,    0, 'Bank'),
            ROW('1400', v_CreditH,  0, 'Customer credit'),
            ROW('4100', 0, v_NetH,  'Sales'),
            ROW('2100', 0, v_TaxH,  'Output VAT'),
            ROW('5100', v_CogsH, 0, 'Cost of goods sold'),
            ROW('1200', 0, v_CogsH, 'Inventory')
        ]::fin.JournalLineTable[];

        PERFORM fin.usp_PostJournalEntry(
            p_Kind            => 'sale',
            p_DescriptionEn   => v_InvoiceNumber,
            p_DescriptionAr   => v_InvoiceNumber,
            p_SourceReference => v_InvoiceNumber,
            p_BranchId        => p_BranchId,
            p_Actor           => p_CashierName,
            p_Lines           => to_jsonb(v_Entry));

        PERFORM fin.usp_RecordSaleCommission(p_SaleId => v_SaleId);

        IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l
                   JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
                   WHERE i.RequiresPreparation) THEN
            v_PrepId := core.fn_NewId('prp_');

            INSERT INTO sales.PreparationOrder
                (PreparationId, OrderNumber, SaleId, BranchId, CustomerName, TotalH, Status, OrderType)
            VALUES
                (v_PrepId, v_InvoiceNumber, v_SaleId, p_BranchId,
                 (SELECT NameEn FROM core.Customer WHERE CustomerId = p_CustomerId),
                 v_TotalH, 'open', p_OrderType);

            INSERT INTO sales.PreparationItem
                (PreparationId, ItemId, NameAr, NameEn, Quantity, Note)
            SELECT v_PrepId, l.ItemId, i.NameAr, i.NameEn, l.Quantity, l.Note
            FROM unnest(v_Lines) AS l
            JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
            WHERE i.RequiresPreparation;
        END IF;
    EXCEPTION
        /*
          Two retries racing each other.

          Both passed the replay check before either committed, so the second
          hits the unique index. That is the index doing its job, not a fault —
          return the sale the winner created rather than an error, which is the
          same answer the replay check would have given a moment later. The
          block's writes, the invoice number included, are rolled back.
        */
        WHEN unique_violation THEN
            IF p_IdempotencyKey IS NOT NULL THEN
                RETURN QUERY
                    SELECT s.SaleId, s.InvoiceNumber FROM sales.Sale AS s
                    WHERE s.IdempotencyKey = p_IdempotencyKey;
                IF FOUND THEN RETURN; END IF;
            END IF;
            RAISE;
    END;

    RETURN QUERY SELECT v_SaleId, v_InvoiceNumber;
END $$;

/*--------------------------------------------------- void refuses a returned sale */

CREATE OR REPLACE FUNCTION sales.usp_VoidSale(
    p_SaleId text,
    p_Reason text,
    p_Actor  text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_BranchId        varchar;
    v_InvoiceNumber   varchar;
    v_CustomerId      varchar;
    v_CreditH         bigint;
    v_OriginalEntryId varchar;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sales.Sale WHERE SaleId = p_SaleId) THEN
        RAISE EXCEPTION 'Sale not found.' USING DETAIL = '52010';
    END IF;

    IF EXISTS (SELECT 1 FROM sales.Sale WHERE SaleId = p_SaleId AND Status = 'voided') THEN
        RAISE EXCEPTION 'This sale is already voided.' USING DETAIL = '52011';
    END IF;

    IF trim(COALESCE(p_Reason, '')) = '' THEN
        RAISE EXCEPTION 'A void needs a reason on the record.' USING DETAIL = '52012';
    END IF;

    /* Returned units were already restocked and refunded. Voiding would do
       both again. */
    IF EXISTS (SELECT 1 FROM sales.SaleReturn WHERE SaleId = p_SaleId) THEN
        RAISE EXCEPTION 'This sale has returns against it and cannot be voided.' USING DETAIL = '67012';
    END IF;

    SELECT BranchId, InvoiceNumber, CustomerId INTO v_BranchId, v_InvoiceNumber, v_CustomerId
    FROM sales.Sale WHERE SaleId = p_SaleId;

    /* Stock comes back. */
    UPDATE inv.StockLevel AS s
    SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = now() AT TIME ZONE 'utc'
    FROM (SELECT sl.ItemId, SUM(sl.Quantity) AS Qty
          FROM sales.SaleLine AS sl
          JOIN core.CatalogItem AS i ON i.ItemId = sl.ItemId
          WHERE sl.SaleId = p_SaleId AND i.TracksStock
          GROUP BY sl.ItemId) AS agg
    WHERE agg.ItemId = s.ItemId
      AND s.BranchId = v_BranchId;

    INSERT INTO inv.StockMovement
        (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
         Reference, ReasonEn, ReasonAr, Actor)
    SELECT
        sl.ItemId, v_BranchId, 'return', SUM(sl.Quantity),
        COALESCE(st.Quantity, 0), sl.UnitCostH,
        v_InvoiceNumber, p_Reason, p_Reason, p_Actor
    FROM sales.SaleLine AS sl
    JOIN core.CatalogItem AS i ON i.ItemId = sl.ItemId
    LEFT JOIN inv.StockLevel AS st ON st.ItemId = sl.ItemId AND st.BranchId = v_BranchId
    WHERE sl.SaleId = p_SaleId AND i.TracksStock
    GROUP BY sl.ItemId, sl.UnitCostH, st.Quantity;

    /* Any credit taken is released. */
    v_CreditH := COALESCE((
        SELECT SUM(AmountH)::bigint FROM sales.SalePayment
        WHERE SaleId = p_SaleId AND Method = 'credit'), 0);

    IF v_CreditH > 0 AND v_CustomerId IS NOT NULL THEN
        UPDATE core.Customer
        SET BalanceH = BalanceH - v_CreditH, UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE CustomerId = v_CustomerId;
    END IF;

    /* Commission earned on a voided sale was never earned. */
    DELETE FROM fin.CommissionEntry
    WHERE SaleId = p_SaleId AND PayrollRunId IS NULL;

    /* Reverse the ledger entry rather than deleting it. */
    v_OriginalEntryId := (
        SELECT EntryId FROM fin.JournalEntry
        WHERE SourceReference = v_InvoiceNumber AND Kind = 'sale'
          AND ReversedByEntryId IS NULL
        ORDER BY PostedAtUtc DESC
        LIMIT 1);

    IF v_OriginalEntryId IS NOT NULL THEN
        PERFORM fin.usp_ReverseJournalEntry(
            p_EntryId => v_OriginalEntryId,
            p_Reason  => p_Reason,
            p_Actor   => p_Actor);
    END IF;

    UPDATE sales.Sale
    SET Status = 'voided', UpdatedAtUtc = now() AT TIME ZONE 'utc', UpdatedBy = p_Actor
    WHERE SaleId = p_SaleId;
END $$;

/*------------------------------------------------------------- issue a return */

CREATE OR REPLACE FUNCTION sales.usp_IssueReturn(
    p_SaleId       text,
    p_ReasonCode   text,
    p_Note         text DEFAULT NULL,
    p_RefundMethod text DEFAULT NULL,
    p_Actor        text DEFAULT NULL,
    p_Lines        jsonb DEFAULT '[]')
RETURNS TABLE (ReturnId varchar, NoteNumber varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Lines         sales.ReturnLineTable[] :=
        ARRAY(SELECT jsonb_populate_recordset(NULL::sales.ReturnLineTable, p_Lines));
    /* What is asked for, one row per sale line. */
    v_Req           sales.ReturnLineTable[];
    v_Note          varchar := NULLIF(trim(p_Note), '');

    v_Status        varchar;
    v_BranchId      varchar;
    v_CustomerId    varchar;
    v_Invoice       varchar;
    v_SaleTotalH    bigint;
    v_SaleTaxH      bigint;
    v_SaleDiscountH bigint;

    v_GrossH        bigint;
    v_Completes     boolean;
    v_PriorTotalH   bigint;
    v_PriorTaxH     bigint;
    v_TotalH        bigint;
    v_TopLineId     bigint;
    v_Residue       bigint := 0;
    v_TaxH          bigint;
    v_NetH          bigint;
    v_CogsH         bigint;

    v_Seq           bigint;
    v_ReturnId      varchar;
    v_NoteNumber    varchar;
    v_Entry         fin.JournalLineTable[];
    v_EntryId       varchar;
BEGIN
    IF p_ReasonCode IS NULL OR p_ReasonCode NOT IN
       ('damaged', 'not_as_described', 'changed_mind', 'wrong_item', 'other') THEN
        RAISE EXCEPTION 'Choose a reason for the return.' USING DETAIL = '67008';
    END IF;

    IF p_ReasonCode = 'other' AND v_Note IS NULL THEN
        RAISE EXCEPTION 'Describe the reason when choosing "Other".' USING DETAIL = '67009';
    END IF;

    IF p_RefundMethod IS NULL OR p_RefundMethod NOT IN ('cash', 'card', 'credit', 'bank') THEN
        RAISE EXCEPTION 'Refund by cash, card, bank or to the customer''s account.' USING DETAIL = '67005';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l WHERE l.Quantity < 0) THEN
        RAISE EXCEPTION 'Return quantities cannot be negative.' USING DETAIL = '67010';
    END IF;

    v_Req := ARRAY(
        SELECT ROW(l.SaleLineId, SUM(l.Quantity))::sales.ReturnLineTable
        FROM unnest(v_Lines) AS l
        WHERE l.Quantity > 0
        GROUP BY l.SaleLineId);

    IF cardinality(v_Req) = 0 THEN
        RAISE EXCEPTION 'Choose at least one item to return.' USING DETAIL = '67002';
    END IF;

    /* The lock serialises returns against one sale. */
    SELECT s.Status, s.BranchId, s.CustomerId, s.InvoiceNumber, s.TotalH, s.TaxH
    INTO v_Status, v_BranchId, v_CustomerId, v_Invoice, v_SaleTotalH, v_SaleTaxH
    FROM sales.Sale AS s
    WHERE s.SaleId = p_SaleId
    FOR UPDATE;

    IF v_Invoice IS NULL THEN
        RAISE EXCEPTION 'Sale not found.' USING DETAIL = '67000';
    END IF;

    IF v_Status = 'voided' THEN
        RAISE EXCEPTION 'A voided sale has nothing left to return.' USING DETAIL = '67001';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Req) AS r
               WHERE NOT EXISTS (SELECT 1 FROM sales.SaleLine AS sl
                                 WHERE sl.SaleLineId = r.SaleLineId AND sl.SaleId = p_SaleId)) THEN
        RAISE EXCEPTION 'That line is not part of this invoice.' USING DETAIL = '67003';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Req) AS r
               JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
               WHERE r.Quantity > sl.Quantity - sl.ReturnedQty) THEN
        RAISE EXCEPTION 'You cannot return more than was sold and not already returned.' USING DETAIL = '67004';
    END IF;

    /*------------------------------------------------------ price it */

    /* Whole halalas, cut as SQL Server cut a decimal into BIGINT. */
    v_GrossH := (SELECT trunc(SUM(sl.UnitPriceH * sl.Quantity - sl.LineDiscountH))::bigint
                 FROM sales.SaleLine AS sl WHERE sl.SaleId = p_SaleId);

    /* The invoice discount, VAT inclusive, is what the lines came to less
       what was charged. Sale.DiscountH is ex-VAT from 004 on (and was
       inclusive before it), so it is derived rather than read — right for
       sales on either side of that change. */
    v_SaleDiscountH := CASE WHEN v_GrossH > v_SaleTotalH THEN v_GrossH - v_SaleTotalH ELSE 0 END;

    /*
      Each returned line is priced as its share of what the line came to
      (PortionH), less its share of the invoice discount (AmountH). The same
      pricing is written to SaleReturnLine below; here it gives the total, the
      cost of the goods coming back, and the largest line (which takes any
      rounding residue).
    */
    WITH Calc AS (
        SELECT c.SaleLineId, c.Qty, c.UnitCostH, c.Tracks,
               c.PortionH - CASE WHEN v_GrossH > 0
                                 THEN round(v_SaleDiscountH::numeric * c.PortionH / v_GrossH, 0)::bigint
                                 ELSE 0 END AS AmountH
        FROM (SELECT sl.SaleLineId, r.Quantity AS Qty, sl.UnitCostH,
                     COALESCE(ci.TracksStock, false) AS Tracks,
                     round((sl.UnitPriceH * sl.Quantity - sl.LineDiscountH) * r.Quantity / sl.Quantity, 0)::bigint AS PortionH
              FROM unnest(v_Req) AS r
              JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
              LEFT JOIN core.CatalogItem AS ci ON ci.ItemId = sl.ItemId) AS c
    )
    SELECT (SELECT SUM(AmountH)::bigint FROM Calc),
           (SELECT SaleLineId FROM Calc ORDER BY AmountH DESC, SaleLineId LIMIT 1),
           COALESCE((SELECT SUM(round(Qty * UnitCostH, 0)::bigint)::bigint FROM Calc WHERE Tracks), 0)
    INTO v_TotalH, v_TopLineId, v_CogsH;

    v_Completes := NOT EXISTS (
        SELECT 1 FROM sales.SaleLine AS sl
        LEFT JOIN unnest(v_Req) AS r ON r.SaleLineId = sl.SaleLineId
        WHERE sl.SaleId = p_SaleId
          AND sl.Quantity - sl.ReturnedQty - COALESCE(r.Quantity, 0) > 0);

    v_PriorTotalH := COALESCE((SELECT SUM(RefundH)::bigint FROM sales.SaleReturn WHERE SaleId = p_SaleId), 0);
    v_PriorTaxH   := COALESCE((SELECT SUM(TaxH)::bigint    FROM sales.SaleReturn WHERE SaleId = p_SaleId), 0);

    /* The last return takes exactly what is left, so rounding never leaves
       a halala behind (or refunds one too many). The difference lands on
       the largest line. */
    IF v_Completes THEN
        v_Residue := (v_SaleTotalH - v_PriorTotalH) - v_TotalH;
        v_TotalH := v_SaleTotalH - v_PriorTotalH;
    END IF;

    IF v_TotalH < 0 THEN v_TotalH := 0; END IF;

    v_TaxH :=
        CASE WHEN v_Completes THEN v_SaleTaxH - v_PriorTaxH
             WHEN v_SaleTotalH > 0
                  THEN round(v_TotalH::numeric * v_SaleTaxH / v_SaleTotalH, 0)::bigint
             ELSE 0 END;

    IF v_TaxH < 0 THEN v_TaxH := 0; END IF;
    IF v_TaxH > v_TotalH THEN v_TaxH := v_TotalH; END IF;

    v_NetH := v_TotalH - v_TaxH;

    /*------------------------------------------------- refund checks */

    IF p_RefundMethod = 'credit' THEN
        IF v_CustomerId IS NULL THEN
            RAISE EXCEPTION 'A refund to account needs a customer on the sale.' USING DETAIL = '67006';
        END IF;

        IF v_TotalH > COALESCE((SELECT c.BalanceH FROM core.Customer AS c
                                WHERE c.CustomerId = v_CustomerId FOR UPDATE), 0) THEN
            RAISE EXCEPTION 'The refund is more than the customer owes. Refund it in cash or by card instead.' USING DETAIL = '67007';
        END IF;
    END IF;

    /*--------------------------------------------------------- write */

    v_Seq := nextval('sales.CreditNoteSequence');
    v_ReturnId   := core.fn_NewId('ret_');
    v_NoteNumber := 'CN-' || v_Seq;

    INSERT INTO sales.SaleReturn
        (ReturnId, SaleId, ReasonAr, ReasonEn, RefundH, ReturnedBy,
         NoteNumber, BranchId, CustomerId, ReasonCode, Note,
         SubtotalH, TaxH, CogsH, RefundMethod)
    VALUES
        (v_ReturnId, p_SaleId, v_Note, COALESCE(v_Note, p_ReasonCode), v_TotalH, p_Actor,
         v_NoteNumber, v_BranchId, v_CustomerId, p_ReasonCode, v_Note,
         v_NetH, v_TaxH, v_CogsH, p_RefundMethod);

    /* The lines as priced above, the residue on the largest. */
    INSERT INTO sales.SaleReturnLine (ReturnId, SaleLineId, Quantity, ItemId, UnitPriceH, UnitCostH, AmountH)
    SELECT v_ReturnId, c.SaleLineId, c.Qty, c.ItemId, c.UnitPriceH, c.UnitCostH,
           c.PortionH - CASE WHEN v_GrossH > 0
                             THEN round(v_SaleDiscountH::numeric * c.PortionH / v_GrossH, 0)::bigint
                             ELSE 0 END
                      + CASE WHEN c.SaleLineId = v_TopLineId THEN v_Residue ELSE 0 END
    FROM (SELECT sl.SaleLineId, sl.ItemId, r.Quantity AS Qty, sl.UnitPriceH, sl.UnitCostH,
                 round((sl.UnitPriceH * sl.Quantity - sl.LineDiscountH) * r.Quantity / sl.Quantity, 0)::bigint AS PortionH
          FROM unnest(v_Req) AS r
          JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId) AS c;

    /* Commission on returned work was not earned. Only what payroll has not
       yet paid is reduced, in proportion to what remains of the item. */
    WITH Comm AS (
        SELECT sl.ItemId,
               SUM(sl.Quantity - sl.ReturnedQty) AS BeforeQty,
               SUM(sl.Quantity - sl.ReturnedQty - COALESCE(r.Quantity, 0)) AS AfterQty
        FROM sales.SaleLine AS sl
        LEFT JOIN unnest(v_Req) AS r ON r.SaleLineId = sl.SaleLineId
        WHERE sl.SaleId = p_SaleId
          AND sl.ItemId IN (SELECT rl.ItemId FROM unnest(v_Req) AS rr
                            JOIN sales.SaleLine AS rl ON rl.SaleLineId = rr.SaleLineId
                            WHERE rl.Kind = 'service')
        GROUP BY sl.ItemId
    ),
    Removed AS (
        DELETE FROM fin.CommissionEntry AS ce
        USING Comm AS c
        WHERE c.ItemId = ce.ItemId
          AND ce.SaleId = p_SaleId AND ce.PayrollRunId IS NULL AND c.AfterQty <= 0
    )
    UPDATE fin.CommissionEntry AS ce
    SET AmountH = round(ce.AmountH::numeric * c.AfterQty / c.BeforeQty, 0)::bigint
    FROM Comm AS c
    WHERE c.ItemId = ce.ItemId
      AND ce.SaleId = p_SaleId AND ce.PayrollRunId IS NULL
      AND c.AfterQty > 0 AND c.BeforeQty > c.AfterQty;

    UPDATE sales.SaleLine AS sl
    SET ReturnedQty = sl.ReturnedQty + r.Quantity
    FROM unnest(v_Req) AS r
    WHERE r.SaleLineId = sl.SaleLineId;

    UPDATE sales.Sale
    SET Status = CASE WHEN v_Completes THEN 'returned' ELSE 'partially_returned' END,
        UpdatedAtUtc = now() AT TIME ZONE 'utc',
        UpdatedBy = p_Actor
    WHERE SaleId = p_SaleId;

    /* Stock comes back to the branch that sold it. */
    IF v_BranchId IS NOT NULL THEN
        INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
        SELECT DISTINCT sl.ItemId, v_BranchId, 0
        FROM unnest(v_Req) AS r
        JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
        JOIN core.CatalogItem AS ci ON ci.ItemId = sl.ItemId
        WHERE ci.TracksStock
          AND NOT EXISTS (SELECT 1 FROM inv.StockLevel AS s
                          WHERE s.ItemId = sl.ItemId AND s.BranchId = v_BranchId);

        UPDATE inv.StockLevel AS s
        SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = now() AT TIME ZONE 'utc'
        FROM (SELECT sl.ItemId, SUM(r.Quantity) AS Qty
              FROM unnest(v_Req) AS r
              JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
              JOIN core.CatalogItem AS ci ON ci.ItemId = sl.ItemId
              WHERE ci.TracksStock
              GROUP BY sl.ItemId) AS agg
        WHERE agg.ItemId = s.ItemId
          AND s.BranchId = v_BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, Actor)
        SELECT agg.ItemId, v_BranchId, 'return', agg.Qty, s.Quantity, agg.UnitCostH,
               v_NoteNumber, 'Return against ' || v_Invoice, 'مرتجع على ' || v_Invoice, p_Actor
        FROM (SELECT sl.ItemId, SUM(r.Quantity) AS Qty, MAX(sl.UnitCostH) AS UnitCostH
              FROM unnest(v_Req) AS r
              JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
              JOIN core.CatalogItem AS ci ON ci.ItemId = sl.ItemId
              WHERE ci.TracksStock
              GROUP BY sl.ItemId) AS agg
        JOIN inv.StockLevel AS s ON s.ItemId = agg.ItemId AND s.BranchId = v_BranchId;
    END IF;

    IF p_RefundMethod = 'credit' AND v_TotalH > 0 THEN
        UPDATE core.Customer
        SET BalanceH = BalanceH - v_TotalH, UpdatedAtUtc = now() AT TIME ZONE 'utc', UpdatedBy = p_Actor
        WHERE CustomerId = v_CustomerId;
    END IF;

    IF v_TotalH > 0 OR v_CogsH > 0 THEN
        v_Entry := ARRAY[
            ROW('4100', v_NetH, 0, 'Sales returned'),
            ROW('2100', v_TaxH, 0, 'Output VAT reversed'),
            ROW(CASE p_RefundMethod WHEN 'cash' THEN '1000'
                                    WHEN 'card' THEN '1150'
                                    WHEN 'bank' THEN '1100'
                                    ELSE '1400' END, 0, v_TotalH, 'Refund — ' || p_RefundMethod),
            ROW('1200', v_CogsH, 0, 'Inventory returned'),
            ROW('5100', 0, v_CogsH, 'Cost of goods sold reversed')
        ]::fin.JournalLineTable[];

        SELECT j.EntryId INTO v_EntryId
        FROM fin.usp_PostJournalEntry(
            p_Kind            => 'return',
            p_DescriptionEn   => 'Credit note ' || v_NoteNumber || ' for ' || v_Invoice,
            p_DescriptionAr   => 'إشعار دائن ' || v_NoteNumber || ' للفاتورة ' || v_Invoice,
            p_SourceReference => v_NoteNumber,
            p_BranchId        => v_BranchId,
            p_Actor           => p_Actor,
            p_Lines           => to_jsonb(v_Entry)) AS j;

        UPDATE sales.SaleReturn SET EntryId = v_EntryId WHERE ReturnId = v_ReturnId;
    END IF;

    RETURN QUERY SELECT v_ReturnId, v_NoteNumber;
END $$;

/*-------------------------------------------------------------- save discount */

CREATE OR REPLACE FUNCTION sales.usp_SaveDiscount(
    p_DiscountId     text    DEFAULT NULL,   -- null creates
    p_NameAr         text    DEFAULT NULL,
    p_NameEn         text    DEFAULT NULL,
    p_Description    text    DEFAULT NULL,
    p_DiscountType   text    DEFAULT NULL,   -- percentage | fixed
    p_Value          integer DEFAULT NULL,   -- basis points, or halalas
    p_MaxDiscountH   bigint  DEFAULT NULL,   -- null: no cap
    p_MinSubtotalH   bigint  DEFAULT 0,
    p_ApprovalAboveH bigint  DEFAULT NULL,   -- null: never needs approval
    p_AppliesTo      text    DEFAULT 'all',  -- all | products | services | selected
    p_AppliesToIds   text    DEFAULT NULL,   -- item and category ids, comma separated
    p_BranchIds      text    DEFAULT NULL,   -- empty: every branch
    p_RoleIds        text    DEFAULT NULL,   -- empty: anyone at the till
    p_IsAutomatic    boolean DEFAULT false,
    p_AllowStacking  boolean DEFAULT false,
    p_ActiveDays     text    DEFAULT '',     -- 0 = Sunday, comma separated; empty: every day
    p_StartsOn       date    DEFAULT NULL,
    p_EndsOn         date    DEFAULT NULL,
    p_IsActive       boolean DEFAULT true)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Targets    text[];
    v_Branches   text[];
    v_Roles      text[];
    v_ActiveDays varchar := COALESCE(p_ActiveDays, '');
    v_SavedId    varchar;
BEGIN
    IF trim(COALESCE(p_NameAr, '')) = '' OR trim(COALESCE(p_NameEn, '')) = '' THEN
        RAISE EXCEPTION 'Both names are required.' USING DETAIL = '63000';
    END IF;

    IF p_DiscountId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Discount WHERE DiscountId = p_DiscountId) THEN
        RAISE EXCEPTION 'No such discount.' USING DETAIL = '63015';
    END IF;

    IF EXISTS (SELECT 1 FROM sales.Discount
               WHERE NameEn = p_NameEn AND (p_DiscountId IS NULL OR DiscountId <> p_DiscountId)) THEN
        RAISE EXCEPTION 'Another discount already uses this name.' USING DETAIL = '63014';
    END IF;

    IF p_DiscountType NOT IN ('percentage', 'fixed') THEN
        RAISE EXCEPTION 'A discount is either a percentage or a fixed amount.' USING DETAIL = '63001';
    END IF;

    IF COALESCE(p_Value, 0) <= 0 THEN
        RAISE EXCEPTION 'Enter a value above zero, or the discount does nothing.' USING DETAIL = '63002';
    END IF;

    /* A percentage above 100 would pay the customer to take the goods. */
    IF p_DiscountType = 'percentage' AND p_Value > 10000 THEN
        RAISE EXCEPTION 'A percentage discount cannot exceed 100%%.' USING DETAIL = '63003';
    END IF;

    IF p_MaxDiscountH < 0 THEN
        RAISE EXCEPTION 'A maximum cannot be negative.' USING DETAIL = '63004';
    END IF;

    IF COALESCE(p_MinSubtotalH, 0) < 0 THEN
        RAISE EXCEPTION 'A minimum cannot be negative.' USING DETAIL = '63005';
    END IF;

    IF p_ApprovalAboveH < 0 THEN
        RAISE EXCEPTION 'An approval threshold cannot be negative.' USING DETAIL = '63006';
    END IF;

    /* A fixed discount capped below itself is always clipped — almost certainly
       a typo rather than a decision. */
    IF p_DiscountType = 'fixed' AND p_MaxDiscountH > 0 AND p_MaxDiscountH < p_Value THEN
        RAISE EXCEPTION 'The maximum is below the discount itself, so it would always be clipped.' USING DETAIL = '63017';
    END IF;

    IF p_EndsOn IS NOT NULL AND p_StartsOn IS NOT NULL AND p_EndsOn < p_StartsOn THEN
        RAISE EXCEPTION 'The end date cannot be before the start date.' USING DETAIL = '63007';
    END IF;

    IF p_AppliesTo NOT IN ('all', 'products', 'services', 'selected') THEN
        RAISE EXCEPTION 'Applies to all, products, services or selected.' USING DETAIL = '63008';
    END IF;

    /*------------------------------------------------------------- the sets */

    /* The lists are split with the default collation: a call passing a column
       would hand the parameters its case-insensitive one, which
       string_to_array refuses. */
    v_Targets := ARRAY(
        SELECT DISTINCT trim(v) FROM unnest(string_to_array(COALESCE(p_AppliesToIds, '') COLLATE "default", ',')) AS v
        WHERE trim(v) <> '');

    /* Item and category ids share one list on the screen; which is which is
       looked up, not trusted from the client. */
    IF p_AppliesTo = 'selected' THEN
        IF cardinality(v_Targets) = 0 THEN
            RAISE EXCEPTION 'Choose at least one item or category, or switch to "All".' USING DETAIL = '63009';
        END IF;

        IF EXISTS (SELECT 1 FROM unnest(v_Targets) AS t(Id)
                   WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem WHERE ItemId = t.Id)
                     AND NOT EXISTS (SELECT 1 FROM core.Category WHERE CategoryId = t.Id)) THEN
            RAISE EXCEPTION 'One of those items or categories does not exist.' USING DETAIL = '63010';
        END IF;
    ELSE
        v_Targets := '{}';
    END IF;

    v_Branches := ARRAY(
        SELECT DISTINCT trim(v) FROM unnest(string_to_array(COALESCE(p_BranchIds, '') COLLATE "default", ',')) AS v
        WHERE trim(v) <> '');

    IF EXISTS (SELECT 1 FROM unnest(v_Branches) AS b(Id)
               WHERE NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = b.Id)) THEN
        RAISE EXCEPTION 'One of those branches does not exist.' USING DETAIL = '63011';
    END IF;

    v_Roles := ARRAY(
        SELECT DISTINCT trim(v) FROM unnest(string_to_array(COALESCE(p_RoleIds, '') COLLATE "default", ',')) AS v
        WHERE trim(v) <> '');

    IF EXISTS (SELECT 1 FROM unnest(v_Roles) AS r(Id)
               WHERE NOT EXISTS (SELECT 1 FROM core.Role WHERE RoleId = r.Id)) THEN
        RAISE EXCEPTION 'One of those roles does not exist.' USING DETAIL = '63012';
    END IF;

    IF v_ActiveDays <> '' AND EXISTS (
           SELECT 1 FROM unnest(string_to_array(v_ActiveDays COLLATE "default", ',')) AS d
           WHERE trim(d) NOT IN ('0', '1', '2', '3', '4', '5', '6')) THEN
        RAISE EXCEPTION 'Days of the week are 0 (Sunday) to 6.' USING DETAIL = '63013';
    END IF;

    /*------------------------------------------------------------- write */

    IF p_DiscountId IS NULL THEN
        v_SavedId := core.fn_NewId('dsc_');

        INSERT INTO sales.Discount
            (DiscountId, NameAr, NameEn, Description, DiscountType, Value, MaxDiscountH,
             MinSubtotalH, ApprovalAboveH, AppliesTo, IsAutomatic, AllowStacking,
             ActiveDays, StartsOn, EndsOn, IsActive)
        VALUES
            (v_SavedId, p_NameAr, p_NameEn, p_Description, p_DiscountType, p_Value, p_MaxDiscountH,
             COALESCE(p_MinSubtotalH, 0), p_ApprovalAboveH, p_AppliesTo, p_IsAutomatic, p_AllowStacking,
             v_ActiveDays, p_StartsOn, p_EndsOn, p_IsActive);
    ELSE
        v_SavedId := p_DiscountId;

        /* UsageCount is not touched. It records how often this discount has
           been applied; an edit must not reset that history. */
        UPDATE sales.Discount
        SET NameAr = p_NameAr, NameEn = p_NameEn, Description = p_Description,
            DiscountType = p_DiscountType, Value = p_Value, MaxDiscountH = p_MaxDiscountH,
            MinSubtotalH = COALESCE(p_MinSubtotalH, 0), ApprovalAboveH = p_ApprovalAboveH,
            AppliesTo = p_AppliesTo, IsAutomatic = p_IsAutomatic, AllowStacking = p_AllowStacking,
            ActiveDays = v_ActiveDays, StartsOn = p_StartsOn, EndsOn = p_EndsOn,
            IsActive = p_IsActive, UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE DiscountId = p_DiscountId;
    END IF;

    /* Replaced wholesale, like every other set on a record. Ids that differ
       only in case are one id, as the case-insensitive key says. */
    DELETE FROM sales.DiscountScope WHERE DiscountId = v_SavedId;

    INSERT INTO sales.DiscountScope (DiscountId, ScopeType, ScopeKey)
    SELECT v_SavedId,
           CASE WHEN EXISTS (SELECT 1 FROM core.CatalogItem WHERE ItemId = t.Id)
                THEN 'item' ELSE 'category' END,
           t.Id
    FROM unnest(v_Targets) AS t(Id)
    UNION ALL
    SELECT v_SavedId, 'branch', b.Id FROM unnest(v_Branches) AS b(Id)
    UNION ALL
    SELECT v_SavedId, 'role', r.Id FROM unnest(v_Roles) AS r(Id)
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*------------------------------------------------------------ delete discount */

/*
  Delete only what was never used.

  A discount applied to a sale is named by that sale; removing it would leave
  the invoice pointing at nothing. Those are refused, and the answer is to
  deactivate them. One that was set up and never used is a mistake, and a
  mistake should be removable.
*/
CREATE OR REPLACE FUNCTION sales.usp_DeleteDiscount(p_DiscountId text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_Used integer;
BEGIN
    v_Used := (SELECT UsageCount FROM sales.Discount WHERE DiscountId = p_DiscountId);

    IF v_Used IS NULL THEN
        RAISE EXCEPTION 'No such discount.' USING DETAIL = '63015';
    END IF;

    IF v_Used > 0 OR EXISTS (SELECT 1 FROM sales.Sale WHERE DiscountId = p_DiscountId) THEN
        RAISE EXCEPTION 'This discount has been used on real sales. Deactivate it instead so the history stays intact.' USING DETAIL = '63016';
    END IF;

    /* DiscountScope cascades. */
    DELETE FROM sales.Discount WHERE DiscountId = p_DiscountId;
END $$;

/*-------------------------------------------------------- create a customer */

CREATE OR REPLACE FUNCTION core.usp_CreateCustomer(
    p_NameAr          text,
    p_NameEn          text,
    p_Phone           text   DEFAULT NULL,
    p_Email           text   DEFAULT NULL,
    p_VatNumber       text   DEFAULT NULL,
    p_CustomerType    text   DEFAULT NULL,   -- null = individual
    p_CreditLimitH    bigint DEFAULT 0,
    p_OpeningBalanceH bigint DEFAULT 0,
    p_OpeningAsOf     date   DEFAULT NULL,   -- null = today
    p_BranchId        text   DEFAULT NULL,   -- where the opening entry is tagged; null = business-wide
    p_Actor           text   DEFAULT NULL)
RETURNS TABLE (CustomerId varchar, EntryId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_NameAr          varchar := NULLIF(trim(p_NameAr), '');
    v_NameEn          varchar := NULLIF(trim(p_NameEn), '');
    v_CustomerType    varchar := COALESCE(NULLIF(trim(p_CustomerType), ''), 'individual');
    v_CreditLimitH    bigint  := COALESCE(p_CreditLimitH, 0);
    v_OpeningBalanceH bigint  := COALESCE(p_OpeningBalanceH, 0);
    v_CustomerId      varchar;
    v_EntryId         varchar;
    v_Lines           fin.JournalLineTable[];
BEGIN
    IF v_NameAr IS NULL OR v_NameEn IS NULL THEN
        RAISE EXCEPTION 'Both the Arabic and English name are required.' USING DETAIL = '68000';
    END IF;

    IF v_CreditLimitH < 0 THEN
        RAISE EXCEPTION 'A credit limit cannot be negative.' USING DETAIL = '68001';
    END IF;

    IF v_CustomerType NOT IN ('individual', 'business') THEN
        RAISE EXCEPTION 'A customer is an individual or a business.' USING DETAIL = '68004';
    END IF;

    IF v_OpeningBalanceH < 0 THEN
        RAISE EXCEPTION 'An opening balance cannot be negative.' USING DETAIL = '68006';
    END IF;

    IF v_OpeningBalanceH > v_CreditLimitH THEN
        RAISE EXCEPTION 'The opening balance is above the credit limit.' USING DETAIL = '68007';
    END IF;

    IF p_BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = p_BranchId) THEN
        RAISE EXCEPTION 'Unknown branch.' USING DETAIL = '68008';
    END IF;

    v_CustomerId := left(core.fn_NewId('cus_'), 24);

    INSERT INTO core.Customer
        (CustomerId, NameAr, NameEn, Phone, Email, VatNumber,
         CustomerType, CreditLimitH, BalanceH, CreatedBy, UpdatedBy)
    VALUES
        (v_CustomerId, v_NameAr, v_NameEn,
         NULLIF(trim(p_Phone), ''), NULLIF(trim(p_Email), ''),
         NULLIF(trim(p_VatNumber), ''),
         v_CustomerType, v_CreditLimitH, v_OpeningBalanceH, p_Actor, p_Actor);

    IF v_OpeningBalanceH > 0 THEN
        v_Lines := ARRAY[
            ROW('1400', v_OpeningBalanceH, 0, 'Opening receivable'),
            ROW('3900', 0, v_OpeningBalanceH, 'Opening equity')
        ]::fin.JournalLineTable[];

        SELECT j.EntryId INTO v_EntryId
        FROM fin.usp_PostJournalEntry(
            p_Kind            => 'customer_opening',
            p_DescriptionEn   => 'Opening balance — ' || v_NameEn,
            p_DescriptionAr   => 'رصيد افتتاحي — ' || v_NameAr,
            p_SourceReference => v_CustomerId,
            p_BranchId        => p_BranchId,
            p_Actor           => p_Actor,
            p_PostedAtUtc     => CASE WHEN p_OpeningAsOf IS NULL THEN now() AT TIME ZONE 'utc'
                                      ELSE p_OpeningAsOf::timestamp END,
            p_Lines           => to_jsonb(v_Lines)) AS j;
    END IF;

    RETURN QUERY SELECT v_CustomerId, v_EntryId;
END $$;

/*-------------------------------------------------------- update a customer */

CREATE OR REPLACE FUNCTION core.usp_UpdateCustomer(
    p_CustomerId   text,
    p_NameAr       text,
    p_NameEn       text,
    p_Phone        text    DEFAULT NULL,
    p_Email        text    DEFAULT NULL,
    p_VatNumber    text    DEFAULT NULL,
    p_CustomerType text    DEFAULT NULL,   -- null keeps
    p_CreditLimitH bigint  DEFAULT NULL,
    p_IsActive     boolean DEFAULT NULL,   -- null keeps
    p_Actor        text    DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_NameAr    varchar := NULLIF(trim(p_NameAr), '');
    v_NameEn    varchar := NULLIF(trim(p_NameEn), '');
    v_BalanceH  bigint;
    v_WasActive boolean;
BEGIN
    IF v_NameAr IS NULL OR v_NameEn IS NULL THEN
        RAISE EXCEPTION 'Both the Arabic and English name are required.' USING DETAIL = '68000';
    END IF;

    IF p_CreditLimitH IS NULL OR p_CreditLimitH < 0 THEN
        RAISE EXCEPTION 'A credit limit cannot be negative.' USING DETAIL = '68001';
    END IF;

    IF p_CustomerType IS NOT NULL AND p_CustomerType NOT IN ('individual', 'business') THEN
        RAISE EXCEPTION 'A customer is an individual or a business.' USING DETAIL = '68004';
    END IF;

    SELECT BalanceH, IsActive INTO v_BalanceH, v_WasActive
    FROM core.Customer
    WHERE CustomerId = p_CustomerId
    FOR UPDATE;

    IF v_BalanceH IS NULL THEN
        RAISE EXCEPTION 'Customer not found.' USING DETAIL = '68003';
    END IF;

    IF p_CreditLimitH < v_BalanceH THEN
        RAISE EXCEPTION 'The new limit is below what this customer already owes.' USING DETAIL = '68002';
    END IF;

    IF p_IsActive = false AND v_WasActive AND v_BalanceH > 0 THEN
        RAISE EXCEPTION 'This customer still owes money. Settle the balance before deactivating.' USING DETAIL = '68005';
    END IF;

    UPDATE core.Customer
    SET NameAr       = v_NameAr,
        NameEn       = v_NameEn,
        Phone        = NULLIF(trim(p_Phone), ''),
        Email        = NULLIF(trim(p_Email), ''),
        VatNumber    = NULLIF(trim(p_VatNumber), ''),
        CustomerType = COALESCE(p_CustomerType, CustomerType),
        CreditLimitH = p_CreditLimitH,
        IsActive     = COALESCE(p_IsActive, IsActive),
        UpdatedAtUtc = now() AT TIME ZONE 'utc',
        UpdatedBy    = p_Actor
    WHERE CustomerId = p_CustomerId;
END $$;
