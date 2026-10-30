/*==============================================================================
  Nazad POS — 010 · Core functions (core, audit)

  Users, their branches and permission overrides, roles, registering a
  business, and the nightly purges. Conventions: README.md.
==============================================================================*/

/*=========================================================== branch access */

/*
  Which branches a person may work in.

  Replaced wholesale rather than added to. A grant-and-revoke pair drifts: the
  screen shows a set, and applying a diff means two round trips that can half
  succeed, leaving access nobody chose.

  A refusal the caller is expected to handle comes back as Blocked (NULL when
  the change was made); a missing user is an error.
*/
CREATE OR REPLACE FUNCTION core.usp_SetUserBranches(
    p_UserId    text,
    p_BranchIds text)                -- comma separated
RETURNS TABLE (Blocked varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Wanted varchar[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = p_UserId) THEN
        RAISE EXCEPTION 'No such user.' USING DETAIL = '60000';
    END IF;

    /* Distinct ignoring case, as the old table variable's key did. */
    v_Wanted := ARRAY(
        SELECT DISTINCT trim(x) COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_BranchIds, ''), ',')) AS x
        WHERE trim(x) <> '');

    /* A branch that does not exist would be accepted silently and then never
       appear anywhere — access that looks granted and is not. */
    IF EXISTS (SELECT 1 FROM unnest(v_Wanted) AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Branch AS b WHERE b.BranchId = w)) THEN
        RETURN QUERY SELECT 'One of those branches does not exist.'::varchar;
        RETURN;
    END IF;

    /* Nobody works nowhere. An empty set would leave the person able to sign in
       and do nothing, which reads as a broken account rather than a decision. */
    IF cardinality(v_Wanted) = 0 THEN
        RETURN QUERY SELECT 'A user needs at least one branch.'::varchar;
        RETURN;
    END IF;

    DELETE FROM core.UserBranch WHERE UserId = p_UserId;

    INSERT INTO core.UserBranch (UserId, BranchId)
    SELECT p_UserId, w FROM unnest(v_Wanted) AS w;

    RETURN QUERY SELECT NULL::varchar;
END $$;

/*====================================================== permission overrides */

/*
  Grants and denials on top of a role.

  Also replaced wholesale, for the same reason. The effective permission view
  already resolves the precedence — denial beats grant — so this only records
  what was chosen.
*/
CREATE OR REPLACE FUNCTION core.usp_SetUserOverrides(
    p_UserId text,
    p_Grants text DEFAULT NULL,      -- comma separated permission keys
    p_Denies text DEFAULT NULL)
RETURNS TABLE (Blocked varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Grants varchar[];
    v_Denies varchar[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = p_UserId) THEN
        RAISE EXCEPTION 'No such user.' USING DETAIL = '60010';
    END IF;

    v_Grants := ARRAY(
        SELECT DISTINCT trim(x) COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_Grants, ''), ',')) AS x
        WHERE trim(x) <> '');

    v_Denies := ARRAY(
        SELECT DISTINCT trim(x) COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_Denies, ''), ',')) AS x
        WHERE trim(x) <> '');

    IF EXISTS (SELECT 1 FROM unnest(v_Grants || v_Denies) AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p
                                 WHERE p.PermissionKey = w)) THEN
        RETURN QUERY SELECT 'One of those permissions does not exist.'::varchar;
        RETURN;
    END IF;

    /* Granting and denying the same key is not a preference, it is a mistake.
       The view would resolve it to denied and the screen would show it granted. */
    IF EXISTS (SELECT 1 FROM unnest(v_Grants) AS g
               JOIN unnest(v_Denies) AS d ON d COLLATE ci = g) THEN
        RETURN QUERY SELECT 'A permission cannot be granted and denied at once.'::varchar;
        RETURN;
    END IF;

    /*
      An owner cannot be denied the ability to manage users.

      Otherwise the last person able to grant permissions can remove their own
      ability to do so, and nobody can undo it without a database session.
    */
    IF EXISTS (SELECT 1 FROM unnest(v_Denies) AS d
               JOIN core.AppUser AS u ON u.UserId = p_UserId
               WHERE d COLLATE ci IN ('users.edit', 'users.create')
                 AND u.RoleId = 'rol_owner') THEN
        RETURN QUERY SELECT 'An owner cannot be denied user management.'::varchar;
        RETURN;
    END IF;

    DELETE FROM core.UserPermissionOverride WHERE UserId = p_UserId;

    INSERT INTO core.UserPermissionOverride (UserId, PermissionKey, Effect)
    SELECT p_UserId, g, 'grant' FROM unnest(v_Grants) AS g
    UNION ALL
    SELECT p_UserId, d, 'deny' FROM unnest(v_Denies) AS d;

    RETURN QUERY SELECT NULL::varchar;
