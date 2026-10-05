USE POSMAIN;
GO

/*==============================================================================
  Nazad POS — 011 · Expenses recognised by period; payroll owns salaries

  1. Spread expenses never reached the ledger.
     fin.usp_RecordExpense released each month's slice with
     @PostedAtUtc = '2026-10' (a CHAR(7) month), which SQL Server cannot turn
     into a date, so any monthly, yearly or custom expense failed outright.
     The demo's annual insurance was inserted directly with its recognition
     rows and no journal entries at all, so the ledger-based P&L showed 0 for
     it in every month instead of 1,000.

     The posting now lives in one place, fin.usp_PostExpenseLedger: the
     payment on the day it left (to prepaid when it spreads) and one release
     per month of fin.ExpenseRecognition, dated the first of that month.
     The ledger is then the single source for the P&L, and the recognition
     rows describe exactly the same amounts — the two are never added
     together, so nothing is counted twice.

     Every posted expense with no journal entries is posted now.

  2. A recurring instalment is recognised over the period it pays for.
     A yearly premium paid in September is twelve monthly costs from
     September, a quarterly one three. Monthly and shorter stay one-time.

  3. Payroll owns the salary and commission accounts (6200, 6300).
     fin.usp_PayPayroll posts them. A recurring payment or expense in a
     category mapped to either one counted the same salaries a second time
     (the demo's 6,000 "Employee salaries" on top of payroll). Both are now
     refused, and existing active schedules in such categories are paused
     with a note saying why. Expenses already posted to them stay in the
     ledger — they are real entries — and can be reversed from Expenses if
     they duplicated a payroll run.

  4. A reversal is dated no earlier than the entry it reverses, so reversing
     a spread expense cancels each future month's release in that month
     instead of piling the whole year into today. Reversing a customer
     collection (or a customer opening balance) puts the amount back on the
     customer's balance, so the account and the ledger keep agreeing.
==============================================================================*/

SET NOCOUNT ON;
GO

/*----------------------------------------------------- payroll-owned accounts */

/* One definition, used by every check below. */
CREATE OR ALTER FUNCTION fin.fn_IsPayrollAccount (@AccountCode NVARCHAR(10))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE WHEN @AccountCode IN (N'6200', N'6300') THEN 1 ELSE 0 END;
END
GO

/*--------------------------------------------------------- post one expense */

