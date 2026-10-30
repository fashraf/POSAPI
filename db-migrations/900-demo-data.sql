/*==============================================================================
  Nazad POS — 900 · Demo data (optional, development and demos only)

  A working shop: a company, two branches, six staff, a mixed catalog,
  customers with balances, discounts, recurring payments and six months of
  balanced trading history posted through fin.usp_PostJournalEntry.

  Every demo account signs in with the password 1234 (ahmed owner, sara
  manager, yousef cashier, mona accountant, faisal cashier; khalid is an
  external maintenance account with no password).

  apply-migrations (.sh and .cmd) runs this only with --demo, and only on a database it
  has just created. Never on a live business: it would add a second company's
  worth of records and give known passwords to built-in accounts.
==============================================================================*/

/*==============================================================================
  SECTION: 09-seed-demo.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 09 · Demo data

  A working shop, not an empty prototype: two branches, staff, a mixed catalog
  of products and services, customers with real balances, and six months of
  trading so the charts and reports have something to draw.

  Safe to skip in production — nothing above depends on it.
==============================================================================*/


/* Company and branches ------------------------------------------------------*/

INSERT INTO core.Company
    (NameAr, NameEn, DescriptionAr, DescriptionEn, CrNumber, VatNumber, Phone, Email, Website,
     Street, District, City, PostalCode, Country)
VALUES
    ('متجر النور', 'Al Noor Store',
     'متجرك الموثوق في الحي', 'Your trusted neighbourhood store',
     '1010123456', '300000000000003', '+966 11 220 8899', 'hello@alnoor.sa', 'alnoor.sa',
     'طريق الملك فهد', 'العليا', 'الرياض', '12211', 'SA');

INSERT INTO core.Branch (BranchId, Code, NameAr, NameEn, Phone, AddressAr, AddressEn) VALUES
    ('brn_001', 'RUH-01', 'الرياض الرئيسي', 'Riyadh Main', '+966 11 220 8899',
     'طريق الملك فهد، العليا، الرياض', 'King Fahd Road, Al Olaya, Riyadh'),
    ('brn_002', 'JED-01', 'جدة',            'Jeddah',      '+966 12 660 4411',
     'طريق الأمير سلطان، الروضة، جدة', 'Prince Sultan Road, Al Rawdah, Jeddah');

INSERT INTO core.BranchSettings (BranchId, DefaultCustomerMode, ServedByRequirement) VALUES
    ('brn_001', 'walkin',   'optional'),
    ('brn_002', 'customer', 'required');

/* Users ---------------------------------------------------------------------*/

INSERT INTO core.AppUser
    (UserId, Username, NameAr, NameEn, Email, Phone, RoleId, Status, IsExternal, AccessExpiresOn, BaseSalaryH)
VALUES
    ('usr_001', 'ahmed',   'أحمد علي',      'Ahmed Ali',       'owner@demo.com',   '+966501234567', 'rol_owner',      'active',    false, NULL,         900000),
    ('usr_002', 'sara',    'سارة عبدالله',  'Sara Abdullah',   'manager@demo.com', '+966502345678', 'rol_manager',    'active',    false, NULL,         650000),
    ('usr_003', 'yousef',  'يوسف الحربي',   'Yousef Al Harbi', 'cashier@demo.com', '+966503456789', 'rol_cashier',    'active',    false, NULL,         400000),
    ('usr_004', 'mona',    'منى القحطاني',  'Mona Al Qahtani', 'mona@demo.com',    '+966504567890', 'rol_accountant', 'suspended', false, NULL,         550000),
    ('usr_005', 'khalid',  'خالد الدعم',    'Support Khalid',  'khalid@vendor.sa', '+966505678901', 'rol_maintenance','active',    true, '2026-12-31',      0),
    ('usr_006', 'faisal',  'فيصل النمر',    'Faisal Al Nimr',  'faisal@demo.com',  '+966506789012', 'rol_cashier',    'active',    false, NULL,         420000);

INSERT INTO core.UserBranch (UserId, BranchId) VALUES
    ('usr_001', 'brn_001'), ('usr_001', 'brn_002'),
    ('usr_002', 'brn_001'), ('usr_002', 'brn_002'),
    ('usr_003', 'brn_001'),
    ('usr_004', 'brn_001'),
    ('usr_005', 'brn_001'),
    ('usr_006', 'brn_002');

/* Sara can void a sale even though her role cannot. */
INSERT INTO core.UserPermissionOverride (UserId, PermissionKey, Effect) VALUES
    ('usr_002', 'sales.void', 'grant');

/* Categories, print groups, vendors -----------------------------------------*/

