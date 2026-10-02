/*==============================================================================
  Nazad POS — 26 · Users and roles

  The API's user and role administration (POST/PUT /api/users, the status and
  revoke routes, POST/PUT/DELETE /api/users/roles) runs through these.

  Schema, kept to what the user screen already edits and had nowhere to store:
    - core.AppUser gains FirstName, LastName, Address, EmployeeId, AvatarUrl,
      DefaultBranchId and TicketReference. TicketReference is the support ticket
      that justifies an external account; without a column the rule "record why
      the vendor has access" could only be enforced in the browser.
    - core.Role gains IsActive. A role can be retired without deleting it.
    - Permissions users.disable and roles.delete are seeded: the screens have
      had those switches, and the server had no key to check them against.

  core.usp_SaveUser now saves the account, its branches and its permission
  overrides in one transaction. It still calls usp_SetUserBranches and
  usp_SetUserOverrides for the writes, but checks everything they would refuse
  first, with its own error numbers, so a refusal names the field instead of
  arriving as a half-saved user.

  Error numbers 61000–61099.
==============================================================================*/

USE POSMAIN;
GO

/*---------------------------------------------------------------------- schema */

IF COL_LENGTH(N'core.AppUser', N'FirstName') IS NULL
    ALTER TABLE core.AppUser ADD FirstName NVARCHAR(100) NULL;
IF COL_LENGTH(N'core.AppUser', N'LastName') IS NULL
    ALTER TABLE core.AppUser ADD LastName NVARCHAR(100) NULL;
IF COL_LENGTH(N'core.AppUser', N'Address') IS NULL
    ALTER TABLE core.AppUser ADD Address NVARCHAR(400) NULL;
IF COL_LENGTH(N'core.AppUser', N'EmployeeId') IS NULL
    ALTER TABLE core.AppUser ADD EmployeeId NVARCHAR(40) NULL;
IF COL_LENGTH(N'core.AppUser', N'AvatarUrl') IS NULL
    ALTER TABLE core.AppUser ADD AvatarUrl NVARCHAR(400) NULL;
IF COL_LENGTH(N'core.AppUser', N'DefaultBranchId') IS NULL
    ALTER TABLE core.AppUser ADD DefaultBranchId NVARCHAR(40) NULL;
IF COL_LENGTH(N'core.AppUser', N'TicketReference') IS NULL
    ALTER TABLE core.AppUser ADD TicketReference NVARCHAR(120) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_AppUser_DefaultBranch')
    ALTER TABLE core.AppUser ADD CONSTRAINT FK_AppUser_DefaultBranch
        FOREIGN KEY (DefaultBranchId) REFERENCES core.Branch (BranchId);
GO

IF COL_LENGTH(N'core.Role', N'IsActive') IS NULL
    ALTER TABLE core.Role ADD IsActive BIT NOT NULL
        CONSTRAINT DF_Role_IsActive DEFAULT (1);
GO

/* Existing users land in the first branch they already work at, which is what
   sign-in did implicitly before there was a column. */
UPDATE u
SET DefaultBranchId = (SELECT TOP (1) ub.BranchId FROM core.UserBranch AS ub
                       WHERE ub.UserId = u.UserId ORDER BY ub.BranchId)
FROM core.AppUser AS u
WHERE u.DefaultBranchId IS NULL;
GO

/*----------------------------------------------------------------- permissions */

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
SELECT v.PermissionKey, v.Module, v.Action, v.Sensitivity
FROM (VALUES (N'users.disable', N'users', N'disable', N'personal'),
             (N'roles.delete',  N'roles', N'delete',  N'personal')) AS v (PermissionKey, Module, Action, Sensitivity)
WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p WHERE p.PermissionKey = v.PermissionKey);
GO

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT v.RoleId, v.PermissionKey
FROM (VALUES (N'rol_owner',   N'users.disable'),
             (N'rol_manager', N'users.disable'),
             (N'rol_owner',   N'roles.delete')) AS v (RoleId, PermissionKey)
WHERE EXISTS (SELECT 1 FROM core.Role AS r WHERE r.RoleId = v.RoleId)
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                  WHERE rp.RoleId = v.RoleId AND rp.PermissionKey = v.PermissionKey);
GO

/*------------------------------------------------------------------ save user */