/*
  The ledger side of an expense that is already stored.

  Refuses an expense that already has entries, so it can never post twice.
*/
CREATE OR ALTER PROCEDURE fin.usp_PostExpenseLedger
    @ExpenseId NVARCHAR(40),
    @Actor     NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AmountH BIGINT, @VatH BIGINT, @Recognition NVARCHAR(20), @PaidOn DATE,
            @PaymentMethod NVARCHAR(20), @BranchId NVARCHAR(40), @AccountCode NVARCHAR(10),
            @DescriptionEn NVARCHAR(400), @DescriptionAr NVARCHAR(400);

    SELECT @AmountH = e.AmountH, @VatH = e.VatH, @Recognition = e.Recognition, @PaidOn = e.PaidOn,
           @PaymentMethod = e.PaymentMethod, @BranchId = e.BranchId, @AccountCode = c.AccountCode,
           @DescriptionEn = ISNULL(e.DescriptionEn, e.Reference),
           @DescriptionAr = e.DescriptionAr
    FROM fin.Expense AS e
    JOIN fin.ExpenseCategory AS c ON c.CategoryId = e.CategoryId
    WHERE e.ExpenseId = @ExpenseId;

    IF @AmountH IS NULL THROW 54026, N'Expense not found.', 1;

    IF EXISTS (SELECT 1 FROM fin.JournalEntry WHERE SourceReference = @ExpenseId)
        THROW 54025, N'This expense is already posted.', 1;

    BEGIN TRAN;

        DECLARE @NetH BIGINT = @AmountH - @VatH;
        DECLARE @Spreads BIT = CASE WHEN @Recognition = N'one_time' THEN 0 ELSE 1 END;
        DECLARE @PaymentAccount NVARCHAR(10) =
            CASE @PaymentMethod WHEN N'cash' THEN N'1000'
                                WHEN N'credit' THEN N'2000'
                                ELSE N'1100' END;

        /* The payment leaves on the date it left, whatever period the cost
           belongs to. Anything spread over time parks in prepaid first. */
        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (CASE WHEN @Spreads = 1 THEN N'1500' ELSE @AccountCode END, @NetH, 0, @DescriptionEn),
            (N'1300', @VatH, 0, N'Input VAT'),
            (@PaymentAccount, 0, @AmountH, @PaymentMethod);

        DECLARE @EntryId NVARCHAR(40);
        DECLARE @PaidAt DATETIME2(3) = CAST(@PaidOn AS DATETIME2(3));

        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense', @DescriptionEn = @DescriptionEn, @DescriptionAr = @DescriptionAr,
            @SourceReference = @ExpenseId, @BranchId = @BranchId, @Actor = @Actor,
            @PostedAtUtc = @PaidAt, @Lines = @Entry, @EntryId = @EntryId OUTPUT;

        EXEC fin.usp_BuildExpenseRecognition @ExpenseId = @ExpenseId;

        /* Release prepaid into the expense account, month by month, each on
           the first day of the month it belongs to. */
        IF @Spreads = 1
        BEGIN
            DECLARE @Month CHAR(7), @Slice BIGINT, @MonthAt DATETIME2(3);

            DECLARE slices CURSOR LOCAL FAST_FORWARD FOR
                SELECT PeriodMonth, AmountH FROM fin.ExpenseRecognition
                WHERE ExpenseId = @ExpenseId AND AmountH > 0
                ORDER BY PeriodMonth;

            OPEN slices;
            FETCH NEXT FROM slices INTO @Month, @Slice;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @Release fin.JournalLineTable;
                DELETE FROM @Release;

                INSERT INTO @Release (AccountCode, DebitH, CreditH, Memo) VALUES
                    (@AccountCode, @Slice, 0, @Month),
                    (N'1500', 0, @Slice, N'Prepaid release');

                SET @MonthAt = CAST(CAST(@Month + N'-01' AS DATE) AS DATETIME2(3));

                DECLARE @RelId NVARCHAR(40);
                EXEC fin.usp_PostJournalEntry
                    @Kind = N'expense_recognition',
                    @DescriptionEn = @DescriptionEn, @DescriptionAr = @DescriptionAr,
                    @SourceReference = @ExpenseId, @BranchId = @BranchId, @Actor = @Actor,
                    @PostedAtUtc = @MonthAt, @Lines = @Release, @EntryId = @RelId OUTPUT;

                FETCH NEXT FROM slices INTO @Month, @Slice;
            END

            CLOSE slices;
            DEALLOCATE slices;
        END

    COMMIT;
END
GO

/*----------------------------------------------------------- record expense */