INSERT INTO core.Category (CategoryId, NameAr, NameEn, SortOrder) VALUES
    ('cat_drinks',   'المشروبات',       'Drinks',        1),
    ('cat_food',     'الأطعمة',         'Food',          2),
    ('cat_personal', 'العناية الشخصية', 'Personal Care', 3),
    ('cat_grooming', 'الحلاقة',         'Grooming',      4),
    ('cat_laundry',  'المغسلة',         'Laundry',       5),
    ('cat_prof',     'خدمات مهنية',     'Professional',  6);

INSERT INTO core.PrintGroup (PrintGroupId, NameAr, NameEn, TicketTitle, SortOrder) VALUES
    ('pgr_kitchen', 'المطبخ',    'Kitchen', 'KITCHEN', 1),
    ('pgr_bbq',     'المشويات',  'BBQ',     'BBQ',     2),
    ('pgr_bar',     'المشروبات', 'Bar',     'BAR',     3),
    ('pgr_packing', 'التغليف',   'Packing', 'PACKING', 4);

INSERT INTO core.Vendor (VendorId, NameAr, NameEn, ContactPerson, Phone, Email, VatNumber, PaymentTermDays) VALUES
    ('ven_001', 'الرياض للتجارة',      'Al Riyadh Trading',      'Omar Nasser',  '+966112223344', 'sales@riyadhtrading.sa', '300000000000013', 30),
    ('ven_002', 'الخليج للتوريدات',    'Gulf Supplies',          'Layla Hassan', '+966113334455', 'info@gulfsupplies.sa',   '300000000000023', 15),
    ('ven_003', 'التوزيع الحديث',      'Modern Distribution Co.','Tariq Saeed',  '+966114445566', 'orders@moderndist.sa',   '300000000000033',  0);

/* Catalog -------------------------------------------------------------------*/

INSERT INTO core.CatalogItem
    (ItemId, Kind, NameAr, NameEn, Sku, Barcode, CategoryId, VendorId, PrintGroupId,
     PriceH, CostH, TracksStock, ReorderLevel, RequiresPreparation)
VALUES
    ('itm_001', 'product', 'كوكا كولا ٣٣٠ مل',  'Coca Cola 330ml',   'BEV-001', '6281000010001', 'cat_drinks',   'ven_001', 'pgr_bar',     300,   180, true, 24, false),
    ('itm_002', 'product', 'بيبسي ٣٣٠ مل',      'Pepsi 330ml',       'BEV-002', '6281000010002', 'cat_drinks',   'ven_001', 'pgr_bar',     300,   175, true, 24, false),
    ('itm_003', 'product', 'قهوة عربية',        'Arabic Coffee',     'BEV-003', '6281000010003', 'cat_drinks',   'ven_002', 'pgr_bar',    1200,   450, true, 10, true),
    ('itm_004', 'product', 'برجر دجاج',         'Chicken Burger',    'FOO-001', '6281000020001', 'cat_food',     'ven_002', 'pgr_kitchen',2500,  1050, true, 15, true),
    ('itm_005', 'product', 'شامبو ٤٠٠ مل',      'Shampoo 400ml',     'PER-001', '6281000030001', 'cat_personal', 'ven_003', NULL,          2800,  1800, true, 12, false),
    ('itm_006', 'product', 'جل شعر',            'Hair Gel',          'PER-002', '6281000030002', 'cat_personal', 'ven_003', NULL,          1900,  1150, true, 10, false),
    ('itm_007', 'product', 'ماء ٦٠٠ مل',        'Water 600ml',       'BEV-004', '6281000010004', 'cat_drinks',   'ven_001', 'pgr_bar',     150,    70, true, 48, false),
    ('itm_008', 'product', 'تمر سكري ١ كجم',    'Sukkari Dates 1kg', 'FOO-002', '6281000020002', 'cat_food',     'ven_002', 'pgr_packing',4500,  3000, true,  8, false),
    ('itm_009', 'product', 'رغوة حلاقة',        'Shaving Foam',      'PER-003', '6281000030003', 'cat_personal', 'ven_003', NULL,          2200,  1400, true,  6, false),
    ('itm_010', 'service', 'قص شعر',            'Haircut',           NULL, NULL, 'cat_grooming', NULL, NULL,       4000,  1000, false, 0, false),
    ('itm_011', 'service', 'تشذيب اللحية',      'Beard Trim',        NULL, NULL, 'cat_grooming', NULL, NULL,       2500,   600, false, 0, false),
    ('itm_012', 'service', 'غسيل شعر',          'Hair Wash',         NULL, NULL, 'cat_grooming', NULL, NULL,       1500,   400, false, 0, false),
    ('itm_013', 'service', 'غسيل قميص',         'Shirt Washing',     NULL, NULL, 'cat_laundry',  NULL, NULL,       1500,   500, false, 0, false),
    ('itm_014', 'service', 'تنظيف بدلة جاف',    'Suit Dry Cleaning', NULL, NULL, 'cat_laundry',  NULL, NULL,       4500,  1600, false, 0, false),
    ('itm_015', 'service', 'استشارة',           'Consultation',      NULL, NULL, 'cat_prof',     NULL, NULL,      15000,     0, false, 0, false);