END $$;

/*------------------------------------------------------------------ save user */

CREATE OR REPLACE FUNCTION core.usp_SaveUser(
    p_Username        text,
    p_NameAr          text,
    p_NameEn          text,
    p_RoleId          text,
    p_BranchIds       text,                    -- comma separated
    p_Actor           text,
    p_UserId          text    DEFAULT NULL,    -- null creates
    p_FirstName       text    DEFAULT NULL,
    p_LastName        text    DEFAULT NULL,
    p_Email           text    DEFAULT NULL,
    p_Phone           text    DEFAULT NULL,
    p_Address         text    DEFAULT NULL,
    p_EmployeeId      text    DEFAULT NULL,
    p_Status          text    DEFAULT 'active',
    p_AccessExpiresOn date    DEFAULT NULL,
    p_TicketReference text    DEFAULT NULL,
    p_BaseSalaryH     bigint  DEFAULT NULL,    -- null keeps the current salary
    p_DefaultBranchId text    DEFAULT NULL,
    p_Grants          text    DEFAULT NULL,    -- comma separated permission keys
    p_Denies          text    DEFAULT NULL,
    p_PasswordHash    text    DEFAULT NULL,    -- null keeps the current password
    p_PasswordSalt    text    DEFAULT NULL)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Username        varchar := trim(COALESCE(p_Username, ''));
    v_DefaultBranchId varchar := p_DefaultBranchId;
    v_RoleExternal    boolean;
    v_RoleActive      boolean;
    v_IsExternal      boolean;
    v_Branches        varchar[];
    v_Grants          varchar[];
    v_Denies          varchar[];
    v_Blocked         varchar;
    v_BranchCsv       text;
    v_SavedId         varchar;
