/*==============================================================================
  Nazad POS — 020 · Launch QA fixes (28 Oct 2026)

  * sales.usp_CommitSale
      - locks the stock and customer rows it checks, so parallel sales can no
        longer oversell the last units (QA "oversell race") or take a customer
        over their credit limit together (N04);
      - refuses cash while the branch's drawer is closed (N10, 52050);
      - limits a line to 100,000 units (N08, 52008);
      - can post an offline sale the server refused, on a manager's authority
        (N20: p_ForcedByUserId / p_ForceReason).
  * sales.OfflineSaleIssue: offline sales the server refused at sync, kept
    for a manager to post anyway or record as refunded (N20).
  * Permission sales.resolve_offline, granted to owners and managers.
  * Price and cost limits on the catalog (N08).
  * core.usp_RefreshNotifications also raises open offline sale issues, for
    holders of sales.resolve_offline, until they are resolved.
==============================================================================*/

/*------------------------------------------------------- offline sale issues */

CREATE TABLE IF NOT EXISTS sales.OfflineSaleIssue (
    IssueId       varchar(40)  COLLATE ci NOT NULL CONSTRAINT PK_OfflineSaleIssue PRIMARY KEY,
    /* The device's own reference for the sale — also its idempotency key, so
       posting it later can never create a second invoice. */
    LocalId       varchar(64)  COLLATE ci NOT NULL CONSTRAINT UQ_OfflineSaleIssue_Local UNIQUE,
    BranchId      varchar(40)  COLLATE ci NOT NULL CONSTRAINT FK_OfflineSaleIssue_Branch REFERENCES core.Branch (BranchId),
    CashierUserId varchar(40)  COLLATE ci,
    CashierName   varchar(160) COLLATE ci NOT NULL,
    /* The sale exactly as the device sent it (the POST /api/sales body). */
    Request       jsonb        NOT NULL,
    TotalH        bigint       NOT NULL,
    ErrorCode     varchar(60)  COLLATE ci,
    ErrorMessage  varchar(600) COLLATE ci,
    /* When the customer paid, on the device's clock. */
    OccurredAtUtc timestamp(3) NOT NULL,
    CreatedAtUtc  timestamp(3) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    Status        varchar(20)  COLLATE ci NOT NULL DEFAULT 'open',
    SaleId        varchar(40)  COLLATE ci CONSTRAINT FK_OfflineSaleIssue_Sale REFERENCES sales.Sale (SaleId),
    InvoiceNumber varchar(40)  COLLATE ci,
    ResolvedBy    varchar(120) COLLATE ci,
    ResolvedAtUtc timestamp(3),
    Note          varchar(600) COLLATE ci,
    CONSTRAINT CK_OfflineSaleIssue_Status CHECK (Status IN ('open', 'posted', 'refunded'))
);

CREATE INDEX IF NOT EXISTS IX_OfflineSaleIssue_Open
    ON sales.OfflineSaleIssue (BranchId, CreatedAtUtc) WHERE Status = 'open';

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
VALUES ('sales.resolve_offline', 'sales', 'resolve_offline', 'financial')
ON CONFLICT (PermissionKey) DO NOTHING;

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT r.RoleId, 'sales.resolve_offline'
FROM core.Role AS r
WHERE r.RoleId IN ('rol_owner', 'rol_manager')
ON CONFLICT DO NOTHING;

/*------------------------------------------------------------ catalog limits */

/* No real item costs a million riyals; 90 trillion was a typo that the till
   would have charged. NOT VALID: checked for every new and changed row, without
   failing on a row an earlier version let in. Dropped first so the file can
   run again. */
ALTER TABLE core.CatalogItem
    DROP CONSTRAINT IF EXISTS CK_CatalogItem_PriceLimit,
    DROP CONSTRAINT IF EXISTS CK_CatalogItem_CostLimit,
    ADD CONSTRAINT CK_CatalogItem_PriceLimit CHECK (PriceH <= 100000000) NOT VALID,
    ADD CONSTRAINT CK_CatalogItem_CostLimit  CHECK (CostH  <= 100000000) NOT VALID;

/*------------------------------------------------------------- commit a sale */

/* New parameters make a new signature: drop the old one, or both would exist
   and a call naming only the old parameters would be ambiguous. */
