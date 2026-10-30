/*==============================================================================
  Nazad POS — 013 · Finance functions (fin)

  The ledger, cash drawers, expenses, settlements, payroll, commission and
  balance periods. Conventions: README.md.
==============================================================================*/

/*------------------------------------------------------------ post an entry */

CREATE OR REPLACE FUNCTION fin.usp_PostJournalEntry(
    p_Kind            text,
    p_DescriptionEn   text,
    p_DescriptionAr   text DEFAULT NULL,
    p_SourceReference text DEFAULT NULL,
    p_BranchId        text DEFAULT NULL,
    p_Actor           text DEFAULT NULL,
    p_PostedAtUtc     timestamp DEFAULT NULL,
    p_Lines           jsonb DEFAULT '[]')
RETURNS TABLE (EntryId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Lines   fin.JournalLineTable[] :=
        ARRAY(SELECT jsonb_populate_recordset(NULL::fin.JournalLineTable, p_Lines));
    v_DebitH  bigint;
    v_CreditH bigint;
    v_Seq     bigint;
    v_EntryId varchar;
BEGIN
    SELECT SUM(l.DebitH)::bigint, SUM(l.CreditH)::bigint INTO v_DebitH, v_CreditH
    FROM unnest(v_Lines) AS l;

    IF v_DebitH IS NULL OR v_DebitH = 0 THEN
        RAISE EXCEPTION 'An entry needs at least one non-zero line.' USING DETAIL = '51000';
    END IF;

    IF v_DebitH <> v_CreditH THEN
        RAISE EXCEPTION 'Entry does not balance: debits and credits differ.' USING DETAIL = '51001';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l WHERE l.DebitH > 0 AND l.CreditH > 0) THEN
        RAISE EXCEPTION 'A line is either a debit or a credit, not both.' USING DETAIL = '51002';
    END IF;

    v_Seq := nextval('fin.JournalSequence');
    v_EntryId := 'jrn_' || lpad(v_Seq::text, 6, '0');

    INSERT INTO fin.JournalEntry
        (EntryId, Reference, Kind, SourceReference, DescriptionAr, DescriptionEn,
         PostedAtUtc, BranchId, Actor, TotalDebitH, TotalCreditH)
    VALUES
        (v_EntryId, 'JE-' || v_Seq, p_Kind, p_SourceReference,
         p_DescriptionAr, p_DescriptionEn,
         COALESCE(p_PostedAtUtc, now() AT TIME ZONE 'utc'), p_BranchId, p_Actor, v_DebitH, v_CreditH);

    INSERT INTO fin.JournalLine (EntryId, AccountCode, DebitH, CreditH, Memo)
    SELECT v_EntryId, l.AccountCode, l.DebitH, l.CreditH, l.Memo
    FROM unnest(v_Lines) AS l
    WHERE l.DebitH > 0 OR l.CreditH > 0;

    RETURN QUERY SELECT v_EntryId;
END $$;