UPDATE core.CatalogItem SET IsActive = false WHERE ItemId = 'itm_009';

/* A third language, to prove the overflow table works end to end. */
INSERT INTO core.Translation (EntityType, EntityKey, FieldName, LanguageCode, Value) VALUES
    ('CatalogItem', 'itm_010', 'Name', 'ur', 'بال کٹنگ'),
    ('CatalogItem', 'itm_010', 'Name', 'hi', 'बाल कटवाना'),
    ('CatalogItem', 'itm_010', 'Name', 'tl', 'Gupit'),
    ('CatalogItem', 'itm_013', 'Name', 'ur', 'قمیض دھلائی'),
    ('CatalogItem', 'itm_013', 'Name', 'hi', 'शर्ट धुलाई'),
    ('CatalogItem', 'itm_013', 'Name', 'tl', 'Labada ng Polo'),
    ('Category',    'cat_drinks', 'Name', 'ur', 'مشروبات'),
    ('Category',    'cat_food',   'Name', 'ur', 'کھانا');

/* Opening stock, per branch. */
INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
SELECT i.ItemId, b.BranchId,
       CASE WHEN b.BranchId = 'brn_001' THEN 40 ELSE 22 END
FROM core.CatalogItem AS i
CROSS JOIN core.Branch AS b
WHERE i.TracksStock;

INSERT INTO inv.StockMovement (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH, ReasonEn, ReasonAr, Actor)
SELECT s.ItemId, s.BranchId, 'opening', s.Quantity, s.Quantity, i.CostH,
       'Opening stock', 'رصيد افتتاحي', 'System'
FROM inv.StockLevel AS s
JOIN core.CatalogItem AS i ON i.ItemId = s.ItemId;

/* Customers -----------------------------------------------------------------*/

INSERT INTO core.Customer (CustomerId, NameAr, NameEn, Phone, Email, VatNumber, CustomerType, CreditLimitH, BalanceH) VALUES
    ('cus_001', 'أحمد علي',       'Ahmed Ali',        '+966551112233', 'ahmed@example.sa', NULL,                'individual',  100000,  24500),
    ('cus_002', 'محمد حسن',       'Mohammed Hassan',  '+966552223344', NULL,                NULL,                'individual',   50000,      0),
    ('cus_003', 'سارة عبدالله',   'Sara Abdullah',    '+966553334455', 'sara@example.sa',  NULL,                'individual',   75000,   8000),
    ('cus_004', 'مؤسسة النخبة',   'Al Nukhba Est.',   '+966114445566', 'ap@nukhba.sa',     '300000000000043', 'business',    500000, 182000);

/* Discounts -----------------------------------------------------------------*/

INSERT INTO sales.Discount
    (DiscountId, NameAr, NameEn, DiscountType, Value, MaxDiscountH, MinSubtotalH,
     ApprovalAboveH, AppliesTo, IsAutomatic, AllowStacking, ActiveDays, IsActive)
VALUES
    ('dsc_001', 'خصم العملاء',      'Customer discount',  'percentage',  500, 5000,      0, NULL,  'all',      false, false, '',      true),
    ('dsc_002', 'خصم الموظفين',     'Employee discount',  'percentage', 1000, 10000,     0, 5000, 'all',      false, false, '',      true),
    ('dsc_003', 'عرض ٢٠ ريال',      'SAR 20 promo',       'fixed',      2000, NULL,  10000, NULL,  'all',      false, false, '',      true),
    ('dsc_004', 'خصم الخدمات',      'Services discount',  'percentage', 1500, 8000,      0, 3000, 'services', false, false, '',      true),
    ('dsc_005', 'تصفية',            'Clearance',          'percentage', 2500, NULL,      0, NULL,  'products', false, false, '',      false),
    ('dsc_006', 'اليوم الوطني',     'National Day',       'percentage', 1000, NULL,      0, NULL,  'all',      true, false, '',      true),
    ('dsc_007', 'عرض نهاية الأسبوع','Weekend offer',      'percentage',  700, 6000,  5000, NULL,  'all',      true, false, '4,5,6', true);

/* Bill templates ------------------------------------------------------------*/

INSERT INTO core.BillTemplate
    (BillId, Name, Audience, PrintGroupId, IsDefault, PaperSize, BillLanguage,
     ShowLogo, ShowVatNumber, ShowCrNumber, ShowUnitPrice, ShowLineTotal,
     ShowSubtotal, ShowDiscount, ShowVat, ShowGrandTotal, ShowZatcaQr)
