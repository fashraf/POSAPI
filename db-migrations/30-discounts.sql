/*==============================================================================
  Nazad POS — 30 · Discounts

  Backs POST/PUT/DELETE /api/discounts.

  sales.usp_SaveDiscount as captured in 25 could not save anything: it checked
  for types 'percent'/'amount' while the table only accepts 'percentage'/
  'fixed', defaulted AppliesTo to 'sale' (not allowed) and passed NULL into the
  NOT NULL ActiveDays. This replaces it.

  Schema, kept to what the discount screen already edits:
    - sales.Discount gains Description.
    - sales.Discount.AppliesTo also accepts 'selected': named items and
      categories together, which is what the screen offers. 'item' and
      'category' stay valid for existing rows.
    - sales.DiscountScope.ScopeType also accepts 'branch' and 'role'. "Runs in
      these branches" and "these roles may apply it" are the same shape as
      "applies to these items" — a set of keys on the discount — so they share
      the table rather than adding two more.
    - Permission discounts.delete is seeded for owner and manager.

  Values follow the table: a percentage is basis points of a percent
  (1000 = 10%), a fixed amount is halalas.

  Error numbers 63000–63049.
==============================================================================*/

USE POSMAIN;
GO

/*---------------------------------------------------------------------- schema */

IF COL_LENGTH(N'sales.Discount', N'Description') IS NULL
    ALTER TABLE sales.Discount ADD Description NVARCHAR(400) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = N'CK_Discount_Applies'
             AND definition NOT LIKE N'%selected%')
    ALTER TABLE sales.Discount DROP CONSTRAINT CK_Discount_Applies;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Discount_Applies')
    ALTER TABLE sales.Discount ADD CONSTRAINT CK_Discount_Applies
        CHECK (AppliesTo IN (N'all', N'products', N'services', N'selected', N'item', N'category'));
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = N'CK_DiscountScope_Type'
             AND definition NOT LIKE N'%branch%')
    ALTER TABLE sales.DiscountScope DROP CONSTRAINT CK_DiscountScope_Type;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_DiscountScope_Type')
    ALTER TABLE sales.DiscountScope ADD CONSTRAINT CK_DiscountScope_Type
        CHECK (ScopeType IN (N'item', N'category', N'branch', N'role'));
GO

/*----------------------------------------------------------------- permission */

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
SELECT N'discounts.delete', N'discounts', N'delete', N'general'
WHERE NOT EXISTS (SELECT 1 FROM core.Permission WHERE PermissionKey = N'discounts.delete');
GO

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT r.RoleId, N'discounts.delete'
FROM core.Role AS r
WHERE r.RoleId IN (N'rol_owner', N'rol_manager')
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionKey = N'discounts.delete');
GO

/*-------------------------------------------------------------- save discount */

