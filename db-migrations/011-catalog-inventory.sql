/*==============================================================================
  Nazad POS — 011 · Catalog and inventory functions (core, inv)

  Saving items, categories, print groups and vendors, switching records on and
  off, and moving stock: adjustments, stocktakes, deliveries and paying
  vendors. Conventions: README.md.
==============================================================================*/

/*---------------------------------------------------------- save catalog item */

CREATE OR REPLACE FUNCTION core.usp_SaveCatalogItem(
    p_ItemId              text DEFAULT NULL,   -- null creates
    p_Kind                text DEFAULT NULL,
    p_NameAr              text DEFAULT NULL,
    p_NameEn              text DEFAULT NULL,
    p_DescriptionAr       text DEFAULT NULL,
    p_DescriptionEn       text DEFAULT NULL,
    p_Sku                 text DEFAULT NULL,
    p_Barcode             text DEFAULT NULL,
    p_CategoryId          text DEFAULT NULL,
    p_VendorId            text DEFAULT NULL,
    p_PrintGroupId        text DEFAULT NULL,
    p_PriceH              bigint DEFAULT NULL,
    p_CostH               bigint DEFAULT 0,
    p_TracksStock         boolean DEFAULT true,
    p_ReorderLevel        numeric DEFAULT 0,
    p_RequiresPreparation boolean DEFAULT false,
    p_IsActive            boolean DEFAULT true,
    p_Actor               text DEFAULT NULL)
RETURNS TABLE (SavedItemId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_SavedItemId varchar;
    v_Sku         varchar;
    v_Barcode     varchar;
    v_TracksStock boolean := p_TracksStock;
BEGIN
    IF trim(COALESCE(p_NameAr, '')) = '' OR trim(COALESCE(p_NameEn, '')) = '' THEN
        RAISE EXCEPTION 'Both names are required.' USING DETAIL = '59000';
    END IF;

    IF p_PriceH < 0 THEN RAISE EXCEPTION 'A price cannot be negative.' USING DETAIL = '59001'; END IF;
    IF p_CostH  < 0 THEN RAISE EXCEPTION 'A cost cannot be negative.' USING DETAIL = '59002'; END IF;

    /* '' is "none", the same as NULL — never a value two items could share. */
    v_Sku     := NULLIF(trim(p_Sku), '');
    v_Barcode := NULLIF(trim(p_Barcode), '');

    /* A product is counted, received and looked up by its SKU; a product
       without one cannot be told apart on a stock sheet. A service has
       nothing on a shelf, so it does not need one. */
    IF p_Kind = 'product' AND v_Sku IS NULL THEN
        RAISE EXCEPTION 'A product needs a SKU.' USING DETAIL = '59006';
    END IF;

    /* A service has nothing to count. Letting it track stock would produce
       movements against a thing that does not exist. */
    IF p_Kind = 'service' THEN v_TracksStock := false; END IF;

    /* Barcodes are scanned. Two items sharing one means the till picks the
       wrong product, silently. */
    IF v_Barcode IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.CatalogItem AS i
        WHERE i.Barcode = v_Barcode AND (p_ItemId IS NULL OR i.ItemId <> p_ItemId))
    THEN
        RAISE EXCEPTION 'That barcode is already used by another item.' USING DETAIL = '59003';
    END IF;

    IF v_Sku IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.CatalogItem AS i
        WHERE i.Sku = v_Sku AND (p_ItemId IS NULL OR i.ItemId <> p_ItemId))
    THEN
        RAISE EXCEPTION 'That SKU is already used by another item.' USING DETAIL = '59004';
    END IF;

    IF p_ItemId IS NULL THEN
        v_SavedItemId := core.fn_NewId('itm_');

        INSERT INTO core.CatalogItem
            (ItemId, Kind, NameAr, NameEn, DescriptionAr, DescriptionEn, Sku, Barcode,
             CategoryId, VendorId, PrintGroupId, PriceH, CostH, TracksStock,
             ReorderLevel, RequiresPreparation, IsActive, CreatedBy)
        VALUES
            (v_SavedItemId, p_Kind, p_NameAr, p_NameEn, p_DescriptionAr, p_DescriptionEn,
             v_Sku, v_Barcode, p_CategoryId, p_VendorId, p_PrintGroupId, p_PriceH, p_CostH,
             v_TracksStock, trunc(p_ReorderLevel), p_RequiresPreparation, p_IsActive, p_Actor);
    ELSE
        v_SavedItemId := p_ItemId;

        /*
          Cost is not editable here.

          It is a weighted average maintained by receiving, and overwriting it
          from an edit form would make every past margin wrong. Correcting a
          cost is an inventory adjustment, not a product edit.
        */
        UPDATE core.CatalogItem
        SET Kind                = p_Kind,
            NameAr              = p_NameAr,
            NameEn              = p_NameEn,
            DescriptionAr       = p_DescriptionAr,
            DescriptionEn       = p_DescriptionEn,
            Sku                 = v_Sku,
            Barcode             = v_Barcode,
            CategoryId          = p_CategoryId,
            VendorId            = p_VendorId,
            PrintGroupId        = p_PrintGroupId,
            PriceH              = p_PriceH,
            TracksStock         = v_TracksStock,
            ReorderLevel        = trunc(p_ReorderLevel),
            RequiresPreparation = p_RequiresPreparation,
            IsActive            = p_IsActive,
            UpdatedAtUtc        = now() AT TIME ZONE 'utc',
            UpdatedBy           = p_Actor
        WHERE ItemId = p_ItemId;

        IF NOT FOUND THEN RAISE EXCEPTION 'No such item.' USING DETAIL = '59005'; END IF;
    END IF;

    RETURN QUERY SELECT v_SavedItemId;
END $$;

/*-------------------------------------------------------------- save category */

CREATE OR REPLACE FUNCTION core.usp_SaveCategory(
    p_CategoryId text DEFAULT NULL,    -- null creates
    p_NameAr     text DEFAULT NULL,
    p_NameEn     text DEFAULT NULL,
    p_AppliesTo  text DEFAULT 'both',
    p_SortOrder  integer DEFAULT NULL, -- null: after the last one
    p_IsActive   boolean DEFAULT true)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_SavedId varchar;
    v_NameAr  varchar := trim(COALESCE(p_NameAr, ''));
    v_NameEn  varchar := trim(COALESCE(p_NameEn, ''));
    v_Message text;
