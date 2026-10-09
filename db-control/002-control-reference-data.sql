/*==============================================================================
  002 — control reference data

  Plans, features, what each business type may use, what each plan includes,
  the master lists and platform settings. Administrators are not seeded here:
  a password hash cannot be written honestly in SQL, so the first one comes
  from configuration (SuperAdmin:Mobile / SuperAdmin:Password) at startup.
==============================================================================*/

USE POSCONTROL;
GO

SET NOCOUNT ON;

/*------------------------------------------------------------------- plans */

INSERT INTO ctl.[Plan] (PlanKey, Label, IsTrial, MonthlyH, AnnualH, Branches, Devices, Users, Transactions, StorageGb, Highlights, SortOrder)
SELECT v.* FROM (VALUES
    (N'Trial',      N'Free trial', 1, 0,     NULL,   1,    2,    3,    500,   1,    N'Full POS|One branch|Expires automatically', 0),
    (N'Basic',      N'Basic',      0, 29900, 299000, 1,    3,    5,    5000,  5,    N'POS|Inventory|Basic reports', 1),
    (N'Pro',        N'Pro',        0, 79900, 799000, 5,    20,   25,   25000, 20,   N'Everything in Basic|Multi-branch|Payroll|API access', 2),
    (N'Enterprise', N'Enterprise', 0, NULL,  NULL,   NULL, NULL, NULL, NULL,  NULL, N'Everything in Pro|Unlimited everything|Priority support', 3)
) AS v (PlanKey, Label, IsTrial, MonthlyH, AnnualH, Branches, Devices, Users, Transactions, StorageGb, Highlights, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM ctl.[Plan] AS p WHERE p.PlanKey = v.PlanKey);

/*---------------------------------------------------------------- features */

INSERT INTO ctl.Feature (FeatureKey, Label, Icon, Blurb, IsCore, SortOrder)
SELECT v.* FROM (VALUES
    (N'pos',              N'POS',              N'ShoppingCart',  N'Core point of sale — ring up a sale, take payment, print a receipt.', 1, 1),
    (N'inventory',        N'Inventory',        N'Package',       N'Stock levels, purchases, transfers between branches.', 0, 2),
    (N'kitchen',          N'Kitchen',          N'ChefHat',       N'Kitchen display, order routing, preparation times.', 0, 3),
    (N'tables',           N'Tables',           N'Armchair',      N'Floor plan, table status, split and merge bills.', 0, 4),
    (N'delivery',         N'Delivery',         N'Bike',          N'Delivery orders, drivers, addresses and zones.', 0, 5),
    (N'appointments',     N'Appointments',     N'CalendarClock', N'Bookings by staff member and time slot.', 0, 6),
    (N'laundry',          N'Laundry',          N'Shirt',         N'Garment tags, ready-by dates, collection tickets.', 0, 7),
    (N'customers',        N'Customers',        N'Users',         N'Customer accounts, history and store credit.', 0, 8),
    (N'loyalty',          N'Loyalty',          N'Gift',          N'Points, tiers and rewards.', 0, 9),
    (N'reports',          N'Reports',          N'BarChart3',     N'Daily sales, product mix, cashier performance.', 0, 10),
    (N'advanced_reports', N'Advanced reports', N'LineChart',     N'Cohorts, margins, forecasting and exports.', 0, 11),
    (N'payroll',          N'Payroll',          N'Wallet',        N'Salaries, commission and end-of-service.', 0, 12),
    (N'accounting',       N'Accounting',       N'Calculator',    N'Ledger, trial balance and VAT returns.', 0, 13),
    (N'api',              N'API access',       N'Plug',          N'Read and write their data from another system.', 0, 14),
    (N'multi_branch',     N'Multi-branch',     N'Store',         N'More than one branch, with consolidated reporting.', 0, 15),
    (N'ecommerce',        N'Online orders',    N'Globe',         N'Orders from a web storefront into the same till.', 0, 16)
) AS v (FeatureKey, Label, Icon, Blurb, IsCore, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM ctl.Feature AS f WHERE f.FeatureKey = v.FeatureKey);

/*------------------------------------------- what each business type may use */

INSERT INTO ctl.TypeFeature (BusinessType, FeatureKey)
SELECT t.BusinessType, LTRIM(RTRIM(s.value))
FROM (VALUES
    (N'Laundry',    N'pos,inventory,laundry,customers,loyalty,reports,advanced_reports,payroll,accounting,api,multi_branch,delivery'),
    (N'Retail',     N'pos,inventory,customers,loyalty,reports,advanced_reports,payroll,accounting,api,multi_branch,ecommerce'),
    (N'Restaurant', N'pos,inventory,kitchen,tables,delivery,customers,loyalty,reports,advanced_reports,payroll,accounting,api,multi_branch,ecommerce'),
    (N'Barber',     N'pos,appointments,customers,loyalty,reports,payroll,accounting,multi_branch'),
    (N'Grocery',    N'pos,inventory,customers,loyalty,reports,advanced_reports,payroll,accounting,api,multi_branch,ecommerce'),
    (N'Pharmacy',   N'pos,inventory,customers,reports,advanced_reports,payroll,accounting,api,multi_branch'),
    (N'Cafe',       N'pos,inventory,kitchen,tables,customers,loyalty,reports,payroll,accounting,multi_branch'),
    (N'CarWash',    N'pos,appointments,customers,loyalty,reports,payroll,multi_branch'),
    (N'Bakery',     N'pos,inventory,kitchen,customers,loyalty,reports,payroll,accounting,multi_branch')
) AS t (BusinessType, Features)
CROSS APPLY STRING_SPLIT(t.Features, N',') AS s
WHERE NOT EXISTS (SELECT 1 FROM ctl.TypeFeature AS x
                  WHERE x.BusinessType = t.BusinessType AND x.FeatureKey = LTRIM(RTRIM(s.value)));