CREATE OR ALTER PROCEDURE sales.usp_SaveDiscount
    @DiscountId     NVARCHAR(40)  = NULL,   -- null creates
    @NameAr         NVARCHAR(160),
    @NameEn         NVARCHAR(160),
    @Description    NVARCHAR(400) = NULL,
    @DiscountType   NVARCHAR(20),           -- percentage | fixed
    @Value          INT,                    -- basis points, or halalas
    @MaxDiscountH   BIGINT = NULL,          -- null: no cap
    @MinSubtotalH   BIGINT = 0,
    @ApprovalAboveH BIGINT = NULL,          -- null: never needs approval
    @AppliesTo      NVARCHAR(20) = N'all',  -- all | products | services | selected
    @AppliesToIds   NVARCHAR(MAX) = NULL,   -- item and category ids, comma separated
    @BranchIds      NVARCHAR(MAX) = NULL,   -- empty: every branch
    @RoleIds        NVARCHAR(MAX) = NULL,   -- empty: anyone at the till
    @IsAutomatic    BIT = 0,
    @AllowStacking  BIT = 0,
    @ActiveDays     NVARCHAR(20) = N'',     -- 0 = Sunday, comma separated; empty: every day
    @StartsOn       DATE = NULL,
    @EndsOn         DATE = NULL,
    @IsActive       BIT = 1,
    @SavedId        NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 63000, N'Both names are required.', 1;

    IF @DiscountId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Discount WHERE DiscountId = @DiscountId)
        THROW 63015, N'No such discount.', 1;

    IF EXISTS (SELECT 1 FROM sales.Discount
               WHERE NameEn = @NameEn AND (@DiscountId IS NULL OR DiscountId <> @DiscountId))
        THROW 63014, N'Another discount already uses this name.', 1;

    IF @DiscountType NOT IN (N'percentage', N'fixed')
        THROW 63001, N'A discount is either a percentage or a fixed amount.', 1;

    IF ISNULL(@Value, 0) <= 0
        THROW 63002, N'Enter a value above zero, or the discount does nothing.', 1;

    /* A percentage above 100 would pay the customer to take the goods. */
    IF @DiscountType = N'percentage' AND @Value > 10000
        THROW 63003, N'A percentage discount cannot exceed 100%.', 1;

    IF @MaxDiscountH < 0
        THROW 63004, N'A maximum cannot be negative.', 1;

    IF ISNULL(@MinSubtotalH, 0) < 0
        THROW 63005, N'A minimum cannot be negative.', 1;

    IF @ApprovalAboveH < 0
        THROW 63006, N'An approval threshold cannot be negative.', 1;

    /* A fixed discount capped below itself is always clipped — almost certainly
       a typo rather than a decision. */
    IF @DiscountType = N'fixed' AND @MaxDiscountH > 0 AND @MaxDiscountH < @Value
        THROW 63017, N'The maximum is below the discount itself, so it would always be clipped.', 1;

    IF @EndsOn IS NOT NULL AND @StartsOn IS NOT NULL AND @EndsOn < @StartsOn
        THROW 63007, N'The end date cannot be before the start date.', 1;

    IF @AppliesTo NOT IN (N'all', N'products', N'services', N'selected')
        THROW 63008, N'Applies to all, products, services or selected.', 1;

    /*------------------------------------------------------------- the sets */

    DECLARE @Scope TABLE (ScopeType NVARCHAR(20), ScopeKey NVARCHAR(40),
                          PRIMARY KEY (ScopeType, ScopeKey));

    DECLARE @Targets TABLE (Id NVARCHAR(40) PRIMARY KEY);
    INSERT INTO @Targets (Id)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@AppliesToIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    /* Item and category ids share one list on the screen; which is which is
       looked up, not trusted from the client. */
    IF @AppliesTo = N'selected'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM @Targets)
            THROW 63009, N'Choose at least one item or category, or switch to "All".', 1;

        IF EXISTS (SELECT 1 FROM @Targets AS t
                   WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem WHERE ItemId = t.Id)
                     AND NOT EXISTS (SELECT 1 FROM core.Category WHERE CategoryId = t.Id))
            THROW 63010, N'One of those items or categories does not exist.', 1;

        INSERT INTO @Scope (ScopeType, ScopeKey)
        SELECT CASE WHEN EXISTS (SELECT 1 FROM core.CatalogItem WHERE ItemId = t.Id)
                    THEN N'item' ELSE N'category' END, t.Id
        FROM @Targets AS t;
    END

    INSERT INTO @Scope (ScopeType, ScopeKey)
    SELECT DISTINCT N'branch', LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@BranchIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF EXISTS (SELECT 1 FROM @Scope AS s WHERE s.ScopeType = N'branch'
               AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = s.ScopeKey))
        THROW 63011, N'One of those branches does not exist.', 1;

    INSERT INTO @Scope (ScopeType, ScopeKey)
    SELECT DISTINCT N'role', LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@RoleIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF EXISTS (SELECT 1 FROM @Scope AS s WHERE s.ScopeType = N'role'
               AND NOT EXISTS (SELECT 1 FROM core.Role WHERE RoleId = s.ScopeKey))
        THROW 63012, N'One of those roles does not exist.', 1;

    SET @ActiveDays = ISNULL(@ActiveDays, N'');

    IF EXISTS (SELECT 1 FROM STRING_SPLIT(@ActiveDays, N',')
               WHERE LTRIM(RTRIM(value)) NOT IN (N'0', N'1', N'2', N'3', N'4', N'5', N'6')
                 AND @ActiveDays <> N'')
        THROW 63013, N'Days of the week are 0 (Sunday) to 6.', 1;

    /*------------------------------------------------------------- write */

    BEGIN TRAN;

        IF @DiscountId IS NULL
        BEGIN
            SET @SavedId = CONCAT(N'dsc_',
                LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

            INSERT INTO sales.Discount
                (DiscountId, NameAr, NameEn, Description, DiscountType, Value, MaxDiscountH,
                 MinSubtotalH, ApprovalAboveH, AppliesTo, IsAutomatic, AllowStacking,
                 ActiveDays, StartsOn, EndsOn, IsActive)
            VALUES
                (@SavedId, @NameAr, @NameEn, @Description, @DiscountType, @Value, @MaxDiscountH,
                 ISNULL(@MinSubtotalH, 0), @ApprovalAboveH, @AppliesTo, @IsAutomatic, @AllowStacking,
                 @ActiveDays, @StartsOn, @EndsOn, @IsActive);
        END
        ELSE
        BEGIN
            SET @SavedId = @DiscountId;

            /* UsageCount is not touched. It records how often this discount has
               been applied; an edit must not reset that history. */
            UPDATE sales.Discount
            SET NameAr = @NameAr, NameEn = @NameEn, Description = @Description,
                DiscountType = @DiscountType, Value = @Value, MaxDiscountH = @MaxDiscountH,
                MinSubtotalH = ISNULL(@MinSubtotalH, 0), ApprovalAboveH = @ApprovalAboveH,
                AppliesTo = @AppliesTo, IsAutomatic = @IsAutomatic, AllowStacking = @AllowStacking,
                ActiveDays = @ActiveDays, StartsOn = @StartsOn, EndsOn = @EndsOn,
                IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE DiscountId = @DiscountId;
        END

        /* Replaced wholesale, like every other set on a record. */
        DELETE FROM sales.DiscountScope WHERE DiscountId = @SavedId;

        INSERT INTO sales.DiscountScope (DiscountId, ScopeType, ScopeKey)
        SELECT @SavedId, ScopeType, ScopeKey FROM @Scope;

    COMMIT;
END
GO

/*------------------------------------------------------------ delete discount */

/*
  Delete only what was never used.

  A discount applied to a sale is named by that sale; removing it would leave
  the invoice pointing at nothing. Those are refused, and the answer is to
  deactivate them. One that was set up and never used is a mistake, and a
  mistake should be removable.
*/
CREATE OR ALTER PROCEDURE sales.usp_DeleteDiscount
    @DiscountId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Used INT = (SELECT UsageCount FROM sales.Discount WHERE DiscountId = @DiscountId);

    IF @Used IS NULL
        THROW 63015, N'No such discount.', 1;

    IF @Used > 0 OR EXISTS (SELECT 1 FROM sales.Sale WHERE DiscountId = @DiscountId)
        THROW 63016, N'This discount has been used on real sales. Deactivate it instead so the history stays intact.', 1;

    /* DiscountScope cascades. */
    DELETE FROM sales.Discount WHERE DiscountId = @DiscountId;
END
GO

PRINT N'30 · Discounts ready.';
GO

SELECT
    CASE WHEN COL_LENGTH(N'sales.Discount', N'Description') IS NULL
              THEN N'FAIL  sales.Discount.Description missing'
         WHEN NOT EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = N'CK_DiscountScope_Type' AND definition LIKE N'%role%')
              THEN N'FAIL  scope types not extended'
         WHEN OBJECT_ID(N'sales.usp_DeleteDiscount') IS NULL
              THEN N'FAIL  procedures missing'
         WHEN (SELECT COUNT(*) FROM core.RolePermission WHERE PermissionKey = N'discounts.delete') < 2
              THEN N'FAIL  permission grants incomplete'
         ELSE N'PASS  Discounts ready'
    END AS Result;
GO