CREATE OR ALTER PROCEDURE fin.usp_RecordExpense
    @CategoryId    NVARCHAR(40),
    @BranchId      NVARCHAR(40) = NULL,
    @DescriptionEn NVARCHAR(400),
    @DescriptionAr NVARCHAR(400) = NULL,
    @AmountH       BIGINT,
    @VatH          BIGINT = 0,
    @PaymentMethod NVARCHAR(20),
    @PaidOn        DATE,
    @Recognition   NVARCHAR(20) = N'one_time',
    @PeriodStart   DATE = NULL,
    @PeriodEnd     DATE = NULL,
    @ExternalRef   NVARCHAR(80) = NULL,
    @Attachment    NVARCHAR(300) = NULL,
    @Actor         NVARCHAR(120),
    @ExpenseId     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AmountH IS NULL OR @AmountH <= 0 THROW 54020, N'An expense must be above zero.', 1;
    SET @VatH = ISNULL(@VatH, 0);
    IF @VatH < 0 OR @VatH > @AmountH THROW 54021, N'VAT cannot exceed the amount.', 1;

    SET @Recognition = ISNULL(NULLIF(LTRIM(RTRIM(@Recognition)), N''), N'one_time');
    SET @PeriodStart = ISNULL(@PeriodStart, @PaidOn);
    SET @PeriodEnd   = ISNULL(@PeriodEnd, @PaidOn);

    IF @PeriodEnd < @PeriodStart THROW 54022, N'The period must end after it starts.', 1;

    DECLARE @AccountCode NVARCHAR(10) =
        (SELECT AccountCode FROM fin.ExpenseCategory WHERE CategoryId = @CategoryId);

    IF @AccountCode IS NULL THROW 54023, N'Unknown expense category.', 1;

    /* Salaries and commission are posted by payroll. Recording them here as
       well would count the same pay twice. */
    IF fin.fn_IsPayrollAccount(@AccountCode) = 1
        THROW 54024, N'Salaries and commission are paid through payroll, not as an expense.', 1;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR fin.ExpenseSequence;

        /* A number already taken by a row inserted by hand (or by an import)
           is skipped rather than failing the whole expense. 010 realigns the
           sequence; this keeps one stray row from ever blocking a payment. */
        WHILE EXISTS (SELECT 1 FROM fin.Expense WHERE Reference = CONCAT(N'EXP-', @Seq))
            SET @Seq = NEXT VALUE FOR fin.ExpenseSequence;

        SET @ExpenseId = CONCAT(N'exp_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO fin.Expense
            (ExpenseId, Reference, CategoryId, BranchId, DescriptionAr, DescriptionEn,
             AmountH, VatH, PaymentMethod, PaidOn, Recognition, PeriodStart, PeriodEnd,
             ExternalRef, AttachmentName, CreatedBy)
        VALUES
            (@ExpenseId, CONCAT(N'EXP-', @Seq), @CategoryId, @BranchId,
             @DescriptionAr, @DescriptionEn, @AmountH, @VatH, @PaymentMethod,
             @PaidOn, @Recognition, @PeriodStart, @PeriodEnd,
             @ExternalRef, @Attachment, @Actor);

        EXEC fin.usp_PostExpenseLedger @ExpenseId = @ExpenseId, @Actor = @Actor;

    COMMIT;
END
GO

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
CREATE OR ALTER PROCEDURE fin.usp_RecordRecurringInstalment
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

    SET @PaidOn = ISNULL(@PaidOn, CAST(SYSUTCDATETIME() AS DATE));

    DECLARE @Months INT = CASE @Frequency WHEN N'yearly' THEN 12 WHEN N'quarterly' THEN 3 ELSE 0 END;
    DECLARE @CoverFrom DATE = DATEFROMPARTS(YEAR(@NextDueOn), MONTH(@NextDueOn), 1);
    DECLARE @Recognition NVARCHAR(20) =
        CASE @Frequency WHEN N'yearly' THEN N'yearly' WHEN N'quarterly' THEN N'custom' ELSE N'one_time' END;
    DECLARE @PeriodStart DATE = CASE WHEN @Months > 0 THEN @CoverFrom END;
    DECLARE @PeriodEnd   DATE = CASE WHEN @Months > 0 THEN DATEADD(DAY, -1, DATEADD(MONTH, @Months, @CoverFrom)) END;

    BEGIN TRAN;

        EXEC fin.usp_RecordExpense
            @CategoryId = @CategoryId, @BranchId = @BranchId,
            @DescriptionEn = @DescEn, @DescriptionAr = @DescAr,
            @AmountH = @AmountH, @VatH = 0,
            @PaymentMethod = @Method, @PaidOn = @PaidOn,
            @Recognition = @Recognition, @PeriodStart = @PeriodStart, @PeriodEnd = @PeriodEnd,
            @Actor = @Actor,
            @ExpenseId = @ExpenseId OUTPUT;

        UPDATE fin.RecurringPayment
        SET LastPaidOn   = @PaidOn,
            NextDueOn    = fin.fn_AdvanceDueDate(@NextDueOn, @Frequency),
            UpdatedAtUtc = SYSUTCDATETIME()
        WHERE RecurringId = @RecurringId;

    COMMIT;
END
GO

/*------------------------------------------------------- recurring schedules */

CREATE OR ALTER PROCEDURE fin.usp_SaveRecurringPayment
    @RecurringId   NVARCHAR(40)  = NULL,   -- null creates
    @DescriptionEn NVARCHAR(300),
    @DescriptionAr NVARCHAR(300) = NULL,   -- null → the English text
    @CategoryId    NVARCHAR(40),
    @BranchId      NVARCHAR(40)  = NULL,   -- null = the whole business
    @AmountH       BIGINT,
    @Frequency     NVARCHAR(20),
    @NextDueOn     DATE,
    @PaymentMethod NVARCHAR(20)  = N'bank',
    @Note          NVARCHAR(400) = NULL,
    @Status        NVARCHAR(20)  = NULL,   -- null keeps (active on create)
    @SavedId       NVARCHAR(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @DescriptionEn = NULLIF(LTRIM(RTRIM(@DescriptionEn)), N'');
    SET @DescriptionAr = ISNULL(NULLIF(LTRIM(RTRIM(@DescriptionAr)), N''), @DescriptionEn);

    IF @DescriptionEn IS NULL
        THROW 69100, N'Give the payment a description.', 1;

    IF @AmountH IS NULL OR @AmountH <= 0
        THROW 69101, N'Enter an amount above zero.', 1;

    IF @Frequency IS NULL OR @Frequency NOT IN (N'daily', N'weekly', N'monthly', N'quarterly', N'yearly')
        THROW 69102, N'Frequency is daily, weekly, monthly, quarterly or yearly.', 1;

    IF @NextDueOn IS NULL
        THROW 69103, N'When is the next payment due?', 1;

    IF @PaymentMethod IS NULL OR @PaymentMethod NOT IN (N'cash', N'card', N'bank', N'credit')
        THROW 69104, N'Pay by cash, card, bank or on credit.', 1;

    IF NOT EXISTS (SELECT 1 FROM fin.ExpenseCategory WHERE CategoryId = @CategoryId AND IsActive = 1)
        THROW 69105, N'Choose an active expense category.', 1;

    /* Payroll posts salaries and commission every month already; a schedule
       for them would count the same pay twice. */
    IF EXISTS (SELECT 1 FROM fin.ExpenseCategory
               WHERE CategoryId = @CategoryId AND fin.fn_IsPayrollAccount(AccountCode) = 1)
        THROW 69109, N'Salaries and commission are paid through payroll. Choose another category.', 1;

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId)
        THROW 69106, N'Unknown branch.', 1;

    IF @Status IS NOT NULL AND @Status NOT IN (N'active', N'paused')
        THROW 69108, N'Status is active or paused.', 1;

    IF @RecurringId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.RecurringPayment WHERE RecurringId = @RecurringId)
        THROW 69107, N'Recurring payment not found.', 1;

    IF @RecurringId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'rec_', LEFT(LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')), 20));

        INSERT INTO fin.RecurringPayment
            (RecurringId, DescriptionAr, DescriptionEn, CategoryId, BranchId, AmountH,
             Frequency, NextDueOn, PaymentMethod, Status, Note)
        VALUES
            (@SavedId, @DescriptionAr, @DescriptionEn, @CategoryId, @BranchId, @AmountH,
             @Frequency, @NextDueOn, @PaymentMethod, ISNULL(@Status, N'active'),
             NULLIF(LTRIM(RTRIM(@Note)), N''));
    END
    ELSE
    BEGIN
        SET @SavedId = @RecurringId;

        UPDATE fin.RecurringPayment
        SET DescriptionAr = @DescriptionAr,
            DescriptionEn = @DescriptionEn,
            CategoryId    = @CategoryId,
            BranchId      = @BranchId,
            AmountH       = @AmountH,
            Frequency     = @Frequency,
            NextDueOn     = @NextDueOn,
            PaymentMethod = @PaymentMethod,
            Status        = ISNULL(@Status, Status),
            Note          = NULLIF(LTRIM(RTRIM(@Note)), N''),
            UpdatedAtUtc  = SYSUTCDATETIME()
        WHERE RecurringId = @RecurringId;
    END
END
GO

/*------------------------------------------------------------ reverse entry */

CREATE OR ALTER PROCEDURE fin.usp_ReverseJournalEntry
    @EntryId  NVARCHAR(40),
    @Reason   NVARCHAR(400),
    @Actor    NVARCHAR(120),
    @NewEntryId NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM fin.JournalEntry WHERE EntryId = @EntryId)
        THROW 51010, N'Journal entry not found.', 1;

    IF EXISTS (SELECT 1 FROM fin.JournalEntry
               WHERE EntryId = @EntryId AND ReversedByEntryId IS NOT NULL)
        THROW 51011, N'This entry has already been reversed.', 1;

    IF LTRIM(RTRIM(ISNULL(@Reason, N''))) = N''
        THROW 51012, N'A reversal needs a reason on the record.', 1;

    DECLARE @Flipped fin.JournalLineTable;

    INSERT INTO @Flipped (AccountCode, DebitH, CreditH, Memo)
    SELECT AccountCode, CreditH, DebitH, Memo
    FROM fin.JournalLine WHERE EntryId = @EntryId;

    DECLARE @Kind NVARCHAR(40), @Src NVARCHAR(80), @Branch NVARCHAR(40), @Ref NVARCHAR(40),
            @PostedAt DATETIME2(3);
    SELECT @Kind = Kind, @Src = SourceReference, @Branch = BranchId, @Ref = Reference,
           @PostedAt = PostedAtUtc
    FROM fin.JournalEntry WHERE EntryId = @EntryId;

    /* Never earlier than the original: a future month's release is cancelled
       in that month, a past entry is reversed today. */
    DECLARE @ReverseAt DATETIME2(3) =
        CASE WHEN @PostedAt > SYSUTCDATETIME() THEN @PostedAt ELSE SYSUTCDATETIME() END;

    /* What the entry did to a customer's receivable, for the balance below. */
    DECLARE @ReceivableH BIGINT =
        CASE WHEN @Kind IN (N'customer_collection', N'customer_opening')
             THEN ISNULL((SELECT SUM(DebitH - CreditH) FROM fin.JournalLine
                          WHERE EntryId = @EntryId AND AccountCode = N'1400'), 0)
             ELSE 0 END;

    BEGIN TRAN;

        EXEC fin.usp_PostJournalEntry
            @Kind            = @Kind,
            @DescriptionEn   = @Reason,
            @SourceReference = @Src,
            @BranchId        = @Branch,
            @Actor           = @Actor,
            @PostedAtUtc     = @ReverseAt,
            @Lines           = @Flipped,
            @EntryId         = @NewEntryId OUTPUT;

        UPDATE fin.JournalEntry
        SET ReversesEntryId = @EntryId,
            ReversalReason  = @Reason,
            DescriptionEn   = CONCAT(N'Reversal of ', @Ref, N' — ', @Reason)
        WHERE EntryId = @NewEntryId;

        UPDATE fin.JournalEntry
        SET ReversedByEntryId = @NewEntryId
        WHERE EntryId = @EntryId;

        /* A collection lowered the customer's balance and an opening balance
           raised it; undoing the entry undoes that too. The source reference
           of both is the customer id. */
        IF @ReceivableH <> 0
            UPDATE core.Customer
            SET BalanceH = BalanceH - @ReceivableH, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
            WHERE CustomerId = @Src;

    COMMIT;