/*----------------------------------- what each plan includes, per business type */

INSERT INTO ctl.PlanConfig (BusinessType, PlanKey, Users, Devices, Branches, Duration, DurationUnit,
                            AmountH, Currency, Status, CustomBilling, AutoRenew, RenewalNoticeDays)
SELECT t.BusinessType, p.PlanKey,
       CASE p.PlanKey WHEN N'Trial' THEN 3 WHEN N'Basic' THEN 5 WHEN N'Pro' THEN 25 END,
       CASE p.PlanKey WHEN N'Trial' THEN 2 WHEN N'Basic' THEN 3 WHEN N'Pro' THEN 20 END,
       CASE p.PlanKey WHEN N'Trial' THEN 1 WHEN N'Basic' THEN 1 WHEN N'Pro' THEN 5 END,
       CASE p.PlanKey WHEN N'Trial' THEN 15 ELSE 12 END,
       CASE p.PlanKey WHEN N'Trial' THEN N'days' ELSE N'months' END,
       CASE p.PlanKey WHEN N'Trial' THEN 0 WHEN N'Basic' THEN 29900 WHEN N'Pro' THEN 79900 END,
       N'SAR', N'active',
       CASE p.PlanKey WHEN N'Enterprise' THEN 1 ELSE 0 END,
       CASE p.PlanKey WHEN N'Trial' THEN 0 ELSE 1 END,
       30
FROM (SELECT DISTINCT BusinessType FROM ctl.TypeFeature) AS t
CROSS JOIN ctl.[Plan] AS p
WHERE NOT EXISTS (SELECT 1 FROM ctl.PlanConfig AS c WHERE c.BusinessType = t.BusinessType AND c.PlanKey = p.PlanKey);

/* Included is built from applicable, so it can never claim what the type
   cannot use. Basic: POS, reports, customers. Pro: all but advanced reports,
   API and online orders. Trial and Enterprise: everything applicable. */
INSERT INTO ctl.PlanConfigFeature (BusinessType, PlanKey, FeatureKey)
SELECT c.BusinessType, c.PlanKey, tf.FeatureKey
FROM ctl.PlanConfig AS c
JOIN ctl.TypeFeature AS tf ON tf.BusinessType = c.BusinessType
WHERE (c.PlanKey IN (N'Trial', N'Enterprise')
       OR (c.PlanKey = N'Basic' AND tf.FeatureKey IN (N'pos', N'reports', N'customers'))
       OR (c.PlanKey = N'Pro' AND tf.FeatureKey NOT IN (N'advanced_reports', N'api', N'ecommerce')))
  AND NOT EXISTS (SELECT 1 FROM ctl.PlanConfigFeature AS x
                  WHERE x.BusinessType = c.BusinessType AND x.PlanKey = c.PlanKey AND x.FeatureKey = tf.FeatureKey);

/*------------------------------------------------------------- master lists */