VALUES
    /* Operational tickets carry the item and the count. Money on a kitchen
       ticket is noise the cook has to read past. */
    ('bil_kitchen', 'Kitchen ticket', 'group', 'pgr_kitchen', false, '58mm', 'both', false,false,false,false,false,false,false,false,false,false),
    ('bil_bbq',     'BBQ ticket',     'group', 'pgr_bbq',     false, '58mm', 'both', false,false,false,false,false,false,false,false,false,false),
    ('bil_bar',     'Bar ticket',     'group', 'pgr_bar',     false, '58mm', 'both', false,false,false,false,false,false,false,false,false,false);

UPDATE core.BranchSettings SET DefaultBillId = 'bil_customer';

/* Expense categories and recurring payments ---------------------------------*/


/* No salaries schedule: payroll posts salaries (6200) itself, and a recurring
   payment for them would count the same pay twice (011 refuses one). */
INSERT INTO fin.RecurringPayment
    (RecurringId, DescriptionAr, DescriptionEn, CategoryId, BranchId, AmountH, Frequency, NextDueOn, LastPaidOn, PaymentMethod)
VALUES
    ('rec_rent',   'إيجار المحل',       'Shop rent',             'exc_rent', 'brn_001', 800000, 'monthly', (now() AT TIME ZONE 'utc')::date + 3, (now() AT TIME ZONE 'utc')::date - 27, 'bank'),
    ('rec_elec',   'الكهرباء',          'Electricity',           'exc_util', 'brn_001', 185000, 'monthly', (now() AT TIME ZONE 'utc')::date + 5, (now() AT TIME ZONE 'utc')::date - 25, 'bank'),
    ('rec_net',    'الإنترنت',          'Internet',              'exc_util', NULL,        30000, 'monthly', (now() AT TIME ZONE 'utc')::date + 22, (now() AT TIME ZONE 'utc')::date - 8, 'bank'),
    ('rec_ins',    'تأمين المنشأة',     'Business insurance',    'exc_ins',  NULL,       450000, 'yearly',  (now() AT TIME ZONE 'utc')::date + 18, NULL,                                  'bank'),
    /* Deliberately overdue, so the red state is visible on first run. */
    ('rec_soft',   'اشتراك البرنامج',   'Software subscription', 'exc_sub',  NULL,        45000, 'monthly', (now() AT TIME ZONE 'utc')::date - 2, (now() AT TIME ZONE 'utc')::date - 32, 'card');

/* Commission ----------------------------------------------------------------*/

INSERT INTO fin.CommissionRule (RuleId, Basis, Value) VALUES
    ('crl_default', 'percentage', 1000),   -- everyone, every service: 10%
    ('crl_barbers', 'percentage', 2000);   -- named barbers on named services: 20%

INSERT INTO fin.CommissionRuleUser (RuleId, UserId) VALUES
    ('crl_barbers', 'usr_003'),
    ('crl_barbers', 'usr_006');

INSERT INTO fin.CommissionRuleItem (RuleId, ItemId) VALUES
    ('crl_barbers', 'itm_010'),
    ('crl_barbers', 'itm_011');

DO $$ BEGIN RAISE NOTICE '09 · Demo data ready.'; END $$;

/*==============================================================================
  SECTION: 10-seed-history.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 10 · Six months of trading history

  Posted through fin.usp_PostJournalEntry rather than inserted directly, so the
  seed passes the same balance checks as live data. If this script runs clean,
  the posting path works.

  Shaped so the reports have a story: Riyadh turns over roughly twice Jeddah and
  keeps a healthier margin, which gives the branch comparison something real.
==============================================================================*/


DO $$
DECLARE
    v_MonthOffset integer := 5;          -- start six months back
    v_EntryId     varchar;
    v_MonthStart  date;
    v_PostedAt    timestamp(3);
    v_BranchIx    integer;
    v_BranchId    text;
    v_BaseH       bigint;
    v_GrossH      bigint;
    v_TaxH        bigint;
    v_NetH        bigint;
    v_CardH       bigint;
    v_CashH       bigint;
    v_CredH       bigint;
    v_CogsH       bigint;
    v_RentH       bigint;
    v_SalH        bigint;
    v_UtilH       bigint;
    v_FeeH        bigint;
    v_Lines       fin.JournalLineTable[];