CREATE OR ALTER PROCEDURE core.usp_SaveUser
    @UserId          NVARCHAR(40)  = NULL,   -- null creates
    @Username        NVARCHAR(80),
    @FirstName       NVARCHAR(100) = NULL,
    @LastName        NVARCHAR(100) = NULL,
    @NameAr          NVARCHAR(200),
    @NameEn          NVARCHAR(200),
    @Email           NVARCHAR(200) = NULL,
    @Phone           NVARCHAR(40)  = NULL,
    @Address         NVARCHAR(400) = NULL,
    @EmployeeId      NVARCHAR(40)  = NULL,
    @RoleId          NVARCHAR(40),
    @Status          NVARCHAR(20)  = N'active',
    @AccessExpiresOn DATE          = NULL,
    @TicketReference NVARCHAR(120) = NULL,
    @BaseSalaryH     BIGINT        = NULL,   -- null keeps the current salary
    @BranchIds       NVARCHAR(MAX),          -- comma separated
    @DefaultBranchId NVARCHAR(40)  = NULL,
    @Grants          NVARCHAR(MAX) = NULL,   -- comma separated permission keys
    @Denies          NVARCHAR(MAX) = NULL,
    @PasswordHash    NVARCHAR(400) = NULL,   -- null keeps the current password
    @PasswordSalt    NVARCHAR(200) = NULL,
    @Actor           NVARCHAR(160),
    @SavedId         NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Username = LTRIM(RTRIM(ISNULL(@Username, N'')));

    IF @Username = N''
        THROW 61000, N'A username is required.', 1;

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 61017, N'Both names are required.', 1;

    IF @Status NOT IN (N'active', N'suspended')
        THROW 61019, N'Status must be active or suspended.', 1;

    IF @UserId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = @UserId)
        THROW 61010, N'No such user.', 1;

    IF EXISTS (SELECT 1 FROM core.AppUser
               WHERE Username = @Username AND (@UserId IS NULL OR UserId <> @UserId))
        THROW 61001, N'That username is already taken.', 1;

    /* Sign-in matches on email or phone, so a duplicate would make which
       account you reach a matter of row order. */
    IF @Email IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.AppUser
        WHERE Email = @Email AND (@UserId IS NULL OR UserId <> @UserId))
        THROW 61002, N'That email is already used by another account.', 1;

    IF @Phone IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.AppUser
        WHERE Phone = @Phone AND (@UserId IS NULL OR UserId <> @UserId))
        THROW 61003, N'That mobile number is already used by another account.', 1;

    DECLARE @RoleExternal BIT, @RoleActive BIT;
    SELECT @RoleExternal = IsExternal, @RoleActive = IsActive
    FROM core.Role WHERE RoleId = @RoleId;

    IF @RoleExternal IS NULL
        THROW 61004, N'No such role.', 1;

    /* A retired role may stay on the people who have it, but nobody new is
       given it — otherwise retiring it means nothing. */
    IF @RoleActive = 0 AND NOT EXISTS (SELECT 1 FROM core.AppUser
                                       WHERE UserId = @UserId AND RoleId = @RoleId)
        THROW 61005, N'That role is inactive.', 1;

    /* Whether an account is external follows its role. Two flags that could
       disagree would leave the rules below applying to one and not the other. */
    DECLARE @IsExternal BIT = @RoleExternal;

    /* An external account without an expiry never expires, which defeats the
       reason for marking it external. */
    IF @IsExternal = 1 AND @AccessExpiresOn IS NULL
        THROW 61006, N'An external account needs an access expiry date.', 1;

    IF @IsExternal = 1 AND LTRIM(RTRIM(ISNULL(@TicketReference, N''))) = N''
        THROW 61007, N'Record the ticket that justifies this access.', 1;

    /*------------------------------------------------ branches, checked first */

    DECLARE @Branches TABLE (BranchId NVARCHAR(40) PRIMARY KEY);

    INSERT INTO @Branches (BranchId)
    SELECT DISTINCT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(ISNULL(@BranchIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF NOT EXISTS (SELECT 1 FROM @Branches)
        THROW 61011, N'A user needs at least one branch.', 1;

    IF EXISTS (SELECT 1 FROM @Branches AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Branch AS b WHERE b.BranchId = w.BranchId))
        THROW 61012, N'One of those branches does not exist.', 1;

    /* No default means the first assigned branch, so the column is never empty
       for an account that works somewhere. */
    IF @DefaultBranchId IS NULL
        SELECT TOP (1) @DefaultBranchId = BranchId FROM @Branches ORDER BY BranchId;

    IF NOT EXISTS (SELECT 1 FROM @Branches WHERE BranchId = @DefaultBranchId)
        THROW 61013, N'The default branch must be one of the assigned branches.', 1;

    /*----------------------------------------------- overrides, checked first */

    DECLARE @Overrides TABLE (PermissionKey NVARCHAR(60), Effect NVARCHAR(10));

    INSERT INTO @Overrides (PermissionKey, Effect)
    SELECT DISTINCT LTRIM(RTRIM(value)), N'grant'
    FROM STRING_SPLIT(ISNULL(@Grants, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    INSERT INTO @Overrides (PermissionKey, Effect)
    SELECT DISTINCT LTRIM(RTRIM(value)), N'deny'
    FROM STRING_SPLIT(ISNULL(@Denies, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF EXISTS (SELECT 1 FROM @Overrides AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p
                                 WHERE p.PermissionKey = w.PermissionKey))
        THROW 61014, N'One of those permissions does not exist.', 1;

    IF EXISTS (SELECT PermissionKey FROM @Overrides GROUP BY PermissionKey HAVING COUNT(*) > 1)
        THROW 61015, N'A permission cannot be granted and denied at once.', 1;

    IF @RoleId = N'rol_owner' AND EXISTS (
        SELECT 1 FROM @Overrides
        WHERE Effect = N'deny' AND PermissionKey IN (N'users.edit', N'users.create'))
        THROW 61016, N'An owner cannot be denied user management.', 1;

    /* The maintenance vendor never sees money or customer data, however the
       grant arrives — through the role or added on top of it. */
    IF @IsExternal = 1 AND EXISTS (
        SELECT 1 FROM @Overrides AS w
        JOIN core.Permission AS p ON p.PermissionKey = w.PermissionKey
        WHERE w.Effect = N'grant' AND p.Sensitivity <> N'general')
        THROW 61008, N'A maintenance account cannot hold financial or personal-data permissions.', 1;

    /*--------------------------------------------------------- last owner */

    /* The last active owner cannot be suspended or demoted: someone has to be
       able to grant permissions back. */
    IF @UserId IS NOT NULL
       AND (@Status <> N'active' OR @RoleId <> N'rol_owner')
       AND EXISTS (SELECT 1 FROM core.AppUser
                   WHERE UserId = @UserId AND RoleId = N'rol_owner' AND Status = N'active')
       AND NOT EXISTS (SELECT 1 FROM core.AppUser
                       WHERE RoleId = N'rol_owner' AND Status = N'active' AND UserId <> @UserId)
        THROW 61009, N'This is the only active owner. Appoint another first.', 1;

    /*-------------------------------------------------------------- write */

    DECLARE @Blocked NVARCHAR(400);
    DECLARE @BranchCsv NVARCHAR(MAX) = (SELECT STRING_AGG(BranchId, N',') FROM @Branches);

    BEGIN TRAN;

        IF @UserId IS NULL
        BEGIN
            SET @SavedId = CONCAT(N'usr_',
                LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

            INSERT INTO core.AppUser
                (UserId, Username, FirstName, LastName, NameAr, NameEn, Email, Phone,
                 Address, EmployeeId, RoleId, Status, IsExternal, AccessExpiresOn,
                 TicketReference, BaseSalaryH, DefaultBranchId,
                 PasswordHash, PasswordSalt, CreatedBy, UpdatedBy)
            VALUES
                (@SavedId, @Username, @FirstName, @LastName, @NameAr, @NameEn, @Email, @Phone,
                 @Address, @EmployeeId, @RoleId, @Status, @IsExternal, @AccessExpiresOn,
                 @TicketReference, ISNULL(@BaseSalaryH, 0), NULL,
                 @PasswordHash, @PasswordSalt, @Actor, @Actor);
        END
        ELSE
        BEGIN
            SET @SavedId = @UserId;

            UPDATE core.AppUser
            SET Username = @Username, FirstName = @FirstName, LastName = @LastName,
                NameAr = @NameAr, NameEn = @NameEn, Email = @Email, Phone = @Phone,
                Address = @Address, EmployeeId = @EmployeeId,
                RoleId = @RoleId, Status = @Status, IsExternal = @IsExternal,
                AccessExpiresOn = @AccessExpiresOn, TicketReference = @TicketReference,
                BaseSalaryH = ISNULL(@BaseSalaryH, BaseSalaryH),
                /* A blank password on edit keeps the current one. */
                PasswordHash = ISNULL(@PasswordHash, PasswordHash),
                PasswordSalt = CASE WHEN @PasswordHash IS NULL THEN PasswordSalt ELSE @PasswordSalt END,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
            WHERE UserId = @UserId;
        END

        EXEC core.usp_SetUserBranches
             @UserId = @SavedId, @BranchIds = @BranchCsv, @Blocked = @Blocked OUTPUT;

        /* Everything it could refuse was checked above; this is the backstop. */
        IF @Blocked IS NOT NULL
            THROW 61018, @Blocked, 1;

        UPDATE core.AppUser SET DefaultBranchId = @DefaultBranchId WHERE UserId = @SavedId;

        EXEC core.usp_SetUserOverrides
             @UserId = @SavedId, @Grants = @Grants, @Denies = @Denies, @Blocked = @Blocked OUTPUT;

        IF @Blocked IS NOT NULL
            THROW 61018, @Blocked, 1;

    COMMIT;
END
GO

/*------------------------------------------------------------- status changes */

/*
  Suspend, reactivate, or end an external account's access now.

  Sign-in already refuses a suspended account; revoking the refresh tokens as
  well means an open session cannot renew itself either, so the change takes
  effect within one access-token lifetime rather than whenever they log out.
*/
CREATE OR ALTER PROCEDURE core.usp_SetUserStatus
    @UserId       NVARCHAR(40),
    @Status       NVARCHAR(20),
    @RevokeAccess BIT = 0,          -- 1 also ends the access window today
    @Actor        NVARCHAR(160)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status NOT IN (N'active', N'suspended')
        THROW 61019, N'Status must be active or suspended.', 1;

    IF NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = @UserId)
        THROW 61010, N'No such user.', 1;

    IF @Status <> N'active'
       AND EXISTS (SELECT 1 FROM core.AppUser
                   WHERE UserId = @UserId AND RoleId = N'rol_owner' AND Status = N'active')
       AND NOT EXISTS (SELECT 1 FROM core.AppUser
                       WHERE RoleId = N'rol_owner' AND Status = N'active' AND UserId <> @UserId)
        THROW 61009, N'This is the only active owner. Appoint another first.', 1;

    BEGIN TRAN;

        UPDATE core.AppUser
        SET Status = @Status,
            AccessExpiresOn = CASE WHEN @RevokeAccess = 1
                                   THEN CAST(SYSUTCDATETIME() AS DATE)
                                   ELSE AccessExpiresOn END,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE UserId = @UserId;

        IF @Status <> N'active'
            UPDATE core.RefreshToken
            SET RevokedAtUtc = SYSUTCDATETIME()
            WHERE UserId = @UserId AND RevokedAtUtc IS NULL;

    COMMIT;
END
GO

/*------------------------------------------------------------------ save role */

/*
  Create or edit a role, replacing its permission set wholesale.

  The owner role is not editable: it holds every permission by definition, and
  an owner who could trim it could lock everyone out of user administration.
  Built-in roles keep their names — other screens and the seed data refer to
  them — but their permissions are the owner's to tune.
*/
CREATE OR ALTER PROCEDURE core.usp_SaveRole
    @RoleId        NVARCHAR(40)  = NULL,   -- null creates
    @NameAr        NVARCHAR(120),
    @NameEn        NVARCHAR(120),
    @DescriptionAr NVARCHAR(400) = NULL,
    @DescriptionEn NVARCHAR(400) = NULL,
    @IsExternal    BIT = 0,                -- create only; fixed afterwards
    @IsActive      BIT = 1,
    @Permissions   NVARCHAR(MAX),          -- comma separated permission keys
    @SavedId       NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BuiltIn BIT, @External BIT;

    IF @RoleId IS NOT NULL
    BEGIN
        SELECT @BuiltIn = IsBuiltIn, @External = IsExternal FROM core.Role WHERE RoleId = @RoleId;

        IF @BuiltIn IS NULL
            THROW 61056, N'No such role.', 1;

        IF @RoleId = N'rol_owner'
            THROW 61055, N'The owner role always holds every permission and cannot be edited.', 1;

        /* Built-in names stay; only the permissions are tunable. */
        IF @BuiltIn = 1
            SELECT @NameAr = NameAr, @NameEn = NameEn FROM core.Role WHERE RoleId = @RoleId;
    END
    ELSE
        SET @External = ISNULL(@IsExternal, 0);

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 61050, N'Both names are required.', 1;

    IF EXISTS (SELECT 1 FROM core.Role
               WHERE (NameEn = @NameEn OR NameAr = @NameAr)
                 AND (@RoleId IS NULL OR RoleId <> @RoleId))
        THROW 61051, N'Another role already uses this name.', 1;

    DECLARE @Wanted TABLE (PermissionKey NVARCHAR(60) PRIMARY KEY);

    INSERT INTO @Wanted (PermissionKey)
    SELECT DISTINCT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(ISNULL(@Permissions, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    /* A role with nothing in it signs people in to an empty screen. */
    IF NOT EXISTS (SELECT 1 FROM @Wanted)
        THROW 61052, N'Give the role at least one permission, or nobody can use it.', 1;

    IF EXISTS (SELECT 1 FROM @Wanted AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p
                                 WHERE p.PermissionKey = w.PermissionKey))
        THROW 61053, N'One of those permissions does not exist.', 1;

    IF @External = 1 AND EXISTS (
        SELECT 1 FROM @Wanted AS w
        JOIN core.Permission AS p ON p.PermissionKey = w.PermissionKey
        WHERE p.Sensitivity <> N'general')
        THROW 61054, N'A maintenance role cannot be given access to financial or personal data.', 1;

    /* Retiring a role people still hold would leave them on something nobody
       can be given — move them first, as with any other deactivation. */
    IF @RoleId IS NOT NULL AND @IsActive = 0
       AND EXISTS (SELECT 1 FROM core.AppUser WHERE RoleId = @RoleId)
        THROW 61059, N'Users still hold this role. Move them to another role first.', 1;

    BEGIN TRAN;

        IF @RoleId IS NULL
        BEGIN
            SET @SavedId = CONCAT(N'rol_',
                LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

            INSERT INTO core.Role
                (RoleId, NameAr, NameEn, DescriptionAr, DescriptionEn, IsBuiltIn, IsExternal, IsActive)
            VALUES
                (@SavedId, @NameAr, @NameEn, @DescriptionAr, @DescriptionEn, 0, @External, @IsActive);
        END
        ELSE
        BEGIN
            SET @SavedId = @RoleId;

            UPDATE core.Role
            SET NameAr = @NameAr, NameEn = @NameEn,
                DescriptionAr = @DescriptionAr, DescriptionEn = @DescriptionEn,
                IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE RoleId = @RoleId;
        END

        DELETE FROM core.RolePermission WHERE RoleId = @SavedId;

        INSERT INTO core.RolePermission (RoleId, PermissionKey)
        SELECT @SavedId, PermissionKey FROM @Wanted;

    COMMIT;
END
GO

/*---------------------------------------------------------------- delete role */

/*
  A real delete, because a role is configuration rather than history: no sale,
  payment or ledger line records which role its actor held. What can refer to a
  role is a user, and that is refused rather than cascaded.
*/
CREATE OR ALTER PROCEDURE core.usp_DeleteRole
    @RoleId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BuiltIn BIT = (SELECT IsBuiltIn FROM core.Role WHERE RoleId = @RoleId);

    IF @BuiltIn IS NULL
        THROW 61056, N'No such role.', 1;

    IF @BuiltIn = 1
        THROW 61057, N'Built-in roles cannot be deleted.', 1;

    DECLARE @Assigned INT = (SELECT COUNT(*) FROM core.AppUser WHERE RoleId = @RoleId);

    IF @Assigned > 0
    BEGIN
        DECLARE @Message NVARCHAR(400) = CONCAT(
            @Assigned, N' user(s) still hold this role. Move them to another role first.');
        THROW 61058, @Message, 1;
    END;

    /* RolePermission cascades. */
    DELETE FROM core.Role WHERE RoleId = @RoleId;
END
GO

PRINT N'26 · Users and roles ready.';
GO

/*----------------------------------------------------------------------- check */

SELECT
    CASE WHEN COL_LENGTH(N'core.AppUser', N'DefaultBranchId') IS NULL
              THEN N'FAIL  core.AppUser columns missing'
         WHEN COL_LENGTH(N'core.Role', N'IsActive') IS NULL
              THEN N'FAIL  core.Role.IsActive missing'
         WHEN OBJECT_ID(N'core.usp_SaveRole') IS NULL OR OBJECT_ID(N'core.usp_DeleteRole') IS NULL
              OR OBJECT_ID(N'core.usp_SetUserStatus') IS NULL
              THEN N'FAIL  procedures missing'
         WHEN (SELECT COUNT(*) FROM core.RolePermission
               WHERE PermissionKey IN (N'users.disable', N'roles.delete')) < 3
              THEN N'FAIL  permission grants incomplete'
         ELSE N'PASS  Users and roles ready'
    END AS Result;
GO
