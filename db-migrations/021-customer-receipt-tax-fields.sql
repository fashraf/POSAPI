/*==============================================================================
  Nazad POS — 021 · Customer receipts always carry the tax-invoice fields

  A Saudi B2C receipt is a simplified tax invoice, and ZATCA requires it to
  show the seller's VAT number, the VAT amount and the QR code. The bill
  builder let all three be switched off on a customer template.

  core.usp_SaveBillTemplate now refuses a customer template with any of them
  off: 62031 (VAT number), 62032 (VAT line), 62033 (QR code). Group tickets
  (kitchen, bar...) are not invoices and are unaffected.

  Existing customer templates saved with any of them off are switched back on,
  so what is stored matches what prints.

  Re-runnable: CREATE OR ALTER, and the UPDATE only touches rows still off.
==============================================================================*/

USE POSMAIN;
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

    /*
      A customer receipt is a simplified tax invoice (ZATCA): it must carry the
      seller's VAT number, the VAT amount and the QR code. Those three are not
      layout preferences on a customer template, so they cannot be saved off.
      A kitchen or group ticket is not an invoice and stays free to hide them.
    */
    IF @Audience = N'customer' AND @ShowVatNumber = 0
        THROW 62031, N'A customer receipt must show the VAT number.', 1;

    IF @Audience = N'customer' AND @ShowVat = 0
        THROW 62032, N'A customer receipt must show the VAT amount.', 1;

    IF @Audience = N'customer' AND @ShowZatcaQr = 0
        THROW 62033, N'A customer receipt must show the ZATCA QR code.', 1;

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

UPDATE core.BillTemplate
SET ShowVatNumber = 1, ShowVat = 1, ShowZatcaQr = 1, UpdatedAtUtc = SYSUTCDATETIME()
WHERE Audience = N'customer'
  AND (ShowVatNumber = 0 OR ShowVat = 0 OR ShowZatcaQr = 0);
GO
