/*==============================================================================
  Nazad POS — 900 · Demo data (optional, development and demos only)

  A working shop: a company, two branches, six staff, a mixed catalog,
  customers with balances, discounts, recurring payments and six months of
  balanced trading history posted through fin.usp_PostJournalEntry.

  Every demo account signs in with the password 1234 (ahmed owner, sara
  manager, yousef cashier, mona accountant, faisal cashier; khalid is an
  external maintenance account with no password).

  apply-migrations.cmd runs this only with --demo, and only on a database it
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

USE POSMAIN;
GO

/* Company and branches ------------------------------------------------------*/

INSERT INTO core.Company
    (NameAr, NameEn, DescriptionAr, DescriptionEn, CrNumber, VatNumber, Phone, Email, Website,
     Street, District, City, PostalCode, Country)
VALUES
    (N'متجر النور', N'Al Noor Store',
     N'متجرك الموثوق في الحي', N'Your trusted neighbourhood store',
     N'1010123456', N'300000000000003', N'+966 11 220 8899', N'hello@alnoor.sa', N'alnoor.sa',
     N'طريق الملك فهد', N'العليا', N'الرياض', N'12211', N'SA');
GO

INSERT INTO core.Branch (BranchId, Code, NameAr, NameEn, Phone, AddressAr, AddressEn) VALUES
    (N'brn_001', N'RUH-01', N'الرياض الرئيسي', N'Riyadh Main', N'+966 11 220 8899',
     N'طريق الملك فهد، العليا، الرياض', N'King Fahd Road, Al Olaya, Riyadh'),
    (N'brn_002', N'JED-01', N'جدة',            N'Jeddah',      N'+966 12 660 4411',
     N'طريق الأمير سلطان، الروضة، جدة', N'Prince Sultan Road, Al Rawdah, Jeddah');
GO

INSERT INTO core.BranchSettings (BranchId, DefaultCustomerMode, ServedByRequirement) VALUES
    (N'brn_001', N'walkin',   N'optional'),
    (N'brn_002', N'customer', N'required');
GO

/* Users ---------------------------------------------------------------------*/

INSERT INTO core.AppUser
    (UserId, Username, NameAr, NameEn, Email, Phone, RoleId, Status, IsExternal, AccessExpiresOn, BaseSalaryH)
VALUES
    (N'usr_001', N'ahmed',   N'أحمد علي',      N'Ahmed Ali',       N'owner@demo.com',   N'+966501234567', N'rol_owner',      N'active',    0, NULL,         900000),
    (N'usr_002', N'sara',    N'سارة عبدالله',  N'Sara Abdullah',   N'manager@demo.com', N'+966502345678', N'rol_manager',    N'active',    0, NULL,         650000),
    (N'usr_003', N'yousef',  N'يوسف الحربي',   N'Yousef Al Harbi', N'cashier@demo.com', N'+966503456789', N'rol_cashier',    N'active',    0, NULL,         400000),
    (N'usr_004', N'mona',    N'منى القحطاني',  N'Mona Al Qahtani', N'mona@demo.com',    N'+966504567890', N'rol_accountant', N'suspended', 0, NULL,         550000),
    (N'usr_005', N'khalid',  N'خالد الدعم',    N'Support Khalid',  N'khalid@vendor.sa', N'+966505678901', N'rol_maintenance',N'active',    1, '2026-12-31',      0),
    (N'usr_006', N'faisal',  N'فيصل النمر',    N'Faisal Al Nimr',  N'faisal@demo.com',  N'+966506789012', N'rol_cashier',    N'active',    0, NULL,         420000);
GO

INSERT INTO core.UserBranch (UserId, BranchId) VALUES
    (N'usr_001', N'brn_001'), (N'usr_001', N'brn_002'),
    (N'usr_002', N'brn_001'), (N'usr_002', N'brn_002'),
    (N'usr_003', N'brn_001'),
    (N'usr_004', N'brn_001'),
    (N'usr_005', N'brn_001'),
    (N'usr_006', N'brn_002');
