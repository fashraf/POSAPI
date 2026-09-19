/*==============================================================================
  Nazad POS — 16 · Balance periods, payroll, recurring payments

  The remaining finance operations that write more than one table.
==============================================================================*/

USE POSMAIN;
GO

/*------------------------------------------------------------ balance periods */

/*
  Open a period and post the starting position.

  Modelled as a period rather than a single opening snapshot because the
  question an owner asks is not "what did I start with" but "what did I start
  with, what did I end with, and where did the difference go".
*/
CREATE PROCEDURE fin.usp_OpenBalancePeriod
    @BranchId          NVARCHAR(40),
    @Label             NVARCHAR(160),
    @OpenedOn          DATE,
    @OpeningCashH      BIGINT = 0,
    @OpeningCardH      BIGINT = 0,
    @OpeningCreditH    BIGINT = 0,
    @OpeningBankH      BIGINT = 0,
    @OpeningInventoryH BIGINT = 0,
    @OpeningPayablesH  BIGINT = 0,
    @OpenedBy          NVARCHAR(120),
    @Note              NVARCHAR(400) = NULL,
    @PeriodId          NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* One open period per branch. Two overlapping periods would each claim the
       same movements and neither closing figure would mean anything. */
    IF EXISTS (SELECT 1 FROM fin.BalancePeriod
               WHERE BranchId = @BranchId AND Status = N'open')
        THROW 56000, N'This branch already has an open period.', 1;

    IF @OpeningCashH < 0 OR @OpeningCardH < 0 OR @OpeningCreditH < 0
       OR @OpeningBankH < 0 OR @OpeningInventoryH < 0 OR @OpeningPayablesH < 0
        THROW 56001, N'Opening balances cannot be negative.', 1;

    BEGIN TRAN;

        SET @PeriodId = CONCAT(N'bpd_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO fin.BalancePeriod
            (PeriodId, BranchId, Label, OpenedOn,
             OpeningCashH, OpeningCardH, OpeningCreditH,
             OpeningBankH, OpeningInventoryH, OpeningPayablesH,
             Status, OpenedBy, Note)
        VALUES
            (@PeriodId, @BranchId, @Label, @OpenedOn,
             @OpeningCashH, @OpeningCardH, @OpeningCreditH,
             @OpeningBankH, @OpeningInventoryH, @OpeningPayablesH,
             N'open', @OpenedBy, @Note);

        /* Net worth of the position: what is held, less what is owed. Whatever
           does not net out goes to suspense so the entry balances without
           asking the owner to state their capital. */
        DECLARE @EquityH BIGINT =
            @OpeningCashH + @OpeningCardH + @OpeningCreditH
            + @OpeningBankH + @OpeningInventoryH - @OpeningPayablesH;

        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1000', @OpeningCashH, 0, N'Opening cash'),
            (N'1150', @OpeningCardH, 0, N'Opening card clearing'),
            (N'1400', @OpeningCreditH, 0, N'Opening receivables'),
            (N'1100', @OpeningBankH, 0, N'Opening bank'),
            (N'1200', @OpeningInventoryH, 0, N'Opening inventory'),
            (N'2000', 0, @OpeningPayablesH, N'Opening payables');

        IF @EquityH >= 0
            INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo)
            VALUES (N'3900', 0, @EquityH, N'Opening equity');
        ELSE
            INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo)
            VALUES (N'3900', ABS(@EquityH), 0, N'Opening equity');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'opening_balance',
            @DescriptionEn = @Label, @DescriptionAr = @Label,
            @SourceReference = @PeriodId, @BranchId = @BranchId,
            @Actor = @OpenedBy, @PostedAtUtc = @OpenedOn,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

    COMMIT;
END
GO

/* What the ledger says the position should be, per method. */
CREATE PROCEDURE fin.usp_BalancePeriodExpectation
    @PeriodId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId NVARCHAR(40), @From DATE, @To DATE;

    SELECT @BranchId = BranchId, @From = OpenedOn, @To = ISNULL(ClosedOn, CAST(SYSUTCDATETIME() AS DATE))
    FROM fin.BalancePeriod WHERE PeriodId = @PeriodId;

    IF @From IS NULL THROW 56002, N'Balance period not found.', 1;

    ;WITH Lines AS (
        SELECT l.AccountCode, l.DebitH, l.CreditH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE CAST(e.PostedAtUtc AS DATE) >= @From
          AND CAST(e.PostedAtUtc AS DATE) <= @To
          AND (e.BranchId = @BranchId OR e.BranchId IS NULL)
    )
    SELECT
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1000'), 0) AS CashH,
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1150'), 0) AS CardH,
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1400'), 0) AS CreditH,
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1100'), 0) AS BankH,
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1200'), 0) AS InventoryH,
        /* Payables is credit-normal, so flip it to read as a positive debt. */
        ISNULL((SELECT SUM(CreditH - DebitH) FROM Lines WHERE AccountCode = N'2000'), 0) AS PayablesH;
