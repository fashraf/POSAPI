/*==============================================================================
  Nazad POS — 21 · Activate and deactivate  (corrected)

  Deactivating is not deleting. An item sold last month must keep appearing on
  that invoice, in that month's reports, and in the stock movements that explain
  its quantity. So nothing is removed: IsActive becomes 0, the row stays.

  Corrections over the first version, each from reading the schema rather than
  assuming it:
    - core.Vendor has no BalanceH. Vendor debt is not held on the vendor row, so
      the guard now counts unpaid purchases, which is where it actually lives.
    - Six of these ten tables have no UpdatedBy, and fin.ExpenseCategory has no
      UpdatedAtUtc either. Each UPDATE now sets only columns that exist.
    - core.Permission.Sensitivity is NOT NULL. Passing NULL overrode its
      default; it is now given a value.
==============================================================================*/

USE POSMAIN;
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

          core.Vendor tracks no balance — what is owed sits in unpaid purchases,
          and in the ledger's payables account. Counting the purchases is the
          check that matches how the data is actually kept.
        */
        IF @EntityType = N'vendor'
           AND EXISTS (SELECT 1 FROM inv.Purchase
                       WHERE VendorId = @EntityId AND PaidOnReceipt = 0)
        BEGIN
            SET @Blocked = CONCAT(
                N'This vendor has ',
                (SELECT COUNT(*) FROM inv.Purchase
                 WHERE VendorId = @EntityId AND PaidOnReceipt = 0),
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
        SET    IsActive = @IsActive
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

PRINT N'21 · core.usp_SetActive ready.';
GO

/*------------------------------------------------------------------ permission */

/* Sensitivity is NOT NULL. The first version passed NULL, which overrode the
   column default and failed the insert — taking the role grant with it. */
INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
SELECT N'catalog.activate', N'products', N'activate', N'general'
WHERE NOT EXISTS (SELECT 1 FROM core.Permission
                  WHERE PermissionKey = N'catalog.activate');
GO

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT r.RoleId, N'catalog.activate'
FROM core.Role AS r
WHERE r.RoleId IN (N'rol_owner', N'rol_manager')
  AND EXISTS (SELECT 1 FROM core.Permission
              WHERE PermissionKey = N'catalog.activate')
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                  WHERE rp.RoleId = r.RoleId
                    AND rp.PermissionKey = N'catalog.activate');
GO

/*----------------------------------------------------------------------- check */

SELECT
    CASE WHEN OBJECT_ID(N'core.usp_SetActive') IS NULL
              THEN N'FAIL  The procedure was not created'
         WHEN NOT EXISTS (SELECT 1 FROM core.Permission
                          WHERE PermissionKey = N'catalog.activate')
              THEN N'FAIL  The permission was not seeded'
         WHEN (SELECT COUNT(*) FROM core.RolePermission
               WHERE PermissionKey = N'catalog.activate') < 2
              THEN N'FAIL  The role grants are incomplete'
         ELSE N'PASS  Activation ready'
    END AS Result;
GO
