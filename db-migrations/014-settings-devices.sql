/*==============================================================================
  Nazad POS — 014 · Settings and device functions (core, device)

  The company profile, branch settings, bill templates, the notification bell,
  and the POS terminals: registration, heartbeats, commands and network
  discovery. Conventions: README.md.
==============================================================================*/

/*--------------------------------------------------------------- save company */

CREATE OR REPLACE FUNCTION core.usp_SaveCompany(
    p_NameAr        text,
    p_NameEn        text,
    p_DescriptionAr text DEFAULT NULL,
    p_DescriptionEn text DEFAULT NULL,
    p_LogoUrl       text DEFAULT NULL,
    p_CrNumber      text DEFAULT NULL,
    p_VatNumber     text DEFAULT NULL,
    p_Phone         text DEFAULT NULL,
    p_Email         text DEFAULT NULL,
    p_Website       text DEFAULT NULL,
    p_Street        text DEFAULT NULL,
    p_District      text DEFAULT NULL,
    p_City          text DEFAULT NULL,
    p_PostalCode    text DEFAULT NULL,
    p_Country       text DEFAULT NULL,
    p_SocialLinks   text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF btrim(COALESCE(p_NameAr, '')) = '' OR btrim(COALESCE(p_NameEn, '')) = '' THEN
        RAISE EXCEPTION 'Both company names are required.' USING DETAIL = '62000';
    END IF;

    /* A Saudi VAT number is fifteen digits, starting and ending in 3. A wrong
       one prints on every invoice, so it is checked here rather than
       discovered by an auditor. */
    IF p_VatNumber IS NOT NULL
       AND (length(p_VatNumber) <> 15 OR p_VatNumber !~ '^[0-9]*$'
            OR left(p_VatNumber, 1) <> '3' OR right(p_VatNumber, 1) <> '3') THEN
        RAISE EXCEPTION 'A VAT number is 15 digits, starting and ending with 3.' USING DETAIL = '62001';
    END IF;

    IF p_CrNumber IS NOT NULL AND (length(p_CrNumber) <> 10 OR p_CrNumber !~ '^[0-9]*$') THEN
        RAISE EXCEPTION 'A CR number is 10 digits.' USING DETAIL = '62002';
    END IF;

    IF p_SocialLinks IS NOT NULL AND p_SocialLinks IS NOT JSON THEN
        RAISE EXCEPTION 'The social links are not valid.' USING DETAIL = '62004';
    END IF;

    UPDATE core.Company
    SET NameAr = p_NameAr, NameEn = p_NameEn,
        DescriptionAr = p_DescriptionAr, DescriptionEn = p_DescriptionEn,
        LogoUrl = p_LogoUrl, CrNumber = p_CrNumber, VatNumber = p_VatNumber,
        Phone = p_Phone, Email = p_Email, Website = p_Website,
        Street = p_Street, District = p_District, City = p_City,
        PostalCode = p_PostalCode, Country = p_Country, SocialLinks = p_SocialLinks,
        UpdatedAtUtc = now() AT TIME ZONE 'utc';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No company record exists.' USING DETAIL = '62003';
    END IF;
END $$;

/*------------------------------------------------------ save branch settings */

CREATE OR REPLACE FUNCTION core.usp_SaveBranchSettings(
    p_BranchId            text,
    p_DefaultCustomerMode text,
    p_ServedByRequirement text,
    p_AllowNegativeStock  boolean,
    p_DefaultBillId       text DEFAULT NULL,
    p_AutoPrintCustomer   boolean DEFAULT true,
    p_AutoPrintGroups     boolean DEFAULT true,
    p_VatRatePercent      numeric DEFAULT NULL,
    p_PricesIncludeVat    boolean DEFAULT true,
    p_Actor               text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = p_BranchId) THEN
        RAISE EXCEPTION 'No such branch.' USING DETAIL = '62050';
    END IF;

    /* The list checks ignore case, as SQL Server's collation did. */
    IF lower(p_DefaultCustomerMode) NOT IN ('walkin', 'customer') THEN
        RAISE EXCEPTION 'The default customer mode is walkin or customer.' USING DETAIL = '62051';
    END IF;

    IF lower(p_ServedByRequirement) NOT IN ('off', 'optional', 'required') THEN
        RAISE EXCEPTION 'Served-by is off, optional or required.' USING DETAIL = '62052';
    END IF;

    IF p_VatRatePercent IS NULL OR p_VatRatePercent < 0 OR p_VatRatePercent > 100 THEN
        RAISE EXCEPTION 'Enter a VAT rate between 0 and 100.' USING DETAIL = '62053';
    END IF;

    /* The branch default is what prints on a customer's receipt. A kitchen
       ticket there would hand the customer a bill with no total. */
    IF p_DefaultBillId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM core.BillTemplate
        WHERE BillId = p_DefaultBillId AND Audience = 'customer' AND IsActive) THEN
        RAISE EXCEPTION 'The default bill must be an active customer template.' USING DETAIL = '62054';
    END IF;

    UPDATE core.BranchSettings
    SET DefaultCustomerMode = p_DefaultCustomerMode,
        ServedByRequirement = p_ServedByRequirement,
        AllowNegativeStock  = p_AllowNegativeStock,
        DefaultBillId       = p_DefaultBillId,
        AutoPrintCustomer   = p_AutoPrintCustomer,
        AutoPrintGroups     = p_AutoPrintGroups,
        VatRatePercent      = p_VatRatePercent,
        PricesIncludeVat    = p_PricesIncludeVat,
        UpdatedAtUtc        = now() AT TIME ZONE 'utc',
        UpdatedBy           = p_Actor
    WHERE BranchId = p_BranchId;

    IF NOT FOUND THEN
        INSERT INTO core.BranchSettings
            (BranchId, DefaultCustomerMode, ServedByRequirement, AllowNegativeStock,
             DefaultBillId, AutoPrintCustomer, AutoPrintGroups, VatRatePercent,
             PricesIncludeVat, UpdatedBy)
        VALUES
            (p_BranchId, p_DefaultCustomerMode, p_ServedByRequirement, p_AllowNegativeStock,
             p_DefaultBillId, p_AutoPrintCustomer, p_AutoPrintGroups, p_VatRatePercent,
             p_PricesIncludeVat, p_Actor);
    END IF;