BEGIN
    WHILE v_MonthOffset >= 0 LOOP
        v_MonthStart := date_trunc('month', (now() AT TIME ZONE 'utc')
                                            - make_interval(months => v_MonthOffset))::date;
        v_PostedAt := v_MonthStart::timestamp(3);

        v_BranchIx := 1;

        WHILE v_BranchIx <= 2 LOOP
            v_BranchId := CASE v_BranchIx WHEN 1 THEN 'brn_001' ELSE 'brn_002' END;

            /* Gross takings, rising gently, Riyadh roughly two thirds.
               trunc(): CAST(... AS BIGINT) in SQL Server cut the fraction off. */
            v_BaseH  := 6800000 + (5 - v_MonthOffset) * 450000;
            v_GrossH := CASE v_BranchIx WHEN 1
                             THEN trunc(v_BaseH * 0.66)::bigint
                             ELSE trunc(v_BaseH * 0.34)::bigint END;

            v_TaxH  := fin.fn_VatFromGross(v_GrossH, 15.00);
            v_NetH  := v_GrossH - v_TaxH;
            v_CardH := trunc(v_GrossH * 0.54)::bigint;
            v_CashH := trunc(v_GrossH * 0.38)::bigint;
            v_CredH := v_GrossH - v_CardH - v_CashH;
            v_CogsH := trunc(v_NetH * 0.42)::bigint;

            /* --- the month's sales --- */
            v_Lines := ARRAY[
                ('1000', v_CashH, 0, 'Cash'),
                ('1150', v_CardH, 0, 'Card clearing'),
                ('1400', v_CredH, 0, 'Customer credit'),
                ('4100', 0, v_NetH,  'Sales'),
                ('2100', 0, v_TaxH,  'Output VAT'),
                ('5100', v_CogsH, 0, 'Cost of goods sold'),
                ('1200', 0, v_CogsH, 'Inventory')]::fin.JournalLineTable[];

            SELECT p.EntryId INTO v_EntryId FROM fin.usp_PostJournalEntry(
                p_Kind => 'sale', p_DescriptionEn => 'Monthly sales', p_DescriptionAr => 'مبيعات الشهر',
                p_SourceReference => 'HIST-SALES', p_BranchId => v_BranchId, p_Actor => 'System',
                p_PostedAtUtc => v_PostedAt, p_Lines => to_jsonb(v_Lines)) AS p;

            /* --- rent, weighted so Jeddah's margin is visibly thinner --- */
            v_RentH := CASE v_BranchIx WHEN 1 THEN 800000 ELSE 620000 END;
            v_Lines := ARRAY[
                ('6000', v_RentH, 0, 'Rent'), ('1000', 0, v_RentH, 'Cash')]::fin.JournalLineTable[];

            SELECT p.EntryId INTO v_EntryId FROM fin.usp_PostJournalEntry(
                p_Kind => 'expense_recognition', p_DescriptionEn => 'Rent', p_DescriptionAr => 'الإيجار',
                p_SourceReference => 'HIST-RENT', p_BranchId => v_BranchId, p_Actor => 'System',
                p_PostedAtUtc => v_PostedAt, p_Lines => to_jsonb(v_Lines)) AS p;

            /* --- salaries --- */
            v_SalH := CASE v_BranchIx WHEN 1 THEN 1240000 ELSE 1180000 END;
            v_Lines := ARRAY[
                ('6200', v_SalH, 0, 'Salaries'), ('1100', 0, v_SalH, 'Bank')]::fin.JournalLineTable[];

            SELECT p.EntryId INTO v_EntryId FROM fin.usp_PostJournalEntry(
                p_Kind => 'expense_recognition', p_DescriptionEn => 'Salaries', p_DescriptionAr => 'الرواتب',
                p_SourceReference => 'HIST-SAL', p_BranchId => v_BranchId, p_Actor => 'System',
                p_PostedAtUtc => v_PostedAt, p_Lines => to_jsonb(v_Lines)) AS p;

            /* --- utilities --- */
            v_UtilH := CASE v_BranchIx WHEN 1 THEN 215000 ELSE 268000 END;
            v_Lines := ARRAY[
                ('6000', v_UtilH, 0, 'Utilities'), ('1000', 0, v_UtilH, 'Cash')]::fin.JournalLineTable[];

            SELECT p.EntryId INTO v_EntryId FROM fin.usp_PostJournalEntry(
                p_Kind => 'expense_recognition', p_DescriptionEn => 'Utilities', p_DescriptionAr => 'المرافق',
                p_SourceReference => 'HIST-UTIL', p_BranchId => v_BranchId, p_Actor => 'System',
                p_PostedAtUtc => v_PostedAt, p_Lines => to_jsonb(v_Lines)) AS p;

            /* --- the bank settles the card takings, less its fee --- */
            v_FeeH := trunc(v_CardH * 0.015)::bigint;
            v_Lines := ARRAY[
                ('1100', v_CardH - v_FeeH, 0, 'Bank deposit'),
                ('6100', v_FeeH, 0, 'Card fees'),
                ('1150', 0, v_CardH, 'Card clearing')]::fin.JournalLineTable[];

            SELECT p.EntryId INTO v_EntryId FROM fin.usp_PostJournalEntry(
                p_Kind => 'card_settlement', p_DescriptionEn => 'Card settlement', p_DescriptionAr => 'تسوية الشبكة',
                p_SourceReference => 'HIST-SET', p_BranchId => v_BranchId, p_Actor => 'System',
                p_PostedAtUtc => v_PostedAt, p_Lines => to_jsonb(v_Lines)) AS p;

            v_BranchIx := v_BranchIx + 1;
        END LOOP;

        v_MonthOffset := v_MonthOffset - 1;
    END LOOP;
