/*==============================================================================
  NAZAD POS — COMPLETE DATABASE MIGRATION
  Target: Microsoft SQL Server 2019+   ·   Database: POSMAIN

  HOW TO RUN
  ----------
    sqlcmd -S "VMI1342014\SQLEXPRESS" -E -i nazad-posmain-full.sql -o migrate.log

  or open in SSMS, connect with Windows Authentication, and Execute (F5).
  SQLCMD mode is not required. The script is idempotent at the database level
  (it will not drop an existing POSMAIN) but the CREATE TABLE statements will
  fail if the objects already exist — see 00-DROP-ALL.sql to start clean.

  WHAT IT BUILDS
  --------------
    Schemas   core · sales · inv · fin
    Tables    47
    Views     6
    Procs     5   (posting, reversal, commission, recognition, rebuild)
    Seed      chart of accounts, 50 permissions, 6 roles,
              2 branches, 6 users, 15 catalog items, 4 customers,
              7 discounts, 6 recurring payments,
              6 months of balanced trading history

  CONVENTIONS THAT MATTER
  -----------------------
    · Money is BIGINT halalas. 15.30 SAR is stored as 1530. Never float.
    · Every user-facing string is NVARCHAR. VARCHAR would mangle Arabic.
    · NameAr and NameEn are NOT NULL on every entity; further languages live
      in core.Translation and resolve through core.fn_Text.
    · BranchId NULL means "not branch-specific" and is visible everywhere.
    · The ledger balances by constraint, not by convention.

  The final batch verifies the ledger balances and throws if it does not.
==============================================================================*/

SET NOCOUNT ON;
GO

/*==============================================================================
  SECTION: 01-database.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 01 · Database and collation

  Run once, as a login with dbcreator rights.

  Collation: Arabic_CI_AS on the database. Every user-facing text column is
  NVARCHAR, never VARCHAR — VARCHAR under a Latin code page silently mangles
  Arabic into question marks, and the damage is invisible until someone reads
  the data back.
==============================================================================*/

USE master;
GO

IF DB_ID(N'POSMAIN') IS NULL
BEGIN
    CREATE DATABASE POSMAIN COLLATE Arabic_CI_AS;
END
GO

ALTER DATABASE POSMAIN SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO

/* Dates and money must not depend on the session's regional settings. */
ALTER DATABASE POSMAIN SET ANSI_NULLS ON;
ALTER DATABASE POSMAIN SET QUOTED_IDENTIFIER ON;
GO

USE POSMAIN;
GO

IF SCHEMA_ID(N'core')  IS NULL EXEC(N'CREATE SCHEMA core');
IF SCHEMA_ID(N'sales') IS NULL EXEC(N'CREATE SCHEMA sales');
IF SCHEMA_ID(N'inv')   IS NULL EXEC(N'CREATE SCHEMA inv');
IF SCHEMA_ID(N'fin')   IS NULL EXEC(N'CREATE SCHEMA fin');
GO

PRINT N'01 · Database ready.';
GO

/*==============================================================================
  SECTION: 02-localization.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 02 · Localization

  The approach, and why.

  Arabic and English are guaranteed: every product, category and branch must
  have both, and the app is unusable if one is missing. So they live as NOT NULL
  columns (NameAr, NameEn) on the entity itself. That means the constraint is
  enforced by the database, the POS product grid is a single-table read with no
  joins, and the existing frontend contract (nameAr / nameEn) needs no mapping.

  Any further language — Urdu, Tagalog, Hindi, all common in Saudi retail — is
  optional by nature, and adding one must not require a schema migration. Those
  live in core.Translation, an overflow table keyed by entity and field.

  Resolution order for a requested language: Translation → English → Arabic.
  Falling back to a readable string beats rendering a blank label.
==============================================================================*/

USE POSMAIN;
GO

CREATE TABLE core.Language
(
    Code            NVARCHAR(10)   NOT NULL CONSTRAINT PK_Language PRIMARY KEY,
    NameNative      NVARCHAR(60)   NOT NULL,
    NameEn          NVARCHAR(60)   NOT NULL,
    IsRtl           BIT            NOT NULL CONSTRAINT DF_Language_Rtl     DEFAULT (0),
    IsActive        BIT            NOT NULL CONSTRAINT DF_Language_Active  DEFAULT (1),
    SortOrder       INT            NOT NULL CONSTRAINT DF_Language_Sort    DEFAULT (100)
);
GO

INSERT INTO core.Language (Code, NameNative, NameEn, IsRtl, SortOrder) VALUES
    (N'ar', N'العربية',   N'Arabic',   1, 1),
    (N'en', N'English',   N'English',  0, 2),
    (N'ur', N'اردو',      N'Urdu',     1, 3),
    (N'hi', N'हिन्दी',      N'Hindi',    0, 4),
    (N'tl', N'Tagalog',   N'Tagalog',  0, 5),
    (N'bn', N'বাংলা',      N'Bengali',  0, 6);
GO

/*
  Overflow translations.

  EntityKey is NVARCHAR rather than a typed FK because it spans every entity in
  the system; a per-entity translation table would mean twenty near-identical
  tables. The trade is that referential integrity here is by convention, so
  core.usp_PurgeOrphanTranslations exists to sweep up.
*/
CREATE TABLE core.Translation
(
    TranslationId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Translation PRIMARY KEY,
    EntityType      NVARCHAR(60)   NOT NULL,
    EntityKey       NVARCHAR(60)   NOT NULL,
    FieldName       NVARCHAR(60)   NOT NULL,
    LanguageCode    NVARCHAR(10)   NOT NULL
        CONSTRAINT FK_Translation_Language REFERENCES core.Language (Code),
    Value           NVARCHAR(400)  NOT NULL,
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Translation_Updated DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT UQ_Translation UNIQUE (EntityType, EntityKey, FieldName, LanguageCode)
);
GO

CREATE INDEX IX_Translation_Lookup
    ON core.Translation (EntityType, EntityKey, LanguageCode)
    INCLUDE (FieldName, Value);
GO

/*
  Resolve one localised string.

  SCHEMABINDING and a deterministic body so the optimiser can inline it rather
  than calling row by row.
*/
CREATE FUNCTION core.fn_Text
(
    @EntityType   NVARCHAR(60),
    @EntityKey    NVARCHAR(60),
    @FieldName    NVARCHAR(60),
    @LanguageCode NVARCHAR(10),
    @ValueAr      NVARCHAR(400),
    @ValueEn      NVARCHAR(400)
)
RETURNS NVARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
    IF @LanguageCode = N'ar' RETURN @ValueAr;
    IF @LanguageCode = N'en' RETURN @ValueEn;

    RETURN COALESCE(
        (
            SELECT TOP (1) t.Value
            FROM core.Translation AS t
            WHERE t.EntityType   = @EntityType
              AND t.EntityKey    = @EntityKey
              AND t.FieldName    = @FieldName
              AND t.LanguageCode = @LanguageCode
        ),
        NULLIF(@ValueEn, N''),
        @ValueAr
    );
END
GO

PRINT N'02 · Localization ready.';
GO

/*==============================================================================
  SECTION: 03-core.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 03 · Core: company, branches, users, roles, permissions

  Conventions used throughout:
    · Ids are NVARCHAR(40) business keys ('brn_001'), matching the frontend and
      keeping API payloads readable. Clustered on a surrogate INT where row
      volume warrants it.
    · Money is BIGINT halalas. Never DECIMAL, never FLOAT. 15.30 SAR is 1530.
    · Every table carries CreatedAtUtc/CreatedBy and UpdatedAtUtc/UpdatedBy.
    · BranchId NULL means "not branch-specific" and is visible from every
      branch. This preserves records created before branches existed.
==============================================================================*/

USE POSMAIN;
GO

CREATE TABLE core.Company
(
    CompanyId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Company PRIMARY KEY,
    NameAr          NVARCHAR(160)  NOT NULL,
    NameEn          NVARCHAR(160)  NOT NULL,
    DescriptionAr   NVARCHAR(400)  NULL,
    DescriptionEn   NVARCHAR(400)  NULL,
    LogoUrl         NVARCHAR(400)  NULL,
    CrNumber        NVARCHAR(10)   NULL,
    VatNumber       NVARCHAR(15)   NULL,
    Phone           NVARCHAR(30)   NULL,
    Email           NVARCHAR(160)  NULL,
    Website         NVARCHAR(160)  NULL,
    Street          NVARCHAR(160)  NULL,
    District        NVARCHAR(120)  NULL,
    City            NVARCHAR(120)  NULL,
    PostalCode      NVARCHAR(12)   NULL,
    Country         NVARCHAR(80)   NULL CONSTRAINT DF_Company_Country DEFAULT (N'SA'),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Company_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Company_Updated DEFAULT (SYSUTCDATETIME()),

    /* ZATCA: 15 digits, starts and ends with 3. Enforced here because an
       invalid VAT number fails at invoice-clearance time, which is far too
       late to discover it. */
    CONSTRAINT CK_Company_Vat CHECK (VatNumber IS NULL OR
        (LEN(VatNumber) = 15 AND VatNumber NOT LIKE N'%[^0-9]%'
         AND LEFT(VatNumber,1) = N'3' AND RIGHT(VatNumber,1) = N'3')),
    CONSTRAINT CK_Company_Cr CHECK (CrNumber IS NULL OR
        (LEN(CrNumber) = 10 AND CrNumber NOT LIKE N'%[^0-9]%'))
);
GO

CREATE TABLE core.Branch
(
    BranchId        NVARCHAR(40)   NOT NULL CONSTRAINT PK_Branch PRIMARY KEY,
    Code            NVARCHAR(20)   NOT NULL CONSTRAINT UQ_Branch_Code UNIQUE,
    NameAr          NVARCHAR(160)  NOT NULL,
    NameEn          NVARCHAR(160)  NOT NULL,
    Phone           NVARCHAR(30)   NULL,
    AddressAr       NVARCHAR(300)  NULL,
    AddressEn       NVARCHAR(300)  NULL,
    IsActive        BIT            NOT NULL CONSTRAINT DF_Branch_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Branch_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Branch_Updated DEFAULT (SYSUTCDATETIME())
);
GO

CREATE TABLE core.Permission
(
    PermissionKey   NVARCHAR(60)   NOT NULL CONSTRAINT PK_Permission PRIMARY KEY,
    Module          NVARCHAR(40)   NOT NULL,
    Action          NVARCHAR(40)   NOT NULL,
    /* 'general' | 'financial' | 'personal' — external accounts are barred from
       the latter two. */
    Sensitivity     NVARCHAR(20)   NOT NULL CONSTRAINT DF_Permission_Sens DEFAULT (N'general'),
    CONSTRAINT CK_Permission_Sensitivity
        CHECK (Sensitivity IN (N'general', N'financial', N'personal'))
);
GO

CREATE TABLE core.Role
(
    RoleId          NVARCHAR(40)   NOT NULL CONSTRAINT PK_Role PRIMARY KEY,
    NameAr          NVARCHAR(120)  NOT NULL,
    NameEn          NVARCHAR(120)  NOT NULL,
    DescriptionAr   NVARCHAR(400)  NULL,
    DescriptionEn   NVARCHAR(400)  NULL,
    IsBuiltIn       BIT            NOT NULL CONSTRAINT DF_Role_BuiltIn DEFAULT (0),
    IsExternal      BIT            NOT NULL CONSTRAINT DF_Role_External DEFAULT (0),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Role_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Role_Updated DEFAULT (SYSUTCDATETIME())
);
GO

CREATE TABLE core.RolePermission
(
    RoleId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_RolePermission_Role REFERENCES core.Role (RoleId) ON DELETE CASCADE,
    PermissionKey   NVARCHAR(60)   NOT NULL
        CONSTRAINT FK_RolePermission_Permission REFERENCES core.Permission (PermissionKey),
    CONSTRAINT PK_RolePermission PRIMARY KEY (RoleId, PermissionKey)
);
GO

CREATE TABLE core.AppUser
(
    UserId          NVARCHAR(40)   NOT NULL CONSTRAINT PK_AppUser PRIMARY KEY,
    Username        NVARCHAR(60)   NOT NULL CONSTRAINT UQ_AppUser_Username UNIQUE,
    NameAr          NVARCHAR(160)  NOT NULL,
    NameEn          NVARCHAR(160)  NOT NULL,
    Email           NVARCHAR(160)  NULL,
    Phone           NVARCHAR(30)   NULL,
    RoleId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_AppUser_Role REFERENCES core.Role (RoleId),

    /* Storage for the hash only. The API layer owns hashing; the schema must
       never see a plaintext password. */
    PasswordHash    NVARCHAR(400)  NULL,
    PasswordSalt    NVARCHAR(200)  NULL,

    Status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_AppUser_Status DEFAULT (N'active'),
    IsExternal      BIT            NOT NULL CONSTRAINT DF_AppUser_External DEFAULT (0),
    AccessExpiresOn DATE           NULL,
    BaseSalaryH     BIGINT         NOT NULL CONSTRAINT DF_AppUser_Salary DEFAULT (0),
    LastLoginAtUtc  DATETIME2(3)   NULL,
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_AppUser_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy       NVARCHAR(120)  NULL,
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_AppUser_Updated DEFAULT (SYSUTCDATETIME()),
    UpdatedBy       NVARCHAR(120)  NULL,

    CONSTRAINT CK_AppUser_Status CHECK (Status IN (N'active', N'suspended', N'expired')),
    CONSTRAINT CK_AppUser_Salary CHECK (BaseSalaryH >= 0)
);
GO

CREATE TABLE core.UserBranch
(
    UserId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_UserBranch_User REFERENCES core.AppUser (UserId) ON DELETE CASCADE,
    BranchId        NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_UserBranch_Branch REFERENCES core.Branch (BranchId),
    CONSTRAINT PK_UserBranch PRIMARY KEY (UserId, BranchId)
);
GO

/*
  Per-user permission overrides.

  Three states, not two: inherited from the role, explicitly granted, or
  explicitly denied. Denial must beat a grant, so both are stored rather than
  flattening to a single list.
*/
CREATE TABLE core.UserPermissionOverride
(
    UserId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_UserOverride_User REFERENCES core.AppUser (UserId) ON DELETE CASCADE,
    PermissionKey   NVARCHAR(60)   NOT NULL
        CONSTRAINT FK_UserOverride_Permission REFERENCES core.Permission (PermissionKey),
    Effect          NVARCHAR(10)   NOT NULL,
    CONSTRAINT PK_UserOverride PRIMARY KEY (UserId, PermissionKey),
    CONSTRAINT CK_UserOverride_Effect CHECK (Effect IN (N'grant', N'deny'))
);
GO