BEGIN
    IF v_NameAr = '' OR v_NameEn = '' THEN
        RAISE EXCEPTION 'Both names are required.' USING DETAIL = '65000';
    END IF;

    IF p_AppliesTo COLLATE ci NOT IN ('product', 'service', 'both') THEN
        RAISE EXCEPTION 'A category holds products, services or both.' USING DETAIL = '65001';
    END IF;

    IF p_CategoryId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Category AS c WHERE c.CategoryId = p_CategoryId) THEN
        RAISE EXCEPTION 'No such category.' USING DETAIL = '65002';
    END IF;

    /* One name, one category, in either language. Two "Beverages" on the POS
       rail leaves the cashier guessing which one holds the item. The column
       collation is case-insensitive; trim covers rows saved before this
       function trimmed. */
    IF EXISTS (SELECT 1 FROM core.Category AS c
               WHERE trim(c.NameAr) = v_NameAr
                 AND (p_CategoryId IS NULL OR c.CategoryId <> p_CategoryId)) THEN
        RAISE EXCEPTION 'Another category already has this Arabic name.' USING DETAIL = '65004';
    END IF;

    IF EXISTS (SELECT 1 FROM core.Category AS c
               WHERE trim(c.NameEn) = v_NameEn
                 AND (p_CategoryId IS NULL OR c.CategoryId <> p_CategoryId)) THEN
        RAISE EXCEPTION 'Another category already has this English name.' USING DETAIL = '65005';
    END IF;

    IF p_CategoryId IS NOT NULL AND NOT p_IsActive
       AND EXISTS (SELECT 1 FROM core.CatalogItem AS i WHERE i.CategoryId = p_CategoryId AND i.IsActive)
    THEN
        v_Message :=
            'This category still has '
            || (SELECT COUNT(*) FROM core.CatalogItem AS i WHERE i.CategoryId = p_CategoryId AND i.IsActive)
            || ' active items. Move or deactivate them first.';
        RAISE EXCEPTION '%', v_Message USING DETAIL = '65003';
    END IF;

    IF p_CategoryId IS NULL THEN
        v_SavedId := core.fn_NewId('cat_');

        INSERT INTO core.Category (CategoryId, NameAr, NameEn, AppliesTo, SortOrder, IsActive)
        VALUES (v_SavedId, v_NameAr, v_NameEn, p_AppliesTo,
                COALESCE(p_SortOrder, (SELECT COALESCE(MAX(c.SortOrder), 0) + 1 FROM core.Category AS c)),
                p_IsActive);
    ELSE
        v_SavedId := p_CategoryId;

        UPDATE core.Category
        SET NameAr = v_NameAr, NameEn = v_NameEn, AppliesTo = p_AppliesTo,
            SortOrder = COALESCE(p_SortOrder, SortOrder),
            IsActive = p_IsActive, UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE CategoryId = p_CategoryId;
    END IF;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*----------------------------------------------------------- save print group */

CREATE OR REPLACE FUNCTION core.usp_SavePrintGroup(
    p_PrintGroupId text DEFAULT NULL,    -- null creates
    p_NameAr       text DEFAULT NULL,
    p_NameEn       text DEFAULT NULL,
    p_TicketTitle  text DEFAULT NULL,    -- null: the English name
    p_SortOrder    integer DEFAULT NULL, -- null: after the last one
    p_IsActive     boolean DEFAULT true)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_SavedId     varchar;
    v_NameAr      varchar := trim(COALESCE(p_NameAr, ''));
    v_NameEn      varchar := trim(COALESCE(p_NameEn, ''));
    v_TicketTitle varchar := NULLIF(trim(p_TicketTitle), '');
BEGIN
    IF v_NameAr = '' OR v_NameEn = '' THEN
        RAISE EXCEPTION 'Both names are required.' USING DETAIL = '65010';
    END IF;

    IF p_PrintGroupId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.PrintGroup AS g WHERE g.PrintGroupId = p_PrintGroupId) THEN
        RAISE EXCEPTION 'No such print group.' USING DETAIL = '65011';
    END IF;

    /* Two groups with one name print two tickets nobody can tell apart. */
    IF EXISTS (SELECT 1 FROM core.PrintGroup AS g
               WHERE trim(g.NameAr) = v_NameAr
                 AND (p_PrintGroupId IS NULL OR g.PrintGroupId <> p_PrintGroupId)) THEN
        RAISE EXCEPTION 'Another print group already has this Arabic name.' USING DETAIL = '65013';
    END IF;

    IF EXISTS (SELECT 1 FROM core.PrintGroup AS g
               WHERE trim(g.NameEn) = v_NameEn
                 AND (p_PrintGroupId IS NULL OR g.PrintGroupId <> p_PrintGroupId)) THEN
        RAISE EXCEPTION 'Another print group already has this English name.' USING DETAIL = '65014';
    END IF;

    /* An item whose group is off has nowhere to print its ticket. */
    IF p_PrintGroupId IS NOT NULL AND NOT p_IsActive
       AND EXISTS (SELECT 1 FROM core.CatalogItem AS i WHERE i.PrintGroupId = p_PrintGroupId AND i.IsActive) THEN
        RAISE EXCEPTION 'This print group is still used by active items. Reassign them first, or their tickets will not print.'
            USING DETAIL = '65012';
    END IF;

    IF p_PrintGroupId IS NULL THEN
        v_SavedId := core.fn_NewId('pgr_');

        INSERT INTO core.PrintGroup (PrintGroupId, NameAr, NameEn, TicketTitle, SortOrder, IsActive)
        VALUES (v_SavedId, v_NameAr, v_NameEn, COALESCE(v_TicketTitle, v_NameEn),
                COALESCE(p_SortOrder, (SELECT COALESCE(MAX(g.SortOrder), 0) + 1 FROM core.PrintGroup AS g)),
                p_IsActive);
    ELSE
        v_SavedId := p_PrintGroupId;

        UPDATE core.PrintGroup
        SET NameAr = v_NameAr, NameEn = v_NameEn, TicketTitle = COALESCE(v_TicketTitle, v_NameEn),
            SortOrder = COALESCE(p_SortOrder, SortOrder), IsActive = p_IsActive,
            UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE PrintGroupId = p_PrintGroupId;
    END IF;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*------------------------------------------------------------- save a vendor */