BEGIN
    IF v_Username = '' THEN
        RAISE EXCEPTION 'A username is required.' USING DETAIL = '61000';
    END IF;

    IF trim(COALESCE(p_NameAr, '')) = '' OR trim(COALESCE(p_NameEn, '')) = '' THEN
        RAISE EXCEPTION 'Both names are required.' USING DETAIL = '61017';
    END IF;

    IF p_Status COLLATE ci NOT IN ('active', 'suspended') THEN
        RAISE EXCEPTION 'Status must be active or suspended.' USING DETAIL = '61019';
    END IF;

    IF p_UserId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = p_UserId) THEN
        RAISE EXCEPTION 'No such user.' USING DETAIL = '61010';
    END IF;

    IF EXISTS (SELECT 1 FROM core.AppUser
               WHERE Username = v_Username AND (p_UserId IS NULL OR UserId <> p_UserId)) THEN
        RAISE EXCEPTION 'That username is already taken.' USING DETAIL = '61001';
    END IF;

    /* Sign-in matches on email or phone, so a duplicate would make which
       account you reach a matter of row order. */
    IF p_Email IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.AppUser
        WHERE Email = p_Email AND (p_UserId IS NULL OR UserId <> p_UserId)) THEN
        RAISE EXCEPTION 'That email is already used by another account.' USING DETAIL = '61002';
    END IF;

    IF p_Phone IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.AppUser
        WHERE Phone = p_Phone AND (p_UserId IS NULL OR UserId <> p_UserId)) THEN
        RAISE EXCEPTION 'That mobile number is already used by another account.' USING DETAIL = '61003';
    END IF;

    SELECT IsExternal, IsActive INTO v_RoleExternal, v_RoleActive
    FROM core.Role WHERE RoleId = p_RoleId;

    IF v_RoleExternal IS NULL THEN
        RAISE EXCEPTION 'No such role.' USING DETAIL = '61004';
    END IF;

    /* A retired role may stay on the people who have it, but nobody new is
       given it — otherwise retiring it means nothing. */
    IF NOT v_RoleActive AND NOT EXISTS (SELECT 1 FROM core.AppUser
                                        WHERE UserId = p_UserId AND RoleId = p_RoleId) THEN
        RAISE EXCEPTION 'That role is inactive.' USING DETAIL = '61005';
    END IF;

    /* Whether an account is external follows its role. Two flags that could
       disagree would leave the rules below applying to one and not the other. */
    v_IsExternal := v_RoleExternal;

    /* An external account without an expiry never expires, which defeats the
       reason for marking it external. */
    IF v_IsExternal AND p_AccessExpiresOn IS NULL THEN
        RAISE EXCEPTION 'An external account needs an access expiry date.' USING DETAIL = '61006';
    END IF;

    IF v_IsExternal AND trim(COALESCE(p_TicketReference, '')) = '' THEN
        RAISE EXCEPTION 'Record the ticket that justifies this access.' USING DETAIL = '61007';
    END IF;

    /*------------------------------------------------ branches, checked first */

    v_Branches := ARRAY(
        SELECT DISTINCT trim(x) COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_BranchIds, ''), ',')) AS x
        WHERE trim(x) <> '');

    IF cardinality(v_Branches) = 0 THEN
        RAISE EXCEPTION 'A user needs at least one branch.' USING DETAIL = '61011';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Branches) AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Branch AS b WHERE b.BranchId = w)) THEN
        RAISE EXCEPTION 'One of those branches does not exist.' USING DETAIL = '61012';
    END IF;

    /* No default means the first assigned branch, so the column is never empty
       for an account that works somewhere. */
    IF v_DefaultBranchId IS NULL THEN
        SELECT w INTO v_DefaultBranchId
        FROM unnest(v_Branches) AS w ORDER BY w COLLATE ci LIMIT 1;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM unnest(v_Branches) AS w WHERE w COLLATE ci = v_DefaultBranchId) THEN
        RAISE EXCEPTION 'The default branch must be one of the assigned branches.' USING DETAIL = '61013';
    END IF;

    /*----------------------------------------------- overrides, checked first */

    v_Grants := ARRAY(
        SELECT DISTINCT trim(x) COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_Grants, ''), ',')) AS x
        WHERE trim(x) <> '');

    v_Denies := ARRAY(
        SELECT DISTINCT trim(x) COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_Denies, ''), ',')) AS x
        WHERE trim(x) <> '');

    IF EXISTS (SELECT 1 FROM unnest(v_Grants || v_Denies) AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p
                                 WHERE p.PermissionKey = w)) THEN
        RAISE EXCEPTION 'One of those permissions does not exist.' USING DETAIL = '61014';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Grants) AS g
               JOIN unnest(v_Denies) AS d ON d COLLATE ci = g) THEN
        RAISE EXCEPTION 'A permission cannot be granted and denied at once.' USING DETAIL = '61015';
    END IF;

    IF p_RoleId COLLATE ci = 'rol_owner' AND EXISTS (
        SELECT 1 FROM unnest(v_Denies) AS d
        WHERE d COLLATE ci IN ('users.edit', 'users.create')) THEN
        RAISE EXCEPTION 'An owner cannot be denied user management.' USING DETAIL = '61016';
    END IF;

    /* The maintenance vendor never sees money or customer data, however the
       grant arrives — through the role or added on top of it. */
    IF v_IsExternal AND EXISTS (
        SELECT 1 FROM unnest(v_Grants) AS g
        JOIN core.Permission AS p ON p.PermissionKey = g
        WHERE p.Sensitivity <> 'general') THEN
        RAISE EXCEPTION 'A maintenance account cannot hold financial or personal-data permissions.'
            USING DETAIL = '61008';
    END IF;

    /*--------------------------------------------------------- last owner */

    /* The last active owner cannot be suspended or demoted: someone has to be
       able to grant permissions back. */
    IF p_UserId IS NOT NULL
       AND (p_Status COLLATE ci <> 'active' OR p_RoleId COLLATE ci <> 'rol_owner')
       AND EXISTS (SELECT 1 FROM core.AppUser
                   WHERE UserId = p_UserId AND RoleId = 'rol_owner' AND Status = 'active')
       AND NOT EXISTS (SELECT 1 FROM core.AppUser
                       WHERE RoleId = 'rol_owner' AND Status = 'active' AND UserId <> p_UserId) THEN
        RAISE EXCEPTION 'This is the only active owner. Appoint another first.' USING DETAIL = '61009';
    END IF;

    /*-------------------------------------------------------------- write */

    v_BranchCsv := array_to_string(v_Branches, ',');

    IF p_UserId IS NULL THEN
        v_SavedId := core.fn_NewId('usr_');

        INSERT INTO core.AppUser
            (UserId, Username, FirstName, LastName, NameAr, NameEn, Email, Phone,
             Address, EmployeeId, RoleId, Status, IsExternal, AccessExpiresOn,
             TicketReference, BaseSalaryH, DefaultBranchId,
             PasswordHash, PasswordSalt, CreatedBy, UpdatedBy)
        VALUES
            (v_SavedId, v_Username, p_FirstName, p_LastName, p_NameAr, p_NameEn, p_Email, p_Phone,
             p_Address, p_EmployeeId, p_RoleId, p_Status, v_IsExternal, p_AccessExpiresOn,
             p_TicketReference, COALESCE(p_BaseSalaryH, 0), NULL,
             p_PasswordHash, p_PasswordSalt, p_Actor, p_Actor);
    ELSE
        v_SavedId := p_UserId;

        UPDATE core.AppUser
        SET Username = v_Username, FirstName = p_FirstName, LastName = p_LastName,
            NameAr = p_NameAr, NameEn = p_NameEn, Email = p_Email, Phone = p_Phone,
            Address = p_Address, EmployeeId = p_EmployeeId,
            RoleId = p_RoleId, Status = p_Status, IsExternal = v_IsExternal,
            AccessExpiresOn = p_AccessExpiresOn, TicketReference = p_TicketReference,
            BaseSalaryH = COALESCE(p_BaseSalaryH, BaseSalaryH),
            /* A blank password on edit keeps the current one. */
            PasswordHash = COALESCE(p_PasswordHash, PasswordHash),
            PasswordSalt = CASE WHEN p_PasswordHash IS NULL THEN PasswordSalt ELSE p_PasswordSalt END,
            UpdatedAtUtc = now() AT TIME ZONE 'utc', UpdatedBy = p_Actor
        WHERE UserId = p_UserId;
    END IF;

    SELECT b.Blocked INTO v_Blocked
    FROM core.usp_SetUserBranches(p_UserId => v_SavedId, p_BranchIds => v_BranchCsv) AS b;

    /* Everything it could refuse was checked above; this is the backstop. */
    IF v_Blocked IS NOT NULL THEN
        RAISE EXCEPTION '%', v_Blocked USING DETAIL = '61018';
    END IF;

    UPDATE core.AppUser SET DefaultBranchId = v_DefaultBranchId WHERE UserId = v_SavedId;

    SELECT o.Blocked INTO v_Blocked
    FROM core.usp_SetUserOverrides(p_UserId => v_SavedId, p_Grants => p_Grants, p_Denies => p_Denies) AS o;

    IF v_Blocked IS NOT NULL THEN
        RAISE EXCEPTION '%', v_Blocked USING DETAIL = '61018';
    END IF;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*------------------------------------------------------------- status changes */