CREATE TABLE core.BranchSettings
(
    BranchId            NVARCHAR(40) NOT NULL CONSTRAINT PK_BranchSettings PRIMARY KEY
        CONSTRAINT FK_BranchSettings_Branch REFERENCES core.Branch (BranchId) ON DELETE CASCADE,
    DefaultCustomerMode NVARCHAR(20) NOT NULL CONSTRAINT DF_BS_Mode     DEFAULT (N'walkin'),
    ServedByRequirement NVARCHAR(20) NOT NULL CONSTRAINT DF_BS_ServedBy DEFAULT (N'optional'),
    AllowNegativeStock  BIT          NOT NULL CONSTRAINT DF_BS_NegStock DEFAULT (0),
    DefaultBillId       NVARCHAR(40) NULL,
    AutoPrintCustomer   BIT          NOT NULL CONSTRAINT DF_BS_PrintCust DEFAULT (1),
    AutoPrintGroups     BIT          NOT NULL CONSTRAINT DF_BS_PrintGrp  DEFAULT (1),
    VatRatePercent      DECIMAL(5,2) NOT NULL CONSTRAINT DF_BS_Vat       DEFAULT (15.00),
    PricesIncludeVat    BIT          NOT NULL CONSTRAINT DF_BS_Incl      DEFAULT (1),
    UpdatedAtUtc        DATETIME2(3) NOT NULL CONSTRAINT DF_BS_Updated   DEFAULT (SYSUTCDATETIME()),
    UpdatedBy           NVARCHAR(120) NULL,

    CONSTRAINT CK_BS_Mode     CHECK (DefaultCustomerMode IN (N'walkin', N'customer')),
    CONSTRAINT CK_BS_ServedBy CHECK (ServedByRequirement IN (N'off', N'optional', N'required')),
    CONSTRAINT CK_BS_Vat      CHECK (VatRatePercent >= 0 AND VatRatePercent <= 100)
);
GO

PRINT N'03 · Core ready.';
GO

/*==============================================================================
  SECTION: 04-catalog.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 04 · Catalog: categories, print groups, vendors, items, customers
==============================================================================*/

USE POSMAIN;
GO

CREATE TABLE core.Category
(
    CategoryId      NVARCHAR(40)   NOT NULL CONSTRAINT PK_Category PRIMARY KEY,
    NameAr          NVARCHAR(120)  NOT NULL,
    NameEn          NVARCHAR(120)  NOT NULL,
    SortOrder       INT            NOT NULL CONSTRAINT DF_Category_Sort DEFAULT (100),
    IsActive        BIT            NOT NULL CONSTRAINT DF_Category_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Category_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Category_Updated DEFAULT (SYSUTCDATETIME())
);
GO

/*
  Print groups: where part of an order goes to be prepared or packed.

  Deliberately generic. A restaurant calls them Kitchen and Bar, a laundry calls
  them Washing and Ironing, a salon calls them Hair and Spa. Nothing in the
  model says "restaurant".
*/
CREATE TABLE core.PrintGroup
(
    PrintGroupId    NVARCHAR(40)   NOT NULL CONSTRAINT PK_PrintGroup PRIMARY KEY,
    NameAr          NVARCHAR(120)  NOT NULL,
    NameEn          NVARCHAR(120)  NOT NULL,
    TicketTitle     NVARCHAR(120)  NOT NULL,
    SortOrder       INT            NOT NULL CONSTRAINT DF_PrintGroup_Sort DEFAULT (100),
    IsActive        BIT            NOT NULL CONSTRAINT DF_PrintGroup_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_PrintGroup_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_PrintGroup_Updated DEFAULT (SYSUTCDATETIME())
);
GO

CREATE TABLE core.Vendor
(
    VendorId        NVARCHAR(40)   NOT NULL CONSTRAINT PK_Vendor PRIMARY KEY,
    NameAr          NVARCHAR(160)  NOT NULL,
    NameEn          NVARCHAR(160)  NOT NULL,
    ContactPerson   NVARCHAR(160)  NULL,
    Phone           NVARCHAR(30)   NULL,
    Email           NVARCHAR(160)  NULL,
    VatNumber       NVARCHAR(15)   NULL,
    PaymentTermDays INT            NOT NULL CONSTRAINT DF_Vendor_Terms DEFAULT (0),
    IsActive        BIT            NOT NULL CONSTRAINT DF_Vendor_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Vendor_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy       NVARCHAR(120)  NULL,
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Vendor_Updated DEFAULT (SYSUTCDATETIME()),
    UpdatedBy       NVARCHAR(120)  NULL,
    CONSTRAINT CK_Vendor_Terms CHECK (PaymentTermDays >= 0)
);
GO

CREATE TABLE core.CatalogItem
(
    ItemId          NVARCHAR(40)   NOT NULL CONSTRAINT PK_CatalogItem PRIMARY KEY,
    Kind            NVARCHAR(20)   NOT NULL,
    NameAr          NVARCHAR(200)  NOT NULL,
    NameEn          NVARCHAR(200)  NOT NULL,
    DescriptionAr   NVARCHAR(600)  NULL,
    DescriptionEn   NVARCHAR(600)  NULL,
    Sku             NVARCHAR(60)   NULL,
    Barcode         NVARCHAR(60)   NULL,
    CategoryId      NVARCHAR(40)   NULL
        CONSTRAINT FK_CatalogItem_Category REFERENCES core.Category (CategoryId),
    VendorId        NVARCHAR(40)   NULL
        CONSTRAINT FK_CatalogItem_Vendor REFERENCES core.Vendor (VendorId),
    PrintGroupId    NVARCHAR(40)   NULL
        CONSTRAINT FK_CatalogItem_PrintGroup REFERENCES core.PrintGroup (PrintGroupId),

    /* VAT-inclusive shelf price, in halalas. Saudi retail quotes gross. */
    PriceH          BIGINT         NOT NULL CONSTRAINT DF_CatalogItem_Price DEFAULT (0),
    /* Weighted average cost, recomputed on each receipt. */
    CostH           BIGINT         NOT NULL CONSTRAINT DF_CatalogItem_Cost  DEFAULT (0),

    TracksStock     BIT            NOT NULL CONSTRAINT DF_CatalogItem_Tracks DEFAULT (1),
    ReorderLevel    INT            NOT NULL CONSTRAINT DF_CatalogItem_Reorder DEFAULT (0),
    RequiresPreparation BIT        NOT NULL CONSTRAINT DF_CatalogItem_Prep DEFAULT (0),
    IsActive        BIT            NOT NULL CONSTRAINT DF_CatalogItem_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_CatalogItem_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy       NVARCHAR(120)  NULL,
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_CatalogItem_Updated DEFAULT (SYSUTCDATETIME()),
    UpdatedBy       NVARCHAR(120)  NULL,

    CONSTRAINT CK_CatalogItem_Kind  CHECK (Kind IN (N'product', N'service')),
    CONSTRAINT CK_CatalogItem_Price CHECK (PriceH >= 0),
    CONSTRAINT CK_CatalogItem_Cost  CHECK (CostH  >= 0),
    /* A service has nothing to count, so it must not claim to track stock. */
    CONSTRAINT CK_CatalogItem_ServiceStock
        CHECK (Kind = N'product' OR TracksStock = 0)
);
GO

CREATE UNIQUE INDEX UX_CatalogItem_Barcode
    ON core.CatalogItem (Barcode) WHERE Barcode IS NOT NULL;
CREATE UNIQUE INDEX UX_CatalogItem_Sku
    ON core.CatalogItem (Sku) WHERE Sku IS NOT NULL;
CREATE INDEX IX_CatalogItem_Search
    ON core.CatalogItem (IsActive, Kind) INCLUDE (NameAr, NameEn, PriceH, CategoryId);
GO

/*
  Stock is held per branch, not per item.

  A product exists once for the whole business, but its quantity is physical and
  therefore lives where the shelf is.
*/
CREATE TABLE inv.StockLevel
(
    ItemId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_StockLevel_Item REFERENCES core.CatalogItem (ItemId) ON DELETE CASCADE,
    BranchId        NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_StockLevel_Branch REFERENCES core.Branch (BranchId),
    Quantity        DECIMAL(18,3)  NOT NULL CONSTRAINT DF_StockLevel_Qty DEFAULT (0),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_StockLevel_Updated DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_StockLevel PRIMARY KEY (ItemId, BranchId)
);
GO

CREATE TABLE core.Customer
(
    CustomerId      NVARCHAR(40)   NOT NULL CONSTRAINT PK_Customer PRIMARY KEY,
    NameAr          NVARCHAR(160)  NOT NULL,
    NameEn          NVARCHAR(160)  NOT NULL,
    Phone           NVARCHAR(30)   NULL,
    Email           NVARCHAR(160)  NULL,
    VatNumber       NVARCHAR(15)   NULL,
    CustomerType    NVARCHAR(20)   NOT NULL CONSTRAINT DF_Customer_Type DEFAULT (N'individual'),
    CreditLimitH    BIGINT         NOT NULL CONSTRAINT DF_Customer_Limit DEFAULT (0),
    /* Denormalised running balance. Maintained by the sale and collection
       procedures so the POS does not aggregate a statement on every keystroke;
       fin.usp_RebuildCustomerBalances can reconcile it against the ledger. */
    BalanceH        BIGINT         NOT NULL CONSTRAINT DF_Customer_Balance DEFAULT (0),
    IsActive        BIT            NOT NULL CONSTRAINT DF_Customer_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Customer_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy       NVARCHAR(120)  NULL,
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Customer_Updated DEFAULT (SYSUTCDATETIME()),
    UpdatedBy       NVARCHAR(120)  NULL,

    CONSTRAINT CK_Customer_Type  CHECK (CustomerType IN (N'individual', N'business')),
    CONSTRAINT CK_Customer_Limit CHECK (CreditLimitH >= 0)
);
GO

CREATE INDEX IX_Customer_Phone ON core.Customer (Phone) WHERE Phone IS NOT NULL;
CREATE INDEX IX_Customer_Owing ON core.Customer (BalanceH) WHERE BalanceH > 0;
GO

/* Discounts -----------------------------------------------------------------*/

CREATE TABLE sales.Discount
(
    DiscountId      NVARCHAR(40)   NOT NULL CONSTRAINT PK_Discount PRIMARY KEY,
    NameAr          NVARCHAR(160)  NOT NULL,
    NameEn          NVARCHAR(160)  NOT NULL,
    DiscountType    NVARCHAR(20)   NOT NULL,
    /* Percentage stored as basis points of a percent: 10% is 1000. */
    Value           INT            NOT NULL,
    MaxDiscountH    BIGINT         NULL,
    MinSubtotalH    BIGINT         NOT NULL CONSTRAINT DF_Discount_MinSub DEFAULT (0),
    ApprovalAboveH  BIGINT         NULL,
    AppliesTo       NVARCHAR(20)   NOT NULL CONSTRAINT DF_Discount_Applies DEFAULT (N'all'),
    IsAutomatic     BIT            NOT NULL CONSTRAINT DF_Discount_Auto  DEFAULT (0),
    AllowStacking   BIT            NOT NULL CONSTRAINT DF_Discount_Stack DEFAULT (0),
    /* Comma-separated day numbers, 0=Sunday. Empty means every day. */
    ActiveDays      NVARCHAR(20)   NOT NULL CONSTRAINT DF_Discount_Days DEFAULT (N''),
    StartsOn        DATE           NULL,
    EndsOn          DATE           NULL,
    UsageCount      INT            NOT NULL CONSTRAINT DF_Discount_Usage DEFAULT (0),
    IsActive        BIT            NOT NULL CONSTRAINT DF_Discount_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Discount_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Discount_Updated DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_Discount_Type    CHECK (DiscountType IN (N'percentage', N'fixed')),
    CONSTRAINT CK_Discount_Applies CHECK (AppliesTo IN (N'all', N'products', N'services', N'category', N'item')),
    CONSTRAINT CK_Discount_Value   CHECK (Value > 0),
    CONSTRAINT CK_Discount_Percent CHECK (DiscountType <> N'percentage' OR Value <= 10000),
    CONSTRAINT CK_Discount_Dates   CHECK (EndsOn IS NULL OR StartsOn IS NULL OR EndsOn >= StartsOn)
);
GO

CREATE TABLE sales.DiscountScope
(
    DiscountId      NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_DiscountScope_Discount REFERENCES sales.Discount (DiscountId) ON DELETE CASCADE,
    ScopeType       NVARCHAR(20)   NOT NULL,
    ScopeKey        NVARCHAR(40)   NOT NULL,
    CONSTRAINT PK_DiscountScope PRIMARY KEY (DiscountId, ScopeType, ScopeKey),
    CONSTRAINT CK_DiscountScope_Type CHECK (ScopeType IN (N'category', N'item'))
);
GO

PRINT N'04 · Catalog ready.';
GO

/*==============================================================================
  SECTION: 05-sales.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 05 · Sales, payments, inventory movement, kitchen
==============================================================================*/

USE POSMAIN;
GO

CREATE TABLE sales.Sale
(
    SaleId          NVARCHAR(40)   NOT NULL CONSTRAINT PK_Sale PRIMARY KEY,
    InvoiceNumber   NVARCHAR(40)   NOT NULL CONSTRAINT UQ_Sale_Invoice UNIQUE,
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_Sale_Branch REFERENCES core.Branch (BranchId),
    CustomerId      NVARCHAR(40)   NULL
        CONSTRAINT FK_Sale_Customer REFERENCES core.Customer (CustomerId),
    /* Who performed the work. Drives commission. */
    ServedByUserId  NVARCHAR(40)   NULL
        CONSTRAINT FK_Sale_ServedBy REFERENCES core.AppUser (UserId),
    CashierName     NVARCHAR(160)  NOT NULL,

    SubtotalH       BIGINT         NOT NULL,
    DiscountH       BIGINT         NOT NULL CONSTRAINT DF_Sale_Discount DEFAULT (0),
    TaxH            BIGINT         NOT NULL,
    TotalH          BIGINT         NOT NULL,
    TenderedH       BIGINT         NULL,
    ChangeH         BIGINT         NOT NULL CONSTRAINT DF_Sale_Change DEFAULT (0),
    DiscountId      NVARCHAR(40)   NULL
        CONSTRAINT FK_Sale_Discount_Ref REFERENCES sales.Discount (DiscountId),

    Status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_Sale_Status DEFAULT (N'completed'),
    SoldAtUtc       DATETIME2(3)   NOT NULL CONSTRAINT DF_Sale_SoldAt DEFAULT (SYSUTCDATETIME()),

    /* ZATCA Phase 2 fields. Populated by the API when it signs the invoice;
       the hash chain is what makes the sequence tamper-evident. */
    ZatcaUuid           UNIQUEIDENTIFIER NULL,
    ZatcaCounter        BIGINT           NULL,
    ZatcaInvoiceHash    NVARCHAR(200)    NULL,
    ZatcaPreviousHash   NVARCHAR(200)    NULL,
    ZatcaQrPayload      NVARCHAR(1000)   NULL,

    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Sale_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy       NVARCHAR(120)  NULL,
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Sale_Updated DEFAULT (SYSUTCDATETIME()),
    UpdatedBy       NVARCHAR(120)  NULL,

    CONSTRAINT CK_Sale_Status CHECK (Status IN (N'completed', N'partially_returned', N'returned', N'voided')),
    CONSTRAINT CK_Sale_Totals CHECK (TotalH = SubtotalH - DiscountH + TaxH),
    CONSTRAINT CK_Sale_NonNegative CHECK (SubtotalH >= 0 AND DiscountH >= 0 AND TaxH >= 0 AND TotalH >= 0)
);
GO

