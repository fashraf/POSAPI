/*==============================================================================
  Nazad POS — 15 · Finance operations

  Drawer sessions, card settlement, balance periods and payroll. Each writes
  more than one table, so each is a procedure rather than a sequence of calls.

  Also adds notifications, which the frontend expects and the schema never had.
==============================================================================*/

USE POSMAIN;
GO

/*------------------------------------------------------------ notifications */

CREATE TABLE core.Notification
(
    NotificationId  NVARCHAR(40)   NOT NULL CONSTRAINT PK_Notification PRIMARY KEY,
    /* Null means everyone; a user id targets one person. */
    UserId          NVARCHAR(40)   NULL
        CONSTRAINT FK_Notification_User REFERENCES core.AppUser (UserId) ON DELETE CASCADE,
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_Notification_Branch REFERENCES core.Branch (BranchId),
    Kind            NVARCHAR(40)   NOT NULL,
    Severity        NVARCHAR(20)   NOT NULL CONSTRAINT DF_Notification_Sev DEFAULT (N'info'),
    TitleAr         NVARCHAR(200)  NOT NULL,
    TitleEn         NVARCHAR(200)  NOT NULL,
    BodyAr          NVARCHAR(600)  NULL,
    BodyEn          NVARCHAR(600)  NULL,
    /* Where tapping it should go. */
    LinkPath        NVARCHAR(200)  NULL,
    ReadAtUtc       DATETIME2(3)   NULL,
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Notification_Created DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_Notification_Severity CHECK (Severity IN (N'info', N'warning', N'danger', N'success'))
);
GO

CREATE INDEX IX_Notification_Unread
    ON core.Notification (UserId, CreatedAtUtc DESC) WHERE ReadAtUtc IS NULL;
GO

/*--------------------------------------------------------------- cash drawer */

CREATE PROCEDURE fin.usp_OpenDrawer
    @BranchId     NVARCHAR(40),
    @OpeningCashH BIGINT,
    @OpenedBy     NVARCHAR(120),
    @SessionId    NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OpeningCashH < 0
        THROW 55000, N'An opening float cannot be negative.', 1;

    /* One open drawer per branch. Two would each claim the same movements and
       neither closing figure would mean anything. A filtered unique index
       enforces this as well; the check is here for the readable message. */
    IF EXISTS (SELECT 1 FROM fin.DrawerSession
               WHERE BranchId = @BranchId AND ClosedAtUtc IS NULL)
        THROW 55001, N'A drawer is already open at this branch.', 1;

    SET @SessionId = CONCAT(N'drw_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

    INSERT INTO fin.DrawerSession
        (SessionId, BranchId, OpenedAtUtc, OpeningCashH, OpenedBy)
    VALUES
        (@SessionId, @BranchId, SYSUTCDATETIME(), @OpeningCashH, @OpenedBy);
END
GO

/*
  What should be in the drawer right now.

  Derived from the ledger on every call rather than stored: a saved expectation
  goes stale the moment anything posts behind it, and counting against a stale
  number invents a variance that is not there.

  Only cash moves the drawer. Card takings sit in clearing until the bank
  settles, and a credit sale never touches it — counting either would make every
  close look short by the day's card total.
*/
CREATE PROCEDURE fin.usp_DrawerExpectation
    @SessionId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId NVARCHAR(40), @From DATETIME2(3), @To DATETIME2(3), @OpeningH BIGINT;

    SELECT @BranchId = BranchId,
           @From     = OpenedAtUtc,
           @To       = ISNULL(ClosedAtUtc, SYSUTCDATETIME()),
           @OpeningH = OpeningCashH
    FROM fin.DrawerSession WHERE SessionId = @SessionId;

    IF @BranchId IS NULL AND NOT EXISTS (SELECT 1 FROM fin.DrawerSession WHERE SessionId = @SessionId)
        THROW 55002, N'Drawer session not found.', 1;

    ;WITH CashLines AS (
        SELECT e.Kind, l.DebitH, l.CreditH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode = N'1000'
          AND e.PostedAtUtc >= @From AND e.PostedAtUtc <= @To
          AND (e.BranchId = @BranchId OR e.BranchId IS NULL)
    )
    SELECT
        @OpeningH AS OpeningCashH,
        ISNULL((SELECT SUM(DebitH)  FROM CashLines WHERE Kind = N'sale'), 0)                AS CashSalesH,
        ISNULL((SELECT SUM(DebitH)  FROM CashLines WHERE Kind = N'customer_collection'), 0) AS CashCollectionsH,
        ISNULL((SELECT SUM(DebitH)  FROM CashLines WHERE Kind = N'owner_contribution'), 0)  AS OwnerContributionsH,
        ISNULL((SELECT SUM(CreditH) FROM CashLines WHERE Kind = N'expense'), 0)             AS CashExpensesH,
        ISNULL((SELECT SUM(CreditH) FROM CashLines WHERE Kind = N'owner_withdrawal'), 0)    AS OwnerWithdrawalsH,
        ISNULL((SELECT SUM(CreditH) FROM CashLines WHERE Kind IN (N'return', N'void')), 0)  AS CashRefundsH,
        @OpeningH
            + ISNULL((SELECT SUM(DebitH)  FROM CashLines), 0)
            - ISNULL((SELECT SUM(CreditH) FROM CashLines), 0) AS ExpectedH;
END
GO

/*
  Close the drawer.

  A variance posts as its own ledger entry rather than being absorbed. An
  unexplained forty riyals is a fact about the business, and quietly swallowing
  it is how a drawer problem survives for months.
*/
CREATE PROCEDURE fin.usp_CloseDrawer
    @SessionId    NVARCHAR(40),
    @CountedCashH BIGINT,
    @ClosedBy     NVARCHAR(120),
    @Note         NVARCHAR(400) = NULL,
    @VarianceH    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @CountedCashH < 0
        THROW 55003, N'A count cannot be negative.', 1;

    DECLARE @BranchId NVARCHAR(40), @From DATETIME2(3), @OpeningH BIGINT;

    SELECT @BranchId = BranchId, @From = OpenedAtUtc, @OpeningH = OpeningCashH
    FROM fin.DrawerSession
    WHERE SessionId = @SessionId AND ClosedAtUtc IS NULL;

    IF @From IS NULL
        THROW 55004, N'That drawer session is not open.', 1;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    DECLARE @Movement BIGINT = ISNULL((
        SELECT SUM(l.DebitH - l.CreditH)
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode = N'1000'
          AND e.PostedAtUtc >= @From AND e.PostedAtUtc <= @Now
          AND (e.BranchId = @BranchId OR e.BranchId IS NULL)), 0);

    DECLARE @ExpectedH BIGINT = @OpeningH + @Movement;
    SET @VarianceH = @CountedCashH - @ExpectedH;

    BEGIN TRAN;

        IF @VarianceH <> 0
        BEGIN
            DECLARE @Entry fin.JournalLineTable;

            IF @VarianceH > 0
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'1000', @VarianceH, 0, N'Overage'),
                    (N'6000', 0, @VarianceH, N'Drawer variance');
            ELSE
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'6000', ABS(@VarianceH), 0, N'Drawer variance'),
                    (N'1000', 0, ABS(@VarianceH), N'Shortage');

            DECLARE @EntryId NVARCHAR(40);
            EXEC fin.usp_PostJournalEntry
                @Kind = N'manual',
                @DescriptionEn = N'Cash drawer variance',
                @DescriptionAr = N'فرق درج النقد',
                @SourceReference = @SessionId, @BranchId = @BranchId,
                @Actor = @ClosedBy, @Lines = @Entry, @EntryId = @EntryId OUTPUT;
        END

        UPDATE fin.DrawerSession
        SET ClosedAtUtc   = @Now,
            CountedCashH  = @CountedCashH,
            ExpectedCashH = @ExpectedH,
            VarianceH     = @VarianceH,
            ClosedBy      = @ClosedBy,
            Note          = @Note
        WHERE SessionId = @SessionId;

    COMMIT;
