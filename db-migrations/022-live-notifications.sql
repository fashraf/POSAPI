/*==============================================================================
  Nazad POS — 022 · Notifications that something actually writes

  GET /api/notifications always returned [] because nothing ever inserted into
  core.Notification. This adds the writer.

  How it works
  ------------
  core.usp_RefreshNotifications looks at the current state of the business
  and keeps one open notification per live condition:

    low_stock     a stocked item at or below its reorder level in a branch
                  (out of stock is the same alert, raised to danger)
    recurring_due an active recurring payment due within 3 days, or overdue
    credit_limit  a customer whose balance is over their credit limit
    cash_drawer   a cash drawer left open longer than @DrawerOpenHours

  Each condition has a SourceKey (e.g. low_stock:brn_001:itm_cola). A filtered
  unique index allows only one OPEN row per key, so a condition is never
  announced twice. When the condition clears (stock received, payment made,
  drawer closed) the row is stamped ResolvedAtUtc and leaves the bell; if it
  comes back later, that is a new event and a new row. A recurring payment's
  key carries its due date, so each cycle is its own notification.

  The API runs the refresh just before it lists (at most once every few
  seconds), so the bell reflects a sale, an adjustment or a delivery the next
  time it is opened, without touching the sale or stock procedures.

  Read state is per user. A broadcast row (UserId NULL) used to have a single
  ReadAtUtc, so one person reading it marked it read for everyone;
  core.NotificationRead now holds who has read which. A row addressed to one
  user keeps using ReadAtUtc.

  PermissionKey says who should see a row (inventory.view for stock,
  finance.expenses for recurring payments, customers.view for credit,
  finance.view for drawers); BranchId limits it to people who can see that
  branch. The API applies both.

  Re-runnable: columns, table and indexes only if missing; CREATE OR ALTER.
==============================================================================*/

USE POSMAIN;
GO

IF COL_LENGTH(N'core.Notification', N'SourceKey') IS NULL
    ALTER TABLE core.Notification ADD SourceKey NVARCHAR(200) NULL;
GO

IF COL_LENGTH(N'core.Notification', N'ResolvedAtUtc') IS NULL
    ALTER TABLE core.Notification ADD ResolvedAtUtc DATETIME2(3) NULL;
GO

IF COL_LENGTH(N'core.Notification', N'PermissionKey') IS NULL
    ALTER TABLE core.Notification ADD PermissionKey NVARCHAR(80) NULL;
GO

/* One open notification per condition. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'UX_Notification_OpenSource' AND object_id = OBJECT_ID(N'core.Notification'))
    CREATE UNIQUE INDEX UX_Notification_OpenSource
        ON core.Notification (SourceKey)
        WHERE SourceKey IS NOT NULL AND ResolvedAtUtc IS NULL;
GO

IF OBJECT_ID(N'core.NotificationRead', N'U') IS NULL
BEGIN
    CREATE TABLE core.NotificationRead
    (
        NotificationId NVARCHAR(40) NOT NULL,
        UserId         NVARCHAR(40) NOT NULL,
        ReadAtUtc      DATETIME2(3) NOT NULL
            CONSTRAINT DF_NotificationRead_ReadAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_NotificationRead PRIMARY KEY (NotificationId, UserId),
        CONSTRAINT FK_NotificationRead_Notification FOREIGN KEY (NotificationId)
            REFERENCES core.Notification (NotificationId) ON DELETE CASCADE
    );
END
GO

/*------------------------------------------------------- refresh notifications */

