/*==============================================================================
  Nazad POS — 37 · Customer update

  Backs PUT /api/customers/{customerId}.

  The balance is never written here: it moves only through a credit sale, a
  collection, a void or a return, each of which posts to 1400 in the same
  transaction. A credit limit may not be set below what the customer already
  owes, and a customer who owes money cannot be switched off.

  Error numbers 68000–68049.
==============================================================================*/

USE POSMAIN;
GO

CREATE OR ALTER PROCEDURE core.usp_UpdateCustomer
    @CustomerId   NVARCHAR(40),
    @NameAr       NVARCHAR(160),
    @NameEn       NVARCHAR(160),
    @Phone        NVARCHAR(30)  = NULL,
    @Email        NVARCHAR(160) = NULL,
    @VatNumber    NVARCHAR(15)  = NULL,
    @CustomerType NVARCHAR(20)  = NULL,   -- null keeps
    @CreditLimitH BIGINT,
    @IsActive     BIT           = NULL,   -- null keeps
    @Actor        NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NameAr = NULLIF(LTRIM(RTRIM(@NameAr)), N'');
    SET @NameEn = NULLIF(LTRIM(RTRIM(@NameEn)), N'');

    IF @NameAr IS NULL OR @NameEn IS NULL
        THROW 68000, N'Both the Arabic and English name are required.', 1;

    IF @CreditLimitH IS NULL OR @CreditLimitH < 0
        THROW 68001, N'A credit limit cannot be negative.', 1;

    IF @CustomerType IS NOT NULL AND @CustomerType NOT IN (N'individual', N'business')
        THROW 68004, N'A customer is an individual or a business.', 1;

    BEGIN TRAN;

        DECLARE @BalanceH BIGINT, @WasActive BIT;

        SELECT @BalanceH = BalanceH, @WasActive = IsActive
        FROM core.Customer WITH (UPDLOCK, HOLDLOCK)
        WHERE CustomerId = @CustomerId;

        IF @BalanceH IS NULL
            THROW 68003, N'Customer not found.', 1;

        IF @CreditLimitH < @BalanceH
            THROW 68002, N'The new limit is below what this customer already owes.', 1;

        IF @IsActive = 0 AND @WasActive = 1 AND @BalanceH > 0
            THROW 68005, N'This customer still owes money. Settle the balance before deactivating.', 1;

        UPDATE core.Customer
        SET NameAr       = @NameAr,
            NameEn       = @NameEn,
            Phone        = NULLIF(LTRIM(RTRIM(@Phone)), N''),
            Email        = NULLIF(LTRIM(RTRIM(@Email)), N''),
            VatNumber    = NULLIF(LTRIM(RTRIM(@VatNumber)), N''),
            CustomerType = ISNULL(@CustomerType, CustomerType),
            CreditLimitH = @CreditLimitH,
            IsActive     = ISNULL(@IsActive, IsActive),
            UpdatedAtUtc = SYSUTCDATETIME(),
            UpdatedBy    = @Actor
        WHERE CustomerId = @CustomerId;

    COMMIT;
END
GO

PRINT N'37 · Customer update ready.';
GO

SELECT CASE WHEN OBJECT_ID(N'core.usp_UpdateCustomer') IS NULL
            THEN N'FAIL  core.usp_UpdateCustomer missing'
            ELSE N'PASS  Customer update ready' END AS Result;
GO