END
GO

/*---------------------------------------------------------- card settlement */

CREATE SEQUENCE fin.SettlementSequence AS BIGINT START WITH 300 INCREMENT BY 1;
GO

/*
  Record what the bank actually deposited.

  The gap between takings and deposit is the network's fee, and it is a real
  cost. Recognising it here is why the clearing account returns to zero instead
  of drifting down by the fee every month.
*/
CREATE PROCEDURE fin.usp_RecordSettlement
    @BranchId      NVARCHAR(40) = NULL,
    @CardSalesH    BIGINT,
    @DepositH      BIGINT,
    @SettledOn     DATE,
    @Note          NVARCHAR(400) = NULL,
    @Actor         NVARCHAR(120),
    @SettlementId  NVARCHAR(40) OUTPUT,
    @Reference     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @CardSalesH <= 0 THROW 55010, N'Enter the card takings this batch covers.', 1;
    IF @DepositH < 0     THROW 55011, N'A deposit cannot be negative.', 1;
    IF @DepositH > @CardSalesH
        THROW 55012, N'The deposit is more than the takings. Check the figures.', 1;

    DECLARE @FeeH BIGINT = @CardSalesH - @DepositH;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR fin.SettlementSequence;
        SET @SettlementId = CONCAT(N'set_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @Reference    = CONCAT(N'SET-', @Seq);

        INSERT INTO fin.CardSettlement
            (SettlementId, Reference, BranchId, CardSalesH, DepositH, FeeH,
             SettledOn, Status, Note, CreatedBy)
        VALUES
            (@SettlementId, @Reference, @BranchId, @CardSalesH, @DepositH, @FeeH,
             @SettledOn, N'reconciled', @Note, @Actor);

        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1100', @DepositH, 0, N'Bank deposit'),
            (N'6100', @FeeH, 0, N'Card fees'),
            (N'1150', 0, @CardSalesH, N'Card clearing');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'card_settlement',
            @DescriptionEn = N'Card settlement', @DescriptionAr = N'تسوية الشبكة',
            @SourceReference = @Reference, @BranchId = @BranchId,
            @Actor = @Actor, @PostedAtUtc = @SettledOn,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

    COMMIT;
END
GO

PRINT N'15 · Finance operations ready.';
GO