GO

/* Sara can void a sale even though her role cannot. */
INSERT INTO core.UserPermissionOverride (UserId, PermissionKey, Effect) VALUES
    (N'usr_002', N'sales.void', N'grant');
GO

/* Categories, print groups, vendors -----------------------------------------*/

INSERT INTO core.Category (CategoryId, NameAr, NameEn, SortOrder) VALUES
    (N'cat_drinks',   N'المشروبات',       N'Drinks',        1),
    (N'cat_food',     N'الأطعمة',         N'Food',          2),
    (N'cat_personal', N'العناية الشخصية', N'Personal Care', 3),
    (N'cat_grooming', N'الحلاقة',         N'Grooming',      4),
    (N'cat_laundry',  N'المغسلة',         N'Laundry',       5),
    (N'cat_prof',     N'خدمات مهنية',     N'Professional',  6);
GO

INSERT INTO core.PrintGroup (PrintGroupId, NameAr, NameEn, TicketTitle, SortOrder) VALUES
    (N'pgr_kitchen', N'المطبخ',    N'Kitchen', N'KITCHEN', 1),
    (N'pgr_bbq',     N'المشويات',  N'BBQ',     N'BBQ',     2),
    (N'pgr_bar',     N'المشروبات', N'Bar',     N'BAR',     3),
    (N'pgr_packing', N'التغليف',   N'Packing', N'PACKING', 4);
GO

INSERT INTO core.Vendor (VendorId, NameAr, NameEn, ContactPerson, Phone, Email, VatNumber, PaymentTermDays) VALUES
    (N'ven_001', N'الرياض للتجارة',      N'Al Riyadh Trading',      N'Omar Nasser',  N'+966112223344', N'sales@riyadhtrading.sa', N'300000000000013', 30),
    (N'ven_002', N'الخليج للتوريدات',    N'Gulf Supplies',          N'Layla Hassan', N'+966113334455', N'info@gulfsupplies.sa',   N'300000000000023', 15),
    (N'ven_003', N'التوزيع الحديث',      N'Modern Distribution Co.',N'Tariq Saeed',  N'+966114445566', N'orders@moderndist.sa',   N'300000000000033',  0);
GO

/* Catalog -------------------------------------------------------------------*/

INSERT INTO core.CatalogItem
    (ItemId, Kind, NameAr, NameEn, Sku, Barcode, CategoryId, VendorId, PrintGroupId,
     PriceH, CostH, TracksStock, ReorderLevel, RequiresPreparation)
