/*==============================================================================
  Nazad POS — 43 · Registration keeps the owner's password

  The sign-up wizard asks for a password, the API received it, and
  usp_RegisterBusiness dropped it: the owner row was created with
  PasswordHash NULL. With the API in single-password sign-in mode, the person
  who just registered the business could never sign in.

  The API now hashes the password (Auth/PasswordHasher.cs, the same hasher
  sign-in verifies against) and passes hash and salt here, so the account and
  its credential are written in the same transaction.
==============================================================================*/

USE POSMAIN;
GO

CREATE OR ALTER PROCEDURE core.usp_RegisterBusiness
    @CompanyNameAr   NVARCHAR(160),
    @CompanyNameEn   NVARCHAR(160),
    @CrNumber        NVARCHAR(10)  = NULL,
    @VatNumber       NVARCHAR(15)  = NULL,
    @City            NVARCHAR(120) = NULL,

    @BranchNameAr    NVARCHAR(160),
    @BranchNameEn    NVARCHAR(160),

    @OwnerNameAr     NVARCHAR(160),
    @OwnerNameEn     NVARCHAR(160),
    @OwnerEmail      NVARCHAR(160),
    @OwnerPhone      NVARCHAR(30),
    @PasswordHash    NVARCHAR(400) = NULL,
    @PasswordSalt    NVARCHAR(200) = NULL,

    @UserId          NVARCHAR(40) OUTPUT,
    @BranchId        NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*---------------------------------------------------- validate up front */

    IF LTRIM(RTRIM(ISNULL(@CompanyNameAr, N''))) = N''
       OR LTRIM(RTRIM(ISNULL(@CompanyNameEn, N''))) = N''
        THROW 53000, N'The company needs both an Arabic and an English name.', 1;

    IF LTRIM(RTRIM(ISNULL(@OwnerEmail, N''))) = N''
        THROW 53001, N'An email address is required.', 1;

    /* One account per email or mobile. Two accounts on the same address makes
       sign-in ambiguous, since the OTP flow looks people up by identifier. */
    IF EXISTS (SELECT 1 FROM core.AppUser WHERE Email = @OwnerEmail)
        THROW 53002, N'An account already exists for that email address.', 1;

    IF @OwnerPhone IS NOT NULL AND EXISTS (SELECT 1 FROM core.AppUser WHERE Phone = @OwnerPhone)
        THROW 53003, N'An account already exists for that mobile number.', 1;

    IF @VatNumber IS NOT NULL AND LEN(@VatNumber) > 0
       AND (LEN(@VatNumber) <> 15 OR @VatNumber LIKE N'%[^0-9]%'
            OR LEFT(@VatNumber,1) <> N'3' OR RIGHT(@VatNumber,1) <> N'3')
        THROW 53004, N'A Saudi VAT number is 15 digits beginning and ending with 3.', 1;

    /*---------------------------------------------------------------- write */

    BEGIN TRAN;

        DECLARE @Seq INT = NEXT VALUE FOR core.BranchSequence;

        SET @BranchId = CONCAT(N'brn_', FORMAT(@Seq, N'000'));
        SET @UserId   = CONCAT(N'usr_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        /* One company row for this deployment. A second registration against an
           existing company adds a branch rather than a duplicate business. */
        IF NOT EXISTS (SELECT 1 FROM core.Company)
        BEGIN
            INSERT INTO core.Company (NameAr, NameEn, CrNumber, VatNumber, City, Country)
            VALUES (@CompanyNameAr, @CompanyNameEn,
                    NULLIF(@CrNumber, N''), NULLIF(@VatNumber, N''), @City, N'SA');
        END

        INSERT INTO core.Branch (BranchId, Code, NameAr, NameEn, Phone, IsActive)
        VALUES (@BranchId, CONCAT(N'BR-', FORMAT(@Seq, N'000')),
                @BranchNameAr, @BranchNameEn, @OwnerPhone, 1);

        INSERT INTO core.BranchSettings (BranchId) VALUES (@BranchId);

        /* The hash arrives already computed by the API's hasher (the one
           sign-in verifies with). NULL leaves an OTP-only account, which a
           password sign-in refuses rather than guesses at. */
        INSERT INTO core.AppUser
            (UserId, Username, NameAr, NameEn, Email, Phone, RoleId,
             Status, IsExternal, BaseSalaryH, CreatedBy, PasswordHash, PasswordSalt)
        VALUES
            (@UserId, @OwnerEmail, @OwnerNameAr, @OwnerNameEn, @OwnerEmail, @OwnerPhone,
             N'rol_owner', N'active', 0, 0, N'registration', @PasswordHash, @PasswordSalt);

        INSERT INTO core.UserBranch (UserId, BranchId) VALUES (@UserId, @BranchId);

    COMMIT;
END
GO

PRINT N'43 · Registration stores the owner password.';
GO
