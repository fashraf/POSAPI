/*==============================================================================
  Nazad POS — 27 · Company profile and bill templates

  Backs GET/PUT /api/company and the /api/bill-templates routes.

  Schema, kept to what the screens already edit and had nowhere to store:
    - core.Company gains SocialLinks, a small JSON object of handles
      ({"instagram": "...", ...}). Six platforms as six columns would mean a
      migration every time a platform is added; nothing queries them, they are
      only printed and shown.
    - core.BillTemplate gains the layout switches the bill builder already has:
      HeaderAlignment, LogoSize, ShowCompanyName, ShowDescription, ShowAddress,
      ShowItemName, ShowSku, ShowBarcode, ShowQuantity, ShowLineDiscount.

  core.usp_SaveCompany now applies the same VAT and CR rules as the table's
  CHECK constraints. Before, a VAT number of fifteen digits that did not start
  and end in 3 passed the procedure and failed the constraint — an unhandled
  error instead of a message.

  Error numbers 62000–62049.
==============================================================================*/

USE POSMAIN;
GO

/*---------------------------------------------------------------------- schema */

IF COL_LENGTH(N'core.Company', N'SocialLinks') IS NULL
    ALTER TABLE core.Company ADD SocialLinks NVARCHAR(2000) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Company_SocialJson')
    ALTER TABLE core.Company ADD CONSTRAINT CK_Company_SocialJson
        CHECK (SocialLinks IS NULL OR ISJSON(SocialLinks) = 1);
GO

IF COL_LENGTH(N'core.BillTemplate', N'HeaderAlignment') IS NULL
    ALTER TABLE core.BillTemplate ADD HeaderAlignment NVARCHAR(10) NOT NULL
        CONSTRAINT DF_BillTemplate_HeaderAlignment DEFAULT (N'center')
        CONSTRAINT CK_BillTemplate_HeaderAlignment CHECK (HeaderAlignment IN (N'start', N'center', N'end'));
IF COL_LENGTH(N'core.BillTemplate', N'LogoSize') IS NULL
    ALTER TABLE core.BillTemplate ADD LogoSize NVARCHAR(4) NOT NULL
        CONSTRAINT DF_BillTemplate_LogoSize DEFAULT (N'md')
        CONSTRAINT CK_BillTemplate_LogoSize CHECK (LogoSize IN (N'sm', N'md', N'lg'));
IF COL_LENGTH(N'core.BillTemplate', N'ShowCompanyName') IS NULL
    ALTER TABLE core.BillTemplate ADD ShowCompanyName BIT NOT NULL
        CONSTRAINT DF_BillTemplate_ShowCompanyName DEFAULT (1);
IF COL_LENGTH(N'core.BillTemplate', N'ShowDescription') IS NULL
    ALTER TABLE core.BillTemplate ADD ShowDescription BIT NOT NULL
        CONSTRAINT DF_BillTemplate_ShowDescription DEFAULT (1);
IF COL_LENGTH(N'core.BillTemplate', N'ShowAddress') IS NULL
    ALTER TABLE core.BillTemplate ADD ShowAddress BIT NOT NULL
        CONSTRAINT DF_BillTemplate_ShowAddress DEFAULT (0);
IF COL_LENGTH(N'core.BillTemplate', N'ShowItemName') IS NULL
    ALTER TABLE core.BillTemplate ADD ShowItemName BIT NOT NULL
        CONSTRAINT DF_BillTemplate_ShowItemName DEFAULT (1);
IF COL_LENGTH(N'core.BillTemplate', N'ShowSku') IS NULL
    ALTER TABLE core.BillTemplate ADD ShowSku BIT NOT NULL
        CONSTRAINT DF_BillTemplate_ShowSku DEFAULT (0);
IF COL_LENGTH(N'core.BillTemplate', N'ShowBarcode') IS NULL
    ALTER TABLE core.BillTemplate ADD ShowBarcode BIT NOT NULL
        CONSTRAINT DF_BillTemplate_ShowBarcode DEFAULT (0);
IF COL_LENGTH(N'core.BillTemplate', N'ShowQuantity') IS NULL
    ALTER TABLE core.BillTemplate ADD ShowQuantity BIT NOT NULL
        CONSTRAINT DF_BillTemplate_ShowQuantity DEFAULT (1);
IF COL_LENGTH(N'core.BillTemplate', N'ShowLineDiscount') IS NULL
    ALTER TABLE core.BillTemplate ADD ShowLineDiscount BIT NOT NULL
        CONSTRAINT DF_BillTemplate_ShowLineDiscount DEFAULT (0);
GO

/*--------------------------------------------------------------- save company */