CREATE OR REPLACE FUNCTION core.usp_SaveVendor(
    p_VendorId        text DEFAULT NULL,    -- null creates
    p_NameAr          text DEFAULT NULL,
    p_NameEn          text DEFAULT NULL,
    p_ContactPerson   text DEFAULT NULL,
    p_Phone           text DEFAULT NULL,
    p_Email           text DEFAULT NULL,
    p_VatNumber       text DEFAULT NULL,
    p_City            text DEFAULT NULL,
    p_PaymentTermDays integer DEFAULT NULL, -- null keeps (0 on create)
    p_IsActive        boolean DEFAULT true,
    p_Actor           text DEFAULT NULL)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_SavedId   varchar;
    v_NameAr    varchar := NULLIF(trim(p_NameAr), '');
    v_NameEn    varchar := NULLIF(trim(p_NameEn), '');
    v_Phone     varchar := NULLIF(trim(p_Phone), '');
    v_VatNumber varchar := NULLIF(trim(p_VatNumber), '');
BEGIN
    IF v_NameAr IS NULL OR v_NameEn IS NULL THEN
        RAISE EXCEPTION 'Both names are required.' USING DETAIL = '66000';
    END IF;

    /* The phone is how a missing delivery gets chased. */
    IF v_Phone IS NULL THEN
        RAISE EXCEPTION 'A phone number is required.' USING DETAIL = '66001';
    END IF;

    IF v_VatNumber IS NOT NULL
       AND (length(v_VatNumber) <> 15 OR (v_VatNumber COLLATE "default") ~ '[^0-9]') THEN
        RAISE EXCEPTION 'A Saudi VAT number is exactly 15 digits.' USING DETAIL = '66002';
    END IF;

    IF v_VatNumber IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.Vendor AS v
        WHERE v.VatNumber = v_VatNumber AND (p_VendorId IS NULL OR v.VendorId <> p_VendorId)) THEN
        RAISE EXCEPTION 'Another vendor already uses this VAT number.' USING DETAIL = '66003';
    END IF;

    IF EXISTS (SELECT 1 FROM core.Vendor AS v
               WHERE v.NameEn = v_NameEn AND (p_VendorId IS NULL OR v.VendorId <> p_VendorId)) THEN
        RAISE EXCEPTION 'Another vendor already uses this name.' USING DETAIL = '66004';
    END IF;

    IF p_PaymentTermDays < 0 THEN
        RAISE EXCEPTION 'Payment terms cannot be negative.' USING DETAIL = '66005';
    END IF;

    IF p_VendorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Vendor AS v WHERE v.VendorId = p_VendorId) THEN
        RAISE EXCEPTION 'Vendor not found.' USING DETAIL = '66006';
    END IF;

    /* Switching a vendor off while money is owed hides a debt; the same rule
       core.usp_SetActive applies. */
    IF p_VendorId IS NOT NULL AND NOT p_IsActive
       AND EXISTS (SELECT 1 FROM core.Vendor AS v WHERE v.VendorId = p_VendorId AND v.IsActive)
       AND EXISTS (SELECT 1 FROM inv.Purchase AS p
                   WHERE p.VendorId = p_VendorId AND NOT p.PaidOnReceipt AND p.PaidH < p.TotalH) THEN
        RAISE EXCEPTION 'This vendor still has unpaid deliveries.' USING DETAIL = '66007';
    END IF;

    IF p_VendorId IS NULL THEN
        v_SavedId := core.fn_NewId('ven_');

        INSERT INTO core.Vendor
            (VendorId, NameAr, NameEn, ContactPerson, Phone, Email, VatNumber, City,
             PaymentTermDays, IsActive, CreatedBy, UpdatedBy)
        VALUES
            (v_SavedId, v_NameAr, v_NameEn, NULLIF(trim(p_ContactPerson), ''), v_Phone,
             NULLIF(trim(p_Email), ''), v_VatNumber, NULLIF(trim(p_City), ''),
             COALESCE(p_PaymentTermDays, 0), COALESCE(p_IsActive, true), p_Actor, p_Actor);
    ELSE
        v_SavedId := p_VendorId;

        UPDATE core.Vendor
        SET NameAr          = v_NameAr,
            NameEn          = v_NameEn,
            ContactPerson   = NULLIF(trim(p_ContactPerson), ''),
            Phone           = v_Phone,
            Email           = NULLIF(trim(p_Email), ''),
            VatNumber       = v_VatNumber,
            City            = NULLIF(trim(p_City), ''),
            PaymentTermDays = COALESCE(p_PaymentTermDays, PaymentTermDays),
            IsActive        = COALESCE(p_IsActive, IsActive),
            UpdatedAtUtc    = now() AT TIME ZONE 'utc',
            UpdatedBy       = p_Actor
        WHERE VendorId = p_VendorId;
    END IF;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*------------------------------------------------- activate and deactivate */

CREATE OR REPLACE FUNCTION core.usp_SetActive(
    p_EntityType text,
    p_EntityId   text,
    p_IsActive   boolean,
    p_Actor      text DEFAULT NULL)