END $$;

/* A prepaid expense, to exercise the accrual path: a year of insurance paid up
   front is one cash movement and twelve monthly costs. */
INSERT INTO fin.Expense
    (ExpenseId, Reference, CategoryId, BranchId, DescriptionAr, DescriptionEn,
     AmountH, VatH, PaymentMethod, PaidOn, Recognition, PeriodStart, PeriodEnd, CreatedBy)
VALUES
    ('exp_insurance_demo', 'EXP-401', 'exc_ins', 'brn_001',
     'تأمين سنوي', 'Annual insurance',
     1200000, 0, 'bank',
     make_date(extract(year FROM now() AT TIME ZONE 'utc')::int, 1, 1), 'yearly',
     make_date(extract(year FROM now() AT TIME ZONE 'utc')::int, 1, 1),
     make_date(extract(year FROM now() AT TIME ZONE 'utc')::int, 12, 31),
     'System');

/* Through the same posting as a recorded expense (011): the payment to
   prepaid in January, then one release into 6000 on the first of each month,
   so the ledger-based P&L shows 1,000 in every month of the year.

   Written out here rather than called (the SQL Server file ran
   fin.usp_PostExpenseLedger): demo data depends on nothing but
   fin.usp_PostJournalEntry. The steps are the same — the payment on the day
   it left, parked in prepaid (1500) because a yearly expense spreads; the
   recognition rows (fin.usp_BuildExpenseRecognition: the net amount split
   evenly across the months of the period, the remainder on the last); then one
   release per month, dated the first of that month. */
DO $$
DECLARE
    v_InsId          text := 'exp_insurance_demo';
    v_AmountH        bigint;
    v_VatH           bigint;
    v_NetH           bigint;
    v_PaidOn         date;
    v_PeriodFrom     date;
    v_PeriodTo       date;
    v_PaymentMethod  text;
    v_PaymentAccount text;
    v_BranchId       text;
    v_AccountCode    text;
    v_DescriptionEn  text;
    v_DescriptionAr  text;
    v_EntryId        varchar;
    v_Slice          record;
BEGIN
    SELECT e.AmountH, e.VatH, e.PaidOn, e.PeriodStart, e.PeriodEnd, e.PaymentMethod, e.BranchId,
           c.AccountCode, COALESCE(e.DescriptionEn, e.Reference), e.DescriptionAr
    INTO v_AmountH, v_VatH, v_PaidOn, v_PeriodFrom, v_PeriodTo, v_PaymentMethod, v_BranchId,
         v_AccountCode, v_DescriptionEn, v_DescriptionAr
    FROM fin.Expense AS e
    JOIN fin.ExpenseCategory AS c ON c.CategoryId = e.CategoryId
    WHERE e.ExpenseId = v_InsId;

    v_NetH := v_AmountH - v_VatH;
    v_PaymentAccount := CASE v_PaymentMethod WHEN 'cash' THEN '1000'
                                             WHEN 'credit' THEN '2000'
                                             ELSE '1100' END;

    /* The payment leaves on the date it left, whatever period the cost
       belongs to. Anything spread over time parks in prepaid first. */
    SELECT p.EntryId INTO v_EntryId FROM fin.usp_PostJournalEntry(
        p_Kind => 'expense', p_DescriptionEn => v_DescriptionEn, p_DescriptionAr => v_DescriptionAr,
        p_SourceReference => v_InsId, p_BranchId => v_BranchId, p_Actor => 'System',
        p_PostedAtUtc => v_PaidOn::timestamp(3),
        p_Lines => to_jsonb(ARRAY[
            ('1500', v_NetH, 0, v_DescriptionEn),
            ('1300', v_VatH, 0, 'Input VAT'),
            (v_PaymentAccount, 0, v_AmountH, v_PaymentMethod)]::fin.JournalLineTable[])) AS p;

    /* One recognition row per month of the period. */
    INSERT INTO fin.ExpenseRecognition (ExpenseId, PeriodMonth, AmountH)
    SELECT v_InsId,
           to_char(m.M, 'YYYY-MM'),
           CASE WHEN m.Rn = m.Total
                THEN v_NetH - (v_NetH / m.Total) * (m.Total - 1)   -- remainder on the last month
                ELSE v_NetH / m.Total
           END
    FROM (
        SELECT g.M::date AS M,
               ROW_NUMBER() OVER (ORDER BY g.M) AS Rn,
               COUNT(*) OVER () AS Total
        FROM generate_series(date_trunc('month', v_PeriodFrom),
                             date_trunc('month', v_PeriodTo),
                             interval '1 month') AS g (M)
    ) AS m;

    /* Release prepaid into the expense account, month by month, each on
       the first day of the month it belongs to. */
    FOR v_Slice IN
        SELECT PeriodMonth, AmountH FROM fin.ExpenseRecognition
        WHERE ExpenseId = v_InsId AND AmountH > 0
        ORDER BY PeriodMonth
    LOOP
        SELECT p.EntryId INTO v_EntryId FROM fin.usp_PostJournalEntry(
            p_Kind => 'expense_recognition',
            p_DescriptionEn => v_DescriptionEn, p_DescriptionAr => v_DescriptionAr,
            p_SourceReference => v_InsId, p_BranchId => v_BranchId, p_Actor => 'System',
            p_PostedAtUtc => (v_Slice.PeriodMonth || '-01')::date::timestamp(3),
            p_Lines => to_jsonb(ARRAY[
                (v_AccountCode, v_Slice.AmountH, 0, v_Slice.PeriodMonth),
                ('1500', 0, v_Slice.AmountH, 'Prepaid release')]::fin.JournalLineTable[])) AS p;
    END LOOP;
