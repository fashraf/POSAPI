/*==============================================================================
  Nazad POS — 29 · Categories and print groups

  Backs POST/PUT /api/catalog/categories and POST/PUT /api/catalog/print-groups.

  Schema: core.Category gains AppliesTo ('product', 'service' or 'both'). The
  catalog screen already asks which kinds of item a category holds; without a
  column the answer was lost on reload.

  Both save procedures refuse to switch a record off while active items still
  use it — the same guard core.usp_SetActive applies. Without it, saving the
  form with "inactive" ticked would walk straight past the rule the toggle
  enforces.

  Error numbers 65000–65049.
==============================================================================*/

USE POSMAIN;
GO

IF COL_LENGTH(N'core.Category', N'AppliesTo') IS NULL
    ALTER TABLE core.Category ADD AppliesTo NVARCHAR(10) NOT NULL
        CONSTRAINT DF_Category_AppliesTo DEFAULT (N'both')
        CONSTRAINT CK_Category_AppliesTo CHECK (AppliesTo IN (N'product', N'service', N'both'));
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

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 65000, N'Both names are required.', 1;

    IF @AppliesTo NOT IN (N'product', N'service', N'both')
        THROW 65001, N'A category holds products, services or both.', 1;

    IF @CategoryId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Category WHERE CategoryId = @CategoryId)
        THROW 65002, N'No such category.', 1;

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

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 65010, N'Both names are required.', 1;

    IF @PrintGroupId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.PrintGroup WHERE PrintGroupId = @PrintGroupId)
        THROW 65011, N'No such print group.', 1;

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

PRINT N'29 · Categories and print groups ready.';
GO

SELECT
    CASE WHEN COL_LENGTH(N'core.Category', N'AppliesTo') IS NULL
              THEN N'FAIL  core.Category.AppliesTo missing'
         WHEN OBJECT_ID(N'core.usp_SavePrintGroup') IS NULL
              THEN N'FAIL  procedures missing'
         ELSE N'PASS  Categories and print groups ready'
    END AS Result;
GO
