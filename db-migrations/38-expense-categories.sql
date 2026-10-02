/*==============================================================================
  Nazad POS — 38 · Expense categories

  Backs POST /api/expenses/categories and PUT /api/expenses/categories/{id}.

  A category maps expenses onto one ledger account. Only expense accounts may be
  chosen (fin.Account.AccountType = 'expense'), and not 5100: cost of goods
  sold is posted by sales and returns alone, and an expense booked there would
  distort gross margin.

  Schema
    - fin.ExpenseCategory gains CreatedAtUtc, UpdatedAtUtc, CreatedBy,
      UpdatedBy.
    - core.usp_SetActive is re-issued with two changes over 21:
        * the vendor guard counts only purchases with something still owed
          (inv.Purchase.PaidH, added in 35), so a paid-off vendor can be
          switched off;
        * deactivating an expense category stamps UpdatedAtUtc.
      Everything else in it is unchanged.

  Error numbers 69000–69049.
==============================================================================*/

USE POSMAIN;
GO

IF COL_LENGTH(N'fin.ExpenseCategory', N'CreatedAtUtc') IS NULL
    ALTER TABLE fin.ExpenseCategory ADD
        CreatedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_ExpenseCategory_Created DEFAULT (SYSUTCDATETIME()),
        UpdatedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_ExpenseCategory_Updated DEFAULT (SYSUTCDATETIME()),
        CreatedBy    NVARCHAR(120) NULL,
        UpdatedBy    NVARCHAR(120) NULL;
GO

