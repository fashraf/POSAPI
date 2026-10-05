/*==============================================================================
  Nazad POS — 020 · Catalog integrity

  Three rules the catalog screens promised but the database never enforced:

  1. No two categories with the same name (QA: two "Beverages"). Compared per
     language, trimmed and case-insensitive. core.usp_SaveCategory refuses a
     duplicate with 65004 (Arabic name) / 65005 (English name).
  2. The same for print groups: 65013 / 65014 from core.usp_SavePrintGroup.
  3. A product (kind = product) needs a SKU; a service does not. 59006 from
     core.usp_SaveCatalogItem.

  Unique indexes back rules 1 and 2 where the data allows. The column
  collation is case-insensitive and SQL Server ignores trailing spaces when it
  compares, so a plain unique index on the name already matches the
  procedures' "trimmed, any case" rule (the procedures also trim before they
  store, so leading spaces never reach the table).

  Existing duplicates are NOT renamed: a migration has no business choosing
  which "Beverages" is the real one. If any exist, the index is skipped and the
  duplicates are listed in the output; the procedure rule still applies to
  every save from now on (and an edit of one of the duplicates must give it a
  distinct name). Rename them in the catalog screen and run this file again to
  add the index. Existing products without a SKU are likewise left as they
  are, and need one the next time they are edited.

  Re-runnable: CREATE OR ALTER, and each index is created only if missing.
==============================================================================*/

USE POSMAIN;
GO

/*-------------------------------------------------------------- save category */

CREATE OR ALTER PROCEDURE core.usp_SaveCategory
    @CategoryId  NVARCHAR(40) = NULL,   -- null creates
    @NameAr      NVARCHAR(120),
    @NameEn      NVARCHAR(120),
    @AppliesTo   NVARCHAR(10) = N'both',
    @SortOrder   INT = NULL,            -- null: after the last one
    @IsActive    BIT = 1,
    @SavedId     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @NameAr = LTRIM(RTRIM(ISNULL(@NameAr, N'')));
    SET @NameEn = LTRIM(RTRIM(ISNULL(@NameEn, N'')));

    IF @NameAr = N'' OR @NameEn = N''
        THROW 65000, N'Both names are required.', 1;

    IF @AppliesTo NOT IN (N'product', N'service', N'both')
        THROW 65001, N'A category holds products, services or both.', 1;

    IF @CategoryId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Category WHERE CategoryId = @CategoryId)
        THROW 65002, N'No such category.', 1;

    /* One name, one category, in either language. Two "Beverages" on the POS
       rail leaves the cashier guessing which one holds the item. The column
       collation is case-insensitive; LTRIM/RTRIM covers rows saved before
       this procedure trimmed. */
    IF EXISTS (SELECT 1 FROM core.Category
               WHERE LTRIM(RTRIM(NameAr)) = @NameAr
                 AND (@CategoryId IS NULL OR CategoryId <> @CategoryId))
        THROW 65004, N'Another category already has this Arabic name.', 1;

    IF EXISTS (SELECT 1 FROM core.Category
               WHERE LTRIM(RTRIM(NameEn)) = @NameEn
                 AND (@CategoryId IS NULL OR CategoryId <> @CategoryId))
        THROW 65005, N'Another category already has this English name.', 1;

    IF @CategoryId IS NOT NULL AND @IsActive = 0
       AND EXISTS (SELECT 1 FROM core.CatalogItem WHERE CategoryId = @CategoryId AND IsActive = 1)
    BEGIN
        DECLARE @Message NVARCHAR(400) = CONCAT(
            N'This category still has ',
            (SELECT COUNT(*) FROM core.CatalogItem WHERE CategoryId = @CategoryId AND IsActive = 1),
            N' active items. Move or deactivate them first.');
        THROW 65003, @Message, 1;
    END;

    IF @CategoryId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'cat_',
            LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO core.Category (CategoryId, NameAr, NameEn, AppliesTo, SortOrder, IsActive)
        VALUES (@SavedId, @NameAr, @NameEn, @AppliesTo,
                ISNULL(@SortOrder, (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM core.Category)),
                @IsActive);
    END
    ELSE
    BEGIN
        SET @SavedId = @CategoryId;

        UPDATE core.Category
        SET NameAr = @NameAr, NameEn = @NameEn, AppliesTo = @AppliesTo,
            SortOrder = ISNULL(@SortOrder, SortOrder),
            IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME()
        WHERE CategoryId = @CategoryId;
    END