END
GO

CREATE PROCEDURE fin.usp_CloseBalancePeriod
    @PeriodId          NVARCHAR(40),
    @ClosedOn          DATE,
    @ClosingCashH      BIGINT,
    @ClosingCardH      BIGINT,
    @ClosingCreditH    BIGINT,
    @ClosingBankH      BIGINT,
    @ClosingInventoryH BIGINT,
    @ClosingPayablesH  BIGINT,
    @ClosedBy          NVARCHAR(120),
    @Note              NVARCHAR(400) = NULL,
    @VarianceH         BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BranchId NVARCHAR(40), @From DATE;

    SELECT @BranchId = BranchId, @From = OpenedOn
    FROM fin.BalancePeriod WHERE PeriodId = @PeriodId AND Status = N'open';

    IF @From IS NULL THROW 56003, N'That period is not open.', 1;
    IF @ClosedOn < @From THROW 56004, N'The closing date is before the period opened.', 1;

    DECLARE @ExpectedH BIGINT = ISNULL((
        SELECT SUM(CASE WHEN l.AccountCode = N'2000' THEN -(l.CreditH - l.DebitH)
                        ELSE l.DebitH - l.CreditH END)
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode IN (N'1000', N'1150', N'1400', N'1100', N'1200', N'2000')
          AND CAST(e.PostedAtUtc AS DATE) >= @From
          AND CAST(e.PostedAtUtc AS DATE) <= @ClosedOn
          AND (e.BranchId = @BranchId OR e.BranchId IS NULL)), 0);

    DECLARE @CountedH BIGINT =
        @ClosingCashH + @ClosingCardH + @ClosingCreditH
        + @ClosingBankH + @ClosingInventoryH - @ClosingPayablesH;

    SET @VarianceH = @CountedH - @ExpectedH;

    BEGIN TRAN;

        /* Any gap posts as its own entry rather than being absorbed. */
        IF @VarianceH <> 0
        BEGIN
            DECLARE @Entry fin.JournalLineTable;

            IF @VarianceH > 0
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'1000', @VarianceH, 0, N'Closing overage'),
                    (N'6000', 0, @VarianceH, N'Closing variance');
            ELSE
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'6000', ABS(@VarianceH), 0, N'Closing variance'),
                    (N'1000', 0, ABS(@VarianceH), N'Closing shortage');

            DECLARE @EntryId NVARCHAR(40);
            EXEC fin.usp_PostJournalEntry
                @Kind = N'manual',
                @DescriptionEn = N'Period closing variance',
                @DescriptionAr = N'فرق إقفال الفترة',
                @SourceReference = @PeriodId, @BranchId = @BranchId,
                @Actor = @ClosedBy, @PostedAtUtc = @ClosedOn,
                @Lines = @Entry, @EntryId = @EntryId OUTPUT;
        END

        UPDATE fin.BalancePeriod
        SET Status            = N'closed',
            ClosedOn          = @ClosedOn,
            ClosingCashH      = @ClosingCashH,
            ClosingCardH      = @ClosingCardH,
            ClosingCreditH    = @ClosingCreditH,
            ClosingBankH      = @ClosingBankH,
            ClosingInventoryH = @ClosingInventoryH,
            ClosingPayablesH  = @ClosingPayablesH,
            ClosedBy          = @ClosedBy,
            Note              = ISNULL(@Note, Note),
            UpdatedAtUtc      = SYSUTCDATETIME()
        WHERE PeriodId = @PeriodId;

    COMMIT;
END
GO

/*-------------------------------------------------------------------- payroll */

CREATE SEQUENCE fin.PayrollSequence AS BIGINT START WITH 100 INCREMENT BY 1;
GO

