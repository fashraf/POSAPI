/*==============================================================================
  Nazad POS — 25 · Admin save procedures (captured)

  These eight procedures were created on the development database outside the
  migration scripts, so a fresh install did not have them:

    core.usp_SaveUser, core.usp_SetUserBranches, core.usp_SetUserOverrides,
    core.usp_SaveCompany, core.usp_SaveBillTemplate, core.usp_SaveCategory,
    sales.usp_SaveDiscount, fin.usp_SaveCommissionRule

  This file is each of them exactly as found, so every install starts from the
  same definitions. Migrations 26–31 then replace the ones the API calls —
  several of these no longer match their tables' CHECK constraints (discount
  types 'percent'/'amount' against 'percentage'/'fixed', commission bases that
  the table refuses), so as captured they cannot save a row. Keeping the
  originals here, unchanged, is what makes that history readable.
==============================================================================*/

USE POSMAIN;
GO

/*==================================================================== users */

CREATE OR ALTER PROCEDURE core.usp_SaveUser
    @UserId          NVARCHAR(40) = NULL,
    @Username        NVARCHAR(80),
    @NameAr          NVARCHAR(200),
    @NameEn          NVARCHAR(200),
    @Email           NVARCHAR(200) = NULL,
    @Phone           NVARCHAR(40)  = NULL,
    @RoleId          NVARCHAR(40),
    @Status          NVARCHAR(20)  = N'active',
    @IsExternal      BIT = 0,
    @AccessExpiresOn DATE = NULL,
    @BaseSalaryH     BIGINT = 0,
    @Actor           NVARCHAR(160),
    @SavedId         NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@Username, N''))) = N''
        THROW 59030, N'A username is required.', 1;

    IF EXISTS (SELECT 1 FROM core.AppUser
               WHERE Username = @Username AND (@UserId IS NULL OR UserId <> @UserId))
        THROW 59031, N'That username is already taken.', 1;

    /* Sign-in matches on email or phone, so a duplicate would make which
       account you reach a matter of row order. */
    IF @Email IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.AppUser
        WHERE Email = @Email AND (@UserId IS NULL OR UserId <> @UserId))
        THROW 59032, N'That email is already used by another account.', 1;

    IF @Phone IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.AppUser
        WHERE Phone = @Phone AND (@UserId IS NULL OR UserId <> @UserId))
        THROW 59033, N'That mobile number is already used by another account.', 1;

    IF NOT EXISTS (SELECT 1 FROM core.Role WHERE RoleId = @RoleId)
        THROW 59034, N'No such role.', 1;

    /* An external account without an expiry never expires, which defeats the
       reason for marking it external. */
    IF @IsExternal = 1 AND @AccessExpiresOn IS NULL
        THROW 59035, N'An external account needs an access expiry date.', 1;

    IF @UserId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'usr_',
            LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        /* No password is set here. It arrives through the sign-in flow, so a
           password never passes through an admin form or an audit row. */
        INSERT INTO core.AppUser
            (UserId, Username, NameAr, NameEn, Email, Phone, RoleId, Status,
             IsExternal, AccessExpiresOn, BaseSalaryH, CreatedBy)
        VALUES
            (@SavedId, @Username, @NameAr, @NameEn, @Email, @Phone, @RoleId, @Status,
             @IsExternal, @AccessExpiresOn, @BaseSalaryH, @Actor);
    END
    ELSE
    BEGIN
        SET @SavedId = @UserId;

        /* The last active owner cannot be suspended or demoted: someone has to
           be able to grant permissions back. */
        IF (@Status <> N'active' OR @RoleId <> N'rol_owner')
           AND EXISTS (SELECT 1 FROM core.AppUser
                       WHERE UserId = @UserId AND RoleId = N'rol_owner' AND Status = N'active')
           AND (SELECT COUNT(*) FROM core.AppUser
                WHERE RoleId = N'rol_owner' AND Status = N'active') <= 1
            THROW 59036, N'This is the only active owner. Appoint another first.', 1;

        UPDATE core.AppUser
        SET Username = @Username, NameAr = @NameAr, NameEn = @NameEn,
            Email = @Email, Phone = @Phone, RoleId = @RoleId, Status = @Status,
            IsExternal = @IsExternal, AccessExpiresOn = @AccessExpiresOn,
            BaseSalaryH = @BaseSalaryH,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE UserId = @UserId;

        IF @@ROWCOUNT = 0 THROW 59037, N'No such user.', 1;
    END
