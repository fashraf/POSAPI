/*==============================================================================
  Nazad POS — 40 · Opening balances

  Backs GET and POST /api/finance/opening-balances.

  The starting position is one journal entry (Kind 'opening_balance'), posted
  once per scope — the whole business (BranchId NULL) or one branch:
      Dr 1000 cash          Dr 1100 bank          Dr 1200 inventory
      Dr 1400 receivables   Cr 2000 payables
      Cr 2100 VAT owed (vatH > 0)  or  Dr 1300 VAT reclaimable (vatH < 0)
      Cr 3900 opening balance suspense = assets - liabilities
              (Dr 3900 when liabilities exceed assets)
  3900 is the honest placeholder for "owner's equity at the start": an
  accountant can reclassify it to 3000 later with a manual entry.

  A second posting for the same scope is refused while the first stands. To
  correct one, reverse its entry (POST /api/finance/ledger/{entryId}/reverse);
  the record then reads as reversed and a new posting is allowed. Whether a
  posting stands is read from its journal entry (ReversedByEntryId), never
  stored twice.

  The receivables and payables figures go to 1400 and 2000 as totals. They are
  not spread over individual customers or vendors (no customer or vendor
  balance changes), so per-customer and per-vendor screens start from zero.

  Schema: fin.OpeningBalance. Permission finance.opening_balances (owner).

  Error numbers 70000–70049.
==============================================================================*/

USE POSMAIN;
GO

IF OBJECT_ID(N'fin.OpeningBalance') IS NULL
BEGIN
    CREATE TABLE fin.OpeningBalance
    (
        OpeningId     NVARCHAR(40)  NOT NULL CONSTRAINT PK_OpeningBalance PRIMARY KEY,
        BranchId      NVARCHAR(40)  NULL     CONSTRAINT FK_OpeningBalance_Branch REFERENCES core.Branch (BranchId),
        AsOf          DATE          NOT NULL,
        CashH         BIGINT        NOT NULL,
        BankH         BIGINT        NOT NULL,
        InventoryH    BIGINT        NOT NULL,
        ReceivablesH  BIGINT        NOT NULL,
        PayablesH     BIGINT        NOT NULL,
        VatH          BIGINT        NOT NULL,   -- signed: + owed to the authority
        EquityH       BIGINT        NOT NULL,   -- signed: assets - liabilities
        EntryId       NVARCHAR(40)  NOT NULL CONSTRAINT FK_OpeningBalance_Entry REFERENCES fin.JournalEntry (EntryId),
        Note          NVARCHAR(400) NULL,
        PostedAtUtc   DATETIME2(3)  NOT NULL CONSTRAINT DF_OpeningBalance_Posted DEFAULT (SYSUTCDATETIME()),
        PostedBy      NVARCHAR(120) NOT NULL,
        CONSTRAINT CK_OpeningBalance_NonNegative CHECK
            (CashH >= 0 AND BankH >= 0 AND InventoryH >= 0 AND ReceivablesH >= 0 AND PayablesH >= 0)
    );

    CREATE INDEX IX_OpeningBalance_Branch ON fin.OpeningBalance (BranchId, PostedAtUtc);
END
GO