/*
  Freeze commission for a sale.

  Resolves the most specific active rule per line and writes the amount. Called
  once, at the moment of sale; nothing recomputes it afterwards.
*/
CREATE OR REPLACE FUNCTION fin.usp_RecordSaleCommission(p_SaleId text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_UserId   varchar;
    v_Invoice  varchar;
    v_BranchId varchar;
BEGIN
    SELECT ServedByUserId, InvoiceNumber, BranchId INTO v_UserId, v_Invoice, v_BranchId
    FROM sales.Sale WHERE SaleId = p_SaleId;

    IF v_UserId IS NULL THEN RETURN; END IF;   -- nobody credited, nothing to earn

    WITH Resolved AS (
        SELECT
            sl.SaleLineId, sl.ItemId, sl.NameAr, sl.NameEn,
            /* Whole halalas, cut as SQL Server cut a decimal into BIGINT. */
            trunc((sl.UnitPriceH * sl.Quantity) - sl.LineDiscountH)::bigint AS LineGrossH,
            r.RuleId, r.Basis, r.Value,
            /* Named people beat "everyone"; named services beat "everything". */
            ROW_NUMBER() OVER (
                PARTITION BY sl.SaleLineId
                ORDER BY
                    (CASE WHEN EXISTS (SELECT 1 FROM fin.CommissionRuleUser ru
                                       WHERE ru.RuleId = r.RuleId) THEN 2 ELSE 0 END) +
                    (CASE WHEN EXISTS (SELECT 1 FROM fin.CommissionRuleItem ri
                                       WHERE ri.RuleId = r.RuleId) THEN 1 ELSE 0 END) DESC,
                    r.CreatedAtUtc DESC
            ) AS Rank
        FROM sales.SaleLine AS sl
        JOIN core.CatalogItem AS ci ON ci.ItemId = sl.ItemId
        CROSS JOIN fin.CommissionRule AS r
        WHERE sl.SaleId = p_SaleId
          AND ci.Kind = 'service'          -- commission is for work performed
          AND r.IsActive
          AND (NOT EXISTS (SELECT 1 FROM fin.CommissionRuleUser ru WHERE ru.RuleId = r.RuleId)
               OR EXISTS (SELECT 1 FROM fin.CommissionRuleUser ru
                          WHERE ru.RuleId = r.RuleId AND ru.UserId = v_UserId))
          AND (NOT EXISTS (SELECT 1 FROM fin.CommissionRuleItem ri WHERE ri.RuleId = r.RuleId)
               OR EXISTS (SELECT 1 FROM fin.CommissionRuleItem ri
                          WHERE ri.RuleId = r.RuleId AND ri.ItemId = sl.ItemId))
    ),
    Priced AS (
        SELECT Resolved.*,
               CASE WHEN Basis = 'percentage'
                    THEN round(LineGrossH * Value / 10000.0, 0)::bigint
                    ELSE Value
               END AS AmountH
        FROM Resolved
        WHERE Rank = 1
    )
    INSERT INTO fin.CommissionEntry
        (CommissionId, SaleId, InvoiceNumber, UserId, ItemId, ItemNameAr, ItemNameEn,
         LineGrossH, AmountH, Basis, RateAtSale, BranchId)
    SELECT
        core.fn_NewId('cme_'),
        p_SaleId, v_Invoice, v_UserId, ItemId, NameAr, NameEn,
        LineGrossH, AmountH, Basis, Value, v_BranchId
    FROM Priced
    WHERE AmountH > 0;
END $$;

/*--------------------------------------------------------------- cash drawer */

CREATE OR REPLACE FUNCTION fin.usp_OpenDrawer(
    p_BranchId     text,
    p_OpeningCashH bigint,
    p_OpenedBy     text)
RETURNS TABLE (SessionId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_SessionId varchar;
BEGIN
    IF p_OpeningCashH < 0 THEN
        RAISE EXCEPTION 'An opening float cannot be negative.' USING DETAIL = '55000';
    END IF;

    /* One open drawer per branch. Two would each claim the same movements and
       neither closing figure would mean anything. A filtered unique index
       enforces this as well; the check is here for the readable message. */
    IF EXISTS (SELECT 1 FROM fin.DrawerSession
               WHERE BranchId = p_BranchId AND ClosedAtUtc IS NULL) THEN
        RAISE EXCEPTION 'A drawer is already open at this branch.' USING DETAIL = '55001';
    END IF;

    v_SessionId := core.fn_NewId('drw_');

    INSERT INTO fin.DrawerSession
        (SessionId, BranchId, OpenedAtUtc, OpeningCashH, OpenedBy)
    VALUES
        (v_SessionId, p_BranchId, now() AT TIME ZONE 'utc', p_OpeningCashH, p_OpenedBy);

    RETURN QUERY SELECT v_SessionId;
END $$;

/*
  What should be in the drawer right now.

  Derived from the ledger on every call rather than stored: a saved expectation
  goes stale the moment anything posts behind it, and counting against a stale
  number invents a variance that is not there.

  Only cash moves the drawer. Card takings sit in clearing until the bank
  settles, and a credit sale never touches it — counting either would make every
  close look short by the day's card total.
*/
CREATE OR REPLACE FUNCTION fin.usp_DrawerExpectation(p_SessionId text)
RETURNS TABLE (
    OpeningCashH        bigint,
    CashSalesH          bigint,
    CashCollectionsH    bigint,
    OwnerContributionsH bigint,
    CashExpensesH       bigint,
    OwnerWithdrawalsH   bigint,
    CashRefundsH        bigint,
    ExpectedH           bigint)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_BranchId varchar;
    v_From     timestamp(3);
    v_To       timestamp(3);
    v_OpeningH bigint;
BEGIN
    SELECT s.BranchId, s.OpenedAtUtc, COALESCE(s.ClosedAtUtc, now() AT TIME ZONE 'utc'), s.OpeningCashH
    INTO v_BranchId, v_From, v_To, v_OpeningH
    FROM fin.DrawerSession AS s WHERE s.SessionId = p_SessionId;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Drawer session not found.' USING DETAIL = '55002';
    END IF;

    RETURN QUERY
    WITH CashLines AS (
        SELECT e.Kind, l.DebitH, l.CreditH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode = '1000'
          AND e.PostedAtUtc >= v_From AND e.PostedAtUtc <= v_To
          AND (e.BranchId = v_BranchId OR e.BranchId IS NULL)
    )
    SELECT
        v_OpeningH,
        COALESCE((SELECT SUM(c.DebitH)  FROM CashLines AS c WHERE c.Kind = 'sale'), 0)::bigint,
        COALESCE((SELECT SUM(c.DebitH)  FROM CashLines AS c WHERE c.Kind = 'customer_collection'), 0)::bigint,
        COALESCE((SELECT SUM(c.DebitH)  FROM CashLines AS c WHERE c.Kind = 'owner_contribution'), 0)::bigint,
        COALESCE((SELECT SUM(c.CreditH) FROM CashLines AS c WHERE c.Kind = 'expense'), 0)::bigint,
        COALESCE((SELECT SUM(c.CreditH) FROM CashLines AS c WHERE c.Kind = 'owner_withdrawal'), 0)::bigint,
        COALESCE((SELECT SUM(c.CreditH) FROM CashLines AS c WHERE c.Kind IN ('return', 'void')), 0)::bigint,
        (v_OpeningH
            + COALESCE((SELECT SUM(c.DebitH)  FROM CashLines AS c), 0)
            - COALESCE((SELECT SUM(c.CreditH) FROM CashLines AS c), 0))::bigint;
END $$;

/*
  Close the drawer.

  A variance posts as its own ledger entry rather than being absorbed. An
  unexplained forty riyals is a fact about the business, and quietly swallowing
  it is how a drawer problem survives for months.
*/
CREATE OR REPLACE FUNCTION fin.usp_CloseDrawer(
    p_SessionId    text,
    p_CountedCashH bigint,
    p_ClosedBy     text,
    p_Note         text DEFAULT NULL)
RETURNS TABLE (VarianceH bigint)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_BranchId  varchar;
    v_From      timestamp(3);
    v_OpeningH  bigint;
    v_Now       timestamp(3) := now() AT TIME ZONE 'utc';
    v_Movement  bigint;
    v_ExpectedH bigint;
    v_VarianceH bigint;
    v_Entry     fin.JournalLineTable[];
BEGIN
    IF p_CountedCashH < 0 THEN
        RAISE EXCEPTION 'A count cannot be negative.' USING DETAIL = '55003';
    END IF;

    SELECT s.BranchId, s.OpenedAtUtc, s.OpeningCashH INTO v_BranchId, v_From, v_OpeningH
    FROM fin.DrawerSession AS s
    WHERE s.SessionId = p_SessionId AND s.ClosedAtUtc IS NULL;

    IF v_From IS NULL THEN
        RAISE EXCEPTION 'That drawer session is not open.' USING DETAIL = '55004';
    END IF;

    v_Movement := COALESCE((
        SELECT SUM(l.DebitH - l.CreditH)
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode = '1000'
          AND e.PostedAtUtc >= v_From AND e.PostedAtUtc <= v_Now
          AND (e.BranchId = v_BranchId OR e.BranchId IS NULL)), 0)::bigint;

    v_ExpectedH := v_OpeningH + v_Movement;
    v_VarianceH := p_CountedCashH - v_ExpectedH;

    IF v_VarianceH <> 0 THEN
        IF v_VarianceH > 0 THEN
            v_Entry := ARRAY[
                ROW('1000', v_VarianceH, 0, 'Overage'),
                ROW('6000', 0, v_VarianceH, 'Drawer variance')
            ]::fin.JournalLineTable[];
        ELSE
            v_Entry := ARRAY[
                ROW('6000', abs(v_VarianceH), 0, 'Drawer variance'),
                ROW('1000', 0, abs(v_VarianceH), 'Shortage')
            ]::fin.JournalLineTable[];
        END IF;

        PERFORM fin.usp_PostJournalEntry(
            p_Kind            => 'manual',
            p_DescriptionEn   => 'Cash drawer variance',
            p_DescriptionAr   => 'فرق درج النقد',
            p_SourceReference => p_SessionId,
            p_BranchId        => v_BranchId,
            p_Actor           => p_ClosedBy,
            p_Lines           => to_jsonb(v_Entry));
    END IF;

    UPDATE fin.DrawerSession
    SET ClosedAtUtc   = v_Now,
        CountedCashH  = p_CountedCashH,
        ExpectedCashH = v_ExpectedH,
        VarianceH     = v_VarianceH,
        ClosedBy      = p_ClosedBy,
        Note          = p_Note
    WHERE SessionId = p_SessionId;

    RETURN QUERY SELECT v_VarianceH;
END $$;

/*
  Record what the bank actually deposited.

  The gap between takings and deposit is the network's fee, and it is a real
  cost. Recognising it here is why the clearing account returns to zero instead
  of drifting down by the fee every month.
*/
CREATE OR REPLACE FUNCTION fin.usp_RecordSettlement(
    p_CardSalesH bigint,
    p_DepositH   bigint,
    p_SettledOn  date,
    p_Actor      text,
    p_BranchId   text DEFAULT NULL,
    p_Note       text DEFAULT NULL)
RETURNS TABLE (SettlementId varchar, Reference varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_FeeH         bigint;
    v_Seq          bigint;
    v_SettlementId varchar;
    v_Reference    varchar;
    v_Entry        fin.JournalLineTable[];
BEGIN
    IF p_CardSalesH <= 0 THEN
        RAISE EXCEPTION 'Enter the card takings this batch covers.' USING DETAIL = '55010';
    END IF;
    IF p_DepositH < 0 THEN
        RAISE EXCEPTION 'A deposit cannot be negative.' USING DETAIL = '55011';
    END IF;
    IF p_DepositH > p_CardSalesH THEN
        RAISE EXCEPTION 'The deposit is more than the takings. Check the figures.' USING DETAIL = '55012';
    END IF;

    v_FeeH := p_CardSalesH - p_DepositH;

    v_Seq := nextval('fin.SettlementSequence');
    v_SettlementId := core.fn_NewId('set_');
    v_Reference    := 'SET-' || v_Seq;

    INSERT INTO fin.CardSettlement
        (SettlementId, Reference, BranchId, CardSalesH, DepositH, FeeH,
         SettledOn, Status, Note, CreatedBy)
    VALUES
        (v_SettlementId, v_Reference, p_BranchId, p_CardSalesH, p_DepositH, v_FeeH,
         p_SettledOn, 'reconciled', p_Note, p_Actor);

    v_Entry := ARRAY[
        ROW('1100', p_DepositH, 0, 'Bank deposit'),
        ROW('6100', v_FeeH, 0, 'Card fees'),
        ROW('1150', 0, p_CardSalesH, 'Card clearing')
    ]::fin.JournalLineTable[];

    PERFORM fin.usp_PostJournalEntry(
        p_Kind            => 'card_settlement',
        p_DescriptionEn   => 'Card settlement',
        p_DescriptionAr   => 'تسوية الشبكة',
        p_SourceReference => v_Reference,
        p_BranchId        => p_BranchId,
        p_Actor           => p_Actor,
        p_PostedAtUtc     => p_SettledOn::timestamp,
        p_Lines           => to_jsonb(v_Entry));

    RETURN QUERY SELECT v_SettlementId, v_Reference;
END $$;

/*------------------------------------------------------------- collections */

CREATE OR REPLACE FUNCTION fin.usp_RecordCustomerCollection(
    p_CustomerId text,
    p_AmountH    bigint,
    p_Method     text,
    p_Actor      text,
    p_Reference  text DEFAULT NULL,
    p_BranchId   text DEFAULT NULL)
RETURNS TABLE (EntryId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Balance bigint;
    v_Lines   fin.JournalLineTable[];
    v_EntryId varchar;
BEGIN
    IF p_AmountH <= 0 THEN
        RAISE EXCEPTION 'A collection must be above zero.' USING DETAIL = '52020';
    END IF;

    v_Balance := (SELECT c.BalanceH FROM core.Customer AS c WHERE c.CustomerId = p_CustomerId);

    IF v_Balance IS NULL THEN
        RAISE EXCEPTION 'Customer not found.' USING DETAIL = '52021';
    END IF;

    /* Collecting more than is owed would leave a negative balance, which reads
       as the business owing the customer — a different thing entirely. */
    IF p_AmountH > v_Balance THEN
        RAISE EXCEPTION 'That is more than this customer owes.' USING DETAIL = '52022';
    END IF;

    UPDATE core.Customer
    SET BalanceH = BalanceH - p_AmountH, UpdatedAtUtc = now() AT TIME ZONE 'utc'
    WHERE CustomerId = p_CustomerId;

    v_Lines := ARRAY[
        ROW(CASE WHEN p_Method COLLATE ci = 'cash' THEN '1000' ELSE '1100' END, p_AmountH, 0, p_Method),
        ROW('1400', 0, p_AmountH, 'Customer collection')
    ]::fin.JournalLineTable[];

    SELECT j.EntryId INTO v_EntryId
    FROM fin.usp_PostJournalEntry(
        p_Kind            => 'customer_collection',
        p_DescriptionEn   => 'Customer collection',
        p_DescriptionAr   => 'تحصيل من عميل',
        p_SourceReference => p_CustomerId,
        p_BranchId        => p_BranchId,
        p_Actor           => p_Actor,
        p_Lines           => to_jsonb(v_Lines)) AS j;

    RETURN QUERY SELECT v_EntryId;
END $$;

/*------------------------------------------------------- rebuild balances */

/* Reconcile the denormalised customer balance against everything the
   statement shows: credit sales, opening balances, collections (a reversal
   nets its collection out) and credit notes refunded to the account. */
CREATE OR REPLACE FUNCTION fin.usp_RebuildCustomerBalances()
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    WITH Charged AS (
        SELECT s.CustomerId, SUM(p.AmountH)::bigint AS AmountH
        FROM sales.Sale AS s
        JOIN sales.SalePayment AS p ON p.SaleId = s.SaleId AND p.Method = 'credit'
        WHERE s.CustomerId IS NOT NULL AND s.Status <> 'voided'
        GROUP BY s.CustomerId
    ),
    Posted AS (
        /* Opening balances raise it, collections lower it; reversal entries
           carry the same kind and source, so they cancel what they reverse. */
        SELECT e.SourceReference AS CustomerId, SUM(l.DebitH - l.CreditH)::bigint AS AmountH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId AND l.AccountCode = '1400'
        WHERE e.Kind IN ('customer_collection', 'customer_opening')
        GROUP BY e.SourceReference
    ),
    Credited AS (
        SELECT r.CustomerId, SUM(r.RefundH)::bigint AS AmountH
        FROM sales.SaleReturn AS r
        WHERE r.CustomerId IS NOT NULL AND r.RefundMethod = 'credit'
        GROUP BY r.CustomerId
    ),
    Rebuilt AS (
        SELECT c.CustomerId,
               COALESCE(ch.AmountH, 0) + COALESCE(po.AmountH, 0) - COALESCE(cr.AmountH, 0) AS BalanceH
        FROM core.Customer AS c
        LEFT JOIN Charged  AS ch ON ch.CustomerId = c.CustomerId
        LEFT JOIN Posted   AS po ON po.CustomerId = c.CustomerId
        LEFT JOIN Credited AS cr ON cr.CustomerId = c.CustomerId
    )
    UPDATE core.Customer AS c
    SET BalanceH = rb.BalanceH,
        UpdatedAtUtc = now() AT TIME ZONE 'utc'
    FROM Rebuilt AS rb
    WHERE rb.CustomerId = c.CustomerId;
END $$;

/*------------------------------------------------------------ reverse entry */

CREATE OR REPLACE FUNCTION fin.usp_ReverseJournalEntry(
    p_EntryId text,
    p_Reason  text,
    p_Actor   text)
RETURNS TABLE (NewEntryId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Flipped     fin.JournalLineTable[];
    v_Kind        varchar;
    v_Src         varchar;
    v_Branch      varchar;
    v_Ref         varchar;
    v_PostedAt    timestamp(3);
    v_Now         timestamp(3) := now() AT TIME ZONE 'utc';
    v_ReverseAt   timestamp(3);
    v_ReceivableH bigint;
    v_NewEntryId  varchar;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM fin.JournalEntry WHERE EntryId = p_EntryId) THEN
        RAISE EXCEPTION 'Journal entry not found.' USING DETAIL = '51010';
    END IF;

    IF EXISTS (SELECT 1 FROM fin.JournalEntry
               WHERE EntryId = p_EntryId AND ReversedByEntryId IS NOT NULL) THEN
        RAISE EXCEPTION 'This entry has already been reversed.' USING DETAIL = '51011';
    END IF;

    IF trim(COALESCE(p_Reason, '')) = '' THEN
        RAISE EXCEPTION 'A reversal needs a reason on the record.' USING DETAIL = '51012';
    END IF;

    v_Flipped := ARRAY(
        SELECT ROW(l.AccountCode, l.CreditH, l.DebitH, l.Memo)::fin.JournalLineTable
        FROM fin.JournalLine AS l WHERE l.EntryId = p_EntryId
        ORDER BY l.JournalLineId);

    SELECT e.Kind, e.SourceReference, e.BranchId, e.Reference, e.PostedAtUtc
    INTO v_Kind, v_Src, v_Branch, v_Ref, v_PostedAt
    FROM fin.JournalEntry AS e WHERE e.EntryId = p_EntryId;

    /* Never earlier than the original: a future month's release is cancelled
       in that month, a past entry is reversed today. */
    v_ReverseAt := CASE WHEN v_PostedAt > v_Now THEN v_PostedAt ELSE v_Now END;

    /* What the entry did to a customer's receivable, for the balance below. */
    v_ReceivableH :=
        CASE WHEN v_Kind IN ('customer_collection', 'customer_opening')
             THEN COALESCE((SELECT SUM(l.DebitH - l.CreditH) FROM fin.JournalLine AS l
                            WHERE l.EntryId = p_EntryId AND l.AccountCode = '1400'), 0)::bigint
             ELSE 0 END;

    SELECT j.EntryId INTO v_NewEntryId
    FROM fin.usp_PostJournalEntry(
        p_Kind            => v_Kind,
        p_DescriptionEn   => p_Reason,
        p_SourceReference => v_Src,
        p_BranchId        => v_Branch,
        p_Actor           => p_Actor,
        p_PostedAtUtc     => v_ReverseAt,
        p_Lines           => to_jsonb(v_Flipped)) AS j;

    UPDATE fin.JournalEntry
    SET ReversesEntryId = p_EntryId,
        ReversalReason  = p_Reason,
        DescriptionEn   = 'Reversal of ' || v_Ref || ' — ' || p_Reason
    WHERE EntryId = v_NewEntryId;

    UPDATE fin.JournalEntry
    SET ReversedByEntryId = v_NewEntryId
    WHERE EntryId = p_EntryId;

    /* A collection lowered the customer's balance and an opening balance
       raised it; undoing the entry undoes that too. The source reference
       of both is the customer id. */
    IF v_ReceivableH <> 0 THEN
        UPDATE core.Customer
        SET BalanceH = BalanceH - v_ReceivableH, UpdatedAtUtc = v_Now, UpdatedBy = p_Actor
        WHERE CustomerId = v_Src;
    END IF;

    RETURN QUERY SELECT v_NewEntryId;
END $$;

/*-------------------------------------------------------- opening balances */

CREATE OR REPLACE FUNCTION fin.usp_PostOpeningBalances(
    p_AsOf         date,
    p_Actor        text,
    p_BranchId     text DEFAULT NULL,
    p_CashH        bigint DEFAULT 0,
    p_BankH        bigint DEFAULT 0,
    p_InventoryH   bigint DEFAULT 0,
    p_ReceivablesH bigint DEFAULT 0,
    p_PayablesH    bigint DEFAULT 0,
    p_VatH         bigint DEFAULT 0,
    p_Note         text DEFAULT NULL)
RETURNS TABLE (OpeningId varchar, EntryId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_AssetsH      bigint;
    v_LiabilitiesH bigint;
    v_EquityH      bigint;
    v_Entry        fin.JournalLineTable[];
    v_EntryId      varchar;
    v_OpeningId    varchar;
BEGIN
    IF p_AsOf IS NULL THEN
        RAISE EXCEPTION 'Choose the date the balances are as of.' USING DETAIL = '70001';
    END IF;

    IF p_CashH < 0 OR p_BankH < 0 OR p_InventoryH < 0 OR p_ReceivablesH < 0 OR p_PayablesH < 0 THEN
        RAISE EXCEPTION 'Opening balances cannot be negative.' USING DETAIL = '70002';
    END IF;

    IF p_BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = p_BranchId) THEN
        RAISE EXCEPTION 'Unknown branch.' USING DETAIL = '70003';
    END IF;

    v_AssetsH      := COALESCE(p_CashH, 0) + COALESCE(p_BankH, 0) + COALESCE(p_InventoryH, 0) + COALESCE(p_ReceivablesH, 0)
                      + CASE WHEN p_VatH < 0 THEN -p_VatH ELSE 0 END;
    v_LiabilitiesH := COALESCE(p_PayablesH, 0) + CASE WHEN p_VatH > 0 THEN p_VatH ELSE 0 END;
    v_EquityH      := v_AssetsH - v_LiabilitiesH;

    IF v_AssetsH = 0 AND v_LiabilitiesH = 0 THEN
        RAISE EXCEPTION 'Enter at least one opening figure.' USING DETAIL = '70004';
    END IF;

    /* One standing posting per scope. There are no range locks to stop two at
       once, so the check runs under a transaction-scoped lock. */
    PERFORM pg_advisory_xact_lock(hashtext('fin.OpeningBalance'));

    IF EXISTS (SELECT 1
               FROM fin.OpeningBalance AS o
               JOIN fin.JournalEntry AS e ON e.EntryId = o.EntryId
               WHERE COALESCE(o.BranchId, '') = COALESCE(p_BranchId, '')
                 AND e.ReversedByEntryId IS NULL) THEN
        RAISE EXCEPTION 'Opening balances have already been posted. Reverse the entry in the ledger to correct them.' USING DETAIL = '70000';
    END IF;

    v_Entry := ARRAY[
        ROW('1000', p_CashH, 0, 'Opening cash'),
        ROW('1100', p_BankH, 0, 'Opening bank'),
        ROW('1200', p_InventoryH, 0, 'Opening inventory'),
        ROW('1400', p_ReceivablesH, 0, 'Opening receivables'),
        ROW('2000', 0, p_PayablesH, 'Opening payables'),
        ROW('2100', 0, CASE WHEN p_VatH > 0 THEN p_VatH ELSE 0 END, 'Opening VAT owed'),
        ROW('1300', CASE WHEN p_VatH < 0 THEN -p_VatH ELSE 0 END, 0, 'Opening VAT reclaimable'),
        ROW('3900', CASE WHEN v_EquityH < 0 THEN -v_EquityH ELSE 0 END,
                    CASE WHEN v_EquityH > 0 THEN v_EquityH ELSE 0 END, 'Opening equity')
    ]::fin.JournalLineTable[];

    SELECT j.EntryId INTO v_EntryId
    FROM fin.usp_PostJournalEntry(
        p_Kind            => 'opening_balance',
        p_DescriptionEn   => 'Opening balances',
        p_DescriptionAr   => 'الأرصدة الافتتاحية',
        p_SourceReference => 'OPENING',
        p_BranchId        => p_BranchId,
        p_Actor           => p_Actor,
        p_PostedAtUtc     => p_AsOf::timestamp,
        p_Lines           => to_jsonb(v_Entry)) AS j;

    v_OpeningId := 'opn_' || left(replace(gen_random_uuid()::text, '-', ''), 20);

    INSERT INTO fin.OpeningBalance
        (OpeningId, BranchId, AsOf, CashH, BankH, InventoryH, ReceivablesH, PayablesH,
         VatH, EquityH, EntryId, Note, PostedBy)
    VALUES
        (v_OpeningId, p_BranchId, p_AsOf, p_CashH, p_BankH, p_InventoryH, p_ReceivablesH, p_PayablesH,
         p_VatH, v_EquityH, v_EntryId, NULLIF(trim(p_Note), ''), p_Actor);

    RETURN QUERY SELECT v_OpeningId, v_EntryId;
END $$;

/*------------------------------------------------------------ balance periods */

/*
  Open a period and post the starting position.

  Modelled as a period rather than a single opening snapshot because the
  question an owner asks is not "what did I start with" but "what did I start
  with, what did I end with, and where did the difference go".
*/
CREATE OR REPLACE FUNCTION fin.usp_OpenBalancePeriod(
    p_BranchId          text,
    p_Label             text,
    p_OpenedOn          date,
    p_OpenedBy          text,
    p_OpeningCashH      bigint DEFAULT 0,
    p_OpeningCardH      bigint DEFAULT 0,
    p_OpeningCreditH    bigint DEFAULT 0,
    p_OpeningBankH      bigint DEFAULT 0,
    p_OpeningInventoryH bigint DEFAULT 0,
    p_OpeningPayablesH  bigint DEFAULT 0,
    p_Note              text DEFAULT NULL)
RETURNS TABLE (PeriodId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_PeriodId varchar;
    v_EquityH  bigint;
    v_Entry    fin.JournalLineTable[];
BEGIN
    /* One open period per branch. Two overlapping periods would each claim the
       same movements and neither closing figure would mean anything. */
    IF EXISTS (SELECT 1 FROM fin.BalancePeriod
               WHERE BranchId = p_BranchId AND Status = 'open') THEN
        RAISE EXCEPTION 'This branch already has an open period.' USING DETAIL = '56000';
    END IF;

    IF p_OpeningCashH < 0 OR p_OpeningCardH < 0 OR p_OpeningCreditH < 0
       OR p_OpeningBankH < 0 OR p_OpeningInventoryH < 0 OR p_OpeningPayablesH < 0 THEN
        RAISE EXCEPTION 'Opening balances cannot be negative.' USING DETAIL = '56001';
    END IF;

    v_PeriodId := core.fn_NewId('bpd_');

    INSERT INTO fin.BalancePeriod
        (PeriodId, BranchId, Label, OpenedOn,
         OpeningCashH, OpeningCardH, OpeningCreditH,
         OpeningBankH, OpeningInventoryH, OpeningPayablesH,
         Status, OpenedBy, Note)
    VALUES
        (v_PeriodId, p_BranchId, p_Label, p_OpenedOn,
         p_OpeningCashH, p_OpeningCardH, p_OpeningCreditH,
         p_OpeningBankH, p_OpeningInventoryH, p_OpeningPayablesH,
         'open', p_OpenedBy, p_Note);

    /* Net worth of the position: what is held, less what is owed. Whatever
       does not net out goes to suspense so the entry balances without
       asking the owner to state their capital. */
    v_EquityH :=
        p_OpeningCashH + p_OpeningCardH + p_OpeningCreditH
        + p_OpeningBankH + p_OpeningInventoryH - p_OpeningPayablesH;

    v_Entry := ARRAY[
        ROW('1000', p_OpeningCashH, 0, 'Opening cash'),
        ROW('1150', p_OpeningCardH, 0, 'Opening card clearing'),
        ROW('1400', p_OpeningCreditH, 0, 'Opening receivables'),
        ROW('1100', p_OpeningBankH, 0, 'Opening bank'),
        ROW('1200', p_OpeningInventoryH, 0, 'Opening inventory'),
        ROW('2000', 0, p_OpeningPayablesH, 'Opening payables')
    ]::fin.JournalLineTable[];

    IF v_EquityH >= 0 THEN
        v_Entry := v_Entry || ROW('3900', 0, v_EquityH, 'Opening equity')::fin.JournalLineTable;
    ELSE
        v_Entry := v_Entry || ROW('3900', abs(v_EquityH), 0, 'Opening equity')::fin.JournalLineTable;
    END IF;

    PERFORM fin.usp_PostJournalEntry(
        p_Kind            => 'opening_balance',
        p_DescriptionEn   => p_Label,
        p_DescriptionAr   => p_Label,
        p_SourceReference => v_PeriodId,
        p_BranchId        => p_BranchId,
        p_Actor           => p_OpenedBy,
        p_PostedAtUtc     => p_OpenedOn::timestamp,
        p_Lines           => to_jsonb(v_Entry));

    RETURN QUERY SELECT v_PeriodId;
END $$;

/* What the ledger says the position should be, per method. */
CREATE OR REPLACE FUNCTION fin.usp_BalancePeriodExpectation(p_PeriodId text)
RETURNS TABLE (
    CashH      bigint,
    CardH      bigint,
    CreditH    bigint,
    BankH      bigint,
    InventoryH bigint,
    PayablesH  bigint)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_BranchId varchar;
    v_From     date;
    v_To       date;
BEGIN
    SELECT p.BranchId, p.OpenedOn, COALESCE(p.ClosedOn, (now() AT TIME ZONE 'utc')::date)
    INTO v_BranchId, v_From, v_To
    FROM fin.BalancePeriod AS p WHERE p.PeriodId = p_PeriodId;

    IF v_From IS NULL THEN
        RAISE EXCEPTION 'Balance period not found.' USING DETAIL = '56002';
    END IF;

    RETURN QUERY
    WITH Lines AS (
        SELECT l.AccountCode, l.DebitH, l.CreditH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE e.PostedAtUtc::date >= v_From
          AND e.PostedAtUtc::date <= v_To
          AND (e.BranchId = v_BranchId OR e.BranchId IS NULL)
    )
    SELECT
        COALESCE((SELECT SUM(x.DebitH - x.CreditH) FROM Lines AS x WHERE x.AccountCode = '1000'), 0)::bigint,
        COALESCE((SELECT SUM(x.DebitH - x.CreditH) FROM Lines AS x WHERE x.AccountCode = '1150'), 0)::bigint,
        COALESCE((SELECT SUM(x.DebitH - x.CreditH) FROM Lines AS x WHERE x.AccountCode = '1400'), 0)::bigint,
        COALESCE((SELECT SUM(x.DebitH - x.CreditH) FROM Lines AS x WHERE x.AccountCode = '1100'), 0)::bigint,
        COALESCE((SELECT SUM(x.DebitH - x.CreditH) FROM Lines AS x WHERE x.AccountCode = '1200'), 0)::bigint,
        /* Payables is credit-normal, so flip it to read as a positive debt. */
        COALESCE((SELECT SUM(x.CreditH - x.DebitH) FROM Lines AS x WHERE x.AccountCode = '2000'), 0)::bigint;
END $$;

CREATE OR REPLACE FUNCTION fin.usp_CloseBalancePeriod(
    p_PeriodId          text,
    p_ClosedOn          date,
    p_ClosingCashH      bigint,
    p_ClosingCardH      bigint,
    p_ClosingCreditH    bigint,
    p_ClosingBankH      bigint,
    p_ClosingInventoryH bigint,
    p_ClosingPayablesH  bigint,
    p_ClosedBy          text,
    p_Note              text DEFAULT NULL)
RETURNS TABLE (VarianceH bigint)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_BranchId  varchar;
    v_From      date;
    v_ExpectedH bigint;
    v_CountedH  bigint;
    v_VarianceH bigint;
    v_Entry     fin.JournalLineTable[];
BEGIN
    SELECT p.BranchId, p.OpenedOn INTO v_BranchId, v_From
    FROM fin.BalancePeriod AS p WHERE p.PeriodId = p_PeriodId AND p.Status = 'open';

    IF v_From IS NULL THEN
        RAISE EXCEPTION 'That period is not open.' USING DETAIL = '56003';
    END IF;
    IF p_ClosedOn < v_From THEN
        RAISE EXCEPTION 'The closing date is before the period opened.' USING DETAIL = '56004';
    END IF;

    v_ExpectedH := COALESCE((
        SELECT SUM(CASE WHEN l.AccountCode = '2000' THEN -(l.CreditH - l.DebitH)
                        ELSE l.DebitH - l.CreditH END)
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode IN ('1000', '1150', '1400', '1100', '1200', '2000')
          AND e.PostedAtUtc::date >= v_From
          AND e.PostedAtUtc::date <= p_ClosedOn
          AND (e.BranchId = v_BranchId OR e.BranchId IS NULL)), 0)::bigint;

    v_CountedH :=
        p_ClosingCashH + p_ClosingCardH + p_ClosingCreditH
        + p_ClosingBankH + p_ClosingInventoryH - p_ClosingPayablesH;

    v_VarianceH := v_CountedH - v_ExpectedH;

    /* Any gap posts as its own entry rather than being absorbed. */
    IF v_VarianceH <> 0 THEN
        IF v_VarianceH > 0 THEN
            v_Entry := ARRAY[
                ROW('1000', v_VarianceH, 0, 'Closing overage'),
                ROW('6000', 0, v_VarianceH, 'Closing variance')
            ]::fin.JournalLineTable[];
        ELSE
            v_Entry := ARRAY[
                ROW('6000', abs(v_VarianceH), 0, 'Closing variance'),
                ROW('1000', 0, abs(v_VarianceH), 'Closing shortage')
            ]::fin.JournalLineTable[];
        END IF;

        PERFORM fin.usp_PostJournalEntry(
            p_Kind            => 'manual',
            p_DescriptionEn   => 'Period closing variance',
            p_DescriptionAr   => 'فرق إقفال الفترة',
            p_SourceReference => p_PeriodId,
            p_BranchId        => v_BranchId,
            p_Actor           => p_ClosedBy,
            p_PostedAtUtc     => p_ClosedOn::timestamp,
            p_Lines           => to_jsonb(v_Entry));
    END IF;

    UPDATE fin.BalancePeriod
    SET Status            = 'closed',
        ClosedOn          = p_ClosedOn,
        ClosingCashH      = p_ClosingCashH,
        ClosingCardH      = p_ClosingCardH,
        ClosingCreditH    = p_ClosingCreditH,
        ClosingBankH      = p_ClosingBankH,
        ClosingInventoryH = p_ClosingInventoryH,
        ClosingPayablesH  = p_ClosingPayablesH,
        ClosedBy          = p_ClosedBy,
        Note              = COALESCE(p_Note, Note),
        UpdatedAtUtc      = now() AT TIME ZONE 'utc'
    WHERE PeriodId = p_PeriodId;

    RETURN QUERY SELECT v_VarianceH;
END $$;

/*--------------------------------------------------------- commission rules */

CREATE OR REPLACE FUNCTION fin.usp_SaveCommissionRule(
    p_Basis    text,                 -- percentage | fixed
    p_Value    integer,
    p_RuleId   text DEFAULT NULL,    -- null creates
    p_UserIds  text DEFAULT NULL,    -- comma separated; empty: everyone without their own rule
    p_ItemIds  text DEFAULT NULL,    -- comma separated; empty: every service
    p_IsActive boolean DEFAULT true)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Users   varchar[];
    v_Items   varchar[];
    v_SavedId varchar;
BEGIN
    IF p_Basis COLLATE ci NOT IN ('percentage', 'fixed') THEN
        RAISE EXCEPTION 'Commission is a percentage or a fixed amount.' USING DETAIL = '64000';
    END IF;

    IF COALESCE(p_Value, 0) <= 0 THEN
        RAISE EXCEPTION 'Enter a value above zero.' USING DETAIL = '64001';
    END IF;

    /* A percentage above 100 pays out more than the sale brought in. */
    IF p_Basis COLLATE ci = 'percentage' AND p_Value > 10000 THEN
        RAISE EXCEPTION 'A commission cannot exceed 100%%.' USING DETAIL = '64002';
    END IF;

    IF p_RuleId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.CommissionRule WHERE RuleId = p_RuleId) THEN
        RAISE EXCEPTION 'No such commission rule.' USING DETAIL = '64005';
    END IF;

    /* Distinct ignoring case, as the keys they go into do. */
    v_Users := ARRAY(
        SELECT DISTINCT trim(x)::varchar COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_UserIds, ''), ',')) AS x
        WHERE trim(x) <> '');

    IF EXISTS (SELECT 1 FROM unnest(v_Users) AS u(UserId)
               WHERE NOT EXISTS (SELECT 1 FROM core.AppUser AS a WHERE a.UserId = u.UserId)) THEN
        RAISE EXCEPTION 'One of those people does not exist.' USING DETAIL = '64003';
    END IF;

    v_Items := ARRAY(
        SELECT DISTINCT trim(x)::varchar COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_ItemIds, ''), ',')) AS x
        WHERE trim(x) <> '');

    /* Commission is earned on work performed. usp_RecordSaleCommission only
       ever looks at service lines, so a product here would be a rule that
       silently never pays. */
    IF EXISTS (SELECT 1 FROM unnest(v_Items) AS i(ItemId)
               WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem AS c
                                 WHERE c.ItemId = i.ItemId AND c.Kind = 'service')) THEN
        RAISE EXCEPTION 'Commission rules cover services only, and one of those is not a service.' USING DETAIL = '64004';
    END IF;

    IF p_RuleId IS NULL THEN
        v_SavedId := core.fn_NewId('crl_');

        INSERT INTO fin.CommissionRule (RuleId, Basis, Value, IsActive)
        VALUES (v_SavedId, p_Basis, p_Value, p_IsActive);
    ELSE
        v_SavedId := p_RuleId;

        /*
          Editing a rule does not change commission already earned.

          fin.CommissionEntry records the amount at the moment of each sale,
          so past entries keep the rate that applied then. Recalculating them
          would rewrite what someone was told they had earned.
        */
        UPDATE fin.CommissionRule
        SET Basis = p_Basis, Value = p_Value, IsActive = p_IsActive,
            UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE RuleId = p_RuleId;
    END IF;

    DELETE FROM fin.CommissionRuleUser WHERE RuleId = v_SavedId;
    INSERT INTO fin.CommissionRuleUser (RuleId, UserId) SELECT v_SavedId, u FROM unnest(v_Users) AS u;

    DELETE FROM fin.CommissionRuleItem WHERE RuleId = v_SavedId;
    INSERT INTO fin.CommissionRuleItem (RuleId, ItemId) SELECT v_SavedId, i FROM unnest(v_Items) AS i;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*
  A real delete.

  Commission already earned does not point back at its rule — each entry froze
  its basis and rate at the moment of sale — so removing a rule changes future
  sales only, which is what removing it means. The user and item sets cascade.