DROP FUNCTION IF EXISTS sales.usp_CommitSale(
    text, text, text, text, text, bigint, bigint, text, jsonb, jsonb, text, text, text, text);

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
    p_OverrideReason   text DEFAULT NULL,
    /* A manager posting an offline sale the server refused at sync
       (sales.OfflineSaleIssue). The customer has already paid, so: stock may
       go below zero, the drawer is not required, and a price or discount that
       no longer matches is recorded as this manager's override with their
       reason. The API checks they hold sales.resolve_offline first. */
    p_ForcedByUserId   text DEFAULT NULL,
    p_ForceReason      text DEFAULT NULL)
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
    v_Forced          boolean := p_ForcedByUserId IS NOT NULL;

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

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l WHERE l.Quantity > 100000) THEN
        RAISE EXCEPTION 'A quantity cannot be more than 100,000.' USING DETAIL = '52008';
    END IF;

    /*
      Lock what this sale is about to change, before checking it.

      Two tills selling the last units at the same moment both read "8 in
      stock" and both sold 5; two credit sales both read the same balance and
      together went over the limit. Locked here, the second sale waits for the
      first to commit and then checks against what is really left. Rows are
      taken in item order so two sales never wait on each other in a circle.
    */
    PERFORM 1
    FROM inv.StockLevel AS s
    WHERE s.BranchId = p_BranchId
      AND s.ItemId IN (SELECT l.ItemId FROM unnest(v_Lines) AS l)
    ORDER BY s.ItemId
    FOR UPDATE;

    IF p_CustomerId IS NOT NULL THEN
        PERFORM 1 FROM core.Customer WHERE CustomerId = p_CustomerId FOR UPDATE;
    END IF;

    v_VatRate := COALESCE((SELECT VatRatePercent FROM core.BranchSettings WHERE BranchId = p_BranchId), 15.00);
    v_AllowNegative := COALESCE((SELECT AllowNegativeStock FROM core.BranchSettings WHERE BranchId = p_BranchId), false);

    /* Per item, so two lines of the same item cannot each pass on their own. */
    IF NOT v_AllowNegative AND NOT v_Forced AND EXISTS (
        SELECT 1
        FROM (SELECT l.ItemId, SUM(l.Quantity) AS Quantity
              FROM unnest(v_Lines) AS l GROUP BY l.ItemId) AS l
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

    /* A forced offline sale: the manager is the authority for whatever differs,
       and the sale records them and their reason even when only the stock or
       the drawer stood in the way. */
    IF v_Forced THEN
        v_OverrideBy := p_ForcedByUserId;
        v_OverrideReason := COALESCE(v_OverrideReason, NULLIF(trim(p_ForceReason), ''));
        v_Overridden := true;
    END IF;

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
    /* A forced sale keeps the discount it was sold with even if its rule has
       since ended: it is an override, handled by the branch below. */
    IF p_DiscountId IS NOT NULL AND NOT v_Forced THEN
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
    IF p_DiscountId IS NOT NULL AND v_Forced THEN
        v_ApprovedBy := p_ForcedByUserId;
    ELSIF p_DiscountId IS NOT NULL THEN
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

    /*
      Cash belongs to a shift.

      Cash taken while the drawer is closed is counted by no one: it is in no
      session's expected total, so a shortage in it can never be found. Card,
      bank and credit need no drawer. A forced offline sale is already paid;
      its cash is reconciled by the manager who posts it.
    */
    IF v_CashReceivedH > 0 AND NOT v_Forced AND NOT EXISTS (
        SELECT 1 FROM fin.DrawerSession
        WHERE (BranchId = p_BranchId OR BranchId IS NULL) AND ClosedAtUtc IS NULL)
    THEN
        RAISE EXCEPTION 'The cash drawer is closed. Open the drawer before taking cash.' USING DETAIL = '52050';
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

/*-------------------------------------------------------------- notifications */

/* As 014, plus open offline sale issues. */
CREATE OR REPLACE FUNCTION core.usp_RefreshNotifications(
    p_DrawerOpenHours integer DEFAULT 12,   -- a drawer open longer than this is flagged
    p_RecurringDays   integer DEFAULT 3)    -- how far ahead a recurring payment is "due"
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_Now   timestamp(3);
    v_Today date;
BEGIN
    /* Two requests refreshing at once would race to insert the same key. The
       second simply skips: the first is already doing its work. */
    IF NOT pg_try_advisory_xact_lock(hashtext('core.usp_RefreshNotifications')) THEN
        RETURN;
    END IF;

    v_Now := now() AT TIME ZONE 'utc';
    /* Due dates are business dates; Riyadh is UTC+3 all year. */
    v_Today := (v_Now + interval '3 hours')::date;

    IF to_regclass('pg_temp.Live') IS NOT NULL THEN DROP TABLE pg_temp.Live; END IF;

    CREATE TEMP TABLE Live
    (
        SourceKey     varchar(200) COLLATE ci NOT NULL PRIMARY KEY,
        Kind          varchar(40)  COLLATE ci NOT NULL,
        Severity      varchar(20)  COLLATE ci NOT NULL,
        BranchId      varchar(40)  COLLATE ci NULL,
        TitleAr       varchar(200) COLLATE ci NOT NULL,
        TitleEn       varchar(200) COLLATE ci NOT NULL,
        BodyAr        varchar(600) COLLATE ci NULL,
        BodyEn        varchar(600) COLLATE ci NULL,
        LinkPath      varchar(200) COLLATE ci NULL,
        PermissionKey varchar(80)  COLLATE ci NULL
    ) ON COMMIT DROP;

    /* Low and out of stock — only where the item is actually stocked (it has a
       stock row in that branch), so a branch that never carries an item is not
       told it has none. Quantities print as SQL Server's '0.###' did: no
       trailing zeros. */
    INSERT INTO Live
    SELECT 'low_stock:' || s.BranchId || ':' || i.ItemId,
           'low_stock',
           CASE WHEN s.Quantity <= 0 THEN 'danger' ELSE 'warning' END,
           s.BranchId,
           left(CASE WHEN s.Quantity <= 0
                     THEN 'نفد المخزون: ' || i.NameAr || ' (' || b.NameAr || ')'
                     ELSE 'مخزون منخفض: ' || i.NameAr || ' — ' ||
                          trim_scale(s.Quantity)::text || ' متبقٍ (' || b.NameAr || ')' END, 200),
           left(CASE WHEN s.Quantity <= 0
                     THEN 'Out of stock: ' || i.NameEn || ' (' || b.NameEn || ')'
                     ELSE 'Low stock: ' || i.NameEn || ' — ' ||
                          trim_scale(s.Quantity)::text || ' left (' || b.NameEn || ')' END, 200),
           'حد إعادة الطلب ' || i.ReorderLevel::text,
           'Reorder level ' || i.ReorderLevel::text,
           '/inventory',
           'inventory.view'
    FROM inv.StockLevel AS s
    JOIN core.CatalogItem AS i ON i.ItemId = s.ItemId
    JOIN core.Branch AS b ON b.BranchId = s.BranchId
    WHERE i.TracksStock AND i.IsActive AND b.IsActive
      AND (s.Quantity <= 0 OR (i.ReorderLevel > 0 AND s.Quantity <= i.ReorderLevel));

    /* Recurring payments due soon or overdue. The due date is in the key, so
       paying it (NextDueOn moves on) resolves this one and the next cycle
       raises its own. Amounts print as SQL Server's 'N2' did: 1,234.50. */
    INSERT INTO Live
    SELECT 'recurring:' || r.RecurringId || ':' || to_char(r.NextDueOn, 'YYYY-MM-DD'),
           'recurring_due',
           CASE WHEN r.NextDueOn < v_Today THEN 'danger' ELSE 'warning' END,
           r.BranchId,
           left(CASE WHEN r.NextDueOn < v_Today
                     THEN 'دفعة متأخرة: ' || r.DescriptionAr || ' — ' ||
                          to_char(r.AmountH / 100.0, 'FM999,999,999,999,990.00') || ' ر.س منذ ' ||
                          to_char(r.NextDueOn, 'YYYY-MM-DD')
                     ELSE 'دفعة مستحقة: ' || r.DescriptionAr || ' — ' ||
                          to_char(r.AmountH / 100.0, 'FM999,999,999,999,990.00') || ' ر.س في ' ||
                          to_char(r.NextDueOn, 'YYYY-MM-DD') END, 200),
           left(CASE WHEN r.NextDueOn < v_Today
                     THEN 'Overdue: ' || r.DescriptionEn || ' — SAR ' ||
                          to_char(r.AmountH / 100.0, 'FM999,999,999,999,990.00') || ' was due ' ||
                          to_char(r.NextDueOn, 'YYYY-MM-DD')
                     ELSE 'Due: ' || r.DescriptionEn || ' — SAR ' ||
                          to_char(r.AmountH / 100.0, 'FM999,999,999,999,990.00') || ' on ' ||
                          to_char(r.NextDueOn, 'YYYY-MM-DD') END, 200),
           NULL, NULL,
           '/finance/recurring',
           'finance.expenses'
    FROM fin.RecurringPayment AS r
    WHERE r.Status = 'active'
      AND r.NextDueOn <= v_Today + p_RecurringDays;

    /* Customers over their credit limit. A zero limit means "no credit
       arrangement", not "limit of zero", so it is not flagged here. */
    INSERT INTO Live
    SELECT 'credit:' || c.CustomerId,
           'credit_limit',
           'danger',
           NULL,
           left('تجاوز حد الائتمان: ' || c.NameAr || ' — ' ||
                to_char(c.BalanceH / 100.0, 'FM999,999,999,999,990.00') || ' من ' ||
                to_char(c.CreditLimitH / 100.0, 'FM999,999,999,999,990.00') || ' ر.س', 200),
           left('Over credit limit: ' || c.NameEn || ' — SAR ' ||
                to_char(c.BalanceH / 100.0, 'FM999,999,999,999,990.00') || ' of ' ||
                to_char(c.CreditLimitH / 100.0, 'FM999,999,999,999,990.00'), 200),
           NULL, NULL,
           '/finance/credit',
           'customers.view'
    FROM core.Customer AS c
    WHERE c.IsActive AND c.CreditLimitH > 0 AND c.BalanceH > c.CreditLimitH;

    /* A drawer left open past the threshold — usually a shift nobody closed,
       which leaves the day's cash uncounted. Hours are counted as DATEDIFF
       counted them: hour boundaries crossed. */
    INSERT INTO Live
    SELECT 'drawer:' || d.SessionId,
           'cash_drawer',
           'warning',
           d.BranchId,
           left('درج النقد مفتوح منذ ' ||
                (extract(epoch FROM date_trunc('hour', v_Now) - date_trunc('hour', d.OpenedAtUtc)) / 3600)::bigint ||
                ' ساعة' || COALESCE(' (' || b.NameAr || ')', '') || ' — فتحه ' || COALESCE(d.OpenedBy, ''), 200),
           left('Cash drawer open for ' ||
                (extract(epoch FROM date_trunc('hour', v_Now) - date_trunc('hour', d.OpenedAtUtc)) / 3600)::bigint ||
                ' hours' || COALESCE(' (' || b.NameEn || ')', '') || ' — opened by ' || COALESCE(d.OpenedBy, ''), 200),
           NULL, NULL,
           '/finance/cash',
           'finance.view'
    FROM fin.DrawerSession AS d
    LEFT JOIN core.Branch AS b ON b.BranchId = d.BranchId
    WHERE d.ClosedAtUtc IS NULL
      AND d.OpenedAtUtc < v_Now - make_interval(hours => p_DrawerOpenHours);

    /* Offline sales the server refused at sync (N20). The customer has paid
       and holds a receipt, but there is no invoice until a manager posts it or
       records the refund — so this stays up until they do. */
    INSERT INTO Live
    SELECT 'offline:' || o.IssueId,
           'offline_sale_failed',
           'danger',
           o.BranchId,
           left('بيع غير متصل لم يُسجَّل: ' ||
                to_char(o.TotalH / 100.0, 'FM999,999,999,999,990.00') || ' ر.س — ' ||
                o.CashierName || COALESCE(' (' || b.NameAr || ')', ''), 200),
           left('Offline sale not recorded: SAR ' ||
                to_char(o.TotalH / 100.0, 'FM999,999,999,999,990.00') || ' — ' ||
                o.CashierName || COALESCE(' (' || b.NameEn || ')', ''), 200),
           left(COALESCE(o.ErrorMessage, ''), 600),
           left(COALESCE(o.ErrorMessage, ''), 600),
           '/sales?offline=open',
           'sales.resolve_offline'
    FROM sales.OfflineSaleIssue AS o
    LEFT JOIN core.Branch AS b ON b.BranchId = o.BranchId
    WHERE o.Status = 'open';

    /* Conditions that cleared leave the bell. */
    UPDATE core.Notification AS n
    SET ResolvedAtUtc = v_Now
    WHERE n.SourceKey IS NOT NULL AND n.ResolvedAtUtc IS NULL
      AND NOT EXISTS (SELECT 1 FROM Live AS l WHERE l.SourceKey = n.SourceKey);

    /* Still open: keep the wording current (a quantity dropping further, low
       turning into out). Read state is left alone. */
    UPDATE core.Notification AS n
    SET Severity = l.Severity, TitleAr = l.TitleAr, TitleEn = l.TitleEn,
        BodyAr = l.BodyAr, BodyEn = l.BodyEn
    FROM Live AS l
    WHERE l.SourceKey = n.SourceKey
      AND n.ResolvedAtUtc IS NULL
      AND (n.Severity <> l.Severity OR n.TitleEn <> l.TitleEn OR n.TitleAr <> l.TitleAr);

    /* New conditions become new notifications. */
    INSERT INTO core.Notification
        (NotificationId, UserId, BranchId, Kind, Severity, TitleAr, TitleEn,
         BodyAr, BodyEn, LinkPath, SourceKey, PermissionKey, CreatedAtUtc)
    SELECT core.fn_NewId('ntf_'),
           NULL, l.BranchId, l.Kind, l.Severity, l.TitleAr, l.TitleEn,
           l.BodyAr, l.BodyEn, l.LinkPath, l.SourceKey, l.PermissionKey, v_Now
    FROM Live AS l
    WHERE NOT EXISTS (SELECT 1 FROM core.Notification AS n
                      WHERE n.SourceKey = l.SourceKey AND n.ResolvedAtUtc IS NULL);

    /* Resolved alerts are history nobody reads; a month is plenty. */
    DELETE FROM core.Notification
    WHERE ResolvedAtUtc IS NOT NULL AND ResolvedAtUtc < v_Now - interval '30 days';

    DROP TABLE Live;
END $$;