CREATE OR ALTER PROCEDURE fin.usp_PostOpeningBalances
    @BranchId     NVARCHAR(40) = NULL,
    @AsOf         DATE,
    @CashH        BIGINT = 0,
    @BankH        BIGINT = 0,
    @InventoryH   BIGINT = 0,
    @ReceivablesH BIGINT = 0,
    @PayablesH    BIGINT = 0,
    @VatH         BIGINT = 0,
    @Note         NVARCHAR(400) = NULL,
    @Actor        NVARCHAR(120),
    @OpeningId    NVARCHAR(40) OUTPUT,
    @EntryId      NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AsOf IS NULL
        THROW 70001, N'Choose the date the balances are as of.', 1;

    IF @CashH < 0 OR @BankH < 0 OR @InventoryH < 0 OR @ReceivablesH < 0 OR @PayablesH < 0
        THROW 70002, N'Opening balances cannot be negative.', 1;

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId)
        THROW 70003, N'Unknown branch.', 1;

    DECLARE @AssetsH      BIGINT = ISNULL(@CashH, 0) + ISNULL(@BankH, 0) + ISNULL(@InventoryH, 0) + ISNULL(@ReceivablesH, 0)
                                   + CASE WHEN @VatH < 0 THEN -@VatH ELSE 0 END;
    DECLARE @LiabilitiesH BIGINT = ISNULL(@PayablesH, 0) + CASE WHEN @VatH > 0 THEN @VatH ELSE 0 END;
    DECLARE @EquityH      BIGINT = @AssetsH - @LiabilitiesH;

    IF @AssetsH = 0 AND @LiabilitiesH = 0
        THROW 70004, N'Enter at least one opening figure.', 1;

    BEGIN TRAN;

        /* One standing posting per scope. The range lock stops two at once. */
        IF EXISTS (SELECT 1
                   FROM fin.OpeningBalance AS o WITH (UPDLOCK, HOLDLOCK)
                   JOIN fin.JournalEntry AS e ON e.EntryId = o.EntryId
                   WHERE ISNULL(o.BranchId, N'') = ISNULL(@BranchId, N'')
                     AND e.ReversedByEntryId IS NULL)
            THROW 70000, N'Opening balances have already been posted. Reverse the entry in the ledger to correct them.', 1;

        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1000', @CashH, 0, N'Opening cash'),
            (N'1100', @BankH, 0, N'Opening bank'),
            (N'1200', @InventoryH, 0, N'Opening inventory'),
            (N'1400', @ReceivablesH, 0, N'Opening receivables'),
            (N'2000', 0, @PayablesH, N'Opening payables'),
            (N'2100', 0, CASE WHEN @VatH > 0 THEN @VatH ELSE 0 END, N'Opening VAT owed'),
            (N'1300', CASE WHEN @VatH < 0 THEN -@VatH ELSE 0 END, 0, N'Opening VAT reclaimable'),
            (N'3900', CASE WHEN @EquityH < 0 THEN -@EquityH ELSE 0 END,
                      CASE WHEN @EquityH > 0 THEN @EquityH ELSE 0 END, N'Opening equity');

        EXEC fin.usp_PostJournalEntry
            @Kind            = N'opening_balance',
            @DescriptionEn   = N'Opening balances',
            @DescriptionAr   = N'الأرصدة الافتتاحية',
            @SourceReference = N'OPENING',
            @BranchId        = @BranchId,
            @Actor           = @Actor,
            @PostedAtUtc     = @AsOf,
            @Lines           = @Entry,
            @EntryId         = @EntryId OUTPUT;

        SET @OpeningId = CONCAT(N'opn_', LEFT(LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')), 20));

        INSERT INTO fin.OpeningBalance
            (OpeningId, BranchId, AsOf, CashH, BankH, InventoryH, ReceivablesH, PayablesH,
             VatH, EquityH, EntryId, Note, PostedBy)
        VALUES
            (@OpeningId, @BranchId, @AsOf, @CashH, @BankH, @InventoryH, @ReceivablesH, @PayablesH,
             @VatH, @EquityH, @EntryId, NULLIF(LTRIM(RTRIM(@Note)), N''), @Actor);

    COMMIT;
END
GO

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
SELECT N'finance.opening_balances', N'finance', N'opening_balances', N'financial'
WHERE NOT EXISTS (SELECT 1 FROM core.Permission WHERE PermissionKey = N'finance.opening_balances');
GO

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT N'rol_owner', N'finance.opening_balances'
WHERE EXISTS (SELECT 1 FROM core.Role WHERE RoleId = N'rol_owner')
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission
                  WHERE RoleId = N'rol_owner' AND PermissionKey = N'finance.opening_balances');
GO

PRINT N'40 · Opening balances ready.';
GO

SELECT CASE WHEN OBJECT_ID(N'fin.usp_PostOpeningBalances') IS NULL THEN N'FAIL  proc missing'
            WHEN NOT EXISTS (SELECT 1 FROM core.RolePermission
                             WHERE RoleId = N'rol_owner' AND PermissionKey = N'finance.opening_balances')
                 THEN N'FAIL  permission missing'
            ELSE N'PASS  Opening balances ready' END AS Result;
GO