END $$;

/*
  Copy one branch's configuration onto another.

  Through the save function rather than an INSERT ... SELECT, so a copy is
  held to exactly the rules an edit is — a source configured before a rule
  existed cannot smuggle a now-invalid value across.
*/
CREATE OR REPLACE FUNCTION core.usp_CopyBranchSettings(
    p_SourceBranchId text,
    p_TargetBranchId text,
    p_Actor          text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_Mode          varchar;
    v_ServedBy      varchar;
    v_Negative      boolean;
    v_Bill          varchar;
    v_PrintCustomer boolean;
    v_PrintGroups   boolean;
    v_Vat           numeric(5,2);
    v_IncludesVat   boolean;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = p_SourceBranchId)
       OR NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = p_TargetBranchId) THEN
        RAISE EXCEPTION 'No such branch.' USING DETAIL = '62050';
    END IF;

    /* Compared as the columns compare: the same branch id in another case is
       the same branch. */
    IF p_SourceBranchId::varchar COLLATE ci = p_TargetBranchId::varchar COLLATE ci THEN
        RAISE EXCEPTION 'Choose a different branch to copy from.' USING DETAIL = '62056';
    END IF;

    SELECT DefaultCustomerMode, ServedByRequirement, AllowNegativeStock, DefaultBillId,
           AutoPrintCustomer, AutoPrintGroups, VatRatePercent, PricesIncludeVat
    INTO v_Mode, v_ServedBy, v_Negative, v_Bill,
         v_PrintCustomer, v_PrintGroups, v_Vat, v_IncludesVat
    FROM core.BranchSettings WHERE BranchId = p_SourceBranchId;

    IF v_Mode IS NULL THEN
        RAISE EXCEPTION 'That branch has no settings to copy yet.' USING DETAIL = '62055';
    END IF;

    PERFORM core.usp_SaveBranchSettings(
        p_BranchId => p_TargetBranchId, p_DefaultCustomerMode => v_Mode::text,
        p_ServedByRequirement => v_ServedBy::text, p_AllowNegativeStock => v_Negative,
        p_DefaultBillId => v_Bill::text, p_AutoPrintCustomer => v_PrintCustomer,
        p_AutoPrintGroups => v_PrintGroups, p_VatRatePercent => v_Vat::numeric,
        p_PricesIncludeVat => v_IncludesVat, p_Actor => p_Actor);
END $$;

/*--------------------------------------------------------- save bill template */