CREATE INDEX IX_Sale_Branch_Date ON sales.Sale (BranchId, SoldAtUtc DESC) INCLUDE (TotalH, Status);
CREATE INDEX IX_Sale_Customer    ON sales.Sale (CustomerId, SoldAtUtc DESC) WHERE CustomerId IS NOT NULL;
CREATE UNIQUE INDEX UX_Sale_ZatcaCounter ON sales.Sale (ZatcaCounter) WHERE ZatcaCounter IS NOT NULL;
GO

CREATE TABLE sales.SaleLine
(
    SaleLineId      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SaleLine PRIMARY KEY,
    SaleId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_SaleLine_Sale REFERENCES sales.Sale (SaleId) ON DELETE CASCADE,
    ItemId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_SaleLine_Item REFERENCES core.CatalogItem (ItemId),

    /* Names copied at the time of sale. An invoice must still read correctly
       after the product is renamed or deleted. */
    NameAr          NVARCHAR(200)  NOT NULL,
    NameEn          NVARCHAR(200)  NOT NULL,
    Kind            NVARCHAR(20)   NOT NULL,
    PrintGroupId    NVARCHAR(40)   NULL,

    Quantity        DECIMAL(18,3)  NOT NULL,
    UnitPriceH      BIGINT         NOT NULL,
    UnitCostH       BIGINT         NOT NULL CONSTRAINT DF_SaleLine_Cost DEFAULT (0),
    LineDiscountH   BIGINT         NOT NULL CONSTRAINT DF_SaleLine_Discount DEFAULT (0),
    ReturnedQty     DECIMAL(18,3)  NOT NULL CONSTRAINT DF_SaleLine_Returned DEFAULT (0),
    Note            NVARCHAR(400)  NULL,

    CONSTRAINT CK_SaleLine_Qty      CHECK (Quantity > 0),
    CONSTRAINT CK_SaleLine_Returned CHECK (ReturnedQty >= 0 AND ReturnedQty <= Quantity),
    CONSTRAINT CK_SaleLine_Money    CHECK (UnitPriceH >= 0 AND UnitCostH >= 0 AND LineDiscountH >= 0)
);
GO

CREATE INDEX IX_SaleLine_Sale ON sales.SaleLine (SaleId);
CREATE INDEX IX_SaleLine_Item ON sales.SaleLine (ItemId);
GO

CREATE TABLE sales.SalePayment
(
    SalePaymentId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalePayment PRIMARY KEY,
    SaleId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_SalePayment_Sale REFERENCES sales.Sale (SaleId) ON DELETE CASCADE,
    Method          NVARCHAR(20)   NOT NULL,
    AmountH         BIGINT         NOT NULL,
    Reference       NVARCHAR(80)   NULL,
    CONSTRAINT CK_SalePayment_Method CHECK (Method IN (N'cash', N'card', N'credit', N'bank')),
    CONSTRAINT CK_SalePayment_Amount CHECK (AmountH > 0)
);
GO

CREATE TABLE sales.SaleReturn
(
    ReturnId        NVARCHAR(40)   NOT NULL CONSTRAINT PK_SaleReturn PRIMARY KEY,
    SaleId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_SaleReturn_Sale REFERENCES sales.Sale (SaleId),
    ReasonAr        NVARCHAR(400)  NULL,
    ReasonEn        NVARCHAR(400)  NULL,
    RefundH         BIGINT         NOT NULL,
    ReturnedAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_SaleReturn_At DEFAULT (SYSUTCDATETIME()),
    ReturnedBy      NVARCHAR(120)  NOT NULL,
    CONSTRAINT CK_SaleReturn_Refund CHECK (RefundH >= 0)
);
GO

CREATE TABLE sales.SaleReturnLine
(
    ReturnLineId    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SaleReturnLine PRIMARY KEY,
    ReturnId        NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_SaleReturnLine_Return REFERENCES sales.SaleReturn (ReturnId) ON DELETE CASCADE,
    SaleLineId      BIGINT         NOT NULL
        CONSTRAINT FK_SaleReturnLine_Line REFERENCES sales.SaleLine (SaleLineId),
    Quantity        DECIMAL(18,3)  NOT NULL,
    CONSTRAINT CK_SaleReturnLine_Qty CHECK (Quantity > 0)
);
GO

/* Inventory ledger ----------------------------------------------------------*/

CREATE TABLE inv.StockMovement
(
    MovementId      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockMovement PRIMARY KEY,
    ItemId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_StockMovement_Item REFERENCES core.CatalogItem (ItemId),
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_StockMovement_Branch REFERENCES core.Branch (BranchId),
    MovementType    NVARCHAR(30)   NOT NULL,
    /* Signed: negative for a sale, positive for a receipt. */
    Quantity        DECIMAL(18,3)  NOT NULL,
    BalanceAfter    DECIMAL(18,3)  NOT NULL,
    UnitCostH       BIGINT         NOT NULL CONSTRAINT DF_StockMovement_Cost DEFAULT (0),
    Reference       NVARCHAR(80)   NULL,
    ReasonAr        NVARCHAR(400)  NULL,
    ReasonEn        NVARCHAR(400)  NULL,
    OccurredAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_StockMovement_At DEFAULT (SYSUTCDATETIME()),
    Actor           NVARCHAR(120)  NOT NULL CONSTRAINT DF_StockMovement_Actor DEFAULT (N'System'),

    CONSTRAINT CK_StockMovement_Type CHECK (MovementType IN
        (N'purchase', N'sale', N'return', N'adjustment', N'stocktake', N'opening', N'transfer')),
    CONSTRAINT CK_StockMovement_Qty CHECK (Quantity <> 0)
);
GO

CREATE INDEX IX_StockMovement_Item ON inv.StockMovement (ItemId, OccurredAtUtc DESC);
CREATE INDEX IX_StockMovement_Branch ON inv.StockMovement (BranchId, OccurredAtUtc DESC);
GO

CREATE TABLE inv.Purchase
(
    PurchaseId      NVARCHAR(40)   NOT NULL CONSTRAINT PK_Purchase PRIMARY KEY,
    Reference       NVARCHAR(40)   NOT NULL CONSTRAINT UQ_Purchase_Ref UNIQUE,
    VendorId        NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_Purchase_Vendor REFERENCES core.Vendor (VendorId),
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_Purchase_Branch REFERENCES core.Branch (BranchId),
    InvoiceNumber   NVARCHAR(60)   NULL,
    SubtotalH       BIGINT         NOT NULL,
    TaxH            BIGINT         NOT NULL,
    TotalH          BIGINT         NOT NULL,
    PaidOnReceipt   BIT            NOT NULL CONSTRAINT DF_Purchase_Paid DEFAULT (0),
    ReceivedAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_Purchase_At DEFAULT (SYSUTCDATETIME()),
    ReceivedBy      NVARCHAR(120)  NOT NULL,
    /* Purchase VAT is added to the net supplier price — the opposite direction
       to a retail sale, where VAT is extracted from the gross. */
    CONSTRAINT CK_Purchase_Totals CHECK (TotalH = SubtotalH + TaxH)
);
GO

CREATE TABLE inv.PurchaseLine
(
    PurchaseLineId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseLine PRIMARY KEY,
    PurchaseId      NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_PurchaseLine_Purchase REFERENCES inv.Purchase (PurchaseId) ON DELETE CASCADE,
    ItemId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_PurchaseLine_Item REFERENCES core.CatalogItem (ItemId),
    Quantity        DECIMAL(18,3)  NOT NULL,
    UnitCostH       BIGINT         NOT NULL,
    CONSTRAINT CK_PurchaseLine_Qty  CHECK (Quantity > 0),
    CONSTRAINT CK_PurchaseLine_Cost CHECK (UnitCostH >= 0)
);
GO

/* Kitchen / preparation board -----------------------------------------------*/

CREATE TABLE sales.PreparationOrder
(
    PreparationId   NVARCHAR(40)   NOT NULL CONSTRAINT PK_PreparationOrder PRIMARY KEY,
    OrderNumber     NVARCHAR(40)   NOT NULL,
    SaleId          NVARCHAR(40)   NULL
        CONSTRAINT FK_Preparation_Sale REFERENCES sales.Sale (SaleId),
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_Preparation_Branch REFERENCES core.Branch (BranchId),
    PrintGroupId    NVARCHAR(40)   NULL
        CONSTRAINT FK_Preparation_Group REFERENCES core.PrintGroup (PrintGroupId),
    CustomerName    NVARCHAR(160)  NULL,
    TotalH          BIGINT         NOT NULL CONSTRAINT DF_Preparation_Total DEFAULT (0),
    Status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_Preparation_Status DEFAULT (N'open'),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Preparation_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Preparation_Updated DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_Preparation_Status CHECK (Status IN (N'open', N'preparing', N'ready', N'completed'))
);
GO

CREATE TABLE sales.PreparationItem
(
    PreparationItemId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PreparationItem PRIMARY KEY,
    PreparationId   NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_PreparationItem_Order REFERENCES sales.PreparationOrder (PreparationId) ON DELETE CASCADE,
    ItemId          NVARCHAR(40)   NULL
        CONSTRAINT FK_PreparationItem_Item REFERENCES core.CatalogItem (ItemId),
    NameAr          NVARCHAR(200)  NOT NULL,
    NameEn          NVARCHAR(200)  NOT NULL,
    Quantity        DECIMAL(18,3)  NOT NULL,
    CompletedQty    DECIMAL(18,3)  NOT NULL CONSTRAINT DF_PreparationItem_Done DEFAULT (0),
    Note            NVARCHAR(400)  NULL,
    CONSTRAINT CK_PreparationItem_Qty  CHECK (Quantity > 0),
    CONSTRAINT CK_PreparationItem_Done CHECK (CompletedQty >= 0 AND CompletedQty <= Quantity)
);
GO

PRINT N'05 · Sales ready.';
GO

/*==============================================================================
  SECTION: 06-finance.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 06 · Finance: ledger, expenses, payroll, commission, balances

  The ledger is the spine. Every financial event lands here as a balanced entry,
  and the balance rule is enforced by the database rather than trusted to the
  API — an unbalanced entry that reaches storage is a defect nobody finds until
  a reconciliation months later.
==============================================================================*/

USE POSMAIN;
GO

CREATE TABLE fin.Account
(
    AccountCode     NVARCHAR(10)   NOT NULL CONSTRAINT PK_Account PRIMARY KEY,
    AccountType     NVARCHAR(20)   NOT NULL,
    NameAr          NVARCHAR(160)  NOT NULL,
    NameEn          NVARCHAR(160)  NOT NULL,
    IsActive        BIT            NOT NULL CONSTRAINT DF_Account_Active DEFAULT (1),
    CONSTRAINT CK_Account_Type CHECK (AccountType IN
        (N'asset', N'liability', N'equity', N'revenue', N'expense'))
);
GO

CREATE TABLE fin.JournalEntry
(
    EntryId         NVARCHAR(40)   NOT NULL CONSTRAINT PK_JournalEntry PRIMARY KEY,
    Reference       NVARCHAR(40)   NOT NULL CONSTRAINT UQ_JournalEntry_Ref UNIQUE,
    Kind            NVARCHAR(40)   NOT NULL,
    SourceReference NVARCHAR(80)   NULL,
    DescriptionAr   NVARCHAR(400)  NULL,
    DescriptionEn   NVARCHAR(400)  NOT NULL,
    PostedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_JournalEntry_At DEFAULT (SYSUTCDATETIME()),
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_JournalEntry_Branch REFERENCES core.Branch (BranchId),
    Actor           NVARCHAR(120)  NOT NULL,

    /* Corrections are made by posting the opposite entry, never by editing or
       deleting. An audit trail with a hole in it is not an audit trail. */
    ReversesEntryId   NVARCHAR(40) NULL
        CONSTRAINT FK_JournalEntry_Reverses REFERENCES fin.JournalEntry (EntryId),
    ReversedByEntryId NVARCHAR(40) NULL,
    ReversalReason    NVARCHAR(400) NULL,

    TotalDebitH     BIGINT         NOT NULL,
    TotalCreditH    BIGINT         NOT NULL,
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_JournalEntry_Created DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_JournalEntry_Balanced CHECK (TotalDebitH = TotalCreditH),
    CONSTRAINT CK_JournalEntry_Positive CHECK (TotalDebitH > 0),
    CONSTRAINT CK_JournalEntry_Kind CHECK (Kind IN
        (N'sale', N'return', N'void', N'expense', N'expense_recognition',
         N'customer_collection', N'supplier_payment', N'purchase',
         N'card_settlement', N'stock_adjustment', N'owner_contribution',
         N'owner_withdrawal', N'payroll', N'commission', N'opening_balance', N'manual'))
);
GO

CREATE INDEX IX_JournalEntry_Posted ON fin.JournalEntry (PostedAtUtc DESC) INCLUDE (Kind, BranchId);
CREATE INDEX IX_JournalEntry_Branch ON fin.JournalEntry (BranchId, PostedAtUtc DESC);
CREATE INDEX IX_JournalEntry_Source ON fin.JournalEntry (SourceReference) WHERE SourceReference IS NOT NULL;
GO

CREATE TABLE fin.JournalLine
(
    JournalLineId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JournalLine PRIMARY KEY,
    EntryId         NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_JournalLine_Entry REFERENCES fin.JournalEntry (EntryId) ON DELETE CASCADE,
    AccountCode     NVARCHAR(10)   NOT NULL
        CONSTRAINT FK_JournalLine_Account REFERENCES fin.Account (AccountCode),
    DebitH          BIGINT         NOT NULL CONSTRAINT DF_JournalLine_Debit  DEFAULT (0),
    CreditH         BIGINT         NOT NULL CONSTRAINT DF_JournalLine_Credit DEFAULT (0),
    Memo            NVARCHAR(400)  NULL,

    /* A line is a debit or a credit, never both and never neither. Two
       nullable columns would let a silently-zero line balance by accident. */
    CONSTRAINT CK_JournalLine_OneSided CHECK
        ((DebitH > 0 AND CreditH = 0) OR (CreditH > 0 AND DebitH = 0)),
    CONSTRAINT CK_JournalLine_NonNegative CHECK (DebitH >= 0 AND CreditH >= 0)
);
GO

CREATE INDEX IX_JournalLine_Entry   ON fin.JournalLine (EntryId);
CREATE INDEX IX_JournalLine_Account ON fin.JournalLine (AccountCode) INCLUDE (DebitH, CreditH);
GO

/* Expenses ------------------------------------------------------------------*/