RETURNS TABLE (Blocked varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    /* Compared case-insensitively, as SQL Server did. */
    v_EntityType varchar COLLATE ci := p_EntityType;
BEGIN
    /*-------------------------------------------------- what may be deactivated */

    IF v_EntityType IS NULL
       OR v_EntityType NOT IN ('item', 'category', 'printGroup', 'vendor',
                               'customer', 'discount', 'expenseCategory',
                               'commissionRule', 'billTemplate', 'branch') THEN
        RAISE EXCEPTION 'That kind of record cannot be activated or deactivated.' USING DETAIL = '57000';
    END IF;

    /*----------------------------------------------------- deactivation guards */

    /*
      Refusing is kinder than cascading.

      Deactivating a category that still holds live items would either orphan
      them or silently hide them from the till — and the person clicking the
      toggle would have no idea which. Naming what is in the way lets them
      decide.

      Reactivating is never blocked: a guard that applied in both directions
      would trap a record permanently.
    */
    IF NOT p_IsActive THEN
        IF v_EntityType = 'category'
           AND EXISTS (SELECT 1 FROM core.CatalogItem AS i
                       WHERE i.CategoryId = p_EntityId AND i.IsActive) THEN
            RETURN QUERY SELECT (
                'This category still has '
                || (SELECT COUNT(*) FROM core.CatalogItem AS i
                    WHERE i.CategoryId = p_EntityId AND i.IsActive)
                || ' active items. Move or deactivate them first.')::varchar;
            RETURN;
        END IF;

        IF v_EntityType = 'printGroup'
           AND EXISTS (SELECT 1 FROM core.CatalogItem AS i
                       WHERE i.PrintGroupId = p_EntityId AND i.IsActive) THEN
            RETURN QUERY SELECT ('This print group is still used by active items. '
                              || 'Reassign them first, or their tickets will not print.')::varchar;
            RETURN;
        END IF;

        /* Money owed does not disappear because a record was switched off. */
        IF v_EntityType = 'customer'
           AND EXISTS (SELECT 1 FROM core.Customer AS c
                       WHERE c.CustomerId = p_EntityId AND c.BalanceH > 0) THEN
            RETURN QUERY SELECT ('This customer still owes money. '
                              || 'Settle the balance before deactivating.')::varchar;
            RETURN;
        END IF;

        /*
          A vendor's debt is not a column.

          What is owed is the unsettled part of purchases not paid on receipt
          (TotalH - PaidH, kept by inv.usp_RecordVendorPayment). A purchase that
          has been paid off no longer blocks the vendor.
        */
        IF v_EntityType = 'vendor'
           AND EXISTS (SELECT 1 FROM inv.Purchase AS p
                       WHERE p.VendorId = p_EntityId AND NOT p.PaidOnReceipt AND p.PaidH < p.TotalH) THEN
            RETURN QUERY SELECT (
                'This vendor has '
                || (SELECT COUNT(*) FROM inv.Purchase AS p
                    WHERE p.VendorId = p_EntityId AND NOT p.PaidOnReceipt AND p.PaidH < p.TotalH)
                || ' unpaid deliveries. Settle them before deactivating.')::varchar;
            RETURN;
        END IF;

        /* A branch with an open drawer or period has work in progress. */
        IF v_EntityType = 'branch' THEN
            IF EXISTS (SELECT 1 FROM fin.DrawerSession AS d
                       WHERE d.BranchId = p_EntityId AND d.ClosedAtUtc IS NULL) THEN
                RETURN QUERY SELECT 'This branch has an open cash drawer. Close it first.'::varchar;
                RETURN;
            END IF;

            IF EXISTS (SELECT 1 FROM fin.BalancePeriod AS b
                       WHERE b.BranchId = p_EntityId AND b.Status = 'open') THEN
                RETURN QUERY SELECT 'This branch has an open balance period. Close it first.'::varchar;
                RETURN;
            END IF;

            /* The last active branch cannot go: the till would have nowhere to sell. */
            IF (SELECT COUNT(*) FROM core.Branch AS b WHERE b.IsActive) <= 1 THEN
                RETURN QUERY SELECT 'This is the only active branch. At least one must remain.'::varchar;
                RETURN;
            END IF;
        END IF;
    END IF;

    /*---------------------------------------------------------------- the write */

    /*
      An explicit branch per type, setting only the columns that table has.

      A concatenated UPDATE would be shorter and would also accept whatever
      p_EntityType contained — a parameter reaching dynamic SQL unchecked is an
      injection route. There is no dynamic SQL in this file.
    */
    IF v_EntityType = 'item' THEN
        UPDATE core.CatalogItem
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc',
               UpdatedBy = p_Actor
        WHERE  ItemId = p_EntityId;
    ELSIF v_EntityType = 'category' THEN
        UPDATE core.Category
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE  CategoryId = p_EntityId;
    ELSIF v_EntityType = 'printGroup' THEN
        UPDATE core.PrintGroup
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE  PrintGroupId = p_EntityId;
    ELSIF v_EntityType = 'vendor' THEN
        UPDATE core.Vendor
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc',
               UpdatedBy = p_Actor
        WHERE  VendorId = p_EntityId;
    ELSIF v_EntityType = 'customer' THEN
        UPDATE core.Customer
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc',
               UpdatedBy = p_Actor
        WHERE  CustomerId = p_EntityId;
    ELSIF v_EntityType = 'discount' THEN
        UPDATE sales.Discount
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE  DiscountId = p_EntityId;
    ELSIF v_EntityType = 'expenseCategory' THEN
        UPDATE fin.ExpenseCategory
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE  CategoryId = p_EntityId;
    ELSIF v_EntityType = 'commissionRule' THEN
        UPDATE fin.CommissionRule
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE  RuleId = p_EntityId;
    ELSIF v_EntityType = 'billTemplate' THEN
        UPDATE core.BillTemplate
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE  BillId = p_EntityId;
    ELSIF v_EntityType = 'branch' THEN
        UPDATE core.Branch
        SET    IsActive = p_IsActive,
               UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE  BranchId = p_EntityId;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No such record.' USING DETAIL = '57001';
    END IF;

    /* Not blocked. */
    RETURN QUERY SELECT NULL::varchar;
END $$;

/*-------------------------------------------------------------- adjust stock */

/*
  Adjust stock.

  A correction, a stocktake or a write-off. The difference against the expected
  quantity posts to stock variance rather than disappearing, because unexplained
  shrinkage is the thing an owner most needs to see.
*/
CREATE OR REPLACE FUNCTION inv.usp_AdjustStock(
    p_ItemId      text,
    p_BranchId    text,
    p_NewQuantity numeric,
    p_ReasonEn    text,
    p_ReasonAr    text DEFAULT NULL,
    p_Actor       text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_Old    numeric(18,3);
    v_Delta  numeric(18,3);
    v_CostH  bigint;
    v_ValueH bigint;
    v_Entry  fin.JournalLineTable[];
BEGIN
    IF trim(COALESCE(p_ReasonEn, '')) = '' THEN
        RAISE EXCEPTION 'An adjustment needs a reason on the record.' USING DETAIL = '54010';
    END IF;

    IF p_NewQuantity < 0 THEN
        RAISE EXCEPTION 'Stock cannot be negative.' USING DETAIL = '54011';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.CatalogItem
                   WHERE ItemId = p_ItemId AND TracksStock) THEN
        RAISE EXCEPTION 'This item does not track stock.' USING DETAIL = '54012';
    END IF;

    INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
    VALUES (p_ItemId, p_BranchId, 0)
    ON CONFLICT (ItemId, BranchId) DO NOTHING;

    SELECT Quantity INTO v_Old FROM inv.StockLevel
    WHERE ItemId = p_ItemId AND BranchId = p_BranchId
    FOR UPDATE;

    v_Delta := p_NewQuantity - v_Old;

    IF v_Delta <> 0 THEN
        UPDATE inv.StockLevel
        SET Quantity = p_NewQuantity, UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE ItemId = p_ItemId AND BranchId = p_BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             ReasonEn, ReasonAr, Actor)
        SELECT p_ItemId, p_BranchId, 'adjustment', v_Delta, p_NewQuantity, i.CostH,
               p_ReasonEn, COALESCE(p_ReasonAr, p_ReasonEn), p_Actor
        FROM core.CatalogItem AS i WHERE i.ItemId = p_ItemId;

        /* The value of what was gained or lost. */
        v_CostH  := (SELECT CostH FROM core.CatalogItem WHERE ItemId = p_ItemId);
        v_ValueH := round(abs(v_Delta) * v_CostH, 0)::bigint;

        IF v_ValueH > 0 THEN
            IF v_Delta < 0 THEN
                v_Entry := ARRAY[
                    ROW('5200', v_ValueH, 0, 'Stock variance'),
                    ROW('1200', 0, v_ValueH, 'Inventory')
                ]::fin.JournalLineTable[];
            ELSE
                v_Entry := ARRAY[
                    ROW('1200', v_ValueH, 0, 'Inventory'),
                    ROW('5200', 0, v_ValueH, 'Stock variance')
                ]::fin.JournalLineTable[];
            END IF;

            PERFORM fin.usp_PostJournalEntry(
                p_Kind            => 'stock_adjustment',
                p_DescriptionEn   => p_ReasonEn,
                p_DescriptionAr   => p_ReasonAr,
                p_SourceReference => p_ItemId,
                p_BranchId        => p_BranchId,
                p_Actor           => p_Actor,
                p_Lines           => to_jsonb(v_Entry));
        END IF;
    END IF;
