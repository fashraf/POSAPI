/*==============================================================================
  002 — control reference data

  Plans, features, what each business type may use, what each plan includes,
  the master lists and platform settings. Administrators are not seeded here:
  a password hash cannot be written honestly in SQL, so the first one comes
  from configuration (SuperAdmin:Mobile / SuperAdmin:Password) at startup.
==============================================================================*/

/*------------------------------------------------------------------- plans */

INSERT INTO ctl.Plan (PlanKey, Label, IsTrial, MonthlyH, AnnualH, Branches, Devices, Users, Transactions, StorageGb, Highlights, SortOrder)
VALUES
    ('Trial',      'Free trial', true,  0,     NULL,   1,    2,    3,    500,   1,    'Full POS|One branch|Expires automatically', 0),
    ('Basic',      'Basic',      false, 29900, 299000, 1,    3,    5,    5000,  5,    'POS|Inventory|Basic reports', 1),
    ('Pro',        'Pro',        false, 79900, 799000, 5,    20,   25,   25000, 20,   'Everything in Basic|Multi-branch|Payroll|API access', 2),
    ('Enterprise', 'Enterprise', false, NULL,  NULL,   NULL, NULL, NULL, NULL,  NULL, 'Everything in Pro|Unlimited everything|Priority support', 3)
ON CONFLICT (PlanKey) DO NOTHING;

/*---------------------------------------------------------------- features */

INSERT INTO ctl.Feature (FeatureKey, Label, Icon, Blurb, IsCore, SortOrder)
VALUES
    ('pos',              'POS',              'ShoppingCart',  'Core point of sale — ring up a sale, take payment, print a receipt.', true, 1),
    ('inventory',        'Inventory',        'Package',       'Stock levels, purchases, transfers between branches.', false, 2),
    ('kitchen',          'Kitchen',          'ChefHat',       'Kitchen display, order routing, preparation times.', false, 3),
    ('tables',           'Tables',           'Armchair',      'Floor plan, table status, split and merge bills.', false, 4),
    ('delivery',         'Delivery',         'Bike',          'Delivery orders, drivers, addresses and zones.', false, 5),
    ('appointments',     'Appointments',     'CalendarClock', 'Bookings by staff member and time slot.', false, 6),
    ('laundry',          'Laundry',          'Shirt',         'Garment tags, ready-by dates, collection tickets.', false, 7),
    ('customers',        'Customers',        'Users',         'Customer accounts, history and store credit.', false, 8),
    ('loyalty',          'Loyalty',          'Gift',          'Points, tiers and rewards.', false, 9),
    ('reports',          'Reports',          'BarChart3',     'Daily sales, product mix, cashier performance.', false, 10),
    ('advanced_reports', 'Advanced reports', 'LineChart',     'Cohorts, margins, forecasting and exports.', false, 11),
    ('payroll',          'Payroll',          'Wallet',        'Salaries, commission and end-of-service.', false, 12),
    ('accounting',       'Accounting',       'Calculator',    'Ledger, trial balance and VAT returns.', false, 13),
    ('api',              'API access',       'Plug',          'Read and write their data from another system.', false, 14),
    ('multi_branch',     'Multi-branch',     'Store',         'More than one branch, with consolidated reporting.', false, 15),
    ('ecommerce',        'Online orders',    'Globe',         'Orders from a web storefront into the same till.', false, 16)
ON CONFLICT (FeatureKey) DO NOTHING;

/*------------------------------------------- what each business type may use */

INSERT INTO ctl.TypeFeature (BusinessType, FeatureKey)
SELECT t.BusinessType, trim(f.FeatureKey)
FROM (VALUES
    ('Laundry',    'pos,inventory,laundry,customers,loyalty,reports,advanced_reports,payroll,accounting,api,multi_branch,delivery'),
    ('Retail',     'pos,inventory,customers,loyalty,reports,advanced_reports,payroll,accounting,api,multi_branch,ecommerce'),
    ('Restaurant', 'pos,inventory,kitchen,tables,delivery,customers,loyalty,reports,advanced_reports,payroll,accounting,api,multi_branch,ecommerce'),
    ('Barber',     'pos,appointments,customers,loyalty,reports,payroll,accounting,multi_branch'),
    ('Grocery',    'pos,inventory,customers,loyalty,reports,advanced_reports,payroll,accounting,api,multi_branch,ecommerce'),
    ('Pharmacy',   'pos,inventory,customers,reports,advanced_reports,payroll,accounting,api,multi_branch'),
    ('Cafe',       'pos,inventory,kitchen,tables,customers,loyalty,reports,payroll,accounting,multi_branch'),
    ('CarWash',    'pos,appointments,customers,loyalty,reports,payroll,multi_branch'),
    ('Bakery',     'pos,inventory,kitchen,customers,loyalty,reports,payroll,accounting,multi_branch')
) AS t (BusinessType, Features)
CROSS JOIN LATERAL unnest(string_to_array(t.Features, ',')) AS f (FeatureKey)
ON CONFLICT (BusinessType, FeatureKey) DO NOTHING;