/*
  Suspend, reactivate, or end an external account's access now.

  Sign-in already refuses a suspended account; revoking the refresh tokens as
  well means an open session cannot renew itself either, so the change takes
  effect within one access-token lifetime rather than whenever they log out.
*/
CREATE OR REPLACE FUNCTION core.usp_SetUserStatus(
    p_UserId       text,
    p_Status       text,
    p_Actor        text,
    p_RevokeAccess boolean DEFAULT false)   -- true also ends the access window today
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_Status COLLATE ci NOT IN ('active', 'suspended') THEN
        RAISE EXCEPTION 'Status must be active or suspended.' USING DETAIL = '61019';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = p_UserId) THEN
        RAISE EXCEPTION 'No such user.' USING DETAIL = '61010';
    END IF;

    IF p_Status COLLATE ci <> 'active'
       AND EXISTS (SELECT 1 FROM core.AppUser
                   WHERE UserId = p_UserId AND RoleId = 'rol_owner' AND Status = 'active')
       AND NOT EXISTS (SELECT 1 FROM core.AppUser
                       WHERE RoleId = 'rol_owner' AND Status = 'active' AND UserId <> p_UserId) THEN
        RAISE EXCEPTION 'This is the only active owner. Appoint another first.' USING DETAIL = '61009';
    END IF;

    UPDATE core.AppUser
    SET Status = p_Status,
        AccessExpiresOn = CASE WHEN p_RevokeAccess
                               THEN (now() AT TIME ZONE 'utc')::date
                               ELSE AccessExpiresOn END,
        UpdatedAtUtc = now() AT TIME ZONE 'utc', UpdatedBy = p_Actor
    WHERE UserId = p_UserId;

    IF p_Status COLLATE ci <> 'active' THEN
        UPDATE core.RefreshToken
        SET RevokedAtUtc = now() AT TIME ZONE 'utc'
        WHERE UserId = p_UserId AND RevokedAtUtc IS NULL;
    END IF;