CREATE TABLE fin.ExpenseCategory
(
    CategoryId      NVARCHAR(40)   NOT NULL CONSTRAINT PK_ExpenseCategory PRIMARY KEY,
    NameAr          NVARCHAR(120)  NOT NULL,
    NameEn          NVARCHAR(120)  NOT NULL,
    AccountCode     NVARCHAR(10)   NOT NULL
        CONSTRAINT FK_ExpenseCategory_Account REFERENCES fin.Account (AccountCode),
    IsActive        BIT            NOT NULL CONSTRAINT DF_ExpenseCategory_Active DEFAULT (1)
);
GO

CREATE TABLE fin.Expense
(
    ExpenseId       NVARCHAR(40)   NOT NULL CONSTRAINT PK_Expense PRIMARY KEY,
    Reference       NVARCHAR(40)   NOT NULL CONSTRAINT UQ_Expense_Ref UNIQUE,
    CategoryId      NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_Expense_Category REFERENCES fin.ExpenseCategory (CategoryId),
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_Expense_Branch REFERENCES core.Branch (BranchId),
    DescriptionAr   NVARCHAR(400)  NULL,
    DescriptionEn   NVARCHAR(400)  NULL,
    AmountH         BIGINT         NOT NULL,
    VatH            BIGINT         NOT NULL CONSTRAINT DF_Expense_Vat DEFAULT (0),
    PaymentMethod   NVARCHAR(20)   NOT NULL,

    /* When the money left. Drives the cash report. */
    PaidOn          DATE           NOT NULL,
    /* The months the cost belongs to. Drives the profit report. These are
       different questions and mixing them makes monthly profit meaningless. */
    Recognition     NVARCHAR(20)   NOT NULL CONSTRAINT DF_Expense_Recognition DEFAULT (N'one_time'),
    PeriodStart     DATE           NOT NULL,
    PeriodEnd       DATE           NOT NULL,

    ExternalRef     NVARCHAR(80)   NULL,
    AttachmentName  NVARCHAR(300)  NULL,
    AttachmentUrl   NVARCHAR(600)  NULL,
    Status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_Expense_Status DEFAULT (N'posted'),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Expense_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy       NVARCHAR(120)  NOT NULL,
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Expense_Updated DEFAULT (SYSUTCDATETIME()),
    UpdatedBy       NVARCHAR(120)  NULL,

    CONSTRAINT CK_Expense_Amount      CHECK (AmountH > 0),
    CONSTRAINT CK_Expense_Vat         CHECK (VatH >= 0 AND VatH <= AmountH),
    CONSTRAINT CK_Expense_Method      CHECK (PaymentMethod IN (N'cash', N'card', N'bank', N'credit')),
    CONSTRAINT CK_Expense_Recognition CHECK (Recognition IN (N'one_time', N'monthly', N'yearly', N'custom')),
    CONSTRAINT CK_Expense_Status      CHECK (Status IN (N'posted', N'reversed')),
    CONSTRAINT CK_Expense_Period      CHECK (PeriodEnd >= PeriodStart)
);
GO

CREATE INDEX IX_Expense_PaidOn ON fin.Expense (PaidOn DESC) INCLUDE (AmountH, CategoryId);
GO

/* Each month's share. Slices always sum back to the amount recognised. */
CREATE TABLE fin.ExpenseRecognition
(
    RecognitionId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ExpenseRecognition PRIMARY KEY,
    ExpenseId       NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_ExpenseRecognition_Expense REFERENCES fin.Expense (ExpenseId) ON DELETE CASCADE,
    PeriodMonth     CHAR(7)        NOT NULL,   -- 'YYYY-MM'
    AmountH         BIGINT         NOT NULL,
    CONSTRAINT UQ_ExpenseRecognition UNIQUE (ExpenseId, PeriodMonth),
    CONSTRAINT CK_ExpenseRecognition_Amount CHECK (AmountH >= 0)
);
GO

CREATE TABLE fin.RecurringPayment
(
    RecurringId     NVARCHAR(40)   NOT NULL CONSTRAINT PK_RecurringPayment PRIMARY KEY,
    DescriptionAr   NVARCHAR(300)  NOT NULL,
    DescriptionEn   NVARCHAR(300)  NOT NULL,
    CategoryId      NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_Recurring_Category REFERENCES fin.ExpenseCategory (CategoryId),
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_Recurring_Branch REFERENCES core.Branch (BranchId),
    AmountH         BIGINT         NOT NULL,
    Frequency       NVARCHAR(20)   NOT NULL,
    NextDueOn       DATE           NOT NULL,
    LastPaidOn      DATE           NULL,
    PaymentMethod   NVARCHAR(20)   NOT NULL CONSTRAINT DF_Recurring_Method DEFAULT (N'bank'),
    Status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_Recurring_Status DEFAULT (N'active'),
    Note            NVARCHAR(400)  NULL,
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Recurring_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Recurring_Updated DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_Recurring_Amount    CHECK (AmountH > 0),
    CONSTRAINT CK_Recurring_Frequency CHECK (Frequency IN (N'daily', N'weekly', N'monthly', N'quarterly', N'yearly')),
    CONSTRAINT CK_Recurring_Status    CHECK (Status IN (N'active', N'paused'))
);
GO

/* Cash, settlement, balance periods -----------------------------------------*/

CREATE TABLE fin.DrawerSession
(
    SessionId       NVARCHAR(40)   NOT NULL CONSTRAINT PK_DrawerSession PRIMARY KEY,
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_DrawerSession_Branch REFERENCES core.Branch (BranchId),
    OpenedAtUtc     DATETIME2(3)   NOT NULL,
    ClosedAtUtc     DATETIME2(3)   NULL,
    OpeningCashH    BIGINT         NOT NULL,
    CountedCashH    BIGINT         NULL,
    ExpectedCashH   BIGINT         NULL,
    VarianceH       BIGINT         NULL,
    OpenedBy        NVARCHAR(120)  NOT NULL,
    ClosedBy        NVARCHAR(120)  NULL,
    Note            NVARCHAR(400)  NULL,
    CONSTRAINT CK_DrawerSession_Opening CHECK (OpeningCashH >= 0),
    CONSTRAINT CK_DrawerSession_Counted CHECK (CountedCashH IS NULL OR CountedCashH >= 0)
);
GO

/* Only one drawer open per branch — two would each claim the same movements. */
CREATE UNIQUE INDEX UX_DrawerSession_OpenPerBranch
    ON fin.DrawerSession (BranchId) WHERE ClosedAtUtc IS NULL;
GO

CREATE TABLE fin.CardSettlement
(
    SettlementId    NVARCHAR(40)   NOT NULL CONSTRAINT PK_CardSettlement PRIMARY KEY,
    Reference       NVARCHAR(40)   NOT NULL CONSTRAINT UQ_CardSettlement_Ref UNIQUE,
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_CardSettlement_Branch REFERENCES core.Branch (BranchId),
    CardSalesH      BIGINT         NOT NULL,
    DepositH        BIGINT         NOT NULL,
    FeeH            BIGINT         NOT NULL,
    SettledOn       DATE           NOT NULL,
    Status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_CardSettlement_Status DEFAULT (N'reconciled'),
    Note            NVARCHAR(400)  NULL,
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_CardSettlement_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy       NVARCHAR(120)  NOT NULL,

    /* The fee is defined as the gap, so it cannot be typed independently. */
    CONSTRAINT CK_CardSettlement_Fee    CHECK (FeeH = CardSalesH - DepositH),
    CONSTRAINT CK_CardSettlement_Amount CHECK (CardSalesH > 0 AND DepositH >= 0 AND DepositH <= CardSalesH)
);
GO

CREATE TABLE fin.BalancePeriod
(
    PeriodId        NVARCHAR(40)   NOT NULL CONSTRAINT PK_BalancePeriod PRIMARY KEY,
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_BalancePeriod_Branch REFERENCES core.Branch (BranchId),
    Label           NVARCHAR(160)  NOT NULL,
    OpenedOn        DATE           NOT NULL,
    ClosedOn        DATE           NULL,

    OpeningCashH        BIGINT NOT NULL CONSTRAINT DF_BP_OCash  DEFAULT (0),
    OpeningCardH        BIGINT NOT NULL CONSTRAINT DF_BP_OCard  DEFAULT (0),
    OpeningCreditH      BIGINT NOT NULL CONSTRAINT DF_BP_OCred  DEFAULT (0),
    OpeningBankH        BIGINT NOT NULL CONSTRAINT DF_BP_OBank  DEFAULT (0),
    OpeningInventoryH   BIGINT NOT NULL CONSTRAINT DF_BP_OInv   DEFAULT (0),
    OpeningPayablesH    BIGINT NOT NULL CONSTRAINT DF_BP_OPay   DEFAULT (0),

    ClosingCashH        BIGINT NULL,
    ClosingCardH        BIGINT NULL,
    ClosingCreditH      BIGINT NULL,
    ClosingBankH        BIGINT NULL,
    ClosingInventoryH   BIGINT NULL,
    ClosingPayablesH    BIGINT NULL,

    Status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_BalancePeriod_Status DEFAULT (N'open'),
    OpenedBy        NVARCHAR(120)  NOT NULL,
    ClosedBy        NVARCHAR(120)  NULL,
    Note            NVARCHAR(400)  NULL,
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_BalancePeriod_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_BalancePeriod_Updated DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_BalancePeriod_Status CHECK (Status IN (N'open', N'closed')),
    CONSTRAINT CK_BalancePeriod_Dates  CHECK (ClosedOn IS NULL OR ClosedOn >= OpenedOn)
);
GO

CREATE UNIQUE INDEX UX_BalancePeriod_OpenPerBranch
    ON fin.BalancePeriod (BranchId) WHERE Status = N'open';
GO

/* Commission and payroll ----------------------------------------------------*/

CREATE TABLE fin.CommissionRule
(
    RuleId          NVARCHAR(40)   NOT NULL CONSTRAINT PK_CommissionRule PRIMARY KEY,
    Basis           NVARCHAR(20)   NOT NULL,
    /* Basis points of a percent (2000 = 20%), or halalas for a fixed rule. */
    Value           INT            NOT NULL,
    IsActive        BIT            NOT NULL CONSTRAINT DF_CommissionRule_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_CommissionRule_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_CommissionRule_Updated DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_CommissionRule_Basis CHECK (Basis IN (N'percentage', N'fixed')),
    CONSTRAINT CK_CommissionRule_Value CHECK (Value > 0),
    CONSTRAINT CK_CommissionRule_Pct   CHECK (Basis <> N'percentage' OR Value <= 10000)
);
GO

/* Empty sets mean "everyone" and "every service" respectively. */
CREATE TABLE fin.CommissionRuleUser
(
    RuleId  NVARCHAR(40) NOT NULL
        CONSTRAINT FK_CRU_Rule REFERENCES fin.CommissionRule (RuleId) ON DELETE CASCADE,
    UserId  NVARCHAR(40) NOT NULL
        CONSTRAINT FK_CRU_User REFERENCES core.AppUser (UserId) ON DELETE CASCADE,
    CONSTRAINT PK_CommissionRuleUser PRIMARY KEY (RuleId, UserId)
);
GO

CREATE TABLE fin.CommissionRuleItem
(
    RuleId  NVARCHAR(40) NOT NULL
        CONSTRAINT FK_CRI_Rule REFERENCES fin.CommissionRule (RuleId) ON DELETE CASCADE,
    ItemId  NVARCHAR(40) NOT NULL
        CONSTRAINT FK_CRI_Item REFERENCES core.CatalogItem (ItemId) ON DELETE CASCADE,
    CONSTRAINT PK_CommissionRuleItem PRIMARY KEY (RuleId, ItemId)
);
GO

CREATE TABLE fin.PayrollRun
(
    RunId           NVARCHAR(40)   NOT NULL CONSTRAINT PK_PayrollRun PRIMARY KEY,
    Reference       NVARCHAR(40)   NOT NULL CONSTRAINT UQ_PayrollRun_Ref UNIQUE,
    PeriodMonth     CHAR(7)        NOT NULL,
    BranchId        NVARCHAR(40)   NULL
        CONSTRAINT FK_PayrollRun_Branch REFERENCES core.Branch (BranchId),
    Status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_PayrollRun_Status DEFAULT (N'draft'),
    TotalH          BIGINT         NOT NULL CONSTRAINT DF_PayrollRun_Total DEFAULT (0),
    PaidOn          DATE           NULL,
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_PayrollRun_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy       NVARCHAR(120)  NOT NULL,
    UpdatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_PayrollRun_Updated DEFAULT (SYSUTCDATETIME()),
    UpdatedBy       NVARCHAR(120)  NULL,
    CONSTRAINT CK_PayrollRun_Status CHECK (Status IN (N'draft', N'approved', N'paid')),
    CONSTRAINT UQ_PayrollRun_Period UNIQUE (PeriodMonth, BranchId)
);
GO

CREATE TABLE fin.PayrollLine
(
    PayrollLineId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayrollLine PRIMARY KEY,
    RunId           NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_PayrollLine_Run REFERENCES fin.PayrollRun (RunId) ON DELETE CASCADE,
    UserId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_PayrollLine_User REFERENCES core.AppUser (UserId),
    BaseSalaryH     BIGINT         NOT NULL CONSTRAINT DF_PayrollLine_Base DEFAULT (0),
    CommissionH     BIGINT         NOT NULL CONSTRAINT DF_PayrollLine_Comm DEFAULT (0),
    AllowancesH     BIGINT         NOT NULL CONSTRAINT DF_PayrollLine_Allow DEFAULT (0),
    DeductionsH     BIGINT         NOT NULL CONSTRAINT DF_PayrollLine_Ded  DEFAULT (0),
    NetPayH         AS (BaseSalaryH + CommissionH + AllowancesH - DeductionsH) PERSISTED,
    CONSTRAINT UQ_PayrollLine UNIQUE (RunId, UserId),
    CONSTRAINT CK_PayrollLine_NonNegative CHECK
        (BaseSalaryH >= 0 AND CommissionH >= 0 AND AllowancesH >= 0 AND DeductionsH >= 0)
);
GO

/*
  Commission earned, frozen at the moment of sale.

  AmountH and RateAtSale are written once and never recomputed. If the rule
  changes next month, this row still says what was earned — recalculating
  history from current rules would silently rewrite what people are owed.
*/
CREATE TABLE fin.CommissionEntry
(
    CommissionId    NVARCHAR(40)   NOT NULL CONSTRAINT PK_CommissionEntry PRIMARY KEY,
    SaleId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_CommissionEntry_Sale REFERENCES sales.Sale (SaleId),
    InvoiceNumber   NVARCHAR(40)   NOT NULL,
    UserId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_CommissionEntry_User REFERENCES core.AppUser (UserId),
    ItemId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_CommissionEntry_Item REFERENCES core.CatalogItem (ItemId),
    ItemNameAr      NVARCHAR(200)  NOT NULL,
    ItemNameEn      NVARCHAR(200)  NOT NULL,
    LineGrossH      BIGINT         NOT NULL,
    AmountH         BIGINT         NOT NULL,
    Basis           NVARCHAR(20)   NOT NULL,
    RateAtSale      INT            NOT NULL,
    BranchId        NVARCHAR(40)   NULL,
    EarnedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_CommissionEntry_At DEFAULT (SYSUTCDATETIME()),
    PayrollRunId    NVARCHAR(40)   NULL
        CONSTRAINT FK_CommissionEntry_Run REFERENCES fin.PayrollRun (RunId),
    CONSTRAINT CK_CommissionEntry_Amount CHECK (AmountH >= 0)
);
GO