VALUES
    (N'itm_001', N'product', N'كوكا كولا ٣٣٠ مل',  N'Coca Cola 330ml',   N'BEV-001', N'6281000010001', N'cat_drinks',   N'ven_001', N'pgr_bar',     300,   180, 1, 24, 0),
    (N'itm_002', N'product', N'بيبسي ٣٣٠ مل',      N'Pepsi 330ml',       N'BEV-002', N'6281000010002', N'cat_drinks',   N'ven_001', N'pgr_bar',     300,   175, 1, 24, 0),
    (N'itm_003', N'product', N'قهوة عربية',        N'Arabic Coffee',     N'BEV-003', N'6281000010003', N'cat_drinks',   N'ven_002', N'pgr_bar',    1200,   450, 1, 10, 1),
    (N'itm_004', N'product', N'برجر دجاج',         N'Chicken Burger',    N'FOO-001', N'6281000020001', N'cat_food',     N'ven_002', N'pgr_kitchen',2500,  1050, 1, 15, 1),
    (N'itm_005', N'product', N'شامبو ٤٠٠ مل',      N'Shampoo 400ml',     N'PER-001', N'6281000030001', N'cat_personal', N'ven_003', NULL,          2800,  1800, 1, 12, 0),
    (N'itm_006', N'product', N'جل شعر',            N'Hair Gel',          N'PER-002', N'6281000030002', N'cat_personal', N'ven_003', NULL,          1900,  1150, 1, 10, 0),
    (N'itm_007', N'product', N'ماء ٦٠٠ مل',        N'Water 600ml',       N'BEV-004', N'6281000010004', N'cat_drinks',   N'ven_001', N'pgr_bar',     150,    70, 1, 48, 0),
    (N'itm_008', N'product', N'تمر سكري ١ كجم',    N'Sukkari Dates 1kg', N'FOO-002', N'6281000020002', N'cat_food',     N'ven_002', N'pgr_packing',4500,  3000, 1,  8, 0),
    (N'itm_009', N'product', N'رغوة حلاقة',        N'Shaving Foam',      N'PER-003', N'6281000030003', N'cat_personal', N'ven_003', NULL,          2200,  1400, 1,  6, 0),
    (N'itm_010', N'service', N'قص شعر',            N'Haircut',           NULL, NULL, N'cat_grooming', NULL, NULL,       4000,  1000, 0, 0, 0),
    (N'itm_011', N'service', N'تشذيب اللحية',      N'Beard Trim',        NULL, NULL, N'cat_grooming', NULL, NULL,       2500,   600, 0, 0, 0),
    (N'itm_012', N'service', N'غسيل شعر',          N'Hair Wash',         NULL, NULL, N'cat_grooming', NULL, NULL,       1500,   400, 0, 0, 0),
    (N'itm_013', N'service', N'غسيل قميص',         N'Shirt Washing',     NULL, NULL, N'cat_laundry',  NULL, NULL,       1500,   500, 0, 0, 0),
    (N'itm_014', N'service', N'تنظيف بدلة جاف',    N'Suit Dry Cleaning', NULL, NULL, N'cat_laundry',  NULL, NULL,       4500,  1600, 0, 0, 0),
    (N'itm_015', N'service', N'استشارة',           N'Consultation',      NULL, NULL, N'cat_prof',     NULL, NULL,      15000,     0, 0, 0, 0);
GO

UPDATE core.CatalogItem SET IsActive = 0 WHERE ItemId = N'itm_009';
GO

/* A third language, to prove the overflow table works end to end. */
INSERT INTO core.Translation (EntityType, EntityKey, FieldName, LanguageCode, Value) VALUES
    (N'CatalogItem', N'itm_010', N'Name', N'ur', N'بال کٹنگ'),
    (N'CatalogItem', N'itm_010', N'Name', N'hi', N'बाल कटवाना'),
    (N'CatalogItem', N'itm_010', N'Name', N'tl', N'Gupit'),
    (N'CatalogItem', N'itm_013', N'Name', N'ur', N'قمیض دھلائی'),
    (N'CatalogItem', N'itm_013', N'Name', N'hi', N'शर्ट धुलाई'),
    (N'CatalogItem', N'itm_013', N'Name', N'tl', N'Labada ng Polo'),
    (N'Category',    N'cat_drinks', N'Name', N'ur', N'مشروبات'),
    (N'Category',    N'cat_food',   N'Name', N'ur', N'کھانا');
GO

/* Opening stock, per branch. */
INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
SELECT i.ItemId, b.BranchId,
       CASE WHEN b.BranchId = N'brn_001' THEN 40 ELSE 22 END
FROM core.CatalogItem AS i
CROSS JOIN core.Branch AS b
WHERE i.TracksStock = 1;
GO

INSERT INTO inv.StockMovement (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH, ReasonEn, ReasonAr, Actor)
SELECT s.ItemId, s.BranchId, N'opening', s.Quantity, s.Quantity, i.CostH,
       N'Opening stock', N'رصيد افتتاحي', N'System'
FROM inv.StockLevel AS s
JOIN core.CatalogItem AS i ON i.ItemId = s.ItemId;
GO

/* Customers -----------------------------------------------------------------*/