END $$;

/*------------------------------------------------------------------ save role */

/*
  Create or edit a role, replacing its permission set wholesale.

  The owner role is not editable: it holds every permission by definition, and
  an owner who could trim it could lock everyone out of user administration.
  Built-in roles keep their names — other screens and the seed data refer to
  them — but their permissions are the owner's to tune.
*/
CREATE OR REPLACE FUNCTION core.usp_SaveRole(
    p_NameAr        text,
    p_NameEn        text,
    p_Permissions   text,                    -- comma separated permission keys
    p_RoleId        text    DEFAULT NULL,    -- null creates
    p_DescriptionAr text    DEFAULT NULL,
    p_DescriptionEn text    DEFAULT NULL,
    p_IsExternal    boolean DEFAULT false,   -- create only; fixed afterwards
    p_IsActive      boolean DEFAULT true)
RETURNS TABLE (SavedId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_NameAr   varchar := p_NameAr;
    v_NameEn   varchar := p_NameEn;
    v_BuiltIn  boolean;
    v_External boolean;
    v_Wanted   varchar[];
    v_SavedId  varchar;
BEGIN
    IF p_RoleId IS NOT NULL THEN
        SELECT IsBuiltIn, IsExternal INTO v_BuiltIn, v_External FROM core.Role WHERE RoleId = p_RoleId;

        IF v_BuiltIn IS NULL THEN
            RAISE EXCEPTION 'No such role.' USING DETAIL = '61056';
        END IF;

        IF p_RoleId COLLATE ci = 'rol_owner' THEN
            RAISE EXCEPTION 'The owner role always holds every permission and cannot be edited.'
                USING DETAIL = '61055';
        END IF;

        /* Built-in names stay; only the permissions are tunable. */
        IF v_BuiltIn THEN
            SELECT NameAr, NameEn INTO v_NameAr, v_NameEn FROM core.Role WHERE RoleId = p_RoleId;
        END IF;
    ELSE
        v_External := COALESCE(p_IsExternal, false);
    END IF;

    IF trim(COALESCE(v_NameAr, '')) = '' OR trim(COALESCE(v_NameEn, '')) = '' THEN
        RAISE EXCEPTION 'Both names are required.' USING DETAIL = '61050';
    END IF;

    IF EXISTS (SELECT 1 FROM core.Role
               WHERE (NameEn = v_NameEn OR NameAr = v_NameAr)
                 AND (p_RoleId IS NULL OR RoleId <> p_RoleId)) THEN
        RAISE EXCEPTION 'Another role already uses this name.' USING DETAIL = '61051';
    END IF;

    v_Wanted := ARRAY(
        SELECT DISTINCT trim(x) COLLATE ci
        FROM unnest(string_to_array(COALESCE(p_Permissions, ''), ',')) AS x
        WHERE trim(x) <> '');

    /* A role with nothing in it signs people in to an empty screen. */
    IF cardinality(v_Wanted) = 0 THEN
        RAISE EXCEPTION 'Give the role at least one permission, or nobody can use it.'
            USING DETAIL = '61052';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(v_Wanted) AS w
               WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p
                                 WHERE p.PermissionKey = w)) THEN
        RAISE EXCEPTION 'One of those permissions does not exist.' USING DETAIL = '61053';
    END IF;

    IF v_External AND EXISTS (
        SELECT 1 FROM unnest(v_Wanted) AS w
        JOIN core.Permission AS p ON p.PermissionKey = w
        WHERE p.Sensitivity <> 'general') THEN
        RAISE EXCEPTION 'A maintenance role cannot be given access to financial or personal data.'
            USING DETAIL = '61054';
    END IF;

    /* Retiring a role people still hold would leave them on something nobody
       can be given — move them first, as with any other deactivation. */
    IF p_RoleId IS NOT NULL AND NOT p_IsActive
       AND EXISTS (SELECT 1 FROM core.AppUser WHERE RoleId = p_RoleId) THEN
        RAISE EXCEPTION 'Users still hold this role. Move them to another role first.'
            USING DETAIL = '61059';
    END IF;

    IF p_RoleId IS NULL THEN
        v_SavedId := core.fn_NewId('rol_');

        INSERT INTO core.Role
            (RoleId, NameAr, NameEn, DescriptionAr, DescriptionEn, IsBuiltIn, IsExternal, IsActive)
        VALUES
            (v_SavedId, v_NameAr, v_NameEn, p_DescriptionAr, p_DescriptionEn, false, v_External, p_IsActive);
    ELSE
        v_SavedId := p_RoleId;

        UPDATE core.Role
        SET NameAr = v_NameAr, NameEn = v_NameEn,
            DescriptionAr = p_DescriptionAr, DescriptionEn = p_DescriptionEn,
            IsActive = p_IsActive, UpdatedAtUtc = now() AT TIME ZONE 'utc'
        WHERE RoleId = p_RoleId;
    END IF;

    DELETE FROM core.RolePermission WHERE RoleId = v_SavedId;

    INSERT INTO core.RolePermission (RoleId, PermissionKey)
    SELECT v_SavedId, w FROM unnest(v_Wanted) AS w;

    RETURN QUERY SELECT v_SavedId;