/*----------------------------------- what each plan includes, per business type */

INSERT INTO ctl.PlanConfig (BusinessType, PlanKey, Users, Devices, Branches, Duration, DurationUnit,
                            AmountH, Currency, Status, CustomBilling, AutoRenew, RenewalNoticeDays)
SELECT t.BusinessType, p.PlanKey,
       CASE p.PlanKey WHEN 'Trial' THEN 3 WHEN 'Basic' THEN 5 WHEN 'Pro' THEN 25 END,
       CASE p.PlanKey WHEN 'Trial' THEN 2 WHEN 'Basic' THEN 3 WHEN 'Pro' THEN 20 END,
       CASE p.PlanKey WHEN 'Trial' THEN 1 WHEN 'Basic' THEN 1 WHEN 'Pro' THEN 5 END,
       CASE p.PlanKey WHEN 'Trial' THEN 15 ELSE 12 END,
       CASE p.PlanKey WHEN 'Trial' THEN 'days' ELSE 'months' END,
       CASE p.PlanKey WHEN 'Trial' THEN 0 WHEN 'Basic' THEN 29900 WHEN 'Pro' THEN 79900 END,
       'SAR', 'active',
       p.PlanKey = 'Enterprise',
       p.PlanKey <> 'Trial',
       30
FROM (SELECT DISTINCT BusinessType FROM ctl.TypeFeature) AS t
CROSS JOIN ctl.Plan AS p
ON CONFLICT (BusinessType, PlanKey) DO NOTHING;

/* Included is built from applicable, so it can never claim what the type
   cannot use. Basic: POS, reports, customers. Pro: all but advanced reports,
   API and online orders. Trial and Enterprise: everything applicable. */
INSERT INTO ctl.PlanConfigFeature (BusinessType, PlanKey, FeatureKey)
SELECT c.BusinessType, c.PlanKey, tf.FeatureKey
FROM ctl.PlanConfig AS c
JOIN ctl.TypeFeature AS tf ON tf.BusinessType = c.BusinessType
WHERE c.PlanKey IN ('Trial', 'Enterprise')
   OR (c.PlanKey = 'Basic' AND tf.FeatureKey IN ('pos', 'reports', 'customers'))
   OR (c.PlanKey = 'Pro' AND tf.FeatureKey NOT IN ('advanced_reports', 'api', 'ecommerce'))
ON CONFLICT (BusinessType, PlanKey, FeatureKey) DO NOTHING;

/*------------------------------------------------------------- master lists */