INSERT INTO core.Customer (CustomerId, NameAr, NameEn, Phone, Email, VatNumber, CustomerType, CreditLimitH, BalanceH) VALUES
    (N'cus_001', N'أحمد علي',       N'Ahmed Ali',        N'+966551112233', N'ahmed@example.sa', NULL,                N'individual',  100000,  24500),
    (N'cus_002', N'محمد حسن',       N'Mohammed Hassan',  N'+966552223344', NULL,                NULL,                N'individual',   50000,      0),
    (N'cus_003', N'سارة عبدالله',   N'Sara Abdullah',    N'+966553334455', N'sara@example.sa',  NULL,                N'individual',   75000,   8000),
    (N'cus_004', N'مؤسسة النخبة',   N'Al Nukhba Est.',   N'+966114445566', N'ap@nukhba.sa',     N'300000000000043', N'business',    500000, 182000);
GO

/* Discounts -----------------------------------------------------------------*/

INSERT INTO sales.Discount
    (DiscountId, NameAr, NameEn, DiscountType, Value, MaxDiscountH, MinSubtotalH,
     ApprovalAboveH, AppliesTo, IsAutomatic, AllowStacking, ActiveDays, IsActive)
VALUES
    (N'dsc_001', N'خصم العملاء',      N'Customer discount',  N'percentage',  500, 5000,      0, NULL,  N'all',      0, 0, N'',      1),
    (N'dsc_002', N'خصم الموظفين',     N'Employee discount',  N'percentage', 1000, 10000,     0, 5000, N'all',      0, 0, N'',      1),
    (N'dsc_003', N'عرض ٢٠ ريال',      N'SAR 20 promo',       N'fixed',      2000, NULL,  10000, NULL,  N'all',      0, 0, N'',      1),
    (N'dsc_004', N'خصم الخدمات',      N'Services discount',  N'percentage', 1500, 8000,      0, 3000, N'services', 0, 0, N'',      1),
    (N'dsc_005', N'تصفية',            N'Clearance',          N'percentage', 2500, NULL,      0, NULL,  N'products', 0, 0, N'',      0),
    (N'dsc_006', N'اليوم الوطني',     N'National Day',       N'percentage', 1000, NULL,      0, NULL,  N'all',      1, 0, N'',      1),
    (N'dsc_007', N'عرض نهاية الأسبوع',N'Weekend offer',      N'percentage',  700, 6000,  5000, NULL,  N'all',      1, 0, N'4,5,6', 1);
GO

/* Bill templates ------------------------------------------------------------*/

INSERT INTO core.BillTemplate
    (BillId, Name, Audience, PrintGroupId, IsDefault, PaperSize, BillLanguage,
     ShowLogo, ShowVatNumber, ShowCrNumber, ShowUnitPrice, ShowLineTotal,
     ShowSubtotal, ShowDiscount, ShowVat, ShowGrandTotal, ShowZatcaQr)
VALUES
    /* Operational tickets carry the item and the count. Money on a kitchen
       ticket is noise the cook has to read past. */
    (N'bil_kitchen', N'Kitchen ticket', N'group', N'pgr_kitchen', 0, N'58mm', N'both', 0,0,0,0,0,0,0,0,0,0),
    (N'bil_bbq',     N'BBQ ticket',     N'group', N'pgr_bbq',     0, N'58mm', N'both', 0,0,0,0,0,0,0,0,0,0),
    (N'bil_bar',     N'Bar ticket',     N'group', N'pgr_bar',     0, N'58mm', N'both', 0,0,0,0,0,0,0,0,0,0);
GO

UPDATE core.BranchSettings SET DefaultBillId = N'bil_customer';
GO

/* Expense categories and recurring payments ---------------------------------*/

GO

/* No salaries schedule: payroll posts salaries (6200) itself, and a recurring
   payment for them would count the same pay twice (011 refuses one). */