INSERT INTO ctl.MasterItem (SetKey, Value, Label, LabelAr, Extra, SortOrder)
SELECT v.* FROM (VALUES
    (N'cities', N'Riyadh',   N'Riyadh',   N'الرياض',          N'Riyadh',  1),
    (N'cities', N'Jeddah',   N'Jeddah',   N'جدة',             N'Makkah',  2),
    (N'cities', N'Makkah',   N'Makkah',   N'مكة المكرمة',     N'Makkah',  3),
    (N'cities', N'Madinah',  N'Madinah',  N'المدينة المنورة', N'Madinah', 4),
    (N'cities', N'Dammam',   N'Dammam',   N'الدمام',          N'Eastern', 5),
    (N'cities', N'Khobar',   N'Khobar',   N'الخبر',           N'Eastern', 6),
    (N'cities', N'Dhahran',  N'Dhahran',  N'الظهران',         N'Eastern', 7),
    (N'cities', N'Tabuk',    N'Tabuk',    N'تبوك',            N'Tabuk',   8),
    (N'cities', N'Abha',     N'Abha',     N'أبها',            N'Asir',    9),
    (N'cities', N'Buraydah', N'Buraydah', N'بريدة',           N'Qassim',  10),
    (N'cities', N'Hail',     N'Hail',     N'حائل',            N'Hail',    11),
    (N'cities', N'Najran',   N'Najran',   N'نجران',           N'Najran',  12),
    (N'cities', N'Jubail',   N'Jubail',   N'الجبيل',          N'Eastern', 13),
    (N'cities', N'Yanbu',    N'Yanbu',    N'ينبع',            N'Madinah', 14),
    (N'cities', N'Taif',     N'Taif',     N'الطائف',          N'Makkah',  15),

    (N'services', N'Laundry',    N'Laundry',     N'مغسلة',        N'Shirt',           1),
    (N'services', N'Retail',     N'Retail shop', N'متجر تجزئة',   N'ShoppingBag',     2),
    (N'services', N'Restaurant', N'Restaurant',  N'مطعم',         N'UtensilsCrossed', 3),
    (N'services', N'Barber',     N'Barber shop', N'حلاق',         N'Scissors',        4),
    (N'services', N'Grocery',    N'Grocery',     N'بقالة',        N'ShoppingCart',    5),
    (N'services', N'Pharmacy',   N'Pharmacy',    N'صيدلية',       N'Pill',            6),
    (N'services', N'Cafe',       N'Cafe',        N'مقهى',         N'Coffee',          7),
    (N'services', N'CarWash',    N'Car wash',    N'مغسلة سيارات', N'Car',             8),
    (N'services', N'Bakery',     N'Bakery',      N'مخبز',         N'Croissant',       9),

    (N'payment-methods', N'Cash',         N'Cash',          N'نقدي',          N'cash',   1),
    (N'payment-methods', N'Mada',         N'Mada',          N'مدى',           N'card',   2),
    (N'payment-methods', N'Visa',         N'Visa',          N'فيزا',          N'card',   3),
    (N'payment-methods', N'Mastercard',   N'Mastercard',    N'ماستركارد',     N'card',   4),
    (N'payment-methods', N'ApplePay',     N'Apple Pay',     N'أبل باي',       N'wallet', 5),
    (N'payment-methods', N'STCPay',       N'STC Pay',       N'إس تي سي باي',  N'wallet', 6),
    (N'payment-methods', N'BankTransfer', N'Bank transfer', N'تحويل بنكي',    N'bank',   7),
    (N'payment-methods', N'Credit',       N'Store credit',  N'رصيد المتجر',   N'credit', 8),

    (N'deactivation-reasons', N'non_payment', N'Non-payment',                    N'عدم السداد',             NULL, 1),
    (N'deactivation-reasons', N'requested',   N'Client requested closure',       N'طلب العميل الإغلاق',     NULL, 2),
    (N'deactivation-reasons', N'fraud',       N'Suspected fraud or misuse',      N'اشتباه في احتيال',       NULL, 3),
    (N'deactivation-reasons', N'trial_ended', N'Trial ended without conversion', N'انتهت الفترة التجريبية', NULL, 4),
    (N'deactivation-reasons', N'duplicate',   N'Duplicate account',              N'حساب مكرر',              NULL, 5),
    (N'deactivation-reasons', N'migration',   N'Moved to another account',       N'نُقل إلى حساب آخر',      NULL, 6),
    (N'deactivation-reasons', N'other',       N'Other — see comment',            N'أخرى — انظر التعليق',    NULL, 7)
) AS v (SetKey, Value, Label, LabelAr, Extra, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM ctl.MasterItem AS m WHERE m.SetKey = v.SetKey AND m.Value = v.Value);

/*---------------------------------------------------------------- settings */

INSERT INTO ctl.Setting (SettingKey, Value)
SELECT v.* FROM (VALUES
    (N'trialDays',              N'15'),
    (N'sessionMinutes',         N'60'),
    (N'maxFailedLogins',        N'5'),
    (N'lockoutMinutes',         N'15'),
    (N'defaultTermDays',        N'360'),
    (N'expiryWarningDays',      N'30'),
    (N'refuseSignInOnExpiry',   N'true'),
    (N'snapshotMinutes',        N'60'),
    (N'heartbeatWindowSeconds', N'90')
) AS v (SettingKey, Value)
WHERE NOT EXISTS (SELECT 1 FROM ctl.Setting AS s WHERE s.SettingKey = v.SettingKey);

INSERT INTO ctl.NotificationRule (RuleKey, Label, Channel, IsOn, SortOrder)
SELECT v.* FROM (VALUES
    (N'expiring', N'Licence expiring within 14 days',      N'Email',  1, 1),
    (N'expired',  N'Licence expired',                      N'Email',  1, 2),
    (N'offline',  N'Three or more POS devices offline',    N'In-app', 1, 3),
    (N'payment',  N'Payment failed',                       N'Email',  1, 4),
    (N'quiet',    N'Seven days without activity',          N'In-app', 1, 5),
    (N'health',   N'Client health turns critical',         N'In-app', 1, 6)
) AS v (RuleKey, Label, Channel, IsOn, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM ctl.NotificationRule AS r WHERE r.RuleKey = v.RuleKey);
GO