INSERT INTO ctl.MasterItem (SetKey, Value, Label, LabelAr, Extra, SortOrder)
SELECT v.* FROM (VALUES
    ('cities', 'Riyadh',   'Riyadh',   'الرياض',          'Riyadh',  1),
    ('cities', 'Jeddah',   'Jeddah',   'جدة',             'Makkah',  2),
    ('cities', 'Makkah',   'Makkah',   'مكة المكرمة',     'Makkah',  3),
    ('cities', 'Madinah',  'Madinah',  'المدينة المنورة', 'Madinah', 4),
    ('cities', 'Dammam',   'Dammam',   'الدمام',          'Eastern', 5),
    ('cities', 'Khobar',   'Khobar',   'الخبر',           'Eastern', 6),
    ('cities', 'Dhahran',  'Dhahran',  'الظهران',         'Eastern', 7),
    ('cities', 'Tabuk',    'Tabuk',    'تبوك',            'Tabuk',   8),
    ('cities', 'Abha',     'Abha',     'أبها',            'Asir',    9),
    ('cities', 'Buraydah', 'Buraydah', 'بريدة',           'Qassim',  10),
    ('cities', 'Hail',     'Hail',     'حائل',            'Hail',    11),
    ('cities', 'Najran',   'Najran',   'نجران',           'Najran',  12),
    ('cities', 'Jubail',   'Jubail',   'الجبيل',          'Eastern', 13),
    ('cities', 'Yanbu',    'Yanbu',    'ينبع',            'Madinah', 14),
    ('cities', 'Taif',     'Taif',     'الطائف',          'Makkah',  15),

    ('services', 'Laundry',    'Laundry',     'مغسلة',        'Shirt',           1),
    ('services', 'Retail',     'Retail shop', 'متجر تجزئة',   'ShoppingBag',     2),
    ('services', 'Restaurant', 'Restaurant',  'مطعم',         'UtensilsCrossed', 3),
    ('services', 'Barber',     'Barber shop', 'حلاق',         'Scissors',        4),
    ('services', 'Grocery',    'Grocery',     'بقالة',        'ShoppingCart',    5),
    ('services', 'Pharmacy',   'Pharmacy',    'صيدلية',       'Pill',            6),
    ('services', 'Cafe',       'Cafe',        'مقهى',         'Coffee',          7),
    ('services', 'CarWash',    'Car wash',    'مغسلة سيارات', 'Car',             8),
    ('services', 'Bakery',     'Bakery',      'مخبز',         'Croissant',       9),

    ('payment-methods', 'Cash',         'Cash',          'نقدي',          'cash',   1),
    ('payment-methods', 'Mada',         'Mada',          'مدى',           'card',   2),
    ('payment-methods', 'Visa',         'Visa',          'فيزا',          'card',   3),
    ('payment-methods', 'Mastercard',   'Mastercard',    'ماستركارد',     'card',   4),
    ('payment-methods', 'ApplePay',     'Apple Pay',     'أبل باي',       'wallet', 5),
    ('payment-methods', 'STCPay',       'STC Pay',       'إس تي سي باي',  'wallet', 6),
    ('payment-methods', 'BankTransfer', 'Bank transfer', 'تحويل بنكي',    'bank',   7),
    ('payment-methods', 'Credit',       'Store credit',  'رصيد المتجر',   'credit', 8),

    ('deactivation-reasons', 'non_payment', 'Non-payment',                    'عدم السداد',             NULL, 1),
    ('deactivation-reasons', 'requested',   'Client requested closure',       'طلب العميل الإغلاق',     NULL, 2),
    ('deactivation-reasons', 'fraud',       'Suspected fraud or misuse',      'اشتباه في احتيال',       NULL, 3),
    ('deactivation-reasons', 'trial_ended', 'Trial ended without conversion', 'انتهت الفترة التجريبية', NULL, 4),
    ('deactivation-reasons', 'duplicate',   'Duplicate account',              'حساب مكرر',              NULL, 5),
    ('deactivation-reasons', 'migration',   'Moved to another account',       'نُقل إلى حساب آخر',      NULL, 6),
    ('deactivation-reasons', 'other',       'Other — see comment',            'أخرى — انظر التعليق',    NULL, 7)
) AS v (SetKey, Value, Label, LabelAr, Extra, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM ctl.MasterItem AS m WHERE m.SetKey = v.SetKey AND m.Value = v.Value);

/*---------------------------------------------------------------- settings */

INSERT INTO ctl.Setting (SettingKey, Value)
VALUES
    ('trialDays',              '15'),
    ('sessionMinutes',         '60'),
    ('maxFailedLogins',        '5'),
    ('lockoutMinutes',         '15'),
    ('defaultTermDays',        '360'),
    ('expiryWarningDays',      '30'),
    ('refuseSignInOnExpiry',   'true'),
    ('snapshotMinutes',        '60'),
    ('heartbeatWindowSeconds', '90')
ON CONFLICT (SettingKey) DO NOTHING;

INSERT INTO ctl.NotificationRule (RuleKey, Label, Channel, IsOn, SortOrder)
VALUES
    ('expiring', 'Licence expiring within 14 days',      'Email',  true, 1),
    ('expired',  'Licence expired',                      'Email',  true, 2),
    ('offline',  'Three or more POS devices offline',    'In-app', true, 3),
    ('payment',  'Payment failed',                       'Email',  true, 4),
    ('quiet',    'Seven days without activity',          'In-app', true, 5),
    ('health',   'Client health turns critical',         'In-app', true, 6)
ON CONFLICT (RuleKey) DO NOTHING;