INSERT INTO fin.RecurringPayment
    (RecurringId, DescriptionAr, DescriptionEn, CategoryId, BranchId, AmountH, Frequency, NextDueOn, LastPaidOn, PaymentMethod)
VALUES
    (N'rec_rent',   N'إيجار المحل',       N'Shop rent',             N'exc_rent', N'brn_001', 800000, N'monthly', DATEADD(DAY,  3, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY, -27, CAST(SYSUTCDATETIME() AS DATE)), N'bank'),
    (N'rec_elec',   N'الكهرباء',          N'Electricity',           N'exc_util', N'brn_001', 185000, N'monthly', DATEADD(DAY,  5, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY, -25, CAST(SYSUTCDATETIME() AS DATE)), N'bank'),
    (N'rec_net',    N'الإنترنت',          N'Internet',              N'exc_util', NULL,        30000, N'monthly', DATEADD(DAY, 22, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY,  -8, CAST(SYSUTCDATETIME() AS DATE)), N'bank'),
    (N'rec_ins',    N'تأمين المنشأة',     N'Business insurance',    N'exc_ins',  NULL,       450000, N'yearly',  DATEADD(DAY, 18, CAST(SYSUTCDATETIME() AS DATE)), NULL,                                              N'bank'),
    /* Deliberately overdue, so the red state is visible on first run. */
    (N'rec_soft',   N'اشتراك البرنامج',   N'Software subscription', N'exc_sub',  NULL,        45000, N'monthly', DATEADD(DAY, -2, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY, -32, CAST(SYSUTCDATETIME() AS DATE)), N'card');
GO

/* Commission ----------------------------------------------------------------*/

INSERT INTO fin.CommissionRule (RuleId, Basis, Value) VALUES
    (N'crl_default', N'percentage', 1000),   -- everyone, every service: 10%
    (N'crl_barbers', N'percentage', 2000);   -- named barbers on named services: 20%
GO

INSERT INTO fin.CommissionRuleUser (RuleId, UserId) VALUES
    (N'crl_barbers', N'usr_003'),
    (N'crl_barbers', N'usr_006');

INSERT INTO fin.CommissionRuleItem (RuleId, ItemId) VALUES
    (N'crl_barbers', N'itm_010'),
    (N'crl_barbers', N'itm_011');
GO

PRINT N'09 · Demo data ready.';
GO

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

USE POSMAIN;
GO

SET NOCOUNT ON;
GO

DECLARE @MonthOffset INT = 5;          -- start six months back
DECLARE @EntryId NVARCHAR(40);