END $$;

/*---------------------------------------------------------------- delete role */

/*
  A real delete, because a role is configuration rather than history: no sale,
  payment or ledger line records which role its actor held. What can refer to a
  role is a user, and that is refused rather than cascaded.
*/
CREATE OR REPLACE FUNCTION core.usp_DeleteRole(p_RoleId text)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_BuiltIn  boolean;
    v_Assigned integer;
BEGIN
    SELECT IsBuiltIn INTO v_BuiltIn FROM core.Role WHERE RoleId = p_RoleId;

    IF v_BuiltIn IS NULL THEN
        RAISE EXCEPTION 'No such role.' USING DETAIL = '61056';
    END IF;

    IF v_BuiltIn THEN
        RAISE EXCEPTION 'Built-in roles cannot be deleted.' USING DETAIL = '61057';
    END IF;

    SELECT COUNT(*) INTO v_Assigned FROM core.AppUser WHERE RoleId = p_RoleId;

    IF v_Assigned > 0 THEN
        RAISE EXCEPTION '% user(s) still hold this role. Move them to another role first.', v_Assigned
            USING DETAIL = '61058';
    END IF;

    /* RolePermission cascades. */
    DELETE FROM core.Role WHERE RoleId = p_RoleId;
END $$;

/*---------------------------------------------------------- register business */

CREATE OR REPLACE FUNCTION core.usp_RegisterBusiness(
    p_CompanyNameAr text,
    p_CompanyNameEn text,
    p_BranchNameAr  text,
    p_BranchNameEn  text,
    p_OwnerNameAr   text,
    p_OwnerNameEn   text,
    p_OwnerEmail    text,
    p_OwnerPhone    text,
    p_CrNumber      text DEFAULT NULL,
    p_VatNumber     text DEFAULT NULL,
    p_City          text DEFAULT NULL,
    p_PasswordHash  text DEFAULT NULL,
    p_PasswordSalt  text DEFAULT NULL)