/*
  Build a draft for a period.

  Commission comes from what was frozen at each sale, never recalculated —
  which is the entire reason it was frozen.
*/
CREATE PROCEDURE fin.usp_DraftPayroll
    @PeriodMonth CHAR(7),
    @BranchId    NVARCHAR(40) = NULL,
    @Actor       NVARCHAR(120),
    @RunId       NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM fin.PayrollRun
               WHERE PeriodMonth = @PeriodMonth
                 AND ISNULL(BranchId, N'') = ISNULL(@BranchId, N'')
                 AND Status = N'paid')
        THROW 56010, N'Payroll for this period has already been paid.', 1;

    BEGIN TRAN;

        DELETE FROM fin.PayrollRun
        WHERE PeriodMonth = @PeriodMonth
          AND ISNULL(BranchId, N'') = ISNULL(@BranchId, N'')
          AND Status = N'draft';

        DECLARE @Seq BIGINT = NEXT VALUE FOR fin.PayrollSequence;
        SET @RunId = CONCAT(N'pay_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO fin.PayrollRun
            (RunId, Reference, PeriodMonth, BranchId, Status, TotalH, CreatedBy)
        VALUES
            (@RunId, CONCAT(N'PR-', @Seq), @PeriodMonth, @BranchId, N'draft', 0, @Actor);

        INSERT INTO fin.PayrollLine (RunId, UserId, BaseSalaryH, CommissionH, AllowancesH, DeductionsH)
        SELECT
            @RunId,
            u.UserId,
            u.BaseSalaryH,
            ISNULL(c.EarnedH, 0),
            0,
            0
        FROM core.AppUser AS u
        LEFT JOIN (
            SELECT UserId, SUM(AmountH) AS EarnedH
            FROM fin.CommissionEntry
            WHERE PayrollRunId IS NULL
              AND CONVERT(CHAR(7), EarnedAtUtc, 126) = @PeriodMonth
            GROUP BY UserId
        ) AS c ON c.UserId = u.UserId
        WHERE u.Status = N'active'
          AND u.IsExternal = 0
          AND (@BranchId IS NULL
               OR EXISTS (SELECT 1 FROM core.UserBranch AS ub
                          WHERE ub.UserId = u.UserId AND ub.BranchId = @BranchId));

        UPDATE fin.PayrollRun
        SET TotalH = ISNULL((SELECT SUM(NetPayH) FROM fin.PayrollLine WHERE RunId = @RunId), 0)
        WHERE RunId = @RunId;

    COMMIT;
END
GO

CREATE PROCEDURE fin.usp_PayPayroll
    @RunId  NVARCHAR(40),
    @PaidOn DATE,
    @Actor  NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status NVARCHAR(20), @PeriodMonth CHAR(7), @BranchId NVARCHAR(40), @Reference NVARCHAR(40);

    SELECT @Status = Status, @PeriodMonth = PeriodMonth, @BranchId = BranchId, @Reference = Reference
    FROM fin.PayrollRun WHERE RunId = @RunId;

    IF @Status IS NULL THROW 56011, N'Payroll run not found.', 1;
    IF @Status = N'paid' THROW 56012, N'This payroll has already been paid.', 1;

    DECLARE @SalariesH   BIGINT = ISNULL((SELECT SUM(BaseSalaryH + AllowancesH) FROM fin.PayrollLine WHERE RunId = @RunId), 0);
    DECLARE @CommissionH BIGINT = ISNULL((SELECT SUM(CommissionH) FROM fin.PayrollLine WHERE RunId = @RunId), 0);
    DECLARE @DeductionsH BIGINT = ISNULL((SELECT SUM(DeductionsH) FROM fin.PayrollLine WHERE RunId = @RunId), 0);
    DECLARE @NetH        BIGINT = ISNULL((SELECT SUM(NetPayH) FROM fin.PayrollLine WHERE RunId = @RunId), 0);

    IF @NetH <= 0 THROW 56013, N'There is nothing to pay for this period.', 1;

    BEGIN TRAN;

        /* Deductions credit the expense back rather than being netted off the
           salary line, so the expense reflects what was earned and the cash
           reflects what was actually paid. */
        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'6200', @SalariesH, 0, N'Salaries'),
            (N'6300', @CommissionH, 0, N'Commission'),
            (N'6200', 0, @DeductionsH, N'Deductions'),
            (N'1100', 0, @NetH, N'Paid from bank');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'payroll',
            @DescriptionEn = @Reference, @DescriptionAr = @Reference,
            @SourceReference = @Reference, @BranchId = @BranchId,
            @Actor = @Actor, @PostedAtUtc = @PaidOn,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

        /* Claim the commission this run settles, so it stops showing as owed. */
        UPDATE fin.CommissionEntry
        SET PayrollRunId = @RunId
        WHERE PayrollRunId IS NULL
          AND CONVERT(CHAR(7), EarnedAtUtc, 126) = @PeriodMonth;

        UPDATE fin.PayrollRun
        SET Status = N'paid', PaidOn = @PaidOn, TotalH = @NetH,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE RunId = @RunId;

    COMMIT;