CREATE OR REPLACE FUNCTION core.usp_SaveBillTemplate(
    p_BillId           text DEFAULT NULL,   -- null creates
    p_Name             text DEFAULT NULL,
    p_Audience         text DEFAULT NULL,
    p_PrintGroupId     text DEFAULT NULL,
    p_IsDefault        boolean DEFAULT false,
    p_PaperSize        text DEFAULT '80mm',
    p_BillLanguage     text DEFAULT 'both',
    p_HeaderAlignment  text DEFAULT 'center',
    p_LogoSize         text DEFAULT 'md',
    p_ShowLogo         boolean DEFAULT true,
    p_ShowCompanyName  boolean DEFAULT true,
    p_ShowDescription  boolean DEFAULT true,
    p_ShowVatNumber    boolean DEFAULT true,
    p_ShowCrNumber     boolean DEFAULT false,
    p_ShowAddress      boolean DEFAULT false,
    p_ShowItemName     boolean DEFAULT true,
    p_ShowSku          boolean DEFAULT false,
    p_ShowBarcode      boolean DEFAULT false,
    p_ShowUnitPrice    boolean DEFAULT true,
    p_ShowQuantity     boolean DEFAULT true,
    p_ShowLineTotal    boolean DEFAULT true,
    p_ShowLineDiscount boolean DEFAULT false,
    p_ShowSubtotal     boolean DEFAULT true,
    p_ShowDiscount     boolean DEFAULT true,
    p_ShowVat          boolean DEFAULT true,
    p_ShowGrandTotal   boolean DEFAULT true,
    p_ShowZatcaQr      boolean DEFAULT true,
    p_FooterAr         text DEFAULT NULL,
    p_FooterEn         text DEFAULT NULL,
    p_IsActive         boolean DEFAULT true)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_SavedId      varchar;
    v_PrintGroupId text := p_PrintGroupId;