END
GO

/*---------------------------------------------------- post what never posted */

DECLARE @Pending TABLE (ExpenseId NVARCHAR(40) PRIMARY KEY);

INSERT INTO @Pending (ExpenseId)
SELECT e.ExpenseId
FROM fin.Expense AS e
WHERE e.Status = N'posted'
  AND NOT EXISTS (SELECT 1 FROM fin.JournalEntry AS j WHERE j.SourceReference = e.ExpenseId);

DECLARE @Id NVARCHAR(40);

DECLARE pending CURSOR LOCAL FAST_FORWARD FOR SELECT ExpenseId FROM @Pending;
OPEN pending;
FETCH NEXT FROM pending INTO @Id;

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC fin.usp_PostExpenseLedger @ExpenseId = @Id, @Actor = N'migration-011';
    PRINT CONCAT(N'    Posted expense ', @Id, N' to the ledger.');
    FETCH NEXT FROM pending INTO @Id;
END

CLOSE pending;
DEALLOCATE pending;
GO

/*------------------------------------------ pause payroll-account schedules */

UPDATE r
SET Status = N'paused',
    Note = LEFT(CONCAT(r.Note, CASE WHEN r.Note IS NULL THEN N'' ELSE N' · ' END,
                       N'Paused: salaries are paid through payroll, which already posts them.'), 400),
    UpdatedAtUtc = SYSUTCDATETIME()