*/
CREATE OR REPLACE FUNCTION fin.usp_DeleteCommissionRule(p_RuleId text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM fin.CommissionRule WHERE RuleId = p_RuleId;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such commission rule.' USING DETAIL = '64005';
    END IF;
END $$;

/*------------------------------------------------------------------ payroll */

/*
  Build a draft for a period.

  Commission comes from what was frozen at each sale, never recalculated —
  which is the entire reason it was frozen.
*/
CREATE OR REPLACE FUNCTION fin.usp_DraftPayroll(
    p_PeriodMonth text,
    p_Actor       text,
    p_BranchId    text DEFAULT NULL)
RETURNS TABLE (RunId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Seq   bigint;
    v_RunId varchar;
BEGIN
    IF EXISTS (SELECT 1 FROM fin.PayrollRun
               WHERE PeriodMonth = p_PeriodMonth
                 AND COALESCE(BranchId, '') = COALESCE(p_BranchId, '')
                 AND Status = 'paid') THEN
        RAISE EXCEPTION 'Payroll for this period has already been paid.' USING DETAIL = '56010';
    END IF;

    DELETE FROM fin.PayrollRun
    WHERE PeriodMonth = p_PeriodMonth
      AND COALESCE(BranchId, '') = COALESCE(p_BranchId, '')
      AND Status = 'draft';

    v_Seq := nextval('fin.PayrollSequence');
    v_RunId := core.fn_NewId('pay_');

    INSERT INTO fin.PayrollRun
        (RunId, Reference, PeriodMonth, BranchId, Status, TotalH, CreatedBy)
    VALUES
        (v_RunId, 'PR-' || v_Seq, p_PeriodMonth, p_BranchId, 'draft', 0, p_Actor);

    INSERT INTO fin.PayrollLine (RunId, UserId, BaseSalaryH, CommissionH, AllowancesH, DeductionsH)
    SELECT
        v_RunId,
        u.UserId,
        u.BaseSalaryH,
        COALESCE(c.EarnedH, 0),
        0,
        0
    FROM core.AppUser AS u
    LEFT JOIN (
        SELECT ce.UserId, SUM(ce.AmountH)::bigint AS EarnedH
        FROM fin.CommissionEntry AS ce
        WHERE ce.PayrollRunId IS NULL
          AND to_char(ce.EarnedAtUtc, 'YYYY-MM') = p_PeriodMonth
        GROUP BY ce.UserId
    ) AS c ON c.UserId = u.UserId
    WHERE u.Status = 'active'
      AND NOT u.IsExternal
      AND (p_BranchId IS NULL
           OR EXISTS (SELECT 1 FROM core.UserBranch AS ub
                      WHERE ub.UserId = u.UserId AND ub.BranchId = p_BranchId));

    UPDATE fin.PayrollRun AS r
    SET TotalH = COALESCE((SELECT SUM(l.NetPayH) FROM fin.PayrollLine AS l WHERE l.RunId = v_RunId), 0)::bigint
    WHERE r.RunId = v_RunId;

    RETURN QUERY SELECT v_RunId;
END $$;

CREATE OR REPLACE FUNCTION fin.usp_PayPayroll(
    p_RunId  text,
    p_PaidOn date,
    p_Actor  text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_Status      varchar;
    v_PeriodMonth varchar;
    v_BranchId    varchar;
    v_Reference   varchar;
    v_SalariesH   bigint;
    v_CommissionH bigint;
    v_DeductionsH bigint;
    v_NetH        bigint;
    v_Entry       fin.JournalLineTable[];
BEGIN
    SELECT r.Status, r.PeriodMonth, r.BranchId, r.Reference
    INTO v_Status, v_PeriodMonth, v_BranchId, v_Reference
    FROM fin.PayrollRun AS r WHERE r.RunId = p_RunId;

    IF v_Status IS NULL THEN
        RAISE EXCEPTION 'Payroll run not found.' USING DETAIL = '56011';
    END IF;
    IF v_Status COLLATE ci = 'paid' THEN
        RAISE EXCEPTION 'This payroll has already been paid.' USING DETAIL = '56012';
    END IF;

    SELECT COALESCE(SUM(l.BaseSalaryH + l.AllowancesH), 0)::bigint,
           COALESCE(SUM(l.CommissionH), 0)::bigint,
           COALESCE(SUM(l.DeductionsH), 0)::bigint,
           COALESCE(SUM(l.NetPayH), 0)::bigint
    INTO v_SalariesH, v_CommissionH, v_DeductionsH, v_NetH
    FROM fin.PayrollLine AS l WHERE l.RunId = p_RunId;

    IF v_NetH <= 0 THEN
        RAISE EXCEPTION 'There is nothing to pay for this period.' USING DETAIL = '56013';
    END IF;

    /* Deductions credit the expense back rather than being netted off the
       salary line, so the expense reflects what was earned and the cash
       reflects what was actually paid. */
    v_Entry := ARRAY[
        ROW('6200', v_SalariesH, 0, 'Salaries'),
        ROW('6300', v_CommissionH, 0, 'Commission'),
        ROW('6200', 0, v_DeductionsH, 'Deductions'),
        ROW('1100', 0, v_NetH, 'Paid from bank')
    ]::fin.JournalLineTable[];

    PERFORM fin.usp_PostJournalEntry(
        p_Kind            => 'payroll',
        p_DescriptionEn   => v_Reference,
        p_DescriptionAr   => v_Reference,
        p_SourceReference => v_Reference,
        p_BranchId        => v_BranchId,
        p_Actor           => p_Actor,
        p_PostedAtUtc     => p_PaidOn::timestamp,
        p_Lines           => to_jsonb(v_Entry));

    /* Claim the commission this run settles, so it stops showing as owed. */
    UPDATE fin.CommissionEntry
    SET PayrollRunId = p_RunId
    WHERE PayrollRunId IS NULL
      AND to_char(EarnedAtUtc, 'YYYY-MM') = v_PeriodMonth;

    UPDATE fin.PayrollRun
    SET Status = 'paid', PaidOn = p_PaidOn, TotalH = v_NetH,
        UpdatedAtUtc = now() AT TIME ZONE 'utc', UpdatedBy = p_Actor
    WHERE RunId = p_RunId;
END $$;

/*-------------------------------------------------------- expense categories */

CREATE OR REPLACE FUNCTION fin.usp_SaveExpenseCategory(
    p_NameAr      text,
    p_NameEn      text,
    p_AccountCode text,
    p_Actor       text,
    p_CategoryId  text DEFAULT NULL,      -- null creates
    p_IsActive    boolean DEFAULT NULL)   -- null keeps (active on create)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_NameAr  varchar := NULLIF(trim(p_NameAr), '');
    v_NameEn  varchar := NULLIF(trim(p_NameEn), '');
    v_SavedId varchar;
BEGIN
    IF v_NameAr IS NULL OR v_NameEn IS NULL THEN
        RAISE EXCEPTION 'Both names are required.' USING DETAIL = '69000';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM fin.Account
                   WHERE AccountCode = p_AccountCode AND AccountType = 'expense'
                     AND IsActive AND AccountCode <> '5100') THEN
        RAISE EXCEPTION 'Choose an expense account.' USING DETAIL = '69001';
    END IF;

    IF EXISTS (SELECT 1 FROM fin.ExpenseCategory
               WHERE NameEn = v_NameEn AND (p_CategoryId IS NULL OR CategoryId <> p_CategoryId)) THEN
        RAISE EXCEPTION 'Another category already uses this name.' USING DETAIL = '69002';
    END IF;

    IF p_CategoryId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.ExpenseCategory WHERE CategoryId = p_CategoryId) THEN
        RAISE EXCEPTION 'Expense category not found.' USING DETAIL = '69003';
    END IF;

    /* An active schedule would keep posting into a category nobody can pick. */
    IF p_CategoryId IS NOT NULL AND p_IsActive = false
       AND EXISTS (SELECT 1 FROM fin.RecurringPayment WHERE CategoryId = p_CategoryId AND Status = 'active') THEN
        RAISE EXCEPTION 'Active recurring payments still use this category.' USING DETAIL = '69004';
    END IF;

    IF p_CategoryId IS NULL THEN
        v_SavedId := 'exc_' || left(replace(gen_random_uuid()::text, '-', ''), 20);

        INSERT INTO fin.ExpenseCategory
            (CategoryId, NameAr, NameEn, AccountCode, IsActive, CreatedBy, UpdatedBy)
        VALUES
            (v_SavedId, v_NameAr, v_NameEn, p_AccountCode, COALESCE(p_IsActive, true), p_Actor, p_Actor);
    ELSE
        v_SavedId := p_CategoryId;

        UPDATE fin.ExpenseCategory
        SET NameAr = v_NameAr, NameEn = v_NameEn, AccountCode = p_AccountCode,
            IsActive = COALESCE(p_IsActive, IsActive),
            UpdatedAtUtc = now() AT TIME ZONE 'utc', UpdatedBy = p_Actor
        WHERE CategoryId = p_CategoryId;
    END IF;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*------------------------------------------------------------------ expenses */

/*
  Spread an expense across the months it covers.

  Rounding remainders land on the final month so the slices always sum back to
  the amount recognised — never a halala more or less.
*/
CREATE OR REPLACE FUNCTION fin.usp_BuildExpenseRecognition(p_ExpenseId text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_AmountH     bigint;
    v_VatH        bigint;
    v_Recognition varchar COLLATE ci;
    v_PeriodFrom  date;
    v_PeriodTo    date;
    v_PaidOn      date;
    v_NetH        bigint;
BEGIN
    SELECT e.AmountH, e.VatH, e.Recognition, e.PeriodStart, e.PeriodEnd, e.PaidOn
    INTO v_AmountH, v_VatH, v_Recognition, v_PeriodFrom, v_PeriodTo, v_PaidOn
    FROM fin.Expense AS e WHERE e.ExpenseId = p_ExpenseId;

    IF v_AmountH IS NULL THEN
        RAISE EXCEPTION 'Expense not found.' USING DETAIL = '51020';
    END IF;

    DELETE FROM fin.ExpenseRecognition WHERE ExpenseId = p_ExpenseId;

    v_NetH := v_AmountH - v_VatH;

    IF v_Recognition = 'one_time' THEN
        INSERT INTO fin.ExpenseRecognition (ExpenseId, PeriodMonth, AmountH)
        VALUES (p_ExpenseId, to_char(v_PaidOn, 'YYYY-MM'), v_NetH);
        RETURN;
    END IF;

    WITH Months AS (
        SELECT m::date AS M
        FROM generate_series(date_trunc('month', v_PeriodFrom),
                             date_trunc('month', v_PeriodTo),
                             interval '1 month') AS m
    ),
    Numbered AS (
        SELECT M, ROW_NUMBER() OVER (ORDER BY M) AS Rn, COUNT(*) OVER () AS Total
        FROM Months
    )
    INSERT INTO fin.ExpenseRecognition (ExpenseId, PeriodMonth, AmountH)
    SELECT
        p_ExpenseId,
        to_char(M, 'YYYY-MM'),
        CASE WHEN Rn = Total
             THEN v_NetH - (v_NetH / Total) * (Total - 1)   -- remainder on the last month
             ELSE v_NetH / Total
        END
    FROM Numbered;
END $$;

/*--------------------------------------------------------- post one expense */

/*
  The ledger side of an expense that is already stored.

  Refuses an expense that already has entries, so it can never post twice.
*/
CREATE OR REPLACE FUNCTION fin.usp_PostExpenseLedger(
    p_ExpenseId text,
    p_Actor     text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_AmountH        bigint;
    v_VatH           bigint;
    v_Recognition    varchar COLLATE ci;
    v_PaidOn         date;
    v_PaymentMethod  varchar COLLATE ci;
    v_BranchId       varchar;
    v_AccountCode    varchar;
    v_DescriptionEn  varchar;
    v_DescriptionAr  varchar;
    v_NetH           bigint;
    v_Spreads        boolean;
    v_PaymentAccount varchar;
    v_Entry          fin.JournalLineTable[];
    v_Release        fin.JournalLineTable[];
    r                record;
BEGIN
    SELECT e.AmountH, e.VatH, e.Recognition, e.PaidOn,
           e.PaymentMethod, e.BranchId, c.AccountCode,
           COALESCE(e.DescriptionEn, e.Reference),
           e.DescriptionAr
    INTO v_AmountH, v_VatH, v_Recognition, v_PaidOn,
         v_PaymentMethod, v_BranchId, v_AccountCode,
         v_DescriptionEn, v_DescriptionAr
    FROM fin.Expense AS e
    JOIN fin.ExpenseCategory AS c ON c.CategoryId = e.CategoryId
    WHERE e.ExpenseId = p_ExpenseId;

    IF v_AmountH IS NULL THEN
        RAISE EXCEPTION 'Expense not found.' USING DETAIL = '54026';
    END IF;

    IF EXISTS (SELECT 1 FROM fin.JournalEntry WHERE SourceReference = p_ExpenseId) THEN
        RAISE EXCEPTION 'This expense is already posted.' USING DETAIL = '54025';
    END IF;

    v_NetH := v_AmountH - v_VatH;
    v_Spreads := v_Recognition <> 'one_time';
    v_PaymentAccount :=
        CASE v_PaymentMethod WHEN 'cash' THEN '1000'
                             WHEN 'credit' THEN '2000'
                             ELSE '1100' END;

    /* The payment leaves on the date it left, whatever period the cost
       belongs to. Anything spread over time parks in prepaid first. */
    v_Entry := ARRAY[
        ROW(CASE WHEN v_Spreads THEN '1500' ELSE v_AccountCode END, v_NetH, 0, v_DescriptionEn),
        ROW('1300', v_VatH, 0, 'Input VAT'),
        ROW(v_PaymentAccount, 0, v_AmountH, v_PaymentMethod)
    ]::fin.JournalLineTable[];

    PERFORM fin.usp_PostJournalEntry(
        p_Kind            => 'expense',
        p_DescriptionEn   => v_DescriptionEn,
        p_DescriptionAr   => v_DescriptionAr,
        p_SourceReference => p_ExpenseId,
        p_BranchId        => v_BranchId,
        p_Actor           => p_Actor,
        p_PostedAtUtc     => v_PaidOn::timestamp,
        p_Lines           => to_jsonb(v_Entry));

    PERFORM fin.usp_BuildExpenseRecognition(p_ExpenseId => p_ExpenseId);

    /* Release prepaid into the expense account, month by month, each on
       the first day of the month it belongs to. */
    IF v_Spreads THEN
        FOR r IN
            SELECT x.PeriodMonth, x.AmountH FROM fin.ExpenseRecognition AS x
            WHERE x.ExpenseId = p_ExpenseId AND x.AmountH > 0
            ORDER BY x.PeriodMonth
        LOOP
            v_Release := ARRAY[
                ROW(v_AccountCode, r.AmountH, 0, r.PeriodMonth),
                ROW('1500', 0, r.AmountH, 'Prepaid release')
            ]::fin.JournalLineTable[];

            PERFORM fin.usp_PostJournalEntry(
                p_Kind            => 'expense_recognition',
                p_DescriptionEn   => v_DescriptionEn,
                p_DescriptionAr   => v_DescriptionAr,
                p_SourceReference => p_ExpenseId,
                p_BranchId        => v_BranchId,
                p_Actor           => p_Actor,
                p_PostedAtUtc     => (r.PeriodMonth || '-01')::date::timestamp,
                p_Lines           => to_jsonb(v_Release));
        END LOOP;
    END IF;
END $$;

/*----------------------------------------------------------- record expense */

CREATE OR REPLACE FUNCTION fin.usp_RecordExpense(
    p_CategoryId    text,
    p_DescriptionEn text,
    p_AmountH       bigint,
    p_PaymentMethod text,
    p_PaidOn        date,
    p_Actor         text,
    p_BranchId      text DEFAULT NULL,
    p_DescriptionAr text DEFAULT NULL,
    p_VatH          bigint DEFAULT 0,
    p_Recognition   text DEFAULT 'one_time',
    p_PeriodStart   date DEFAULT NULL,
    p_PeriodEnd     date DEFAULT NULL,
    p_ExternalRef   text DEFAULT NULL,
    p_Attachment    text DEFAULT NULL)
RETURNS TABLE (ExpenseId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_VatH        bigint := COALESCE(p_VatH, 0);
    v_Recognition varchar;
    v_PeriodStart date;
    v_PeriodEnd   date;
    v_AccountCode varchar;
    v_Seq         bigint;
    v_ExpenseId   varchar;
BEGIN
    IF p_AmountH IS NULL OR p_AmountH <= 0 THEN
        RAISE EXCEPTION 'An expense must be above zero.' USING DETAIL = '54020';
    END IF;
    IF v_VatH < 0 OR v_VatH > p_AmountH THEN
        RAISE EXCEPTION 'VAT cannot exceed the amount.' USING DETAIL = '54021';
    END IF;

    v_Recognition := COALESCE(NULLIF(trim(p_Recognition), ''), 'one_time');
    v_PeriodStart := COALESCE(p_PeriodStart, p_PaidOn);
    v_PeriodEnd   := COALESCE(p_PeriodEnd, p_PaidOn);

    IF v_PeriodEnd < v_PeriodStart THEN
        RAISE EXCEPTION 'The period must end after it starts.' USING DETAIL = '54022';
    END IF;

    v_AccountCode := (SELECT c.AccountCode FROM fin.ExpenseCategory AS c WHERE c.CategoryId = p_CategoryId);

    IF v_AccountCode IS NULL THEN
        RAISE EXCEPTION 'Unknown expense category.' USING DETAIL = '54023';
    END IF;

    /* Salaries and commission are posted by payroll. Recording them here as
       well would count the same pay twice. */
    IF fin.fn_IsPayrollAccount(v_AccountCode) THEN
        RAISE EXCEPTION 'Salaries and commission are paid through payroll, not as an expense.' USING DETAIL = '54024';
    END IF;

    v_Seq := nextval('fin.ExpenseSequence');

    /* A number already taken by a row inserted by hand (or by an import)
       is skipped rather than failing the whole expense. 010 realigns the
       sequence; this keeps one stray row from ever blocking a payment. */
    WHILE EXISTS (SELECT 1 FROM fin.Expense WHERE Reference = 'EXP-' || v_Seq) LOOP
        v_Seq := nextval('fin.ExpenseSequence');
    END LOOP;

    v_ExpenseId := core.fn_NewId('exp_');

    INSERT INTO fin.Expense
        (ExpenseId, Reference, CategoryId, BranchId, DescriptionAr, DescriptionEn,
         AmountH, VatH, PaymentMethod, PaidOn, Recognition, PeriodStart, PeriodEnd,
         ExternalRef, AttachmentName, CreatedBy)
    VALUES
        (v_ExpenseId, 'EXP-' || v_Seq, p_CategoryId, p_BranchId,
         p_DescriptionAr, p_DescriptionEn, p_AmountH, v_VatH, p_PaymentMethod,
         p_PaidOn, v_Recognition, v_PeriodStart, v_PeriodEnd,
         p_ExternalRef, p_Attachment, p_Actor);

    PERFORM fin.usp_PostExpenseLedger(p_ExpenseId => v_ExpenseId, p_Actor => p_Actor);

    RETURN QUERY SELECT v_ExpenseId;
END $$;

/* Reverse an expense. The original stays; the opposite is posted. */
CREATE OR REPLACE FUNCTION fin.usp_ReverseExpense(
    p_ExpenseId text,
    p_Reason    text,
    p_Actor     text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM fin.Expense WHERE ExpenseId = p_ExpenseId) THEN
        RAISE EXCEPTION 'Expense not found.' USING DETAIL = '56030';
    END IF;

    IF EXISTS (SELECT 1 FROM fin.Expense WHERE ExpenseId = p_ExpenseId AND Status = 'reversed') THEN
        RAISE EXCEPTION 'This expense has already been reversed.' USING DETAIL = '56031';
    END IF;

    IF trim(COALESCE(p_Reason, '')) = '' THEN
        RAISE EXCEPTION 'A reversal needs a reason on the record.' USING DETAIL = '56032';
    END IF;

    FOR r IN
        SELECT e.EntryId FROM fin.JournalEntry AS e
        WHERE e.SourceReference = p_ExpenseId
          AND e.ReversesEntryId IS NULL
          AND e.ReversedByEntryId IS NULL
    LOOP
        PERFORM fin.usp_ReverseJournalEntry(
            p_EntryId => r.EntryId, p_Reason => p_Reason, p_Actor => p_Actor);
    END LOOP;

    UPDATE fin.Expense
    SET Status = 'reversed', UpdatedAtUtc = now() AT TIME ZONE 'utc', UpdatedBy = p_Actor
    WHERE ExpenseId = p_ExpenseId;
END $$;

/*------------------------------------------------------- recurring schedules */

CREATE OR REPLACE FUNCTION fin.usp_SaveRecurringPayment(
    p_DescriptionEn text,
    p_CategoryId    text,
    p_AmountH       bigint,
    p_Frequency     text,
    p_NextDueOn     date,
    p_RecurringId   text DEFAULT NULL,     -- null creates
    p_DescriptionAr text DEFAULT NULL,     -- null → the English text
    p_BranchId      text DEFAULT NULL,     -- null = the whole business
    p_PaymentMethod text DEFAULT 'bank',
    p_Note          text DEFAULT NULL,
    p_Status        text DEFAULT NULL)     -- null keeps (active on create)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_DescriptionEn varchar := NULLIF(trim(p_DescriptionEn), '');
    v_DescriptionAr varchar;
    v_SavedId       varchar;
BEGIN
    v_DescriptionAr := COALESCE(NULLIF(trim(p_DescriptionAr), ''), v_DescriptionEn);

    IF v_DescriptionEn IS NULL THEN
        RAISE EXCEPTION 'Give the payment a description.' USING DETAIL = '69100';
    END IF;

    IF p_AmountH IS NULL OR p_AmountH <= 0 THEN
        RAISE EXCEPTION 'Enter an amount above zero.' USING DETAIL = '69101';
    END IF;

    IF p_Frequency IS NULL OR p_Frequency COLLATE ci NOT IN ('daily', 'weekly', 'monthly', 'quarterly', 'yearly') THEN
        RAISE EXCEPTION 'Frequency is daily, weekly, monthly, quarterly or yearly.' USING DETAIL = '69102';
    END IF;

    IF p_NextDueOn IS NULL THEN
        RAISE EXCEPTION 'When is the next payment due?' USING DETAIL = '69103';
    END IF;

    IF p_PaymentMethod IS NULL OR p_PaymentMethod COLLATE ci NOT IN ('cash', 'card', 'bank', 'credit') THEN
        RAISE EXCEPTION 'Pay by cash, card, bank or on credit.' USING DETAIL = '69104';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM fin.ExpenseCategory WHERE CategoryId = p_CategoryId AND IsActive) THEN
        RAISE EXCEPTION 'Choose an active expense category.' USING DETAIL = '69105';
    END IF;

    /* Payroll posts salaries and commission every month already; a schedule
       for them would count the same pay twice. */
    IF EXISTS (SELECT 1 FROM fin.ExpenseCategory
               WHERE CategoryId = p_CategoryId AND fin.fn_IsPayrollAccount(AccountCode)) THEN
        RAISE EXCEPTION 'Salaries and commission are paid through payroll. Choose another category.' USING DETAIL = '69109';
    END IF;

    IF p_BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = p_BranchId) THEN
        RAISE EXCEPTION 'Unknown branch.' USING DETAIL = '69106';
    END IF;

    IF p_Status IS NOT NULL AND p_Status COLLATE ci NOT IN ('active', 'paused') THEN
        RAISE EXCEPTION 'Status is active or paused.' USING DETAIL = '69108';
    END IF;

    IF p_RecurringId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.RecurringPayment WHERE RecurringId = p_RecurringId) THEN
        RAISE EXCEPTION 'Recurring payment not found.' USING DETAIL = '69107';
    END IF;

    IF p_RecurringId IS NULL THEN
        v_SavedId := 'rec_' || left(replace(gen_random_uuid()::text, '-', ''), 20);

        INSERT INTO fin.RecurringPayment
            (RecurringId, DescriptionAr, DescriptionEn, CategoryId, BranchId, AmountH,
             Frequency, NextDueOn, PaymentMethod, Status, Note)
        VALUES
            (v_SavedId, v_DescriptionAr, v_DescriptionEn, p_CategoryId, p_BranchId, p_AmountH,
             p_Frequency, p_NextDueOn, p_PaymentMethod, COALESCE(p_Status, 'active'),
             NULLIF(trim(p_Note), ''));
    ELSE
        v_SavedId := p_RecurringId;

        UPDATE fin.RecurringPayment
        SET DescriptionAr = v_DescriptionAr,
            DescriptionEn = v_DescriptionEn,
            CategoryId    = p_CategoryId,
            BranchId      = p_BranchId,
            AmountH       = p_AmountH,
            Frequency     = p_Frequency,
            NextDueOn     = p_NextDueOn,
            PaymentMethod = p_PaymentMethod,
            Status        = COALESCE(p_Status, Status),
            Note          = NULLIF(trim(p_Note), ''),
            UpdatedAtUtc  = now() AT TIME ZONE 'utc'
        WHERE RecurringId = p_RecurringId;
    END IF;

    RETURN QUERY SELECT v_SavedId;
END $$;

CREATE OR REPLACE FUNCTION fin.usp_SetRecurringStatus(
    p_RecurringId text,
    p_Status      text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_Status IS NULL OR p_Status COLLATE ci NOT IN ('active', 'paused') THEN
        RAISE EXCEPTION 'Status is active or paused.' USING DETAIL = '69108';
    END IF;

    UPDATE fin.RecurringPayment
    SET Status = p_Status, UpdatedAtUtc = now() AT TIME ZONE 'utc'
    WHERE RecurringId = p_RecurringId;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Recurring payment not found.' USING DETAIL = '69107';
    END IF;
END $$;

/*------------------------------------------------------ recurring instalment */

/*
  Record an instalment.

  Creates a real expense, which posts, then rolls the schedule forward from the
  date that was due rather than from today. Paying late must not drag every
  future instalment along with it.

  A yearly or quarterly instalment pays for the months that follow its due
  date, so it is recognised over them (twelve or three whole months starting
  with the due month). Monthly and shorter belong to the month paid.
*/
CREATE OR REPLACE FUNCTION fin.usp_RecordRecurringInstalment(
    p_RecurringId text,
    p_PaidOn      date,
    p_Actor       text)
RETURNS TABLE (ExpenseId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_CategoryId  varchar;
    v_BranchId    varchar;
    v_AmountH     bigint;
    v_Frequency   varchar COLLATE ci;
    v_NextDueOn   date;
    v_Method      varchar;
    v_DescEn      varchar;
    v_DescAr      varchar;
    v_PaidOn      date;
    v_Months      integer;
    v_CoverFrom   date;
    v_Recognition varchar;
    v_PeriodStart date;
    v_PeriodEnd   date;
    v_ExpenseId   varchar;
BEGIN
    SELECT rp.CategoryId, rp.BranchId, rp.AmountH, rp.Frequency, rp.NextDueOn, rp.PaymentMethod,
           rp.DescriptionEn, rp.DescriptionAr
    INTO v_CategoryId, v_BranchId, v_AmountH, v_Frequency, v_NextDueOn, v_Method,
         v_DescEn, v_DescAr
    FROM fin.RecurringPayment AS rp WHERE rp.RecurringId = p_RecurringId;

    IF v_CategoryId IS NULL THEN
        RAISE EXCEPTION 'Recurring payment not found.' USING DETAIL = '56020';
    END IF;

    v_PaidOn := COALESCE(p_PaidOn, (now() AT TIME ZONE 'utc')::date);

    v_Months := CASE v_Frequency WHEN 'yearly' THEN 12 WHEN 'quarterly' THEN 3 ELSE 0 END;
    v_CoverFrom := make_date(extract(year FROM v_NextDueOn)::int, extract(month FROM v_NextDueOn)::int, 1);
    v_Recognition :=
        CASE v_Frequency WHEN 'yearly' THEN 'yearly' WHEN 'quarterly' THEN 'custom' ELSE 'one_time' END;
    v_PeriodStart := CASE WHEN v_Months > 0 THEN v_CoverFrom END;
    v_PeriodEnd   := CASE WHEN v_Months > 0
                          THEN (v_CoverFrom + make_interval(months => v_Months))::date - 1 END;

    SELECT x.ExpenseId INTO v_ExpenseId
    FROM fin.usp_RecordExpense(
        p_CategoryId    => v_CategoryId,
        p_BranchId      => v_BranchId,
        p_DescriptionEn => v_DescEn,
        p_DescriptionAr => v_DescAr,
        p_AmountH       => v_AmountH,
        p_VatH          => 0,
        p_PaymentMethod => v_Method,
        p_PaidOn        => v_PaidOn,
        p_Recognition   => v_Recognition,
        p_PeriodStart   => v_PeriodStart,
        p_PeriodEnd     => v_PeriodEnd,
        p_Actor         => p_Actor) AS x;

    UPDATE fin.RecurringPayment
    SET LastPaidOn   = v_PaidOn,
        NextDueOn    = fin.fn_AdvanceDueDate(v_NextDueOn, v_Frequency),
        UpdatedAtUtc = now() AT TIME ZONE 'utc'
    WHERE RecurringId = p_RecurringId;

    RETURN QUERY SELECT v_ExpenseId;
END $$;