CREATE INDEX IX_CommissionEntry_User
    ON fin.CommissionEntry (UserId, EarnedAtUtc DESC) INCLUDE (AmountH, PayrollRunId);
CREATE INDEX IX_CommissionEntry_Unpaid
    ON fin.CommissionEntry (UserId) INCLUDE (AmountH) WHERE PayrollRunId IS NULL;
GO

/* Bill templates ------------------------------------------------------------*/

CREATE TABLE core.BillTemplate
(
    BillId          NVARCHAR(40)   NOT NULL CONSTRAINT PK_BillTemplate PRIMARY KEY,
    Name            NVARCHAR(160)  NOT NULL,
    /* 'customer' carries the whole order; 'group' carries only its own lines. */
    Audience        NVARCHAR(20)   NOT NULL,
    PrintGroupId    NVARCHAR(40)   NULL
        CONSTRAINT FK_BillTemplate_Group REFERENCES core.PrintGroup (PrintGroupId),
    IsDefault       BIT            NOT NULL CONSTRAINT DF_BillTemplate_Default DEFAULT (0),
    PaperSize       NVARCHAR(10)   NOT NULL CONSTRAINT DF_BillTemplate_Paper DEFAULT (N'80mm'),
    BillLanguage    NVARCHAR(10)   NOT NULL CONSTRAINT DF_BillTemplate_Lang DEFAULT (N'both'),
    ShowLogo        BIT NOT NULL CONSTRAINT DF_BT_Logo    DEFAULT (1),
    ShowVatNumber   BIT NOT NULL CONSTRAINT DF_BT_Vat     DEFAULT (1),
    ShowCrNumber    BIT NOT NULL CONSTRAINT DF_BT_Cr      DEFAULT (1),
    ShowUnitPrice   BIT NOT NULL CONSTRAINT DF_BT_Unit    DEFAULT (1),
    ShowLineTotal   BIT NOT NULL CONSTRAINT DF_BT_Line    DEFAULT (1),
    ShowSubtotal    BIT NOT NULL CONSTRAINT DF_BT_Sub     DEFAULT (1),
    ShowDiscount    BIT NOT NULL CONSTRAINT DF_BT_Disc    DEFAULT (1),
    ShowVat         BIT NOT NULL CONSTRAINT DF_BT_VatLine DEFAULT (1),
    ShowGrandTotal  BIT NOT NULL CONSTRAINT DF_BT_Grand   DEFAULT (1),
    ShowZatcaQr     BIT NOT NULL CONSTRAINT DF_BT_Qr      DEFAULT (1),
    FooterAr        NVARCHAR(400) NULL,
    FooterEn        NVARCHAR(400) NULL,
    IsActive        BIT NOT NULL CONSTRAINT DF_BillTemplate_Active DEFAULT (1),
    CreatedAtUtc    DATETIME2(3) NOT NULL CONSTRAINT DF_BillTemplate_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAtUtc    DATETIME2(3) NOT NULL CONSTRAINT DF_BillTemplate_Updated DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_BillTemplate_Audience CHECK (Audience IN (N'customer', N'group')),
    CONSTRAINT CK_BillTemplate_Paper    CHECK (PaperSize IN (N'58mm', N'80mm', N'a4')),
    CONSTRAINT CK_BillTemplate_Lang     CHECK (BillLanguage IN (N'ar', N'en', N'both')),
    /* A group ticket without a group has nothing to filter on. */
    CONSTRAINT CK_BillTemplate_GroupSet CHECK (Audience <> N'group' OR PrintGroupId IS NOT NULL)
);
GO

ALTER TABLE core.BranchSettings
    ADD CONSTRAINT FK_BranchSettings_Bill FOREIGN KEY (DefaultBillId)
        REFERENCES core.BillTemplate (BillId);
GO

PRINT N'06 · Finance ready.';
GO

/*==============================================================================
  SECTION: 07-programmability.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 07 · Views, functions and procedures

  These exist so the API layer cannot bypass the rules that matter. Posting a
  journal entry, committing a sale and freezing commission all go through a
  procedure; none of them is safe to assemble from ad-hoc INSERTs.
==============================================================================*/

USE POSMAIN;
GO

/*------------------------------------------------------------------ helpers */

/* Assets and expenses grow on the debit side; everything else on the credit. */
CREATE FUNCTION fin.fn_IsDebitNormal (@AccountType NVARCHAR(20))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE WHEN @AccountType IN (N'asset', N'expense') THEN 1 ELSE 0 END;
END
GO

/* VAT extracted from a VAT-inclusive gross amount, the Saudi retail case. */
CREATE FUNCTION fin.fn_VatFromGross (@GrossH BIGINT, @RatePercent DECIMAL(5,2))
RETURNS BIGINT
WITH SCHEMABINDING
AS
BEGIN
    RETURN CAST(ROUND(@GrossH * @RatePercent / (100.0 + @RatePercent), 0) AS BIGINT);
END
GO

/* Month-end aware date arithmetic: 31 Jan + 1 month is 28 Feb, not 3 Mar. */
CREATE FUNCTION fin.fn_AdvanceDueDate (@From DATE, @Frequency NVARCHAR(20))
RETURNS DATE
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE @Frequency
        WHEN N'daily'     THEN DATEADD(DAY,   1, @From)
        WHEN N'weekly'    THEN DATEADD(DAY,   7, @From)
        WHEN N'monthly'   THEN DATEADD(MONTH, 1, @From)
        WHEN N'quarterly' THEN DATEADD(MONTH, 3, @From)
        WHEN N'yearly'    THEN DATEADD(YEAR,  1, @From)
        ELSE @From
    END;
END
GO

/*-------------------------------------------------------------------- views */

CREATE VIEW fin.vw_AccountBalance
AS
SELECT
    a.AccountCode,
    a.AccountType,
    a.NameAr,
    a.NameEn,
    SUM(ISNULL(l.DebitH, 0))  AS TotalDebitH,
    SUM(ISNULL(l.CreditH, 0)) AS TotalCreditH,
    CASE WHEN fin.fn_IsDebitNormal(a.AccountType) = 1
         THEN SUM(ISNULL(l.DebitH, 0)) - SUM(ISNULL(l.CreditH, 0))
         ELSE SUM(ISNULL(l.CreditH, 0)) - SUM(ISNULL(l.DebitH, 0))
    END AS BalanceH
FROM fin.Account AS a
LEFT JOIN fin.JournalLine AS l ON l.AccountCode = a.AccountCode
GROUP BY a.AccountCode, a.AccountType, a.NameAr, a.NameEn;
GO

/* The ledger must balance. If this ever returns a row, something bypassed the
   posting procedure and it needs investigating, not patching. */
CREATE VIEW fin.vw_TrialBalanceCheck
AS
SELECT
    SUM(DebitH)  AS TotalDebitH,
    SUM(CreditH) AS TotalCreditH,
    SUM(DebitH) - SUM(CreditH) AS DifferenceH
FROM fin.JournalLine
HAVING SUM(DebitH) <> SUM(CreditH);
GO

CREATE VIEW sales.vw_SaleSummary
AS
SELECT
    s.SaleId,
    s.InvoiceNumber,
    s.BranchId,
    b.NameAr        AS BranchNameAr,
    b.NameEn        AS BranchNameEn,
    s.CustomerId,
    c.NameAr        AS CustomerNameAr,
    c.NameEn        AS CustomerNameEn,
    s.ServedByUserId,
    u.NameAr        AS ServedByNameAr,
    u.NameEn        AS ServedByNameEn,
    s.SubtotalH, s.DiscountH, s.TaxH, s.TotalH,
    s.Status, s.SoldAtUtc,
    (SELECT COUNT(*) FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId) AS LineCount
FROM sales.Sale AS s
LEFT JOIN core.Branch   AS b ON b.BranchId   = s.BranchId
LEFT JOIN core.Customer AS c ON c.CustomerId = s.CustomerId
LEFT JOIN core.AppUser  AS u ON u.UserId     = s.ServedByUserId;
GO

/* Receivables with aging, for the collections screen. */
CREATE VIEW fin.vw_Receivables
AS
SELECT
    c.CustomerId,
    c.NameAr,
    c.NameEn,
    c.Phone,
    c.BalanceH,
    c.CreditLimitH,
    c.CreditLimitH - c.BalanceH AS AvailableCreditH,
    oldest.OldestUnpaidUtc,
    DATEDIFF(DAY, oldest.OldestUnpaidUtc, SYSUTCDATETIME()) AS AgeDays,
    CASE
        WHEN oldest.OldestUnpaidUtc IS NULL THEN N'current'
        WHEN DATEDIFF(DAY, oldest.OldestUnpaidUtc, SYSUTCDATETIME()) <= 30 THEN N'current'
        WHEN DATEDIFF(DAY, oldest.OldestUnpaidUtc, SYSUTCDATETIME()) <= 60 THEN N'd30'
        WHEN DATEDIFF(DAY, oldest.OldestUnpaidUtc, SYSUTCDATETIME()) <= 90 THEN N'd60'
        ELSE N'd90'
    END AS AgeBucket
FROM core.Customer AS c
OUTER APPLY (
    SELECT MIN(s.SoldAtUtc) AS OldestUnpaidUtc
    FROM sales.Sale AS s
    WHERE s.CustomerId = c.CustomerId
      AND s.Status <> N'voided'
      AND EXISTS (SELECT 1 FROM sales.SalePayment AS p
                  WHERE p.SaleId = s.SaleId AND p.Method = N'credit')
) AS oldest
WHERE c.BalanceH > 0;
GO

/* Commission earned / paid / outstanding per employee per month. */
CREATE VIEW fin.vw_CommissionSummary
AS
SELECT
    e.UserId,
    u.NameAr,
    u.NameEn,
    CONVERT(CHAR(7), e.EarnedAtUtc, 126) AS PeriodMonth,
    COUNT(*)                                                        AS SaleLines,
    SUM(e.AmountH)                                                  AS EarnedH,
    SUM(CASE WHEN e.PayrollRunId IS NOT NULL THEN e.AmountH ELSE 0 END) AS PaidH,
    SUM(CASE WHEN e.PayrollRunId IS NULL     THEN e.AmountH ELSE 0 END) AS OutstandingH
FROM fin.CommissionEntry AS e
JOIN core.AppUser AS u ON u.UserId = e.UserId
GROUP BY e.UserId, u.NameAr, u.NameEn, CONVERT(CHAR(7), e.EarnedAtUtc, 126);
GO

/* Effective permissions: role grants, plus overrides, with denial winning. */
CREATE VIEW core.vw_EffectivePermission
AS
SELECT u.UserId, p.PermissionKey
FROM core.AppUser AS u
CROSS JOIN core.Permission AS p
WHERE
    (
        EXISTS (SELECT 1 FROM core.RolePermission AS rp
                WHERE rp.RoleId = u.RoleId AND rp.PermissionKey = p.PermissionKey)
        OR EXISTS (SELECT 1 FROM core.UserPermissionOverride AS o
                   WHERE o.UserId = u.UserId AND o.PermissionKey = p.PermissionKey
                     AND o.Effect = N'grant')
    )
    AND NOT EXISTS (SELECT 1 FROM core.UserPermissionOverride AS d
                    WHERE d.UserId = u.UserId AND d.PermissionKey = p.PermissionKey
                      AND d.Effect = N'deny');
GO

/*--------------------------------------------------------------- procedures */

/*
  Post a balanced journal entry.

  @Lines is a table-valued parameter so the whole entry arrives in one call and
  either lands complete or not at all.
*/
CREATE TYPE fin.JournalLineTable AS TABLE
(
    AccountCode NVARCHAR(10)  NOT NULL,
    DebitH      BIGINT        NOT NULL DEFAULT (0),
    CreditH     BIGINT        NOT NULL DEFAULT (0),
    Memo        NVARCHAR(400) NULL
);
GO

CREATE SEQUENCE fin.JournalSequence AS BIGINT START WITH 1001 INCREMENT BY 1;
GO

CREATE PROCEDURE fin.usp_PostJournalEntry
    @Kind            NVARCHAR(40),
    @DescriptionEn   NVARCHAR(400),
    @DescriptionAr   NVARCHAR(400) = NULL,
    @SourceReference NVARCHAR(80)  = NULL,
    @BranchId        NVARCHAR(40)  = NULL,
    @Actor           NVARCHAR(120),
    @PostedAtUtc     DATETIME2(3)  = NULL,
    @Lines           fin.JournalLineTable READONLY,
    @EntryId         NVARCHAR(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DebitH  BIGINT = (SELECT SUM(DebitH)  FROM @Lines);
    DECLARE @CreditH BIGINT = (SELECT SUM(CreditH) FROM @Lines);

    IF @DebitH IS NULL OR @DebitH = 0
        THROW 51000, N'An entry needs at least one non-zero line.', 1;

    IF @DebitH <> @CreditH
        THROW 51001, N'Entry does not balance: debits and credits differ.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE DebitH > 0 AND CreditH > 0)
        THROW 51002, N'A line is either a debit or a credit, not both.', 1;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR fin.JournalSequence;
        SET @EntryId = CONCAT(N'jrn_', FORMAT(@Seq, N'000000'));

        INSERT INTO fin.JournalEntry
            (EntryId, Reference, Kind, SourceReference, DescriptionAr, DescriptionEn,
             PostedAtUtc, BranchId, Actor, TotalDebitH, TotalCreditH)
        VALUES
            (@EntryId, CONCAT(N'JE-', @Seq), @Kind, @SourceReference,
             @DescriptionAr, @DescriptionEn,
             ISNULL(@PostedAtUtc, SYSUTCDATETIME()), @BranchId, @Actor, @DebitH, @CreditH);

        INSERT INTO fin.JournalLine (EntryId, AccountCode, DebitH, CreditH, Memo)
        SELECT @EntryId, AccountCode, DebitH, CreditH, Memo
        FROM @Lines
        WHERE DebitH > 0 OR CreditH > 0;

    COMMIT;
END
GO

/*
  Reverse an entry.

  Posts the mirror image and links the two. The original is never touched.
*/
CREATE PROCEDURE fin.usp_ReverseJournalEntry
    @EntryId  NVARCHAR(40),
    @Reason   NVARCHAR(400),
    @Actor    NVARCHAR(120),
    @NewEntryId NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM fin.JournalEntry WHERE EntryId = @EntryId)
        THROW 51010, N'Journal entry not found.', 1;

    IF EXISTS (SELECT 1 FROM fin.JournalEntry
               WHERE EntryId = @EntryId AND ReversedByEntryId IS NOT NULL)
        THROW 51011, N'This entry has already been reversed.', 1;

    IF LTRIM(RTRIM(ISNULL(@Reason, N''))) = N''
        THROW 51012, N'A reversal needs a reason on the record.', 1;

    DECLARE @Flipped fin.JournalLineTable;

    INSERT INTO @Flipped (AccountCode, DebitH, CreditH, Memo)
    SELECT AccountCode, CreditH, DebitH, Memo
    FROM fin.JournalLine WHERE EntryId = @EntryId;

    DECLARE @Kind NVARCHAR(40), @Src NVARCHAR(80), @Branch NVARCHAR(40), @Ref NVARCHAR(40);
    SELECT @Kind = Kind, @Src = SourceReference, @Branch = BranchId, @Ref = Reference
    FROM fin.JournalEntry WHERE EntryId = @EntryId;

    BEGIN TRAN;

        EXEC fin.usp_PostJournalEntry
            @Kind            = @Kind,
            @DescriptionEn   = @Reason,
            @SourceReference = @Src,
            @BranchId        = @Branch,
            @Actor           = @Actor,
            @Lines           = @Flipped,
            @EntryId         = @NewEntryId OUTPUT;

        UPDATE fin.JournalEntry
        SET ReversesEntryId = @EntryId,
            ReversalReason  = @Reason,
            DescriptionEn   = CONCAT(N'Reversal of ', @Ref, N' — ', @Reason)
        WHERE EntryId = @NewEntryId;

        UPDATE fin.JournalEntry
        SET ReversedByEntryId = @NewEntryId
        WHERE EntryId = @EntryId;

    COMMIT;