CREATE OR ALTER PROCEDURE core.usp_SaveCompany
    @NameAr        NVARCHAR(160),
    @NameEn        NVARCHAR(160),
    @DescriptionAr NVARCHAR(400)  = NULL,
    @DescriptionEn NVARCHAR(400)  = NULL,
    @LogoUrl       NVARCHAR(400)  = NULL,
    @CrNumber      NVARCHAR(10)   = NULL,
    @VatNumber     NVARCHAR(15)   = NULL,
    @Phone         NVARCHAR(30)   = NULL,
    @Email         NVARCHAR(160)  = NULL,
    @Website       NVARCHAR(160)  = NULL,
    @Street        NVARCHAR(160)  = NULL,
    @District      NVARCHAR(120)  = NULL,
    @City          NVARCHAR(120)  = NULL,
    @PostalCode    NVARCHAR(12)   = NULL,
    @Country       NVARCHAR(80)   = NULL,
    @SocialLinks   NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 62000, N'Both company names are required.', 1;

    /* A Saudi VAT number is fifteen digits, starting and ending in 3. A wrong
       one prints on every invoice, so it is checked here rather than
       discovered by an auditor. */
    IF @VatNumber IS NOT NULL
       AND (LEN(@VatNumber) <> 15 OR @VatNumber LIKE N'%[^0-9]%'
            OR LEFT(@VatNumber, 1) <> N'3' OR RIGHT(@VatNumber, 1) <> N'3')
        THROW 62001, N'A VAT number is 15 digits, starting and ending with 3.', 1;

    IF @CrNumber IS NOT NULL AND (LEN(@CrNumber) <> 10 OR @CrNumber LIKE N'%[^0-9]%')
        THROW 62002, N'A CR number is 10 digits.', 1;

    IF @SocialLinks IS NOT NULL AND ISJSON(@SocialLinks) = 0
        THROW 62004, N'The social links are not valid.', 1;

    UPDATE core.Company
    SET NameAr = @NameAr, NameEn = @NameEn,
        DescriptionAr = @DescriptionAr, DescriptionEn = @DescriptionEn,
        LogoUrl = @LogoUrl, CrNumber = @CrNumber, VatNumber = @VatNumber,
        Phone = @Phone, Email = @Email, Website = @Website,
        Street = @Street, District = @District, City = @City,
        PostalCode = @PostalCode, Country = @Country, SocialLinks = @SocialLinks,
        UpdatedAtUtc = SYSUTCDATETIME();

    IF @@ROWCOUNT = 0 THROW 62003, N'No company record exists.', 1;
END
GO

/*--------------------------------------------------------- save bill template */