RETURNS TABLE (UserId varchar, BranchId varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Seq      integer;
    v_Number   text;
    v_BranchId varchar;
    v_UserId   varchar;
BEGIN
    /*---------------------------------------------------- validate up front */

    IF trim(COALESCE(p_CompanyNameAr, '')) = ''
       OR trim(COALESCE(p_CompanyNameEn, '')) = '' THEN
        RAISE EXCEPTION 'The company needs both an Arabic and an English name.' USING DETAIL = '53000';
    END IF;

    IF trim(COALESCE(p_OwnerEmail, '')) = '' THEN
        RAISE EXCEPTION 'An email address is required.' USING DETAIL = '53001';
    END IF;

    /* One account per email or mobile. Two accounts on the same address makes
       sign-in ambiguous, since the OTP flow looks people up by identifier. */
    IF EXISTS (SELECT 1 FROM core.AppUser WHERE Email = p_OwnerEmail) THEN
        RAISE EXCEPTION 'An account already exists for that email address.' USING DETAIL = '53002';
    END IF;

    IF p_OwnerPhone IS NOT NULL AND EXISTS (SELECT 1 FROM core.AppUser WHERE Phone = p_OwnerPhone) THEN
        RAISE EXCEPTION 'An account already exists for that mobile number.' USING DETAIL = '53003';
    END IF;

    IF p_VatNumber IS NOT NULL AND length(p_VatNumber) > 0
       AND (length(p_VatNumber) <> 15 OR p_VatNumber !~ '^[0-9]*$'
            OR left(p_VatNumber, 1) <> '3' OR right(p_VatNumber, 1) <> '3') THEN
        RAISE EXCEPTION 'A Saudi VAT number is 15 digits beginning and ending with 3.' USING DETAIL = '53004';
    END IF;

    /*---------------------------------------------------------------- write */

    v_Seq := nextval('core.BranchSequence');

    /* At least three digits, as FORMAT(n, '000') wrote it; more once past 999. */
    v_Number   := lpad(v_Seq::text, greatest(3, length(v_Seq::text)), '0');
    v_BranchId := 'brn_' || v_Number;
    v_UserId   := core.fn_NewId('usr_');

    /* One company row for this deployment. A second registration against an
       existing company adds a branch rather than a duplicate business. */
    IF NOT EXISTS (SELECT 1 FROM core.Company) THEN
        INSERT INTO core.Company (NameAr, NameEn, CrNumber, VatNumber, City, Country)
        VALUES (p_CompanyNameAr, p_CompanyNameEn,
                NULLIF(p_CrNumber, ''), NULLIF(p_VatNumber, ''), p_City, 'SA');
    END IF;

    INSERT INTO core.Branch (BranchId, Code, NameAr, NameEn, Phone, IsActive)
    VALUES (v_BranchId, 'BR-' || v_Number,
            p_BranchNameAr, p_BranchNameEn, p_OwnerPhone, true);

    INSERT INTO core.BranchSettings (BranchId) VALUES (v_BranchId);

    /* The hash arrives already computed by the API's hasher (the one
       sign-in verifies with). NULL leaves an OTP-only account, which a
       password sign-in refuses rather than guesses at. */
    INSERT INTO core.AppUser
        (UserId, Username, NameAr, NameEn, Email, Phone, RoleId,
         Status, IsExternal, BaseSalaryH, CreatedBy, PasswordHash, PasswordSalt)
    VALUES
        (v_UserId, p_OwnerEmail, p_OwnerNameAr, p_OwnerNameEn, p_OwnerEmail, p_OwnerPhone,
         'rol_owner', 'active', false, 0, 'registration', p_PasswordHash, p_PasswordSalt);

    INSERT INTO core.UserBranch (UserId, BranchId) VALUES (v_UserId, v_BranchId);

    RETURN QUERY SELECT v_UserId, v_BranchId;
END $$;

/*------------------------------------------------------------------- purges */

/* Expired challenges and tokens are noise. Schedule this nightly. */
CREATE OR REPLACE FUNCTION core.usp_PurgeExpiredAuth()
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM core.OtpChallenge
    WHERE ExpiresAtUtc < (now() AT TIME ZONE 'utc') - interval '1 day';

    DELETE FROM core.RefreshToken
    WHERE ExpiresAtUtc < (now() AT TIME ZONE 'utc') - interval '7 days';

    DELETE FROM core.LoginAttempt
    WHERE AttemptedAtUtc < (now() AT TIME ZONE 'utc') - interval '90 days';
END $$;

/* Telemetry is not evidence; it ages out. The audit trail does not. */
CREATE OR REPLACE FUNCTION audit.usp_PurgeTelemetry(p_KeepDays integer DEFAULT 30)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM audit.QueryTiming
    WHERE OccurredAtUtc < (now() AT TIME ZONE 'utc') - make_interval(days => p_KeepDays);

    DELETE FROM audit.RequestTiming
    WHERE OccurredAtUtc < (now() AT TIME ZONE 'utc') - make_interval(days => p_KeepDays);
END $$;