END

GO


/*=========================================================== branch access */

/*
  Which branches a person may work in.

  Replaced wholesale rather than added to. A grant-and-revoke pair drifts: the
  screen shows a set, and applying a diff means two round trips that can half
  succeed, leaving access nobody chose.
*/
CREATE OR ALTER PROCEDURE core.usp_SetUserBranches
    @UserId    NVARCHAR(40),
    @BranchIds NVARCHAR(MAX),        -- comma separated
    @Blocked   NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Blocked = NULL;

    IF NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = @UserId)
        THROW 60000, N'No such user.', 1;

    DECLARE @Wanted TABLE (BranchId NVARCHAR(40) PRIMARY KEY);

    INSERT INTO @Wanted (BranchId)
    SELECT DISTINCT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(ISNULL(@BranchIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    /* A branch that does not exist would be accepted silently and then never
       appear anywhere — access that looks granted and is not. */
    IF EXISTS (SELECT 1 FROM @Wanted AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Branch AS b WHERE b.BranchId = w.BranchId))
    BEGIN
        SET @Blocked = N'One of those branches does not exist.';
        RETURN;
    END

    /* Nobody works nowhere. An empty set would leave the person able to sign in
       and do nothing, which reads as a broken account rather than a decision. */
    IF NOT EXISTS (SELECT 1 FROM @Wanted)
    BEGIN
        SET @Blocked = N'A user needs at least one branch.';
        RETURN;
    END

    BEGIN TRAN;

        DELETE FROM core.UserBranch WHERE UserId = @UserId;

        INSERT INTO core.UserBranch (UserId, BranchId)
        SELECT @UserId, BranchId FROM @Wanted;

    COMMIT;
END

GO


/*====================================================== permission overrides */

/*
  Grants and denials on top of a role.

  Also replaced wholesale, for the same reason. The effective permission view
  already resolves the precedence — denial beats grant — so this only records
  what was chosen.
*/
CREATE OR ALTER PROCEDURE core.usp_SetUserOverrides
    @UserId  NVARCHAR(40),
    @Grants  NVARCHAR(MAX) = NULL,   -- comma separated permission keys
    @Denies  NVARCHAR(MAX) = NULL,
    @Blocked NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Blocked = NULL;

    IF NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = @UserId)
        THROW 60010, N'No such user.', 1;

    DECLARE @Wanted TABLE (PermissionKey NVARCHAR(60), Effect NVARCHAR(10));

    INSERT INTO @Wanted (PermissionKey, Effect)
    SELECT DISTINCT LTRIM(RTRIM(value)), N'grant'
    FROM STRING_SPLIT(ISNULL(@Grants, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    INSERT INTO @Wanted (PermissionKey, Effect)
    SELECT DISTINCT LTRIM(RTRIM(value)), N'deny'
    FROM STRING_SPLIT(ISNULL(@Denies, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF EXISTS (SELECT 1 FROM @Wanted AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p
                                 WHERE p.PermissionKey = w.PermissionKey))
    BEGIN
        SET @Blocked = N'One of those permissions does not exist.';
        RETURN;
    END

    /* Granting and denying the same key is not a preference, it is a mistake.
       The view would resolve it to denied and the screen would show it granted. */
    IF EXISTS (SELECT PermissionKey FROM @Wanted
               GROUP BY PermissionKey HAVING COUNT(*) > 1)
    BEGIN
        SET @Blocked = N'A permission cannot be granted and denied at once.';
        RETURN;
    END

    /*
      An owner cannot be denied the ability to manage users.

      Otherwise the last person able to grant permissions can remove their own
      ability to do so, and nobody can undo it without a database session.
    */
    IF EXISTS (SELECT 1 FROM @Wanted AS w
               JOIN core.AppUser AS u ON u.UserId = @UserId
               WHERE w.Effect = N'deny'
                 AND w.PermissionKey IN (N'users.edit', N'users.create')
                 AND u.RoleId = N'rol_owner')
    BEGIN
        SET @Blocked = N'An owner cannot be denied user management.';
        RETURN;
    END

    BEGIN TRAN;

        DELETE FROM core.UserPermissionOverride WHERE UserId = @UserId;

        INSERT INTO core.UserPermissionOverride (UserId, PermissionKey, Effect)
        SELECT @UserId, PermissionKey, Effect FROM @Wanted;

    COMMIT;
END

GO


/*================================================================== company */

CREATE OR ALTER PROCEDURE core.usp_SaveCompany
    @NameAr        NVARCHAR(200),
    @NameEn        NVARCHAR(200),
    @DescriptionAr NVARCHAR(600) = NULL,
    @DescriptionEn NVARCHAR(600) = NULL,
    @LogoUrl       NVARCHAR(400) = NULL,
    @CrNumber      NVARCHAR(40)  = NULL,
    @VatNumber     NVARCHAR(40)  = NULL,
    @Phone         NVARCHAR(40)  = NULL,
    @Email         NVARCHAR(200) = NULL,
    @Website       NVARCHAR(200) = NULL,
    @Street        NVARCHAR(200) = NULL,
    @District      NVARCHAR(120) = NULL,
    @City          NVARCHAR(120) = NULL,
    @PostalCode    NVARCHAR(20)  = NULL,
    @Country       NVARCHAR(80)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* A Saudi VAT number is fifteen digits. A wrong one prints on every
       invoice, so it is checked here rather than discovered by an auditor. */
    IF @VatNumber IS NOT NULL AND @VatNumber <> N''
       AND (LEN(@VatNumber) <> 15 OR @VatNumber LIKE N'%[^0-9]%')
        THROW 59040, N'A VAT number must be exactly 15 digits.', 1;

    UPDATE core.Company
    SET NameAr = @NameAr, NameEn = @NameEn,
        DescriptionAr = @DescriptionAr, DescriptionEn = @DescriptionEn,
        LogoUrl = @LogoUrl, CrNumber = @CrNumber, VatNumber = @VatNumber,
        Phone = @Phone, Email = @Email, Website = @Website,
        Street = @Street, District = @District, City = @City,
        PostalCode = @PostalCode, Country = @Country,
        UpdatedAtUtc = SYSUTCDATETIME();

    IF @@ROWCOUNT = 0 THROW 59041, N'No company record exists.', 1;
END

GO


/*========================================================== bill templates */

CREATE OR ALTER PROCEDURE core.usp_SaveBillTemplate
    @BillId        NVARCHAR(40) = NULL,
    @Name          NVARCHAR(120),
    @Audience      NVARCHAR(20),
    @PrintGroupId  NVARCHAR(40) = NULL,
    @IsDefault     BIT = 0,
    @PaperSize     NVARCHAR(10) = N'80mm',
    @BillLanguage  NVARCHAR(10) = N'both',
    @ShowLogo      BIT = 1,
    @ShowVatNumber BIT = 1,
    @ShowCrNumber  BIT = 0,
    @ShowUnitPrice BIT = 1,
    @ShowLineTotal BIT = 1,
    @ShowSubtotal  BIT = 1,
    @ShowDiscount  BIT = 1,
    @ShowVat       BIT = 1,
    @ShowGrandTotal BIT = 1,
    @ShowZatcaQr   BIT = 1,
    @FooterAr      NVARCHAR(400) = NULL,
    @FooterEn      NVARCHAR(400) = NULL,
    @IsActive      BIT = 1,
    @SavedId       NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@Name, N''))) = N''
        THROW 60030, N'A template needs a name.', 1;

    IF @PaperSize NOT IN (N'58mm', N'80mm', N'A4')
        THROW 60031, N'Paper size must be 58mm, 80mm or A4.', 1;

    /*
      A customer receipt must show the total.

      Everything else is a layout preference; a receipt without a total is not a
      receipt, and a customer cannot check what they were charged.
    */
    IF @Audience = N'customer' AND @ShowGrandTotal = 0
        THROW 60032, N'A customer receipt must show the total.', 1;

    BEGIN TRAN;

        IF @BillId IS NULL
        BEGIN
            SET @SavedId = CONCAT(N'bil_',
                LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

            INSERT INTO core.BillTemplate
                (BillId, Name, Audience, PrintGroupId, IsDefault, PaperSize, BillLanguage,
                 ShowLogo, ShowVatNumber, ShowCrNumber, ShowUnitPrice, ShowLineTotal,
                 ShowSubtotal, ShowDiscount, ShowVat, ShowGrandTotal, ShowZatcaQr,
                 FooterAr, FooterEn, IsActive)
            VALUES
                (@SavedId, @Name, @Audience, @PrintGroupId, @IsDefault, @PaperSize, @BillLanguage,
                 @ShowLogo, @ShowVatNumber, @ShowCrNumber, @ShowUnitPrice, @ShowLineTotal,
                 @ShowSubtotal, @ShowDiscount, @ShowVat, @ShowGrandTotal, @ShowZatcaQr,
                 @FooterAr, @FooterEn, @IsActive);
        END
        ELSE
        BEGIN
            SET @SavedId = @BillId;

            UPDATE core.BillTemplate
            SET Name = @Name, Audience = @Audience, PrintGroupId = @PrintGroupId,
                IsDefault = @IsDefault, PaperSize = @PaperSize, BillLanguage = @BillLanguage,
                ShowLogo = @ShowLogo, ShowVatNumber = @ShowVatNumber,
                ShowCrNumber = @ShowCrNumber, ShowUnitPrice = @ShowUnitPrice,
                ShowLineTotal = @ShowLineTotal, ShowSubtotal = @ShowSubtotal,
                ShowDiscount = @ShowDiscount, ShowVat = @ShowVat,
                ShowGrandTotal = @ShowGrandTotal, ShowZatcaQr = @ShowZatcaQr,
                FooterAr = @FooterAr, FooterEn = @FooterEn, IsActive = @IsActive,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE BillId = @BillId;

            IF @@ROWCOUNT = 0 THROW 60033, N'No such template.', 1;
        END

        /* One default per audience. Two would make which one prints a matter of
           row order, and a receipt layout that changes at random is worse than
           the wrong layout consistently. */
        IF @IsDefault = 1
        BEGIN
            UPDATE core.BillTemplate
            SET IsDefault = 0, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE Audience = @Audience AND BillId <> @SavedId AND IsDefault = 1;
        END

    COMMIT;
END

GO


CREATE OR ALTER PROCEDURE core.usp_SaveCategory
    @CategoryId  NVARCHAR(40) = NULL,
    @NameAr      NVARCHAR(200),
    @NameEn      NVARCHAR(200),
    @SortOrder   INT = 0,
    @IsActive    BIT = 1,
    @SavedId     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 59010, N'Both names are required.', 1;

    IF @CategoryId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'cat_',
            LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO core.Category (CategoryId, NameAr, NameEn, SortOrder, IsActive)
        VALUES (@SavedId, @NameAr, @NameEn, @SortOrder, @IsActive);
    END
    ELSE
    BEGIN
        SET @SavedId = @CategoryId;

        UPDATE core.Category
        SET NameAr = @NameAr, NameEn = @NameEn, SortOrder = @SortOrder,
            IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME()
        WHERE CategoryId = @CategoryId;

        IF @@ROWCOUNT = 0 THROW 59011, N'No such category.', 1;
    END
END

GO


/*================================================================ discounts */

CREATE OR ALTER PROCEDURE sales.usp_SaveDiscount
    @DiscountId     NVARCHAR(40) = NULL,
    @NameAr         NVARCHAR(200),
    @NameEn         NVARCHAR(200),
    @DiscountType   NVARCHAR(20),
    @Value          DECIMAL(18,3),
    @MaxDiscountH   BIGINT = NULL,
    @MinSubtotalH   BIGINT = 0,
    @ApprovalAboveH BIGINT = NULL,
    @AppliesTo      NVARCHAR(20) = N'sale',
    @IsAutomatic    BIT = 0,
    @AllowStacking  BIT = 0,
    @ActiveDays     NVARCHAR(20) = NULL,
    @StartsOn       DATE = NULL,
    @EndsOn         DATE = NULL,
    @IsActive       BIT = 1,
    @SavedId        NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @DiscountType NOT IN (N'percent', N'amount')
        THROW 59020, N'A discount is either a percentage or an amount.', 1;

    /* A percentage above 100 would pay the customer to take the goods. */
    IF @DiscountType = N'percent' AND (@Value <= 0 OR @Value > 100)
        THROW 59021, N'A percentage must be above zero and at most 100.', 1;

    IF @DiscountType = N'amount' AND @Value <= 0
        THROW 59022, N'An amount must be above zero.', 1;

    IF @EndsOn IS NOT NULL AND @StartsOn IS NOT NULL AND @EndsOn < @StartsOn
        THROW 59023, N'The end date cannot be before the start date.', 1;

    IF @DiscountId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'dsc_',
            LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO sales.Discount
            (DiscountId, NameAr, NameEn, DiscountType, Value, MaxDiscountH,
             MinSubtotalH, ApprovalAboveH, AppliesTo, IsAutomatic, AllowStacking,
             ActiveDays, StartsOn, EndsOn, IsActive)
        VALUES
            (@SavedId, @NameAr, @NameEn, @DiscountType, @Value, @MaxDiscountH,
             @MinSubtotalH, @ApprovalAboveH, @AppliesTo, @IsAutomatic, @AllowStacking,
             @ActiveDays, @StartsOn, @EndsOn, @IsActive);
    END
    ELSE
    BEGIN
        SET @SavedId = @DiscountId;

        /* UsageCount is not touched. It records how often this discount has
           been applied; an edit must not reset that history. */
        UPDATE sales.Discount
        SET NameAr = @NameAr, NameEn = @NameEn, DiscountType = @DiscountType,
            Value = @Value, MaxDiscountH = @MaxDiscountH, MinSubtotalH = @MinSubtotalH,
            ApprovalAboveH = @ApprovalAboveH, AppliesTo = @AppliesTo,
            IsAutomatic = @IsAutomatic, AllowStacking = @AllowStacking,
            ActiveDays = @ActiveDays, StartsOn = @StartsOn, EndsOn = @EndsOn,
            IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME()
        WHERE DiscountId = @DiscountId;

        IF @@ROWCOUNT = 0 THROW 59024, N'No such discount.', 1;
    END
END

GO


/*======================================================== commission rules */

CREATE OR ALTER PROCEDURE fin.usp_SaveCommissionRule
    @RuleId   NVARCHAR(40) = NULL,
    @Basis    NVARCHAR(20),
    @Value    DECIMAL(18,3),
    @IsActive BIT = 1,
    @SavedId  NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @Basis NOT IN (N'percent_of_sale', N'percent_of_margin', N'fixed_per_sale')
        THROW 60020, N'That commission basis is not recognised.', 1;

    IF @Value <= 0
        THROW 60021, N'A commission value must be above zero.', 1;

    /* A percentage above 100 pays out more than the sale brought in. */
    IF @Basis LIKE N'percent%' AND @Value > 100
        THROW 60022, N'A commission percentage cannot exceed 100.', 1;

    IF @RuleId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'crl_',
            LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO fin.CommissionRule (RuleId, Basis, Value, IsActive)
        VALUES (@SavedId, @Basis, @Value, @IsActive);
    END
    ELSE
    BEGIN
        SET @SavedId = @RuleId;

        /*
          Editing a rule does not change commission already earned.

          fin.CommissionEntry records the amount at the moment of each sale, so
          past entries keep the rate that applied then. Recalculating them would
          rewrite what someone was told they had earned.
        */
        UPDATE fin.CommissionRule
        SET Basis = @Basis, Value = @Value, IsActive = @IsActive,
            UpdatedAtUtc = SYSUTCDATETIME()
        WHERE RuleId = @RuleId;

        IF @@ROWCOUNT = 0 THROW 60023, N'No such commission rule.', 1;
    END
END

GO


PRINT N'25 · Admin save procedures captured.';
GO