END
GO

/*
  Freeze commission for a sale.

  Resolves the most specific active rule per line and writes the amount. Called
  once, at the moment of sale; nothing recomputes it afterwards.
*/
CREATE PROCEDURE fin.usp_RecordSaleCommission
    @SaleId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId NVARCHAR(40), @Invoice NVARCHAR(40), @BranchId NVARCHAR(40);
    SELECT @UserId = ServedByUserId, @Invoice = InvoiceNumber, @BranchId = BranchId
    FROM sales.Sale WHERE SaleId = @SaleId;

    IF @UserId IS NULL RETURN;   -- nobody credited, nothing to earn

    ;WITH Resolved AS (
        SELECT
            sl.SaleLineId, sl.ItemId, sl.NameAr, sl.NameEn,
            (sl.UnitPriceH * sl.Quantity) - sl.LineDiscountH AS LineGrossH,
            r.RuleId, r.Basis, r.Value,
            /* Named people beat "everyone"; named services beat "everything". */
            ROW_NUMBER() OVER (
                PARTITION BY sl.SaleLineId
                ORDER BY
                    (CASE WHEN EXISTS (SELECT 1 FROM fin.CommissionRuleUser ru
                                       WHERE ru.RuleId = r.RuleId) THEN 2 ELSE 0 END) +
                    (CASE WHEN EXISTS (SELECT 1 FROM fin.CommissionRuleItem ri
                                       WHERE ri.RuleId = r.RuleId) THEN 1 ELSE 0 END) DESC,
                    r.CreatedAtUtc DESC
            ) AS Rank
        FROM sales.SaleLine AS sl
        JOIN core.CatalogItem AS ci ON ci.ItemId = sl.ItemId
        CROSS JOIN fin.CommissionRule AS r
        WHERE sl.SaleId = @SaleId
          AND ci.Kind = N'service'          -- commission is for work performed
          AND r.IsActive = 1
          AND (NOT EXISTS (SELECT 1 FROM fin.CommissionRuleUser ru WHERE ru.RuleId = r.RuleId)
               OR EXISTS (SELECT 1 FROM fin.CommissionRuleUser ru
                          WHERE ru.RuleId = r.RuleId AND ru.UserId = @UserId))
          AND (NOT EXISTS (SELECT 1 FROM fin.CommissionRuleItem ri WHERE ri.RuleId = r.RuleId)
               OR EXISTS (SELECT 1 FROM fin.CommissionRuleItem ri
                          WHERE ri.RuleId = r.RuleId AND ri.ItemId = sl.ItemId))
    )
    INSERT INTO fin.CommissionEntry
        (CommissionId, SaleId, InvoiceNumber, UserId, ItemId, ItemNameAr, ItemNameEn,
         LineGrossH, AmountH, Basis, RateAtSale, BranchId)
    SELECT
        CONCAT(N'cme_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''))),
        @SaleId, @Invoice, @UserId, ItemId, NameAr, NameEn,
        LineGrossH,
        CASE WHEN Basis = N'percentage'
             THEN CAST(ROUND(LineGrossH * Value / 10000.0, 0) AS BIGINT)
             ELSE Value
        END,
        Basis, Value, @BranchId
    FROM Resolved
    WHERE Rank = 1
      AND (CASE WHEN Basis = N'percentage'
                THEN CAST(ROUND(LineGrossH * Value / 10000.0, 0) AS BIGINT)
                ELSE Value END) > 0;
END
GO

/*
  Spread an expense across the months it covers.

  Rounding remainders land on the final month so the slices always sum back to
  the amount recognised — never a halala more or less.
*/
CREATE PROCEDURE fin.usp_BuildExpenseRecognition
    @ExpenseId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AmountH BIGINT, @VatH BIGINT, @Recognition NVARCHAR(20),
            @PeriodFrom DATE, @PeriodTo DATE, @PaidOn DATE;

    SELECT @AmountH = AmountH, @VatH = VatH, @Recognition = Recognition,
           @PeriodFrom = PeriodStart, @PeriodTo = PeriodEnd, @PaidOn = PaidOn
    FROM fin.Expense WHERE ExpenseId = @ExpenseId;

    IF @AmountH IS NULL THROW 51020, N'Expense not found.', 1;

    DELETE FROM fin.ExpenseRecognition WHERE ExpenseId = @ExpenseId;

    DECLARE @NetH BIGINT = @AmountH - @VatH;

    IF @Recognition = N'one_time'
    BEGIN
        INSERT INTO fin.ExpenseRecognition (ExpenseId, PeriodMonth, AmountH)
        VALUES (@ExpenseId, CONVERT(CHAR(7), @PaidOn, 126), @NetH);
        RETURN;
    END

    ;WITH Months AS (
        SELECT CAST(DATEFROMPARTS(YEAR(@PeriodFrom), MONTH(@PeriodFrom), 1) AS DATE) AS M
        UNION ALL
        SELECT DATEADD(MONTH, 1, M) FROM Months
        WHERE DATEADD(MONTH, 1, M) <= DATEFROMPARTS(YEAR(@PeriodTo), MONTH(@PeriodTo), 1)
    ),
    Numbered AS (
        SELECT M, ROW_NUMBER() OVER (ORDER BY M) AS Rn, COUNT(*) OVER () AS Total
        FROM Months
    )
    INSERT INTO fin.ExpenseRecognition (ExpenseId, PeriodMonth, AmountH)
    SELECT
        @ExpenseId,
        CONVERT(CHAR(7), M, 126),
        CASE WHEN Rn = Total
             THEN @NetH - (@NetH / Total) * (Total - 1)   -- remainder on the last month
             ELSE @NetH / Total
        END
    FROM Numbered
    OPTION (MAXRECURSION 400);
END
GO

/* Reconcile the denormalised customer balance against the ledger. */
CREATE PROCEDURE fin.usp_RebuildCustomerBalances
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Charged AS (
        SELECT s.CustomerId, SUM(p.AmountH) AS ChargedH
        FROM sales.Sale AS s
        JOIN sales.SalePayment AS p ON p.SaleId = s.SaleId AND p.Method = N'credit'
        WHERE s.CustomerId IS NOT NULL AND s.Status <> N'voided'
        GROUP BY s.CustomerId
    ),
    Collected AS (
        SELECT e.SourceReference AS CustomerId, SUM(l.CreditH) AS CollectedH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId AND l.AccountCode = N'1400'
        WHERE e.Kind = N'customer_collection'
        GROUP BY e.SourceReference
    )
    UPDATE c
    SET BalanceH = ISNULL(ch.ChargedH, 0) - ISNULL(co.CollectedH, 0),
        UpdatedAtUtc = SYSUTCDATETIME()
    FROM core.Customer AS c
    LEFT JOIN Charged   AS ch ON ch.CustomerId = c.CustomerId
    LEFT JOIN Collected AS co ON co.CustomerId = c.CustomerId;
END
GO

PRINT N'07 · Programmability ready.';
GO

/*==============================================================================
  SECTION: 08-seed-reference.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 08 · Reference data

  Chart of accounts, permissions, roles. This is not demo data — the system
  cannot function without it.
==============================================================================*/

USE POSMAIN;
GO

/* Chart of accounts ---------------------------------------------------------*/

INSERT INTO fin.Account (AccountCode, AccountType, NameAr, NameEn) VALUES
    (N'1000', N'asset',     N'الصندوق',                      N'Cash'),
    (N'1100', N'asset',     N'البنك',                        N'Bank'),
    (N'1150', N'asset',     N'متحصلات الشبكة تحت التحصيل',   N'Card clearing'),
    (N'1200', N'asset',     N'المخزون',                      N'Inventory'),
    (N'1300', N'asset',     N'ضريبة المدخلات',               N'Input VAT'),
    (N'1400', N'asset',     N'ذمم العملاء',                  N'Accounts receivable'),
    (N'1500', N'asset',     N'مصروفات مدفوعة مقدمًا',        N'Prepaid expenses'),
    (N'2000', N'liability', N'الموردون',                     N'Accounts payable'),
    (N'2050', N'liability', N'بضاعة مستلمة غير مفوترة',      N'Goods received not invoiced'),
    (N'2100', N'liability', N'ضريبة المخرجات',               N'Output VAT'),
    (N'2200', N'liability', N'مصروفات مستحقة',               N'Accrued expenses'),
    (N'2300', N'liability', N'عمولات مستحقة للموظفين',       N'Commission payable'),
    (N'3000', N'equity',    N'رأس مال المالك',               N'Owner capital'),
    (N'3200', N'equity',    N'حساب جاري المالك',             N'Owner current account'),
    (N'3900', N'equity',    N'تسوية الأرصدة الافتتاحية',     N'Opening balance suspense'),
    (N'4100', N'revenue',   N'المبيعات',                     N'Sales'),
    (N'4200', N'revenue',   N'مردودات المبيعات',             N'Sales returns'),
    (N'5100', N'expense',   N'تكلفة البضاعة المباعة',        N'Cost of goods sold'),
    (N'5200', N'expense',   N'فروقات وتلف المخزون',          N'Stock variance'),
    (N'6000', N'expense',   N'مصروفات تشغيلية',              N'Operating expenses'),
    (N'6100', N'expense',   N'رسوم وعمولات الشبكة',          N'Card fees'),
    (N'6200', N'expense',   N'الرواتب',                      N'Salaries'),
    (N'6300', N'expense',   N'العمولات',                     N'Commissions');
GO

/* Permissions ---------------------------------------------------------------*/

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity) VALUES
    (N'dashboard.view',        N'dashboard', N'view',          N'general'),
    (N'pos.create_sale',       N'pos',       N'create_sale',   N'general'),
    (N'pos.apply_discount',    N'pos',       N'apply_discount',N'general'),
    (N'pos.open_drawer',       N'pos',       N'open_drawer',   N'financial'),
    (N'sales.view',            N'sales',     N'view',          N'general'),
    (N'sales.view_details',    N'sales',     N'view_details',  N'general'),
    (N'sales.refund',          N'sales',     N'refund',        N'financial'),
    (N'sales.void',            N'sales',     N'void',          N'financial'),
    (N'products.view',         N'products',  N'view',          N'general'),
    (N'products.create',       N'products',  N'create',        N'general'),
    (N'products.edit',         N'products',  N'edit',          N'general'),
    (N'products.delete',       N'products',  N'delete',        N'general'),
    (N'inventory.view',        N'inventory', N'view',          N'general'),
    (N'inventory.adjust',      N'inventory', N'adjust',        N'general'),
    (N'inventory.restock',     N'inventory', N'restock',       N'general'),
    (N'inventory.purchase_entry', N'inventory', N'purchase_entry', N'financial'),
    (N'vendors.view',          N'vendors',   N'view',          N'general'),
    (N'vendors.create',        N'vendors',   N'create',        N'general'),
    (N'vendors.edit',          N'vendors',   N'edit',          N'general'),
    (N'vendors.pay',           N'vendors',   N'pay',           N'financial'),
    (N'customers.view',        N'customers', N'view',          N'general'),
    (N'customers.create',      N'customers', N'create',        N'general'),
    (N'customers.edit',        N'customers', N'edit',          N'general'),
    (N'customers.credit',      N'customers', N'credit',        N'financial'),
    (N'discounts.view',        N'discounts', N'view',          N'general'),
    (N'discounts.create',      N'discounts', N'create',        N'general'),
    (N'discounts.edit',        N'discounts', N'edit',          N'general'),
    (N'discounts.approve',     N'discounts', N'approve',       N'financial'),
    (N'kitchen.view',          N'kitchen',   N'view',          N'general'),
    (N'kitchen.update',        N'kitchen',   N'update',        N'general'),
    (N'users.view',            N'users',     N'view',          N'personal'),
    (N'users.create',          N'users',     N'create',        N'personal'),
    (N'users.edit',            N'users',     N'edit',          N'personal'),
    (N'users.delete',          N'users',     N'delete',        N'personal'),
    (N'roles.view',            N'roles',     N'view',          N'personal'),
    (N'roles.create',          N'roles',     N'create',        N'personal'),
    (N'roles.edit',            N'roles',     N'edit',          N'personal'),
    (N'finance.view',          N'finance',   N'view',          N'financial'),
    (N'finance.expenses',      N'finance',   N'expenses',      N'financial'),
    (N'finance.ledger',        N'finance',   N'ledger',        N'financial'),
    (N'finance.reverse',       N'finance',   N'reverse',       N'financial'),
    (N'finance.payroll',       N'finance',   N'payroll',       N'financial'),
    (N'finance.commission',    N'finance',   N'commission',    N'financial'),
    (N'reports.view',          N'reports',   N'view',          N'financial'),
    (N'settings.view',         N'settings',  N'view',          N'general'),
    (N'settings.edit',         N'settings',  N'edit',          N'general'),
    (N'bill_builder.view',     N'bill_builder', N'view',       N'general'),
    (N'bill_builder.edit',     N'bill_builder', N'edit',       N'general'),
    (N'company.view',          N'company',   N'view',          N'general'),
    (N'company.edit',          N'company',   N'edit',          N'general');
GO

/* Roles ---------------------------------------------------------------------*/