END $$;

DO $$ BEGIN RAISE NOTICE '10 · Trading history ready.'; END $$;

/*------------------------------------------------------------------ sanity */

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM fin.vw_TrialBalanceCheck) THEN
        RAISE EXCEPTION 'Ledger does not balance after seeding. Investigate before use.' USING DETAIL = '51100';
    END IF;

    IF (SELECT SUM(AmountH) FROM fin.ExpenseRecognition WHERE ExpenseId = 'exp_insurance_demo')
       IS DISTINCT FROM 1200000 THEN
        RAISE EXCEPTION 'Expense recognition slices do not sum to the amount paid.' USING DETAIL = '51101';
    END IF;

    RAISE NOTICE '    Ledger balances.';
    RAISE NOTICE '    Recognition slices reconcile.';
END $$;

/*------------------------------------------------------- user defaults and logins */

/* Each demo user lands in the first branch they work at. */
UPDATE core.AppUser AS u
SET DefaultBranchId = (SELECT ub.BranchId FROM core.UserBranch AS ub
                       WHERE ub.UserId = u.UserId ORDER BY ub.BranchId LIMIT 1)
WHERE u.DefaultBranchId IS NULL;

/* Every demo account gets the password 1234. */
WITH DevPasswords (UserId, PasswordHash, PasswordSalt) AS
(
    VALUES
    ('usr_001', 'pbkdf2$210000$qZqQrmEZg/a0vYFT4EwxFkXkjiv9l3RvTSKK7VMBp1I=', '9/+4xax1zmYyqtIJb8PoUw=='),
    ('usr_002', 'pbkdf2$210000$dDdnRScHH9/dcz6zJQPjdTnOopc+WHoJG8aFanEzADM=', 'IpkoigRknMnmg62ZGvcuGA=='),
    ('usr_003', 'pbkdf2$210000$lexo/qs7fb3hHDXefDjKKWXYW8F1lEjwexKTpJ529P4=', 'BblS/wJ5t+BzU0uG4C4STg=='),
    ('usr_004', 'pbkdf2$210000$gHaqGnI+jKyQrShyOqEeefIDlAr3841qSWt9nmQKwSQ=', 'M+76N5jye/RyXIQ8s0lwFQ=='),
    ('usr_006', 'pbkdf2$210000$a8ABqd1tYWOWvM9G6aGDXX+wCE7DFA/uej920gTQZQQ=', 'khpIdNYVfF33LNiK11ZgeQ==')
)
UPDATE core.AppUser AS u
SET PasswordHash = d.PasswordHash,
    PasswordSalt = d.PasswordSalt,
    UpdatedAtUtc = now() AT TIME ZONE 'utc',
    UpdatedBy    = 'dev-seed'
FROM DevPasswords AS d
WHERE d.UserId = u.UserId;

DO $$ BEGIN RAISE NOTICE '900 · Demo data loaded. Demo accounts sign in with 1234.'; END $$;

/*------------------------------------------------- realign the sequences */

/* The rows above carry literal numbers (EXP-401, the branch ids), while the
   sequences that number new rows still sit at their starting values. Without
   this, the next expense recorded draws EXP-401 and fails as a duplicate.
   The same block as migration 010 did on SQL Server — on a new database the
   migrations run before this file, so they cannot see these rows. */

DO $$
DECLARE
    v_Map     record;
    v_MaxUsed bigint;
    v_Last    bigint;
    v_Called  boolean;
    v_Next    bigint;