END
GO

/*----------------------------------------------------------- save print group */

CREATE OR ALTER PROCEDURE core.usp_SavePrintGroup
    @PrintGroupId NVARCHAR(40) = NULL,   -- null creates
    @NameAr       NVARCHAR(120),
    @NameEn       NVARCHAR(120),
    @TicketTitle  NVARCHAR(120) = NULL,  -- null: the English name
    @SortOrder    INT = NULL,            -- null: after the last one
    @IsActive     BIT = 1,
    @SavedId      NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @NameAr = LTRIM(RTRIM(ISNULL(@NameAr, N'')));
    SET @NameEn = LTRIM(RTRIM(ISNULL(@NameEn, N'')));

    IF @NameAr = N'' OR @NameEn = N''
        THROW 65010, N'Both names are required.', 1;

    IF @PrintGroupId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.PrintGroup WHERE PrintGroupId = @PrintGroupId)
        THROW 65011, N'No such print group.', 1;

    /* Two groups with one name print two tickets nobody can tell apart. */
    IF EXISTS (SELECT 1 FROM core.PrintGroup
               WHERE LTRIM(RTRIM(NameAr)) = @NameAr
                 AND (@PrintGroupId IS NULL OR PrintGroupId <> @PrintGroupId))
        THROW 65013, N'Another print group already has this Arabic name.', 1;

    IF EXISTS (SELECT 1 FROM core.PrintGroup
               WHERE LTRIM(RTRIM(NameEn)) = @NameEn
                 AND (@PrintGroupId IS NULL OR PrintGroupId <> @PrintGroupId))
        THROW 65014, N'Another print group already has this English name.', 1;

    /* An item whose group is off has nowhere to print its ticket. */
    IF @PrintGroupId IS NOT NULL AND @IsActive = 0
       AND EXISTS (SELECT 1 FROM core.CatalogItem WHERE PrintGroupId = @PrintGroupId AND IsActive = 1)
        THROW 65012, N'This print group is still used by active items. Reassign them first, or their tickets will not print.', 1;

    SET @TicketTitle = NULLIF(LTRIM(RTRIM(@TicketTitle)), N'');

    IF @PrintGroupId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'pgr_',
            LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO core.PrintGroup (PrintGroupId, NameAr, NameEn, TicketTitle, SortOrder, IsActive)
        VALUES (@SavedId, @NameAr, @NameEn, ISNULL(@TicketTitle, @NameEn),
                ISNULL(@SortOrder, (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM core.PrintGroup)),
                @IsActive);
    END
    ELSE
    BEGIN
        SET @SavedId = @PrintGroupId;

        UPDATE core.PrintGroup
        SET NameAr = @NameAr, NameEn = @NameEn, TicketTitle = ISNULL(@TicketTitle, @NameEn),
            SortOrder = ISNULL(@SortOrder, SortOrder), IsActive = @IsActive,
            UpdatedAtUtc = SYSUTCDATETIME()
        WHERE PrintGroupId = @PrintGroupId;
    END
END
GO

/*---------------------------------------------------------- save catalog item */

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

    /* '' is "none", the same as NULL — never a value two items could share. */
    SET @Sku     = NULLIF(LTRIM(RTRIM(@Sku)), N'');
    SET @Barcode = NULLIF(LTRIM(RTRIM(@Barcode)), N'');

    /* A product is counted, received and looked up by its SKU; a product
       without one cannot be told apart on a stock sheet. A service has
       nothing on a shelf, so it does not need one. */
    IF @Kind = N'product' AND @Sku IS NULL
        THROW 59006, N'A product needs a SKU.', 1;

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

