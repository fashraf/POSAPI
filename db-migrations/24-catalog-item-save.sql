/*==============================================================================
  Nazad POS — 24 · Catalog item save

  core.usp_SaveCatalogItem was created on the development database outside the
  migration scripts, so a fresh install did not have it. The API's create and
  edit routes (POST/PUT /api/catalog/items) call it; this file is that
  procedure, unchanged, so every install has the same one.
==============================================================================*/

USE POSMAIN;
GO

CREATE OR ALTER PROCEDURE core.usp_SaveCatalogItem
    @ItemId              NVARCHAR(40)  = NULL,   -- null creates
    @Kind                NVARCHAR(20),
    @NameAr              NVARCHAR(200),
    @NameEn              NVARCHAR(200),
    @DescriptionAr       NVARCHAR(600) = NULL,
    @DescriptionEn       NVARCHAR(600) = NULL,
    @Sku                 NVARCHAR(60)  = NULL,
    @Barcode             NVARCHAR(60)  = NULL,
    @CategoryId          NVARCHAR(40)  = NULL,
    @VendorId            NVARCHAR(40)  = NULL,
    @PrintGroupId        NVARCHAR(40)  = NULL,
    @PriceH              BIGINT,
    @CostH               BIGINT = 0,
    @TracksStock         BIT = 1,
    @ReorderLevel        DECIMAL(18,3) = 0,
    @RequiresPreparation BIT = 0,
    @IsActive            BIT = 1,
    @Actor               NVARCHAR(160),
    @SavedItemId         NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 59000, N'Both names are required.', 1;

    IF @PriceH < 0 THROW 59001, N'A price cannot be negative.', 1;
    IF @CostH  < 0 THROW 59002, N'A cost cannot be negative.', 1;

    /* A service has nothing to count. Letting it track stock would produce
       movements against a thing that does not exist. */
    IF @Kind = N'service' SET @TracksStock = 0;

    /* Barcodes are scanned. Two items sharing one means the till picks the
       wrong product, silently. */
    IF @Barcode IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.CatalogItem
        WHERE Barcode = @Barcode AND (@ItemId IS NULL OR ItemId <> @ItemId))
        THROW 59003, N'That barcode is already used by another item.', 1;

    IF @Sku IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.CatalogItem
        WHERE Sku = @Sku AND (@ItemId IS NULL OR ItemId <> @ItemId))
        THROW 59004, N'That SKU is already used by another item.', 1;

    IF @ItemId IS NULL
    BEGIN
        SET @SavedItemId = CONCAT(N'itm_',
            LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO core.CatalogItem
            (ItemId, Kind, NameAr, NameEn, DescriptionAr, DescriptionEn, Sku, Barcode,
             CategoryId, VendorId, PrintGroupId, PriceH, CostH, TracksStock,
             ReorderLevel, RequiresPreparation, IsActive, CreatedBy)
        VALUES
            (@SavedItemId, @Kind, @NameAr, @NameEn, @DescriptionAr, @DescriptionEn,
             @Sku, @Barcode, @CategoryId, @VendorId, @PrintGroupId, @PriceH, @CostH,
             @TracksStock, @ReorderLevel, @RequiresPreparation, @IsActive, @Actor);
    END
    ELSE
    BEGIN
        SET @SavedItemId = @ItemId;

        /*
          Cost is not editable here.

          It is a weighted average maintained by receiving, and overwriting it
          from an edit form would make every past margin wrong. Correcting a
          cost is an inventory adjustment, not a product edit.
        */
        UPDATE core.CatalogItem
        SET Kind                = @Kind,
            NameAr              = @NameAr,
            NameEn              = @NameEn,
            DescriptionAr       = @DescriptionAr,
            DescriptionEn       = @DescriptionEn,
            Sku                 = @Sku,
            Barcode             = @Barcode,
            CategoryId          = @CategoryId,
            VendorId            = @VendorId,
            PrintGroupId        = @PrintGroupId,
            PriceH              = @PriceH,
            TracksStock         = @TracksStock,
            ReorderLevel        = @ReorderLevel,
            RequiresPreparation = @RequiresPreparation,
            IsActive            = @IsActive,
            UpdatedAtUtc        = SYSUTCDATETIME(),
            UpdatedBy           = @Actor
        WHERE ItemId = @ItemId;

        IF @@ROWCOUNT = 0 THROW 59005, N'No such item.', 1;
    END
END
GO

PRINT N'24 · core.usp_SaveCatalogItem ready.';
GO