WHILE @MonthOffset >= 0
BEGIN
    DECLARE @MonthStart DATE =
        DATEFROMPARTS(YEAR(DATEADD(MONTH, -@MonthOffset, SYSUTCDATETIME())),
                      MONTH(DATEADD(MONTH, -@MonthOffset, SYSUTCDATETIME())), 1);
    DECLARE @PostedAt DATETIME2(3) = CAST(@MonthStart AS DATETIME2(3));

    DECLARE @BranchIx INT = 1;

    WHILE @BranchIx <= 2
    BEGIN
        DECLARE @BranchId NVARCHAR(40) = CASE @BranchIx WHEN 1 THEN N'brn_001' ELSE N'brn_002' END;

        /* Gross takings, rising gently, Riyadh roughly two thirds. */
        DECLARE @BaseH BIGINT = 6800000 + (5 - @MonthOffset) * 450000;
        DECLARE @GrossH BIGINT = CASE @BranchIx WHEN 1
                                      THEN CAST(@BaseH * 0.66 AS BIGINT)
                                      ELSE CAST(@BaseH * 0.34 AS BIGINT) END;

        DECLARE @TaxH  BIGINT = fin.fn_VatFromGross(@GrossH, 15.00);
        DECLARE @NetH  BIGINT = @GrossH - @TaxH;
        DECLARE @CardH BIGINT = CAST(@GrossH * 0.54 AS BIGINT);
        DECLARE @CashH BIGINT = CAST(@GrossH * 0.38 AS BIGINT);
        DECLARE @CredH BIGINT = @GrossH - @CardH - @CashH;
        DECLARE @CogsH BIGINT = CAST(@NetH * 0.42 AS BIGINT);

        DECLARE @Lines fin.JournalLineTable;

        /* --- the month's sales --- */
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1000', @CashH, 0, N'Cash'),
            (N'1150', @CardH, 0, N'Card clearing'),
            (N'1400', @CredH, 0, N'Customer credit'),
            (N'4100', 0, @NetH,  N'Sales'),
            (N'2100', 0, @TaxH,  N'Output VAT'),
            (N'5100', @CogsH, 0, N'Cost of goods sold'),
            (N'1200', 0, @CogsH, N'Inventory');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'sale', @DescriptionEn = N'Monthly sales', @DescriptionAr = N'مبيعات الشهر',
            @SourceReference = N'HIST-SALES', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        /* --- rent, weighted so Jeddah's margin is visibly thinner --- */
        DECLARE @RentH BIGINT = CASE @BranchIx WHEN 1 THEN 800000 ELSE 620000 END;
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'6000', @RentH, 0, N'Rent'), (N'1000', 0, @RentH, N'Cash');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense_recognition', @DescriptionEn = N'Rent', @DescriptionAr = N'الإيجار',
            @SourceReference = N'HIST-RENT', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        /* --- salaries --- */
        DECLARE @SalH BIGINT = CASE @BranchIx WHEN 1 THEN 1240000 ELSE 1180000 END;
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'6200', @SalH, 0, N'Salaries'), (N'1100', 0, @SalH, N'Bank');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense_recognition', @DescriptionEn = N'Salaries', @DescriptionAr = N'الرواتب',
            @SourceReference = N'HIST-SAL', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        /* --- utilities --- */
        DECLARE @UtilH BIGINT = CASE @BranchIx WHEN 1 THEN 215000 ELSE 268000 END;
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'6000', @UtilH, 0, N'Utilities'), (N'1000', 0, @UtilH, N'Cash');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense_recognition', @DescriptionEn = N'Utilities', @DescriptionAr = N'المرافق',
            @SourceReference = N'HIST-UTIL', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        /* --- the bank settles the card takings, less its fee --- */
        DECLARE @FeeH BIGINT = CAST(@CardH * 0.015 AS BIGINT);
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1100', @CardH - @FeeH, 0, N'Bank deposit'),
            (N'6100', @FeeH, 0, N'Card fees'),
            (N'1150', 0, @CardH, N'Card clearing');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'card_settlement', @DescriptionEn = N'Card settlement', @DescriptionAr = N'تسوية الشبكة',
            @SourceReference = N'HIST-SET', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        SET @BranchIx += 1;
    END

    SET @MonthOffset -= 1;
END
GO

/* A prepaid expense, to exercise the accrual path: a year of insurance paid up
   front is one cash movement and twelve monthly costs. */
DECLARE @InsId NVARCHAR(40) = N'exp_insurance_demo';

INSERT INTO fin.Expense
    (ExpenseId, Reference, CategoryId, BranchId, DescriptionAr, DescriptionEn,
     AmountH, VatH, PaymentMethod, PaidOn, Recognition, PeriodStart, PeriodEnd, CreatedBy)
VALUES
    (@InsId, N'EXP-401', N'exc_ins', N'brn_001',
     N'تأمين سنوي', N'Annual insurance',
     1200000, 0, N'bank',
     DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 1, 1), N'yearly',
     DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 1, 1),
     DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 12, 31),
     N'System');

/* Through the same posting as a recorded expense (011): the payment to
   prepaid in January, then one release into 6000 on the first of each month,
   so the ledger-based P&L shows 1,000 in every month of the year. */
EXEC fin.usp_PostExpenseLedger @ExpenseId = @InsId, @Actor = N'System';
GO