BEGIN
    FOR v_Map IN
        SELECT * FROM (VALUES
            ('core.BranchSequence',        'core.Branch',        'BranchId',    'brn_'),
            ('fin.JournalSequence',        'fin.JournalEntry',   'Reference',   'JE-'),
            ('fin.JournalSequence',        'fin.JournalEntry',   'EntryId',     'jrn_'),
            ('fin.SettlementSequence',     'fin.CardSettlement', 'Reference',   'SET-'),
            ('fin.PayrollSequence',        'fin.PayrollRun',     'Reference',   'PR-'),
            ('fin.ExpenseSequence',        'fin.Expense',        'Reference',   'EXP-'),
            ('inv.VendorPaymentSequence',  'inv.VendorPayment',  'Reference',   'VP-'),
            ('inv.PurchaseSequence',       'inv.Purchase',       'Reference',   'PO-'),
            ('sales.CreditNoteSequence',   'sales.SaleReturn',   'NoteNumber',  'CN-')
        ) AS m (SequenceName, TableName, ColumnName, Prefix)
    LOOP
        CONTINUE WHEN to_regclass(v_Map.TableName) IS NULL OR to_regclass(v_Map.SequenceName) IS NULL;

        /* Names as written, unquoted, so they fold to lower case like every
           other name (format's %I would quote them: hence lower()).
           Only values that are the prefix followed by digits alone count:
           anything else (a hand-made reference) was never drawn from it.
           COLLATE "default": a regular expression refuses the ci collation;
           ~* keeps the match case-insensitive, as LIKE was under CI_AS. */
        EXECUTE format(
            'SELECT MAX(substr(%1$I COLLATE "default", %2$s)::bigint) FROM %3$s
             WHERE %1$I COLLATE "default" ~* %4$L',
            lower(v_Map.ColumnName), length(v_Map.Prefix) + 1, v_Map.TableName,
            '^' || v_Map.Prefix || '[0-9]{1,18}$')
        INTO v_MaxUsed;

        /* The next number the sequence would hand out. Moving it to
           MaxUsed + 1 only when that is not already ahead keeps every number
           unique. */
        EXECUTE format('SELECT last_value, is_called FROM %s', v_Map.SequenceName)
        INTO v_Last, v_Called;
        v_Next := CASE WHEN v_Called THEN v_Last + 1 ELSE v_Last END;

        IF v_MaxUsed IS NOT NULL AND v_MaxUsed >= v_Next THEN
            PERFORM setval(v_Map.SequenceName, v_MaxUsed, true);
            RAISE NOTICE '    % restarted at % (%.% uses up to %).',
                v_Map.SequenceName, v_MaxUsed + 1, v_Map.TableName, v_Map.ColumnName, v_MaxUsed;
        END IF;
    END LOOP;
END $$;

/* The gap-free invoice counter (002 starts it at 1001) continues one past the
   highest invoice number already issued, so the next sale cannot collide. */
UPDATE sales.InvoiceCounter AS c
SET NextNumber   = s.MaxUsed + 1,
    UpdatedAtUtc = now() AT TIME ZONE 'utc'
FROM (
    SELECT MAX(substr(InvoiceNumber COLLATE "default", length(ic.Prefix) + 1)::bigint) AS MaxUsed
    FROM sales.Sale, sales.InvoiceCounter AS ic
    WHERE ic.CounterKey = 'invoice'
      AND InvoiceNumber COLLATE "default" ~* ('^' || ic.Prefix || '[0-9]{1,18}$')
) AS s
WHERE c.CounterKey = 'invoice'
  AND s.MaxUsed >= c.NextNumber;

/* Identity columns number themselves; none of the rows above gave one
   explicitly, but if a later edit does, this keeps the next one clear. */
DO $$
DECLARE
    v_Col record;
BEGIN
    FOR v_Col IN
        SELECT n.nspname AS SchemaName, c.relname AS TableName, a.attname AS ColumnName
        FROM pg_attribute AS a
        JOIN pg_class AS c ON c.oid = a.attrelid
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE a.attidentity <> '' AND c.relkind = 'r' AND NOT a.attisdropped
          AND n.nspname IN ('audit', 'core', 'device', 'fin', 'inv', 'sales')
    LOOP
        /* Only forward: a sequence already past the highest id stays put. */
        EXECUTE format(
            'SELECT setval(x.Seq, x.MaxUsed)
             FROM (SELECT pg_get_serial_sequence(%1$L, %2$L) AS Seq, MAX(%3$I) AS MaxUsed FROM %4$I.%5$I) AS x
             WHERE x.MaxUsed > COALESCE((SELECT q.last_value FROM pg_sequences AS q
                                         WHERE format(%6$L, q.schemaname, q.sequencename) = x.Seq), 0)',
            v_Col.SchemaName || '.' || v_Col.TableName, v_Col.ColumnName, v_Col.ColumnName,
            v_Col.SchemaName, v_Col.TableName, '%I.%I');
    END LOOP;
END $$;

DO $$ BEGIN RAISE NOTICE '900 · Sequences realigned above the demo rows.'; END $$;