BEGIN
    IF btrim(COALESCE(p_Name, '')) = '' THEN
        RAISE EXCEPTION 'A template needs a name.' USING DETAIL = '62020';
    END IF;

    /* The list checks ignore case, as SQL Server's collation did. */
    IF lower(p_PaperSize) NOT IN ('58mm', '80mm', 'a4') THEN
        RAISE EXCEPTION 'Paper size must be 58mm, 80mm or a4.' USING DETAIL = '62021';
    END IF;

    IF lower(p_Audience) NOT IN ('customer', 'group') THEN
        RAISE EXCEPTION 'A template is for the customer or for a print group.' USING DETAIL = '62022';
    END IF;

    IF lower(p_BillLanguage) NOT IN ('ar', 'en', 'both') THEN
        RAISE EXCEPTION 'Language must be ar, en or both.' USING DETAIL = '62027';
    END IF;

    IF lower(p_HeaderAlignment) NOT IN ('start', 'center', 'end')
       OR lower(p_LogoSize) NOT IN ('sm', 'md', 'lg') THEN
        RAISE EXCEPTION 'That header layout is not recognised.' USING DETAIL = '62028';
    END IF;

    /* A customer receipt carries the whole order, so a print group on it
       would mean nothing — and leaving one there makes resolving confusing. */
    IF lower(p_Audience) = 'customer' THEN v_PrintGroupId := NULL; END IF;

    IF lower(p_Audience) = 'group' AND v_PrintGroupId IS NULL THEN
        RAISE EXCEPTION 'Choose which print group this ticket is for.' USING DETAIL = '62023';
    END IF;

    IF v_PrintGroupId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.PrintGroup WHERE PrintGroupId = v_PrintGroupId) THEN
        RAISE EXCEPTION 'No such print group.' USING DETAIL = '62024';
    END IF;

    /*
      A customer receipt must show the total.

      Everything else is a layout preference; a receipt without a total is not a
      receipt, and a customer cannot check what they were charged.
    */
    IF lower(p_Audience) = 'customer' AND NOT p_ShowGrandTotal THEN
        RAISE EXCEPTION 'A customer receipt must show the total.' USING DETAIL = '62025';
    END IF;

    /*
      A customer receipt is a simplified tax invoice (ZATCA): it must carry the
      seller's VAT number, the VAT amount and the QR code. Those three are not
      layout preferences on a customer template, so they cannot be saved off.
      A kitchen or group ticket is not an invoice and stays free to hide them.
    */
    IF lower(p_Audience) = 'customer' AND NOT p_ShowVatNumber THEN
        RAISE EXCEPTION 'A customer receipt must show the VAT number.' USING DETAIL = '62031';
    END IF;

    IF lower(p_Audience) = 'customer' AND NOT p_ShowVat THEN
        RAISE EXCEPTION 'A customer receipt must show the VAT amount.' USING DETAIL = '62032';
    END IF;

    IF lower(p_Audience) = 'customer' AND NOT p_ShowZatcaQr THEN
        RAISE EXCEPTION 'A customer receipt must show the ZATCA QR code.' USING DETAIL = '62033';
    END IF;

    IF p_BillId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.BillTemplate WHERE BillId = p_BillId) THEN
        RAISE EXCEPTION 'No such template.' USING DETAIL = '62026';
    END IF;

    IF p_BillId IS NULL THEN
        v_SavedId := core.fn_NewId('bil_');

        INSERT INTO core.BillTemplate
            (BillId, Name, Audience, PrintGroupId, IsDefault, PaperSize, BillLanguage,
             HeaderAlignment, LogoSize,
             ShowLogo, ShowCompanyName, ShowDescription, ShowVatNumber, ShowCrNumber, ShowAddress,
             ShowItemName, ShowSku, ShowBarcode, ShowUnitPrice, ShowQuantity, ShowLineTotal,
             ShowLineDiscount, ShowSubtotal, ShowDiscount, ShowVat, ShowGrandTotal, ShowZatcaQr,
             FooterAr, FooterEn, IsActive)
        VALUES
            (v_SavedId, p_Name, p_Audience, v_PrintGroupId, p_IsDefault, p_PaperSize, p_BillLanguage,
             p_HeaderAlignment, p_LogoSize,
             p_ShowLogo, p_ShowCompanyName, p_ShowDescription, p_ShowVatNumber, p_ShowCrNumber, p_ShowAddress,
             p_ShowItemName, p_ShowSku, p_ShowBarcode, p_ShowUnitPrice, p_ShowQuantity, p_ShowLineTotal,
             p_ShowLineDiscount, p_ShowSubtotal, p_ShowDiscount, p_ShowVat, p_ShowGrandTotal, p_ShowZatcaQr,
             p_FooterAr, p_FooterEn, p_IsActive);
    ELSE
        v_SavedId := p_BillId;

        UPDATE core.BillTemplate
        SET Name = p_Name, Audience = p_Audience, PrintGroupId = v_PrintGroupId,
            IsDefault = p_IsDefault, PaperSize = p_PaperSize, BillLanguage = p_BillLanguage,
            HeaderAlignment = p_HeaderAlignment, LogoSize = p_LogoSize,
            ShowLogo = p_ShowLogo, ShowCompanyName = p_ShowCompanyName,
            ShowDescription = p_ShowDescription, ShowVatNumber = p_ShowVatNumber,
            ShowCrNumber = p_ShowCrNumber, ShowAddress = p_ShowAddress,
            ShowItemName = p_ShowItemName, ShowSku = p_ShowSku, ShowBarcode = p_ShowBarcode,
            ShowUnitPrice = p_ShowUnitPrice, ShowQuantity = p_ShowQuantity,
            ShowLineTotal = p_ShowLineTotal, ShowLineDiscount = p_ShowLineDiscount,
            ShowSubtotal = p_ShowSubtotal, ShowDiscount = p_ShowDiscount,
            ShowVat = p_ShowVat, ShowGrandTotal = p_ShowGrandTotal, ShowZatcaQr = p_ShowZatcaQr,
            FooterAr = p_FooterAr, FooterEn = p_FooterEn, IsActive = p_IsActive,
            UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE BillId = p_BillId;
    END IF;

    /* One default per audience. Two would make which one prints a matter of
       row order, and a receipt layout that changes at random is worse than
       the wrong layout consistently. */
    IF p_IsDefault THEN
        UPDATE core.BillTemplate
        SET IsDefault = false, UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE Audience = p_Audience AND BillId <> v_SavedId AND IsDefault;
    END IF;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*------------------------------------------------------- delete bill template */