FROM fin.RecurringPayment AS r
JOIN fin.ExpenseCategory AS c ON c.CategoryId = r.CategoryId
WHERE r.Status = N'active'
  AND fin.fn_IsPayrollAccount(c.AccountCode) = 1;

IF @@ROWCOUNT > 0
    PRINT N'    Paused recurring payments in payroll-owned categories.';
GO

/*------------------------------------------------------------------ check */

/* Every posted expense: what its recognition rows say equals what its
   releases (or its one-time debit) put into the expense account. */
IF EXISTS (
    SELECT 1
    FROM fin.Expense AS e
    JOIN fin.ExpenseCategory AS c ON c.CategoryId = e.CategoryId
    WHERE e.Status = N'posted'
      AND ISNULL((SELECT SUM(r.AmountH) FROM fin.ExpenseRecognition AS r WHERE r.ExpenseId = e.ExpenseId), 0)
          <> ISNULL((SELECT SUM(l.DebitH - l.CreditH)
                     FROM fin.JournalEntry AS j
                     JOIN fin.JournalLine AS l ON l.EntryId = j.EntryId AND l.AccountCode = c.AccountCode
                     WHERE j.SourceReference = e.ExpenseId), 0))
    PRINT N'    WARNING: an expense''s recognition rows and its ledger postings disagree.';
GO

PRINT N'011 · Expenses recognised by period; payroll owns salaries.';
GO