PRINT N'10 · Trading history ready.';
GO

/*------------------------------------------------------------------ sanity */

DECLARE @Unbalanced INT = (SELECT COUNT(*) FROM fin.vw_TrialBalanceCheck);
IF @Unbalanced > 0
    THROW 51100, N'Ledger does not balance after seeding. Investigate before use.', 1;

DECLARE @Slices BIGINT = (SELECT SUM(AmountH) FROM fin.ExpenseRecognition WHERE ExpenseId = N'exp_insurance_demo');
IF @Slices <> 1200000
    THROW 51101, N'Expense recognition slices do not sum to the amount paid.', 1;

PRINT N'    Ledger balances.';
PRINT N'    Recognition slices reconcile.';
GO

/*------------------------------------------------------- user defaults and logins */

USE POSMAIN;
GO

/* Each demo user lands in the first branch they work at. */
UPDATE u
SET DefaultBranchId = (SELECT TOP (1) ub.BranchId FROM core.UserBranch AS ub
                       WHERE ub.UserId = u.UserId ORDER BY ub.BranchId)
FROM core.AppUser AS u
WHERE u.DefaultBranchId IS NULL;
GO

/* Every demo account gets the password 1234. */
;WITH DevPasswords (UserId, PasswordHash, PasswordSalt) AS
(
    SELECT * FROM (VALUES
    (N'usr_001', N'pbkdf2$210000$qZqQrmEZg/a0vYFT4EwxFkXkjiv9l3RvTSKK7VMBp1I=', N'9/+4xax1zmYyqtIJb8PoUw=='),
    (N'usr_002', N'pbkdf2$210000$dDdnRScHH9/dcz6zJQPjdTnOopc+WHoJG8aFanEzADM=', N'IpkoigRknMnmg62ZGvcuGA=='),
    (N'usr_003', N'pbkdf2$210000$lexo/qs7fb3hHDXefDjKKWXYW8F1lEjwexKTpJ529P4=', N'BblS/wJ5t+BzU0uG4C4STg=='),
    (N'usr_004', N'pbkdf2$210000$gHaqGnI+jKyQrShyOqEeefIDlAr3841qSWt9nmQKwSQ=', N'M+76N5jye/RyXIQ8s0lwFQ=='),
    (N'usr_006', N'pbkdf2$210000$a8ABqd1tYWOWvM9G6aGDXX+wCE7DFA/uej920gTQZQQ=', N'khpIdNYVfF33LNiK11ZgeQ==')
    ) AS v (UserId, PasswordHash, PasswordSalt)
)
UPDATE u
SET PasswordHash = d.PasswordHash,
    PasswordSalt = d.PasswordSalt,
    UpdatedAtUtc = SYSUTCDATETIME(),
    UpdatedBy    = N'dev-seed'
FROM core.AppUser AS u
JOIN DevPasswords AS d ON d.UserId = u.UserId;
GO
GO

PRINT N'900 · Demo data loaded. Demo accounts sign in with 1234.';
GO

/*------------------------------------------------- realign the sequences */

/* The rows above carry literal numbers (EXP-401, the branch ids), while the
   sequences that number new rows still sit at their starting values. Without
   this, the next expense recorded draws EXP-401 and fails as a duplicate.
   The same block as migration 010 — that one runs before this file on a new
   database, so it cannot see these rows. */

USE POSMAIN;
GO

SET NOCOUNT ON;
GO

DECLARE @Map TABLE
(
    SequenceName SYSNAME       NOT NULL,   -- schema.name
    TableName    NVARCHAR(256) NOT NULL,   -- schema.table
    ColumnName   SYSNAME       NOT NULL,
    Prefix       NVARCHAR(10)  NOT NULL    -- the text before the number
);