/*
  A real delete. A template is layout, not history: a printed receipt does not
  record which template drew it, so removing one orphans nothing. What does
  point at a template — a branch's default bill — is refused rather than
  silently cleared, and so is the audience default, which is what prints when
  nothing more specific matches.
*/
CREATE OR REPLACE FUNCTION core.usp_DeleteBillTemplate(p_BillId text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_IsDefault boolean;
BEGIN
    SELECT IsDefault INTO v_IsDefault FROM core.BillTemplate WHERE BillId = p_BillId;

    IF v_IsDefault IS NULL THEN
        RAISE EXCEPTION 'No such template.' USING DETAIL = '62026';
    END IF;

    IF v_IsDefault THEN
        RAISE EXCEPTION 'Make another template the default before deleting this one.' USING DETAIL = '62029';
    END IF;

    IF EXISTS (SELECT 1 FROM core.BranchSettings WHERE DefaultBillId = p_BillId) THEN
        RAISE EXCEPTION 'A branch uses this as its default bill. Change that branch first.' USING DETAIL = '62030';
    END IF;

    DELETE FROM core.BillTemplate WHERE BillId = p_BillId;
END $$;

/*------------------------------------------------------- refresh notifications */

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

/*==============================================================================
  Devices
==============================================================================*/

/*------------------------------------------------------------------ register */

CREATE OR REPLACE FUNCTION device.usp_RegisterDevice(
    p_RegistrationCode text,
    p_SerialNumber     text,
    p_AndroidId        text DEFAULT NULL,
    p_DeviceModel      text DEFAULT NULL,
    p_AppVersion       text DEFAULT NULL,
    p_TokenHash        text DEFAULT NULL)
RETURNS TABLE (DeviceId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_DeviceId varchar;
BEGIN
    SELECT d.DeviceId INTO v_DeviceId FROM device.PosDevice AS d
    WHERE d.RegistrationCode = p_RegistrationCode;

    IF v_DeviceId IS NULL THEN
        RAISE EXCEPTION 'That registration code is not recognised.' USING DETAIL = '58000';
    END IF;

    IF EXISTS (SELECT 1 FROM device.PosDevice AS d
               WHERE d.DeviceId = v_DeviceId AND d.CodeExpiresAtUtc < now() AT TIME ZONE 'utc') THEN
        RAISE EXCEPTION 'That registration code has expired. Ask for a new one.' USING DETAIL = '58001';
    END IF;

    IF EXISTS (SELECT 1 FROM device.PosDevice AS d WHERE d.DeviceId = v_DeviceId AND NOT d.IsActive) THEN
        RAISE EXCEPTION 'This device has been deactivated.' USING DETAIL = '58002';
    END IF;

    /*
      A serial belongs to one device record.

      Re-registering the SAME terminal is fine — that is a reinstall. Presenting
      a different serial against a record that already has one means the code
      travelled, and enrolling a second till under one identity would make every
      heartbeat afterwards ambiguous.
    */
    IF EXISTS (SELECT 1 FROM device.PosDevice AS d
               WHERE d.SerialNumber = p_SerialNumber AND d.DeviceId <> v_DeviceId) THEN
        RAISE EXCEPTION 'This terminal is already registered as another device.' USING DETAIL = '58003';
    END IF;

    IF EXISTS (SELECT 1 FROM device.PosDevice AS d
               WHERE d.DeviceId = v_DeviceId
                 AND d.SerialNumber IS NOT NULL
                 AND d.SerialNumber <> p_SerialNumber) THEN
        RAISE EXCEPTION 'This code was issued for a different terminal.' USING DETAIL = '58004';
    END IF;

    UPDATE device.PosDevice AS d
    SET SerialNumber     = p_SerialNumber,
        AndroidId        = COALESCE(p_AndroidId, d.AndroidId),
        DeviceModel      = COALESCE(p_DeviceModel, d.DeviceModel),
        AppVersion       = COALESCE(p_AppVersion, d.AppVersion),
        TokenHash        = p_TokenHash,
        RegisteredAtUtc  = now() AT TIME ZONE 'utc',
        /* Consumed. Single use is what stops a shared code enrolling a
           second terminal tomorrow. */
        RegistrationCode = NULL,
        CodeExpiresAtUtc = NULL,
        UpdatedAtUtc     = now() AT TIME ZONE 'utc'
    WHERE d.DeviceId = v_DeviceId;

    INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
    VALUES (v_DeviceId, 'registered', 'info',
            'Device registered', 'تم تسجيل الجهاز');

    RETURN QUERY SELECT v_DeviceId;
END $$;

/*----------------------------------------------------------------- heartbeat */

/*
  One call does three things: records the state, answers with any queued
  commands, and tells the device how soon to come back.

  Folding the command collection into the heartbeat is the whole design. A
  separate poll would double the traffic to learn the same thing.

  One row per command to run, each carrying NextIntervalMs. With nothing to
  run there is still one row, its command columns NULL, so the interval always
  comes back (SQL Server returned it as an OUTPUT parameter beside the result
  set).
*/
CREATE OR REPLACE FUNCTION device.usp_RecordHeartbeat(
    p_DeviceId       text,
    p_PrinterStatus  text,
    p_PaperStatus    text,
    p_PrinterError   text DEFAULT NULL,
    p_BatteryPercent integer DEFAULT NULL,
    p_NetworkType    text DEFAULT NULL,
    p_AppVersion     text DEFAULT NULL)
RETURNS TABLE (NextIntervalMs integer, CommandId varchar, CommandType varchar, Payload text)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_WasPrinter     varchar;
    v_WasPaper       varchar;
    v_WasSeen        timestamp(0);
    v_Now            timestamp(3) := now() AT TIME ZONE 'utc';
    v_NextIntervalMs integer;
BEGIN
    SELECT d.PrinterStatus, d.PaperStatus, d.LastHeartbeatAtUtc
    INTO v_WasPrinter, v_WasPaper, v_WasSeen
    FROM device.PosDevice AS d WHERE d.DeviceId = p_DeviceId;

    UPDATE device.PosDevice AS d
    SET LastHeartbeatAtUtc = v_Now,
        PrinterStatus  = p_PrinterStatus,
        PaperStatus    = p_PaperStatus,
        PrinterError   = p_PrinterError,
        BatteryPercent = p_BatteryPercent,
        NetworkType    = p_NetworkType,
        AppVersion     = COALESCE(p_AppVersion, d.AppVersion)
    WHERE d.DeviceId = p_DeviceId;

    INSERT INTO device.DeviceHeartbeat
        (DeviceId, PrinterStatus, PaperStatus, PrinterError,
         BatteryPercent, NetworkType, AppVersion)
    VALUES
        (p_DeviceId, p_PrinterStatus, p_PaperStatus, p_PrinterError,
         p_BatteryPercent, p_NetworkType, p_AppVersion);

    /* An event per heartbeat would bury everything else. Only changes.
       Compared as the columns compare, case-insensitively. */
    IF v_WasPaper <> p_PaperStatus::varchar COLLATE ci
       AND lower(p_PaperStatus) IN ('low', 'empty') THEN
        INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
        VALUES (p_DeviceId, 'paper', 'warning',
                'Paper ' || p_PaperStatus, 'حالة الورق تغيّرت');
    END IF;

    IF v_WasPrinter <> p_PrinterStatus::varchar COLLATE ci
       AND lower(p_PrinterStatus) = 'error' THEN
        INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
        VALUES (p_DeviceId, 'printer', 'error',
                COALESCE(p_PrinterError, 'Printer error'), 'خطأ في الطابعة');
    END IF;

    /* Coming back after a gap is worth recording; it explains a missing
       receipt far better than an absence of rows. Seconds counted as DATEDIFF
       counted them: second boundaries crossed. */
    IF v_WasSeen IS NOT NULL
       AND extract(epoch FROM date_trunc('second', v_Now) - v_WasSeen) > 90 THEN
        INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
        VALUES (p_DeviceId, 'reconnected', 'info',
                'Back online after ' ||
                    trunc(extract(epoch FROM date_trunc('second', v_Now) - v_WasSeen))::bigint || 's',
                'عاد الاتصال');
    END IF;

    /* Anything queued is now the device's. */
    UPDATE device.DeviceCommand AS c
    SET Status = 'sent', SentAtUtc = v_Now
    WHERE c.DeviceId = p_DeviceId AND c.Status = 'pending'
      AND c.ExpiresAtUtc > v_Now;

    UPDATE device.DeviceCommand AS c
    SET Status = 'expired', CompletedAtUtc = v_Now,
        ResultMessage = 'The device did not collect this in time.'
    WHERE c.DeviceId = p_DeviceId AND c.Status IN ('pending', 'sent')
      AND c.ExpiresAtUtc <= v_Now;

    /*
      Come back sooner while there is work.

      Two seconds when something is outstanding, ten when idle. A ping then
      answers in about two seconds without holding a socket open all day — which
      is the compromise that makes polling acceptable here.
    */
    v_NextIntervalMs := CASE
        WHEN EXISTS (SELECT 1 FROM device.DeviceCommand AS c
                     WHERE c.DeviceId = p_DeviceId AND c.Status IN ('pending', 'sent'))
        THEN 2000 ELSE 10000 END;

    /* The commands to run, returned to the caller. */
    RETURN QUERY
    SELECT v_NextIntervalMs, c.CommandId, c.CommandType, c.Payload
    FROM (SELECT 1) AS one
    LEFT JOIN device.DeviceCommand AS c
           ON c.DeviceId = p_DeviceId AND c.Status = 'sent' AND c.CompletedAtUtc IS NULL
    ORDER BY c.QueuedAtUtc;
END $$;

/*------------------------------------------------------------ command result */

CREATE OR REPLACE FUNCTION device.usp_CompleteCommand(
    p_CommandId     text,
    p_DeviceId      text,
    p_Succeeded     boolean,
    p_ResultMessage text DEFAULT NULL,
    p_ResultData    text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_Queued timestamp(3);
    v_Now    timestamp(3) := now() AT TIME ZONE 'utc';
BEGIN
    SELECT QueuedAtUtc INTO v_Queued FROM device.DeviceCommand
    WHERE CommandId = p_CommandId AND DeviceId = p_DeviceId;

    IF v_Queued IS NULL THEN
        RAISE EXCEPTION 'No such command for this device.' USING DETAIL = '58010';
    END IF;

    UPDATE device.DeviceCommand
    SET Status         = CASE WHEN p_Succeeded THEN 'succeeded' ELSE 'failed' END,
        CompletedAtUtc = v_Now,
        Succeeded      = p_Succeeded,
        ResultMessage  = p_ResultMessage,
        ResultData     = p_ResultData,
        /* Queued to answered, as the admin experienced it. Measuring only the
           device's own work would report 40ms for a wait of several seconds. */
        RoundTripMs    = trunc(extract(epoch FROM v_Now - v_Queued) * 1000)::integer
    WHERE CommandId = p_CommandId;

    INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
    SELECT p_DeviceId, c.CommandType,
           CASE WHEN p_Succeeded THEN 'info' ELSE 'error' END,
           c.CommandType || ': ' || COALESCE(p_ResultMessage, 'done'),
           c.CommandType || ': ' || COALESCE(p_ResultMessage, 'تم')
    FROM device.DeviceCommand AS c WHERE c.CommandId = p_CommandId;
END $$;

/*------------------------------------------------------------------- record */

CREATE OR REPLACE FUNCTION device.usp_RecordAnnouncement(
    p_SerialNumber    text,
    p_ClaimedDeviceId text DEFAULT NULL,
    p_DeviceName      text DEFAULT NULL,
    p_Manufacturer    text DEFAULT NULL,
    p_DeviceModel     text DEFAULT NULL,
    p_AndroidId       text DEFAULT NULL,
    p_AppVersion      text DEFAULT NULL,
    p_LocalIpAddress  text DEFAULT NULL,
    p_NetworkName     text DEFAULT NULL,
    p_SourceIpAddress text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    /* One row per terminal, refreshed. A row per announcement would grow
       without bound for a device left switched on. */
    INSERT INTO device.DeviceAnnouncement AS target
        (SerialNumber, ClaimedDeviceId, DeviceName, Manufacturer, DeviceModel,
         AndroidId, AppVersion, LocalIpAddress, NetworkName, SourceIpAddress)
    VALUES
        (p_SerialNumber, p_ClaimedDeviceId, p_DeviceName, p_Manufacturer, p_DeviceModel,
         p_AndroidId, p_AppVersion, p_LocalIpAddress, p_NetworkName, p_SourceIpAddress)
    ON CONFLICT (SerialNumber) DO UPDATE SET
        ClaimedDeviceId = COALESCE(p_ClaimedDeviceId, target.ClaimedDeviceId),
        DeviceName      = COALESCE(p_DeviceName, target.DeviceName),
        Manufacturer    = COALESCE(p_Manufacturer, target.Manufacturer),
        DeviceModel     = COALESCE(p_DeviceModel, target.DeviceModel),
        AndroidId       = COALESCE(p_AndroidId, target.AndroidId),
        AppVersion      = COALESCE(p_AppVersion, target.AppVersion),
        LocalIpAddress  = p_LocalIpAddress,
        NetworkName     = p_NetworkName,
        SourceIpAddress = p_SourceIpAddress,
        LastSeenAtUtc   = now() AT TIME ZONE 'utc';
END $$;

/*------------------------------------------------------------------ discover */

/*
  What the admin sees.

  Recent announcements, each already matched against the registry so the modal
  can tell "new", "already yours" and "registered elsewhere" apart — which the
  brief rightly insists are different outcomes.
*/
CREATE OR REPLACE FUNCTION device.usp_DiscoverDevices(p_WithinSeconds integer DEFAULT 120)
RETURNS TABLE (
    SerialNumber        varchar,
    ClaimedDeviceId     varchar,
    DeviceName          varchar,
    Manufacturer        varchar,
    DeviceModel         varchar,
    AppVersion          varchar,
    LocalIpAddress      varchar,
    NetworkName         varchar,
    FirstSeenAtUtc      timestamp,
    LastSeenAtUtc       timestamp,
    SecondsSinceSeen    integer,
    MatchedDeviceId     varchar,
    MatchedDeviceName   varchar,
    MatchedBranchId     varchar,
    MatchedBranchNameEn varchar,
    DiscoveryStatus     varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    /* Whole seconds, as DATEDIFF(SECOND, ...) counted boundaries crossed. */
    v_Now timestamp := date_trunc('second', now() AT TIME ZONE 'utc');
BEGIN
    RETURN QUERY
    SELECT
        a.SerialNumber::varchar, a.ClaimedDeviceId::varchar, a.DeviceName::varchar,
        a.Manufacturer::varchar, a.DeviceModel::varchar, a.AppVersion::varchar,
        a.LocalIpAddress::varchar, a.NetworkName::varchar,
        a.FirstSeenAtUtc::timestamp, a.LastSeenAtUtc::timestamp,
        trunc(extract(epoch FROM v_Now - a.LastSeenAtUtc))::integer AS SecondsSinceSeen,

        d.DeviceId::varchar        AS MatchedDeviceId,
        d.DeviceName::varchar      AS MatchedDeviceName,
        d.BranchId::varchar        AS MatchedBranchId,
        b.NameEn::varchar          AS MatchedBranchNameEn,

        /*
          Three outcomes, kept apart.

          available          no record holds this serial — it can be registered
          already_registered this serial is already one of ours
          claimed_elsewhere  the record exists but was never completed here

          Collapsing these would let an admin register a second record for a
          terminal that already has one, and every heartbeat afterwards would be
          ambiguous.
        */
        (CASE
            WHEN d.DeviceId IS NULL THEN 'available'
            WHEN d.RegisteredAtUtc IS NOT NULL THEN 'already_registered'
            ELSE 'awaiting_registration'
        END)::varchar AS DiscoveryStatus
    FROM device.DeviceAnnouncement AS a
    LEFT JOIN device.PosDevice AS d ON d.SerialNumber = a.SerialNumber
    LEFT JOIN core.Branch     AS b ON b.BranchId = d.BranchId
    WHERE extract(epoch FROM v_Now - a.LastSeenAtUtc) <= p_WithinSeconds
    ORDER BY a.LastSeenAtUtc DESC;
END $$;

/*------------------------------------------------------------------ connect */

/*
  Bind a discovered terminal to a device record.

  Called after the challenge has been answered, and it re-checks rather than
  trusting the caller: a verification that happened is not the same as a
  verification that still applies.

  Returns one row: Blocked is NULL when the terminal was connected, otherwise
  the reason it was not.
*/
CREATE OR REPLACE FUNCTION device.usp_ConnectDiscovered(
    p_SerialNumber text,
    p_DeviceId     text,
    p_BranchId     text,
    p_Location     text DEFAULT NULL,
    p_DeviceName   text DEFAULT NULL,
    p_Actor        text DEFAULT NULL)
RETURNS TABLE (Blocked varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
BEGIN
    /* Already ours, and complete. Offer to open it, never to duplicate it. */
    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE SerialNumber = p_SerialNumber AND RegisteredAtUtc IS NOT NULL) THEN
        RETURN QUERY SELECT 'This terminal is already registered here.'::varchar;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM device.PosDevice WHERE DeviceId = p_DeviceId) THEN
        RETURN QUERY SELECT 'That device id is already in use.'::varchar;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM device.DeviceAnnouncement WHERE SerialNumber = p_SerialNumber) THEN
        RETURN QUERY SELECT 'That terminal has not announced itself recently.'::varchar;
        RETURN;
    END IF;

    /*
      A record and a code, in one step.

      The terminal is listening, so it collects the code on its next
      announcement and completes registration without anyone reading it
      aloud. The existing registration path is reused exactly — there is no
      second way to become registered, which is what the brief asks for.
    */
    INSERT INTO device.PosDevice
        (DeviceId, DeviceName, DeviceType, DeviceModel, SerialNumber, AndroidId,
         BranchId, Location, PaperWidth, RegistrationCode, CodeExpiresAtUtc,
         AppVersion, IsActive, CreatedBy)
    SELECT
        p_DeviceId, p_DeviceName, 'sunmi_v2', a.DeviceModel, p_SerialNumber, a.AndroidId,
        p_BranchId, p_Location, 80,
        /* Short-lived: the terminal is on the other end of this exchange
           and will collect it within seconds. Upper case, as NEWID() printed. */
        'DSC-' || upper(right(gen_random_uuid()::text, 4)),
        (now() AT TIME ZONE 'utc') + interval '10 minutes',
        a.AppVersion, true, p_Actor
    FROM device.DeviceAnnouncement AS a
    WHERE a.SerialNumber = p_SerialNumber;

    INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
    VALUES (p_DeviceId, 'created', 'info',
            'Created from network discovery', 'أُنشئ عبر الاكتشاف على الشبكة');

    RETURN QUERY SELECT NULL::varchar;
END $$;