INSERT INTO core.Role (RoleId, NameAr, NameEn, DescriptionAr, DescriptionEn, IsBuiltIn, IsExternal) VALUES
    (N'rol_owner',     N'مالك',            N'Owner',             N'صلاحية كاملة على النظام',        N'Full access to everything', 1, 0),
    (N'rol_manager',   N'مدير',            N'Manager',           N'إدارة الفرع والعمليات اليومية',  N'Runs the branch day to day', 1, 0),
    (N'rol_cashier',   N'كاشير',           N'Cashier',           N'البيع وخدمة العملاء',            N'Sells and serves customers', 1, 0),
    (N'rol_accountant',N'محاسب',           N'Accountant',        N'المالية والتقارير',              N'Finance and reporting',      1, 0),
    (N'rol_inventory', N'أمين مستودع',     N'Inventory manager', N'المخزون والموردون',              N'Stock and suppliers',        1, 0),
    (N'rol_maintenance',N'صيانة خارجية',   N'External support',  N'وصول مؤقت للصيانة',              N'Temporary maintenance access',1, 1);
GO

/* Owner: everything. */
INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT N'rol_owner', PermissionKey FROM core.Permission;

/* Manager: everything except user administration and ledger reversal. */
INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT N'rol_manager', PermissionKey FROM core.Permission
WHERE PermissionKey NOT IN (N'users.delete', N'roles.create', N'roles.edit', N'finance.reverse');

INSERT INTO core.RolePermission (RoleId, PermissionKey) VALUES
    (N'rol_cashier', N'dashboard.view'),
    (N'rol_cashier', N'pos.create_sale'),
    (N'rol_cashier', N'pos.apply_discount'),
    (N'rol_cashier', N'sales.view'),
    (N'rol_cashier', N'sales.view_details'),
    (N'rol_cashier', N'products.view'),
    (N'rol_cashier', N'customers.view'),
    (N'rol_cashier', N'customers.create'),
    (N'rol_cashier', N'discounts.view'),
    (N'rol_cashier', N'kitchen.view'),
    (N'rol_cashier', N'kitchen.update');

INSERT INTO core.RolePermission (RoleId, PermissionKey) VALUES
    (N'rol_accountant', N'dashboard.view'),
    (N'rol_accountant', N'sales.view'),
    (N'rol_accountant', N'sales.view_details'),
    (N'rol_accountant', N'products.view'),
    (N'rol_accountant', N'inventory.view'),
    (N'rol_accountant', N'vendors.view'),
    (N'rol_accountant', N'vendors.pay'),
    (N'rol_accountant', N'customers.view'),
    (N'rol_accountant', N'customers.credit'),
    (N'rol_accountant', N'finance.view'),
    (N'rol_accountant', N'finance.expenses'),
    (N'rol_accountant', N'finance.ledger'),
    (N'rol_accountant', N'finance.payroll'),
    (N'rol_accountant', N'finance.commission'),
    (N'rol_accountant', N'reports.view');

INSERT INTO core.RolePermission (RoleId, PermissionKey) VALUES
    (N'rol_inventory', N'dashboard.view'),
    (N'rol_inventory', N'products.view'),
    (N'rol_inventory', N'products.create'),
    (N'rol_inventory', N'products.edit'),
    (N'rol_inventory', N'inventory.view'),
    (N'rol_inventory', N'inventory.adjust'),
    (N'rol_inventory', N'inventory.restock'),
    (N'rol_inventory', N'inventory.purchase_entry'),
    (N'rol_inventory', N'vendors.view'),
    (N'rol_inventory', N'vendors.create'),
    (N'rol_inventory', N'vendors.edit');

/* External support: nothing financial, nothing personal. Enforced by data, so
   granting it by mistake is impossible rather than merely discouraged. */
INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT N'rol_maintenance', PermissionKey FROM core.Permission
WHERE Sensitivity = N'general'
  AND Module IN (N'dashboard', N'products', N'inventory', N'settings');
GO

PRINT N'08 · Reference data ready.';
GO

/*==============================================================================
  SECTION: 09-seed-demo.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 09 · Demo data

  A working shop, not an empty prototype: two branches, staff, a mixed catalog
  of products and services, customers with real balances, and six months of
  trading so the charts and reports have something to draw.

  Safe to skip in production — nothing above depends on it.
==============================================================================*/

USE POSMAIN;
GO

/* Company and branches ------------------------------------------------------*/

INSERT INTO core.Company
    (NameAr, NameEn, DescriptionAr, DescriptionEn, CrNumber, VatNumber, Phone, Email, Website,
     Street, District, City, PostalCode, Country)
VALUES
    (N'متجر النور', N'Al Noor Store',
     N'متجرك الموثوق في الحي', N'Your trusted neighbourhood store',
     N'1010123456', N'300000000000003', N'+966 11 220 8899', N'hello@alnoor.sa', N'alnoor.sa',
     N'طريق الملك فهد', N'العليا', N'الرياض', N'12211', N'SA');
GO

INSERT INTO core.Branch (BranchId, Code, NameAr, NameEn, Phone, AddressAr, AddressEn) VALUES
    (N'brn_001', N'RUH-01', N'الرياض الرئيسي', N'Riyadh Main', N'+966 11 220 8899',
     N'طريق الملك فهد، العليا، الرياض', N'King Fahd Road, Al Olaya, Riyadh'),
    (N'brn_002', N'JED-01', N'جدة',            N'Jeddah',      N'+966 12 660 4411',
     N'طريق الأمير سلطان، الروضة، جدة', N'Prince Sultan Road, Al Rawdah, Jeddah');
GO

INSERT INTO core.BranchSettings (BranchId, DefaultCustomerMode, ServedByRequirement) VALUES
    (N'brn_001', N'walkin',   N'optional'),
    (N'brn_002', N'customer', N'required');
GO

/* Users ---------------------------------------------------------------------*/

INSERT INTO core.AppUser
    (UserId, Username, NameAr, NameEn, Email, Phone, RoleId, Status, IsExternal, AccessExpiresOn, BaseSalaryH)
VALUES
    (N'usr_001', N'ahmed',   N'أحمد علي',      N'Ahmed Ali',       N'owner@demo.com',   N'+966501234567', N'rol_owner',      N'active',    0, NULL,         900000),
    (N'usr_002', N'sara',    N'سارة عبدالله',  N'Sara Abdullah',   N'manager@demo.com', N'+966502345678', N'rol_manager',    N'active',    0, NULL,         650000),
    (N'usr_003', N'yousef',  N'يوسف الحربي',   N'Yousef Al Harbi', N'cashier@demo.com', N'+966503456789', N'rol_cashier',    N'active',    0, NULL,         400000),
    (N'usr_004', N'mona',    N'منى القحطاني',  N'Mona Al Qahtani', N'mona@demo.com',    N'+966504567890', N'rol_accountant', N'suspended', 0, NULL,         550000),
    (N'usr_005', N'khalid',  N'خالد الدعم',    N'Support Khalid',  N'khalid@vendor.sa', N'+966505678901', N'rol_maintenance',N'active',    1, '2026-12-31',      0),
    (N'usr_006', N'faisal',  N'فيصل النمر',    N'Faisal Al Nimr',  N'faisal@demo.com',  N'+966506789012', N'rol_cashier',    N'active',    0, NULL,         420000);
GO

INSERT INTO core.UserBranch (UserId, BranchId) VALUES
    (N'usr_001', N'brn_001'), (N'usr_001', N'brn_002'),
    (N'usr_002', N'brn_001'), (N'usr_002', N'brn_002'),
    (N'usr_003', N'brn_001'),
    (N'usr_004', N'brn_001'),
    (N'usr_005', N'brn_001'),
    (N'usr_006', N'brn_002');
GO

/* Sara can void a sale even though her role cannot. */
INSERT INTO core.UserPermissionOverride (UserId, PermissionKey, Effect) VALUES
    (N'usr_002', N'sales.void', N'grant');
GO

/* Categories, print groups, vendors -----------------------------------------*/

INSERT INTO core.Category (CategoryId, NameAr, NameEn, SortOrder) VALUES
    (N'cat_drinks',   N'المشروبات',       N'Drinks',        1),
    (N'cat_food',     N'الأطعمة',         N'Food',          2),
    (N'cat_personal', N'العناية الشخصية', N'Personal Care', 3),
    (N'cat_grooming', N'الحلاقة',         N'Grooming',      4),
    (N'cat_laundry',  N'المغسلة',         N'Laundry',       5),
    (N'cat_prof',     N'خدمات مهنية',     N'Professional',  6);
GO

INSERT INTO core.PrintGroup (PrintGroupId, NameAr, NameEn, TicketTitle, SortOrder) VALUES
    (N'pgr_kitchen', N'المطبخ',    N'Kitchen', N'KITCHEN', 1),
    (N'pgr_bbq',     N'المشويات',  N'BBQ',     N'BBQ',     2),
    (N'pgr_bar',     N'المشروبات', N'Bar',     N'BAR',     3),
    (N'pgr_packing', N'التغليف',   N'Packing', N'PACKING', 4);
GO

INSERT INTO core.Vendor (VendorId, NameAr, NameEn, ContactPerson, Phone, Email, VatNumber, PaymentTermDays) VALUES
    (N'ven_001', N'الرياض للتجارة',      N'Al Riyadh Trading',      N'Omar Nasser',  N'+966112223344', N'sales@riyadhtrading.sa', N'300000000000013', 30),
    (N'ven_002', N'الخليج للتوريدات',    N'Gulf Supplies',          N'Layla Hassan', N'+966113334455', N'info@gulfsupplies.sa',   N'300000000000023', 15),
    (N'ven_003', N'التوزيع الحديث',      N'Modern Distribution Co.',N'Tariq Saeed',  N'+966114445566', N'orders@moderndist.sa',   N'300000000000033',  0);
GO

/* Catalog -------------------------------------------------------------------*/

INSERT INTO core.CatalogItem
    (ItemId, Kind, NameAr, NameEn, Sku, Barcode, CategoryId, VendorId, PrintGroupId,
     PriceH, CostH, TracksStock, ReorderLevel, RequiresPreparation)
VALUES
    (N'itm_001', N'product', N'كوكا كولا ٣٣٠ مل',  N'Coca Cola 330ml',   N'BEV-001', N'6281000010001', N'cat_drinks',   N'ven_001', N'pgr_bar',     300,   180, 1, 24, 0),
    (N'itm_002', N'product', N'بيبسي ٣٣٠ مل',      N'Pepsi 330ml',       N'BEV-002', N'6281000010002', N'cat_drinks',   N'ven_001', N'pgr_bar',     300,   175, 1, 24, 0),
    (N'itm_003', N'product', N'قهوة عربية',        N'Arabic Coffee',     N'BEV-003', N'6281000010003', N'cat_drinks',   N'ven_002', N'pgr_bar',    1200,   450, 1, 10, 1),
    (N'itm_004', N'product', N'برجر دجاج',         N'Chicken Burger',    N'FOO-001', N'6281000020001', N'cat_food',     N'ven_002', N'pgr_kitchen',2500,  1050, 1, 15, 1),
    (N'itm_005', N'product', N'شامبو ٤٠٠ مل',      N'Shampoo 400ml',     N'PER-001', N'6281000030001', N'cat_personal', N'ven_003', NULL,          2800,  1800, 1, 12, 0),
    (N'itm_006', N'product', N'جل شعر',            N'Hair Gel',          N'PER-002', N'6281000030002', N'cat_personal', N'ven_003', NULL,          1900,  1150, 1, 10, 0),
    (N'itm_007', N'product', N'ماء ٦٠٠ مل',        N'Water 600ml',       N'BEV-004', N'6281000010004', N'cat_drinks',   N'ven_001', N'pgr_bar',     150,    70, 1, 48, 0),
    (N'itm_008', N'product', N'تمر سكري ١ كجم',    N'Sukkari Dates 1kg', N'FOO-002', N'6281000020002', N'cat_food',     N'ven_002', N'pgr_packing',4500,  3000, 1,  8, 0),
    (N'itm_009', N'product', N'رغوة حلاقة',        N'Shaving Foam',      N'PER-003', N'6281000030003', N'cat_personal', N'ven_003', NULL,          2200,  1400, 1,  6, 0),
    (N'itm_010', N'service', N'قص شعر',            N'Haircut',           NULL, NULL, N'cat_grooming', NULL, NULL,       4000,  1000, 0, 0, 0),
    (N'itm_011', N'service', N'تشذيب اللحية',      N'Beard Trim',        NULL, NULL, N'cat_grooming', NULL, NULL,       2500,   600, 0, 0, 0),
    (N'itm_012', N'service', N'غسيل شعر',          N'Hair Wash',         NULL, NULL, N'cat_grooming', NULL, NULL,       1500,   400, 0, 0, 0),
    (N'itm_013', N'service', N'غسيل قميص',         N'Shirt Washing',     NULL, NULL, N'cat_laundry',  NULL, NULL,       1500,   500, 0, 0, 0),
    (N'itm_014', N'service', N'تنظيف بدلة جاف',    N'Suit Dry Cleaning', NULL, NULL, N'cat_laundry',  NULL, NULL,       4500,  1600, 0, 0, 0),
    (N'itm_015', N'service', N'استشارة',           N'Consultation',      NULL, NULL, N'cat_prof',     NULL, NULL,      15000,     0, 0, 0, 0);
GO

UPDATE core.CatalogItem SET IsActive = 0 WHERE ItemId = N'itm_009';
GO

/* A third language, to prove the overflow table works end to end. */
INSERT INTO core.Translation (EntityType, EntityKey, FieldName, LanguageCode, Value) VALUES
    (N'CatalogItem', N'itm_010', N'Name', N'ur', N'بال کٹنگ'),
    (N'CatalogItem', N'itm_010', N'Name', N'hi', N'बाल कटवाना'),
    (N'CatalogItem', N'itm_010', N'Name', N'tl', N'Gupit'),
    (N'CatalogItem', N'itm_013', N'Name', N'ur', N'قمیض دھلائی'),
    (N'CatalogItem', N'itm_013', N'Name', N'hi', N'शर्ट धुलाई'),
    (N'CatalogItem', N'itm_013', N'Name', N'tl', N'Labada ng Polo'),
    (N'Category',    N'cat_drinks', N'Name', N'ur', N'مشروبات'),
    (N'Category',    N'cat_food',   N'Name', N'ur', N'کھانا');
GO

/* Opening stock, per branch. */
INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
SELECT i.ItemId, b.BranchId,
       CASE WHEN b.BranchId = N'brn_001' THEN 40 ELSE 22 END
FROM core.CatalogItem AS i
CROSS JOIN core.Branch AS b
WHERE i.TracksStock = 1;
GO

INSERT INTO inv.StockMovement (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH, ReasonEn, ReasonAr, Actor)
SELECT s.ItemId, s.BranchId, N'opening', s.Quantity, s.Quantity, i.CostH,
       N'Opening stock', N'رصيد افتتاحي', N'System'
FROM inv.StockLevel AS s
JOIN core.CatalogItem AS i ON i.ItemId = s.ItemId;
GO

/* Customers -----------------------------------------------------------------*/