END $$;

/*---------------------------------------------------------- post a stocktake */

CREATE OR REPLACE FUNCTION inv.usp_PostStocktake(
    p_BranchId text,
    p_Lines    jsonb DEFAULT '[]',
    p_Note     text DEFAULT NULL,
    p_Actor    text DEFAULT NULL)
RETURNS TABLE (
    Reference       varchar,
    ItemId          varchar,
    NameAr          varchar,
    NameEn          varchar,
    Sku             varchar,
    SystemQuantity  numeric,
    CountedQuantity numeric,
    Difference      numeric,
    ValueH          bigint)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Lines     inv.StocktakeLineTable[] :=
        ARRAY(SELECT jsonb_populate_recordset(NULL::inv.StocktakeLineTable, p_Lines));
    v_Now       timestamp := (now() AT TIME ZONE 'utc')::timestamp(3);
    /* What changed: one object per item (itemid, oldqty, newqty, costh). */
    v_Diff      jsonb;
    v_Reference varchar;
    v_ReasonEn  varchar;
    v_ReasonAr  varchar;
    v_LossH     bigint;
    v_GainH     bigint;
    v_Entry     fin.JournalLineTable[] := ARRAY[]::fin.JournalLineTable[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.Branch AS b WHERE b.BranchId = p_BranchId AND b.IsActive) THEN
        RAISE EXCEPTION 'Unknown or inactive branch.' USING DETAIL = '54034';
    END IF;

    IF cardinality(v_Lines) = 0 THEN
        RAISE EXCEPTION 'A stocktake needs at least one counted line.' USING DETAIL = '54030';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l WHERE l.CountedQuantity < 0)
       OR EXISTS (SELECT l.ItemId FROM unnest(v_Lines) AS l GROUP BY l.ItemId HAVING COUNT(*) > 1) THEN
        RAISE EXCEPTION 'Counts cannot be negative, and each item is counted once.' USING DETAIL = '54031';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l
               LEFT JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId AND i.TracksStock
               WHERE i.ItemId IS NULL) THEN
        RAISE EXCEPTION 'Only items that track stock can be counted.' USING DETAIL = '54032';
    END IF;

    /* Every counted item gets a stock row, so "no row" and "zero" are the same. */
    INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
    SELECT l.ItemId, p_BranchId, 0
    FROM unnest(v_Lines) AS l
    ON CONFLICT (ItemId, BranchId) DO NOTHING;

    /* Read the system quantities under an update lock, so a sale cannot
       move them between reading and writing. */
    PERFORM 1
    FROM inv.StockLevel AS s
    WHERE s.BranchId = p_BranchId
      AND s.ItemId IN (SELECT l.ItemId FROM unnest(v_Lines) AS l)
    FOR UPDATE;

    v_Diff := (
        SELECT jsonb_agg(jsonb_build_object(
                   'itemid', l.ItemId, 'oldqty', s.Quantity,
                   'newqty', l.CountedQuantity, 'costh', i.CostH))
        FROM unnest(v_Lines) AS l
        JOIN inv.StockLevel AS s ON s.ItemId = l.ItemId AND s.BranchId = p_BranchId
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
        WHERE s.Quantity <> l.CountedQuantity);

    IF v_Diff IS NULL THEN
        RAISE EXCEPTION 'Nothing changed: every count matches the system quantity.' USING DETAIL = '54033';
    END IF;

    v_Reference := 'STK-' || to_char(v_Now + interval '3 hours', 'YYYYMMDD') || '-'
                || upper(left(replace(gen_random_uuid()::text, '-', ''), 6));

    v_ReasonEn := left('Stocktake ' || v_Reference
                       || COALESCE(' — ' || NULLIF(trim(p_Note), ''), ''), 400);
    v_ReasonAr := left('جرد ' || v_Reference
                       || COALESCE(' — ' || NULLIF(trim(p_Note), ''), ''), 400);

    UPDATE inv.StockLevel AS s
    SET Quantity = d.NewQty, UpdatedAtUtc = v_Now
    FROM jsonb_to_recordset(v_Diff) AS d(ItemId varchar, OldQty numeric, NewQty numeric, CostH bigint)
    WHERE d.ItemId = s.ItemId AND s.BranchId = p_BranchId;

    INSERT INTO inv.StockMovement
        (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
         Reference, ReasonEn, ReasonAr, OccurredAtUtc, Actor)
    SELECT d.ItemId, p_BranchId, 'stocktake', d.NewQty - d.OldQty, d.NewQty, d.CostH,
           v_Reference, v_ReasonEn, v_ReasonAr, v_Now, p_Actor
    FROM jsonb_to_recordset(v_Diff) AS d(ItemId varchar, OldQty numeric, NewQty numeric, CostH bigint);

    /* One entry for the whole count: what was lost, and what was found. */
    v_LossH := COALESCE((SELECT SUM(round((d.OldQty - d.NewQty) * d.CostH, 0)::bigint)::bigint
                         FROM jsonb_to_recordset(v_Diff) AS d(OldQty numeric, NewQty numeric, CostH bigint)
                         WHERE d.NewQty < d.OldQty), 0);
    v_GainH := COALESCE((SELECT SUM(round((d.NewQty - d.OldQty) * d.CostH, 0)::bigint)::bigint
                         FROM jsonb_to_recordset(v_Diff) AS d(OldQty numeric, NewQty numeric, CostH bigint)
                         WHERE d.NewQty > d.OldQty), 0);

    IF v_LossH > 0 OR v_GainH > 0 THEN
        IF v_LossH > 0 THEN
            v_Entry := v_Entry || ARRAY[
                ROW('5200', v_LossH, 0, 'Stock variance — stocktake shrinkage'),
                ROW('1200', 0, v_LossH, 'Inventory')
            ]::fin.JournalLineTable[];
        END IF;

        IF v_GainH > 0 THEN
            v_Entry := v_Entry || ARRAY[
                ROW('1200', v_GainH, 0, 'Inventory'),
                ROW('5200', 0, v_GainH, 'Stock variance — stocktake surplus')
            ]::fin.JournalLineTable[];
        END IF;

        PERFORM fin.usp_PostJournalEntry(
            p_Kind            => 'stock_adjustment',
            p_DescriptionEn   => v_ReasonEn,
            p_DescriptionAr   => v_ReasonAr,
            p_SourceReference => v_Reference,
            p_BranchId        => p_BranchId,
            p_Actor           => p_Actor,
            p_Lines           => to_jsonb(v_Entry));
    END IF;

    /* What changed, for the screen's summary. The reference rides on every row. */
    RETURN QUERY
        SELECT v_Reference, i.ItemId, i.NameAr, i.NameEn, i.Sku,
               d.OldQty, d.NewQty, d.NewQty - d.OldQty,
               round((d.NewQty - d.OldQty) * d.CostH, 0)::bigint
        FROM jsonb_to_recordset(v_Diff) AS d(ItemId varchar, OldQty numeric, NewQty numeric, CostH bigint)
        JOIN core.CatalogItem AS i ON i.ItemId = d.ItemId
        ORDER BY i.NameEn;