CREATE OR ALTER PROCEDURE fin.usp_SaveExpenseCategory
    @CategoryId  NVARCHAR(40) = NULL,   -- null creates
    @NameAr      NVARCHAR(120),
    @NameEn      NVARCHAR(120),
    @AccountCode NVARCHAR(10),
    @IsActive    BIT = NULL,            -- null keeps (active on create)
    @Actor       NVARCHAR(120),
    @SavedId     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NameAr = NULLIF(LTRIM(RTRIM(@NameAr)), N'');
    SET @NameEn = NULLIF(LTRIM(RTRIM(@NameEn)), N'');

    IF @NameAr IS NULL OR @NameEn IS NULL
        THROW 69000, N'Both names are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM fin.Account
                   WHERE AccountCode = @AccountCode AND AccountType = N'expense'
                     AND IsActive = 1 AND AccountCode <> N'5100')
        THROW 69001, N'Choose an expense account.', 1;

    IF EXISTS (SELECT 1 FROM fin.ExpenseCategory
               WHERE NameEn = @NameEn AND (@CategoryId IS NULL OR CategoryId <> @CategoryId))
        THROW 69002, N'Another category already uses this name.', 1;

    IF @CategoryId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.ExpenseCategory WHERE CategoryId = @CategoryId)
        THROW 69003, N'Expense category not found.', 1;

    /* An active schedule would keep posting into a category nobody can pick. */
    IF @CategoryId IS NOT NULL AND @IsActive = 0
       AND EXISTS (SELECT 1 FROM fin.RecurringPayment WHERE CategoryId = @CategoryId AND Status = N'active')
        THROW 69004, N'Active recurring payments still use this category.', 1;

    IF @CategoryId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'exc_', LEFT(LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')), 20));

        INSERT INTO fin.ExpenseCategory
            (CategoryId, NameAr, NameEn, AccountCode, IsActive, CreatedBy, UpdatedBy)
        VALUES
            (@SavedId, @NameAr, @NameEn, @AccountCode, ISNULL(@IsActive, 1), @Actor, @Actor);
    END
    ELSE
    BEGIN
        SET @SavedId = @CategoryId;

        UPDATE fin.ExpenseCategory
        SET NameAr = @NameAr, NameEn = @NameEn, AccountCode = @AccountCode,
            IsActive = ISNULL(@IsActive, IsActive),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE CategoryId = @CategoryId;
    END
END
GO

CREATE OR ALTER PROCEDURE core.usp_SetActive
    @EntityType  NVARCHAR(40),
    @EntityId    NVARCHAR(40),
    @IsActive    BIT,
    @Actor       NVARCHAR(160),
    @Blocked     NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Blocked = NULL;

    /*-------------------------------------------------- what may be deactivated */

    IF @EntityType NOT IN (N'item', N'category', N'printGroup', N'vendor',
                           N'customer', N'discount', N'expenseCategory',
                           N'commissionRule', N'billTemplate', N'branch')
    BEGIN
        THROW 57000, N'That kind of record cannot be activated or deactivated.', 1;
    END

    /*----------------------------------------------------- deactivation guards */

    /*
      Refusing is kinder than cascading.

      Deactivating a category that still holds live items would either orphan
      them or silently hide them from the till — and the person clicking the
      toggle would have no idea which. Naming what is in the way lets them
      decide.

      Reactivating is never blocked: a guard that applied in both directions
      would trap a record permanently.
    */
    IF @IsActive = 0
    BEGIN
        IF @EntityType = N'category'
           AND EXISTS (SELECT 1 FROM core.CatalogItem
                       WHERE CategoryId = @EntityId AND IsActive = 1)
        BEGIN
            SET @Blocked = CONCAT(
                N'This category still has ',
                (SELECT COUNT(*) FROM core.CatalogItem
                 WHERE CategoryId = @EntityId AND IsActive = 1),
                N' active items. Move or deactivate them first.');
            RETURN;
        END

        IF @EntityType = N'printGroup'
           AND EXISTS (SELECT 1 FROM core.CatalogItem
                       WHERE PrintGroupId = @EntityId AND IsActive = 1)
        BEGIN
            SET @Blocked = N'This print group is still used by active items. '
                         + N'Reassign them first, or their tickets will not print.';
            RETURN;
        END

        /* Money owed does not disappear because a record was switched off. */
        IF @EntityType = N'customer'
           AND EXISTS (SELECT 1 FROM core.Customer
                       WHERE CustomerId = @EntityId AND BalanceH > 0)
        BEGIN
            SET @Blocked = N'This customer still owes money. '
                         + N'Settle the balance before deactivating.';
            RETURN;
        END

        /*
          A vendor's debt is not a column.

          What is owed is the unsettled part of purchases not paid on receipt
          (TotalH - PaidH, kept by inv.usp_RecordVendorPayment). A purchase that
          has been paid off no longer blocks the vendor.
        */
        IF @EntityType = N'vendor'
           AND EXISTS (SELECT 1 FROM inv.Purchase
                       WHERE VendorId = @EntityId AND PaidOnReceipt = 0 AND PaidH < TotalH)
        BEGIN
            SET @Blocked = CONCAT(
                N'This vendor has ',
                (SELECT COUNT(*) FROM inv.Purchase
                 WHERE VendorId = @EntityId AND PaidOnReceipt = 0 AND PaidH < TotalH),
                N' unpaid deliveries. Settle them before deactivating.');
            RETURN;
        END

        /* A branch with an open drawer or period has work in progress. */
        IF @EntityType = N'branch'
        BEGIN
            IF EXISTS (SELECT 1 FROM fin.DrawerSession
                       WHERE BranchId = @EntityId AND ClosedAtUtc IS NULL)
            BEGIN
                SET @Blocked = N'This branch has an open cash drawer. Close it first.';
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM fin.BalancePeriod
                       WHERE BranchId = @EntityId AND Status = N'open')
            BEGIN
                SET @Blocked = N'This branch has an open balance period. Close it first.';
                RETURN;
            END

            /* The last active branch cannot go: the till would have nowhere to sell. */
            IF (SELECT COUNT(*) FROM core.Branch WHERE IsActive = 1) <= 1
            BEGIN
                SET @Blocked = N'This is the only active branch. At least one must remain.';
                RETURN;
            END
        END
    END

    /*---------------------------------------------------------------- the write */

    /*
      An explicit branch per type, setting only the columns that table has.

      A concatenated UPDATE would be shorter and would also accept whatever
      @EntityType contained — a parameter reaching sys.objects unchecked is an
      injection route. There is no dynamic SQL in this file.
    */
    IF @EntityType = N'item'
        UPDATE core.CatalogItem
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME(),
               UpdatedBy = @Actor
        WHERE  ItemId = @EntityId;
    ELSE
    IF @EntityType = N'category'
        UPDATE core.Category
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  CategoryId = @EntityId;
    ELSE
    IF @EntityType = N'printGroup'
        UPDATE core.PrintGroup
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  PrintGroupId = @EntityId;
    ELSE
    IF @EntityType = N'vendor'
        UPDATE core.Vendor
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME(),
               UpdatedBy = @Actor
        WHERE  VendorId = @EntityId;
    ELSE
    IF @EntityType = N'customer'
        UPDATE core.Customer
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME(),
               UpdatedBy = @Actor
        WHERE  CustomerId = @EntityId;
    ELSE
    IF @EntityType = N'discount'
        UPDATE sales.Discount
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  DiscountId = @EntityId;
    ELSE
    IF @EntityType = N'expenseCategory'
        UPDATE fin.ExpenseCategory
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  CategoryId = @EntityId;
    ELSE
    IF @EntityType = N'commissionRule'
        UPDATE fin.CommissionRule
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  RuleId = @EntityId;
    ELSE
    IF @EntityType = N'billTemplate'
        UPDATE core.BillTemplate
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  BillId = @EntityId;
    ELSE
    IF @EntityType = N'branch'
        UPDATE core.Branch
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  BranchId = @EntityId;

    IF @@ROWCOUNT = 0
        THROW 57001, N'No such record.', 1;
END
GO
GO

PRINT N'38 · Expense categories ready.';
GO

SELECT CASE WHEN OBJECT_ID(N'fin.usp_SaveExpenseCategory') IS NULL THEN N'FAIL  save proc missing'
            WHEN COL_LENGTH(N'fin.ExpenseCategory', N'UpdatedAtUtc') IS NULL THEN N'FAIL  timestamps missing'
            WHEN OBJECT_DEFINITION(OBJECT_ID(N'core.usp_SetActive')) NOT LIKE N'%PaidH < TotalH%'
                 THEN N'FAIL  vendor guard not updated'
            ELSE N'PASS  Expense categories ready' END AS Result;
GO