INSERT INTO @Map (SequenceName, TableName, ColumnName, Prefix) VALUES
    (N'core.BranchSequence',          N'core.Branch',         N'BranchId',    N'brn_'),
    (N'fin.JournalSequence',          N'fin.JournalEntry',    N'Reference',   N'JE-'),
    (N'fin.JournalSequence',          N'fin.JournalEntry',    N'EntryId',     N'jrn_'),
    (N'fin.SettlementSequence',       N'fin.CardSettlement',  N'Reference',   N'SET-'),
    (N'fin.PayrollSequence',          N'fin.PayrollRun',      N'Reference',   N'PR-'),
    (N'fin.ExpenseSequence',          N'fin.Expense',         N'Reference',   N'EXP-'),
    (N'inv.VendorPaymentSequence',    N'inv.VendorPayment',   N'Reference',   N'VP-'),
    (N'inv.PurchaseSequence',         N'inv.Purchase',        N'Reference',   N'PO-'),
    (N'sales.CreditNoteSequence',     N'sales.SaleReturn',    N'NoteNumber',  N'CN-');

DECLARE @Seq SYSNAME, @Table NVARCHAR(256), @Column SYSNAME, @Prefix NVARCHAR(10),
        @Sql NVARCHAR(MAX), @Like NVARCHAR(20), @MaxUsed BIGINT, @Current BIGINT;

DECLARE map CURSOR LOCAL FAST_FORWARD FOR
    SELECT SequenceName, TableName, ColumnName, Prefix FROM @Map;

OPEN map;
FETCH NEXT FROM map INTO @Seq, @Table, @Column, @Prefix;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(@Table, N'U') IS NOT NULL
       AND EXISTS (SELECT 1 FROM sys.sequences WHERE object_id = OBJECT_ID(@Seq))
    BEGIN
        /* Only values that are the prefix followed by digits alone count:
           anything else (a hand-made reference) was never drawn from it. */
        SET @Sql = N'SELECT @MaxUsed = MAX(TRY_CAST(SUBSTRING(' + QUOTENAME(@Column) + N', '
                 + CAST(LEN(@Prefix) + 1 AS NVARCHAR(10)) + N', 40) AS BIGINT)) FROM '
                 + QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(PARSENAME(@Table, 1))
                 + N' WHERE ' + QUOTENAME(@Column) + N' LIKE @Like'
                 + N' AND SUBSTRING(' + QUOTENAME(@Column) + N', '
                 + CAST(LEN(@Prefix) + 1 AS NVARCHAR(10)) + N', 40) NOT LIKE N''%[^0-9]%'';';

        SET @MaxUsed = NULL;
        SET @Like = @Prefix + N'%';
        EXEC sys.sp_executesql @Sql, N'@Like NVARCHAR(20), @MaxUsed BIGINT OUTPUT',
             @Like = @Like, @MaxUsed = @MaxUsed OUTPUT;

        /* current_value is the last number issued (or the start, if none has
           been). Restarting at MaxUsed + 1 only when that is not already
           ahead keeps every number unique. */
        SELECT @Current = CAST(current_value AS BIGINT)
        FROM sys.sequences WHERE object_id = OBJECT_ID(@Seq);

        IF @MaxUsed IS NOT NULL AND @MaxUsed >= @Current
        BEGIN
            SET @Sql = N'ALTER SEQUENCE ' + QUOTENAME(PARSENAME(@Seq, 2)) + N'.' + QUOTENAME(PARSENAME(@Seq, 1))
                     + N' RESTART WITH ' + CAST(@MaxUsed + 1 AS NVARCHAR(20)) + N';';
            EXEC sys.sp_executesql @Sql;
            PRINT CONCAT(N'    ', @Seq, N' restarted at ', @MaxUsed + 1, N' (', @Table, N'.', @Column, N' uses up to ', @MaxUsed, N').');
        END
    END

    FETCH NEXT FROM map INTO @Seq, @Table, @Column, @Prefix;
END

CLOSE map;
DEALLOCATE map;
GO

PRINT N'900 · Sequences realigned above the demo rows.';
GO