END $$;

/*------------------------------------------------------ receive a delivery */

/*
  Receive a delivery.

  A purchase paid on receipt is settled at once (PaidH = TotalH) so it never
  shows as owed.

  Cost is recalculated as a weighted average rather than overwritten. Taking the
  latest supplier price as the cost makes reported margin lurch every time a
  supplier changes their price, even on stock bought months earlier.
*/
CREATE OR REPLACE FUNCTION inv.usp_ReceivePurchase(
    p_VendorId      text,
    p_BranchId      text,
    p_InvoiceNumber text DEFAULT NULL,
    p_VatRate       numeric DEFAULT 15.00,
    p_PaidOnReceipt boolean DEFAULT false,
    p_ReceivedBy    text DEFAULT NULL,
    p_Lines         jsonb DEFAULT '[]',
    p_Note          text DEFAULT NULL)
RETURNS TABLE (PurchaseId varchar, Reference varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Lines      inv.PurchaseLineTable[] :=
        ARRAY(SELECT jsonb_populate_recordset(NULL::inv.PurchaseLineTable, p_Lines));
    v_SubtotalH  bigint;
    v_TaxH       bigint;
    v_TotalH     bigint;
    v_Seq        bigint;
    v_PurchaseId varchar;
    v_Reference  varchar;
    v_Entry      fin.JournalLineTable[];
BEGIN
    IF cardinality(v_Lines) = 0 THEN
        RAISE EXCEPTION 'A delivery needs at least one line.' USING DETAIL = '54000';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l WHERE l.Quantity <= 0 OR l.UnitCostH < 0) THEN
        RAISE EXCEPTION 'Quantities must be above zero and costs cannot be negative.' USING DETAIL = '54001';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Lines) AS l
               JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
               WHERE NOT i.TracksStock) THEN
        RAISE EXCEPTION 'A service cannot be received into stock.' USING DETAIL = '54002';
    END IF;

    /* Purchase VAT is added on top of the net supplier price — the opposite
       direction to a retail sale, where it is extracted from the gross.
       Whole halalas, cut as SQL Server cut a decimal into BIGINT. */
    v_SubtotalH := (SELECT trunc(SUM(l.Quantity * l.UnitCostH))::bigint FROM unnest(v_Lines) AS l);
    v_TaxH      := round(v_SubtotalH * p_VatRate / 100.0, 0)::bigint;
    v_TotalH    := v_SubtotalH + v_TaxH;

    v_Seq        := nextval('inv.PurchaseSequence');
    v_PurchaseId := core.fn_NewId('pur_');
    v_Reference  := 'PO-' || v_Seq;

    INSERT INTO inv.Purchase
        (PurchaseId, Reference, VendorId, BranchId, InvoiceNumber,
         SubtotalH, TaxH, TotalH, PaidOnReceipt, PaidH, Note, ReceivedBy)
    VALUES
        (v_PurchaseId, v_Reference, p_VendorId, p_BranchId, p_InvoiceNumber,
         v_SubtotalH, v_TaxH, v_TotalH, p_PaidOnReceipt,
         CASE WHEN p_PaidOnReceipt THEN v_TotalH ELSE 0 END,
         NULLIF(trim(p_Note), ''), p_ReceivedBy);

    INSERT INTO inv.PurchaseLine (PurchaseId, ItemId, Quantity, UnitCostH)
    SELECT v_PurchaseId, l.ItemId, l.Quantity, l.UnitCostH FROM unnest(v_Lines) AS l;

    /* Weighted average: (existing value + incoming value) / total units. */
    UPDATE core.CatalogItem AS i
    SET CostH = CASE
                    WHEN COALESCE(s.Quantity, 0) + agg.Qty = 0 THEN trunc(agg.AvgCost)::bigint
                    ELSE trunc(
                        (COALESCE(s.Quantity, 0) * i.CostH + agg.Qty * agg.AvgCost)
                        / (COALESCE(s.Quantity, 0) + agg.Qty))::bigint
                END,
        UpdatedAtUtc = now() AT TIME ZONE 'utc'
    FROM (SELECT l.ItemId, SUM(l.Quantity) AS Qty,
                 SUM(l.Quantity * l.UnitCostH) / NULLIF(SUM(l.Quantity), 0) AS AvgCost
          FROM unnest(v_Lines) AS l GROUP BY l.ItemId) AS agg
    LEFT JOIN inv.StockLevel AS s ON s.ItemId = agg.ItemId AND s.BranchId = p_BranchId
    WHERE agg.ItemId = i.ItemId;

    /* Create the stock row if this branch has never held the item. */
    INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
    SELECT DISTINCT l.ItemId, p_BranchId, 0
    FROM unnest(v_Lines) AS l
    ON CONFLICT (ItemId, BranchId) DO NOTHING;

    UPDATE inv.StockLevel AS s
    SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = now() AT TIME ZONE 'utc'
    FROM (SELECT l.ItemId, SUM(l.Quantity) AS Qty FROM unnest(v_Lines) AS l GROUP BY l.ItemId) AS agg
    WHERE agg.ItemId = s.ItemId AND s.BranchId = p_BranchId;

    INSERT INTO inv.StockMovement
        (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
         Reference, ReasonEn, ReasonAr, Actor)
    SELECT
        agg.ItemId, p_BranchId, 'purchase', agg.Qty, s.Quantity, trunc(agg.AvgCost)::bigint,
        v_Reference, 'Delivery received', 'استلام بضاعة', p_ReceivedBy
    FROM (SELECT l.ItemId, SUM(l.Quantity) AS Qty,
                 SUM(l.Quantity * l.UnitCostH) / NULLIF(SUM(l.Quantity), 0) AS AvgCost
          FROM unnest(v_Lines) AS l GROUP BY l.ItemId) AS agg
    JOIN inv.StockLevel AS s ON s.ItemId = agg.ItemId AND s.BranchId = p_BranchId;

    /* Stock arriving is an asset swap, not a cost. It becomes a cost when
       it is sold, through COGS. */
    v_Entry := ARRAY[
        ROW('1200', v_SubtotalH, 0, 'Inventory'),
        ROW('1300', v_TaxH, 0, 'Input VAT'),
        ROW(CASE WHEN p_PaidOnReceipt THEN '1000' ELSE '2000' END, 0, v_TotalH, 'Supplier')
    ]::fin.JournalLineTable[];

    PERFORM fin.usp_PostJournalEntry(
        p_Kind            => 'purchase',
        p_DescriptionEn   => 'Delivery received',
        p_DescriptionAr   => 'استلام بضاعة',
        p_SourceReference => v_Reference,
        p_BranchId        => p_BranchId,
        p_Actor           => p_ReceivedBy,
        p_Lines           => to_jsonb(v_Entry));

    RETURN QUERY SELECT v_PurchaseId, v_Reference;
