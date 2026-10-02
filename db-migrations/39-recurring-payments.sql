/*==============================================================================
  Nazad POS — 39 · Recurring payments

  Backs POST /api/expenses/recurring, PUT /api/expenses/recurring/{id} and
  PATCH /api/expenses/recurring/{id}/status.

  A schedule posts nothing by itself. Money moves only when an instalment is
  recorded (POST /api/finance/recurring/{id}/record → fin.usp_RecordExpense),
  so saving, editing, pausing or resuming a schedule never touches the ledger.

  Error numbers 69100–69149.
==============================================================================*/

USE POSMAIN;
GO

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

CREATE OR ALTER PROCEDURE fin.usp_SetRecurringStatus
    @RecurringId NVARCHAR(40),
    @Status      NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status IS NULL OR @Status NOT IN (N'active', N'paused')
        THROW 69108, N'Status is active or paused.', 1;

    UPDATE fin.RecurringPayment
    SET Status = @Status, UpdatedAtUtc = SYSUTCDATETIME()
    WHERE RecurringId = @RecurringId;

    IF @@ROWCOUNT = 0
        THROW 69107, N'Recurring payment not found.', 1;
END
GO

PRINT N'39 · Recurring payments ready.';
GO

SELECT CASE WHEN OBJECT_ID(N'fin.usp_SaveRecurringPayment') IS NULL
              OR OBJECT_ID(N'fin.usp_SetRecurringStatus') IS NULL
            THEN N'FAIL  recurring procs missing'
            ELSE N'PASS  Recurring payments ready' END AS Result;
GO