INSERT INTO core.Customer (CustomerId, NameAr, NameEn, Phone, Email, VatNumber, CustomerType, CreditLimitH, BalanceH) VALUES
    (N'cus_001', N'أحمد علي',       N'Ahmed Ali',        N'+966551112233', N'ahmed@example.sa', NULL,                N'individual',  100000,  24500),
    (N'cus_002', N'محمد حسن',       N'Mohammed Hassan',  N'+966552223344', NULL,                NULL,                N'individual',   50000,      0),
    (N'cus_003', N'سارة عبدالله',   N'Sara Abdullah',    N'+966553334455', N'sara@example.sa',  NULL,                N'individual',   75000,   8000),
    (N'cus_004', N'مؤسسة النخبة',   N'Al Nukhba Est.',   N'+966114445566', N'ap@nukhba.sa',     N'300000000000043', N'business',    500000, 182000);
GO

/* Discounts -----------------------------------------------------------------*/

INSERT INTO sales.Discount
    (DiscountId, NameAr, NameEn, DiscountType, Value, MaxDiscountH, MinSubtotalH,
     ApprovalAboveH, AppliesTo, IsAutomatic, AllowStacking, ActiveDays, IsActive)
VALUES
    (N'dsc_001', N'خصم العملاء',      N'Customer discount',  N'percentage',  500, 5000,      0, NULL,  N'all',      0, 0, N'',      1),
    (N'dsc_002', N'خصم الموظفين',     N'Employee discount',  N'percentage', 1000, 10000,     0, 5000, N'all',      0, 0, N'',      1),
    (N'dsc_003', N'عرض ٢٠ ريال',      N'SAR 20 promo',       N'fixed',      2000, NULL,  10000, NULL,  N'all',      0, 0, N'',      1),
    (N'dsc_004', N'خصم الخدمات',      N'Services discount',  N'percentage', 1500, 8000,      0, 3000, N'services', 0, 0, N'',      1),
    (N'dsc_005', N'تصفية',            N'Clearance',          N'percentage', 2500, NULL,      0, NULL,  N'products', 0, 0, N'',      0),
    (N'dsc_006', N'اليوم الوطني',     N'National Day',       N'percentage', 1000, NULL,      0, NULL,  N'all',      1, 0, N'',      1),
    (N'dsc_007', N'عرض نهاية الأسبوع',N'Weekend offer',      N'percentage',  700, 6000,  5000, NULL,  N'all',      1, 0, N'4,5,6', 1);
GO

/* Bill templates ------------------------------------------------------------*/

INSERT INTO core.BillTemplate (BillId, Name, Audience, PrintGroupId, IsDefault, PaperSize, BillLanguage) VALUES
    (N'bil_customer', N'Customer bill', N'customer', NULL, 1, N'80mm', N'both');

INSERT INTO core.BillTemplate
    (BillId, Name, Audience, PrintGroupId, IsDefault, PaperSize, BillLanguage,
     ShowLogo, ShowVatNumber, ShowCrNumber, ShowUnitPrice, ShowLineTotal,
     ShowSubtotal, ShowDiscount, ShowVat, ShowGrandTotal, ShowZatcaQr)
VALUES
    /* Operational tickets carry the item and the count. Money on a kitchen
       ticket is noise the cook has to read past. */
    (N'bil_kitchen', N'Kitchen ticket', N'group', N'pgr_kitchen', 0, N'58mm', N'both', 0,0,0,0,0,0,0,0,0,0),
    (N'bil_bbq',     N'BBQ ticket',     N'group', N'pgr_bbq',     0, N'58mm', N'both', 0,0,0,0,0,0,0,0,0,0),
    (N'bil_bar',     N'Bar ticket',     N'group', N'pgr_bar',     0, N'58mm', N'both', 0,0,0,0,0,0,0,0,0,0);
GO

UPDATE core.BranchSettings SET DefaultBillId = N'bil_customer';
GO

/* Expense categories and recurring payments ---------------------------------*/

INSERT INTO fin.ExpenseCategory (CategoryId, NameAr, NameEn, AccountCode) VALUES
    (N'exc_rent',  N'الإيجار',        N'Rent',            N'6000'),
    (N'exc_util',  N'المرافق',        N'Utilities',       N'6000'),
    (N'exc_sal',   N'الرواتب',        N'Salaries',        N'6200'),
    (N'exc_ins',   N'التأمين',        N'Insurance',       N'6000'),
    (N'exc_sub',   N'الاشتراكات',     N'Subscriptions',   N'6000'),
    (N'exc_main',  N'الصيانة',        N'Maintenance',     N'6000'),
    (N'exc_gov',   N'رسوم حكومية',    N'Government fees', N'6000'),
    (N'exc_mkt',   N'التسويق',        N'Marketing',       N'6000'),
    (N'exc_other', N'أخرى',           N'Other',           N'6000');
GO

INSERT INTO fin.RecurringPayment
    (RecurringId, DescriptionAr, DescriptionEn, CategoryId, BranchId, AmountH, Frequency, NextDueOn, LastPaidOn, PaymentMethod)
VALUES
    (N'rec_rent',   N'إيجار المحل',       N'Shop rent',             N'exc_rent', N'brn_001', 800000, N'monthly', DATEADD(DAY,  3, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY, -27, CAST(SYSUTCDATETIME() AS DATE)), N'bank'),
    (N'rec_salary', N'رواتب الموظفين',    N'Employee salaries',     N'exc_sal',  NULL,       600000, N'monthly', DATEADD(DAY,  9, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY, -21, CAST(SYSUTCDATETIME() AS DATE)), N'bank'),
    (N'rec_elec',   N'الكهرباء',          N'Electricity',           N'exc_util', N'brn_001', 185000, N'monthly', DATEADD(DAY,  5, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY, -25, CAST(SYSUTCDATETIME() AS DATE)), N'bank'),
    (N'rec_net',    N'الإنترنت',          N'Internet',              N'exc_util', NULL,        30000, N'monthly', DATEADD(DAY, 22, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY,  -8, CAST(SYSUTCDATETIME() AS DATE)), N'bank'),
    (N'rec_ins',    N'تأمين المنشأة',     N'Business insurance',    N'exc_ins',  NULL,       450000, N'yearly',  DATEADD(DAY, 18, CAST(SYSUTCDATETIME() AS DATE)), NULL,                                              N'bank'),
    /* Deliberately overdue, so the red state is visible on first run. */
    (N'rec_soft',   N'اشتراك البرنامج',   N'Software subscription', N'exc_sub',  NULL,        45000, N'monthly', DATEADD(DAY, -2, CAST(SYSUTCDATETIME() AS DATE)), DATEADD(DAY, -32, CAST(SYSUTCDATETIME() AS DATE)), N'card');
GO

/* Commission ----------------------------------------------------------------*/

INSERT INTO fin.CommissionRule (RuleId, Basis, Value) VALUES
    (N'crl_default', N'percentage', 1000),   -- everyone, every service: 10%
    (N'crl_barbers', N'percentage', 2000);   -- named barbers on named services: 20%
GO

INSERT INTO fin.CommissionRuleUser (RuleId, UserId) VALUES
    (N'crl_barbers', N'usr_003'),
    (N'crl_barbers', N'usr_006');

INSERT INTO fin.CommissionRuleItem (RuleId, ItemId) VALUES
    (N'crl_barbers', N'itm_010'),
    (N'crl_barbers', N'itm_011');
GO

PRINT N'09 · Demo data ready.';
GO

/*==============================================================================
  SECTION: 10-seed-history.sql
==============================================================================*/

/*==============================================================================
  Nazad POS — 10 · Six months of trading history

  Posted through fin.usp_PostJournalEntry rather than inserted directly, so the
  seed passes the same balance checks as live data. If this script runs clean,
  the posting path works.

  Shaped so the reports have a story: Riyadh turns over roughly twice Jeddah and
  keeps a healthier margin, which gives the branch comparison something real.
==============================================================================*/

USE POSMAIN;
GO

SET NOCOUNT ON;
GO

DECLARE @MonthOffset INT = 5;          -- start six months back
DECLARE @EntryId NVARCHAR(40);

WHILE @MonthOffset >= 0
BEGIN
    DECLARE @MonthStart DATE =
        DATEFROMPARTS(YEAR(DATEADD(MONTH, -@MonthOffset, SYSUTCDATETIME())),
                      MONTH(DATEADD(MONTH, -@MonthOffset, SYSUTCDATETIME())), 1);
    DECLARE @PostedAt DATETIME2(3) = CAST(@MonthStart AS DATETIME2(3));

    DECLARE @BranchIx INT = 1;

    WHILE @BranchIx <= 2
    BEGIN
        DECLARE @BranchId NVARCHAR(40) = CASE @BranchIx WHEN 1 THEN N'brn_001' ELSE N'brn_002' END;

        /* Gross takings, rising gently, Riyadh roughly two thirds. */
        DECLARE @BaseH BIGINT = 6800000 + (5 - @MonthOffset) * 450000;
        DECLARE @GrossH BIGINT = CASE @BranchIx WHEN 1
                                      THEN CAST(@BaseH * 0.66 AS BIGINT)
                                      ELSE CAST(@BaseH * 0.34 AS BIGINT) END;

        DECLARE @TaxH  BIGINT = fin.fn_VatFromGross(@GrossH, 15.00);
        DECLARE @NetH  BIGINT = @GrossH - @TaxH;
        DECLARE @CardH BIGINT = CAST(@GrossH * 0.54 AS BIGINT);
        DECLARE @CashH BIGINT = CAST(@GrossH * 0.38 AS BIGINT);
        DECLARE @CredH BIGINT = @GrossH - @CardH - @CashH;
        DECLARE @CogsH BIGINT = CAST(@NetH * 0.42 AS BIGINT);

        DECLARE @Lines fin.JournalLineTable;

        /* --- the month's sales --- */
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1000', @CashH, 0, N'Cash'),
            (N'1150', @CardH, 0, N'Card clearing'),
            (N'1400', @CredH, 0, N'Customer credit'),
            (N'4100', 0, @NetH,  N'Sales'),
            (N'2100', 0, @TaxH,  N'Output VAT'),
            (N'5100', @CogsH, 0, N'Cost of goods sold'),
            (N'1200', 0, @CogsH, N'Inventory');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'sale', @DescriptionEn = N'Monthly sales', @DescriptionAr = N'مبيعات الشهر',
            @SourceReference = N'HIST-SALES', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        /* --- rent, weighted so Jeddah's margin is visibly thinner --- */
        DECLARE @RentH BIGINT = CASE @BranchIx WHEN 1 THEN 800000 ELSE 620000 END;
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'6000', @RentH, 0, N'Rent'), (N'1000', 0, @RentH, N'Cash');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense_recognition', @DescriptionEn = N'Rent', @DescriptionAr = N'الإيجار',
            @SourceReference = N'HIST-RENT', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        /* --- salaries --- */
        DECLARE @SalH BIGINT = CASE @BranchIx WHEN 1 THEN 1240000 ELSE 1180000 END;
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'6200', @SalH, 0, N'Salaries'), (N'1100', 0, @SalH, N'Bank');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense_recognition', @DescriptionEn = N'Salaries', @DescriptionAr = N'الرواتب',
            @SourceReference = N'HIST-SAL', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        /* --- utilities --- */
        DECLARE @UtilH BIGINT = CASE @BranchIx WHEN 1 THEN 215000 ELSE 268000 END;
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'6000', @UtilH, 0, N'Utilities'), (N'1000', 0, @UtilH, N'Cash');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense_recognition', @DescriptionEn = N'Utilities', @DescriptionAr = N'المرافق',
            @SourceReference = N'HIST-UTIL', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        /* --- the bank settles the card takings, less its fee --- */
        DECLARE @FeeH BIGINT = CAST(@CardH * 0.015 AS BIGINT);
        DELETE FROM @Lines;
        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1100', @CardH - @FeeH, 0, N'Bank deposit'),
            (N'6100', @FeeH, 0, N'Card fees'),
            (N'1150', 0, @CardH, N'Card clearing');

        EXEC fin.usp_PostJournalEntry
            @Kind = N'card_settlement', @DescriptionEn = N'Card settlement', @DescriptionAr = N'تسوية الشبكة',
            @SourceReference = N'HIST-SET', @BranchId = @BranchId, @Actor = N'System',
            @PostedAtUtc = @PostedAt, @Lines = @Lines, @EntryId = @EntryId OUTPUT;

        SET @BranchIx += 1;
    END

    SET @MonthOffset -= 1;
END
GO

/* A prepaid expense, to exercise the accrual path: a year of insurance paid up
   front is one cash movement and twelve monthly costs. */
DECLARE @InsId NVARCHAR(40) = N'exp_insurance_demo';

INSERT INTO fin.Expense
    (ExpenseId, Reference, CategoryId, BranchId, DescriptionAr, DescriptionEn,
     AmountH, VatH, PaymentMethod, PaidOn, Recognition, PeriodStart, PeriodEnd, CreatedBy)
VALUES
    (@InsId, N'EXP-401', N'exc_ins', N'brn_001',
     N'تأمين سنوي', N'Annual insurance',
     1200000, 0, N'bank',
     DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 1, 1), N'yearly',
     DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 1, 1),
     DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 12, 31),
     N'System');

EXEC fin.usp_BuildExpenseRecognition @ExpenseId = @InsId;
GO

PRINT N'10 · Trading history ready.';
GO

/*------------------------------------------------------------------ sanity */

DECLARE @Unbalanced INT = (SELECT COUNT(*) FROM fin.vw_TrialBalanceCheck);
IF @Unbalanced > 0
    THROW 51100, N'Ledger does not balance after seeding. Investigate before use.', 1;

DECLARE @Slices BIGINT = (SELECT SUM(AmountH) FROM fin.ExpenseRecognition WHERE ExpenseId = N'exp_insurance_demo');
IF @Slices <> 1200000
    THROW 51101, N'Expense recognition slices do not sum to the amount paid.', 1;

PRINT N'    Ledger balances.';
PRINT N'    Recognition slices reconcile.';
GO

/*==============================================================================
  DONE
==============================================================================*/

USE POSMAIN;
GO

PRINT N'';
PRINT N'================================================';
PRINT N'  Nazad POS — migration complete';
PRINT N'================================================';

SELECT N'Tables'      AS Object, COUNT(*) AS Count FROM sys.tables
UNION ALL SELECT N'Views',       COUNT(*) FROM sys.views
UNION ALL SELECT N'Procedures',  COUNT(*) FROM sys.procedures
UNION ALL SELECT N'Branches',    COUNT(*) FROM core.Branch
UNION ALL SELECT N'Users',       COUNT(*) FROM core.AppUser
UNION ALL SELECT N'Permissions', COUNT(*) FROM core.Permission
UNION ALL SELECT N'Catalog',     COUNT(*) FROM core.CatalogItem
UNION ALL SELECT N'Accounts',    COUNT(*) FROM fin.Account
UNION ALL SELECT N'Entries',     COUNT(*) FROM fin.JournalEntry
UNION ALL SELECT N'Languages',   COUNT(*) FROM core.Language;
GO

/* Arabic must survive the round trip. If this prints question marks, the
   collation or the client encoding is wrong, not the data. */
SELECT TOP (3) ItemId, NameAr, NameEn FROM core.CatalogItem ORDER BY ItemId;
GO