END $$;

/*---------------------------------------------------------- pay a vendor */

/*
  Pay a supplier.

  The amount is allocated to the oldest unsettled purchases first, or only to
  p_PurchaseId when one is named. More than is owed is refused: an overpayment
  would leave a debit balance on payables that nothing explains.
*/
CREATE OR REPLACE FUNCTION inv.usp_RecordVendorPayment(
    p_VendorId   text,
    p_AmountH    bigint,
    p_Method     text,
    p_PurchaseId text DEFAULT NULL,
    p_BranchId   text DEFAULT NULL,
    p_Note       text DEFAULT NULL,
    p_Actor      text DEFAULT NULL)
RETURNS TABLE (PaymentId varchar, Reference varchar, EntryId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_VendorNameEn varchar;
    v_VendorNameAr varchar;
    v_OpenCount    integer;
    v_OwedH        bigint;
    /* The allocation: one object per purchase (purchaseid, branchid, amounth). */
    v_Alloc        jsonb;
    v_BranchId     varchar := p_BranchId;
    v_Seq          bigint;
    v_PaymentId    varchar;
    v_Reference    varchar;
    v_EntryId      varchar;
    v_Entry        fin.JournalLineTable[];
    v_DescEn       varchar;
    v_DescAr       varchar;
BEGIN
    IF p_AmountH IS NULL OR p_AmountH <= 0 THEN
        RAISE EXCEPTION 'A payment must be above zero.' USING DETAIL = '66010';
    END IF;

    IF p_Method IS NULL OR p_Method NOT IN ('cash', 'card', 'bank') THEN
        RAISE EXCEPTION 'Pay by cash, card or bank.' USING DETAIL = '66013';
    END IF;

    SELECT v.NameEn, v.NameAr INTO v_VendorNameEn, v_VendorNameAr
    FROM core.Vendor AS v WHERE v.VendorId = p_VendorId;

    IF v_VendorNameEn IS NULL THEN
        RAISE EXCEPTION 'Vendor not found.' USING DETAIL = '66011';
    END IF;

    /* Locked, so two payments at once cannot both settle the same debt. */
    PERFORM 1
    FROM inv.Purchase AS p
    WHERE p.VendorId = p_VendorId
      AND NOT p.PaidOnReceipt
      AND p.PaidH < p.TotalH
      AND (p_PurchaseId IS NULL OR p.PurchaseId = p_PurchaseId)
    FOR UPDATE;

    SELECT COUNT(*)::int, COALESCE(SUM(p.TotalH - p.PaidH), 0)::bigint INTO v_OpenCount, v_OwedH
    FROM inv.Purchase AS p
    WHERE p.VendorId = p_VendorId
      AND NOT p.PaidOnReceipt
      AND p.PaidH < p.TotalH
      AND (p_PurchaseId IS NULL OR p.PurchaseId = p_PurchaseId);

    IF p_PurchaseId IS NOT NULL AND v_OpenCount = 0 THEN
        IF NOT EXISTS (SELECT 1 FROM inv.Purchase AS p
                       WHERE p.PurchaseId = p_PurchaseId AND p.VendorId = p_VendorId) THEN
            RAISE EXCEPTION 'That purchase is not from this vendor.' USING DETAIL = '66014';
        ELSE
            RAISE EXCEPTION 'That purchase is already settled.' USING DETAIL = '66015';
        END IF;
    END IF;

    IF p_AmountH > v_OwedH THEN
        RAISE EXCEPTION 'That is more than is owed to this vendor.' USING DETAIL = '66012';
    END IF;

    /* Oldest first: each purchase takes what it still owes, the last one
       takes whatever is left of the payment. */
    v_Alloc := (
        SELECT jsonb_agg(jsonb_build_object(
                   'purchaseid', o.PurchaseId, 'branchid', o.BranchId,
                   'amounth', CASE WHEN o.RunningH <= p_AmountH THEN o.OwedH
                                   ELSE p_AmountH - (o.RunningH - o.OwedH) END))
        FROM (SELECT p.PurchaseId, p.BranchId, p.TotalH - p.PaidH AS OwedH,
                     SUM(p.TotalH - p.PaidH) OVER (ORDER BY p.ReceivedAtUtc, p.Reference
                                                   ROWS UNBOUNDED PRECEDING) AS RunningH
              FROM inv.Purchase AS p
              WHERE p.VendorId = p_VendorId
                AND NOT p.PaidOnReceipt
                AND p.PaidH < p.TotalH
                AND (p_PurchaseId IS NULL OR p.PurchaseId = p_PurchaseId)) AS o
        WHERE o.RunningH - o.OwedH < p_AmountH);

    /* No branch given: the branch of what was settled, when that is one. */
    IF v_BranchId IS NULL
       AND (SELECT COUNT(DISTINCT a.BranchId)
            FROM jsonb_to_recordset(v_Alloc) AS a(BranchId varchar)) = 1
       AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(v_Alloc) AS a(BranchId varchar)
                       WHERE a.BranchId IS NULL) THEN
        v_BranchId := (SELECT a.BranchId FROM jsonb_to_recordset(v_Alloc) AS a(BranchId varchar) LIMIT 1);
    END IF;

    v_Seq       := nextval('inv.VendorPaymentSequence');
    v_PaymentId := core.fn_NewId('vpy_');
    v_Reference := 'VP-' || v_Seq;

    v_Entry := ARRAY[
        ROW('2000', p_AmountH, 0, 'Accounts payable'),
        ROW(CASE WHEN p_Method = 'cash' THEN '1000' ELSE '1100' END, 0, p_AmountH, p_Method)
    ]::fin.JournalLineTable[];

    v_DescEn := 'Vendor payment ' || v_Reference || ' — ' || v_VendorNameEn;
    v_DescAr := 'سداد مورد ' || v_Reference || ' — ' || COALESCE(v_VendorNameAr, '');

    SELECT e.EntryId INTO v_EntryId
    FROM fin.usp_PostJournalEntry(
        p_Kind            => 'supplier_payment',
        p_DescriptionEn   => v_DescEn,
        p_DescriptionAr   => v_DescAr,
        p_SourceReference => v_Reference,
        p_BranchId        => v_BranchId,
        p_Actor           => p_Actor,
        p_Lines           => to_jsonb(v_Entry)) AS e;

    INSERT INTO inv.VendorPayment
        (PaymentId, Reference, VendorId, BranchId, AmountH, Method, Note, EntryId, PaidBy)
    VALUES
        (v_PaymentId, v_Reference, p_VendorId, v_BranchId, p_AmountH, p_Method,
         NULLIF(trim(p_Note), ''), v_EntryId, p_Actor);

    INSERT INTO inv.VendorPaymentAllocation (PaymentId, PurchaseId, AmountH)
    SELECT v_PaymentId, a.PurchaseId, a.AmountH
    FROM jsonb_to_recordset(v_Alloc) AS a(PurchaseId varchar, AmountH bigint)
    WHERE a.AmountH > 0;

    UPDATE inv.Purchase AS p
    SET PaidH = p.PaidH + a.AmountH
    FROM jsonb_to_recordset(v_Alloc) AS a(PurchaseId varchar, AmountH bigint)
    WHERE a.PurchaseId = p.PurchaseId;

    RETURN QUERY SELECT v_PaymentId, v_Reference, v_EntryId;
END $$;