CREATE OR ALTER PROCEDURE core.usp_SaveBillTemplate
    @BillId           NVARCHAR(40) = NULL,   -- null creates
    @Name             NVARCHAR(120),
    @Audience         NVARCHAR(20),
    @PrintGroupId     NVARCHAR(40) = NULL,
    @IsDefault        BIT = 0,
    @PaperSize        NVARCHAR(10) = N'80mm',
    @BillLanguage     NVARCHAR(10) = N'both',
    @HeaderAlignment  NVARCHAR(10) = N'center',
    @LogoSize         NVARCHAR(4)  = N'md',
    @ShowLogo         BIT = 1,
    @ShowCompanyName  BIT = 1,
    @ShowDescription  BIT = 1,
    @ShowVatNumber    BIT = 1,
    @ShowCrNumber     BIT = 0,
    @ShowAddress      BIT = 0,
    @ShowItemName     BIT = 1,
    @ShowSku          BIT = 0,
    @ShowBarcode      BIT = 0,
    @ShowUnitPrice    BIT = 1,
    @ShowQuantity     BIT = 1,
    @ShowLineTotal    BIT = 1,
    @ShowLineDiscount BIT = 0,
    @ShowSubtotal     BIT = 1,
    @ShowDiscount     BIT = 1,
    @ShowVat          BIT = 1,
    @ShowGrandTotal   BIT = 1,
    @ShowZatcaQr      BIT = 1,
    @FooterAr         NVARCHAR(400) = NULL,
    @FooterEn         NVARCHAR(400) = NULL,
    @IsActive         BIT = 1,
    @SavedId          NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@Name, N''))) = N''
        THROW 62020, N'A template needs a name.', 1;

    IF @PaperSize NOT IN (N'58mm', N'80mm', N'a4')
        THROW 62021, N'Paper size must be 58mm, 80mm or a4.', 1;

    IF @Audience NOT IN (N'customer', N'group')
        THROW 62022, N'A template is for the customer or for a print group.', 1;

    IF @BillLanguage NOT IN (N'ar', N'en', N'both')
        THROW 62027, N'Language must be ar, en or both.', 1;

    IF @HeaderAlignment NOT IN (N'start', N'center', N'end') OR @LogoSize NOT IN (N'sm', N'md', N'lg')
        THROW 62028, N'That header layout is not recognised.', 1;

    /* A customer receipt carries the whole order, so a print group on it
       would mean nothing — and leaving one there makes resolving confusing. */
    IF @Audience = N'customer' SET @PrintGroupId = NULL;

    IF @Audience = N'group' AND @PrintGroupId IS NULL
        THROW 62023, N'Choose which print group this ticket is for.', 1;

    IF @PrintGroupId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.PrintGroup WHERE PrintGroupId = @PrintGroupId)
        THROW 62024, N'No such print group.', 1;

    /*
      A customer receipt must show the total.

      Everything else is a layout preference; a receipt without a total is not a
      receipt, and a customer cannot check what they were charged.
    */
    IF @Audience = N'customer' AND @ShowGrandTotal = 0
        THROW 62025, N'A customer receipt must show the total.', 1;

    IF @BillId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.BillTemplate WHERE BillId = @BillId)
        THROW 62026, N'No such template.', 1;

    BEGIN TRAN;

        IF @BillId IS NULL
        BEGIN
            SET @SavedId = CONCAT(N'bil_',
                LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

            INSERT INTO core.BillTemplate
                (BillId, Name, Audience, PrintGroupId, IsDefault, PaperSize, BillLanguage,
                 HeaderAlignment, LogoSize,
                 ShowLogo, ShowCompanyName, ShowDescription, ShowVatNumber, ShowCrNumber, ShowAddress,
                 ShowItemName, ShowSku, ShowBarcode, ShowUnitPrice, ShowQuantity, ShowLineTotal,
                 ShowLineDiscount, ShowSubtotal, ShowDiscount, ShowVat, ShowGrandTotal, ShowZatcaQr,
                 FooterAr, FooterEn, IsActive)
            VALUES
                (@SavedId, @Name, @Audience, @PrintGroupId, @IsDefault, @PaperSize, @BillLanguage,
                 @HeaderAlignment, @LogoSize,
                 @ShowLogo, @ShowCompanyName, @ShowDescription, @ShowVatNumber, @ShowCrNumber, @ShowAddress,
                 @ShowItemName, @ShowSku, @ShowBarcode, @ShowUnitPrice, @ShowQuantity, @ShowLineTotal,
                 @ShowLineDiscount, @ShowSubtotal, @ShowDiscount, @ShowVat, @ShowGrandTotal, @ShowZatcaQr,
                 @FooterAr, @FooterEn, @IsActive);
        END
        ELSE
        BEGIN
            SET @SavedId = @BillId;

            UPDATE core.BillTemplate
            SET Name = @Name, Audience = @Audience, PrintGroupId = @PrintGroupId,
                IsDefault = @IsDefault, PaperSize = @PaperSize, BillLanguage = @BillLanguage,
                HeaderAlignment = @HeaderAlignment, LogoSize = @LogoSize,
                ShowLogo = @ShowLogo, ShowCompanyName = @ShowCompanyName,
                ShowDescription = @ShowDescription, ShowVatNumber = @ShowVatNumber,
                ShowCrNumber = @ShowCrNumber, ShowAddress = @ShowAddress,
                ShowItemName = @ShowItemName, ShowSku = @ShowSku, ShowBarcode = @ShowBarcode,
                ShowUnitPrice = @ShowUnitPrice, ShowQuantity = @ShowQuantity,
                ShowLineTotal = @ShowLineTotal, ShowLineDiscount = @ShowLineDiscount,
                ShowSubtotal = @ShowSubtotal, ShowDiscount = @ShowDiscount,
                ShowVat = @ShowVat, ShowGrandTotal = @ShowGrandTotal, ShowZatcaQr = @ShowZatcaQr,
                FooterAr = @FooterAr, FooterEn = @FooterEn, IsActive = @IsActive,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE BillId = @BillId;
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

/*------------------------------------------------------- delete bill template */

/*
  A real delete. A template is layout, not history: a printed receipt does not
  record which template drew it, so removing one orphans nothing. What does
  point at a template — a branch's default bill — is refused rather than
  silently cleared, and so is the audience default, which is what prints when
  nothing more specific matches.
*/
CREATE OR ALTER PROCEDURE core.usp_DeleteBillTemplate
    @BillId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IsDefault BIT = (SELECT IsDefault FROM core.BillTemplate WHERE BillId = @BillId);

    IF @IsDefault IS NULL
        THROW 62026, N'No such template.', 1;

    IF @IsDefault = 1
        THROW 62029, N'Make another template the default before deleting this one.', 1;

    IF EXISTS (SELECT 1 FROM core.BranchSettings WHERE DefaultBillId = @BillId)
        THROW 62030, N'A branch uses this as its default bill. Change that branch first.', 1;

    DELETE FROM core.BillTemplate WHERE BillId = @BillId;
END
GO

PRINT N'27 · Company profile and bill templates ready.';
GO

/*----------------------------------------------------------------------- check */

SELECT
    CASE WHEN COL_LENGTH(N'core.Company', N'SocialLinks') IS NULL
              THEN N'FAIL  core.Company.SocialLinks missing'
         WHEN COL_LENGTH(N'core.BillTemplate', N'ShowLineDiscount') IS NULL
              THEN N'FAIL  core.BillTemplate columns missing'
         WHEN OBJECT_ID(N'core.usp_DeleteBillTemplate') IS NULL
              THEN N'FAIL  procedures missing'
         ELSE N'PASS  Company and bill templates ready'
    END AS Result;
GO