/*--------------------------------------------------- unique name indexes */

/* Each index only when the data already satisfies it — see the header for
   what happens to existing duplicates. */

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Category_NameAr' AND object_id = OBJECT_ID(N'core.Category'))
BEGIN
    IF EXISTS (SELECT 1 FROM core.Category GROUP BY LTRIM(RTRIM(NameAr)) HAVING COUNT(*) > 1)
    BEGIN
        PRINT N'WARNING: duplicate category Arabic names exist; UX_Category_NameAr not created. Rename these, then run 020 again:';
        SELECT CategoryId, NameAr, NameEn, IsActive FROM core.Category
        WHERE LTRIM(RTRIM(NameAr)) IN (SELECT LTRIM(RTRIM(NameAr)) FROM core.Category
                                       GROUP BY LTRIM(RTRIM(NameAr)) HAVING COUNT(*) > 1)
        ORDER BY NameAr, CategoryId;
    END
    ELSE
        CREATE UNIQUE INDEX UX_Category_NameAr ON core.Category (NameAr);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Category_NameEn' AND object_id = OBJECT_ID(N'core.Category'))
BEGIN
    IF EXISTS (SELECT 1 FROM core.Category GROUP BY LTRIM(RTRIM(NameEn)) HAVING COUNT(*) > 1)
    BEGIN
        PRINT N'WARNING: duplicate category English names exist; UX_Category_NameEn not created. Rename these, then run 020 again:';
        SELECT CategoryId, NameAr, NameEn, IsActive FROM core.Category
        WHERE LTRIM(RTRIM(NameEn)) IN (SELECT LTRIM(RTRIM(NameEn)) FROM core.Category
                                       GROUP BY LTRIM(RTRIM(NameEn)) HAVING COUNT(*) > 1)
        ORDER BY NameEn, CategoryId;
    END
    ELSE
        CREATE UNIQUE INDEX UX_Category_NameEn ON core.Category (NameEn);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_PrintGroup_NameAr' AND object_id = OBJECT_ID(N'core.PrintGroup'))
BEGIN
    IF EXISTS (SELECT 1 FROM core.PrintGroup GROUP BY LTRIM(RTRIM(NameAr)) HAVING COUNT(*) > 1)
    BEGIN
        PRINT N'WARNING: duplicate print group Arabic names exist; UX_PrintGroup_NameAr not created. Rename these, then run 020 again:';
        SELECT PrintGroupId, NameAr, NameEn, IsActive FROM core.PrintGroup
        WHERE LTRIM(RTRIM(NameAr)) IN (SELECT LTRIM(RTRIM(NameAr)) FROM core.PrintGroup
                                       GROUP BY LTRIM(RTRIM(NameAr)) HAVING COUNT(*) > 1)
        ORDER BY NameAr, PrintGroupId;
    END
    ELSE
        CREATE UNIQUE INDEX UX_PrintGroup_NameAr ON core.PrintGroup (NameAr);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_PrintGroup_NameEn' AND object_id = OBJECT_ID(N'core.PrintGroup'))
BEGIN
    IF EXISTS (SELECT 1 FROM core.PrintGroup GROUP BY LTRIM(RTRIM(NameEn)) HAVING COUNT(*) > 1)
    BEGIN
        PRINT N'WARNING: duplicate print group English names exist; UX_PrintGroup_NameEn not created. Rename these, then run 020 again:';
        SELECT PrintGroupId, NameAr, NameEn, IsActive FROM core.PrintGroup
        WHERE LTRIM(RTRIM(NameEn)) IN (SELECT LTRIM(RTRIM(NameEn)) FROM core.PrintGroup
                                       GROUP BY LTRIM(RTRIM(NameEn)) HAVING COUNT(*) > 1)
        ORDER BY NameEn, PrintGroupId;
    END
    ELSE
        CREATE UNIQUE INDEX UX_PrintGroup_NameEn ON core.PrintGroup (NameEn);
END
GO