CREATE OR ALTER PROCEDURE core.usp_RefreshNotifications
    @DrawerOpenHours INT = 12,   -- a drawer open longer than this is flagged
    @RecurringDays   INT = 3     -- how far ahead a recurring payment is "due"
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Two requests refreshing at once would race to insert the same key. The
       second simply skips: the first is already doing its work. */
    BEGIN TRAN;

    DECLARE @Lock INT;
    EXEC @Lock = sp_getapplock @Resource = N'core.usp_RefreshNotifications',
                               @LockMode = N'Exclusive', @LockOwner = N'Transaction',
                               @LockTimeout = 0;
    IF @Lock < 0
    BEGIN
        ROLLBACK;
        RETURN;
    END

    DECLARE @Now   DATETIME2(3) = SYSUTCDATETIME();
    /* Due dates are business dates; Riyadh is UTC+3 all year. */
    DECLARE @Today DATE = CAST(DATEADD(HOUR, 3, @Now) AS DATE);

    CREATE TABLE #Live
    (
        SourceKey     NVARCHAR(200) NOT NULL PRIMARY KEY,
        Kind          NVARCHAR(40)  NOT NULL,
        Severity      NVARCHAR(20)  NOT NULL,
        BranchId      NVARCHAR(40)  NULL,
        TitleAr       NVARCHAR(200) NOT NULL,
        TitleEn       NVARCHAR(200) NOT NULL,
        BodyAr        NVARCHAR(600) NULL,
        BodyEn        NVARCHAR(600) NULL,
        LinkPath      NVARCHAR(200) NULL,
        PermissionKey NVARCHAR(80)  NULL
    );

    /* Low and out of stock — only where the item is actually stocked (it has a
       stock row in that branch), so a branch that never carries an item is not
       told it has none. */
    INSERT INTO #Live
    SELECT CONCAT(N'low_stock:', s.BranchId, N':', i.ItemId),
           N'low_stock',
           CASE WHEN s.Quantity <= 0 THEN N'danger' ELSE N'warning' END,
           s.BranchId,
           LEFT(CASE WHEN s.Quantity <= 0
                     THEN CONCAT(N'نفد المخزون: ', i.NameAr, N' (', b.NameAr, N')')
                     ELSE CONCAT(N'مخزون منخفض: ', i.NameAr, N' — ',
                                 FORMAT(s.Quantity, N'0.###'), N' متبقٍ (', b.NameAr, N')') END, 200),
           LEFT(CASE WHEN s.Quantity <= 0
                     THEN CONCAT(N'Out of stock: ', i.NameEn, N' (', b.NameEn, N')')
                     ELSE CONCAT(N'Low stock: ', i.NameEn, N' — ',
                                 FORMAT(s.Quantity, N'0.###'), N' left (', b.NameEn, N')') END, 200),
           CONCAT(N'حد إعادة الطلب ', FORMAT(i.ReorderLevel, N'0.###')),
           CONCAT(N'Reorder level ', FORMAT(i.ReorderLevel, N'0.###')),
           N'/inventory',
           N'inventory.view'
    FROM inv.StockLevel AS s
    JOIN core.CatalogItem AS i ON i.ItemId = s.ItemId
    JOIN core.Branch AS b ON b.BranchId = s.BranchId
    WHERE i.TracksStock = 1 AND i.IsActive = 1 AND b.IsActive = 1
      AND (s.Quantity <= 0 OR (i.ReorderLevel > 0 AND s.Quantity <= i.ReorderLevel));

    /* Recurring payments due soon or overdue. The due date is in the key, so
       paying it (NextDueOn moves on) resolves this one and the next cycle
       raises its own. */
    INSERT INTO #Live
    SELECT CONCAT(N'recurring:', r.RecurringId, N':', CONVERT(NCHAR(10), r.NextDueOn, 23)),
           N'recurring_due',
           CASE WHEN r.NextDueOn < @Today THEN N'danger' ELSE N'warning' END,
           r.BranchId,
           LEFT(CASE WHEN r.NextDueOn < @Today
                     THEN CONCAT(N'دفعة متأخرة: ', r.DescriptionAr, N' — ',
                                 FORMAT(r.AmountH / 100.0, N'N2'), N' ر.س منذ ',
                                 CONVERT(NCHAR(10), r.NextDueOn, 23))
                     ELSE CONCAT(N'دفعة مستحقة: ', r.DescriptionAr, N' — ',
                                 FORMAT(r.AmountH / 100.0, N'N2'), N' ر.س في ',
                                 CONVERT(NCHAR(10), r.NextDueOn, 23)) END, 200),
           LEFT(CASE WHEN r.NextDueOn < @Today
                     THEN CONCAT(N'Overdue: ', r.DescriptionEn, N' — SAR ',
                                 FORMAT(r.AmountH / 100.0, N'N2'), N' was due ',
                                 CONVERT(NCHAR(10), r.NextDueOn, 23))
                     ELSE CONCAT(N'Due: ', r.DescriptionEn, N' — SAR ',
                                 FORMAT(r.AmountH / 100.0, N'N2'), N' on ',
                                 CONVERT(NCHAR(10), r.NextDueOn, 23)) END, 200),
           NULL, NULL,
           N'/finance/recurring',
           N'finance.expenses'
    FROM fin.RecurringPayment AS r
    WHERE r.Status = N'active'
      AND r.NextDueOn <= DATEADD(DAY, @RecurringDays, @Today);

    /* Customers over their credit limit. A zero limit means "no credit
       arrangement", not "limit of zero", so it is not flagged here. */
    INSERT INTO #Live
    SELECT CONCAT(N'credit:', c.CustomerId),
           N'credit_limit',
           N'danger',
           NULL,
           LEFT(CONCAT(N'تجاوز حد الائتمان: ', c.NameAr, N' — ',
                       FORMAT(c.BalanceH / 100.0, N'N2'), N' من ',
                       FORMAT(c.CreditLimitH / 100.0, N'N2'), N' ر.س'), 200),
           LEFT(CONCAT(N'Over credit limit: ', c.NameEn, N' — SAR ',
                       FORMAT(c.BalanceH / 100.0, N'N2'), N' of ',
                       FORMAT(c.CreditLimitH / 100.0, N'N2')), 200),
           NULL, NULL,
           N'/finance/credit',
           N'customers.view'
    FROM core.Customer AS c
    WHERE c.IsActive = 1 AND c.CreditLimitH > 0 AND c.BalanceH > c.CreditLimitH;

    /* A drawer left open past the threshold — usually a shift nobody closed,
       which leaves the day's cash uncounted. */
    INSERT INTO #Live
    SELECT CONCAT(N'drawer:', d.SessionId),
           N'cash_drawer',
           N'warning',
           d.BranchId,
           LEFT(CONCAT(N'درج النقد مفتوح منذ ', DATEDIFF(HOUR, d.OpenedAtUtc, @Now), N' ساعة',
                       ISNULL(N' (' + b.NameAr + N')', N''), N' — فتحه ', d.OpenedBy), 200),
           LEFT(CONCAT(N'Cash drawer open for ', DATEDIFF(HOUR, d.OpenedAtUtc, @Now), N' hours',
                       ISNULL(N' (' + b.NameEn + N')', N''), N' — opened by ', d.OpenedBy), 200),
           NULL, NULL,
           N'/finance/cash',
           N'finance.view'
    FROM fin.DrawerSession AS d
    LEFT JOIN core.Branch AS b ON b.BranchId = d.BranchId
    WHERE d.ClosedAtUtc IS NULL
      AND d.OpenedAtUtc < DATEADD(HOUR, -@DrawerOpenHours, @Now);

    /* Conditions that cleared leave the bell. */
    UPDATE n
    SET ResolvedAtUtc = @Now
    FROM core.Notification AS n
    WHERE n.SourceKey IS NOT NULL AND n.ResolvedAtUtc IS NULL
      AND NOT EXISTS (SELECT 1 FROM #Live AS l WHERE l.SourceKey = n.SourceKey);

    /* Still open: keep the wording current (a quantity dropping further, low
       turning into out). Read state is left alone. */
    UPDATE n
    SET Severity = l.Severity, TitleAr = l.TitleAr, TitleEn = l.TitleEn,
        BodyAr = l.BodyAr, BodyEn = l.BodyEn
    FROM core.Notification AS n
    JOIN #Live AS l ON l.SourceKey = n.SourceKey
    WHERE n.ResolvedAtUtc IS NULL
      AND (n.Severity <> l.Severity OR n.TitleEn <> l.TitleEn OR n.TitleAr <> l.TitleAr);

    /* New conditions become new notifications. */
    INSERT INTO core.Notification
        (NotificationId, UserId, BranchId, Kind, Severity, TitleAr, TitleEn,
         BodyAr, BodyEn, LinkPath, SourceKey, PermissionKey, CreatedAtUtc)
    SELECT CONCAT(N'ntf_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''))),
           NULL, l.BranchId, l.Kind, l.Severity, l.TitleAr, l.TitleEn,
           l.BodyAr, l.BodyEn, l.LinkPath, l.SourceKey, l.PermissionKey, @Now
    FROM #Live AS l
    WHERE NOT EXISTS (SELECT 1 FROM core.Notification AS n
                      WHERE n.SourceKey = l.SourceKey AND n.ResolvedAtUtc IS NULL);

    /* Resolved alerts are history nobody reads; a month is plenty. */
    DELETE FROM core.Notification
    WHERE ResolvedAtUtc IS NOT NULL AND ResolvedAtUtc < DATEADD(DAY, -30, @Now);

    COMMIT;
END
GO