END
GO

/*---------------------------------------------------------- recurring payments */

/*
  Record an instalment.

  Creates a real expense, which posts, then rolls the schedule forward from the
  date that was due rather than from today. Paying late must not drag every
  future instalment along with it.
*/
CREATE PROCEDURE fin.usp_RecordRecurringInstalment
    @RecurringId NVARCHAR(40),
    @PaidOn      DATE,
    @Actor       NVARCHAR(120),
    @ExpenseId   NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CategoryId NVARCHAR(40), @BranchId NVARCHAR(40), @AmountH BIGINT,
            @Frequency NVARCHAR(20), @NextDueOn DATE,
            @Method NVARCHAR(20), @DescEn NVARCHAR(300), @DescAr NVARCHAR(300);

    SELECT @CategoryId = CategoryId, @BranchId = BranchId, @AmountH = AmountH,
           @Frequency = Frequency, @NextDueOn = NextDueOn, @Method = PaymentMethod,
           @DescEn = DescriptionEn, @DescAr = DescriptionAr
    FROM fin.RecurringPayment WHERE RecurringId = @RecurringId;

    IF @CategoryId IS NULL THROW 56020, N'Recurring payment not found.', 1;

    BEGIN TRAN;

        EXEC fin.usp_RecordExpense
            @CategoryId = @CategoryId, @BranchId = @BranchId,
            @DescriptionEn = @DescEn, @DescriptionAr = @DescAr,
            @AmountH = @AmountH, @VatH = 0,
            @PaymentMethod = @Method, @PaidOn = @PaidOn,
            @Recognition = N'one_time', @Actor = @Actor,
            @ExpenseId = @ExpenseId OUTPUT;

        UPDATE fin.RecurringPayment
        SET LastPaidOn   = @PaidOn,
            NextDueOn    = fin.fn_AdvanceDueDate(@NextDueOn, @Frequency),
            UpdatedAtUtc = SYSUTCDATETIME()
        WHERE RecurringId = @RecurringId;

    COMMIT;
END
GO

/* Reverse an expense. The original stays; the opposite is posted. */
CREATE PROCEDURE fin.usp_ReverseExpense
    @ExpenseId NVARCHAR(40),
    @Reason    NVARCHAR(400),
    @Actor     NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM fin.Expense WHERE ExpenseId = @ExpenseId)
        THROW 56030, N'Expense not found.', 1;

    IF EXISTS (SELECT 1 FROM fin.Expense WHERE ExpenseId = @ExpenseId AND Status = N'reversed')
        THROW 56031, N'This expense has already been reversed.', 1;

    IF LTRIM(RTRIM(ISNULL(@Reason, N''))) = N''
        THROW 56032, N'A reversal needs a reason on the record.', 1;

    BEGIN TRAN;

        DECLARE @EntryId NVARCHAR(40), @NewId NVARCHAR(40);

        DECLARE entries CURSOR LOCAL FAST_FORWARD FOR
            SELECT EntryId FROM fin.JournalEntry
            WHERE SourceReference = @ExpenseId
              AND ReversesEntryId IS NULL
              AND ReversedByEntryId IS NULL;

        OPEN entries;
        FETCH NEXT FROM entries INTO @EntryId;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC fin.usp_ReverseJournalEntry
                @EntryId = @EntryId, @Reason = @Reason,
                @Actor = @Actor, @NewEntryId = @NewId OUTPUT;

            FETCH NEXT FROM entries INTO @EntryId;
        END

        CLOSE entries;
        DEALLOCATE entries;

        UPDATE fin.Expense
        SET Status = N'reversed', UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE ExpenseId = @ExpenseId;

    COMMIT;
END
GO

PRINT N'16 · Periods, payroll and recurring ready.';
GO
