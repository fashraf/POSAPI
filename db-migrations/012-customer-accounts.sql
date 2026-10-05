USE POSMAIN;
GO

/*==============================================================================
  Nazad POS — 012 · Customer accounts: opening balances and checked creates

  1. A new customer's opening balance was lost. The form sends it; the create
     route inserted the row with BalanceH = 0 and ignored it. A balance typed
     straight into BalanceH would not do either: nothing in the ledger would
     stand behind it, and receivables (1400) would never agree with the sum
     of what customers owe.

     core.usp_CreateCustomer stores the customer and, for an opening balance,
     posts it the way fin.usp_PostOpeningBalances posts the business's:
     Dr 1400 receivables / Cr 3900 opening balance suspense, kind
     'customer_opening', source reference the customer id. The statement
     shows that entry as its first line. Reversing it in the ledger takes it
     back off the balance (011).

  2. A negative credit limit on create reached the CK_Customer_Limit check and
     came back as HTTP 500. The procedure now refuses it with 68001 (the same
     number usp_UpdateCustomer uses), and the route answers 422 on
     creditLimitH.

  3. fin.usp_RebuildCustomerBalances ignored credit notes refunded to the
     account, opening balances and reversed collections. It now counts every
     movement the statement shows, so a rebuild lands on the same figure.
==============================================================================*/

SET NOCOUNT ON;
GO

/*--------------------------------------------------- a journal kind for it */

/* Added to whatever the check allows today, so a kind another change added
   is kept. */
DECLARE @Definition NVARCHAR(MAX) =
    (SELECT definition FROM sys.check_constraints WHERE name = N'CK_JournalEntry_Kind'
       AND parent_object_id = OBJECT_ID(N'fin.JournalEntry'));

IF @Definition IS NOT NULL AND @Definition NOT LIKE N'%customer_opening%'
BEGIN
    DECLARE @Sql NVARCHAR(MAX) =
        N'ALTER TABLE fin.JournalEntry DROP CONSTRAINT CK_JournalEntry_Kind; '
      + N'ALTER TABLE fin.JournalEntry WITH CHECK ADD CONSTRAINT CK_JournalEntry_Kind CHECK ('
      + @Definition + N' OR [Kind]=N''customer_opening'');';
    EXEC sys.sp_executesql @Sql;
    PRINT N'    Journal kind customer_opening allowed.';
END
GO

/*-------------------------------------------------------- create a customer */

CREATE OR ALTER PROCEDURE core.usp_CreateCustomer
    @NameAr          NVARCHAR(160),
    @NameEn          NVARCHAR(160),
    @Phone           NVARCHAR(30)  = NULL,
    @Email           NVARCHAR(160) = NULL,
    @VatNumber       NVARCHAR(15)  = NULL,
    @CustomerType    NVARCHAR(20)  = NULL,   -- null = individual
    @CreditLimitH    BIGINT        = 0,
    @OpeningBalanceH BIGINT        = 0,
    @OpeningAsOf     DATE          = NULL,   -- null = today
    @BranchId        NVARCHAR(40)  = NULL,   -- where the opening entry is tagged; null = business-wide
    @Actor           NVARCHAR(120),
    @CustomerId      NVARCHAR(40)  OUTPUT,
    @EntryId         NVARCHAR(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NameAr = NULLIF(LTRIM(RTRIM(@NameAr)), N'');
    SET @NameEn = NULLIF(LTRIM(RTRIM(@NameEn)), N'');
    SET @CustomerType = ISNULL(NULLIF(LTRIM(RTRIM(@CustomerType)), N''), N'individual');
    SET @CreditLimitH = ISNULL(@CreditLimitH, 0);
    SET @OpeningBalanceH = ISNULL(@OpeningBalanceH, 0);

    IF @NameAr IS NULL OR @NameEn IS NULL
        THROW 68000, N'Both the Arabic and English name are required.', 1;

    IF @CreditLimitH < 0
        THROW 68001, N'A credit limit cannot be negative.', 1;

    IF @CustomerType NOT IN (N'individual', N'business')
        THROW 68004, N'A customer is an individual or a business.', 1;

    IF @OpeningBalanceH < 0
        THROW 68006, N'An opening balance cannot be negative.', 1;

    IF @OpeningBalanceH > @CreditLimitH
        THROW 68007, N'The opening balance is above the credit limit.', 1;

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId)
        THROW 68008, N'Unknown branch.', 1;

    SET @CustomerId = LEFT(CONCAT(N'cus_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''))), 24);
    SET @EntryId = NULL;

    BEGIN TRAN;

        INSERT INTO core.Customer
            (CustomerId, NameAr, NameEn, Phone, Email, VatNumber,
             CustomerType, CreditLimitH, BalanceH, CreatedBy, UpdatedBy)
        VALUES
            (@CustomerId, @NameAr, @NameEn,
             NULLIF(LTRIM(RTRIM(@Phone)), N''), NULLIF(LTRIM(RTRIM(@Email)), N''),
             NULLIF(LTRIM(RTRIM(@VatNumber)), N''),
             @CustomerType, @CreditLimitH, @OpeningBalanceH, @Actor, @Actor);

        IF @OpeningBalanceH > 0
        BEGIN
            DECLARE @Lines fin.JournalLineTable;
            INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
                (N'1400', @OpeningBalanceH, 0, N'Opening receivable'),
                (N'3900', 0, @OpeningBalanceH, N'Opening equity');

            DECLARE @DescEn NVARCHAR(400) = CONCAT(N'Opening balance — ', @NameEn);
            DECLARE @DescAr NVARCHAR(400) = CONCAT(N'رصيد افتتاحي — ', @NameAr);
            DECLARE @PostedAt DATETIME2(3) =
                CASE WHEN @OpeningAsOf IS NULL THEN SYSUTCDATETIME()
                     ELSE CAST(@OpeningAsOf AS DATETIME2(3)) END;

            EXEC fin.usp_PostJournalEntry
                @Kind            = N'customer_opening',
                @DescriptionEn   = @DescEn,
                @DescriptionAr   = @DescAr,
                @SourceReference = @CustomerId,
                @BranchId        = @BranchId,
                @Actor           = @Actor,
                @PostedAtUtc     = @PostedAt,
                @Lines           = @Lines,
                @EntryId         = @EntryId OUTPUT;
        END

    COMMIT;
END
GO

/*------------------------------------------------------- rebuild balances */

/* Reconcile the denormalised customer balance against everything the
   statement shows: credit sales, opening balances, collections (a reversal
   nets its collection out) and credit notes refunded to the account. */
CREATE OR ALTER PROCEDURE fin.usp_RebuildCustomerBalances
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Charged AS (
        SELECT s.CustomerId, SUM(p.AmountH) AS AmountH
        FROM sales.Sale AS s
        JOIN sales.SalePayment AS p ON p.SaleId = s.SaleId AND p.Method = N'credit'
        WHERE s.CustomerId IS NOT NULL AND s.Status <> N'voided'
        GROUP BY s.CustomerId
    ),
    Posted AS (
        /* Opening balances raise it, collections lower it; reversal entries
           carry the same kind and source, so they cancel what they reverse. */
        SELECT e.SourceReference AS CustomerId, SUM(l.DebitH - l.CreditH) AS AmountH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId AND l.AccountCode = N'1400'
        WHERE e.Kind IN (N'customer_collection', N'customer_opening')
        GROUP BY e.SourceReference
    ),
    Credited AS (
        SELECT r.CustomerId, SUM(r.RefundH) AS AmountH
        FROM sales.SaleReturn AS r
        WHERE r.CustomerId IS NOT NULL AND r.RefundMethod = N'credit'
        GROUP BY r.CustomerId
    )
    UPDATE c
    SET BalanceH = ISNULL(ch.AmountH, 0) + ISNULL(po.AmountH, 0) - ISNULL(cr.AmountH, 0),
        UpdatedAtUtc = SYSUTCDATETIME()
    FROM core.Customer AS c
    LEFT JOIN Charged  AS ch ON ch.CustomerId = c.CustomerId
    LEFT JOIN Posted   AS po ON po.CustomerId = c.CustomerId
    LEFT JOIN Credited AS cr ON cr.CustomerId = c.CustomerId;
END
GO

PRINT N'012 · Customer opening balances post to the ledger; creates are checked.';
GO
