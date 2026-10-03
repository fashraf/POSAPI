/*==============================================================================
  Nazad POS — 001 · Baseline schema

  The whole database as it stands after every earlier migration (11–43 and the
  original nazad-posmain-full.sql), generated from a fully migrated database in
  dependency order: schemas, sequences, table types, tables, constraints,
  indexes, functions, views and procedures.

  It replaces those files. They redefined the same procedures several times
  (usp_CommitSale alone was rewritten in 12, 20, 41 and 42), mixed run-once
  and re-runnable scripts, and could only be applied in one exact order — a
  database that missed one step failed on the next.

  Runs once, on a database with no objects: apply-migrations.cmd creates
  POSMAIN, runs this, and records it. Reference data is in 002; demo data is
  the optional 900.
==============================================================================*/

USE master;
GO

IF DB_ID(N'POSMAIN') IS NULL
BEGIN
    /* NVARCHAR everywhere, so the collation decides sorting and comparison,
       not whether Arabic survives — but sorting Arabic correctly matters. */
    CREATE DATABASE POSMAIN COLLATE Arabic_CI_AS;
END
GO

ALTER DATABASE POSMAIN SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO

USE POSMAIN;
GO

/* Refuse to run over an existing schema: CREATE would fail half-way and leave
   a mixture. An existing database is brought in with --adopt or --recreate. */
IF SCHEMA_ID(N'core') IS NOT NULL
    THROW 50001, N'POSMAIN already has a schema. 001 only runs on an empty database.', 1;
GO

SET ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT, CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

PRINT N'Creating Schema [audit]...';


GO
CREATE SCHEMA [audit]
    AUTHORIZATION [dbo];


GO
PRINT N'Creating Schema [core]...';


GO
CREATE SCHEMA [core]
    AUTHORIZATION [dbo];


GO
PRINT N'Creating Schema [device]...';


GO
CREATE SCHEMA [device]
    AUTHORIZATION [dbo];


GO
PRINT N'Creating Schema [fin]...';


GO
CREATE SCHEMA [fin]
    AUTHORIZATION [dbo];


GO
PRINT N'Creating Schema [inv]...';


GO
CREATE SCHEMA [inv]
    AUTHORIZATION [dbo];


GO
PRINT N'Creating Schema [sales]...';


GO
CREATE SCHEMA [sales]
    AUTHORIZATION [dbo];


GO
PRINT N'Creating User-Defined Table Type [fin].[JournalLineTable]...';


GO
CREATE TYPE [fin].[JournalLineTable] AS TABLE (
    [AccountCode] NVARCHAR (10)  NOT NULL,
    [DebitH]      BIGINT         DEFAULT ((0)) NOT NULL,
    [CreditH]     BIGINT         DEFAULT ((0)) NOT NULL,
    [Memo]        NVARCHAR (400) NULL);


GO
PRINT N'Creating User-Defined Table Type [inv].[PurchaseLineTable]...';


GO
CREATE TYPE [inv].[PurchaseLineTable] AS TABLE (
    [ItemId]    NVARCHAR (40)   NOT NULL,
    [Quantity]  DECIMAL (18, 3) NOT NULL,
    [UnitCostH] BIGINT          NOT NULL);


GO
PRINT N'Creating User-Defined Table Type [sales].[ReturnLineTable]...';


GO
CREATE TYPE [sales].[ReturnLineTable] AS TABLE (
    [SaleLineId] BIGINT          NOT NULL,
    [Quantity]   DECIMAL (18, 3) NOT NULL);


GO
PRINT N'Creating User-Defined Table Type [sales].[SaleLineTable]...';


GO
CREATE TYPE [sales].[SaleLineTable] AS TABLE (
    [ItemId]        NVARCHAR (40)   NOT NULL,
    [Quantity]      DECIMAL (18, 3) NOT NULL,
    [UnitPriceH]    BIGINT          NOT NULL,
    [LineDiscountH] BIGINT          DEFAULT ((0)) NOT NULL,
    [Note]          NVARCHAR (400)  NULL);


GO
PRINT N'Creating User-Defined Table Type [sales].[SalePaymentTable]...';


GO
CREATE TYPE [sales].[SalePaymentTable] AS TABLE (
    [Method]    NVARCHAR (20) NOT NULL,
    [AmountH]   BIGINT        NOT NULL,
    [Reference] NVARCHAR (80) NULL);


GO
PRINT N'Creating Table [audit].[RequestTiming]...';


GO
CREATE TABLE [audit].[RequestTiming] (
    [TimingId]      BIGINT         IDENTITY (1, 1) NOT NULL,
    [CorrelationId] NVARCHAR (40)  NOT NULL,
    [UserId]        NVARCHAR (40)  NULL,
    [Username]      NVARCHAR (120) NULL,
    [ApiPath]       NVARCHAR (300) NOT NULL,
    [HttpMethod]    NVARCHAR (10)  NOT NULL,
    [CurrentPage]   NVARCHAR (200) NULL,
    [PreviousPage]  NVARCHAR (200) NULL,
    [TotalMs]       INT            NOT NULL,
    [DatabaseMs]    INT            NOT NULL,
    [QueryCount]    INT            NOT NULL,
    [StatusCode]    INT            NOT NULL,
    [Succeeded]     BIT            NOT NULL,
    [ErrorMessage]  NVARCHAR (600) NULL,
    [ResponseBytes] INT            NULL,
    [OccurredAtUtc] DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_RequestTiming] PRIMARY KEY CLUSTERED ([TimingId] ASC)
);


GO
PRINT N'Creating Index [audit].[RequestTiming].[IX_Timing_Slow]...';


GO
CREATE NONCLUSTERED INDEX [IX_Timing_Slow]
    ON [audit].[RequestTiming]([TotalMs] DESC)
    INCLUDE([ApiPath], [HttpMethod], [OccurredAtUtc]);


GO
PRINT N'Creating Index [audit].[RequestTiming].[IX_Timing_Time]...';


GO
CREATE NONCLUSTERED INDEX [IX_Timing_Time]
    ON [audit].[RequestTiming]([OccurredAtUtc] DESC)
    INCLUDE([ApiPath], [TotalMs], [StatusCode]);


GO
PRINT N'Creating Table [audit].[QueryTiming]...';


GO
CREATE TABLE [audit].[QueryTiming] (
    [QueryTimingId]  BIGINT          IDENTITY (1, 1) NOT NULL,
    [CorrelationId]  NVARCHAR (40)   NOT NULL,
    [QueryType]      NVARCHAR (20)   NOT NULL,
    [CommandText]    NVARCHAR (2000) NOT NULL,
    [ParameterNames] NVARCHAR (600)  NULL,
    [DurationMs]     INT             NOT NULL,
    [RowsAffected]   INT             NULL,
    [Succeeded]      BIT             NOT NULL,
    [OccurredAtUtc]  DATETIME2 (3)   NOT NULL,
    CONSTRAINT [PK_QueryTiming] PRIMARY KEY CLUSTERED ([QueryTimingId] ASC)
);


GO
PRINT N'Creating Index [audit].[QueryTiming].[IX_QueryTiming_Slow]...';


GO
CREATE NONCLUSTERED INDEX [IX_QueryTiming_Slow]
    ON [audit].[QueryTiming]([DurationMs] DESC)
    INCLUDE([CommandText], [OccurredAtUtc]);


GO
PRINT N'Creating Index [audit].[QueryTiming].[IX_QueryTiming_Correlation]...';


GO
CREATE NONCLUSTERED INDEX [IX_QueryTiming_Correlation]
    ON [audit].[QueryTiming]([CorrelationId] ASC);


GO
PRINT N'Creating Table [audit].[AuditEntry]...';


GO
CREATE TABLE [audit].[AuditEntry] (
    [AuditId]       BIGINT         IDENTITY (1, 1) NOT NULL,
    [UserId]        NVARCHAR (40)  NULL,
    [Username]      NVARCHAR (120) NULL,
    [RoleId]        NVARCHAR (40)  NULL,
    [Action]        NVARCHAR (30)  NOT NULL,
    [Module]        NVARCHAR (60)  NOT NULL,
    [EntityType]    NVARCHAR (60)  NULL,
    [EntityId]      NVARCHAR (80)  NULL,
    [ApiPath]       NVARCHAR (300) NULL,
    [HttpMethod]    NVARCHAR (10)  NULL,
    [CurrentPage]   NVARCHAR (200) NULL,
    [PreviousPage]  NVARCHAR (200) NULL,
    [BranchId]      NVARCHAR (40)  NULL,
    [OldValue]      NVARCHAR (MAX) NULL,
    [NewValue]      NVARCHAR (MAX) NULL,
    [Details]       NVARCHAR (MAX) NULL,
    [Result]        NVARCHAR (20)  NOT NULL,
    [StatusCode]    INT            NULL,
    [ErrorMessage]  NVARCHAR (600) NULL,
    [IpAddress]     NVARCHAR (60)  NULL,
    [UserAgent]     NVARCHAR (400) NULL,
    [CorrelationId] NVARCHAR (40)  NULL,
    [OccurredAtUtc] DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_AuditEntry] PRIMARY KEY CLUSTERED ([AuditId] ASC)
);


GO
PRINT N'Creating Index [audit].[AuditEntry].[IX_Audit_User]...';


GO
CREATE NONCLUSTERED INDEX [IX_Audit_User]
    ON [audit].[AuditEntry]([UserId] ASC, [OccurredAtUtc] DESC);


GO
PRINT N'Creating Index [audit].[AuditEntry].[IX_Audit_Entity]...';


GO
CREATE NONCLUSTERED INDEX [IX_Audit_Entity]
    ON [audit].[AuditEntry]([EntityType] ASC, [EntityId] ASC, [OccurredAtUtc] DESC);


GO
PRINT N'Creating Index [audit].[AuditEntry].[IX_Audit_Time]...';


GO
CREATE NONCLUSTERED INDEX [IX_Audit_Time]
    ON [audit].[AuditEntry]([OccurredAtUtc] DESC)
    INCLUDE([UserId], [Action], [Module], [Result]);


GO
PRINT N'Creating Index [audit].[AuditEntry].[IX_Audit_Module]...';


GO
CREATE NONCLUSTERED INDEX [IX_Audit_Module]
    ON [audit].[AuditEntry]([Module] ASC, [OccurredAtUtc] DESC);


GO
PRINT N'Creating Table [core].[Category]...';


GO
CREATE TABLE [core].[Category] (
    [CategoryId]   NVARCHAR (40)  NOT NULL,
    [NameAr]       NVARCHAR (120) NOT NULL,
    [NameEn]       NVARCHAR (120) NOT NULL,
    [SortOrder]    INT            NOT NULL,
    [IsActive]     BIT            NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NOT NULL,
    [AppliesTo]    NVARCHAR (10)  NOT NULL,
    CONSTRAINT [PK_Category] PRIMARY KEY CLUSTERED ([CategoryId] ASC)
);


GO
PRINT N'Creating Table [core].[Customer]...';


GO
CREATE TABLE [core].[Customer] (
    [CustomerId]   NVARCHAR (40)  NOT NULL,
    [NameAr]       NVARCHAR (160) NOT NULL,
    [NameEn]       NVARCHAR (160) NOT NULL,
    [Phone]        NVARCHAR (30)  NULL,
    [Email]        NVARCHAR (160) NULL,
    [VatNumber]    NVARCHAR (15)  NULL,
    [CustomerType] NVARCHAR (20)  NOT NULL,
    [CreditLimitH] BIGINT         NOT NULL,
    [BalanceH]     BIGINT         NOT NULL,
    [IsActive]     BIT            NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    [CreatedBy]    NVARCHAR (120) NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NOT NULL,
    [UpdatedBy]    NVARCHAR (120) NULL,
    CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([CustomerId] ASC)
);


GO
PRINT N'Creating Index [core].[Customer].[IX_Customer_Phone]...';


GO
CREATE NONCLUSTERED INDEX [IX_Customer_Phone]
    ON [core].[Customer]([Phone] ASC) WHERE ([Phone] IS NOT NULL);


GO
PRINT N'Creating Index [core].[Customer].[IX_Customer_Owing]...';


GO
CREATE NONCLUSTERED INDEX [IX_Customer_Owing]
    ON [core].[Customer]([BalanceH] ASC) WHERE ([BalanceH]>(0));


GO
PRINT N'Creating Table [core].[Translation]...';


GO
CREATE TABLE [core].[Translation] (
    [TranslationId] BIGINT         IDENTITY (1, 1) NOT NULL,
    [EntityType]    NVARCHAR (60)  NOT NULL,
    [EntityKey]     NVARCHAR (60)  NOT NULL,
    [FieldName]     NVARCHAR (60)  NOT NULL,
    [LanguageCode]  NVARCHAR (10)  NOT NULL,
    [Value]         NVARCHAR (400) NOT NULL,
    [UpdatedAtUtc]  DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_Translation] PRIMARY KEY CLUSTERED ([TranslationId] ASC),
    CONSTRAINT [UQ_Translation] UNIQUE NONCLUSTERED ([EntityType] ASC, [EntityKey] ASC, [FieldName] ASC, [LanguageCode] ASC)
);


GO
PRINT N'Creating Index [core].[Translation].[IX_Translation_Lookup]...';


GO
CREATE NONCLUSTERED INDEX [IX_Translation_Lookup]
    ON [core].[Translation]([EntityType] ASC, [EntityKey] ASC, [LanguageCode] ASC)
    INCLUDE([FieldName], [Value]);


GO
PRINT N'Creating Table [core].[Language]...';


GO
CREATE TABLE [core].[Language] (
    [Code]       NVARCHAR (10) NOT NULL,
    [NameNative] NVARCHAR (60) NOT NULL,
    [NameEn]     NVARCHAR (60) NOT NULL,
    [IsRtl]      BIT           NOT NULL,
    [IsActive]   BIT           NOT NULL,
    [SortOrder]  INT           NOT NULL,
    CONSTRAINT [PK_Language] PRIMARY KEY CLUSTERED ([Code] ASC)
);


GO
PRINT N'Creating Table [core].[Notification]...';


GO
CREATE TABLE [core].[Notification] (
    [NotificationId] NVARCHAR (40)  NOT NULL,
    [UserId]         NVARCHAR (40)  NULL,
    [BranchId]       NVARCHAR (40)  NULL,
    [Kind]           NVARCHAR (40)  NOT NULL,
    [Severity]       NVARCHAR (20)  NOT NULL,
    [TitleAr]        NVARCHAR (200) NOT NULL,
    [TitleEn]        NVARCHAR (200) NOT NULL,
    [BodyAr]         NVARCHAR (600) NULL,
    [BodyEn]         NVARCHAR (600) NULL,
    [LinkPath]       NVARCHAR (200) NULL,
    [ReadAtUtc]      DATETIME2 (3)  NULL,
    [CreatedAtUtc]   DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_Notification] PRIMARY KEY CLUSTERED ([NotificationId] ASC)
);


GO
PRINT N'Creating Index [core].[Notification].[IX_Notification_Unread]...';


GO
CREATE NONCLUSTERED INDEX [IX_Notification_Unread]
    ON [core].[Notification]([UserId] ASC, [CreatedAtUtc] DESC) WHERE ([ReadAtUtc] IS NULL);


GO
PRINT N'Creating Table [core].[Role]...';


GO
CREATE TABLE [core].[Role] (
    [RoleId]        NVARCHAR (40)  NOT NULL,
    [NameAr]        NVARCHAR (120) NOT NULL,
    [NameEn]        NVARCHAR (120) NOT NULL,
    [DescriptionAr] NVARCHAR (400) NULL,
    [DescriptionEn] NVARCHAR (400) NULL,
    [IsBuiltIn]     BIT            NOT NULL,
    [IsExternal]    BIT            NOT NULL,
    [CreatedAtUtc]  DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc]  DATETIME2 (3)  NOT NULL,
    [IsActive]      BIT            NOT NULL,
    CONSTRAINT [PK_Role] PRIMARY KEY CLUSTERED ([RoleId] ASC)
);


GO
PRINT N'Creating Table [core].[Branch]...';


GO
CREATE TABLE [core].[Branch] (
    [BranchId]     NVARCHAR (40)  NOT NULL,
    [Code]         NVARCHAR (20)  NOT NULL,
    [NameAr]       NVARCHAR (160) NOT NULL,
    [NameEn]       NVARCHAR (160) NOT NULL,
    [Phone]        NVARCHAR (30)  NULL,
    [AddressAr]    NVARCHAR (300) NULL,
    [AddressEn]    NVARCHAR (300) NULL,
    [IsActive]     BIT            NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_Branch] PRIMARY KEY CLUSTERED ([BranchId] ASC),
    CONSTRAINT [UQ_Branch_Code] UNIQUE NONCLUSTERED ([Code] ASC)
);


GO
PRINT N'Creating Table [core].[UserPermissionOverride]...';


GO
CREATE TABLE [core].[UserPermissionOverride] (
    [UserId]        NVARCHAR (40) NOT NULL,
    [PermissionKey] NVARCHAR (60) NOT NULL,
    [Effect]        NVARCHAR (10) NOT NULL,
    CONSTRAINT [PK_UserOverride] PRIMARY KEY CLUSTERED ([UserId] ASC, [PermissionKey] ASC)
);


GO
PRINT N'Creating Table [core].[PrintGroup]...';


GO
CREATE TABLE [core].[PrintGroup] (
    [PrintGroupId] NVARCHAR (40)  NOT NULL,
    [NameAr]       NVARCHAR (120) NOT NULL,
    [NameEn]       NVARCHAR (120) NOT NULL,
    [TicketTitle]  NVARCHAR (120) NOT NULL,
    [SortOrder]    INT            NOT NULL,
    [IsActive]     BIT            NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_PrintGroup] PRIMARY KEY CLUSTERED ([PrintGroupId] ASC)
);


GO
PRINT N'Creating Table [core].[RolePermission]...';


GO
CREATE TABLE [core].[RolePermission] (
    [RoleId]        NVARCHAR (40) NOT NULL,
    [PermissionKey] NVARCHAR (60) NOT NULL,
    CONSTRAINT [PK_RolePermission] PRIMARY KEY CLUSTERED ([RoleId] ASC, [PermissionKey] ASC)
);


GO
PRINT N'Creating Table [core].[LoginAttempt]...';


GO
CREATE TABLE [core].[LoginAttempt] (
    [AttemptId]      BIGINT         IDENTITY (1, 1) NOT NULL,
    [Identifier]     NVARCHAR (160) NOT NULL,
    [Succeeded]      BIT            NOT NULL,
    [IpAddress]      NVARCHAR (60)  NULL,
    [UserAgent]      NVARCHAR (300) NULL,
    [AttemptedAtUtc] DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_LoginAttempt] PRIMARY KEY CLUSTERED ([AttemptId] ASC)
);


GO
PRINT N'Creating Index [core].[LoginAttempt].[IX_LoginAttempt_Identifier]...';


GO
CREATE NONCLUSTERED INDEX [IX_LoginAttempt_Identifier]
    ON [core].[LoginAttempt]([Identifier] ASC, [AttemptedAtUtc] DESC)
    INCLUDE([Succeeded]);


GO
PRINT N'Creating Table [core].[UserBranch]...';


GO
CREATE TABLE [core].[UserBranch] (
    [UserId]   NVARCHAR (40) NOT NULL,
    [BranchId] NVARCHAR (40) NOT NULL,
    CONSTRAINT [PK_UserBranch] PRIMARY KEY CLUSTERED ([UserId] ASC, [BranchId] ASC)
);


GO
PRINT N'Creating Table [core].[Company]...';


GO
CREATE TABLE [core].[Company] (
    [CompanyId]     INT             IDENTITY (1, 1) NOT NULL,
    [NameAr]        NVARCHAR (160)  NOT NULL,
    [NameEn]        NVARCHAR (160)  NOT NULL,
    [DescriptionAr] NVARCHAR (400)  NULL,
    [DescriptionEn] NVARCHAR (400)  NULL,
    [LogoUrl]       NVARCHAR (400)  NULL,
    [CrNumber]      NVARCHAR (10)   NULL,
    [VatNumber]     NVARCHAR (15)   NULL,
    [Phone]         NVARCHAR (30)   NULL,
    [Email]         NVARCHAR (160)  NULL,
    [Website]       NVARCHAR (160)  NULL,
    [Street]        NVARCHAR (160)  NULL,
    [District]      NVARCHAR (120)  NULL,
    [City]          NVARCHAR (120)  NULL,
    [PostalCode]    NVARCHAR (12)   NULL,
    [Country]       NVARCHAR (80)   NULL,
    [CreatedAtUtc]  DATETIME2 (3)   NOT NULL,
    [UpdatedAtUtc]  DATETIME2 (3)   NOT NULL,
    [SocialLinks]   NVARCHAR (2000) NULL,
    CONSTRAINT [PK_Company] PRIMARY KEY CLUSTERED ([CompanyId] ASC)
);


GO
PRINT N'Creating Table [core].[Vendor]...';


GO
CREATE TABLE [core].[Vendor] (
    [VendorId]        NVARCHAR (40)  NOT NULL,
    [NameAr]          NVARCHAR (160) NOT NULL,
    [NameEn]          NVARCHAR (160) NOT NULL,
    [ContactPerson]   NVARCHAR (160) NULL,
    [Phone]           NVARCHAR (30)  NULL,
    [Email]           NVARCHAR (160) NULL,
    [VatNumber]       NVARCHAR (15)  NULL,
    [PaymentTermDays] INT            NOT NULL,
    [IsActive]        BIT            NOT NULL,
    [CreatedAtUtc]    DATETIME2 (3)  NOT NULL,
    [CreatedBy]       NVARCHAR (120) NULL,
    [UpdatedAtUtc]    DATETIME2 (3)  NOT NULL,
    [UpdatedBy]       NVARCHAR (120) NULL,
    [City]            NVARCHAR (120) NULL,
    CONSTRAINT [PK_Vendor] PRIMARY KEY CLUSTERED ([VendorId] ASC)
);


GO
PRINT N'Creating Table [core].[BranchSettings]...';


GO
CREATE TABLE [core].[BranchSettings] (
    [BranchId]            NVARCHAR (40)  NOT NULL,
    [DefaultCustomerMode] NVARCHAR (20)  NOT NULL,
    [ServedByRequirement] NVARCHAR (20)  NOT NULL,
    [AllowNegativeStock]  BIT            NOT NULL,
    [DefaultBillId]       NVARCHAR (40)  NULL,
    [AutoPrintCustomer]   BIT            NOT NULL,
    [AutoPrintGroups]     BIT            NOT NULL,
    [VatRatePercent]      DECIMAL (5, 2) NOT NULL,
    [PricesIncludeVat]    BIT            NOT NULL,
    [UpdatedAtUtc]        DATETIME2 (3)  NOT NULL,
    [UpdatedBy]           NVARCHAR (120) NULL,
    CONSTRAINT [PK_BranchSettings] PRIMARY KEY CLUSTERED ([BranchId] ASC)
);


GO
PRINT N'Creating Table [core].[RefreshToken]...';


GO
CREATE TABLE [core].[RefreshToken] (
    [TokenHash]    NVARCHAR (200) NOT NULL,
    [UserId]       NVARCHAR (40)  NOT NULL,
    [IssuedAtUtc]  DATETIME2 (3)  NOT NULL,
    [ExpiresAtUtc] DATETIME2 (3)  NOT NULL,
    [RevokedAtUtc] DATETIME2 (3)  NULL,
    [UserAgent]    NVARCHAR (300) NULL,
    [IpAddress]    NVARCHAR (60)  NULL,
    CONSTRAINT [PK_RefreshToken] PRIMARY KEY CLUSTERED ([TokenHash] ASC)
);


GO
PRINT N'Creating Index [core].[RefreshToken].[IX_RefreshToken_User]...';


GO
CREATE NONCLUSTERED INDEX [IX_RefreshToken_User]
    ON [core].[RefreshToken]([UserId] ASC) WHERE ([RevokedAtUtc] IS NULL);


GO
PRINT N'Creating Table [core].[AppUser]...';


GO
CREATE TABLE [core].[AppUser] (
    [UserId]          NVARCHAR (40)  NOT NULL,
    [Username]        NVARCHAR (60)  NOT NULL,
    [NameAr]          NVARCHAR (160) NOT NULL,
    [NameEn]          NVARCHAR (160) NOT NULL,
    [Email]           NVARCHAR (160) NULL,
    [Phone]           NVARCHAR (30)  NULL,
    [RoleId]          NVARCHAR (40)  NOT NULL,
    [PasswordHash]    NVARCHAR (400) NULL,
    [PasswordSalt]    NVARCHAR (200) NULL,
    [Status]          NVARCHAR (20)  NOT NULL,
    [IsExternal]      BIT            NOT NULL,
    [AccessExpiresOn] DATE           NULL,
    [BaseSalaryH]     BIGINT         NOT NULL,
    [LastLoginAtUtc]  DATETIME2 (3)  NULL,
    [CreatedAtUtc]    DATETIME2 (3)  NOT NULL,
    [CreatedBy]       NVARCHAR (120) NULL,
    [UpdatedAtUtc]    DATETIME2 (3)  NOT NULL,
    [UpdatedBy]       NVARCHAR (120) NULL,
    [FirstName]       NVARCHAR (100) NULL,
    [LastName]        NVARCHAR (100) NULL,
    [Address]         NVARCHAR (400) NULL,
    [EmployeeId]      NVARCHAR (40)  NULL,
    [AvatarUrl]       NVARCHAR (400) NULL,
    [DefaultBranchId] NVARCHAR (40)  NULL,
    [TicketReference] NVARCHAR (120) NULL,
    CONSTRAINT [PK_AppUser] PRIMARY KEY CLUSTERED ([UserId] ASC),
    CONSTRAINT [UQ_AppUser_Username] UNIQUE NONCLUSTERED ([Username] ASC)
);


GO
PRINT N'Creating Table [core].[CatalogItem]...';


GO
CREATE TABLE [core].[CatalogItem] (
    [ItemId]              NVARCHAR (40)  NOT NULL,
    [Kind]                NVARCHAR (20)  NOT NULL,
    [NameAr]              NVARCHAR (200) NOT NULL,
    [NameEn]              NVARCHAR (200) NOT NULL,
    [DescriptionAr]       NVARCHAR (600) NULL,
    [DescriptionEn]       NVARCHAR (600) NULL,
    [Sku]                 NVARCHAR (60)  NULL,
    [Barcode]             NVARCHAR (60)  NULL,
    [CategoryId]          NVARCHAR (40)  NULL,
    [VendorId]            NVARCHAR (40)  NULL,
    [PrintGroupId]        NVARCHAR (40)  NULL,
    [PriceH]              BIGINT         NOT NULL,
    [CostH]               BIGINT         NOT NULL,
    [TracksStock]         BIT            NOT NULL,
    [ReorderLevel]        INT            NOT NULL,
    [RequiresPreparation] BIT            NOT NULL,
    [IsActive]            BIT            NOT NULL,
    [CreatedAtUtc]        DATETIME2 (3)  NOT NULL,
    [CreatedBy]           NVARCHAR (120) NULL,
    [UpdatedAtUtc]        DATETIME2 (3)  NOT NULL,
    [UpdatedBy]           NVARCHAR (120) NULL,
    CONSTRAINT [PK_CatalogItem] PRIMARY KEY CLUSTERED ([ItemId] ASC)
);


GO
PRINT N'Creating Index [core].[CatalogItem].[UX_CatalogItem_Barcode]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_CatalogItem_Barcode]
    ON [core].[CatalogItem]([Barcode] ASC) WHERE ([Barcode] IS NOT NULL);


GO
PRINT N'Creating Index [core].[CatalogItem].[IX_CatalogItem_Search]...';


GO
CREATE NONCLUSTERED INDEX [IX_CatalogItem_Search]
    ON [core].[CatalogItem]([IsActive] ASC, [Kind] ASC)
    INCLUDE([NameAr], [NameEn], [PriceH], [CategoryId]);


GO
PRINT N'Creating Index [core].[CatalogItem].[UX_CatalogItem_Sku]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_CatalogItem_Sku]
    ON [core].[CatalogItem]([Sku] ASC) WHERE ([Sku] IS NOT NULL);


GO
PRINT N'Creating Table [core].[BillTemplate]...';


GO
CREATE TABLE [core].[BillTemplate] (
    [BillId]           NVARCHAR (40)  NOT NULL,
    [Name]             NVARCHAR (160) NOT NULL,
    [Audience]         NVARCHAR (20)  NOT NULL,
    [PrintGroupId]     NVARCHAR (40)  NULL,
    [IsDefault]        BIT            NOT NULL,
    [PaperSize]        NVARCHAR (10)  NOT NULL,
    [BillLanguage]     NVARCHAR (10)  NOT NULL,
    [ShowLogo]         BIT            NOT NULL,
    [ShowVatNumber]    BIT            NOT NULL,
    [ShowCrNumber]     BIT            NOT NULL,
    [ShowUnitPrice]    BIT            NOT NULL,
    [ShowLineTotal]    BIT            NOT NULL,
    [ShowSubtotal]     BIT            NOT NULL,
    [ShowDiscount]     BIT            NOT NULL,
    [ShowVat]          BIT            NOT NULL,
    [ShowGrandTotal]   BIT            NOT NULL,
    [ShowZatcaQr]      BIT            NOT NULL,
    [FooterAr]         NVARCHAR (400) NULL,
    [FooterEn]         NVARCHAR (400) NULL,
    [IsActive]         BIT            NOT NULL,
    [CreatedAtUtc]     DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc]     DATETIME2 (3)  NOT NULL,
    [HeaderAlignment]  NVARCHAR (10)  NOT NULL,
    [LogoSize]         NVARCHAR (4)   NOT NULL,
    [ShowCompanyName]  BIT            NOT NULL,
    [ShowDescription]  BIT            NOT NULL,
    [ShowAddress]      BIT            NOT NULL,
    [ShowItemName]     BIT            NOT NULL,
    [ShowSku]          BIT            NOT NULL,
    [ShowBarcode]      BIT            NOT NULL,
    [ShowQuantity]     BIT            NOT NULL,
    [ShowLineDiscount] BIT            NOT NULL,
    CONSTRAINT [PK_BillTemplate] PRIMARY KEY CLUSTERED ([BillId] ASC)
);


GO
PRINT N'Creating Table [core].[OtpChallenge]...';


GO
CREATE TABLE [core].[OtpChallenge] (
    [ChallengeId]   NVARCHAR (64)  NOT NULL,
    [Identifier]    NVARCHAR (160) NOT NULL,
    [Purpose]       NVARCHAR (40)  NOT NULL,
    [CodeHash]      NVARCHAR (400) NOT NULL,
    [CodeSalt]      NVARCHAR (200) NOT NULL,
    [ExpiresAtUtc]  DATETIME2 (3)  NOT NULL,
    [Attempts]      INT            NOT NULL,
    [ConsumedAtUtc] DATETIME2 (3)  NULL,
    [CreatedAtUtc]  DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_OtpChallenge] PRIMARY KEY CLUSTERED ([ChallengeId] ASC)
);


GO
PRINT N'Creating Index [core].[OtpChallenge].[IX_Otp_Expiry]...';


GO
CREATE NONCLUSTERED INDEX [IX_Otp_Expiry]
    ON [core].[OtpChallenge]([ExpiresAtUtc] ASC) WHERE ([ConsumedAtUtc] IS NULL);


GO
PRINT N'Creating Index [core].[OtpChallenge].[IX_Otp_Identifier]...';


GO
CREATE NONCLUSTERED INDEX [IX_Otp_Identifier]
    ON [core].[OtpChallenge]([Identifier] ASC, [CreatedAtUtc] DESC);


GO
PRINT N'Creating Table [core].[Permission]...';


GO
CREATE TABLE [core].[Permission] (
    [PermissionKey] NVARCHAR (60) NOT NULL,
    [Module]        NVARCHAR (40) NOT NULL,
    [Action]        NVARCHAR (40) NOT NULL,
    [Sensitivity]   NVARCHAR (20) NOT NULL,
    CONSTRAINT [PK_Permission] PRIMARY KEY CLUSTERED ([PermissionKey] ASC)
);


GO
PRINT N'Creating Table [device].[DeviceHeartbeat]...';


GO
CREATE TABLE [device].[DeviceHeartbeat] (
    [HeartbeatId]    BIGINT         IDENTITY (1, 1) NOT NULL,
    [DeviceId]       NVARCHAR (40)  NOT NULL,
    [ReceivedAtUtc]  DATETIME2 (0)  NOT NULL,
    [PrinterStatus]  NVARCHAR (20)  NOT NULL,
    [PaperStatus]    NVARCHAR (20)  NOT NULL,
    [PrinterError]   NVARCHAR (200) NULL,
    [BatteryPercent] INT            NULL,
    [NetworkType]    NVARCHAR (20)  NULL,
    [AppVersion]     NVARCHAR (40)  NULL,
    CONSTRAINT [PK_DeviceHeartbeat] PRIMARY KEY CLUSTERED ([HeartbeatId] ASC)
);


GO
PRINT N'Creating Index [device].[DeviceHeartbeat].[IX_Heartbeat_Device]...';


GO
CREATE NONCLUSTERED INDEX [IX_Heartbeat_Device]
    ON [device].[DeviceHeartbeat]([DeviceId] ASC, [ReceivedAtUtc] DESC);


GO
PRINT N'Creating Table [device].[DeviceAnnouncement]...';


GO
CREATE TABLE [device].[DeviceAnnouncement] (
    [AnnouncementId]  BIGINT         IDENTITY (1, 1) NOT NULL,
    [ClaimedDeviceId] NVARCHAR (40)  NULL,
    [DeviceName]      NVARCHAR (120) NULL,
    [Manufacturer]    NVARCHAR (60)  NULL,
    [DeviceModel]     NVARCHAR (60)  NULL,
    [SerialNumber]    NVARCHAR (80)  NOT NULL,
    [AndroidId]       NVARCHAR (80)  NULL,
    [AppVersion]      NVARCHAR (40)  NULL,
    [LocalIpAddress]  NVARCHAR (45)  NULL,
    [NetworkName]     NVARCHAR (120) NULL,
    [SourceIpAddress] NVARCHAR (45)  NULL,
    [FirstSeenAtUtc]  DATETIME2 (0)  NOT NULL,
    [LastSeenAtUtc]   DATETIME2 (0)  NOT NULL,
    CONSTRAINT [PK_DeviceAnnouncement] PRIMARY KEY CLUSTERED ([AnnouncementId] ASC),
    CONSTRAINT [UX_Announcement_Serial] UNIQUE NONCLUSTERED ([SerialNumber] ASC)
);


GO
PRINT N'Creating Index [device].[DeviceAnnouncement].[IX_Announcement_Recent]...';


GO
CREATE NONCLUSTERED INDEX [IX_Announcement_Recent]
    ON [device].[DeviceAnnouncement]([LastSeenAtUtc] DESC);


GO
PRINT N'Creating Table [device].[PosDevice]...';


GO
CREATE TABLE [device].[PosDevice] (
    [DeviceId]           NVARCHAR (40)  NOT NULL,
    [DeviceName]         NVARCHAR (120) NOT NULL,
    [DeviceType]         NVARCHAR (40)  NOT NULL,
    [DeviceModel]        NVARCHAR (60)  NULL,
    [SerialNumber]       NVARCHAR (80)  NULL,
    [AndroidId]          NVARCHAR (80)  NULL,
    [BranchId]           NVARCHAR (40)  NOT NULL,
    [Location]           NVARCHAR (120) NULL,
    [Description]        NVARCHAR (400) NULL,
    [PaperWidth]         INT            NOT NULL,
    [PrinterKind]        NVARCHAR (40)  NOT NULL,
    [RegistrationCode]   NVARCHAR (20)  NULL,
    [CodeExpiresAtUtc]   DATETIME2 (0)  NULL,
    [RegisteredAtUtc]    DATETIME2 (0)  NULL,
    [TokenHash]          NVARCHAR (128) NULL,
    [LastHeartbeatAtUtc] DATETIME2 (0)  NULL,
    [PrinterStatus]      NVARCHAR (20)  NOT NULL,
    [PaperStatus]        NVARCHAR (20)  NOT NULL,
    [PrinterError]       NVARCHAR (200) NULL,
    [BatteryPercent]     INT            NULL,
    [NetworkType]        NVARCHAR (20)  NULL,
    [AppVersion]         NVARCHAR (40)  NULL,
    [IsActive]           BIT            NOT NULL,
    [CreatedAtUtc]       DATETIME2 (0)  NOT NULL,
    [CreatedBy]          NVARCHAR (160) NULL,
    [UpdatedAtUtc]       DATETIME2 (0)  NULL,
    [UpdatedBy]          NVARCHAR (160) NULL,
    CONSTRAINT [PK_PosDevice] PRIMARY KEY CLUSTERED ([DeviceId] ASC)
);


GO
PRINT N'Creating Index [device].[PosDevice].[IX_PosDevice_Branch]...';


GO
CREATE NONCLUSTERED INDEX [IX_PosDevice_Branch]
    ON [device].[PosDevice]([BranchId] ASC, [IsActive] ASC);


GO
PRINT N'Creating Index [device].[PosDevice].[UX_PosDevice_Serial]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_PosDevice_Serial]
    ON [device].[PosDevice]([SerialNumber] ASC) WHERE ([SerialNumber] IS NOT NULL);


GO
PRINT N'Creating Index [device].[PosDevice].[UX_PosDevice_Code]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_PosDevice_Code]
    ON [device].[PosDevice]([RegistrationCode] ASC) WHERE ([RegistrationCode] IS NOT NULL);


GO
PRINT N'Creating Table [device].[DeviceEvent]...';


GO
CREATE TABLE [device].[DeviceEvent] (
    [EventId]       BIGINT         IDENTITY (1, 1) NOT NULL,
    [DeviceId]      NVARCHAR (40)  NOT NULL,
    [EventType]     NVARCHAR (40)  NOT NULL,
    [Severity]      NVARCHAR (20)  NOT NULL,
    [MessageEn]     NVARCHAR (300) NOT NULL,
    [MessageAr]     NVARCHAR (300) NOT NULL,
    [OccurredAtUtc] DATETIME2 (0)  NOT NULL,
    CONSTRAINT [PK_DeviceEvent] PRIMARY KEY CLUSTERED ([EventId] ASC)
);


GO
PRINT N'Creating Index [device].[DeviceEvent].[IX_Event_Device]...';


GO
CREATE NONCLUSTERED INDEX [IX_Event_Device]
    ON [device].[DeviceEvent]([DeviceId] ASC, [OccurredAtUtc] DESC);


GO
PRINT N'Creating Table [device].[DeviceChallenge]...';


GO
CREATE TABLE [device].[DeviceChallenge] (
    [ChallengeId]   NVARCHAR (40) NOT NULL,
    [SerialNumber]  NVARCHAR (80) NOT NULL,
    [Nonce]         NVARCHAR (88) NOT NULL,
    [IssuedAtUtc]   DATETIME2 (0) NOT NULL,
    [ExpiresAtUtc]  DATETIME2 (0) NOT NULL,
    [AnsweredAtUtc] DATETIME2 (0) NULL,
    [Verified]      BIT           NULL,
    [ConsumedAtUtc] DATETIME2 (0) NULL,
    CONSTRAINT [PK_DeviceChallenge] PRIMARY KEY CLUSTERED ([ChallengeId] ASC)
);


GO
PRINT N'Creating Index [device].[DeviceChallenge].[IX_Challenge_Serial]...';


GO
CREATE NONCLUSTERED INDEX [IX_Challenge_Serial]
    ON [device].[DeviceChallenge]([SerialNumber] ASC, [ExpiresAtUtc] DESC);


GO
PRINT N'Creating Table [device].[DeviceCommand]...';


GO
CREATE TABLE [device].[DeviceCommand] (
    [CommandId]      NVARCHAR (40)  NOT NULL,
    [DeviceId]       NVARCHAR (40)  NOT NULL,
    [CommandType]    NVARCHAR (40)  NOT NULL,
    [Payload]        NVARCHAR (MAX) NULL,
    [Status]         NVARCHAR (20)  NOT NULL,
    [QueuedAtUtc]    DATETIME2 (3)  NOT NULL,
    [SentAtUtc]      DATETIME2 (3)  NULL,
    [CompletedAtUtc] DATETIME2 (3)  NULL,
    [ExpiresAtUtc]   DATETIME2 (0)  NOT NULL,
    [Succeeded]      BIT            NULL,
    [ResultMessage]  NVARCHAR (400) NULL,
    [ResultData]     NVARCHAR (MAX) NULL,
    [RoundTripMs]    INT            NULL,
    [RequestedBy]    NVARCHAR (160) NULL,
    CONSTRAINT [PK_DeviceCommand] PRIMARY KEY CLUSTERED ([CommandId] ASC)
);


GO
PRINT N'Creating Index [device].[DeviceCommand].[IX_Command_Pending]...';


GO
CREATE NONCLUSTERED INDEX [IX_Command_Pending]
    ON [device].[DeviceCommand]([DeviceId] ASC, [Status] ASC, [QueuedAtUtc] ASC) WHERE ([Status]=N'pending');


GO
PRINT N'Creating Index [device].[DeviceCommand].[IX_Command_Device]...';


GO
CREATE NONCLUSTERED INDEX [IX_Command_Device]
    ON [device].[DeviceCommand]([DeviceId] ASC, [QueuedAtUtc] DESC);


GO
PRINT N'Creating Table [fin].[Account]...';


GO
CREATE TABLE [fin].[Account] (
    [AccountCode] NVARCHAR (10)  NOT NULL,
    [AccountType] NVARCHAR (20)  NOT NULL,
    [NameAr]      NVARCHAR (160) NOT NULL,
    [NameEn]      NVARCHAR (160) NOT NULL,
    [IsActive]    BIT            NOT NULL,
    CONSTRAINT [PK_Account] PRIMARY KEY CLUSTERED ([AccountCode] ASC)
);


GO
PRINT N'Creating Table [fin].[CommissionRuleItem]...';


GO
CREATE TABLE [fin].[CommissionRuleItem] (
    [RuleId] NVARCHAR (40) NOT NULL,
    [ItemId] NVARCHAR (40) NOT NULL,
    CONSTRAINT [PK_CommissionRuleItem] PRIMARY KEY CLUSTERED ([RuleId] ASC, [ItemId] ASC)
);


GO
PRINT N'Creating Table [fin].[JournalLine]...';


GO
CREATE TABLE [fin].[JournalLine] (
    [JournalLineId] BIGINT         IDENTITY (1, 1) NOT NULL,
    [EntryId]       NVARCHAR (40)  NOT NULL,
    [AccountCode]   NVARCHAR (10)  NOT NULL,
    [DebitH]        BIGINT         NOT NULL,
    [CreditH]       BIGINT         NOT NULL,
    [Memo]          NVARCHAR (400) NULL,
    CONSTRAINT [PK_JournalLine] PRIMARY KEY CLUSTERED ([JournalLineId] ASC)
);


GO
PRINT N'Creating Index [fin].[JournalLine].[IX_JournalLine_Account]...';


GO
CREATE NONCLUSTERED INDEX [IX_JournalLine_Account]
    ON [fin].[JournalLine]([AccountCode] ASC)
    INCLUDE([DebitH], [CreditH]);


GO
PRINT N'Creating Index [fin].[JournalLine].[IX_JournalLine_Entry]...';


GO
CREATE NONCLUSTERED INDEX [IX_JournalLine_Entry]
    ON [fin].[JournalLine]([EntryId] ASC);


GO
PRINT N'Creating Table [fin].[CommissionRule]...';


GO
CREATE TABLE [fin].[CommissionRule] (
    [RuleId]       NVARCHAR (40) NOT NULL,
    [Basis]        NVARCHAR (20) NOT NULL,
    [Value]        INT           NOT NULL,
    [IsActive]     BIT           NOT NULL,
    [CreatedAtUtc] DATETIME2 (3) NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3) NOT NULL,
    CONSTRAINT [PK_CommissionRule] PRIMARY KEY CLUSTERED ([RuleId] ASC)
);


GO
PRINT N'Creating Table [fin].[JournalEntry]...';


GO
CREATE TABLE [fin].[JournalEntry] (
    [EntryId]           NVARCHAR (40)  NOT NULL,
    [Reference]         NVARCHAR (40)  NOT NULL,
    [Kind]              NVARCHAR (40)  NOT NULL,
    [SourceReference]   NVARCHAR (80)  NULL,
    [DescriptionAr]     NVARCHAR (400) NULL,
    [DescriptionEn]     NVARCHAR (400) NOT NULL,
    [PostedAtUtc]       DATETIME2 (3)  NOT NULL,
    [BranchId]          NVARCHAR (40)  NULL,
    [Actor]             NVARCHAR (120) NOT NULL,
    [ReversesEntryId]   NVARCHAR (40)  NULL,
    [ReversedByEntryId] NVARCHAR (40)  NULL,
    [ReversalReason]    NVARCHAR (400) NULL,
    [TotalDebitH]       BIGINT         NOT NULL,
    [TotalCreditH]      BIGINT         NOT NULL,
    [CreatedAtUtc]      DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_JournalEntry] PRIMARY KEY CLUSTERED ([EntryId] ASC),
    CONSTRAINT [UQ_JournalEntry_Ref] UNIQUE NONCLUSTERED ([Reference] ASC)
);


GO
PRINT N'Creating Index [fin].[JournalEntry].[IX_JournalEntry_Branch]...';


GO
CREATE NONCLUSTERED INDEX [IX_JournalEntry_Branch]
    ON [fin].[JournalEntry]([BranchId] ASC, [PostedAtUtc] DESC);


GO
PRINT N'Creating Index [fin].[JournalEntry].[IX_JournalEntry_Source]...';


GO
CREATE NONCLUSTERED INDEX [IX_JournalEntry_Source]
    ON [fin].[JournalEntry]([SourceReference] ASC) WHERE ([SourceReference] IS NOT NULL);


GO
PRINT N'Creating Index [fin].[JournalEntry].[IX_JournalEntry_Posted]...';


GO
CREATE NONCLUSTERED INDEX [IX_JournalEntry_Posted]
    ON [fin].[JournalEntry]([PostedAtUtc] DESC)
    INCLUDE([Kind], [BranchId]);


GO
PRINT N'Creating Table [fin].[CommissionEntry]...';


GO
CREATE TABLE [fin].[CommissionEntry] (
    [CommissionId]  NVARCHAR (40)  NOT NULL,
    [SaleId]        NVARCHAR (40)  NOT NULL,
    [InvoiceNumber] NVARCHAR (40)  NOT NULL,
    [UserId]        NVARCHAR (40)  NOT NULL,
    [ItemId]        NVARCHAR (40)  NOT NULL,
    [ItemNameAr]    NVARCHAR (200) NOT NULL,
    [ItemNameEn]    NVARCHAR (200) NOT NULL,
    [LineGrossH]    BIGINT         NOT NULL,
    [AmountH]       BIGINT         NOT NULL,
    [Basis]         NVARCHAR (20)  NOT NULL,
    [RateAtSale]    INT            NOT NULL,
    [BranchId]      NVARCHAR (40)  NULL,
    [EarnedAtUtc]   DATETIME2 (3)  NOT NULL,
    [PayrollRunId]  NVARCHAR (40)  NULL,
    CONSTRAINT [PK_CommissionEntry] PRIMARY KEY CLUSTERED ([CommissionId] ASC)
);


GO
PRINT N'Creating Index [fin].[CommissionEntry].[IX_CommissionEntry_Unpaid]...';


GO
CREATE NONCLUSTERED INDEX [IX_CommissionEntry_Unpaid]
    ON [fin].[CommissionEntry]([UserId] ASC)
    INCLUDE([AmountH]) WHERE ([PayrollRunId] IS NULL);


GO
PRINT N'Creating Index [fin].[CommissionEntry].[IX_CommissionEntry_User]...';


GO
CREATE NONCLUSTERED INDEX [IX_CommissionEntry_User]
    ON [fin].[CommissionEntry]([UserId] ASC, [EarnedAtUtc] DESC)
    INCLUDE([AmountH], [PayrollRunId]);


GO
PRINT N'Creating Table [fin].[RecurringPayment]...';


GO
CREATE TABLE [fin].[RecurringPayment] (
    [RecurringId]   NVARCHAR (40)  NOT NULL,
    [DescriptionAr] NVARCHAR (300) NOT NULL,
    [DescriptionEn] NVARCHAR (300) NOT NULL,
    [CategoryId]    NVARCHAR (40)  NOT NULL,
    [BranchId]      NVARCHAR (40)  NULL,
    [AmountH]       BIGINT         NOT NULL,
    [Frequency]     NVARCHAR (20)  NOT NULL,
    [NextDueOn]     DATE           NOT NULL,
    [LastPaidOn]    DATE           NULL,
    [PaymentMethod] NVARCHAR (20)  NOT NULL,
    [Status]        NVARCHAR (20)  NOT NULL,
    [Note]          NVARCHAR (400) NULL,
    [CreatedAtUtc]  DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc]  DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_RecurringPayment] PRIMARY KEY CLUSTERED ([RecurringId] ASC)
);


GO
PRINT N'Creating Table [fin].[OpeningBalance]...';


GO
CREATE TABLE [fin].[OpeningBalance] (
    [OpeningId]    NVARCHAR (40)  NOT NULL,
    [BranchId]     NVARCHAR (40)  NULL,
    [AsOf]         DATE           NOT NULL,
    [CashH]        BIGINT         NOT NULL,
    [BankH]        BIGINT         NOT NULL,
    [InventoryH]   BIGINT         NOT NULL,
    [ReceivablesH] BIGINT         NOT NULL,
    [PayablesH]    BIGINT         NOT NULL,
    [VatH]         BIGINT         NOT NULL,
    [EquityH]      BIGINT         NOT NULL,
    [EntryId]      NVARCHAR (40)  NOT NULL,
    [Note]         NVARCHAR (400) NULL,
    [PostedAtUtc]  DATETIME2 (3)  NOT NULL,
    [PostedBy]     NVARCHAR (120) NOT NULL,
    CONSTRAINT [PK_OpeningBalance] PRIMARY KEY CLUSTERED ([OpeningId] ASC)
);


GO
PRINT N'Creating Index [fin].[OpeningBalance].[IX_OpeningBalance_Branch]...';


GO
CREATE NONCLUSTERED INDEX [IX_OpeningBalance_Branch]
    ON [fin].[OpeningBalance]([BranchId] ASC, [PostedAtUtc] ASC);


GO
PRINT N'Creating Table [fin].[PayrollLine]...';


GO
CREATE TABLE [fin].[PayrollLine] (
    [PayrollLineId] BIGINT        IDENTITY (1, 1) NOT NULL,
    [RunId]         NVARCHAR (40) NOT NULL,
    [UserId]        NVARCHAR (40) NOT NULL,
    [BaseSalaryH]   BIGINT        NOT NULL,
    [CommissionH]   BIGINT        NOT NULL,
    [AllowancesH]   BIGINT        NOT NULL,
    [DeductionsH]   BIGINT        NOT NULL,
    [NetPayH]       AS            ((([BaseSalaryH] + [CommissionH]) + [AllowancesH]) - [DeductionsH]) PERSISTED,
    CONSTRAINT [PK_PayrollLine] PRIMARY KEY CLUSTERED ([PayrollLineId] ASC),
    CONSTRAINT [UQ_PayrollLine] UNIQUE NONCLUSTERED ([RunId] ASC, [UserId] ASC)
);


GO
PRINT N'Creating Table [fin].[ExpenseRecognition]...';


GO
CREATE TABLE [fin].[ExpenseRecognition] (
    [RecognitionId] BIGINT        IDENTITY (1, 1) NOT NULL,
    [ExpenseId]     NVARCHAR (40) NOT NULL,
    [PeriodMonth]   CHAR (7)      NOT NULL,
    [AmountH]       BIGINT        NOT NULL,
    CONSTRAINT [PK_ExpenseRecognition] PRIMARY KEY CLUSTERED ([RecognitionId] ASC),
    CONSTRAINT [UQ_ExpenseRecognition] UNIQUE NONCLUSTERED ([ExpenseId] ASC, [PeriodMonth] ASC)
);


GO
PRINT N'Creating Table [fin].[BalancePeriod]...';


GO
CREATE TABLE [fin].[BalancePeriod] (
    [PeriodId]          NVARCHAR (40)  NOT NULL,
    [BranchId]          NVARCHAR (40)  NULL,
    [Label]             NVARCHAR (160) NOT NULL,
    [OpenedOn]          DATE           NOT NULL,
    [ClosedOn]          DATE           NULL,
    [OpeningCashH]      BIGINT         NOT NULL,
    [OpeningCardH]      BIGINT         NOT NULL,
    [OpeningCreditH]    BIGINT         NOT NULL,
    [OpeningBankH]      BIGINT         NOT NULL,
    [OpeningInventoryH] BIGINT         NOT NULL,
    [OpeningPayablesH]  BIGINT         NOT NULL,
    [ClosingCashH]      BIGINT         NULL,
    [ClosingCardH]      BIGINT         NULL,
    [ClosingCreditH]    BIGINT         NULL,
    [ClosingBankH]      BIGINT         NULL,
    [ClosingInventoryH] BIGINT         NULL,
    [ClosingPayablesH]  BIGINT         NULL,
    [Status]            NVARCHAR (20)  NOT NULL,
    [OpenedBy]          NVARCHAR (120) NOT NULL,
    [ClosedBy]          NVARCHAR (120) NULL,
    [Note]              NVARCHAR (400) NULL,
    [CreatedAtUtc]      DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc]      DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_BalancePeriod] PRIMARY KEY CLUSTERED ([PeriodId] ASC)
);


GO
PRINT N'Creating Index [fin].[BalancePeriod].[UX_BalancePeriod_OpenPerBranch]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_BalancePeriod_OpenPerBranch]
    ON [fin].[BalancePeriod]([BranchId] ASC) WHERE ([Status]=N'open');


GO
PRINT N'Creating Table [fin].[CommissionRuleUser]...';


GO
CREATE TABLE [fin].[CommissionRuleUser] (
    [RuleId] NVARCHAR (40) NOT NULL,
    [UserId] NVARCHAR (40) NOT NULL,
    CONSTRAINT [PK_CommissionRuleUser] PRIMARY KEY CLUSTERED ([RuleId] ASC, [UserId] ASC)
);


GO
PRINT N'Creating Table [fin].[ExpenseCategory]...';


GO
CREATE TABLE [fin].[ExpenseCategory] (
    [CategoryId]   NVARCHAR (40)  NOT NULL,
    [NameAr]       NVARCHAR (120) NOT NULL,
    [NameEn]       NVARCHAR (120) NOT NULL,
    [AccountCode]  NVARCHAR (10)  NOT NULL,
    [IsActive]     BIT            NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NOT NULL,
    [CreatedBy]    NVARCHAR (120) NULL,
    [UpdatedBy]    NVARCHAR (120) NULL,
    CONSTRAINT [PK_ExpenseCategory] PRIMARY KEY CLUSTERED ([CategoryId] ASC)
);


GO
PRINT N'Creating Table [fin].[Expense]...';


GO
CREATE TABLE [fin].[Expense] (
    [ExpenseId]      NVARCHAR (40)  NOT NULL,
    [Reference]      NVARCHAR (40)  NOT NULL,
    [CategoryId]     NVARCHAR (40)  NOT NULL,
    [BranchId]       NVARCHAR (40)  NULL,
    [DescriptionAr]  NVARCHAR (400) NULL,
    [DescriptionEn]  NVARCHAR (400) NULL,
    [AmountH]        BIGINT         NOT NULL,
    [VatH]           BIGINT         NOT NULL,
    [PaymentMethod]  NVARCHAR (20)  NOT NULL,
    [PaidOn]         DATE           NOT NULL,
    [Recognition]    NVARCHAR (20)  NOT NULL,
    [PeriodStart]    DATE           NOT NULL,
    [PeriodEnd]      DATE           NOT NULL,
    [ExternalRef]    NVARCHAR (80)  NULL,
    [AttachmentName] NVARCHAR (300) NULL,
    [AttachmentUrl]  NVARCHAR (600) NULL,
    [Status]         NVARCHAR (20)  NOT NULL,
    [CreatedAtUtc]   DATETIME2 (3)  NOT NULL,
    [CreatedBy]      NVARCHAR (120) NOT NULL,
    [UpdatedAtUtc]   DATETIME2 (3)  NOT NULL,
    [UpdatedBy]      NVARCHAR (120) NULL,
    CONSTRAINT [PK_Expense] PRIMARY KEY CLUSTERED ([ExpenseId] ASC),
    CONSTRAINT [UQ_Expense_Ref] UNIQUE NONCLUSTERED ([Reference] ASC)
);


GO
PRINT N'Creating Index [fin].[Expense].[IX_Expense_PaidOn]...';


GO
CREATE NONCLUSTERED INDEX [IX_Expense_PaidOn]
    ON [fin].[Expense]([PaidOn] DESC)
    INCLUDE([AmountH], [CategoryId]);


GO
PRINT N'Creating Table [fin].[DrawerSession]...';


GO
CREATE TABLE [fin].[DrawerSession] (
    [SessionId]     NVARCHAR (40)  NOT NULL,
    [BranchId]      NVARCHAR (40)  NULL,
    [OpenedAtUtc]   DATETIME2 (3)  NOT NULL,
    [ClosedAtUtc]   DATETIME2 (3)  NULL,
    [OpeningCashH]  BIGINT         NOT NULL,
    [CountedCashH]  BIGINT         NULL,
    [ExpectedCashH] BIGINT         NULL,
    [VarianceH]     BIGINT         NULL,
    [OpenedBy]      NVARCHAR (120) NOT NULL,
    [ClosedBy]      NVARCHAR (120) NULL,
    [Note]          NVARCHAR (400) NULL,
    CONSTRAINT [PK_DrawerSession] PRIMARY KEY CLUSTERED ([SessionId] ASC)
);


GO
PRINT N'Creating Index [fin].[DrawerSession].[UX_DrawerSession_OpenPerBranch]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_DrawerSession_OpenPerBranch]
    ON [fin].[DrawerSession]([BranchId] ASC) WHERE ([ClosedAtUtc] IS NULL);


GO
PRINT N'Creating Table [fin].[CardSettlement]...';


GO
CREATE TABLE [fin].[CardSettlement] (
    [SettlementId] NVARCHAR (40)  NOT NULL,
    [Reference]    NVARCHAR (40)  NOT NULL,
    [BranchId]     NVARCHAR (40)  NULL,
    [CardSalesH]   BIGINT         NOT NULL,
    [DepositH]     BIGINT         NOT NULL,
    [FeeH]         BIGINT         NOT NULL,
    [SettledOn]    DATE           NOT NULL,
    [Status]       NVARCHAR (20)  NOT NULL,
    [Note]         NVARCHAR (400) NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    [CreatedBy]    NVARCHAR (120) NOT NULL,
    CONSTRAINT [PK_CardSettlement] PRIMARY KEY CLUSTERED ([SettlementId] ASC),
    CONSTRAINT [UQ_CardSettlement_Ref] UNIQUE NONCLUSTERED ([Reference] ASC)
);


GO
PRINT N'Creating Table [fin].[PayrollRun]...';


GO
CREATE TABLE [fin].[PayrollRun] (
    [RunId]        NVARCHAR (40)  NOT NULL,
    [Reference]    NVARCHAR (40)  NOT NULL,
    [PeriodMonth]  CHAR (7)       NOT NULL,
    [BranchId]     NVARCHAR (40)  NULL,
    [Status]       NVARCHAR (20)  NOT NULL,
    [TotalH]       BIGINT         NOT NULL,
    [PaidOn]       DATE           NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    [CreatedBy]    NVARCHAR (120) NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)  NOT NULL,
    [UpdatedBy]    NVARCHAR (120) NULL,
    CONSTRAINT [PK_PayrollRun] PRIMARY KEY CLUSTERED ([RunId] ASC),
    CONSTRAINT [UQ_PayrollRun_Period] UNIQUE NONCLUSTERED ([PeriodMonth] ASC, [BranchId] ASC),
    CONSTRAINT [UQ_PayrollRun_Ref] UNIQUE NONCLUSTERED ([Reference] ASC)
);


GO
PRINT N'Creating Table [inv].[StockLevel]...';


GO
CREATE TABLE [inv].[StockLevel] (
    [ItemId]       NVARCHAR (40)   NOT NULL,
    [BranchId]     NVARCHAR (40)   NOT NULL,
    [Quantity]     DECIMAL (18, 3) NOT NULL,
    [UpdatedAtUtc] DATETIME2 (3)   NOT NULL,
    CONSTRAINT [PK_StockLevel] PRIMARY KEY CLUSTERED ([ItemId] ASC, [BranchId] ASC)
);


GO
PRINT N'Creating Table [inv].[PurchaseLine]...';


GO
CREATE TABLE [inv].[PurchaseLine] (
    [PurchaseLineId] BIGINT          IDENTITY (1, 1) NOT NULL,
    [PurchaseId]     NVARCHAR (40)   NOT NULL,
    [ItemId]         NVARCHAR (40)   NOT NULL,
    [Quantity]       DECIMAL (18, 3) NOT NULL,
    [UnitCostH]      BIGINT          NOT NULL,
    CONSTRAINT [PK_PurchaseLine] PRIMARY KEY CLUSTERED ([PurchaseLineId] ASC)
);


GO
PRINT N'Creating Table [inv].[StockMovement]...';


GO
CREATE TABLE [inv].[StockMovement] (
    [MovementId]    BIGINT          IDENTITY (1, 1) NOT NULL,
    [ItemId]        NVARCHAR (40)   NOT NULL,
    [BranchId]      NVARCHAR (40)   NULL,
    [MovementType]  NVARCHAR (30)   NOT NULL,
    [Quantity]      DECIMAL (18, 3) NOT NULL,
    [BalanceAfter]  DECIMAL (18, 3) NOT NULL,
    [UnitCostH]     BIGINT          NOT NULL,
    [Reference]     NVARCHAR (80)   NULL,
    [ReasonAr]      NVARCHAR (400)  NULL,
    [ReasonEn]      NVARCHAR (400)  NULL,
    [OccurredAtUtc] DATETIME2 (3)   NOT NULL,
    [Actor]         NVARCHAR (120)  NOT NULL,
    CONSTRAINT [PK_StockMovement] PRIMARY KEY CLUSTERED ([MovementId] ASC)
);


GO
PRINT N'Creating Index [inv].[StockMovement].[IX_StockMovement_Branch]...';


GO
CREATE NONCLUSTERED INDEX [IX_StockMovement_Branch]
    ON [inv].[StockMovement]([BranchId] ASC, [OccurredAtUtc] DESC);


GO
PRINT N'Creating Index [inv].[StockMovement].[IX_StockMovement_Item]...';


GO
CREATE NONCLUSTERED INDEX [IX_StockMovement_Item]
    ON [inv].[StockMovement]([ItemId] ASC, [OccurredAtUtc] DESC);


GO
PRINT N'Creating Table [inv].[VendorPayment]...';


GO
CREATE TABLE [inv].[VendorPayment] (
    [PaymentId]    NVARCHAR (40)  NOT NULL,
    [Reference]    NVARCHAR (40)  NOT NULL,
    [VendorId]     NVARCHAR (40)  NOT NULL,
    [BranchId]     NVARCHAR (40)  NULL,
    [AmountH]      BIGINT         NOT NULL,
    [Method]       NVARCHAR (20)  NOT NULL,
    [Note]         NVARCHAR (400) NULL,
    [EntryId]      NVARCHAR (40)  NULL,
    [PaidAtUtc]    DATETIME2 (3)  NOT NULL,
    [PaidBy]       NVARCHAR (120) NOT NULL,
    [CreatedAtUtc] DATETIME2 (3)  NOT NULL,
    CONSTRAINT [PK_VendorPayment] PRIMARY KEY CLUSTERED ([PaymentId] ASC),
    CONSTRAINT [UQ_VendorPayment_Ref] UNIQUE NONCLUSTERED ([Reference] ASC)
);


GO
PRINT N'Creating Index [inv].[VendorPayment].[IX_VendorPayment_Vendor]...';


GO
CREATE NONCLUSTERED INDEX [IX_VendorPayment_Vendor]
    ON [inv].[VendorPayment]([VendorId] ASC, [PaidAtUtc] ASC);


GO
PRINT N'Creating Table [inv].[Purchase]...';


GO
CREATE TABLE [inv].[Purchase] (
    [PurchaseId]    NVARCHAR (40)  NOT NULL,
    [Reference]     NVARCHAR (40)  NOT NULL,
    [VendorId]      NVARCHAR (40)  NOT NULL,
    [BranchId]      NVARCHAR (40)  NULL,
    [InvoiceNumber] NVARCHAR (60)  NULL,
    [SubtotalH]     BIGINT         NOT NULL,
    [TaxH]          BIGINT         NOT NULL,
    [TotalH]        BIGINT         NOT NULL,
    [PaidOnReceipt] BIT            NOT NULL,
    [ReceivedAtUtc] DATETIME2 (3)  NOT NULL,
    [ReceivedBy]    NVARCHAR (120) NOT NULL,
    [PaidH]         BIGINT         NOT NULL,
    [Note]          NVARCHAR (400) NULL,
    CONSTRAINT [PK_Purchase] PRIMARY KEY CLUSTERED ([PurchaseId] ASC),
    CONSTRAINT [UQ_Purchase_Ref] UNIQUE NONCLUSTERED ([Reference] ASC)
);


GO
PRINT N'Creating Index [inv].[Purchase].[IX_Purchase_Vendor]...';


GO
CREATE NONCLUSTERED INDEX [IX_Purchase_Vendor]
    ON [inv].[Purchase]([VendorId] ASC, [ReceivedAtUtc] ASC)
    INCLUDE([TotalH], [PaidH], [PaidOnReceipt]);


GO
PRINT N'Creating Table [inv].[VendorPaymentAllocation]...';


GO
CREATE TABLE [inv].[VendorPaymentAllocation] (
    [PaymentId]  NVARCHAR (40) NOT NULL,
    [PurchaseId] NVARCHAR (40) NOT NULL,
    [AmountH]    BIGINT        NOT NULL,
    CONSTRAINT [PK_VendorPaymentAllocation] PRIMARY KEY CLUSTERED ([PaymentId] ASC, [PurchaseId] ASC)
);


GO
PRINT N'Creating Index [inv].[VendorPaymentAllocation].[IX_VPA_Purchase]...';


GO
CREATE NONCLUSTERED INDEX [IX_VPA_Purchase]
    ON [inv].[VendorPaymentAllocation]([PurchaseId] ASC);


GO
PRINT N'Creating Table [sales].[SaleLine]...';


GO
CREATE TABLE [sales].[SaleLine] (
    [SaleLineId]    BIGINT          IDENTITY (1, 1) NOT NULL,
    [SaleId]        NVARCHAR (40)   NOT NULL,
    [ItemId]        NVARCHAR (40)   NOT NULL,
    [NameAr]        NVARCHAR (200)  NOT NULL,
    [NameEn]        NVARCHAR (200)  NOT NULL,
    [Kind]          NVARCHAR (20)   NOT NULL,
    [PrintGroupId]  NVARCHAR (40)   NULL,
    [Quantity]      DECIMAL (18, 3) NOT NULL,
    [UnitPriceH]    BIGINT          NOT NULL,
    [UnitCostH]     BIGINT          NOT NULL,
    [LineDiscountH] BIGINT          NOT NULL,
    [ReturnedQty]   DECIMAL (18, 3) NOT NULL,
    [Note]          NVARCHAR (400)  NULL,
    CONSTRAINT [PK_SaleLine] PRIMARY KEY CLUSTERED ([SaleLineId] ASC)
);


GO
PRINT N'Creating Index [sales].[SaleLine].[IX_SaleLine_Item]...';


GO
CREATE NONCLUSTERED INDEX [IX_SaleLine_Item]
    ON [sales].[SaleLine]([ItemId] ASC);


GO
PRINT N'Creating Index [sales].[SaleLine].[IX_SaleLine_Sale]...';


GO
CREATE NONCLUSTERED INDEX [IX_SaleLine_Sale]
    ON [sales].[SaleLine]([SaleId] ASC);


GO
PRINT N'Creating Table [sales].[Sale]...';


GO
CREATE TABLE [sales].[Sale] (
    [SaleId]             NVARCHAR (40)    NOT NULL,
    [InvoiceNumber]      NVARCHAR (40)    NOT NULL,
    [BranchId]           NVARCHAR (40)    NULL,
    [CustomerId]         NVARCHAR (40)    NULL,
    [ServedByUserId]     NVARCHAR (40)    NULL,
    [CashierName]        NVARCHAR (160)   NOT NULL,
    [SubtotalH]          BIGINT           NOT NULL,
    [DiscountH]          BIGINT           NOT NULL,
    [TaxH]               BIGINT           NOT NULL,
    [TotalH]             BIGINT           NOT NULL,
    [TenderedH]          BIGINT           NULL,
    [ChangeH]            BIGINT           NOT NULL,
    [DiscountId]         NVARCHAR (40)    NULL,
    [Status]             NVARCHAR (20)    NOT NULL,
    [SoldAtUtc]          DATETIME2 (3)    NOT NULL,
    [ZatcaUuid]          UNIQUEIDENTIFIER NULL,
    [ZatcaCounter]       BIGINT           NULL,
    [ZatcaInvoiceHash]   NVARCHAR (200)   NULL,
    [ZatcaPreviousHash]  NVARCHAR (200)   NULL,
    [ZatcaQrPayload]     NVARCHAR (1000)  NULL,
    [CreatedAtUtc]       DATETIME2 (3)    NOT NULL,
    [CreatedBy]          NVARCHAR (120)   NULL,
    [UpdatedAtUtc]       DATETIME2 (3)    NOT NULL,
    [UpdatedBy]          NVARCHAR (120)   NULL,
    [IdempotencyKey]     NVARCHAR (64)    NULL,
    [DiscountApprovedBy] NVARCHAR (40)    NULL,
    [OrderType]          NVARCHAR (20)    NULL,
    CONSTRAINT [PK_Sale] PRIMARY KEY CLUSTERED ([SaleId] ASC),
    CONSTRAINT [UQ_Sale_Invoice] UNIQUE NONCLUSTERED ([InvoiceNumber] ASC)
);


GO
PRINT N'Creating Index [sales].[Sale].[IX_Sale_Customer]...';


GO
CREATE NONCLUSTERED INDEX [IX_Sale_Customer]
    ON [sales].[Sale]([CustomerId] ASC, [SoldAtUtc] DESC) WHERE ([CustomerId] IS NOT NULL);


GO
PRINT N'Creating Index [sales].[Sale].[IX_Sale_Branch_Date]...';


GO
CREATE NONCLUSTERED INDEX [IX_Sale_Branch_Date]
    ON [sales].[Sale]([BranchId] ASC, [SoldAtUtc] DESC)
    INCLUDE([TotalH], [Status]);


GO
PRINT N'Creating Index [sales].[Sale].[UX_Sale_IdempotencyKey]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_Sale_IdempotencyKey]
    ON [sales].[Sale]([IdempotencyKey] ASC) WHERE ([IdempotencyKey] IS NOT NULL);


GO
PRINT N'Creating Index [sales].[Sale].[UX_Sale_ZatcaCounter]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_Sale_ZatcaCounter]
    ON [sales].[Sale]([ZatcaCounter] ASC) WHERE ([ZatcaCounter] IS NOT NULL);


GO
PRINT N'Creating Table [sales].[DiscountScope]...';


GO
CREATE TABLE [sales].[DiscountScope] (
    [DiscountId] NVARCHAR (40) NOT NULL,
    [ScopeType]  NVARCHAR (20) NOT NULL,
    [ScopeKey]   NVARCHAR (40) NOT NULL,
    CONSTRAINT [PK_DiscountScope] PRIMARY KEY CLUSTERED ([DiscountId] ASC, [ScopeType] ASC, [ScopeKey] ASC)
);


GO
PRINT N'Creating Table [sales].[Discount]...';


GO
CREATE TABLE [sales].[Discount] (
    [DiscountId]     NVARCHAR (40)  NOT NULL,
    [NameAr]         NVARCHAR (160) NOT NULL,
    [NameEn]         NVARCHAR (160) NOT NULL,
    [DiscountType]   NVARCHAR (20)  NOT NULL,
    [Value]          INT            NOT NULL,
    [MaxDiscountH]   BIGINT         NULL,
    [MinSubtotalH]   BIGINT         NOT NULL,
    [ApprovalAboveH] BIGINT         NULL,
    [AppliesTo]      NVARCHAR (20)  NOT NULL,
    [IsAutomatic]    BIT            NOT NULL,
    [AllowStacking]  BIT            NOT NULL,
    [ActiveDays]     NVARCHAR (20)  NOT NULL,
    [StartsOn]       DATE           NULL,
    [EndsOn]         DATE           NULL,
    [UsageCount]     INT            NOT NULL,
    [IsActive]       BIT            NOT NULL,
    [CreatedAtUtc]   DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc]   DATETIME2 (3)  NOT NULL,
    [Description]    NVARCHAR (400) NULL,
    CONSTRAINT [PK_Discount] PRIMARY KEY CLUSTERED ([DiscountId] ASC)
);


GO
PRINT N'Creating Table [sales].[SaleReturn]...';


GO
CREATE TABLE [sales].[SaleReturn] (
    [ReturnId]      NVARCHAR (40)  NOT NULL,
    [SaleId]        NVARCHAR (40)  NOT NULL,
    [ReasonAr]      NVARCHAR (400) NULL,
    [ReasonEn]      NVARCHAR (400) NULL,
    [RefundH]       BIGINT         NOT NULL,
    [ReturnedAtUtc] DATETIME2 (3)  NOT NULL,
    [ReturnedBy]    NVARCHAR (120) NOT NULL,
    [NoteNumber]    NVARCHAR (40)  NULL,
    [BranchId]      NVARCHAR (40)  NULL,
    [CustomerId]    NVARCHAR (40)  NULL,
    [ReasonCode]    NVARCHAR (30)  NULL,
    [Note]          NVARCHAR (400) NULL,
    [SubtotalH]     BIGINT         NOT NULL,
    [TaxH]          BIGINT         NOT NULL,
    [CogsH]         BIGINT         NOT NULL,
    [RefundMethod]  NVARCHAR (20)  NULL,
    [EntryId]       NVARCHAR (40)  NULL,
    CONSTRAINT [PK_SaleReturn] PRIMARY KEY CLUSTERED ([ReturnId] ASC)
);


GO
PRINT N'Creating Index [sales].[SaleReturn].[UX_SaleReturn_NoteNumber]...';


GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_SaleReturn_NoteNumber]
    ON [sales].[SaleReturn]([NoteNumber] ASC) WHERE ([NoteNumber] IS NOT NULL);


GO
PRINT N'Creating Index [sales].[SaleReturn].[IX_SaleReturn_Sale]...';


GO
CREATE NONCLUSTERED INDEX [IX_SaleReturn_Sale]
    ON [sales].[SaleReturn]([SaleId] ASC);


GO
PRINT N'Creating Table [sales].[PreparationItem]...';


GO
CREATE TABLE [sales].[PreparationItem] (
    [PreparationItemId] BIGINT          IDENTITY (1, 1) NOT NULL,
    [PreparationId]     NVARCHAR (40)   NOT NULL,
    [ItemId]            NVARCHAR (40)   NULL,
    [NameAr]            NVARCHAR (200)  NOT NULL,
    [NameEn]            NVARCHAR (200)  NOT NULL,
    [Quantity]          DECIMAL (18, 3) NOT NULL,
    [CompletedQty]      DECIMAL (18, 3) NOT NULL,
    [Note]              NVARCHAR (400)  NULL,
    CONSTRAINT [PK_PreparationItem] PRIMARY KEY CLUSTERED ([PreparationItemId] ASC)
);


GO
PRINT N'Creating Table [sales].[SalePayment]...';


GO
CREATE TABLE [sales].[SalePayment] (
    [SalePaymentId] BIGINT        IDENTITY (1, 1) NOT NULL,
    [SaleId]        NVARCHAR (40) NOT NULL,
    [Method]        NVARCHAR (20) NOT NULL,
    [AmountH]       BIGINT        NOT NULL,
    [Reference]     NVARCHAR (80) NULL,
    CONSTRAINT [PK_SalePayment] PRIMARY KEY CLUSTERED ([SalePaymentId] ASC)
);


GO
PRINT N'Creating Table [sales].[SaleReturnLine]...';


GO
CREATE TABLE [sales].[SaleReturnLine] (
    [ReturnLineId] BIGINT          IDENTITY (1, 1) NOT NULL,
    [ReturnId]     NVARCHAR (40)   NOT NULL,
    [SaleLineId]   BIGINT          NOT NULL,
    [Quantity]     DECIMAL (18, 3) NOT NULL,
    [ItemId]       NVARCHAR (40)   NULL,
    [UnitPriceH]   BIGINT          NOT NULL,
    [UnitCostH]    BIGINT          NOT NULL,
    [AmountH]      BIGINT          NOT NULL,
    CONSTRAINT [PK_SaleReturnLine] PRIMARY KEY CLUSTERED ([ReturnLineId] ASC)
);


GO
PRINT N'Creating Table [sales].[PreparationOrder]...';


GO
CREATE TABLE [sales].[PreparationOrder] (
    [PreparationId] NVARCHAR (40)  NOT NULL,
    [OrderNumber]   NVARCHAR (40)  NOT NULL,
    [SaleId]        NVARCHAR (40)  NULL,
    [BranchId]      NVARCHAR (40)  NULL,
    [PrintGroupId]  NVARCHAR (40)  NULL,
    [CustomerName]  NVARCHAR (160) NULL,
    [TotalH]        BIGINT         NOT NULL,
    [Status]        NVARCHAR (20)  NOT NULL,
    [CreatedAtUtc]  DATETIME2 (3)  NOT NULL,
    [UpdatedAtUtc]  DATETIME2 (3)  NOT NULL,
    [OrderType]     NVARCHAR (20)  NULL,
    CONSTRAINT [PK_PreparationOrder] PRIMARY KEY CLUSTERED ([PreparationId] ASC)
);


GO
PRINT N'Creating Default Constraint [audit].[DF_Timing_At]...';


GO
ALTER TABLE [audit].[RequestTiming]
    ADD CONSTRAINT [DF_Timing_At] DEFAULT (sysutcdatetime()) FOR [OccurredAtUtc];


GO
PRINT N'Creating Default Constraint [audit].[DF_Timing_Db]...';


GO
ALTER TABLE [audit].[RequestTiming]
    ADD CONSTRAINT [DF_Timing_Db] DEFAULT ((0)) FOR [DatabaseMs];


GO
PRINT N'Creating Default Constraint [audit].[DF_Timing_Count]...';


GO
ALTER TABLE [audit].[RequestTiming]
    ADD CONSTRAINT [DF_Timing_Count] DEFAULT ((0)) FOR [QueryCount];


GO
PRINT N'Creating Default Constraint [audit].[DF_QueryTiming_Ok]...';


GO
ALTER TABLE [audit].[QueryTiming]
    ADD CONSTRAINT [DF_QueryTiming_Ok] DEFAULT ((1)) FOR [Succeeded];


GO
PRINT N'Creating Default Constraint [audit].[DF_QueryTiming_At]...';


GO
ALTER TABLE [audit].[QueryTiming]
    ADD CONSTRAINT [DF_QueryTiming_At] DEFAULT (sysutcdatetime()) FOR [OccurredAtUtc];


GO
PRINT N'Creating Default Constraint [audit].[DF_Audit_Result]...';


GO
ALTER TABLE [audit].[AuditEntry]
    ADD CONSTRAINT [DF_Audit_Result] DEFAULT (N'success') FOR [Result];


GO
PRINT N'Creating Default Constraint [audit].[DF_Audit_At]...';


GO
ALTER TABLE [audit].[AuditEntry]
    ADD CONSTRAINT [DF_Audit_At] DEFAULT (sysutcdatetime()) FOR [OccurredAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Category_AppliesTo]...';


GO
ALTER TABLE [core].[Category]
    ADD CONSTRAINT [DF_Category_AppliesTo] DEFAULT (N'both') FOR [AppliesTo];


GO
PRINT N'Creating Default Constraint [core].[DF_Category_Active]...';


GO
ALTER TABLE [core].[Category]
    ADD CONSTRAINT [DF_Category_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_Category_Sort]...';


GO
ALTER TABLE [core].[Category]
    ADD CONSTRAINT [DF_Category_Sort] DEFAULT ((100)) FOR [SortOrder];


GO
PRINT N'Creating Default Constraint [core].[DF_Category_Created]...';


GO
ALTER TABLE [core].[Category]
    ADD CONSTRAINT [DF_Category_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Category_Updated]...';


GO
ALTER TABLE [core].[Category]
    ADD CONSTRAINT [DF_Category_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Customer_Created]...';


GO
ALTER TABLE [core].[Customer]
    ADD CONSTRAINT [DF_Customer_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Customer_Balance]...';


GO
ALTER TABLE [core].[Customer]
    ADD CONSTRAINT [DF_Customer_Balance] DEFAULT ((0)) FOR [BalanceH];


GO
PRINT N'Creating Default Constraint [core].[DF_Customer_Active]...';


GO
ALTER TABLE [core].[Customer]
    ADD CONSTRAINT [DF_Customer_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_Customer_Updated]...';


GO
ALTER TABLE [core].[Customer]
    ADD CONSTRAINT [DF_Customer_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Customer_Type]...';


GO
ALTER TABLE [core].[Customer]
    ADD CONSTRAINT [DF_Customer_Type] DEFAULT (N'individual') FOR [CustomerType];


GO
PRINT N'Creating Default Constraint [core].[DF_Customer_Limit]...';


GO
ALTER TABLE [core].[Customer]
    ADD CONSTRAINT [DF_Customer_Limit] DEFAULT ((0)) FOR [CreditLimitH];


GO
PRINT N'Creating Default Constraint [core].[DF_Translation_Updated]...';


GO
ALTER TABLE [core].[Translation]
    ADD CONSTRAINT [DF_Translation_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Language_Rtl]...';


GO
ALTER TABLE [core].[Language]
    ADD CONSTRAINT [DF_Language_Rtl] DEFAULT ((0)) FOR [IsRtl];


GO
PRINT N'Creating Default Constraint [core].[DF_Language_Sort]...';


GO
ALTER TABLE [core].[Language]
    ADD CONSTRAINT [DF_Language_Sort] DEFAULT ((100)) FOR [SortOrder];


GO
PRINT N'Creating Default Constraint [core].[DF_Language_Active]...';


GO
ALTER TABLE [core].[Language]
    ADD CONSTRAINT [DF_Language_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_Notification_Sev]...';


GO
ALTER TABLE [core].[Notification]
    ADD CONSTRAINT [DF_Notification_Sev] DEFAULT (N'info') FOR [Severity];


GO
PRINT N'Creating Default Constraint [core].[DF_Notification_Created]...';


GO
ALTER TABLE [core].[Notification]
    ADD CONSTRAINT [DF_Notification_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Role_Created]...';


GO
ALTER TABLE [core].[Role]
    ADD CONSTRAINT [DF_Role_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Role_BuiltIn]...';


GO
ALTER TABLE [core].[Role]
    ADD CONSTRAINT [DF_Role_BuiltIn] DEFAULT ((0)) FOR [IsBuiltIn];


GO
PRINT N'Creating Default Constraint [core].[DF_Role_External]...';


GO
ALTER TABLE [core].[Role]
    ADD CONSTRAINT [DF_Role_External] DEFAULT ((0)) FOR [IsExternal];


GO
PRINT N'Creating Default Constraint [core].[DF_Role_IsActive]...';


GO
ALTER TABLE [core].[Role]
    ADD CONSTRAINT [DF_Role_IsActive] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_Role_Updated]...';


GO
ALTER TABLE [core].[Role]
    ADD CONSTRAINT [DF_Role_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Branch_Updated]...';


GO
ALTER TABLE [core].[Branch]
    ADD CONSTRAINT [DF_Branch_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Branch_Created]...';


GO
ALTER TABLE [core].[Branch]
    ADD CONSTRAINT [DF_Branch_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Branch_Active]...';


GO
ALTER TABLE [core].[Branch]
    ADD CONSTRAINT [DF_Branch_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_PrintGroup_Active]...';


GO
ALTER TABLE [core].[PrintGroup]
    ADD CONSTRAINT [DF_PrintGroup_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_PrintGroup_Updated]...';


GO
ALTER TABLE [core].[PrintGroup]
    ADD CONSTRAINT [DF_PrintGroup_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_PrintGroup_Created]...';


GO
ALTER TABLE [core].[PrintGroup]
    ADD CONSTRAINT [DF_PrintGroup_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_PrintGroup_Sort]...';


GO
ALTER TABLE [core].[PrintGroup]
    ADD CONSTRAINT [DF_PrintGroup_Sort] DEFAULT ((100)) FOR [SortOrder];


GO
PRINT N'Creating Default Constraint [core].[DF_LoginAttempt_At]...';


GO
ALTER TABLE [core].[LoginAttempt]
    ADD CONSTRAINT [DF_LoginAttempt_At] DEFAULT (sysutcdatetime()) FOR [AttemptedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Company_Country]...';


GO
ALTER TABLE [core].[Company]
    ADD CONSTRAINT [DF_Company_Country] DEFAULT (N'SA') FOR [Country];


GO
PRINT N'Creating Default Constraint [core].[DF_Company_Updated]...';


GO
ALTER TABLE [core].[Company]
    ADD CONSTRAINT [DF_Company_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Company_Created]...';


GO
ALTER TABLE [core].[Company]
    ADD CONSTRAINT [DF_Company_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Vendor_Active]...';


GO
ALTER TABLE [core].[Vendor]
    ADD CONSTRAINT [DF_Vendor_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_Vendor_Created]...';


GO
ALTER TABLE [core].[Vendor]
    ADD CONSTRAINT [DF_Vendor_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Vendor_Terms]...';


GO
ALTER TABLE [core].[Vendor]
    ADD CONSTRAINT [DF_Vendor_Terms] DEFAULT ((0)) FOR [PaymentTermDays];


GO
PRINT N'Creating Default Constraint [core].[DF_Vendor_Updated]...';


GO
ALTER TABLE [core].[Vendor]
    ADD CONSTRAINT [DF_Vendor_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_BS_Vat]...';


GO
ALTER TABLE [core].[BranchSettings]
    ADD CONSTRAINT [DF_BS_Vat] DEFAULT ((15.00)) FOR [VatRatePercent];


GO
PRINT N'Creating Default Constraint [core].[DF_BS_Incl]...';


GO
ALTER TABLE [core].[BranchSettings]
    ADD CONSTRAINT [DF_BS_Incl] DEFAULT ((1)) FOR [PricesIncludeVat];


GO
PRINT N'Creating Default Constraint [core].[DF_BS_Mode]...';


GO
ALTER TABLE [core].[BranchSettings]
    ADD CONSTRAINT [DF_BS_Mode] DEFAULT (N'walkin') FOR [DefaultCustomerMode];


GO
PRINT N'Creating Default Constraint [core].[DF_BS_ServedBy]...';


GO
ALTER TABLE [core].[BranchSettings]
    ADD CONSTRAINT [DF_BS_ServedBy] DEFAULT (N'optional') FOR [ServedByRequirement];


GO
PRINT N'Creating Default Constraint [core].[DF_BS_Updated]...';


GO
ALTER TABLE [core].[BranchSettings]
    ADD CONSTRAINT [DF_BS_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_BS_PrintGrp]...';


GO
ALTER TABLE [core].[BranchSettings]
    ADD CONSTRAINT [DF_BS_PrintGrp] DEFAULT ((1)) FOR [AutoPrintGroups];


GO
PRINT N'Creating Default Constraint [core].[DF_BS_NegStock]...';


GO
ALTER TABLE [core].[BranchSettings]
    ADD CONSTRAINT [DF_BS_NegStock] DEFAULT ((0)) FOR [AllowNegativeStock];


GO
PRINT N'Creating Default Constraint [core].[DF_BS_PrintCust]...';


GO
ALTER TABLE [core].[BranchSettings]
    ADD CONSTRAINT [DF_BS_PrintCust] DEFAULT ((1)) FOR [AutoPrintCustomer];


GO
PRINT N'Creating Default Constraint [core].[DF_Refresh_Issued]...';


GO
ALTER TABLE [core].[RefreshToken]
    ADD CONSTRAINT [DF_Refresh_Issued] DEFAULT (sysutcdatetime()) FOR [IssuedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_AppUser_Updated]...';


GO
ALTER TABLE [core].[AppUser]
    ADD CONSTRAINT [DF_AppUser_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_AppUser_Created]...';


GO
ALTER TABLE [core].[AppUser]
    ADD CONSTRAINT [DF_AppUser_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_AppUser_Status]...';


GO
ALTER TABLE [core].[AppUser]
    ADD CONSTRAINT [DF_AppUser_Status] DEFAULT (N'active') FOR [Status];


GO
PRINT N'Creating Default Constraint [core].[DF_AppUser_Salary]...';


GO
ALTER TABLE [core].[AppUser]
    ADD CONSTRAINT [DF_AppUser_Salary] DEFAULT ((0)) FOR [BaseSalaryH];


GO
PRINT N'Creating Default Constraint [core].[DF_AppUser_External]...';


GO
ALTER TABLE [core].[AppUser]
    ADD CONSTRAINT [DF_AppUser_External] DEFAULT ((0)) FOR [IsExternal];


GO
PRINT N'Creating Default Constraint [core].[DF_CatalogItem_Reorder]...';


GO
ALTER TABLE [core].[CatalogItem]
    ADD CONSTRAINT [DF_CatalogItem_Reorder] DEFAULT ((0)) FOR [ReorderLevel];


GO
PRINT N'Creating Default Constraint [core].[DF_CatalogItem_Updated]...';


GO
ALTER TABLE [core].[CatalogItem]
    ADD CONSTRAINT [DF_CatalogItem_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_CatalogItem_Tracks]...';


GO
ALTER TABLE [core].[CatalogItem]
    ADD CONSTRAINT [DF_CatalogItem_Tracks] DEFAULT ((1)) FOR [TracksStock];


GO
PRINT N'Creating Default Constraint [core].[DF_CatalogItem_Created]...';


GO
ALTER TABLE [core].[CatalogItem]
    ADD CONSTRAINT [DF_CatalogItem_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_CatalogItem_Price]...';


GO
ALTER TABLE [core].[CatalogItem]
    ADD CONSTRAINT [DF_CatalogItem_Price] DEFAULT ((0)) FOR [PriceH];


GO
PRINT N'Creating Default Constraint [core].[DF_CatalogItem_Prep]...';


GO
ALTER TABLE [core].[CatalogItem]
    ADD CONSTRAINT [DF_CatalogItem_Prep] DEFAULT ((0)) FOR [RequiresPreparation];


GO
PRINT N'Creating Default Constraint [core].[DF_CatalogItem_Active]...';


GO
ALTER TABLE [core].[CatalogItem]
    ADD CONSTRAINT [DF_CatalogItem_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_CatalogItem_Cost]...';


GO
ALTER TABLE [core].[CatalogItem]
    ADD CONSTRAINT [DF_CatalogItem_Cost] DEFAULT ((0)) FOR [CostH];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Unit]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Unit] DEFAULT ((1)) FOR [ShowUnitPrice];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_ShowBarcode]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_ShowBarcode] DEFAULT ((0)) FOR [ShowBarcode];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_ShowCompanyName]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_ShowCompanyName] DEFAULT ((1)) FOR [ShowCompanyName];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_Lang]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_Lang] DEFAULT (N'both') FOR [BillLanguage];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Cr]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Cr] DEFAULT ((1)) FOR [ShowCrNumber];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Vat]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Vat] DEFAULT ((1)) FOR [ShowVatNumber];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_ShowSku]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_ShowSku] DEFAULT ((0)) FOR [ShowSku];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_ShowAddress]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_ShowAddress] DEFAULT ((0)) FOR [ShowAddress];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Qr]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Qr] DEFAULT ((1)) FOR [ShowZatcaQr];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_ShowLineDiscount]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_ShowLineDiscount] DEFAULT ((0)) FOR [ShowLineDiscount];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_Default]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_Default] DEFAULT ((0)) FOR [IsDefault];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_ShowQuantity]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_ShowQuantity] DEFAULT ((1)) FOR [ShowQuantity];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_HeaderAlignment]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_HeaderAlignment] DEFAULT (N'center') FOR [HeaderAlignment];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Sub]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Sub] DEFAULT ((1)) FOR [ShowSubtotal];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_Paper]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_Paper] DEFAULT (N'80mm') FOR [PaperSize];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_ShowItemName]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_ShowItemName] DEFAULT ((1)) FOR [ShowItemName];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Line]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Line] DEFAULT ((1)) FOR [ShowLineTotal];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_Created]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Logo]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Logo] DEFAULT ((1)) FOR [ShowLogo];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Disc]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Disc] DEFAULT ((1)) FOR [ShowDiscount];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_Updated]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_Active]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_VatLine]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_VatLine] DEFAULT ((1)) FOR [ShowVat];


GO
PRINT N'Creating Default Constraint [core].[DF_BT_Grand]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BT_Grand] DEFAULT ((1)) FOR [ShowGrandTotal];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_ShowDescription]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_ShowDescription] DEFAULT ((1)) FOR [ShowDescription];


GO
PRINT N'Creating Default Constraint [core].[DF_BillTemplate_LogoSize]...';


GO
ALTER TABLE [core].[BillTemplate]
    ADD CONSTRAINT [DF_BillTemplate_LogoSize] DEFAULT (N'md') FOR [LogoSize];


GO
PRINT N'Creating Default Constraint [core].[DF_Otp_Created]...';


GO
ALTER TABLE [core].[OtpChallenge]
    ADD CONSTRAINT [DF_Otp_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [core].[DF_Otp_Attempts]...';


GO
ALTER TABLE [core].[OtpChallenge]
    ADD CONSTRAINT [DF_Otp_Attempts] DEFAULT ((0)) FOR [Attempts];


GO
PRINT N'Creating Default Constraint [core].[DF_Permission_Sens]...';


GO
ALTER TABLE [core].[Permission]
    ADD CONSTRAINT [DF_Permission_Sens] DEFAULT (N'general') FOR [Sensitivity];


GO
PRINT N'Creating Default Constraint [device].[DF_HB_At]...';


GO
ALTER TABLE [device].[DeviceHeartbeat]
    ADD CONSTRAINT [DF_HB_At] DEFAULT (sysutcdatetime()) FOR [ReceivedAtUtc];


GO
PRINT N'Creating Default Constraint [device].[DF_Ann_Last]...';


GO
ALTER TABLE [device].[DeviceAnnouncement]
    ADD CONSTRAINT [DF_Ann_Last] DEFAULT (sysutcdatetime()) FOR [LastSeenAtUtc];


GO
PRINT N'Creating Default Constraint [device].[DF_Ann_First]...';


GO
ALTER TABLE [device].[DeviceAnnouncement]
    ADD CONSTRAINT [DF_Ann_First] DEFAULT (sysutcdatetime()) FOR [FirstSeenAtUtc];


GO
PRINT N'Creating Default Constraint [device].[DF_Device_Paper]...';


GO
ALTER TABLE [device].[PosDevice]
    ADD CONSTRAINT [DF_Device_Paper] DEFAULT ((80)) FOR [PaperWidth];


GO
PRINT N'Creating Default Constraint [device].[DF_Device_Active]...';


GO
ALTER TABLE [device].[PosDevice]
    ADD CONSTRAINT [DF_Device_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [device].[DF_Device_Printer]...';


GO
ALTER TABLE [device].[PosDevice]
    ADD CONSTRAINT [DF_Device_Printer] DEFAULT (N'sunmi_builtin') FOR [PrinterKind];


GO
PRINT N'Creating Default Constraint [device].[DF_Device_Created]...';


GO
ALTER TABLE [device].[PosDevice]
    ADD CONSTRAINT [DF_Device_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [device].[DF_Device_Type]...';


GO
ALTER TABLE [device].[PosDevice]
    ADD CONSTRAINT [DF_Device_Type] DEFAULT (N'sunmi_v2') FOR [DeviceType];


GO
PRINT N'Creating Default Constraint [device].[DF_Device_PrinterStatus]...';


GO
ALTER TABLE [device].[PosDevice]
    ADD CONSTRAINT [DF_Device_PrinterStatus] DEFAULT (N'unknown') FOR [PrinterStatus];


GO
PRINT N'Creating Default Constraint [device].[DF_Device_PaperStatus]...';


GO
ALTER TABLE [device].[PosDevice]
    ADD CONSTRAINT [DF_Device_PaperStatus] DEFAULT (N'unknown') FOR [PaperStatus];


GO
PRINT N'Creating Default Constraint [device].[DF_Event_At]...';


GO
ALTER TABLE [device].[DeviceEvent]
    ADD CONSTRAINT [DF_Event_At] DEFAULT (sysutcdatetime()) FOR [OccurredAtUtc];


GO
PRINT N'Creating Default Constraint [device].[DF_Event_Sev]...';


GO
ALTER TABLE [device].[DeviceEvent]
    ADD CONSTRAINT [DF_Event_Sev] DEFAULT (N'info') FOR [Severity];


GO
PRINT N'Creating Default Constraint [device].[DF_Chal_At]...';


GO
ALTER TABLE [device].[DeviceChallenge]
    ADD CONSTRAINT [DF_Chal_At] DEFAULT (sysutcdatetime()) FOR [IssuedAtUtc];


GO
PRINT N'Creating Default Constraint [device].[DF_Cmd_Status]...';


GO
ALTER TABLE [device].[DeviceCommand]
    ADD CONSTRAINT [DF_Cmd_Status] DEFAULT (N'pending') FOR [Status];


GO
PRINT N'Creating Default Constraint [device].[DF_Cmd_Queued]...';


GO
ALTER TABLE [device].[DeviceCommand]
    ADD CONSTRAINT [DF_Cmd_Queued] DEFAULT (sysutcdatetime()) FOR [QueuedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_Account_Active]...';


GO
ALTER TABLE [fin].[Account]
    ADD CONSTRAINT [DF_Account_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [fin].[DF_JournalLine_Credit]...';


GO
ALTER TABLE [fin].[JournalLine]
    ADD CONSTRAINT [DF_JournalLine_Credit] DEFAULT ((0)) FOR [CreditH];


GO
PRINT N'Creating Default Constraint [fin].[DF_JournalLine_Debit]...';


GO
ALTER TABLE [fin].[JournalLine]
    ADD CONSTRAINT [DF_JournalLine_Debit] DEFAULT ((0)) FOR [DebitH];


GO
PRINT N'Creating Default Constraint [fin].[DF_CommissionRule_Updated]...';


GO
ALTER TABLE [fin].[CommissionRule]
    ADD CONSTRAINT [DF_CommissionRule_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_CommissionRule_Created]...';


GO
ALTER TABLE [fin].[CommissionRule]
    ADD CONSTRAINT [DF_CommissionRule_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_CommissionRule_Active]...';


GO
ALTER TABLE [fin].[CommissionRule]
    ADD CONSTRAINT [DF_CommissionRule_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [fin].[DF_JournalEntry_At]...';


GO
ALTER TABLE [fin].[JournalEntry]
    ADD CONSTRAINT [DF_JournalEntry_At] DEFAULT (sysutcdatetime()) FOR [PostedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_JournalEntry_Created]...';


GO
ALTER TABLE [fin].[JournalEntry]
    ADD CONSTRAINT [DF_JournalEntry_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_CommissionEntry_At]...';


GO
ALTER TABLE [fin].[CommissionEntry]
    ADD CONSTRAINT [DF_CommissionEntry_At] DEFAULT (sysutcdatetime()) FOR [EarnedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_Recurring_Method]...';


GO
ALTER TABLE [fin].[RecurringPayment]
    ADD CONSTRAINT [DF_Recurring_Method] DEFAULT (N'bank') FOR [PaymentMethod];


GO
PRINT N'Creating Default Constraint [fin].[DF_Recurring_Updated]...';


GO
ALTER TABLE [fin].[RecurringPayment]
    ADD CONSTRAINT [DF_Recurring_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_Recurring_Status]...';


GO
ALTER TABLE [fin].[RecurringPayment]
    ADD CONSTRAINT [DF_Recurring_Status] DEFAULT (N'active') FOR [Status];


GO
PRINT N'Creating Default Constraint [fin].[DF_Recurring_Created]...';


GO
ALTER TABLE [fin].[RecurringPayment]
    ADD CONSTRAINT [DF_Recurring_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_OpeningBalance_Posted]...';


GO
ALTER TABLE [fin].[OpeningBalance]
    ADD CONSTRAINT [DF_OpeningBalance_Posted] DEFAULT (sysutcdatetime()) FOR [PostedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_PayrollLine_Allow]...';


GO
ALTER TABLE [fin].[PayrollLine]
    ADD CONSTRAINT [DF_PayrollLine_Allow] DEFAULT ((0)) FOR [AllowancesH];


GO
PRINT N'Creating Default Constraint [fin].[DF_PayrollLine_Base]...';


GO
ALTER TABLE [fin].[PayrollLine]
    ADD CONSTRAINT [DF_PayrollLine_Base] DEFAULT ((0)) FOR [BaseSalaryH];


GO
PRINT N'Creating Default Constraint [fin].[DF_PayrollLine_Comm]...';


GO
ALTER TABLE [fin].[PayrollLine]
    ADD CONSTRAINT [DF_PayrollLine_Comm] DEFAULT ((0)) FOR [CommissionH];


GO
PRINT N'Creating Default Constraint [fin].[DF_PayrollLine_Ded]...';


GO
ALTER TABLE [fin].[PayrollLine]
    ADD CONSTRAINT [DF_PayrollLine_Ded] DEFAULT ((0)) FOR [DeductionsH];


GO
PRINT N'Creating Default Constraint [fin].[DF_BP_OInv]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BP_OInv] DEFAULT ((0)) FOR [OpeningInventoryH];


GO
PRINT N'Creating Default Constraint [fin].[DF_BP_OCred]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BP_OCred] DEFAULT ((0)) FOR [OpeningCreditH];


GO
PRINT N'Creating Default Constraint [fin].[DF_BalancePeriod_Created]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BalancePeriod_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_BalancePeriod_Updated]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BalancePeriod_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_BalancePeriod_Status]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BalancePeriod_Status] DEFAULT (N'open') FOR [Status];


GO
PRINT N'Creating Default Constraint [fin].[DF_BP_OPay]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BP_OPay] DEFAULT ((0)) FOR [OpeningPayablesH];


GO
PRINT N'Creating Default Constraint [fin].[DF_BP_OCard]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BP_OCard] DEFAULT ((0)) FOR [OpeningCardH];


GO
PRINT N'Creating Default Constraint [fin].[DF_BP_OBank]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BP_OBank] DEFAULT ((0)) FOR [OpeningBankH];


GO
PRINT N'Creating Default Constraint [fin].[DF_BP_OCash]...';


GO
ALTER TABLE [fin].[BalancePeriod]
    ADD CONSTRAINT [DF_BP_OCash] DEFAULT ((0)) FOR [OpeningCashH];


GO
PRINT N'Creating Default Constraint [fin].[DF_ExpenseCategory_Active]...';


GO
ALTER TABLE [fin].[ExpenseCategory]
    ADD CONSTRAINT [DF_ExpenseCategory_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [fin].[DF_ExpenseCategory_Updated]...';


GO
ALTER TABLE [fin].[ExpenseCategory]
    ADD CONSTRAINT [DF_ExpenseCategory_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_ExpenseCategory_Created]...';


GO
ALTER TABLE [fin].[ExpenseCategory]
    ADD CONSTRAINT [DF_ExpenseCategory_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_Expense_Created]...';


GO
ALTER TABLE [fin].[Expense]
    ADD CONSTRAINT [DF_Expense_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_Expense_Status]...';


GO
ALTER TABLE [fin].[Expense]
    ADD CONSTRAINT [DF_Expense_Status] DEFAULT (N'posted') FOR [Status];


GO
PRINT N'Creating Default Constraint [fin].[DF_Expense_Recognition]...';


GO
ALTER TABLE [fin].[Expense]
    ADD CONSTRAINT [DF_Expense_Recognition] DEFAULT (N'one_time') FOR [Recognition];


GO
PRINT N'Creating Default Constraint [fin].[DF_Expense_Vat]...';


GO
ALTER TABLE [fin].[Expense]
    ADD CONSTRAINT [DF_Expense_Vat] DEFAULT ((0)) FOR [VatH];


GO
PRINT N'Creating Default Constraint [fin].[DF_Expense_Updated]...';


GO
ALTER TABLE [fin].[Expense]
    ADD CONSTRAINT [DF_Expense_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_CardSettlement_Created]...';


GO
ALTER TABLE [fin].[CardSettlement]
    ADD CONSTRAINT [DF_CardSettlement_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_CardSettlement_Status]...';


GO
ALTER TABLE [fin].[CardSettlement]
    ADD CONSTRAINT [DF_CardSettlement_Status] DEFAULT (N'reconciled') FOR [Status];


GO
PRINT N'Creating Default Constraint [fin].[DF_PayrollRun_Created]...';


GO
ALTER TABLE [fin].[PayrollRun]
    ADD CONSTRAINT [DF_PayrollRun_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [fin].[DF_PayrollRun_Status]...';


GO
ALTER TABLE [fin].[PayrollRun]
    ADD CONSTRAINT [DF_PayrollRun_Status] DEFAULT (N'draft') FOR [Status];


GO
PRINT N'Creating Default Constraint [fin].[DF_PayrollRun_Total]...';


GO
ALTER TABLE [fin].[PayrollRun]
    ADD CONSTRAINT [DF_PayrollRun_Total] DEFAULT ((0)) FOR [TotalH];


GO
PRINT N'Creating Default Constraint [fin].[DF_PayrollRun_Updated]...';


GO
ALTER TABLE [fin].[PayrollRun]
    ADD CONSTRAINT [DF_PayrollRun_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [inv].[DF_StockLevel_Qty]...';


GO
ALTER TABLE [inv].[StockLevel]
    ADD CONSTRAINT [DF_StockLevel_Qty] DEFAULT ((0)) FOR [Quantity];


GO
PRINT N'Creating Default Constraint [inv].[DF_StockLevel_Updated]...';


GO
ALTER TABLE [inv].[StockLevel]
    ADD CONSTRAINT [DF_StockLevel_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [inv].[DF_StockMovement_Cost]...';


GO
ALTER TABLE [inv].[StockMovement]
    ADD CONSTRAINT [DF_StockMovement_Cost] DEFAULT ((0)) FOR [UnitCostH];


GO
PRINT N'Creating Default Constraint [inv].[DF_StockMovement_Actor]...';


GO
ALTER TABLE [inv].[StockMovement]
    ADD CONSTRAINT [DF_StockMovement_Actor] DEFAULT (N'System') FOR [Actor];


GO
PRINT N'Creating Default Constraint [inv].[DF_StockMovement_At]...';


GO
ALTER TABLE [inv].[StockMovement]
    ADD CONSTRAINT [DF_StockMovement_At] DEFAULT (sysutcdatetime()) FOR [OccurredAtUtc];


GO
PRINT N'Creating Default Constraint [inv].[DF_VendorPayment_Created]...';


GO
ALTER TABLE [inv].[VendorPayment]
    ADD CONSTRAINT [DF_VendorPayment_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [inv].[DF_VendorPayment_PaidAt]...';


GO
ALTER TABLE [inv].[VendorPayment]
    ADD CONSTRAINT [DF_VendorPayment_PaidAt] DEFAULT (sysutcdatetime()) FOR [PaidAtUtc];


GO
PRINT N'Creating Default Constraint [inv].[DF_Purchase_At]...';


GO
ALTER TABLE [inv].[Purchase]
    ADD CONSTRAINT [DF_Purchase_At] DEFAULT (sysutcdatetime()) FOR [ReceivedAtUtc];


GO
PRINT N'Creating Default Constraint [inv].[DF_Purchase_Paid]...';


GO
ALTER TABLE [inv].[Purchase]
    ADD CONSTRAINT [DF_Purchase_Paid] DEFAULT ((0)) FOR [PaidOnReceipt];


GO
PRINT N'Creating Default Constraint [inv].[DF_Purchase_PaidH]...';


GO
ALTER TABLE [inv].[Purchase]
    ADD CONSTRAINT [DF_Purchase_PaidH] DEFAULT ((0)) FOR [PaidH];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleLine_Cost]...';


GO
ALTER TABLE [sales].[SaleLine]
    ADD CONSTRAINT [DF_SaleLine_Cost] DEFAULT ((0)) FOR [UnitCostH];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleLine_Discount]...';


GO
ALTER TABLE [sales].[SaleLine]
    ADD CONSTRAINT [DF_SaleLine_Discount] DEFAULT ((0)) FOR [LineDiscountH];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleLine_Returned]...';


GO
ALTER TABLE [sales].[SaleLine]
    ADD CONSTRAINT [DF_SaleLine_Returned] DEFAULT ((0)) FOR [ReturnedQty];


GO
PRINT N'Creating Default Constraint [sales].[DF_Sale_Change]...';


GO
ALTER TABLE [sales].[Sale]
    ADD CONSTRAINT [DF_Sale_Change] DEFAULT ((0)) FOR [ChangeH];


GO
PRINT N'Creating Default Constraint [sales].[DF_Sale_Created]...';


GO
ALTER TABLE [sales].[Sale]
    ADD CONSTRAINT [DF_Sale_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [sales].[DF_Sale_Discount]...';


GO
ALTER TABLE [sales].[Sale]
    ADD CONSTRAINT [DF_Sale_Discount] DEFAULT ((0)) FOR [DiscountH];


GO
PRINT N'Creating Default Constraint [sales].[DF_Sale_SoldAt]...';


GO
ALTER TABLE [sales].[Sale]
    ADD CONSTRAINT [DF_Sale_SoldAt] DEFAULT (sysutcdatetime()) FOR [SoldAtUtc];


GO
PRINT N'Creating Default Constraint [sales].[DF_Sale_Status]...';


GO
ALTER TABLE [sales].[Sale]
    ADD CONSTRAINT [DF_Sale_Status] DEFAULT (N'completed') FOR [Status];


GO
PRINT N'Creating Default Constraint [sales].[DF_Sale_Updated]...';


GO
ALTER TABLE [sales].[Sale]
    ADD CONSTRAINT [DF_Sale_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_Active]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_Active] DEFAULT ((1)) FOR [IsActive];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_Applies]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_Applies] DEFAULT (N'all') FOR [AppliesTo];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_Auto]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_Auto] DEFAULT ((0)) FOR [IsAutomatic];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_Created]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_Days]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_Days] DEFAULT (N'') FOR [ActiveDays];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_MinSub]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_MinSub] DEFAULT ((0)) FOR [MinSubtotalH];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_Stack]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_Stack] DEFAULT ((0)) FOR [AllowStacking];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_Updated]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Default Constraint [sales].[DF_Discount_Usage]...';


GO
ALTER TABLE [sales].[Discount]
    ADD CONSTRAINT [DF_Discount_Usage] DEFAULT ((0)) FOR [UsageCount];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleReturn_At]...';


GO
ALTER TABLE [sales].[SaleReturn]
    ADD CONSTRAINT [DF_SaleReturn_At] DEFAULT (sysutcdatetime()) FOR [ReturnedAtUtc];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleReturn_Cogs]...';


GO
ALTER TABLE [sales].[SaleReturn]
    ADD CONSTRAINT [DF_SaleReturn_Cogs] DEFAULT ((0)) FOR [CogsH];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleReturn_Subtotal]...';


GO
ALTER TABLE [sales].[SaleReturn]
    ADD CONSTRAINT [DF_SaleReturn_Subtotal] DEFAULT ((0)) FOR [SubtotalH];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleReturn_Tax]...';


GO
ALTER TABLE [sales].[SaleReturn]
    ADD CONSTRAINT [DF_SaleReturn_Tax] DEFAULT ((0)) FOR [TaxH];


GO
PRINT N'Creating Default Constraint [sales].[DF_PreparationItem_Done]...';


GO
ALTER TABLE [sales].[PreparationItem]
    ADD CONSTRAINT [DF_PreparationItem_Done] DEFAULT ((0)) FOR [CompletedQty];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleReturnLine_Price]...';


GO
ALTER TABLE [sales].[SaleReturnLine]
    ADD CONSTRAINT [DF_SaleReturnLine_Price] DEFAULT ((0)) FOR [UnitPriceH];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleReturnLine_Amount]...';


GO
ALTER TABLE [sales].[SaleReturnLine]
    ADD CONSTRAINT [DF_SaleReturnLine_Amount] DEFAULT ((0)) FOR [AmountH];


GO
PRINT N'Creating Default Constraint [sales].[DF_SaleReturnLine_Cost]...';


GO
ALTER TABLE [sales].[SaleReturnLine]
    ADD CONSTRAINT [DF_SaleReturnLine_Cost] DEFAULT ((0)) FOR [UnitCostH];


GO
PRINT N'Creating Default Constraint [sales].[DF_Preparation_Created]...';


GO
ALTER TABLE [sales].[PreparationOrder]
    ADD CONSTRAINT [DF_Preparation_Created] DEFAULT (sysutcdatetime()) FOR [CreatedAtUtc];


GO
PRINT N'Creating Default Constraint [sales].[DF_Preparation_Status]...';


GO
ALTER TABLE [sales].[PreparationOrder]
    ADD CONSTRAINT [DF_Preparation_Status] DEFAULT (N'open') FOR [Status];


GO
PRINT N'Creating Default Constraint [sales].[DF_Preparation_Total]...';


GO
ALTER TABLE [sales].[PreparationOrder]
    ADD CONSTRAINT [DF_Preparation_Total] DEFAULT ((0)) FOR [TotalH];


GO
PRINT N'Creating Default Constraint [sales].[DF_Preparation_Updated]...';


GO
ALTER TABLE [sales].[PreparationOrder]
    ADD CONSTRAINT [DF_Preparation_Updated] DEFAULT (sysutcdatetime()) FOR [UpdatedAtUtc];


GO
PRINT N'Creating Sequence [core].[BranchSequence]...';


GO
CREATE SEQUENCE [core].[BranchSequence]
    AS INT
    START WITH 100
    INCREMENT BY 1;


GO





GO
PRINT N'Creating Sequence [fin].[JournalSequence]...';


GO
CREATE SEQUENCE [fin].[JournalSequence]
    AS BIGINT
    START WITH 1001
    INCREMENT BY 1;


GO





GO
PRINT N'Creating Sequence [fin].[SettlementSequence]...';


GO
CREATE SEQUENCE [fin].[SettlementSequence]
    AS BIGINT
    START WITH 300
    INCREMENT BY 1;


GO
PRINT N'Creating Sequence [fin].[PayrollSequence]...';


GO
CREATE SEQUENCE [fin].[PayrollSequence]
    AS BIGINT
    START WITH 100
    INCREMENT BY 1;


GO


GO
PRINT N'Creating Sequence [fin].[ExpenseSequence]...';


GO
CREATE SEQUENCE [fin].[ExpenseSequence]
    AS BIGINT
    START WITH 400
    INCREMENT BY 1;


GO
PRINT N'Creating Sequence [inv].[VendorPaymentSequence]...';


GO
CREATE SEQUENCE [inv].[VendorPaymentSequence]
    AS BIGINT
    START WITH 100
    INCREMENT BY 1;


GO



GO
PRINT N'Creating Sequence [inv].[PurchaseSequence]...';


GO
CREATE SEQUENCE [inv].[PurchaseSequence]
    AS BIGINT
    START WITH 500
    INCREMENT BY 1;


GO





GO
PRINT N'Creating Sequence [sales].[CreditNoteSequence]...';


GO
CREATE SEQUENCE [sales].[CreditNoteSequence]
    AS BIGINT
    START WITH 200
    INCREMENT BY 1;


GO





GO
PRINT N'Creating Sequence [sales].[InvoiceSequence]...';


GO
CREATE SEQUENCE [sales].[InvoiceSequence]
    AS BIGINT
    START WITH 1001
    INCREMENT BY 1;


GO





GO
PRINT N'Creating Foreign Key [core].[FK_Translation_Language]...';


GO
ALTER TABLE [core].[Translation] WITH NOCHECK
    ADD CONSTRAINT [FK_Translation_Language] FOREIGN KEY ([LanguageCode]) REFERENCES [core].[Language] ([Code]);


GO
PRINT N'Creating Foreign Key [core].[FK_Notification_Branch]...';


GO
ALTER TABLE [core].[Notification] WITH NOCHECK
    ADD CONSTRAINT [FK_Notification_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [core].[FK_Notification_User]...';


GO
ALTER TABLE [core].[Notification] WITH NOCHECK
    ADD CONSTRAINT [FK_Notification_User] FOREIGN KEY ([UserId]) REFERENCES [core].[AppUser] ([UserId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [core].[FK_UserOverride_Permission]...';


GO
ALTER TABLE [core].[UserPermissionOverride] WITH NOCHECK
    ADD CONSTRAINT [FK_UserOverride_Permission] FOREIGN KEY ([PermissionKey]) REFERENCES [core].[Permission] ([PermissionKey]);


GO
PRINT N'Creating Foreign Key [core].[FK_UserOverride_User]...';


GO
ALTER TABLE [core].[UserPermissionOverride] WITH NOCHECK
    ADD CONSTRAINT [FK_UserOverride_User] FOREIGN KEY ([UserId]) REFERENCES [core].[AppUser] ([UserId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [core].[FK_RolePermission_Permission]...';


GO
ALTER TABLE [core].[RolePermission] WITH NOCHECK
    ADD CONSTRAINT [FK_RolePermission_Permission] FOREIGN KEY ([PermissionKey]) REFERENCES [core].[Permission] ([PermissionKey]);


GO
PRINT N'Creating Foreign Key [core].[FK_RolePermission_Role]...';


GO
ALTER TABLE [core].[RolePermission] WITH NOCHECK
    ADD CONSTRAINT [FK_RolePermission_Role] FOREIGN KEY ([RoleId]) REFERENCES [core].[Role] ([RoleId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [core].[FK_UserBranch_User]...';


GO
ALTER TABLE [core].[UserBranch] WITH NOCHECK
    ADD CONSTRAINT [FK_UserBranch_User] FOREIGN KEY ([UserId]) REFERENCES [core].[AppUser] ([UserId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [core].[FK_UserBranch_Branch]...';


GO
ALTER TABLE [core].[UserBranch] WITH NOCHECK
    ADD CONSTRAINT [FK_UserBranch_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [core].[FK_BranchSettings_Bill]...';


GO
ALTER TABLE [core].[BranchSettings] WITH NOCHECK
    ADD CONSTRAINT [FK_BranchSettings_Bill] FOREIGN KEY ([DefaultBillId]) REFERENCES [core].[BillTemplate] ([BillId]);


GO
PRINT N'Creating Foreign Key [core].[FK_BranchSettings_Branch]...';


GO
ALTER TABLE [core].[BranchSettings] WITH NOCHECK
    ADD CONSTRAINT [FK_BranchSettings_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [core].[FK_RefreshToken_User]...';


GO
ALTER TABLE [core].[RefreshToken] WITH NOCHECK
    ADD CONSTRAINT [FK_RefreshToken_User] FOREIGN KEY ([UserId]) REFERENCES [core].[AppUser] ([UserId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [core].[FK_AppUser_Role]...';


GO
ALTER TABLE [core].[AppUser] WITH NOCHECK
    ADD CONSTRAINT [FK_AppUser_Role] FOREIGN KEY ([RoleId]) REFERENCES [core].[Role] ([RoleId]);


GO
PRINT N'Creating Foreign Key [core].[FK_AppUser_DefaultBranch]...';


GO
ALTER TABLE [core].[AppUser] WITH NOCHECK
    ADD CONSTRAINT [FK_AppUser_DefaultBranch] FOREIGN KEY ([DefaultBranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [core].[FK_CatalogItem_Vendor]...';


GO
ALTER TABLE [core].[CatalogItem] WITH NOCHECK
    ADD CONSTRAINT [FK_CatalogItem_Vendor] FOREIGN KEY ([VendorId]) REFERENCES [core].[Vendor] ([VendorId]);


GO
PRINT N'Creating Foreign Key [core].[FK_CatalogItem_Category]...';


GO
ALTER TABLE [core].[CatalogItem] WITH NOCHECK
    ADD CONSTRAINT [FK_CatalogItem_Category] FOREIGN KEY ([CategoryId]) REFERENCES [core].[Category] ([CategoryId]);


GO
PRINT N'Creating Foreign Key [core].[FK_CatalogItem_PrintGroup]...';


GO
ALTER TABLE [core].[CatalogItem] WITH NOCHECK
    ADD CONSTRAINT [FK_CatalogItem_PrintGroup] FOREIGN KEY ([PrintGroupId]) REFERENCES [core].[PrintGroup] ([PrintGroupId]);


GO
PRINT N'Creating Foreign Key [core].[FK_BillTemplate_Group]...';


GO
ALTER TABLE [core].[BillTemplate] WITH NOCHECK
    ADD CONSTRAINT [FK_BillTemplate_Group] FOREIGN KEY ([PrintGroupId]) REFERENCES [core].[PrintGroup] ([PrintGroupId]);


GO
PRINT N'Creating Foreign Key [device].[FK_Heartbeat_Device]...';


GO
ALTER TABLE [device].[DeviceHeartbeat] WITH NOCHECK
    ADD CONSTRAINT [FK_Heartbeat_Device] FOREIGN KEY ([DeviceId]) REFERENCES [device].[PosDevice] ([DeviceId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [device].[FK_PosDevice_Branch]...';


GO
ALTER TABLE [device].[PosDevice] WITH NOCHECK
    ADD CONSTRAINT [FK_PosDevice_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [device].[FK_Event_Device]...';


GO
ALTER TABLE [device].[DeviceEvent] WITH NOCHECK
    ADD CONSTRAINT [FK_Event_Device] FOREIGN KEY ([DeviceId]) REFERENCES [device].[PosDevice] ([DeviceId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [device].[FK_Command_Device]...';


GO
ALTER TABLE [device].[DeviceCommand] WITH NOCHECK
    ADD CONSTRAINT [FK_Command_Device] FOREIGN KEY ([DeviceId]) REFERENCES [device].[PosDevice] ([DeviceId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [fin].[FK_CRI_Item]...';


GO
ALTER TABLE [fin].[CommissionRuleItem] WITH NOCHECK
    ADD CONSTRAINT [FK_CRI_Item] FOREIGN KEY ([ItemId]) REFERENCES [core].[CatalogItem] ([ItemId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [fin].[FK_CRI_Rule]...';


GO
ALTER TABLE [fin].[CommissionRuleItem] WITH NOCHECK
    ADD CONSTRAINT [FK_CRI_Rule] FOREIGN KEY ([RuleId]) REFERENCES [fin].[CommissionRule] ([RuleId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [fin].[FK_JournalLine_Account]...';


GO
ALTER TABLE [fin].[JournalLine] WITH NOCHECK
    ADD CONSTRAINT [FK_JournalLine_Account] FOREIGN KEY ([AccountCode]) REFERENCES [fin].[Account] ([AccountCode]);


GO
PRINT N'Creating Foreign Key [fin].[FK_JournalLine_Entry]...';


GO
ALTER TABLE [fin].[JournalLine] WITH NOCHECK
    ADD CONSTRAINT [FK_JournalLine_Entry] FOREIGN KEY ([EntryId]) REFERENCES [fin].[JournalEntry] ([EntryId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [fin].[FK_JournalEntry_Reverses]...';


GO
ALTER TABLE [fin].[JournalEntry] WITH NOCHECK
    ADD CONSTRAINT [FK_JournalEntry_Reverses] FOREIGN KEY ([ReversesEntryId]) REFERENCES [fin].[JournalEntry] ([EntryId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_JournalEntry_Branch]...';


GO
ALTER TABLE [fin].[JournalEntry] WITH NOCHECK
    ADD CONSTRAINT [FK_JournalEntry_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_CommissionEntry_Sale]...';


GO
ALTER TABLE [fin].[CommissionEntry] WITH NOCHECK
    ADD CONSTRAINT [FK_CommissionEntry_Sale] FOREIGN KEY ([SaleId]) REFERENCES [sales].[Sale] ([SaleId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_CommissionEntry_Item]...';


GO
ALTER TABLE [fin].[CommissionEntry] WITH NOCHECK
    ADD CONSTRAINT [FK_CommissionEntry_Item] FOREIGN KEY ([ItemId]) REFERENCES [core].[CatalogItem] ([ItemId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_CommissionEntry_User]...';


GO
ALTER TABLE [fin].[CommissionEntry] WITH NOCHECK
    ADD CONSTRAINT [FK_CommissionEntry_User] FOREIGN KEY ([UserId]) REFERENCES [core].[AppUser] ([UserId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_CommissionEntry_Run]...';


GO
ALTER TABLE [fin].[CommissionEntry] WITH NOCHECK
    ADD CONSTRAINT [FK_CommissionEntry_Run] FOREIGN KEY ([PayrollRunId]) REFERENCES [fin].[PayrollRun] ([RunId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_Recurring_Branch]...';


GO
ALTER TABLE [fin].[RecurringPayment] WITH NOCHECK
    ADD CONSTRAINT [FK_Recurring_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_Recurring_Category]...';


GO
ALTER TABLE [fin].[RecurringPayment] WITH NOCHECK
    ADD CONSTRAINT [FK_Recurring_Category] FOREIGN KEY ([CategoryId]) REFERENCES [fin].[ExpenseCategory] ([CategoryId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_OpeningBalance_Branch]...';


GO
ALTER TABLE [fin].[OpeningBalance] WITH NOCHECK
    ADD CONSTRAINT [FK_OpeningBalance_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_OpeningBalance_Entry]...';


GO
ALTER TABLE [fin].[OpeningBalance] WITH NOCHECK
    ADD CONSTRAINT [FK_OpeningBalance_Entry] FOREIGN KEY ([EntryId]) REFERENCES [fin].[JournalEntry] ([EntryId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_PayrollLine_Run]...';


GO
ALTER TABLE [fin].[PayrollLine] WITH NOCHECK
    ADD CONSTRAINT [FK_PayrollLine_Run] FOREIGN KEY ([RunId]) REFERENCES [fin].[PayrollRun] ([RunId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [fin].[FK_PayrollLine_User]...';


GO
ALTER TABLE [fin].[PayrollLine] WITH NOCHECK
    ADD CONSTRAINT [FK_PayrollLine_User] FOREIGN KEY ([UserId]) REFERENCES [core].[AppUser] ([UserId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_ExpenseRecognition_Expense]...';


GO
ALTER TABLE [fin].[ExpenseRecognition] WITH NOCHECK
    ADD CONSTRAINT [FK_ExpenseRecognition_Expense] FOREIGN KEY ([ExpenseId]) REFERENCES [fin].[Expense] ([ExpenseId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [fin].[FK_BalancePeriod_Branch]...';


GO
ALTER TABLE [fin].[BalancePeriod] WITH NOCHECK
    ADD CONSTRAINT [FK_BalancePeriod_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_CRU_Rule]...';


GO
ALTER TABLE [fin].[CommissionRuleUser] WITH NOCHECK
    ADD CONSTRAINT [FK_CRU_Rule] FOREIGN KEY ([RuleId]) REFERENCES [fin].[CommissionRule] ([RuleId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [fin].[FK_CRU_User]...';


GO
ALTER TABLE [fin].[CommissionRuleUser] WITH NOCHECK
    ADD CONSTRAINT [FK_CRU_User] FOREIGN KEY ([UserId]) REFERENCES [core].[AppUser] ([UserId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [fin].[FK_ExpenseCategory_Account]...';


GO
ALTER TABLE [fin].[ExpenseCategory] WITH NOCHECK
    ADD CONSTRAINT [FK_ExpenseCategory_Account] FOREIGN KEY ([AccountCode]) REFERENCES [fin].[Account] ([AccountCode]);


GO
PRINT N'Creating Foreign Key [fin].[FK_Expense_Branch]...';


GO
ALTER TABLE [fin].[Expense] WITH NOCHECK
    ADD CONSTRAINT [FK_Expense_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_Expense_Category]...';


GO
ALTER TABLE [fin].[Expense] WITH NOCHECK
    ADD CONSTRAINT [FK_Expense_Category] FOREIGN KEY ([CategoryId]) REFERENCES [fin].[ExpenseCategory] ([CategoryId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_DrawerSession_Branch]...';


GO
ALTER TABLE [fin].[DrawerSession] WITH NOCHECK
    ADD CONSTRAINT [FK_DrawerSession_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_CardSettlement_Branch]...';


GO
ALTER TABLE [fin].[CardSettlement] WITH NOCHECK
    ADD CONSTRAINT [FK_CardSettlement_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [fin].[FK_PayrollRun_Branch]...';


GO
ALTER TABLE [fin].[PayrollRun] WITH NOCHECK
    ADD CONSTRAINT [FK_PayrollRun_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_StockLevel_Branch]...';


GO
ALTER TABLE [inv].[StockLevel] WITH NOCHECK
    ADD CONSTRAINT [FK_StockLevel_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_StockLevel_Item]...';


GO
ALTER TABLE [inv].[StockLevel] WITH NOCHECK
    ADD CONSTRAINT [FK_StockLevel_Item] FOREIGN KEY ([ItemId]) REFERENCES [core].[CatalogItem] ([ItemId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [inv].[FK_PurchaseLine_Item]...';


GO
ALTER TABLE [inv].[PurchaseLine] WITH NOCHECK
    ADD CONSTRAINT [FK_PurchaseLine_Item] FOREIGN KEY ([ItemId]) REFERENCES [core].[CatalogItem] ([ItemId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_PurchaseLine_Purchase]...';


GO
ALTER TABLE [inv].[PurchaseLine] WITH NOCHECK
    ADD CONSTRAINT [FK_PurchaseLine_Purchase] FOREIGN KEY ([PurchaseId]) REFERENCES [inv].[Purchase] ([PurchaseId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [inv].[FK_StockMovement_Branch]...';


GO
ALTER TABLE [inv].[StockMovement] WITH NOCHECK
    ADD CONSTRAINT [FK_StockMovement_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_StockMovement_Item]...';


GO
ALTER TABLE [inv].[StockMovement] WITH NOCHECK
    ADD CONSTRAINT [FK_StockMovement_Item] FOREIGN KEY ([ItemId]) REFERENCES [core].[CatalogItem] ([ItemId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_VendorPayment_Entry]...';


GO
ALTER TABLE [inv].[VendorPayment] WITH NOCHECK
    ADD CONSTRAINT [FK_VendorPayment_Entry] FOREIGN KEY ([EntryId]) REFERENCES [fin].[JournalEntry] ([EntryId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_VendorPayment_Vendor]...';


GO
ALTER TABLE [inv].[VendorPayment] WITH NOCHECK
    ADD CONSTRAINT [FK_VendorPayment_Vendor] FOREIGN KEY ([VendorId]) REFERENCES [core].[Vendor] ([VendorId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_VendorPayment_Branch]...';


GO
ALTER TABLE [inv].[VendorPayment] WITH NOCHECK
    ADD CONSTRAINT [FK_VendorPayment_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_Purchase_Branch]...';


GO
ALTER TABLE [inv].[Purchase] WITH NOCHECK
    ADD CONSTRAINT [FK_Purchase_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_Purchase_Vendor]...';


GO
ALTER TABLE [inv].[Purchase] WITH NOCHECK
    ADD CONSTRAINT [FK_Purchase_Vendor] FOREIGN KEY ([VendorId]) REFERENCES [core].[Vendor] ([VendorId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_VPA_Payment]...';


GO
ALTER TABLE [inv].[VendorPaymentAllocation] WITH NOCHECK
    ADD CONSTRAINT [FK_VPA_Payment] FOREIGN KEY ([PaymentId]) REFERENCES [inv].[VendorPayment] ([PaymentId]);


GO
PRINT N'Creating Foreign Key [inv].[FK_VPA_Purchase]...';


GO
ALTER TABLE [inv].[VendorPaymentAllocation] WITH NOCHECK
    ADD CONSTRAINT [FK_VPA_Purchase] FOREIGN KEY ([PurchaseId]) REFERENCES [inv].[Purchase] ([PurchaseId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_SaleLine_Sale]...';


GO
ALTER TABLE [sales].[SaleLine] WITH NOCHECK
    ADD CONSTRAINT [FK_SaleLine_Sale] FOREIGN KEY ([SaleId]) REFERENCES [sales].[Sale] ([SaleId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [sales].[FK_SaleLine_Item]...';


GO
ALTER TABLE [sales].[SaleLine] WITH NOCHECK
    ADD CONSTRAINT [FK_SaleLine_Item] FOREIGN KEY ([ItemId]) REFERENCES [core].[CatalogItem] ([ItemId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_Sale_ServedBy]...';


GO
ALTER TABLE [sales].[Sale] WITH NOCHECK
    ADD CONSTRAINT [FK_Sale_ServedBy] FOREIGN KEY ([ServedByUserId]) REFERENCES [core].[AppUser] ([UserId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_Sale_Customer]...';


GO
ALTER TABLE [sales].[Sale] WITH NOCHECK
    ADD CONSTRAINT [FK_Sale_Customer] FOREIGN KEY ([CustomerId]) REFERENCES [core].[Customer] ([CustomerId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_Sale_Discount_Ref]...';


GO
ALTER TABLE [sales].[Sale] WITH NOCHECK
    ADD CONSTRAINT [FK_Sale_Discount_Ref] FOREIGN KEY ([DiscountId]) REFERENCES [sales].[Discount] ([DiscountId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_Sale_Branch]...';


GO
ALTER TABLE [sales].[Sale] WITH NOCHECK
    ADD CONSTRAINT [FK_Sale_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_DiscountScope_Discount]...';


GO
ALTER TABLE [sales].[DiscountScope] WITH NOCHECK
    ADD CONSTRAINT [FK_DiscountScope_Discount] FOREIGN KEY ([DiscountId]) REFERENCES [sales].[Discount] ([DiscountId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [sales].[FK_SaleReturn_Sale]...';


GO
ALTER TABLE [sales].[SaleReturn] WITH NOCHECK
    ADD CONSTRAINT [FK_SaleReturn_Sale] FOREIGN KEY ([SaleId]) REFERENCES [sales].[Sale] ([SaleId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_PreparationItem_Order]...';


GO
ALTER TABLE [sales].[PreparationItem] WITH NOCHECK
    ADD CONSTRAINT [FK_PreparationItem_Order] FOREIGN KEY ([PreparationId]) REFERENCES [sales].[PreparationOrder] ([PreparationId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [sales].[FK_PreparationItem_Item]...';


GO
ALTER TABLE [sales].[PreparationItem] WITH NOCHECK
    ADD CONSTRAINT [FK_PreparationItem_Item] FOREIGN KEY ([ItemId]) REFERENCES [core].[CatalogItem] ([ItemId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_SalePayment_Sale]...';


GO
ALTER TABLE [sales].[SalePayment] WITH NOCHECK
    ADD CONSTRAINT [FK_SalePayment_Sale] FOREIGN KEY ([SaleId]) REFERENCES [sales].[Sale] ([SaleId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [sales].[FK_SaleReturnLine_Return]...';


GO
ALTER TABLE [sales].[SaleReturnLine] WITH NOCHECK
    ADD CONSTRAINT [FK_SaleReturnLine_Return] FOREIGN KEY ([ReturnId]) REFERENCES [sales].[SaleReturn] ([ReturnId]) ON DELETE CASCADE;


GO
PRINT N'Creating Foreign Key [sales].[FK_SaleReturnLine_Line]...';


GO
ALTER TABLE [sales].[SaleReturnLine] WITH NOCHECK
    ADD CONSTRAINT [FK_SaleReturnLine_Line] FOREIGN KEY ([SaleLineId]) REFERENCES [sales].[SaleLine] ([SaleLineId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_Preparation_Group]...';


GO
ALTER TABLE [sales].[PreparationOrder] WITH NOCHECK
    ADD CONSTRAINT [FK_Preparation_Group] FOREIGN KEY ([PrintGroupId]) REFERENCES [core].[PrintGroup] ([PrintGroupId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_Preparation_Sale]...';


GO
ALTER TABLE [sales].[PreparationOrder] WITH NOCHECK
    ADD CONSTRAINT [FK_Preparation_Sale] FOREIGN KEY ([SaleId]) REFERENCES [sales].[Sale] ([SaleId]);


GO
PRINT N'Creating Foreign Key [sales].[FK_Preparation_Branch]...';


GO
ALTER TABLE [sales].[PreparationOrder] WITH NOCHECK
    ADD CONSTRAINT [FK_Preparation_Branch] FOREIGN KEY ([BranchId]) REFERENCES [core].[Branch] ([BranchId]);


GO
PRINT N'Creating Check Constraint [audit].[CK_Timing_Ms]...';


GO
ALTER TABLE [audit].[RequestTiming] WITH NOCHECK
    ADD CONSTRAINT [CK_Timing_Ms] CHECK ([TotalMs]>=(0) AND [DatabaseMs]>=(0));


GO
PRINT N'Creating Check Constraint [audit].[CK_QueryTiming_Type]...';


GO
ALTER TABLE [audit].[QueryTiming] WITH NOCHECK
    ADD CONSTRAINT [CK_QueryTiming_Type] CHECK ([QueryType]=N'OTHER' OR [QueryType]=N'PROCEDURE' OR [QueryType]=N'DELETE' OR [QueryType]=N'UPDATE' OR [QueryType]=N'INSERT' OR [QueryType]=N'SELECT');


GO
PRINT N'Creating Check Constraint [audit].[CK_QueryTiming_Ms]...';


GO
ALTER TABLE [audit].[QueryTiming] WITH NOCHECK
    ADD CONSTRAINT [CK_QueryTiming_Ms] CHECK ([DurationMs]>=(0));


GO
PRINT N'Creating Check Constraint [audit].[CK_Audit_Result]...';


GO
ALTER TABLE [audit].[AuditEntry] WITH NOCHECK
    ADD CONSTRAINT [CK_Audit_Result] CHECK ([Result]=N'denied' OR [Result]=N'failure' OR [Result]=N'success');


GO
PRINT N'Creating Check Constraint [audit].[CK_Audit_Action]...';


GO
ALTER TABLE [audit].[AuditEntry] WITH NOCHECK
    ADD CONSTRAINT [CK_Audit_Action] CHECK ([Action]=N'LOGIN_FAILED' OR [Action]=N'EXPORT' OR [Action]=N'REVERSE' OR [Action]=N'VOID' OR [Action]=N'STATUS_CHANGE' OR [Action]=N'PAYMENT' OR [Action]=N'LOGOUT' OR [Action]=N'LOGIN' OR [Action]=N'VIEW' OR [Action]=N'DELETE' OR [Action]=N'UPDATE' OR [Action]=N'CREATE');


GO
PRINT N'Creating Check Constraint [core].[CK_Category_AppliesTo]...';


GO
ALTER TABLE [core].[Category] WITH NOCHECK
    ADD CONSTRAINT [CK_Category_AppliesTo] CHECK ([AppliesTo]=N'both' OR [AppliesTo]=N'service' OR [AppliesTo]=N'product');


GO
PRINT N'Creating Check Constraint [core].[CK_Customer_Type]...';


GO
ALTER TABLE [core].[Customer] WITH NOCHECK
    ADD CONSTRAINT [CK_Customer_Type] CHECK ([CustomerType]=N'business' OR [CustomerType]=N'individual');


GO
PRINT N'Creating Check Constraint [core].[CK_Customer_Limit]...';


GO
ALTER TABLE [core].[Customer] WITH NOCHECK
    ADD CONSTRAINT [CK_Customer_Limit] CHECK ([CreditLimitH]>=(0));


GO
PRINT N'Creating Check Constraint [core].[CK_Notification_Severity]...';


GO
ALTER TABLE [core].[Notification] WITH NOCHECK
    ADD CONSTRAINT [CK_Notification_Severity] CHECK ([Severity]=N'success' OR [Severity]=N'danger' OR [Severity]=N'warning' OR [Severity]=N'info');


GO
PRINT N'Creating Check Constraint [core].[CK_UserOverride_Effect]...';


GO
ALTER TABLE [core].[UserPermissionOverride] WITH NOCHECK
    ADD CONSTRAINT [CK_UserOverride_Effect] CHECK ([Effect]=N'deny' OR [Effect]=N'grant');


GO
PRINT N'Creating Check Constraint [core].[CK_Company_Cr]...';


GO
ALTER TABLE [core].[Company] WITH NOCHECK
    ADD CONSTRAINT [CK_Company_Cr] CHECK ([CrNumber] IS NULL OR len([CrNumber])=(10) AND NOT [CrNumber] like N'%[^0-9]%');


GO
PRINT N'Creating Check Constraint [core].[CK_Company_Vat]...';


GO
ALTER TABLE [core].[Company] WITH NOCHECK
    ADD CONSTRAINT [CK_Company_Vat] CHECK ([VatNumber] IS NULL OR len([VatNumber])=(15) AND NOT [VatNumber] like N'%[^0-9]%' AND left([VatNumber],(1))=N'3' AND right([VatNumber],(1))=N'3');


GO
PRINT N'Creating Check Constraint [core].[CK_Company_SocialJson]...';


GO
ALTER TABLE [core].[Company] WITH NOCHECK
    ADD CONSTRAINT [CK_Company_SocialJson] CHECK ([SocialLinks] IS NULL OR isjson([SocialLinks])=(1));


GO
PRINT N'Creating Check Constraint [core].[CK_Vendor_Terms]...';


GO
ALTER TABLE [core].[Vendor] WITH NOCHECK
    ADD CONSTRAINT [CK_Vendor_Terms] CHECK ([PaymentTermDays]>=(0));


GO
PRINT N'Creating Check Constraint [core].[CK_BS_Mode]...';


GO
ALTER TABLE [core].[BranchSettings] WITH NOCHECK
    ADD CONSTRAINT [CK_BS_Mode] CHECK ([DefaultCustomerMode]=N'customer' OR [DefaultCustomerMode]=N'walkin');


GO
PRINT N'Creating Check Constraint [core].[CK_BS_Vat]...';


GO
ALTER TABLE [core].[BranchSettings] WITH NOCHECK
    ADD CONSTRAINT [CK_BS_Vat] CHECK ([VatRatePercent]>=(0) AND [VatRatePercent]<=(100));


GO
PRINT N'Creating Check Constraint [core].[CK_BS_ServedBy]...';


GO
ALTER TABLE [core].[BranchSettings] WITH NOCHECK
    ADD CONSTRAINT [CK_BS_ServedBy] CHECK ([ServedByRequirement]=N'required' OR [ServedByRequirement]=N'optional' OR [ServedByRequirement]=N'off');


GO
PRINT N'Creating Check Constraint [core].[CK_AppUser_Status]...';


GO
ALTER TABLE [core].[AppUser] WITH NOCHECK
    ADD CONSTRAINT [CK_AppUser_Status] CHECK ([Status]=N'expired' OR [Status]=N'suspended' OR [Status]=N'active');


GO
PRINT N'Creating Check Constraint [core].[CK_AppUser_Salary]...';


GO
ALTER TABLE [core].[AppUser] WITH NOCHECK
    ADD CONSTRAINT [CK_AppUser_Salary] CHECK ([BaseSalaryH]>=(0));


GO
PRINT N'Creating Check Constraint [core].[CK_CatalogItem_ServiceStock]...';


GO
ALTER TABLE [core].[CatalogItem] WITH NOCHECK
    ADD CONSTRAINT [CK_CatalogItem_ServiceStock] CHECK ([Kind]=N'product' OR [TracksStock]=(0));


GO
PRINT N'Creating Check Constraint [core].[CK_CatalogItem_Kind]...';


GO
ALTER TABLE [core].[CatalogItem] WITH NOCHECK
    ADD CONSTRAINT [CK_CatalogItem_Kind] CHECK ([Kind]=N'service' OR [Kind]=N'product');


GO
PRINT N'Creating Check Constraint [core].[CK_CatalogItem_Cost]...';


GO
ALTER TABLE [core].[CatalogItem] WITH NOCHECK
    ADD CONSTRAINT [CK_CatalogItem_Cost] CHECK ([CostH]>=(0));


GO
PRINT N'Creating Check Constraint [core].[CK_CatalogItem_Price]...';


GO
ALTER TABLE [core].[CatalogItem] WITH NOCHECK
    ADD CONSTRAINT [CK_CatalogItem_Price] CHECK ([PriceH]>=(0));


GO
PRINT N'Creating Check Constraint [core].[CK_BillTemplate_HeaderAlignment]...';


GO
ALTER TABLE [core].[BillTemplate] WITH NOCHECK
    ADD CONSTRAINT [CK_BillTemplate_HeaderAlignment] CHECK ([HeaderAlignment]=N'end' OR [HeaderAlignment]=N'center' OR [HeaderAlignment]=N'start');


GO
PRINT N'Creating Check Constraint [core].[CK_BillTemplate_LogoSize]...';


GO
ALTER TABLE [core].[BillTemplate] WITH NOCHECK
    ADD CONSTRAINT [CK_BillTemplate_LogoSize] CHECK ([LogoSize]=N'lg' OR [LogoSize]=N'md' OR [LogoSize]=N'sm');


GO
PRINT N'Creating Check Constraint [core].[CK_BillTemplate_Audience]...';


GO
ALTER TABLE [core].[BillTemplate] WITH NOCHECK
    ADD CONSTRAINT [CK_BillTemplate_Audience] CHECK ([Audience]=N'group' OR [Audience]=N'customer');


GO
PRINT N'Creating Check Constraint [core].[CK_BillTemplate_GroupSet]...';


GO
ALTER TABLE [core].[BillTemplate] WITH NOCHECK
    ADD CONSTRAINT [CK_BillTemplate_GroupSet] CHECK ([Audience]<>N'group' OR [PrintGroupId] IS NOT NULL);


GO
PRINT N'Creating Check Constraint [core].[CK_BillTemplate_Lang]...';


GO
ALTER TABLE [core].[BillTemplate] WITH NOCHECK
    ADD CONSTRAINT [CK_BillTemplate_Lang] CHECK ([BillLanguage]=N'both' OR [BillLanguage]=N'en' OR [BillLanguage]=N'ar');


GO
PRINT N'Creating Check Constraint [core].[CK_BillTemplate_Paper]...';


GO
ALTER TABLE [core].[BillTemplate] WITH NOCHECK
    ADD CONSTRAINT [CK_BillTemplate_Paper] CHECK ([PaperSize]=N'a4' OR [PaperSize]=N'80mm' OR [PaperSize]=N'58mm');


GO
PRINT N'Creating Check Constraint [core].[CK_Otp_Attempts]...';


GO
ALTER TABLE [core].[OtpChallenge] WITH NOCHECK
    ADD CONSTRAINT [CK_Otp_Attempts] CHECK ([Attempts]>=(0));


GO
PRINT N'Creating Check Constraint [core].[CK_Otp_Purpose]...';


GO
ALTER TABLE [core].[OtpChallenge] WITH NOCHECK
    ADD CONSTRAINT [CK_Otp_Purpose] CHECK ([Purpose]=N'verify' OR [Purpose]=N'reset' OR [Purpose]=N'register' OR [Purpose]=N'login');


GO
PRINT N'Creating Check Constraint [core].[CK_Permission_Sensitivity]...';


GO
ALTER TABLE [core].[Permission] WITH NOCHECK
    ADD CONSTRAINT [CK_Permission_Sensitivity] CHECK ([Sensitivity]=N'personal' OR [Sensitivity]=N'financial' OR [Sensitivity]=N'general');


GO
PRINT N'Creating Check Constraint [device].[CK_Device_Printer]...';


GO
ALTER TABLE [device].[PosDevice] WITH NOCHECK
    ADD CONSTRAINT [CK_Device_Printer] CHECK ([PrinterStatus]=N'unknown' OR [PrinterStatus]=N'unavailable' OR [PrinterStatus]=N'error' OR [PrinterStatus]=N'ready');


GO
PRINT N'Creating Check Constraint [device].[CK_Device_Battery]...';


GO
ALTER TABLE [device].[PosDevice] WITH NOCHECK
    ADD CONSTRAINT [CK_Device_Battery] CHECK ([BatteryPercent] IS NULL OR [BatteryPercent]>=(0) AND [BatteryPercent]<=(100));


GO
PRINT N'Creating Check Constraint [device].[CK_Device_Paper]...';


GO
ALTER TABLE [device].[PosDevice] WITH NOCHECK
    ADD CONSTRAINT [CK_Device_Paper] CHECK ([PaperWidth]=(80) OR [PaperWidth]=(58));


GO
PRINT N'Creating Check Constraint [device].[CK_Device_PaperStatus]...';


GO
ALTER TABLE [device].[PosDevice] WITH NOCHECK
    ADD CONSTRAINT [CK_Device_PaperStatus] CHECK ([PaperStatus]=N'unknown' OR [PaperStatus]=N'empty' OR [PaperStatus]=N'low' OR [PaperStatus]=N'available');


GO
PRINT N'Creating Check Constraint [device].[CK_Event_Severity]...';


GO
ALTER TABLE [device].[DeviceEvent] WITH NOCHECK
    ADD CONSTRAINT [CK_Event_Severity] CHECK ([Severity]=N'error' OR [Severity]=N'warning' OR [Severity]=N'info');


GO
PRINT N'Creating Check Constraint [device].[CK_Cmd_Status]...';


GO
ALTER TABLE [device].[DeviceCommand] WITH NOCHECK
    ADD CONSTRAINT [CK_Cmd_Status] CHECK ([Status]=N'expired' OR [Status]=N'failed' OR [Status]=N'succeeded' OR [Status]=N'sent' OR [Status]=N'pending');


GO
PRINT N'Creating Check Constraint [device].[CK_Cmd_Type]...';


GO
ALTER TABLE [device].[DeviceCommand] WITH NOCHECK
    ADD CONSTRAINT [CK_Cmd_Type] CHECK ([CommandType]=N'get_info' OR [CommandType]=N'print_test_receipt' OR [CommandType]=N'refresh_status' OR [CommandType]=N'test_printer' OR [CommandType]=N'ping');


GO
PRINT N'Creating Check Constraint [fin].[CK_Account_Type]...';


GO
ALTER TABLE [fin].[Account] WITH NOCHECK
    ADD CONSTRAINT [CK_Account_Type] CHECK ([AccountType]=N'expense' OR [AccountType]=N'revenue' OR [AccountType]=N'equity' OR [AccountType]=N'liability' OR [AccountType]=N'asset');


GO
PRINT N'Creating Check Constraint [fin].[CK_JournalLine_NonNegative]...';


GO
ALTER TABLE [fin].[JournalLine] WITH NOCHECK
    ADD CONSTRAINT [CK_JournalLine_NonNegative] CHECK ([DebitH]>=(0) AND [CreditH]>=(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_JournalLine_OneSided]...';


GO
ALTER TABLE [fin].[JournalLine] WITH NOCHECK
    ADD CONSTRAINT [CK_JournalLine_OneSided] CHECK ([DebitH]>(0) AND [CreditH]=(0) OR [CreditH]>(0) AND [DebitH]=(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_CommissionRule_Basis]...';


GO
ALTER TABLE [fin].[CommissionRule] WITH NOCHECK
    ADD CONSTRAINT [CK_CommissionRule_Basis] CHECK ([Basis]=N'fixed' OR [Basis]=N'percentage');


GO
PRINT N'Creating Check Constraint [fin].[CK_CommissionRule_Pct]...';


GO
ALTER TABLE [fin].[CommissionRule] WITH NOCHECK
    ADD CONSTRAINT [CK_CommissionRule_Pct] CHECK ([Basis]<>N'percentage' OR [Value]<=(10000));


GO
PRINT N'Creating Check Constraint [fin].[CK_CommissionRule_Value]...';


GO
ALTER TABLE [fin].[CommissionRule] WITH NOCHECK
    ADD CONSTRAINT [CK_CommissionRule_Value] CHECK ([Value]>(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_JournalEntry_Kind]...';


GO
ALTER TABLE [fin].[JournalEntry] WITH NOCHECK
    ADD CONSTRAINT [CK_JournalEntry_Kind] CHECK ([Kind]=N'manual' OR [Kind]=N'opening_balance' OR [Kind]=N'commission' OR [Kind]=N'payroll' OR [Kind]=N'owner_withdrawal' OR [Kind]=N'owner_contribution' OR [Kind]=N'stock_adjustment' OR [Kind]=N'card_settlement' OR [Kind]=N'purchase' OR [Kind]=N'supplier_payment' OR [Kind]=N'customer_collection' OR [Kind]=N'expense_recognition' OR [Kind]=N'expense' OR [Kind]=N'void' OR [Kind]=N'return' OR [Kind]=N'sale');


GO
PRINT N'Creating Check Constraint [fin].[CK_JournalEntry_Positive]...';


GO
ALTER TABLE [fin].[JournalEntry] WITH NOCHECK
    ADD CONSTRAINT [CK_JournalEntry_Positive] CHECK ([TotalDebitH]>(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_JournalEntry_Balanced]...';


GO
ALTER TABLE [fin].[JournalEntry] WITH NOCHECK
    ADD CONSTRAINT [CK_JournalEntry_Balanced] CHECK ([TotalDebitH]=[TotalCreditH]);


GO
PRINT N'Creating Check Constraint [fin].[CK_CommissionEntry_Amount]...';


GO
ALTER TABLE [fin].[CommissionEntry] WITH NOCHECK
    ADD CONSTRAINT [CK_CommissionEntry_Amount] CHECK ([AmountH]>=(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_Recurring_Frequency]...';


GO
ALTER TABLE [fin].[RecurringPayment] WITH NOCHECK
    ADD CONSTRAINT [CK_Recurring_Frequency] CHECK ([Frequency]=N'yearly' OR [Frequency]=N'quarterly' OR [Frequency]=N'monthly' OR [Frequency]=N'weekly' OR [Frequency]=N'daily');


GO
PRINT N'Creating Check Constraint [fin].[CK_Recurring_Status]...';


GO
ALTER TABLE [fin].[RecurringPayment] WITH NOCHECK
    ADD CONSTRAINT [CK_Recurring_Status] CHECK ([Status]=N'paused' OR [Status]=N'active');


GO
PRINT N'Creating Check Constraint [fin].[CK_Recurring_Amount]...';


GO
ALTER TABLE [fin].[RecurringPayment] WITH NOCHECK
    ADD CONSTRAINT [CK_Recurring_Amount] CHECK ([AmountH]>(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_OpeningBalance_NonNegative]...';


GO
ALTER TABLE [fin].[OpeningBalance] WITH NOCHECK
    ADD CONSTRAINT [CK_OpeningBalance_NonNegative] CHECK ([CashH]>=(0) AND [BankH]>=(0) AND [InventoryH]>=(0) AND [ReceivablesH]>=(0) AND [PayablesH]>=(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_PayrollLine_NonNegative]...';


GO
ALTER TABLE [fin].[PayrollLine] WITH NOCHECK
    ADD CONSTRAINT [CK_PayrollLine_NonNegative] CHECK ([BaseSalaryH]>=(0) AND [CommissionH]>=(0) AND [AllowancesH]>=(0) AND [DeductionsH]>=(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_ExpenseRecognition_Amount]...';


GO
ALTER TABLE [fin].[ExpenseRecognition] WITH NOCHECK
    ADD CONSTRAINT [CK_ExpenseRecognition_Amount] CHECK ([AmountH]>=(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_BalancePeriod_Dates]...';


GO
ALTER TABLE [fin].[BalancePeriod] WITH NOCHECK
    ADD CONSTRAINT [CK_BalancePeriod_Dates] CHECK ([ClosedOn] IS NULL OR [ClosedOn]>=[OpenedOn]);


GO
PRINT N'Creating Check Constraint [fin].[CK_BalancePeriod_Status]...';


GO
ALTER TABLE [fin].[BalancePeriod] WITH NOCHECK
    ADD CONSTRAINT [CK_BalancePeriod_Status] CHECK ([Status]=N'closed' OR [Status]=N'open');


GO
PRINT N'Creating Check Constraint [fin].[CK_Expense_Amount]...';


GO
ALTER TABLE [fin].[Expense] WITH NOCHECK
    ADD CONSTRAINT [CK_Expense_Amount] CHECK ([AmountH]>(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_Expense_Recognition]...';


GO
ALTER TABLE [fin].[Expense] WITH NOCHECK
    ADD CONSTRAINT [CK_Expense_Recognition] CHECK ([Recognition]=N'custom' OR [Recognition]=N'yearly' OR [Recognition]=N'monthly' OR [Recognition]=N'one_time');


GO
PRINT N'Creating Check Constraint [fin].[CK_Expense_Status]...';


GO
ALTER TABLE [fin].[Expense] WITH NOCHECK
    ADD CONSTRAINT [CK_Expense_Status] CHECK ([Status]=N'reversed' OR [Status]=N'posted');


GO
PRINT N'Creating Check Constraint [fin].[CK_Expense_Period]...';


GO
ALTER TABLE [fin].[Expense] WITH NOCHECK
    ADD CONSTRAINT [CK_Expense_Period] CHECK ([PeriodEnd]>=[PeriodStart]);


GO
PRINT N'Creating Check Constraint [fin].[CK_Expense_Method]...';


GO
ALTER TABLE [fin].[Expense] WITH NOCHECK
    ADD CONSTRAINT [CK_Expense_Method] CHECK ([PaymentMethod]=N'credit' OR [PaymentMethod]=N'bank' OR [PaymentMethod]=N'card' OR [PaymentMethod]=N'cash');


GO
PRINT N'Creating Check Constraint [fin].[CK_Expense_Vat]...';


GO
ALTER TABLE [fin].[Expense] WITH NOCHECK
    ADD CONSTRAINT [CK_Expense_Vat] CHECK ([VatH]>=(0) AND [VatH]<=[AmountH]);


GO
PRINT N'Creating Check Constraint [fin].[CK_DrawerSession_Counted]...';


GO
ALTER TABLE [fin].[DrawerSession] WITH NOCHECK
    ADD CONSTRAINT [CK_DrawerSession_Counted] CHECK ([CountedCashH] IS NULL OR [CountedCashH]>=(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_DrawerSession_Opening]...';


GO
ALTER TABLE [fin].[DrawerSession] WITH NOCHECK
    ADD CONSTRAINT [CK_DrawerSession_Opening] CHECK ([OpeningCashH]>=(0));


GO
PRINT N'Creating Check Constraint [fin].[CK_CardSettlement_Amount]...';


GO
ALTER TABLE [fin].[CardSettlement] WITH NOCHECK
    ADD CONSTRAINT [CK_CardSettlement_Amount] CHECK ([CardSalesH]>(0) AND [DepositH]>=(0) AND [DepositH]<=[CardSalesH]);


GO
PRINT N'Creating Check Constraint [fin].[CK_CardSettlement_Fee]...';


GO
ALTER TABLE [fin].[CardSettlement] WITH NOCHECK
    ADD CONSTRAINT [CK_CardSettlement_Fee] CHECK ([FeeH]=([CardSalesH]-[DepositH]));


GO
PRINT N'Creating Check Constraint [fin].[CK_PayrollRun_Status]...';


GO
ALTER TABLE [fin].[PayrollRun] WITH NOCHECK
    ADD CONSTRAINT [CK_PayrollRun_Status] CHECK ([Status]=N'paid' OR [Status]=N'approved' OR [Status]=N'draft');


GO
PRINT N'Creating Check Constraint [inv].[CK_PurchaseLine_Qty]...';


GO
ALTER TABLE [inv].[PurchaseLine] WITH NOCHECK
    ADD CONSTRAINT [CK_PurchaseLine_Qty] CHECK ([Quantity]>(0));


GO
PRINT N'Creating Check Constraint [inv].[CK_PurchaseLine_Cost]...';


GO
ALTER TABLE [inv].[PurchaseLine] WITH NOCHECK
    ADD CONSTRAINT [CK_PurchaseLine_Cost] CHECK ([UnitCostH]>=(0));


GO
PRINT N'Creating Check Constraint [inv].[CK_StockMovement_Qty]...';


GO
ALTER TABLE [inv].[StockMovement] WITH NOCHECK
    ADD CONSTRAINT [CK_StockMovement_Qty] CHECK ([Quantity]<>(0));


GO
PRINT N'Creating Check Constraint [inv].[CK_StockMovement_Type]...';


GO
ALTER TABLE [inv].[StockMovement] WITH NOCHECK
    ADD CONSTRAINT [CK_StockMovement_Type] CHECK ([MovementType]=N'transfer' OR [MovementType]=N'opening' OR [MovementType]=N'stocktake' OR [MovementType]=N'adjustment' OR [MovementType]=N'return' OR [MovementType]=N'sale' OR [MovementType]=N'purchase');


GO
PRINT N'Creating Check Constraint [inv].[CK_VendorPayment_Method]...';


GO
ALTER TABLE [inv].[VendorPayment] WITH NOCHECK
    ADD CONSTRAINT [CK_VendorPayment_Method] CHECK ([Method]=N'bank' OR [Method]=N'card' OR [Method]=N'cash');


GO
PRINT N'Creating Check Constraint [inv].[CK_VendorPayment_Amount]...';


GO
ALTER TABLE [inv].[VendorPayment] WITH NOCHECK
    ADD CONSTRAINT [CK_VendorPayment_Amount] CHECK ([AmountH]>(0));


GO
PRINT N'Creating Check Constraint [inv].[CK_Purchase_Totals]...';


GO
ALTER TABLE [inv].[Purchase] WITH NOCHECK
    ADD CONSTRAINT [CK_Purchase_Totals] CHECK ([TotalH]=([SubtotalH]+[TaxH]));


GO
PRINT N'Creating Check Constraint [inv].[CK_Purchase_PaidH]...';


GO
ALTER TABLE [inv].[Purchase] WITH NOCHECK
    ADD CONSTRAINT [CK_Purchase_PaidH] CHECK ([PaidH]>=(0) AND [PaidH]<=[TotalH]);


GO
PRINT N'Creating Check Constraint [inv].[CK_VPA_Amount]...';


GO
ALTER TABLE [inv].[VendorPaymentAllocation] WITH NOCHECK
    ADD CONSTRAINT [CK_VPA_Amount] CHECK ([AmountH]>(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_SaleLine_Money]...';


GO
ALTER TABLE [sales].[SaleLine] WITH NOCHECK
    ADD CONSTRAINT [CK_SaleLine_Money] CHECK ([UnitPriceH]>=(0) AND [UnitCostH]>=(0) AND [LineDiscountH]>=(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_SaleLine_Qty]...';


GO
ALTER TABLE [sales].[SaleLine] WITH NOCHECK
    ADD CONSTRAINT [CK_SaleLine_Qty] CHECK ([Quantity]>(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_SaleLine_Returned]...';


GO
ALTER TABLE [sales].[SaleLine] WITH NOCHECK
    ADD CONSTRAINT [CK_SaleLine_Returned] CHECK ([ReturnedQty]>=(0) AND [ReturnedQty]<=[Quantity]);


GO
PRINT N'Creating Check Constraint [sales].[CK_Sale_NonNegative]...';


GO
ALTER TABLE [sales].[Sale] WITH NOCHECK
    ADD CONSTRAINT [CK_Sale_NonNegative] CHECK ([SubtotalH]>=(0) AND [DiscountH]>=(0) AND [TaxH]>=(0) AND [TotalH]>=(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_Sale_OrderType]...';


GO
ALTER TABLE [sales].[Sale] WITH NOCHECK
    ADD CONSTRAINT [CK_Sale_OrderType] CHECK ([OrderType] IS NULL OR ([OrderType]=N'other' OR [OrderType]=N'delivery' OR [OrderType]=N'takeaway' OR [OrderType]=N'dine_in'));


GO
PRINT N'Creating Check Constraint [sales].[CK_Sale_Status]...';


GO
ALTER TABLE [sales].[Sale] WITH NOCHECK
    ADD CONSTRAINT [CK_Sale_Status] CHECK ([Status]=N'voided' OR [Status]=N'returned' OR [Status]=N'partially_returned' OR [Status]=N'completed');


GO
PRINT N'Creating Check Constraint [sales].[CK_Sale_Totals]...';


GO
ALTER TABLE [sales].[Sale] WITH NOCHECK
    ADD CONSTRAINT [CK_Sale_Totals] CHECK ([TotalH]=(([SubtotalH]-[DiscountH])+[TaxH]));


GO
PRINT N'Creating Check Constraint [sales].[CK_DiscountScope_Type]...';


GO
ALTER TABLE [sales].[DiscountScope] WITH NOCHECK
    ADD CONSTRAINT [CK_DiscountScope_Type] CHECK ([ScopeType]=N'role' OR [ScopeType]=N'branch' OR [ScopeType]=N'category' OR [ScopeType]=N'item');


GO
PRINT N'Creating Check Constraint [sales].[CK_Discount_Percent]...';


GO
ALTER TABLE [sales].[Discount] WITH NOCHECK
    ADD CONSTRAINT [CK_Discount_Percent] CHECK ([DiscountType]<>N'percentage' OR [Value]<=(10000));


GO
PRINT N'Creating Check Constraint [sales].[CK_Discount_Type]...';


GO
ALTER TABLE [sales].[Discount] WITH NOCHECK
    ADD CONSTRAINT [CK_Discount_Type] CHECK ([DiscountType]=N'fixed' OR [DiscountType]=N'percentage');


GO
PRINT N'Creating Check Constraint [sales].[CK_Discount_Value]...';


GO
ALTER TABLE [sales].[Discount] WITH NOCHECK
    ADD CONSTRAINT [CK_Discount_Value] CHECK ([Value]>(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_Discount_Applies]...';


GO
ALTER TABLE [sales].[Discount] WITH NOCHECK
    ADD CONSTRAINT [CK_Discount_Applies] CHECK ([AppliesTo]=N'category' OR [AppliesTo]=N'item' OR [AppliesTo]=N'selected' OR [AppliesTo]=N'services' OR [AppliesTo]=N'products' OR [AppliesTo]=N'all');


GO
PRINT N'Creating Check Constraint [sales].[CK_Discount_Dates]...';


GO
ALTER TABLE [sales].[Discount] WITH NOCHECK
    ADD CONSTRAINT [CK_Discount_Dates] CHECK ([EndsOn] IS NULL OR [StartsOn] IS NULL OR [EndsOn]>=[StartsOn]);


GO
PRINT N'Creating Check Constraint [sales].[CK_SaleReturn_Method]...';


GO
ALTER TABLE [sales].[SaleReturn] WITH NOCHECK
    ADD CONSTRAINT [CK_SaleReturn_Method] CHECK ([RefundMethod] IS NULL OR ([RefundMethod]=N'bank' OR [RefundMethod]=N'credit' OR [RefundMethod]=N'card' OR [RefundMethod]=N'cash'));


GO
PRINT N'Creating Check Constraint [sales].[CK_SaleReturn_Reason]...';


GO
ALTER TABLE [sales].[SaleReturn] WITH NOCHECK
    ADD CONSTRAINT [CK_SaleReturn_Reason] CHECK ([ReasonCode] IS NULL OR ([ReasonCode]=N'other' OR [ReasonCode]=N'wrong_item' OR [ReasonCode]=N'changed_mind' OR [ReasonCode]=N'not_as_described' OR [ReasonCode]=N'damaged'));


GO
PRINT N'Creating Check Constraint [sales].[CK_SaleReturn_Refund]...';


GO
ALTER TABLE [sales].[SaleReturn] WITH NOCHECK
    ADD CONSTRAINT [CK_SaleReturn_Refund] CHECK ([RefundH]>=(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_PreparationItem_Done]...';


GO
ALTER TABLE [sales].[PreparationItem] WITH NOCHECK
    ADD CONSTRAINT [CK_PreparationItem_Done] CHECK ([CompletedQty]>=(0) AND [CompletedQty]<=[Quantity]);


GO
PRINT N'Creating Check Constraint [sales].[CK_PreparationItem_Qty]...';


GO
ALTER TABLE [sales].[PreparationItem] WITH NOCHECK
    ADD CONSTRAINT [CK_PreparationItem_Qty] CHECK ([Quantity]>(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_SalePayment_Method]...';


GO
ALTER TABLE [sales].[SalePayment] WITH NOCHECK
    ADD CONSTRAINT [CK_SalePayment_Method] CHECK ([Method]=N'bank' OR [Method]=N'credit' OR [Method]=N'card' OR [Method]=N'cash');


GO
PRINT N'Creating Check Constraint [sales].[CK_SalePayment_Amount]...';


GO
ALTER TABLE [sales].[SalePayment] WITH NOCHECK
    ADD CONSTRAINT [CK_SalePayment_Amount] CHECK ([AmountH]>(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_SaleReturnLine_Qty]...';


GO
ALTER TABLE [sales].[SaleReturnLine] WITH NOCHECK
    ADD CONSTRAINT [CK_SaleReturnLine_Qty] CHECK ([Quantity]>(0));


GO
PRINT N'Creating Check Constraint [sales].[CK_Preparation_OrderType]...';


GO
ALTER TABLE [sales].[PreparationOrder] WITH NOCHECK
    ADD CONSTRAINT [CK_Preparation_OrderType] CHECK ([OrderType] IS NULL OR ([OrderType]=N'other' OR [OrderType]=N'delivery' OR [OrderType]=N'takeaway' OR [OrderType]=N'dine_in'));


GO
PRINT N'Creating Check Constraint [sales].[CK_Preparation_Status]...';


GO
ALTER TABLE [sales].[PreparationOrder] WITH NOCHECK
    ADD CONSTRAINT [CK_Preparation_Status] CHECK ([Status]=N'completed' OR [Status]=N'ready' OR [Status]=N'preparing' OR [Status]=N'open');


GO
PRINT N'Creating View [audit].[vw_SuspectedNPlusOne]...';


GO

/*
  Requests that ran the same statement several times.

  This is the N+1 signature: one request, one statement shape, many executions.
*/
CREATE VIEW audit.vw_SuspectedNPlusOne
AS
SELECT
    q.CorrelationId,
    r.ApiPath,
    r.HttpMethod,
    LEFT(q.CommandText, 120) AS Statement,
    COUNT(*)                 AS Executions,
    SUM(q.DurationMs)        AS TotalMs,
    r.OccurredAtUtc
FROM audit.QueryTiming AS q
JOIN audit.RequestTiming AS r ON r.CorrelationId = q.CorrelationId
GROUP BY q.CorrelationId, r.ApiPath, r.HttpMethod,
         LEFT(q.CommandText, 120), r.OccurredAtUtc
HAVING COUNT(*) >= 5;
GO
PRINT N'Creating View [audit].[vw_EndpointPerformance]...';


GO

/*------------------------------------------------------------------- views */

/*
  Performance per endpoint.

  The average is reported alongside p95 because an average hides the tail: an
  endpoint answering in 40ms for nineteen callers and 4 seconds for the
  twentieth averages 238ms and looks healthy, while the twentieth person is the
  one who complains.
*/
CREATE VIEW audit.vw_EndpointPerformance
AS
SELECT
    ApiPath,
    HttpMethod,
    COUNT(*)                                   AS Calls,
    AVG(TotalMs)                               AS AvgMs,
    MIN(TotalMs)                               AS MinMs,
    MAX(TotalMs)                               AS MaxMs,
    AVG(DatabaseMs)                            AS AvgDatabaseMs,
    SUM(CASE WHEN Succeeded = 0 THEN 1 ELSE 0 END) AS Failures,
    CAST(ROUND(
        100.0 * SUM(CASE WHEN Succeeded = 0 THEN 1 ELSE 0 END) / COUNT(*), 1)
        AS DECIMAL(5,1))                       AS FailurePercent,
    /* The QA bands from the test plan. */
    CASE
        WHEN AVG(TotalMs) < 100  THEN N'Excellent'
        WHEN AVG(TotalMs) < 300  THEN N'Good'
        WHEN AVG(TotalMs) < 1000 THEN N'Acceptable'
        WHEN AVG(TotalMs) < 2000 THEN N'Slow'
        ELSE N'Critical'
    END                                        AS Rating
FROM audit.RequestTiming
GROUP BY ApiPath, HttpMethod;
GO
PRINT N'Creating View [core].[vw_EffectivePermission]...';


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
PRINT N'Creating View [device].[vw_DeviceStatus]...';


GO

/*--------------------------------------------------------------------- view */

/*
  Devices with their connection state worked out.

  Ninety seconds is three missed heartbeats at the ten-second interval — long
  enough that one dropped packet does not turn the light red, short enough that
  a genuinely dead till is noticed.
*/
CREATE VIEW device.vw_DeviceStatus
AS
SELECT
    d.DeviceId, d.DeviceName, d.DeviceType, d.DeviceModel, d.SerialNumber,
    d.BranchId, b.NameAr AS BranchNameAr, b.NameEn AS BranchNameEn,
    d.Location, d.Description, d.PaperWidth, d.PrinterKind,

    CASE WHEN d.RegisteredAtUtc IS NULL THEN N'unregistered'
         WHEN d.LastHeartbeatAtUtc IS NULL THEN N'unknown'
         WHEN DATEDIFF(SECOND, d.LastHeartbeatAtUtc, SYSUTCDATETIME()) <= 90 THEN N'online'
         ELSE N'offline'
    END AS ConnectionStatus,

    d.LastHeartbeatAtUtc,
    DATEDIFF(SECOND, d.LastHeartbeatAtUtc, SYSUTCDATETIME()) AS SecondsSinceHeartbeat,

    /*
      A stale device reports nothing, so its printer state is unknown — not
      whatever it last said. A green printer light under an offline device is
      the light that lies.
    */
    CASE WHEN d.LastHeartbeatAtUtc IS NULL
              OR DATEDIFF(SECOND, d.LastHeartbeatAtUtc, SYSUTCDATETIME()) > 90
         THEN N'unknown' ELSE d.PrinterStatus END AS PrinterStatus,

    CASE WHEN d.LastHeartbeatAtUtc IS NULL
              OR DATEDIFF(SECOND, d.LastHeartbeatAtUtc, SYSUTCDATETIME()) > 90
         THEN N'unknown' ELSE d.PaperStatus END AS PaperStatus,

    d.PrinterError, d.BatteryPercent, d.NetworkType, d.AppVersion,
    d.RegisteredAtUtc, d.RegistrationCode, d.CodeExpiresAtUtc,
    CAST(CASE WHEN d.RegisteredAtUtc IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsRegistered,
    d.IsActive, d.CreatedAtUtc,

    (SELECT COUNT(*) FROM device.DeviceCommand AS c
     WHERE c.DeviceId = d.DeviceId AND c.Status = N'pending') AS PendingCommands
FROM device.PosDevice AS d
JOIN core.Branch AS b ON b.BranchId = d.BranchId;
GO
PRINT N'Creating View [fin].[vw_CommissionSummary]...';


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
PRINT N'Creating View [fin].[vw_TrialBalanceCheck]...';


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
PRINT N'Creating View [fin].[vw_Receivables]...';


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
PRINT N'Creating View [sales].[vw_SaleSummary]...';


GO

/* ALTER rather than DROP: dropping would break anything referencing it, and the
   column list is the only thing changing. */
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
    s.CashierName,

    s.SubtotalH,
    s.DiscountH,
    s.TaxH,
    s.TotalH,

    /* The receipt's two missing figures.
       TenderedH is null for a sale with no cash leg, and null reaches the client
       as null rather than as a missing key — which it can test for. Change is
       never null: nothing tendered means nothing given back. */
    s.TenderedH,
    ISNULL(s.ChangeH, 0) AS ChangeH,

    s.DiscountId,
    s.Status,
    s.SoldAtUtc,
    /* The client's field is `soldAt`. Carrying both costs nothing and saves a
       rename on either side. */
    s.SoldAtUtc     AS SoldAt,

    (SELECT COUNT(*) FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId) AS LineCount
FROM sales.Sale AS s
LEFT JOIN core.Branch   AS b ON b.BranchId   = s.BranchId
LEFT JOIN core.Customer AS c ON c.CustomerId = s.CustomerId
LEFT JOIN core.AppUser  AS u ON u.UserId     = s.ServedByUserId;
GO
PRINT N'Creating Function [core].[fn_Text]...';


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
PRINT N'Creating Function [fin].[fn_AdvanceDueDate]...';


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
PRINT N'Creating Function [fin].[fn_VatFromGross]...';


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
PRINT N'Creating Function [fin].[fn_IsDebitNormal]...';


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
PRINT N'Creating View [fin].[vw_AccountBalance]...';


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
PRINT N'Creating Procedure [audit].[usp_PurgeTelemetry]...';


GO

/* Telemetry is not evidence; it ages out. The audit trail does not. */
CREATE PROCEDURE audit.usp_PurgeTelemetry
    @KeepDays INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM audit.QueryTiming
    WHERE OccurredAtUtc < DATEADD(DAY, -@KeepDays, SYSUTCDATETIME());

    DELETE FROM audit.RequestTiming
    WHERE OccurredAtUtc < DATEADD(DAY, -@KeepDays, SYSUTCDATETIME());
END
GO
PRINT N'Creating Procedure [core].[usp_SaveBillTemplate]...';


GO

/*--------------------------------------------------------- save bill template */

CREATE   PROCEDURE core.usp_SaveBillTemplate
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
PRINT N'Creating Procedure [core].[usp_SetUserOverrides]...';


GO


/*====================================================== permission overrides */

/*
  Grants and denials on top of a role.

  Also replaced wholesale, for the same reason. The effective permission view
  already resolves the precedence — denial beats grant — so this only records
  what was chosen.
*/
CREATE   PROCEDURE core.usp_SetUserOverrides
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
PRINT N'Creating Procedure [core].[usp_SaveCategory]...';


GO

/*-------------------------------------------------------------- save category */

CREATE   PROCEDURE core.usp_SaveCategory
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
PRINT N'Creating Procedure [core].[usp_SaveRole]...';


GO

/*------------------------------------------------------------------ save role */

/*
  Create or edit a role, replacing its permission set wholesale.

  The owner role is not editable: it holds every permission by definition, and
  an owner who could trim it could lock everyone out of user administration.
  Built-in roles keep their names — other screens and the seed data refer to
  them — but their permissions are the owner's to tune.
*/
CREATE   PROCEDURE core.usp_SaveRole
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
PRINT N'Creating Procedure [core].[usp_SetUserStatus]...';


GO

/*------------------------------------------------------------- status changes */

/*
  Suspend, reactivate, or end an external account's access now.

  Sign-in already refuses a suspended account; revoking the refresh tokens as
  well means an open session cannot renew itself either, so the change takes
  effect within one access-token lifetime rather than whenever they log out.
*/
CREATE   PROCEDURE core.usp_SetUserStatus
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
PRINT N'Creating Procedure [core].[usp_SaveBranchSettings]...';


GO

CREATE   PROCEDURE core.usp_SaveBranchSettings
    @BranchId            NVARCHAR(40),
    @DefaultCustomerMode NVARCHAR(20),
    @ServedByRequirement NVARCHAR(20),
    @AllowNegativeStock  BIT,
    @DefaultBillId       NVARCHAR(40) = NULL,
    @AutoPrintCustomer   BIT,
    @AutoPrintGroups     BIT,
    @VatRatePercent      DECIMAL(5,2),
    @PricesIncludeVat    BIT,
    @Actor               NVARCHAR(160)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId)
        THROW 62050, N'No such branch.', 1;

    IF @DefaultCustomerMode NOT IN (N'walkin', N'customer')
        THROW 62051, N'The default customer mode is walkin or customer.', 1;

    IF @ServedByRequirement NOT IN (N'off', N'optional', N'required')
        THROW 62052, N'Served-by is off, optional or required.', 1;

    IF @VatRatePercent IS NULL OR @VatRatePercent < 0 OR @VatRatePercent > 100
        THROW 62053, N'Enter a VAT rate between 0 and 100.', 1;

    /* The branch default is what prints on a customer's receipt. A kitchen
       ticket there would hand the customer a bill with no total. */
    IF @DefaultBillId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM core.BillTemplate
        WHERE BillId = @DefaultBillId AND Audience = N'customer' AND IsActive = 1)
        THROW 62054, N'The default bill must be an active customer template.', 1;

    UPDATE core.BranchSettings
    SET DefaultCustomerMode = @DefaultCustomerMode,
        ServedByRequirement = @ServedByRequirement,
        AllowNegativeStock  = @AllowNegativeStock,
        DefaultBillId       = @DefaultBillId,
        AutoPrintCustomer   = @AutoPrintCustomer,
        AutoPrintGroups     = @AutoPrintGroups,
        VatRatePercent      = @VatRatePercent,
        PricesIncludeVat    = @PricesIncludeVat,
        UpdatedAtUtc        = SYSUTCDATETIME(),
        UpdatedBy           = @Actor
    WHERE BranchId = @BranchId;

    IF @@ROWCOUNT = 0
        INSERT INTO core.BranchSettings
            (BranchId, DefaultCustomerMode, ServedByRequirement, AllowNegativeStock,
             DefaultBillId, AutoPrintCustomer, AutoPrintGroups, VatRatePercent,
             PricesIncludeVat, UpdatedBy)
        VALUES
            (@BranchId, @DefaultCustomerMode, @ServedByRequirement, @AllowNegativeStock,
             @DefaultBillId, @AutoPrintCustomer, @AutoPrintGroups, @VatRatePercent,
             @PricesIncludeVat, @Actor);
END
GO
PRINT N'Creating Procedure [core].[usp_SetActive]...';


GO

CREATE   PROCEDURE core.usp_SetActive
    @EntityType  NVARCHAR(40),
    @EntityId    NVARCHAR(40),
    @IsActive    BIT,
    @Actor       NVARCHAR(160),
    @Blocked     NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Blocked = NULL;

    /*-------------------------------------------------- what may be deactivated */

    IF @EntityType NOT IN (N'item', N'category', N'printGroup', N'vendor',
                           N'customer', N'discount', N'expenseCategory',
                           N'commissionRule', N'billTemplate', N'branch')
    BEGIN
        THROW 57000, N'That kind of record cannot be activated or deactivated.', 1;
    END

    /*----------------------------------------------------- deactivation guards */

    /*
      Refusing is kinder than cascading.

      Deactivating a category that still holds live items would either orphan
      them or silently hide them from the till — and the person clicking the
      toggle would have no idea which. Naming what is in the way lets them
      decide.

      Reactivating is never blocked: a guard that applied in both directions
      would trap a record permanently.
    */
    IF @IsActive = 0
    BEGIN
        IF @EntityType = N'category'
           AND EXISTS (SELECT 1 FROM core.CatalogItem
                       WHERE CategoryId = @EntityId AND IsActive = 1)
        BEGIN
            SET @Blocked = CONCAT(
                N'This category still has ',
                (SELECT COUNT(*) FROM core.CatalogItem
                 WHERE CategoryId = @EntityId AND IsActive = 1),
                N' active items. Move or deactivate them first.');
            RETURN;
        END

        IF @EntityType = N'printGroup'
           AND EXISTS (SELECT 1 FROM core.CatalogItem
                       WHERE PrintGroupId = @EntityId AND IsActive = 1)
        BEGIN
            SET @Blocked = N'This print group is still used by active items. '
                         + N'Reassign them first, or their tickets will not print.';
            RETURN;
        END

        /* Money owed does not disappear because a record was switched off. */
        IF @EntityType = N'customer'
           AND EXISTS (SELECT 1 FROM core.Customer
                       WHERE CustomerId = @EntityId AND BalanceH > 0)
        BEGIN
            SET @Blocked = N'This customer still owes money. '
                         + N'Settle the balance before deactivating.';
            RETURN;
        END

        /*
          A vendor's debt is not a column.

          What is owed is the unsettled part of purchases not paid on receipt
          (TotalH - PaidH, kept by inv.usp_RecordVendorPayment). A purchase that
          has been paid off no longer blocks the vendor.
        */
        IF @EntityType = N'vendor'
           AND EXISTS (SELECT 1 FROM inv.Purchase
                       WHERE VendorId = @EntityId AND PaidOnReceipt = 0 AND PaidH < TotalH)
        BEGIN
            SET @Blocked = CONCAT(
                N'This vendor has ',
                (SELECT COUNT(*) FROM inv.Purchase
                 WHERE VendorId = @EntityId AND PaidOnReceipt = 0 AND PaidH < TotalH),
                N' unpaid deliveries. Settle them before deactivating.');
            RETURN;
        END

        /* A branch with an open drawer or period has work in progress. */
        IF @EntityType = N'branch'
        BEGIN
            IF EXISTS (SELECT 1 FROM fin.DrawerSession
                       WHERE BranchId = @EntityId AND ClosedAtUtc IS NULL)
            BEGIN
                SET @Blocked = N'This branch has an open cash drawer. Close it first.';
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM fin.BalancePeriod
                       WHERE BranchId = @EntityId AND Status = N'open')
            BEGIN
                SET @Blocked = N'This branch has an open balance period. Close it first.';
                RETURN;
            END

            /* The last active branch cannot go: the till would have nowhere to sell. */
            IF (SELECT COUNT(*) FROM core.Branch WHERE IsActive = 1) <= 1
            BEGIN
                SET @Blocked = N'This is the only active branch. At least one must remain.';
                RETURN;
            END
        END
    END

    /*---------------------------------------------------------------- the write */

    /*
      An explicit branch per type, setting only the columns that table has.

      A concatenated UPDATE would be shorter and would also accept whatever
      @EntityType contained — a parameter reaching sys.objects unchecked is an
      injection route. There is no dynamic SQL in this file.
    */
    IF @EntityType = N'item'
        UPDATE core.CatalogItem
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME(),
               UpdatedBy = @Actor
        WHERE  ItemId = @EntityId;
    ELSE
    IF @EntityType = N'category'
        UPDATE core.Category
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  CategoryId = @EntityId;
    ELSE
    IF @EntityType = N'printGroup'
        UPDATE core.PrintGroup
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  PrintGroupId = @EntityId;
    ELSE
    IF @EntityType = N'vendor'
        UPDATE core.Vendor
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME(),
               UpdatedBy = @Actor
        WHERE  VendorId = @EntityId;
    ELSE
    IF @EntityType = N'customer'
        UPDATE core.Customer
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME(),
               UpdatedBy = @Actor
        WHERE  CustomerId = @EntityId;
    ELSE
    IF @EntityType = N'discount'
        UPDATE sales.Discount
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  DiscountId = @EntityId;
    ELSE
    IF @EntityType = N'expenseCategory'
        UPDATE fin.ExpenseCategory
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  CategoryId = @EntityId;
    ELSE
    IF @EntityType = N'commissionRule'
        UPDATE fin.CommissionRule
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  RuleId = @EntityId;
    ELSE
    IF @EntityType = N'billTemplate'
        UPDATE core.BillTemplate
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  BillId = @EntityId;
    ELSE
    IF @EntityType = N'branch'
        UPDATE core.Branch
        SET    IsActive = @IsActive,
               UpdatedAtUtc = SYSUTCDATETIME()
        WHERE  BranchId = @EntityId;

    IF @@ROWCOUNT = 0
        THROW 57001, N'No such record.', 1;
END
GO
PRINT N'Creating Procedure [core].[usp_SavePrintGroup]...';


GO

/*----------------------------------------------------------- save print group */

CREATE   PROCEDURE core.usp_SavePrintGroup
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
PRINT N'Creating Procedure [core].[usp_SaveCompany]...';


GO

/*--------------------------------------------------------------- save company */

CREATE   PROCEDURE core.usp_SaveCompany
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
PRINT N'Creating Procedure [core].[usp_DeleteRole]...';


GO

/*---------------------------------------------------------------- delete role */

/*
  A real delete, because a role is configuration rather than history: no sale,
  payment or ledger line records which role its actor held. What can refer to a
  role is a user, and that is refused rather than cascaded.
*/
CREATE   PROCEDURE core.usp_DeleteRole
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
PRINT N'Creating Procedure [core].[usp_RegisterBusiness]...';


GO

CREATE   PROCEDURE core.usp_RegisterBusiness
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
PRINT N'Creating Procedure [core].[usp_SetUserBranches]...';


GO


/*=========================================================== branch access */

/*
  Which branches a person may work in.

  Replaced wholesale rather than added to. A grant-and-revoke pair drifts: the
  screen shows a set, and applying a diff means two round trips that can half
  succeed, leaving access nobody chose.
*/
CREATE   PROCEDURE core.usp_SetUserBranches
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
PRINT N'Creating Procedure [core].[usp_PurgeExpiredAuth]...';


GO

/* Expired challenges and tokens are noise. Schedule this nightly. */
CREATE PROCEDURE core.usp_PurgeExpiredAuth
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM core.OtpChallenge
    WHERE ExpiresAtUtc < DATEADD(DAY, -1, SYSUTCDATETIME());

    DELETE FROM core.RefreshToken
    WHERE ExpiresAtUtc < DATEADD(DAY, -7, SYSUTCDATETIME());

    DELETE FROM core.LoginAttempt
    WHERE AttemptedAtUtc < DATEADD(DAY, -90, SYSUTCDATETIME());
END
GO
PRINT N'Creating Procedure [core].[usp_SaveUser]...';


GO

/*------------------------------------------------------------------ save user */

CREATE   PROCEDURE core.usp_SaveUser
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
PRINT N'Creating Procedure [core].[usp_SaveCatalogItem]...';


GO

CREATE   PROCEDURE core.usp_SaveCatalogItem
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
PRINT N'Creating Procedure [core].[usp_UpdateCustomer]...';


GO

CREATE   PROCEDURE core.usp_UpdateCustomer
    @CustomerId   NVARCHAR(40),
    @NameAr       NVARCHAR(160),
    @NameEn       NVARCHAR(160),
    @Phone        NVARCHAR(30)  = NULL,
    @Email        NVARCHAR(160) = NULL,
    @VatNumber    NVARCHAR(15)  = NULL,
    @CustomerType NVARCHAR(20)  = NULL,   -- null keeps
    @CreditLimitH BIGINT,
    @IsActive     BIT           = NULL,   -- null keeps
    @Actor        NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NameAr = NULLIF(LTRIM(RTRIM(@NameAr)), N'');
    SET @NameEn = NULLIF(LTRIM(RTRIM(@NameEn)), N'');

    IF @NameAr IS NULL OR @NameEn IS NULL
        THROW 68000, N'Both the Arabic and English name are required.', 1;

    IF @CreditLimitH IS NULL OR @CreditLimitH < 0
        THROW 68001, N'A credit limit cannot be negative.', 1;

    IF @CustomerType IS NOT NULL AND @CustomerType NOT IN (N'individual', N'business')
        THROW 68004, N'A customer is an individual or a business.', 1;

    BEGIN TRAN;

        DECLARE @BalanceH BIGINT, @WasActive BIT;

        SELECT @BalanceH = BalanceH, @WasActive = IsActive
        FROM core.Customer WITH (UPDLOCK, HOLDLOCK)
        WHERE CustomerId = @CustomerId;

        IF @BalanceH IS NULL
            THROW 68003, N'Customer not found.', 1;

        IF @CreditLimitH < @BalanceH
            THROW 68002, N'The new limit is below what this customer already owes.', 1;

        IF @IsActive = 0 AND @WasActive = 1 AND @BalanceH > 0
            THROW 68005, N'This customer still owes money. Settle the balance before deactivating.', 1;

        UPDATE core.Customer
        SET NameAr       = @NameAr,
            NameEn       = @NameEn,
            Phone        = NULLIF(LTRIM(RTRIM(@Phone)), N''),
            Email        = NULLIF(LTRIM(RTRIM(@Email)), N''),
            VatNumber    = NULLIF(LTRIM(RTRIM(@VatNumber)), N''),
            CustomerType = ISNULL(@CustomerType, CustomerType),
            CreditLimitH = @CreditLimitH,
            IsActive     = ISNULL(@IsActive, IsActive),
            UpdatedAtUtc = SYSUTCDATETIME(),
            UpdatedBy    = @Actor
        WHERE CustomerId = @CustomerId;

    COMMIT;
END
GO
PRINT N'Creating Procedure [core].[usp_SaveVendor]...';


GO

/*------------------------------------------------------------- save a vendor */

CREATE   PROCEDURE core.usp_SaveVendor
    @VendorId        NVARCHAR(40)  = NULL,   -- null creates
    @NameAr          NVARCHAR(160),
    @NameEn          NVARCHAR(160),
    @ContactPerson   NVARCHAR(160) = NULL,
    @Phone           NVARCHAR(30)  = NULL,
    @Email           NVARCHAR(160) = NULL,
    @VatNumber       NVARCHAR(15)  = NULL,
    @City            NVARCHAR(120) = NULL,
    @PaymentTermDays INT           = NULL,   -- null keeps (0 on create)
    @IsActive        BIT           = 1,
    @Actor           NVARCHAR(120),
    @SavedId         NVARCHAR(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NameAr = NULLIF(LTRIM(RTRIM(@NameAr)), N'');
    SET @NameEn = NULLIF(LTRIM(RTRIM(@NameEn)), N'');
    SET @Phone = NULLIF(LTRIM(RTRIM(@Phone)), N'');
    SET @VatNumber = NULLIF(LTRIM(RTRIM(@VatNumber)), N'');

    IF @NameAr IS NULL OR @NameEn IS NULL
        THROW 66000, N'Both names are required.', 1;

    /* The phone is how a missing delivery gets chased. */
    IF @Phone IS NULL
        THROW 66001, N'A phone number is required.', 1;

    IF @VatNumber IS NOT NULL AND (LEN(@VatNumber) <> 15 OR @VatNumber LIKE N'%[^0-9]%')
        THROW 66002, N'A Saudi VAT number is exactly 15 digits.', 1;

    IF @VatNumber IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.Vendor
        WHERE VatNumber = @VatNumber AND (@VendorId IS NULL OR VendorId <> @VendorId))
        THROW 66003, N'Another vendor already uses this VAT number.', 1;

    IF EXISTS (SELECT 1 FROM core.Vendor
               WHERE NameEn = @NameEn AND (@VendorId IS NULL OR VendorId <> @VendorId))
        THROW 66004, N'Another vendor already uses this name.', 1;

    IF @PaymentTermDays < 0
        THROW 66005, N'Payment terms cannot be negative.', 1;

    IF @VendorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Vendor WHERE VendorId = @VendorId)
        THROW 66006, N'Vendor not found.', 1;

    /* Switching a vendor off while money is owed hides a debt; the same rule
       core.usp_SetActive applies. */
    IF @VendorId IS NOT NULL AND @IsActive = 0 AND EXISTS (
        SELECT 1 FROM core.Vendor WHERE VendorId = @VendorId AND IsActive = 1)
       AND EXISTS (SELECT 1 FROM inv.Purchase
                   WHERE VendorId = @VendorId AND PaidOnReceipt = 0 AND PaidH < TotalH)
        THROW 66007, N'This vendor still has unpaid deliveries.', 1;

    IF @VendorId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'ven_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO core.Vendor
            (VendorId, NameAr, NameEn, ContactPerson, Phone, Email, VatNumber, City,
             PaymentTermDays, IsActive, CreatedBy, UpdatedBy)
        VALUES
            (@SavedId, @NameAr, @NameEn, NULLIF(LTRIM(RTRIM(@ContactPerson)), N''), @Phone,
             NULLIF(LTRIM(RTRIM(@Email)), N''), @VatNumber, NULLIF(LTRIM(RTRIM(@City)), N''),
             ISNULL(@PaymentTermDays, 0), ISNULL(@IsActive, 1), @Actor, @Actor);
    END
    ELSE
    BEGIN
        SET @SavedId = @VendorId;

        UPDATE core.Vendor
        SET NameAr          = @NameAr,
            NameEn          = @NameEn,
            ContactPerson   = NULLIF(LTRIM(RTRIM(@ContactPerson)), N''),
            Phone           = @Phone,
            Email           = NULLIF(LTRIM(RTRIM(@Email)), N''),
            VatNumber       = @VatNumber,
            City            = NULLIF(LTRIM(RTRIM(@City)), N''),
            PaymentTermDays = ISNULL(@PaymentTermDays, PaymentTermDays),
            IsActive        = ISNULL(@IsActive, IsActive),
            UpdatedAtUtc    = SYSUTCDATETIME(),
            UpdatedBy       = @Actor
        WHERE VendorId = @VendorId;
    END
END
GO
PRINT N'Creating Procedure [core].[usp_DeleteBillTemplate]...';


GO

/*------------------------------------------------------- delete bill template */

/*
  A real delete. A template is layout, not history: a printed receipt does not
  record which template drew it, so removing one orphans nothing. What does
  point at a template — a branch's default bill — is refused rather than
  silently cleared, and so is the audience default, which is what prints when
  nothing more specific matches.
*/
CREATE   PROCEDURE core.usp_DeleteBillTemplate
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
PRINT N'Creating Procedure [device].[usp_RecordHeartbeat]...';


GO

/*----------------------------------------------------------------- heartbeat */

/*
  One call does three things: records the state, answers with any queued
  commands, and tells the device how soon to come back.

  Folding the command collection into the heartbeat is the whole design. A
  separate poll would double the traffic to learn the same thing.
*/
CREATE   PROCEDURE device.usp_RecordHeartbeat
    @DeviceId       NVARCHAR(40),
    @PrinterStatus  NVARCHAR(20),
    @PaperStatus    NVARCHAR(20),
    @PrinterError   NVARCHAR(200) = NULL,
    @BatteryPercent INT = NULL,
    @NetworkType    NVARCHAR(20) = NULL,
    @AppVersion     NVARCHAR(40) = NULL,
    @NextIntervalMs INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @WasPrinter NVARCHAR(20), @WasPaper NVARCHAR(20), @WasSeen DATETIME2(0);

    SELECT @WasPrinter = PrinterStatus, @WasPaper = PaperStatus, @WasSeen = LastHeartbeatAtUtc
    FROM device.PosDevice WHERE DeviceId = @DeviceId;

    BEGIN TRAN;

        UPDATE device.PosDevice
        SET LastHeartbeatAtUtc = SYSUTCDATETIME(),
            PrinterStatus  = @PrinterStatus,
            PaperStatus    = @PaperStatus,
            PrinterError   = @PrinterError,
            BatteryPercent = @BatteryPercent,
            NetworkType    = @NetworkType,
            AppVersion     = ISNULL(@AppVersion, AppVersion)
        WHERE DeviceId = @DeviceId;

        INSERT INTO device.DeviceHeartbeat
            (DeviceId, PrinterStatus, PaperStatus, PrinterError,
             BatteryPercent, NetworkType, AppVersion)
        VALUES
            (@DeviceId, @PrinterStatus, @PaperStatus, @PrinterError,
             @BatteryPercent, @NetworkType, @AppVersion);

        /* An event per heartbeat would bury everything else. Only changes. */
        IF @WasPaper <> @PaperStatus AND @PaperStatus IN (N'low', N'empty')
        BEGIN
            INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
            VALUES (@DeviceId, N'paper', N'warning',
                    CONCAT(N'Paper ', @PaperStatus), N'حالة الورق تغيّرت');
        END

        IF @WasPrinter <> @PrinterStatus AND @PrinterStatus = N'error'
        BEGIN
            INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
            VALUES (@DeviceId, N'printer', N'error',
                    ISNULL(@PrinterError, N'Printer error'), N'خطأ في الطابعة');
        END

        /* Coming back after a gap is worth recording; it explains a missing
           receipt far better than an absence of rows. */
        IF @WasSeen IS NOT NULL AND DATEDIFF(SECOND, @WasSeen, SYSUTCDATETIME()) > 90
        BEGIN
            INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
            VALUES (@DeviceId, N'reconnected', N'info',
                    CONCAT(N'Back online after ',
                           DATEDIFF(SECOND, @WasSeen, SYSUTCDATETIME()), N's'),
                    N'عاد الاتصال');
        END

        /* Anything queued is now the device's. */
        UPDATE device.DeviceCommand
        SET Status = N'sent', SentAtUtc = SYSUTCDATETIME()
        WHERE DeviceId = @DeviceId AND Status = N'pending'
          AND ExpiresAtUtc > SYSUTCDATETIME();

        UPDATE device.DeviceCommand
        SET Status = N'expired', CompletedAtUtc = SYSUTCDATETIME(),
            ResultMessage = N'The device did not collect this in time.'
        WHERE DeviceId = @DeviceId AND Status IN (N'pending', N'sent')
          AND ExpiresAtUtc <= SYSUTCDATETIME();

    COMMIT;

    /*
      Come back sooner while there is work.

      Two seconds when something is outstanding, ten when idle. A ping then
      answers in about two seconds without holding a socket open all day — which
      is the compromise that makes polling acceptable here.
    */
    SET @NextIntervalMs = CASE
        WHEN EXISTS (SELECT 1 FROM device.DeviceCommand
                     WHERE DeviceId = @DeviceId AND Status IN (N'pending', N'sent'))
        THEN 2000 ELSE 10000 END;

    /* The commands to run, returned to the caller. */
    SELECT CommandId, CommandType, Payload
    FROM device.DeviceCommand
    WHERE DeviceId = @DeviceId AND Status = N'sent' AND CompletedAtUtc IS NULL
    ORDER BY QueuedAtUtc;
END
GO
PRINT N'Creating Procedure [device].[usp_RecordAnnouncement]...';


GO

/*------------------------------------------------------------------- record */

CREATE   PROCEDURE device.usp_RecordAnnouncement
    @SerialNumber    NVARCHAR(80),
    @ClaimedDeviceId NVARCHAR(40)  = NULL,
    @DeviceName      NVARCHAR(120) = NULL,
    @Manufacturer    NVARCHAR(60)  = NULL,
    @DeviceModel     NVARCHAR(60)  = NULL,
    @AndroidId       NVARCHAR(80)  = NULL,
    @AppVersion      NVARCHAR(40)  = NULL,
    @LocalIpAddress  NVARCHAR(45)  = NULL,
    @NetworkName     NVARCHAR(120) = NULL,
    @SourceIpAddress NVARCHAR(45)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* One row per terminal, refreshed. A row per announcement would grow
       without bound for a device left switched on. */
    MERGE device.DeviceAnnouncement AS target
    USING (SELECT @SerialNumber AS SerialNumber) AS source
       ON target.SerialNumber = source.SerialNumber
    WHEN MATCHED THEN UPDATE SET
        ClaimedDeviceId = ISNULL(@ClaimedDeviceId, target.ClaimedDeviceId),
        DeviceName      = ISNULL(@DeviceName, target.DeviceName),
        Manufacturer    = ISNULL(@Manufacturer, target.Manufacturer),
        DeviceModel     = ISNULL(@DeviceModel, target.DeviceModel),
        AndroidId       = ISNULL(@AndroidId, target.AndroidId),
        AppVersion      = ISNULL(@AppVersion, target.AppVersion),
        LocalIpAddress  = @LocalIpAddress,
        NetworkName     = @NetworkName,
        SourceIpAddress = @SourceIpAddress,
        LastSeenAtUtc   = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (SerialNumber, ClaimedDeviceId, DeviceName, Manufacturer, DeviceModel,
         AndroidId, AppVersion, LocalIpAddress, NetworkName, SourceIpAddress)
    VALUES
        (@SerialNumber, @ClaimedDeviceId, @DeviceName, @Manufacturer, @DeviceModel,
         @AndroidId, @AppVersion, @LocalIpAddress, @NetworkName, @SourceIpAddress);
END
GO
PRINT N'Creating Procedure [device].[usp_DiscoverDevices]...';


GO

/*------------------------------------------------------------------ discover */

/*
  What the admin sees.

  Recent announcements, each already matched against the registry so the modal
  can tell "new", "already yours" and "registered elsewhere" apart — which the
  brief rightly insists are different outcomes.
*/
CREATE   PROCEDURE device.usp_DiscoverDevices
    @WithinSeconds INT = 120
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        a.SerialNumber, a.ClaimedDeviceId, a.DeviceName, a.Manufacturer,
        a.DeviceModel, a.AppVersion, a.LocalIpAddress, a.NetworkName,
        a.FirstSeenAtUtc, a.LastSeenAtUtc,
        DATEDIFF(SECOND, a.LastSeenAtUtc, SYSUTCDATETIME()) AS SecondsSinceSeen,

        d.DeviceId        AS MatchedDeviceId,
        d.DeviceName      AS MatchedDeviceName,
        d.BranchId        AS MatchedBranchId,
        b.NameEn          AS MatchedBranchNameEn,

        /*
          Three outcomes, kept apart.

          available          no record holds this serial — it can be registered
          already_registered this serial is already one of ours
          claimed_elsewhere  the record exists but was never completed here

          Collapsing these would let an admin register a second record for a
          terminal that already has one, and every heartbeat afterwards would be
          ambiguous.
        */
        CASE
            WHEN d.DeviceId IS NULL THEN N'available'
            WHEN d.RegisteredAtUtc IS NOT NULL THEN N'already_registered'
            ELSE N'awaiting_registration'
        END AS DiscoveryStatus
    FROM device.DeviceAnnouncement AS a
    LEFT JOIN device.PosDevice AS d ON d.SerialNumber = a.SerialNumber
    LEFT JOIN core.Branch     AS b ON b.BranchId = d.BranchId
    WHERE DATEDIFF(SECOND, a.LastSeenAtUtc, SYSUTCDATETIME()) <= @WithinSeconds
    ORDER BY a.LastSeenAtUtc DESC;
END
GO
PRINT N'Creating Procedure [device].[usp_ConnectDiscovered]...';


GO

/*------------------------------------------------------------------ connect */

/*
  Bind a discovered terminal to a device record.

  Called after the challenge has been answered, and it re-checks rather than
  trusting the caller: a verification that happened is not the same as a
  verification that still applies.
*/
CREATE   PROCEDURE device.usp_ConnectDiscovered
    @SerialNumber  NVARCHAR(80),
    @DeviceId      NVARCHAR(40),
    @BranchId      NVARCHAR(40),
    @Location      NVARCHAR(120) = NULL,
    @DeviceName    NVARCHAR(120),
    @Actor         NVARCHAR(160),
    @Blocked       NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Blocked = NULL;

    /* Already ours, and complete. Offer to open it, never to duplicate it. */
    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE SerialNumber = @SerialNumber AND RegisteredAtUtc IS NOT NULL)
    BEGIN
        SET @Blocked = N'This terminal is already registered here.';
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM device.PosDevice WHERE DeviceId = @DeviceId)
    BEGIN
        SET @Blocked = N'That device id is already in use.';
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM device.DeviceAnnouncement WHERE SerialNumber = @SerialNumber)
    BEGIN
        SET @Blocked = N'That terminal has not announced itself recently.';
        RETURN;
    END

    BEGIN TRAN;

        /*
          A record and a code, in one step.

          The terminal is listening, so it collects the code on its next
          announcement and completes registration without anyone reading it
          aloud. The existing registration path is reused exactly — there is no
          second way to become registered, which is what the brief asks for.
        */
        INSERT INTO device.PosDevice
            (DeviceId, DeviceName, DeviceType, DeviceModel, SerialNumber, AndroidId,
             BranchId, Location, PaperWidth, RegistrationCode, CodeExpiresAtUtc,
             AppVersion, IsActive, CreatedBy)
        SELECT
            @DeviceId, @DeviceName, N'sunmi_v2', a.DeviceModel, @SerialNumber, a.AndroidId,
            @BranchId, @Location, 80,
            /* Short-lived: the terminal is on the other end of this exchange
               and will collect it within seconds. */
            CONCAT(N'DSC-', RIGHT(CONVERT(NVARCHAR(36), NEWID()), 4)),
            DATEADD(MINUTE, 10, SYSUTCDATETIME()),
            a.AppVersion, 1, @Actor
        FROM device.DeviceAnnouncement AS a
        WHERE a.SerialNumber = @SerialNumber;

        INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
        VALUES (@DeviceId, N'created', N'info',
                N'Created from network discovery', N'أُنشئ عبر الاكتشاف على الشبكة');

    COMMIT;
END
GO
PRINT N'Creating Procedure [device].[usp_RegisterDevice]...';


GO

/*==============================================================================
  Procedures
==============================================================================*/

/*------------------------------------------------------------------ register */

CREATE   PROCEDURE device.usp_RegisterDevice
    @RegistrationCode NVARCHAR(20),
    @SerialNumber     NVARCHAR(80),
    @AndroidId        NVARCHAR(80) = NULL,
    @DeviceModel      NVARCHAR(60) = NULL,
    @AppVersion       NVARCHAR(40) = NULL,
    @TokenHash        NVARCHAR(128),
    @DeviceId         NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @DeviceId = DeviceId FROM device.PosDevice
    WHERE RegistrationCode = @RegistrationCode;

    IF @DeviceId IS NULL
        THROW 58000, N'That registration code is not recognised.', 1;

    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE DeviceId = @DeviceId AND CodeExpiresAtUtc < SYSUTCDATETIME())
        THROW 58001, N'That registration code has expired. Ask for a new one.', 1;

    IF EXISTS (SELECT 1 FROM device.PosDevice WHERE DeviceId = @DeviceId AND IsActive = 0)
        THROW 58002, N'This device has been deactivated.', 1;

    /*
      A serial belongs to one device record.

      Re-registering the SAME terminal is fine — that is a reinstall. Presenting
      a different serial against a record that already has one means the code
      travelled, and enrolling a second till under one identity would make every
      heartbeat afterwards ambiguous.
    */
    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE SerialNumber = @SerialNumber AND DeviceId <> @DeviceId)
        THROW 58003, N'This terminal is already registered as another device.', 1;

    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE DeviceId = @DeviceId
                 AND SerialNumber IS NOT NULL
                 AND SerialNumber <> @SerialNumber)
        THROW 58004, N'This code was issued for a different terminal.', 1;

    BEGIN TRAN;

        UPDATE device.PosDevice
        SET SerialNumber     = @SerialNumber,
            AndroidId        = ISNULL(@AndroidId, AndroidId),
            DeviceModel      = ISNULL(@DeviceModel, DeviceModel),
            AppVersion       = ISNULL(@AppVersion, AppVersion),
            TokenHash        = @TokenHash,
            RegisteredAtUtc  = SYSUTCDATETIME(),
            /* Consumed. Single use is what stops a shared code enrolling a
               second terminal tomorrow. */
            RegistrationCode = NULL,
            CodeExpiresAtUtc = NULL,
            UpdatedAtUtc     = SYSUTCDATETIME()
        WHERE DeviceId = @DeviceId;

        INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
        VALUES (@DeviceId, N'registered', N'info',
                N'Device registered', N'تم تسجيل الجهاز');

    COMMIT;
END
GO
PRINT N'Creating Procedure [device].[usp_CompleteCommand]...';


GO

/*------------------------------------------------------------ command result */

CREATE   PROCEDURE device.usp_CompleteCommand
    @CommandId     NVARCHAR(40),
    @DeviceId      NVARCHAR(40),
    @Succeeded     BIT,
    @ResultMessage NVARCHAR(400) = NULL,
    @ResultData    NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Queued DATETIME2(3);
    SELECT @Queued = QueuedAtUtc FROM device.DeviceCommand
    WHERE CommandId = @CommandId AND DeviceId = @DeviceId;

    IF @Queued IS NULL
        THROW 58010, N'No such command for this device.', 1;

    UPDATE device.DeviceCommand
    SET Status         = CASE WHEN @Succeeded = 1 THEN N'succeeded' ELSE N'failed' END,
        CompletedAtUtc = SYSUTCDATETIME(),
        Succeeded      = @Succeeded,
        ResultMessage  = @ResultMessage,
        ResultData     = @ResultData,
        /* Queued to answered, as the admin experienced it. Measuring only the
           device's own work would report 40ms for a wait of several seconds. */
        RoundTripMs    = DATEDIFF(MILLISECOND, @Queued, SYSUTCDATETIME())
    WHERE CommandId = @CommandId;

    INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
    SELECT @DeviceId, c.CommandType,
           CASE WHEN @Succeeded = 1 THEN N'info' ELSE N'error' END,
           CONCAT(c.CommandType, N': ', ISNULL(@ResultMessage, N'done')),
           CONCAT(c.CommandType, N': ', ISNULL(@ResultMessage, N'تم'))
    FROM device.DeviceCommand AS c WHERE c.CommandId = @CommandId;
END
GO
PRINT N'Creating Procedure [fin].[usp_BalancePeriodExpectation]...';


GO

/* What the ledger says the position should be, per method. */
CREATE PROCEDURE fin.usp_BalancePeriodExpectation
    @PeriodId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId NVARCHAR(40), @From DATE, @To DATE;

    SELECT @BranchId = BranchId, @From = OpenedOn, @To = ISNULL(ClosedOn, CAST(SYSUTCDATETIME() AS DATE))
    FROM fin.BalancePeriod WHERE PeriodId = @PeriodId;

    IF @From IS NULL THROW 56002, N'Balance period not found.', 1;

    ;WITH Lines AS (
        SELECT l.AccountCode, l.DebitH, l.CreditH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE CAST(e.PostedAtUtc AS DATE) >= @From
          AND CAST(e.PostedAtUtc AS DATE) <= @To
          AND (e.BranchId = @BranchId OR e.BranchId IS NULL)
    )
    SELECT
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1000'), 0) AS CashH,
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1150'), 0) AS CardH,
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1400'), 0) AS CreditH,
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1100'), 0) AS BankH,
        ISNULL((SELECT SUM(DebitH - CreditH) FROM Lines WHERE AccountCode = N'1200'), 0) AS InventoryH,
        /* Payables is credit-normal, so flip it to read as a positive debt. */
        ISNULL((SELECT SUM(CreditH - DebitH) FROM Lines WHERE AccountCode = N'2000'), 0) AS PayablesH;
END
GO
PRINT N'Creating Procedure [fin].[usp_SaveRecurringPayment]...';


GO

CREATE   PROCEDURE fin.usp_SaveRecurringPayment
    @RecurringId   NVARCHAR(40)  = NULL,   -- null creates
    @DescriptionEn NVARCHAR(300),
    @DescriptionAr NVARCHAR(300) = NULL,   -- null → the English text
    @CategoryId    NVARCHAR(40),
    @BranchId      NVARCHAR(40)  = NULL,   -- null = the whole business
    @AmountH       BIGINT,
    @Frequency     NVARCHAR(20),
    @NextDueOn     DATE,
    @PaymentMethod NVARCHAR(20)  = N'bank',
    @Note          NVARCHAR(400) = NULL,
    @Status        NVARCHAR(20)  = NULL,   -- null keeps (active on create)
    @SavedId       NVARCHAR(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @DescriptionEn = NULLIF(LTRIM(RTRIM(@DescriptionEn)), N'');
    SET @DescriptionAr = ISNULL(NULLIF(LTRIM(RTRIM(@DescriptionAr)), N''), @DescriptionEn);

    IF @DescriptionEn IS NULL
        THROW 69100, N'Give the payment a description.', 1;

    IF @AmountH IS NULL OR @AmountH <= 0
        THROW 69101, N'Enter an amount above zero.', 1;

    IF @Frequency IS NULL OR @Frequency NOT IN (N'daily', N'weekly', N'monthly', N'quarterly', N'yearly')
        THROW 69102, N'Frequency is daily, weekly, monthly, quarterly or yearly.', 1;

    IF @NextDueOn IS NULL
        THROW 69103, N'When is the next payment due?', 1;

    IF @PaymentMethod IS NULL OR @PaymentMethod NOT IN (N'cash', N'card', N'bank', N'credit')
        THROW 69104, N'Pay by cash, card, bank or on credit.', 1;

    IF NOT EXISTS (SELECT 1 FROM fin.ExpenseCategory WHERE CategoryId = @CategoryId AND IsActive = 1)
        THROW 69105, N'Choose an active expense category.', 1;

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId)
        THROW 69106, N'Unknown branch.', 1;

    IF @Status IS NOT NULL AND @Status NOT IN (N'active', N'paused')
        THROW 69108, N'Status is active or paused.', 1;

    IF @RecurringId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.RecurringPayment WHERE RecurringId = @RecurringId)
        THROW 69107, N'Recurring payment not found.', 1;

    IF @RecurringId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'rec_', LEFT(LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')), 20));

        INSERT INTO fin.RecurringPayment
            (RecurringId, DescriptionAr, DescriptionEn, CategoryId, BranchId, AmountH,
             Frequency, NextDueOn, PaymentMethod, Status, Note)
        VALUES
            (@SavedId, @DescriptionAr, @DescriptionEn, @CategoryId, @BranchId, @AmountH,
             @Frequency, @NextDueOn, @PaymentMethod, ISNULL(@Status, N'active'),
             NULLIF(LTRIM(RTRIM(@Note)), N''));
    END
    ELSE
    BEGIN
        SET @SavedId = @RecurringId;

        UPDATE fin.RecurringPayment
        SET DescriptionAr = @DescriptionAr,
            DescriptionEn = @DescriptionEn,
            CategoryId    = @CategoryId,
            BranchId      = @BranchId,
            AmountH       = @AmountH,
            Frequency     = @Frequency,
            NextDueOn     = @NextDueOn,
            PaymentMethod = @PaymentMethod,
            Status        = ISNULL(@Status, Status),
            Note          = NULLIF(LTRIM(RTRIM(@Note)), N''),
            UpdatedAtUtc  = SYSUTCDATETIME()
        WHERE RecurringId = @RecurringId;
    END
END
GO
PRINT N'Creating Procedure [fin].[usp_OpenDrawer]...';


GO

/*--------------------------------------------------------------- cash drawer */

CREATE PROCEDURE fin.usp_OpenDrawer
    @BranchId     NVARCHAR(40),
    @OpeningCashH BIGINT,
    @OpenedBy     NVARCHAR(120),
    @SessionId    NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OpeningCashH < 0
        THROW 55000, N'An opening float cannot be negative.', 1;

    /* One open drawer per branch. Two would each claim the same movements and
       neither closing figure would mean anything. A filtered unique index
       enforces this as well; the check is here for the readable message. */
    IF EXISTS (SELECT 1 FROM fin.DrawerSession
               WHERE BranchId = @BranchId AND ClosedAtUtc IS NULL)
        THROW 55001, N'A drawer is already open at this branch.', 1;

    SET @SessionId = CONCAT(N'drw_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

    INSERT INTO fin.DrawerSession
        (SessionId, BranchId, OpenedAtUtc, OpeningCashH, OpenedBy)
    VALUES
        (@SessionId, @BranchId, SYSUTCDATETIME(), @OpeningCashH, @OpenedBy);
END
GO
PRINT N'Creating Procedure [fin].[usp_SaveCommissionRule]...';


GO

CREATE   PROCEDURE fin.usp_SaveCommissionRule
    @RuleId   NVARCHAR(40)  = NULL,   -- null creates
    @Basis    NVARCHAR(20),           -- percentage | fixed
    @Value    INT,
    @UserIds  NVARCHAR(MAX) = NULL,   -- comma separated; empty: everyone without their own rule
    @ItemIds  NVARCHAR(MAX) = NULL,   -- comma separated; empty: every service
    @IsActive BIT = 1,
    @SavedId  NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Basis NOT IN (N'percentage', N'fixed')
        THROW 64000, N'Commission is a percentage or a fixed amount.', 1;

    IF ISNULL(@Value, 0) <= 0
        THROW 64001, N'Enter a value above zero.', 1;

    /* A percentage above 100 pays out more than the sale brought in. */
    IF @Basis = N'percentage' AND @Value > 10000
        THROW 64002, N'A commission cannot exceed 100%.', 1;

    IF @RuleId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.CommissionRule WHERE RuleId = @RuleId)
        THROW 64005, N'No such commission rule.', 1;

    DECLARE @Users TABLE (UserId NVARCHAR(40) PRIMARY KEY);
    INSERT INTO @Users (UserId)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@UserIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF EXISTS (SELECT 1 FROM @Users AS u
               WHERE NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = u.UserId))
        THROW 64003, N'One of those people does not exist.', 1;

    DECLARE @Items TABLE (ItemId NVARCHAR(40) PRIMARY KEY);
    INSERT INTO @Items (ItemId)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@ItemIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    /* Commission is earned on work performed. usp_RecordSaleCommission only
       ever looks at service lines, so a product here would be a rule that
       silently never pays. */
    IF EXISTS (SELECT 1 FROM @Items AS i
               WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem
                                 WHERE ItemId = i.ItemId AND Kind = N'service'))
        THROW 64004, N'Commission rules cover services only, and one of those is not a service.', 1;

    BEGIN TRAN;

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

              fin.CommissionEntry records the amount at the moment of each sale,
              so past entries keep the rate that applied then. Recalculating them
              would rewrite what someone was told they had earned.
            */
            UPDATE fin.CommissionRule
            SET Basis = @Basis, Value = @Value, IsActive = @IsActive,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE RuleId = @RuleId;
        END

        DELETE FROM fin.CommissionRuleUser WHERE RuleId = @SavedId;
        INSERT INTO fin.CommissionRuleUser (RuleId, UserId) SELECT @SavedId, UserId FROM @Users;

        DELETE FROM fin.CommissionRuleItem WHERE RuleId = @SavedId;
        INSERT INTO fin.CommissionRuleItem (RuleId, ItemId) SELECT @SavedId, ItemId FROM @Items;

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_RecordSaleCommission]...';


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
PRINT N'Creating Procedure [fin].[usp_BuildExpenseRecognition]...';


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
PRINT N'Creating Procedure [fin].[usp_RebuildCustomerBalances]...';


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
PRINT N'Creating Procedure [fin].[usp_SetRecurringStatus]...';


GO

CREATE   PROCEDURE fin.usp_SetRecurringStatus
    @RecurringId NVARCHAR(40),
    @Status      NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status IS NULL OR @Status NOT IN (N'active', N'paused')
        THROW 69108, N'Status is active or paused.', 1;

    UPDATE fin.RecurringPayment
    SET Status = @Status, UpdatedAtUtc = SYSUTCDATETIME()
    WHERE RecurringId = @RecurringId;

    IF @@ROWCOUNT = 0
        THROW 69107, N'Recurring payment not found.', 1;
END
GO
PRINT N'Creating Procedure [fin].[usp_SaveExpenseCategory]...';


GO

CREATE   PROCEDURE fin.usp_SaveExpenseCategory
    @CategoryId  NVARCHAR(40) = NULL,   -- null creates
    @NameAr      NVARCHAR(120),
    @NameEn      NVARCHAR(120),
    @AccountCode NVARCHAR(10),
    @IsActive    BIT = NULL,            -- null keeps (active on create)
    @Actor       NVARCHAR(120),
    @SavedId     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NameAr = NULLIF(LTRIM(RTRIM(@NameAr)), N'');
    SET @NameEn = NULLIF(LTRIM(RTRIM(@NameEn)), N'');

    IF @NameAr IS NULL OR @NameEn IS NULL
        THROW 69000, N'Both names are required.', 1;

    IF NOT EXISTS (SELECT 1 FROM fin.Account
                   WHERE AccountCode = @AccountCode AND AccountType = N'expense'
                     AND IsActive = 1 AND AccountCode <> N'5100')
        THROW 69001, N'Choose an expense account.', 1;

    IF EXISTS (SELECT 1 FROM fin.ExpenseCategory
               WHERE NameEn = @NameEn AND (@CategoryId IS NULL OR CategoryId <> @CategoryId))
        THROW 69002, N'Another category already uses this name.', 1;

    IF @CategoryId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.ExpenseCategory WHERE CategoryId = @CategoryId)
        THROW 69003, N'Expense category not found.', 1;

    /* An active schedule would keep posting into a category nobody can pick. */
    IF @CategoryId IS NOT NULL AND @IsActive = 0
       AND EXISTS (SELECT 1 FROM fin.RecurringPayment WHERE CategoryId = @CategoryId AND Status = N'active')
        THROW 69004, N'Active recurring payments still use this category.', 1;

    IF @CategoryId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'exc_', LEFT(LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')), 20));

        INSERT INTO fin.ExpenseCategory
            (CategoryId, NameAr, NameEn, AccountCode, IsActive, CreatedBy, UpdatedBy)
        VALUES
            (@SavedId, @NameAr, @NameEn, @AccountCode, ISNULL(@IsActive, 1), @Actor, @Actor);
    END
    ELSE
    BEGIN
        SET @SavedId = @CategoryId;

        UPDATE fin.ExpenseCategory
        SET NameAr = @NameAr, NameEn = @NameEn, AccountCode = @AccountCode,
            IsActive = ISNULL(@IsActive, IsActive),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE CategoryId = @CategoryId;
    END
END
GO
PRINT N'Creating Procedure [fin].[usp_DrawerExpectation]...';


GO

/*
  What should be in the drawer right now.

  Derived from the ledger on every call rather than stored: a saved expectation
  goes stale the moment anything posts behind it, and counting against a stale
  number invents a variance that is not there.

  Only cash moves the drawer. Card takings sit in clearing until the bank
  settles, and a credit sale never touches it — counting either would make every
  close look short by the day's card total.
*/
CREATE PROCEDURE fin.usp_DrawerExpectation
    @SessionId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BranchId NVARCHAR(40), @From DATETIME2(3), @To DATETIME2(3), @OpeningH BIGINT;

    SELECT @BranchId = BranchId,
           @From     = OpenedAtUtc,
           @To       = ISNULL(ClosedAtUtc, SYSUTCDATETIME()),
           @OpeningH = OpeningCashH
    FROM fin.DrawerSession WHERE SessionId = @SessionId;

    IF @BranchId IS NULL AND NOT EXISTS (SELECT 1 FROM fin.DrawerSession WHERE SessionId = @SessionId)
        THROW 55002, N'Drawer session not found.', 1;

    ;WITH CashLines AS (
        SELECT e.Kind, l.DebitH, l.CreditH
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode = N'1000'
          AND e.PostedAtUtc >= @From AND e.PostedAtUtc <= @To
          AND (e.BranchId = @BranchId OR e.BranchId IS NULL)
    )
    SELECT
        @OpeningH AS OpeningCashH,
        ISNULL((SELECT SUM(DebitH)  FROM CashLines WHERE Kind = N'sale'), 0)                AS CashSalesH,
        ISNULL((SELECT SUM(DebitH)  FROM CashLines WHERE Kind = N'customer_collection'), 0) AS CashCollectionsH,
        ISNULL((SELECT SUM(DebitH)  FROM CashLines WHERE Kind = N'owner_contribution'), 0)  AS OwnerContributionsH,
        ISNULL((SELECT SUM(CreditH) FROM CashLines WHERE Kind = N'expense'), 0)             AS CashExpensesH,
        ISNULL((SELECT SUM(CreditH) FROM CashLines WHERE Kind = N'owner_withdrawal'), 0)    AS OwnerWithdrawalsH,
        ISNULL((SELECT SUM(CreditH) FROM CashLines WHERE Kind IN (N'return', N'void')), 0)  AS CashRefundsH,
        @OpeningH
            + ISNULL((SELECT SUM(DebitH)  FROM CashLines), 0)
            - ISNULL((SELECT SUM(CreditH) FROM CashLines), 0) AS ExpectedH;
END
GO
PRINT N'Creating Procedure [fin].[usp_PostJournalEntry]...';


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
PRINT N'Creating Procedure [fin].[usp_DeleteCommissionRule]...';


GO

/*
  A real delete.

  Commission already earned does not point back at its rule — each entry froze
  its basis and rate at the moment of sale — so removing a rule changes future
  sales only, which is what removing it means. The user and item sets cascade.
*/
CREATE   PROCEDURE fin.usp_DeleteCommissionRule
    @RuleId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM fin.CommissionRule WHERE RuleId = @RuleId;

    IF @@ROWCOUNT = 0 THROW 64005, N'No such commission rule.', 1;
END
GO
PRINT N'Creating Procedure [fin].[usp_DraftPayroll]...';


GO

/*
  Build a draft for a period.

  Commission comes from what was frozen at each sale, never recalculated —
  which is the entire reason it was frozen.
*/
CREATE PROCEDURE fin.usp_DraftPayroll
    @PeriodMonth CHAR(7),
    @BranchId    NVARCHAR(40) = NULL,
    @Actor       NVARCHAR(120),
    @RunId       NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM fin.PayrollRun
               WHERE PeriodMonth = @PeriodMonth
                 AND ISNULL(BranchId, N'') = ISNULL(@BranchId, N'')
                 AND Status = N'paid')
        THROW 56010, N'Payroll for this period has already been paid.', 1;

    BEGIN TRAN;

        DELETE FROM fin.PayrollRun
        WHERE PeriodMonth = @PeriodMonth
          AND ISNULL(BranchId, N'') = ISNULL(@BranchId, N'')
          AND Status = N'draft';

        DECLARE @Seq BIGINT = NEXT VALUE FOR fin.PayrollSequence;
        SET @RunId = CONCAT(N'pay_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO fin.PayrollRun
            (RunId, Reference, PeriodMonth, BranchId, Status, TotalH, CreatedBy)
        VALUES
            (@RunId, CONCAT(N'PR-', @Seq), @PeriodMonth, @BranchId, N'draft', 0, @Actor);

        INSERT INTO fin.PayrollLine (RunId, UserId, BaseSalaryH, CommissionH, AllowancesH, DeductionsH)
        SELECT
            @RunId,
            u.UserId,
            u.BaseSalaryH,
            ISNULL(c.EarnedH, 0),
            0,
            0
        FROM core.AppUser AS u
        LEFT JOIN (
            SELECT UserId, SUM(AmountH) AS EarnedH
            FROM fin.CommissionEntry
            WHERE PayrollRunId IS NULL
              AND CONVERT(CHAR(7), EarnedAtUtc, 126) = @PeriodMonth
            GROUP BY UserId
        ) AS c ON c.UserId = u.UserId
        WHERE u.Status = N'active'
          AND u.IsExternal = 0
          AND (@BranchId IS NULL
               OR EXISTS (SELECT 1 FROM core.UserBranch AS ub
                          WHERE ub.UserId = u.UserId AND ub.BranchId = @BranchId));

        UPDATE fin.PayrollRun
        SET TotalH = ISNULL((SELECT SUM(NetPayH) FROM fin.PayrollLine WHERE RunId = @RunId), 0)
        WHERE RunId = @RunId;

    COMMIT;
END
GO
PRINT N'Creating Procedure [inv].[usp_ReceivePurchase]...';


GO

/*------------------------------------------------------ receive a delivery */

/*
  Receive a delivery.

  As in 14, plus @Note, and a purchase paid on receipt is settled at once
  (PaidH = TotalH) so it never shows as owed.

  Cost is recalculated as a weighted average rather than overwritten. Taking the
  latest supplier price as the cost makes reported margin lurch every time a
  supplier changes their price, even on stock bought months earlier.
*/
CREATE   PROCEDURE inv.usp_ReceivePurchase
    @VendorId      NVARCHAR(40),
    @BranchId      NVARCHAR(40),
    @InvoiceNumber NVARCHAR(60) = NULL,
    @VatRate       DECIMAL(5,2) = 15.00,
    @PaidOnReceipt BIT = 0,
    @ReceivedBy    NVARCHAR(120),
    @Lines         inv.PurchaseLineTable READONLY,
    @PurchaseId    NVARCHAR(40) OUTPUT,
    @Reference     NVARCHAR(40) OUTPUT,
    @Note          NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Lines)
        THROW 54000, N'A delivery needs at least one line.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE Quantity <= 0 OR UnitCostH < 0)
        THROW 54001, N'Quantities must be above zero and costs cannot be negative.', 1;

    IF EXISTS (SELECT 1 FROM @Lines AS l
               JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
               WHERE i.TracksStock = 0)
        THROW 54002, N'A service cannot be received into stock.', 1;

    /* Purchase VAT is added on top of the net supplier price — the opposite
       direction to a retail sale, where it is extracted from the gross. */
    DECLARE @SubtotalH BIGINT = (SELECT SUM(Quantity * UnitCostH) FROM @Lines);
    DECLARE @TaxH      BIGINT = CAST(ROUND(@SubtotalH * @VatRate / 100.0, 0) AS BIGINT);
    DECLARE @TotalH    BIGINT = @SubtotalH + @TaxH;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR inv.PurchaseSequence;
        SET @PurchaseId = CONCAT(N'pur_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @Reference  = CONCAT(N'PO-', @Seq);

        INSERT INTO inv.Purchase
            (PurchaseId, Reference, VendorId, BranchId, InvoiceNumber,
             SubtotalH, TaxH, TotalH, PaidOnReceipt, PaidH, Note, ReceivedBy)
        VALUES
            (@PurchaseId, @Reference, @VendorId, @BranchId, @InvoiceNumber,
             @SubtotalH, @TaxH, @TotalH, @PaidOnReceipt,
             CASE WHEN @PaidOnReceipt = 1 THEN @TotalH ELSE 0 END,
             NULLIF(LTRIM(RTRIM(@Note)), N''), @ReceivedBy);

        INSERT INTO inv.PurchaseLine (PurchaseId, ItemId, Quantity, UnitCostH)
        SELECT @PurchaseId, ItemId, Quantity, UnitCostH FROM @Lines;

        /* Weighted average: (existing value + incoming value) / total units. */
        UPDATE i
        SET CostH = CASE
                        WHEN ISNULL(s.Quantity, 0) + agg.Qty = 0 THEN agg.AvgCost
                        ELSE CAST(
                            (ISNULL(s.Quantity, 0) * i.CostH + agg.Qty * agg.AvgCost)
                            / (ISNULL(s.Quantity, 0) + agg.Qty) AS BIGINT)
                    END,
            UpdatedAtUtc = SYSUTCDATETIME()
        FROM core.CatalogItem AS i
        JOIN (SELECT ItemId, SUM(Quantity) AS Qty,
                     SUM(Quantity * UnitCostH) / NULLIF(SUM(Quantity), 0) AS AvgCost
              FROM @Lines GROUP BY ItemId) AS agg ON agg.ItemId = i.ItemId
        LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId;

        /* Create the stock row if this branch has never held the item. */
        INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
        SELECT DISTINCT l.ItemId, @BranchId, 0
        FROM @Lines AS l
        WHERE NOT EXISTS (SELECT 1 FROM inv.StockLevel AS s
                          WHERE s.ItemId = l.ItemId AND s.BranchId = @BranchId);

        UPDATE s
        SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = SYSUTCDATETIME()
        FROM inv.StockLevel AS s
        JOIN (SELECT ItemId, SUM(Quantity) AS Qty FROM @Lines GROUP BY ItemId) AS agg
             ON agg.ItemId = s.ItemId
        WHERE s.BranchId = @BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, Actor)
        SELECT
            agg.ItemId, @BranchId, N'purchase', agg.Qty, s.Quantity, agg.AvgCost,
            @Reference, N'Delivery received', N'استلام بضاعة', @ReceivedBy
        FROM (SELECT ItemId, SUM(Quantity) AS Qty,
                     SUM(Quantity * UnitCostH) / NULLIF(SUM(Quantity), 0) AS AvgCost
              FROM @Lines GROUP BY ItemId) AS agg
        JOIN inv.StockLevel AS s ON s.ItemId = agg.ItemId AND s.BranchId = @BranchId;

        /* Stock arriving is an asset swap, not a cost. It becomes a cost when
           it is sold, through COGS. */
        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1200', @SubtotalH, 0, N'Inventory'),
            (N'1300', @TaxH, 0, N'Input VAT'),
            (CASE WHEN @PaidOnReceipt = 1 THEN N'1000' ELSE N'2000' END, 0, @TotalH, N'Supplier');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'purchase', @DescriptionEn = N'Delivery received',
            @DescriptionAr = N'استلام بضاعة', @SourceReference = @Reference,
            @BranchId = @BranchId, @Actor = @ReceivedBy,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

    COMMIT;
END
GO
PRINT N'Creating Procedure [inv].[usp_RecordVendorPayment]...';


GO

/*---------------------------------------------------------- pay a vendor */

/*
  Pay a supplier.

  The amount is allocated to the oldest unsettled purchases first, or only to
  @PurchaseId when one is named. More than is owed is refused: an overpayment
  would leave a debit balance on payables that nothing explains.
*/
CREATE   PROCEDURE inv.usp_RecordVendorPayment
    @VendorId   NVARCHAR(40),
    @AmountH    BIGINT,
    @Method     NVARCHAR(20),
    @PurchaseId NVARCHAR(40)  = NULL,
    @BranchId   NVARCHAR(40)  = NULL,
    @Note       NVARCHAR(400) = NULL,
    @Actor      NVARCHAR(120),
    @PaymentId  NVARCHAR(40)  OUTPUT,
    @Reference  NVARCHAR(40)  OUTPUT,
    @EntryId    NVARCHAR(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AmountH IS NULL OR @AmountH <= 0
        THROW 66010, N'A payment must be above zero.', 1;

    IF @Method IS NULL OR @Method NOT IN (N'cash', N'card', N'bank')
        THROW 66013, N'Pay by cash, card or bank.', 1;

    DECLARE @VendorNameEn NVARCHAR(160), @VendorNameAr NVARCHAR(160);
    SELECT @VendorNameEn = NameEn, @VendorNameAr = NameAr FROM core.Vendor WHERE VendorId = @VendorId;

    IF @VendorNameEn IS NULL
        THROW 66011, N'Vendor not found.', 1;

    BEGIN TRAN;

        /* Locked, so two payments at once cannot both settle the same debt. */
        DECLARE @Open TABLE (PurchaseId NVARCHAR(40) PRIMARY KEY, BranchId NVARCHAR(40) NULL,
                             OwedH BIGINT, Seq INT);

        INSERT INTO @Open (PurchaseId, BranchId, OwedH, Seq)
        SELECT p.PurchaseId, p.BranchId, p.TotalH - p.PaidH,
               ROW_NUMBER() OVER (ORDER BY p.ReceivedAtUtc, p.Reference)
        FROM inv.Purchase AS p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.VendorId = @VendorId
          AND p.PaidOnReceipt = 0
          AND p.PaidH < p.TotalH
          AND (@PurchaseId IS NULL OR p.PurchaseId = @PurchaseId);

        IF @PurchaseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @Open)
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM inv.Purchase WHERE PurchaseId = @PurchaseId AND VendorId = @VendorId)
                THROW 66014, N'That purchase is not from this vendor.', 1;
            ELSE
                THROW 66015, N'That purchase is already settled.', 1;
        END;

        IF @AmountH > ISNULL((SELECT SUM(OwedH) FROM @Open), 0)
            THROW 66012, N'That is more than is owed to this vendor.', 1;

        /* Oldest first: each purchase takes what it still owes, the last one
           takes whatever is left of the payment. */
        DECLARE @Alloc TABLE (PurchaseId NVARCHAR(40) PRIMARY KEY, BranchId NVARCHAR(40) NULL, AmountH BIGINT);

        INSERT INTO @Alloc (PurchaseId, BranchId, AmountH)
        SELECT PurchaseId, BranchId,
               CASE WHEN RunningH <= @AmountH THEN OwedH ELSE @AmountH - (RunningH - OwedH) END
        FROM (SELECT PurchaseId, BranchId, OwedH,
                     SUM(OwedH) OVER (ORDER BY Seq ROWS UNBOUNDED PRECEDING) AS RunningH
              FROM @Open) AS o
        WHERE RunningH - OwedH < @AmountH;

        /* No branch given: the branch of what was settled, when that is one. */
        IF @BranchId IS NULL AND (SELECT COUNT(DISTINCT BranchId) FROM @Alloc) = 1
           AND NOT EXISTS (SELECT 1 FROM @Alloc WHERE BranchId IS NULL)
            SET @BranchId = (SELECT TOP (1) BranchId FROM @Alloc);

        DECLARE @Seq BIGINT = NEXT VALUE FOR inv.VendorPaymentSequence;
        SET @PaymentId = CONCAT(N'vpy_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @Reference = CONCAT(N'VP-', @Seq);

        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'2000', @AmountH, 0, N'Accounts payable'),
            (CASE WHEN @Method = N'cash' THEN N'1000' ELSE N'1100' END, 0, @AmountH, @Method);

        DECLARE @DescEn NVARCHAR(400) = CONCAT(N'Vendor payment ', @Reference, N' — ', @VendorNameEn);
        DECLARE @DescAr NVARCHAR(400) = CONCAT(N'سداد مورد ', @Reference, N' — ', @VendorNameAr);

        EXEC fin.usp_PostJournalEntry
            @Kind            = N'supplier_payment',
            @DescriptionEn   = @DescEn,
            @DescriptionAr   = @DescAr,
            @SourceReference = @Reference,
            @BranchId        = @BranchId,
            @Actor           = @Actor,
            @Lines           = @Entry,
            @EntryId         = @EntryId OUTPUT;

        INSERT INTO inv.VendorPayment
            (PaymentId, Reference, VendorId, BranchId, AmountH, Method, Note, EntryId, PaidBy)
        VALUES
            (@PaymentId, @Reference, @VendorId, @BranchId, @AmountH, @Method,
             NULLIF(LTRIM(RTRIM(@Note)), N''), @EntryId, @Actor);

        INSERT INTO inv.VendorPaymentAllocation (PaymentId, PurchaseId, AmountH)
        SELECT @PaymentId, PurchaseId, AmountH FROM @Alloc WHERE AmountH > 0;

        UPDATE p
        SET PaidH = p.PaidH + a.AmountH
        FROM inv.Purchase AS p
        JOIN @Alloc AS a ON a.PurchaseId = p.PurchaseId;

    COMMIT;
END
GO
PRINT N'Creating Procedure [inv].[usp_AdjustStock]...';


GO

/*
  Adjust stock.

  A correction, a stocktake or a write-off. The difference against the expected
  quantity posts to stock variance rather than disappearing, because unexplained
  shrinkage is the thing an owner most needs to see.
*/
CREATE PROCEDURE inv.usp_AdjustStock
    @ItemId      NVARCHAR(40),
    @BranchId    NVARCHAR(40),
    @NewQuantity DECIMAL(18,3),
    @ReasonEn    NVARCHAR(400),
    @ReasonAr    NVARCHAR(400) = NULL,
    @Actor       NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@ReasonEn, N''))) = N''
        THROW 54010, N'An adjustment needs a reason on the record.', 1;

    IF @NewQuantity < 0
        THROW 54011, N'Stock cannot be negative.', 1;

    IF NOT EXISTS (SELECT 1 FROM core.CatalogItem
                   WHERE ItemId = @ItemId AND TracksStock = 1)
        THROW 54012, N'This item does not track stock.', 1;

    BEGIN TRAN;

        INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
        SELECT @ItemId, @BranchId, 0
        WHERE NOT EXISTS (SELECT 1 FROM inv.StockLevel
                          WHERE ItemId = @ItemId AND BranchId = @BranchId);

        DECLARE @Old DECIMAL(18,3) = (SELECT Quantity FROM inv.StockLevel
                                      WHERE ItemId = @ItemId AND BranchId = @BranchId);
        DECLARE @Delta DECIMAL(18,3) = @NewQuantity - @Old;

        IF @Delta <> 0
        BEGIN
            UPDATE inv.StockLevel
            SET Quantity = @NewQuantity, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE ItemId = @ItemId AND BranchId = @BranchId;

            INSERT INTO inv.StockMovement
                (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
                 ReasonEn, ReasonAr, Actor)
            SELECT @ItemId, @BranchId, N'adjustment', @Delta, @NewQuantity, i.CostH,
                   @ReasonEn, ISNULL(@ReasonAr, @ReasonEn), @Actor
            FROM core.CatalogItem AS i WHERE i.ItemId = @ItemId;

            /* The value of what was gained or lost. */
            DECLARE @CostH BIGINT = (SELECT CostH FROM core.CatalogItem WHERE ItemId = @ItemId);
            DECLARE @ValueH BIGINT = CAST(ROUND(ABS(@Delta) * @CostH, 0) AS BIGINT);

            IF @ValueH > 0
            BEGIN
                DECLARE @Entry fin.JournalLineTable;

                IF @Delta < 0
                    INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                        (N'5200', @ValueH, 0, N'Stock variance'),
                        (N'1200', 0, @ValueH, N'Inventory');
                ELSE
                    INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                        (N'1200', @ValueH, 0, N'Inventory'),
                        (N'5200', 0, @ValueH, N'Stock variance');

                DECLARE @EntryId NVARCHAR(40);
                EXEC fin.usp_PostJournalEntry
                    @Kind = N'stock_adjustment', @DescriptionEn = @ReasonEn,
                    @DescriptionAr = @ReasonAr, @SourceReference = @ItemId,
                    @BranchId = @BranchId, @Actor = @Actor,
                    @Lines = @Entry, @EntryId = @EntryId OUTPUT;
            END
        END

    COMMIT;
END
GO
PRINT N'Creating Procedure [sales].[usp_IssueReturn]...';


GO

/*------------------------------------------------------------- issue a return */

CREATE   PROCEDURE sales.usp_IssueReturn
    @SaleId       NVARCHAR(40),
    @ReasonCode   NVARCHAR(30),
    @Note         NVARCHAR(400) = NULL,
    @RefundMethod NVARCHAR(20),
    @Actor        NVARCHAR(120),
    @Lines        sales.ReturnLineTable READONLY,
    @ReturnId     NVARCHAR(40) OUTPUT,
    @NoteNumber   NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');

    IF @ReasonCode IS NULL OR @ReasonCode NOT IN
       (N'damaged', N'not_as_described', N'changed_mind', N'wrong_item', N'other')
        THROW 67008, N'Choose a reason for the return.', 1;

    IF @ReasonCode = N'other' AND @Note IS NULL
        THROW 67009, N'Describe the reason when choosing "Other".', 1;

    IF @RefundMethod IS NULL OR @RefundMethod NOT IN (N'cash', N'card', N'credit', N'bank')
        THROW 67005, N'Refund by cash, card, bank or to the customer''s account.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE Quantity < 0)
        THROW 67010, N'Return quantities cannot be negative.', 1;

    DECLARE @Req TABLE (SaleLineId BIGINT PRIMARY KEY, Qty DECIMAL(18,3) NOT NULL);

    INSERT INTO @Req (SaleLineId, Qty)
    SELECT SaleLineId, SUM(Quantity) FROM @Lines WHERE Quantity > 0 GROUP BY SaleLineId;

    IF NOT EXISTS (SELECT 1 FROM @Req)
        THROW 67002, N'Choose at least one item to return.', 1;

    BEGIN TRAN;

        DECLARE @Status NVARCHAR(40), @BranchId NVARCHAR(40), @CustomerId NVARCHAR(40),
                @Invoice NVARCHAR(40), @SaleTotalH BIGINT, @SaleTaxH BIGINT, @SaleDiscountH BIGINT;

        /* The lock serialises returns against one sale. */
        SELECT @Status = Status, @BranchId = BranchId, @CustomerId = CustomerId,
               @Invoice = InvoiceNumber, @SaleTotalH = TotalH, @SaleTaxH = TaxH,
               @SaleDiscountH = DiscountH
        FROM sales.Sale WITH (UPDLOCK, HOLDLOCK)
        WHERE SaleId = @SaleId;

        IF @Invoice IS NULL
            THROW 67000, N'Sale not found.', 1;

        IF @Status = N'voided'
            THROW 67001, N'A voided sale has nothing left to return.', 1;

        IF EXISTS (SELECT 1 FROM @Req AS r
                   WHERE NOT EXISTS (SELECT 1 FROM sales.SaleLine AS sl
                                     WHERE sl.SaleLineId = r.SaleLineId AND sl.SaleId = @SaleId))
            THROW 67003, N'That line is not part of this invoice.', 1;

        IF EXISTS (SELECT 1 FROM @Req AS r
                   JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
                   WHERE r.Qty > sl.Quantity - sl.ReturnedQty)
            THROW 67004, N'You cannot return more than was sold and not already returned.', 1;

        /*------------------------------------------------------ price it */

        DECLARE @GrossH BIGINT = (SELECT SUM(UnitPriceH * Quantity - LineDiscountH)
                                  FROM sales.SaleLine WHERE SaleId = @SaleId);

        DECLARE @Calc TABLE
        (
            SaleLineId BIGINT PRIMARY KEY,
            ItemId     NVARCHAR(40),
            Qty        DECIMAL(18,3),
            UnitPriceH BIGINT,
            UnitCostH  BIGINT,
            Tracks     BIT,
            IsService  BIT,
            PortionH   BIGINT,
            AmountH    BIGINT
        );

        INSERT INTO @Calc (SaleLineId, ItemId, Qty, UnitPriceH, UnitCostH, Tracks, IsService, PortionH, AmountH)
        SELECT sl.SaleLineId, sl.ItemId, r.Qty, sl.UnitPriceH, sl.UnitCostH,
               ISNULL(ci.TracksStock, 0),
               CASE WHEN sl.Kind = N'service' THEN 1 ELSE 0 END,
               CAST(ROUND(CAST(sl.UnitPriceH * sl.Quantity - sl.LineDiscountH AS DECIMAL(38,6))
                          * r.Qty / sl.Quantity, 0) AS BIGINT),
               0
        FROM @Req AS r
        JOIN sales.SaleLine AS sl ON sl.SaleLineId = r.SaleLineId
        LEFT JOIN core.CatalogItem AS ci ON ci.ItemId = sl.ItemId;

        /* Each line gives back its share of the invoice discount. */
        UPDATE @Calc
        SET AmountH = PortionH - CASE WHEN @GrossH > 0
                                      THEN CAST(ROUND(CAST(@SaleDiscountH AS DECIMAL(38,6)) * PortionH / @GrossH, 0) AS BIGINT)
                                      ELSE 0 END;

        DECLARE @Completes BIT =
            CASE WHEN EXISTS (SELECT 1 FROM sales.SaleLine AS sl
                              LEFT JOIN @Req AS r ON r.SaleLineId = sl.SaleLineId
                              WHERE sl.SaleId = @SaleId
                                AND sl.Quantity - sl.ReturnedQty - ISNULL(r.Qty, 0) > 0)
                 THEN 0 ELSE 1 END;

        DECLARE @PriorTotalH BIGINT = ISNULL((SELECT SUM(RefundH) FROM sales.SaleReturn WHERE SaleId = @SaleId), 0);
        DECLARE @PriorTaxH   BIGINT = ISNULL((SELECT SUM(TaxH)    FROM sales.SaleReturn WHERE SaleId = @SaleId), 0);

        DECLARE @TotalH BIGINT = (SELECT SUM(AmountH) FROM @Calc);

        /* The last return takes exactly what is left, so rounding never leaves
           a halala behind (or refunds one too many). The difference lands on
           the largest line. */
        IF @Completes = 1
        BEGIN
            DECLARE @Residue BIGINT = (@SaleTotalH - @PriorTotalH) - @TotalH;

            IF @Residue <> 0
                UPDATE c SET AmountH = c.AmountH + @Residue
                FROM @Calc AS c
                WHERE c.SaleLineId = (SELECT TOP (1) SaleLineId FROM @Calc ORDER BY AmountH DESC, SaleLineId);

            SET @TotalH = @SaleTotalH - @PriorTotalH;
        END

        IF @TotalH < 0 SET @TotalH = 0;

        DECLARE @TaxH BIGINT =
            CASE WHEN @Completes = 1 THEN @SaleTaxH - @PriorTaxH
                 WHEN @SaleTotalH > 0
                      THEN CAST(ROUND(CAST(@TotalH AS DECIMAL(38,6)) * @SaleTaxH / @SaleTotalH, 0) AS BIGINT)
                 ELSE 0 END;

        IF @TaxH < 0 SET @TaxH = 0;
        IF @TaxH > @TotalH SET @TaxH = @TotalH;

        DECLARE @NetH  BIGINT = @TotalH - @TaxH;
        DECLARE @CogsH BIGINT = ISNULL((SELECT SUM(CAST(ROUND(Qty * UnitCostH, 0) AS BIGINT))
                                        FROM @Calc WHERE Tracks = 1), 0);

        /*------------------------------------------------- refund checks */

        IF @RefundMethod = N'credit'
        BEGIN
            IF @CustomerId IS NULL
                THROW 67006, N'A refund to account needs a customer on the sale.', 1;

            IF @TotalH > ISNULL((SELECT BalanceH FROM core.Customer WITH (UPDLOCK)
                                 WHERE CustomerId = @CustomerId), 0)
                THROW 67007, N'The refund is more than the customer owes. Refund it in cash or by card instead.', 1;
        END

        /*--------------------------------------------------------- write */

        DECLARE @Seq BIGINT = NEXT VALUE FOR sales.CreditNoteSequence;
        SET @ReturnId   = CONCAT(N'ret_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @NoteNumber = CONCAT(N'CN-', @Seq);

        INSERT INTO sales.SaleReturn
            (ReturnId, SaleId, ReasonAr, ReasonEn, RefundH, ReturnedBy,
             NoteNumber, BranchId, CustomerId, ReasonCode, Note,
             SubtotalH, TaxH, CogsH, RefundMethod)
        VALUES
            (@ReturnId, @SaleId, @Note, ISNULL(@Note, @ReasonCode), @TotalH, @Actor,
             @NoteNumber, @BranchId, @CustomerId, @ReasonCode, @Note,
             @NetH, @TaxH, @CogsH, @RefundMethod);

        INSERT INTO sales.SaleReturnLine (ReturnId, SaleLineId, Quantity, ItemId, UnitPriceH, UnitCostH, AmountH)
        SELECT @ReturnId, SaleLineId, Qty, ItemId, UnitPriceH, UnitCostH, AmountH FROM @Calc;

        /* Commission on returned work was not earned. Only what payroll has not
           yet paid is reduced, in proportion to what remains of the item. */
        DECLARE @Comm TABLE (ItemId NVARCHAR(40) PRIMARY KEY, BeforeQty DECIMAL(18,3), AfterQty DECIMAL(18,3));

        INSERT INTO @Comm (ItemId, BeforeQty, AfterQty)
        SELECT sl.ItemId,
               SUM(sl.Quantity - sl.ReturnedQty),
               SUM(sl.Quantity - sl.ReturnedQty - ISNULL(r.Qty, 0))
        FROM sales.SaleLine AS sl
        LEFT JOIN @Req AS r ON r.SaleLineId = sl.SaleLineId
        WHERE sl.SaleId = @SaleId
          AND sl.ItemId IN (SELECT ItemId FROM @Calc WHERE IsService = 1)
        GROUP BY sl.ItemId;

        DELETE ce
        FROM fin.CommissionEntry AS ce
        JOIN @Comm AS c ON c.ItemId = ce.ItemId
        WHERE ce.SaleId = @SaleId AND ce.PayrollRunId IS NULL AND c.AfterQty <= 0;

        UPDATE ce
        SET AmountH = CAST(ROUND(CAST(ce.AmountH AS DECIMAL(38,6)) * c.AfterQty / c.BeforeQty, 0) AS BIGINT)
        FROM fin.CommissionEntry AS ce
        JOIN @Comm AS c ON c.ItemId = ce.ItemId
        WHERE ce.SaleId = @SaleId AND ce.PayrollRunId IS NULL
          AND c.AfterQty > 0 AND c.BeforeQty > c.AfterQty;

        UPDATE sl
        SET ReturnedQty = sl.ReturnedQty + r.Qty
        FROM sales.SaleLine AS sl
        JOIN @Req AS r ON r.SaleLineId = sl.SaleLineId;

        UPDATE sales.Sale
        SET Status = CASE WHEN @Completes = 1 THEN N'returned' ELSE N'partially_returned' END,
            UpdatedAtUtc = SYSUTCDATETIME(),
            UpdatedBy = @Actor
        WHERE SaleId = @SaleId;

        /* Stock comes back to the branch that sold it. */
        IF @BranchId IS NOT NULL
        BEGIN
            INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
            SELECT DISTINCT c.ItemId, @BranchId, 0
            FROM @Calc AS c
            WHERE c.Tracks = 1
              AND NOT EXISTS (SELECT 1 FROM inv.StockLevel AS s
                              WHERE s.ItemId = c.ItemId AND s.BranchId = @BranchId);

            UPDATE s
            SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = SYSUTCDATETIME()
            FROM inv.StockLevel AS s
            JOIN (SELECT ItemId, SUM(Qty) AS Qty FROM @Calc WHERE Tracks = 1 GROUP BY ItemId) AS agg
                 ON agg.ItemId = s.ItemId
            WHERE s.BranchId = @BranchId;

            INSERT INTO inv.StockMovement
                (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
                 Reference, ReasonEn, ReasonAr, Actor)
            SELECT agg.ItemId, @BranchId, N'return', agg.Qty, s.Quantity, agg.UnitCostH,
                   @NoteNumber, CONCAT(N'Return against ', @Invoice), CONCAT(N'مرتجع على ', @Invoice), @Actor
            FROM (SELECT ItemId, SUM(Qty) AS Qty, MAX(UnitCostH) AS UnitCostH
                  FROM @Calc WHERE Tracks = 1 GROUP BY ItemId) AS agg
            JOIN inv.StockLevel AS s ON s.ItemId = agg.ItemId AND s.BranchId = @BranchId;
        END

        IF @RefundMethod = N'credit' AND @TotalH > 0
            UPDATE core.Customer
            SET BalanceH = BalanceH - @TotalH, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
            WHERE CustomerId = @CustomerId;

        IF @TotalH > 0 OR @CogsH > 0
        BEGIN
            DECLARE @Entry fin.JournalLineTable;
            INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                (N'4100', @NetH, 0, N'Sales returned'),
                (N'2100', @TaxH, 0, N'Output VAT reversed'),
                (CASE @RefundMethod WHEN N'cash' THEN N'1000'
                                    WHEN N'card' THEN N'1150'
                                    WHEN N'bank' THEN N'1100'
                                    ELSE N'1400' END, 0, @TotalH, CONCAT(N'Refund — ', @RefundMethod)),
                (N'1200', @CogsH, 0, N'Inventory returned'),
                (N'5100', 0, @CogsH, N'Cost of goods sold reversed');

            DECLARE @DescEn NVARCHAR(400) = CONCAT(N'Credit note ', @NoteNumber, N' for ', @Invoice);
            DECLARE @DescAr NVARCHAR(400) = CONCAT(N'إشعار دائن ', @NoteNumber, N' للفاتورة ', @Invoice);
            DECLARE @EntryId NVARCHAR(40);

            EXEC fin.usp_PostJournalEntry
                @Kind            = N'return',
                @DescriptionEn   = @DescEn,
                @DescriptionAr   = @DescAr,
                @SourceReference = @NoteNumber,
                @BranchId        = @BranchId,
                @Actor           = @Actor,
                @Lines           = @Entry,
                @EntryId         = @EntryId OUTPUT;

            UPDATE sales.SaleReturn SET EntryId = @EntryId WHERE ReturnId = @ReturnId;
        END

    COMMIT;
END
GO
PRINT N'Creating Procedure [sales].[usp_DeleteDiscount]...';


GO

/*------------------------------------------------------------ delete discount */

/*
  Delete only what was never used.

  A discount applied to a sale is named by that sale; removing it would leave
  the invoice pointing at nothing. Those are refused, and the answer is to
  deactivate them. One that was set up and never used is a mistake, and a
  mistake should be removable.
*/
CREATE   PROCEDURE sales.usp_DeleteDiscount
    @DiscountId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Used INT = (SELECT UsageCount FROM sales.Discount WHERE DiscountId = @DiscountId);

    IF @Used IS NULL
        THROW 63015, N'No such discount.', 1;

    IF @Used > 0 OR EXISTS (SELECT 1 FROM sales.Sale WHERE DiscountId = @DiscountId)
        THROW 63016, N'This discount has been used on real sales. Deactivate it instead so the history stays intact.', 1;

    /* DiscountScope cascades. */
    DELETE FROM sales.Discount WHERE DiscountId = @DiscountId;
END
GO
PRINT N'Creating Procedure [sales].[usp_SaveDiscount]...';


GO

/*-------------------------------------------------------------- save discount */

CREATE   PROCEDURE sales.usp_SaveDiscount
    @DiscountId     NVARCHAR(40)  = NULL,   -- null creates
    @NameAr         NVARCHAR(160),
    @NameEn         NVARCHAR(160),
    @Description    NVARCHAR(400) = NULL,
    @DiscountType   NVARCHAR(20),           -- percentage | fixed
    @Value          INT,                    -- basis points, or halalas
    @MaxDiscountH   BIGINT = NULL,          -- null: no cap
    @MinSubtotalH   BIGINT = 0,
    @ApprovalAboveH BIGINT = NULL,          -- null: never needs approval
    @AppliesTo      NVARCHAR(20) = N'all',  -- all | products | services | selected
    @AppliesToIds   NVARCHAR(MAX) = NULL,   -- item and category ids, comma separated
    @BranchIds      NVARCHAR(MAX) = NULL,   -- empty: every branch
    @RoleIds        NVARCHAR(MAX) = NULL,   -- empty: anyone at the till
    @IsAutomatic    BIT = 0,
    @AllowStacking  BIT = 0,
    @ActiveDays     NVARCHAR(20) = N'',     -- 0 = Sunday, comma separated; empty: every day
    @StartsOn       DATE = NULL,
    @EndsOn         DATE = NULL,
    @IsActive       BIT = 1,
    @SavedId        NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF LTRIM(RTRIM(ISNULL(@NameAr, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@NameEn, N''))) = N''
        THROW 63000, N'Both names are required.', 1;

    IF @DiscountId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sales.Discount WHERE DiscountId = @DiscountId)
        THROW 63015, N'No such discount.', 1;

    IF EXISTS (SELECT 1 FROM sales.Discount
               WHERE NameEn = @NameEn AND (@DiscountId IS NULL OR DiscountId <> @DiscountId))
        THROW 63014, N'Another discount already uses this name.', 1;

    IF @DiscountType NOT IN (N'percentage', N'fixed')
        THROW 63001, N'A discount is either a percentage or a fixed amount.', 1;

    IF ISNULL(@Value, 0) <= 0
        THROW 63002, N'Enter a value above zero, or the discount does nothing.', 1;

    /* A percentage above 100 would pay the customer to take the goods. */
    IF @DiscountType = N'percentage' AND @Value > 10000
        THROW 63003, N'A percentage discount cannot exceed 100%.', 1;

    IF @MaxDiscountH < 0
        THROW 63004, N'A maximum cannot be negative.', 1;

    IF ISNULL(@MinSubtotalH, 0) < 0
        THROW 63005, N'A minimum cannot be negative.', 1;

    IF @ApprovalAboveH < 0
        THROW 63006, N'An approval threshold cannot be negative.', 1;

    /* A fixed discount capped below itself is always clipped — almost certainly
       a typo rather than a decision. */
    IF @DiscountType = N'fixed' AND @MaxDiscountH > 0 AND @MaxDiscountH < @Value
        THROW 63017, N'The maximum is below the discount itself, so it would always be clipped.', 1;

    IF @EndsOn IS NOT NULL AND @StartsOn IS NOT NULL AND @EndsOn < @StartsOn
        THROW 63007, N'The end date cannot be before the start date.', 1;

    IF @AppliesTo NOT IN (N'all', N'products', N'services', N'selected')
        THROW 63008, N'Applies to all, products, services or selected.', 1;

    /*------------------------------------------------------------- the sets */

    DECLARE @Scope TABLE (ScopeType NVARCHAR(20), ScopeKey NVARCHAR(40),
                          PRIMARY KEY (ScopeType, ScopeKey));

    DECLARE @Targets TABLE (Id NVARCHAR(40) PRIMARY KEY);
    INSERT INTO @Targets (Id)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@AppliesToIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    /* Item and category ids share one list on the screen; which is which is
       looked up, not trusted from the client. */
    IF @AppliesTo = N'selected'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM @Targets)
            THROW 63009, N'Choose at least one item or category, or switch to "All".', 1;

        IF EXISTS (SELECT 1 FROM @Targets AS t
                   WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem WHERE ItemId = t.Id)
                     AND NOT EXISTS (SELECT 1 FROM core.Category WHERE CategoryId = t.Id))
            THROW 63010, N'One of those items or categories does not exist.', 1;

        INSERT INTO @Scope (ScopeType, ScopeKey)
        SELECT CASE WHEN EXISTS (SELECT 1 FROM core.CatalogItem WHERE ItemId = t.Id)
                    THEN N'item' ELSE N'category' END, t.Id
        FROM @Targets AS t;
    END

    INSERT INTO @Scope (ScopeType, ScopeKey)
    SELECT DISTINCT N'branch', LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@BranchIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF EXISTS (SELECT 1 FROM @Scope AS s WHERE s.ScopeType = N'branch'
               AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = s.ScopeKey))
        THROW 63011, N'One of those branches does not exist.', 1;

    INSERT INTO @Scope (ScopeType, ScopeKey)
    SELECT DISTINCT N'role', LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@RoleIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF EXISTS (SELECT 1 FROM @Scope AS s WHERE s.ScopeType = N'role'
               AND NOT EXISTS (SELECT 1 FROM core.Role WHERE RoleId = s.ScopeKey))
        THROW 63012, N'One of those roles does not exist.', 1;

    SET @ActiveDays = ISNULL(@ActiveDays, N'');

    IF EXISTS (SELECT 1 FROM STRING_SPLIT(@ActiveDays, N',')
               WHERE LTRIM(RTRIM(value)) NOT IN (N'0', N'1', N'2', N'3', N'4', N'5', N'6')
                 AND @ActiveDays <> N'')
        THROW 63013, N'Days of the week are 0 (Sunday) to 6.', 1;

    /*------------------------------------------------------------- write */

    BEGIN TRAN;

        IF @DiscountId IS NULL
        BEGIN
            SET @SavedId = CONCAT(N'dsc_',
                LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

            INSERT INTO sales.Discount
                (DiscountId, NameAr, NameEn, Description, DiscountType, Value, MaxDiscountH,
                 MinSubtotalH, ApprovalAboveH, AppliesTo, IsAutomatic, AllowStacking,
                 ActiveDays, StartsOn, EndsOn, IsActive)
            VALUES
                (@SavedId, @NameAr, @NameEn, @Description, @DiscountType, @Value, @MaxDiscountH,
                 ISNULL(@MinSubtotalH, 0), @ApprovalAboveH, @AppliesTo, @IsAutomatic, @AllowStacking,
                 @ActiveDays, @StartsOn, @EndsOn, @IsActive);
        END
        ELSE
        BEGIN
            SET @SavedId = @DiscountId;

            /* UsageCount is not touched. It records how often this discount has
               been applied; an edit must not reset that history. */
            UPDATE sales.Discount
            SET NameAr = @NameAr, NameEn = @NameEn, Description = @Description,
                DiscountType = @DiscountType, Value = @Value, MaxDiscountH = @MaxDiscountH,
                MinSubtotalH = ISNULL(@MinSubtotalH, 0), ApprovalAboveH = @ApprovalAboveH,
                AppliesTo = @AppliesTo, IsAutomatic = @IsAutomatic, AllowStacking = @AllowStacking,
                ActiveDays = @ActiveDays, StartsOn = @StartsOn, EndsOn = @EndsOn,
                IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE DiscountId = @DiscountId;
        END

        /* Replaced wholesale, like every other set on a record. */
        DELETE FROM sales.DiscountScope WHERE DiscountId = @SavedId;

        INSERT INTO sales.DiscountScope (DiscountId, ScopeType, ScopeKey)
        SELECT @SavedId, ScopeType, ScopeKey FROM @Scope;

    COMMIT;
END
GO
PRINT N'Creating Procedure [sales].[usp_CommitSale]...';


GO

CREATE   PROCEDURE sales.usp_CommitSale
    @BranchId        NVARCHAR(40),
    @CustomerId      NVARCHAR(40) = NULL,
    @ServedByUserId  NVARCHAR(40) = NULL,
    @CashierName     NVARCHAR(160),
    @DiscountId      NVARCHAR(40) = NULL,
    @DiscountH       BIGINT = 0,
    @TenderedH       BIGINT = NULL,
    @IdempotencyKey  NVARCHAR(64) = NULL,
    @Lines           sales.SaleLineTable    READONLY,
    @Payments        sales.SalePaymentTable READONLY,
    @SaleId          NVARCHAR(40) OUTPUT,
    @InvoiceNumber   NVARCHAR(40) OUTPUT,
    @ApprovedByUserId NVARCHAR(40) = NULL,
    @OrderType       NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
      A replay returns the original sale.

      Checked before any validation: a retry of a sale that already succeeded
      must succeed again with the same answer, even if stock has since fallen
      below what that sale took. Re-validating would refuse a sale that has
      already happened.
    */
    IF @IdempotencyKey IS NOT NULL
    BEGIN
        SELECT @SaleId = SaleId, @InvoiceNumber = InvoiceNumber
        FROM sales.Sale
        WHERE IdempotencyKey = @IdempotencyKey;

        IF @SaleId IS NOT NULL RETURN;
    END

    /*-------------------------------------------------- validate before writing */

    IF NOT EXISTS (SELECT 1 FROM @Lines)
        THROW 52000, N'A sale needs at least one line.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE Quantity <= 0)
        THROW 52001, N'Quantities must be above zero.', 1;

    IF EXISTS (SELECT 1 FROM @Lines AS l
               WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem AS i
                                 WHERE i.ItemId = l.ItemId AND i.IsActive = 1))
        THROW 52002, N'A line refers to an item that does not exist or is inactive.', 1;

    DECLARE @VatRate DECIMAL(5,2) =
        ISNULL((SELECT VatRatePercent FROM core.BranchSettings WHERE BranchId = @BranchId), 15.00);

    DECLARE @AllowNegative BIT =
        ISNULL((SELECT AllowNegativeStock FROM core.BranchSettings WHERE BranchId = @BranchId), 0);

    IF @AllowNegative = 0 AND EXISTS (
        SELECT 1
        FROM @Lines AS l
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
        LEFT JOIN inv.StockLevel AS s ON s.ItemId = l.ItemId AND s.BranchId = @BranchId
        WHERE i.TracksStock = 1 AND ISNULL(s.Quantity, 0) < l.Quantity)
    BEGIN
        THROW 52003, N'Not enough stock for one or more items.', 1;
    END

    DECLARE @GrossH BIGINT =
        (SELECT SUM(l.UnitPriceH * l.Quantity - l.LineDiscountH) FROM @Lines AS l);

    IF @DiscountH < 0 OR @DiscountH > @GrossH
        THROW 52004, N'The discount cannot exceed the basket total.', 1;

    /*
      Approval is enforced here, not only in the browser.

      A discount with an approval threshold that is exceeded needs an approver
      who holds discounts.approve right now (an active user, permissions as
      they stand). The API decides who the approver is — the cashier, or
      another user whose password it has just checked — and passes their id.
    */
    IF @DiscountId IS NOT NULL
    BEGIN
        DECLARE @ApprovalAboveH BIGINT =
            (SELECT ApprovalAboveH FROM sales.Discount WHERE DiscountId = @DiscountId);

        IF @ApprovalAboveH > 0 AND @DiscountH > @ApprovalAboveH
        BEGIN
            IF @ApprovedByUserId IS NULL
                THROW 63050, N'This discount needs approval from someone allowed to approve discounts.', 1;

            IF NOT EXISTS (SELECT 1
                           FROM core.vw_EffectivePermission AS ep
                           JOIN core.AppUser AS u ON u.UserId = ep.UserId
                           WHERE ep.UserId = @ApprovedByUserId
                             AND ep.PermissionKey = N'discounts.approve'
                             AND u.Status = N'active')
                THROW 63051, N'The approver is not allowed to approve discounts.', 1;
        END
        ELSE
            SET @ApprovedByUserId = NULL;   -- nothing needed approving
    END
    ELSE
        SET @ApprovedByUserId = NULL;

    IF @OrderType IS NOT NULL AND @OrderType NOT IN (N'dine_in', N'takeaway', N'delivery', N'other')
        THROW 52030, N'Order type is dine_in, takeaway, delivery or other.', 1;

    DECLARE @NetOfDiscountH BIGINT = @GrossH - @DiscountH;
    DECLARE @TaxH      BIGINT = fin.fn_VatFromGross(@NetOfDiscountH, @VatRate);
    DECLARE @SubtotalH BIGINT = @NetOfDiscountH - @TaxH + @DiscountH;
    DECLARE @TotalH    BIGINT = @NetOfDiscountH;

    /*
      Cash is the only tender that can exceed what it pays for.

      The till sends the cash line as the amount applied to the sale and
      @TenderedH as the notes handed over; an older client sends the cash line
      as the notes handed over. Both are accepted: the cash received is the
      larger of the two, the cash due is whatever the other tenders leave, and
      change is the difference. The ledger takes only the cash due, so the
      entry balances whichever way the client counted.
    */
    DECLARE @NonCashH BIGINT =
        ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method <> N'cash'), 0);
    DECLARE @CashLineH BIGINT =
        ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'cash'), 0);

    IF @NonCashH > @TotalH
        THROW 52031, N'Card, bank and credit payments cannot exceed the total; only cash gives change.', 1;

    DECLARE @CashDueH      BIGINT = @TotalH - @NonCashH;
    DECLARE @CashReceivedH BIGINT =
        CASE WHEN ISNULL(@TenderedH, 0) > @CashLineH THEN @TenderedH ELSE @CashLineH END;

    IF @CashReceivedH < @CashDueH
        THROW 52005, N'Payments do not cover the total.', 1;

    DECLARE @CreditH BIGINT =
        ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'credit'), 0);

    IF @CreditH > 0
    BEGIN
        IF @CustomerId IS NULL
            THROW 52006, N'A credit sale needs a customer.', 1;

        IF EXISTS (SELECT 1 FROM core.Customer
                   WHERE CustomerId = @CustomerId
                     AND BalanceH + @CreditH > CreditLimitH)
            THROW 52007, N'This sale would take the customer over their credit limit.', 1;
    END

    /*----------------------------------------------------------------- write */

    BEGIN TRY
        BEGIN TRAN;

            DECLARE @Seq BIGINT = NEXT VALUE FOR sales.InvoiceSequence;
            SET @SaleId = CONCAT(N'sal_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
            SET @InvoiceNumber = CONCAT(N'INV-', @Seq);

            DECLARE @ChangeH BIGINT = @CashReceivedH - @CashDueH;

            INSERT INTO sales.Sale
                (SaleId, InvoiceNumber, BranchId, CustomerId, ServedByUserId, CashierName,
                 SubtotalH, DiscountH, TaxH, TotalH, TenderedH, ChangeH, DiscountId,
                 Status, SoldAtUtc, CreatedBy, IdempotencyKey, DiscountApprovedBy, OrderType)
            VALUES
                (@SaleId, @InvoiceNumber, @BranchId, @CustomerId, @ServedByUserId, @CashierName,
                 @SubtotalH, @DiscountH, @TaxH, @TotalH, @TenderedH, @ChangeH, @DiscountId,
                 N'completed', SYSUTCDATETIME(), @CashierName, @IdempotencyKey,
                 @ApprovedByUserId, @OrderType);

            INSERT INTO sales.SaleLine
                (SaleId, ItemId, NameAr, NameEn, Kind, PrintGroupId,
                 Quantity, UnitPriceH, UnitCostH, LineDiscountH, Note)
            SELECT
                @SaleId, l.ItemId, i.NameAr, i.NameEn, i.Kind, i.PrintGroupId,
                l.Quantity, l.UnitPriceH, i.CostH, l.LineDiscountH, l.Note
            FROM @Lines AS l
            JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId;

            /* Cash is stored as received, so cash less ChangeH is what the
               drawer kept — the rule the summary's payment mix applies. */
            INSERT INTO sales.SalePayment (SaleId, Method, AmountH, Reference)
            SELECT @SaleId, Method, AmountH, Reference
            FROM @Payments WHERE AmountH > 0 AND Method <> N'cash';

            IF @CashReceivedH > 0
                INSERT INTO sales.SalePayment (SaleId, Method, AmountH, Reference)
                VALUES (@SaleId, N'cash', @CashReceivedH,
                        (SELECT TOP (1) Reference FROM @Payments
                         WHERE Method = N'cash' AND Reference IS NOT NULL));

            UPDATE s
            SET Quantity = s.Quantity - agg.Qty,
                UpdatedAtUtc = SYSUTCDATETIME()
            FROM inv.StockLevel AS s
            JOIN (SELECT l.ItemId, SUM(l.Quantity) AS Qty
                  FROM @Lines AS l
                  JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
                  WHERE i.TracksStock = 1
                  GROUP BY l.ItemId) AS agg ON agg.ItemId = s.ItemId
            WHERE s.BranchId = @BranchId;

            INSERT INTO inv.StockMovement
                (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
                 Reference, ReasonEn, ReasonAr, Actor)
            SELECT
                l.ItemId, @BranchId, N'sale', -SUM(l.Quantity),
                ISNULL(s.Quantity, 0), i.CostH,
                @InvoiceNumber, N'Sale', N'بيع', @CashierName
            FROM @Lines AS l
            JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
            LEFT JOIN inv.StockLevel AS s ON s.ItemId = l.ItemId AND s.BranchId = @BranchId
            WHERE i.TracksStock = 1
            GROUP BY l.ItemId, i.CostH, s.Quantity;

            IF @CreditH > 0
            BEGIN
                UPDATE core.Customer
                SET BalanceH = BalanceH + @CreditH,
                    UpdatedAtUtc = SYSUTCDATETIME()
                WHERE CustomerId = @CustomerId;
            END

            IF @DiscountId IS NOT NULL
            BEGIN
                UPDATE sales.Discount SET UsageCount = UsageCount + 1 WHERE DiscountId = @DiscountId;
            END

            DECLARE @CardH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'card'), 0);
            DECLARE @BankH BIGINT = ISNULL((SELECT SUM(AmountH) FROM @Payments WHERE Method = N'bank'), 0);
            DECLARE @CogsH BIGINT = ISNULL((
                SELECT SUM(i.CostH * l.Quantity)
                FROM @Lines AS l JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
                WHERE i.TracksStock = 1), 0);

            DECLARE @CashNetH BIGINT = @CashDueH;

            DECLARE @Entry fin.JournalLineTable;

            INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                (N'1000', @CashNetH, 0, N'Cash'),
                (N'1150', @CardH,    0, N'Card clearing'),
                (N'1100', @BankH,    0, N'Bank'),
                (N'1400', @CreditH,  0, N'Customer credit'),
                (N'4100', 0, @SubtotalH - @DiscountH, N'Sales'),
                (N'2100', 0, @TaxH,   N'Output VAT'),
                (N'5100', @CogsH, 0,  N'Cost of goods sold'),
                (N'1200', 0, @CogsH,  N'Inventory');

            DECLARE @EntryId NVARCHAR(40);

            EXEC fin.usp_PostJournalEntry
                @Kind            = N'sale',
                @DescriptionEn   = @InvoiceNumber,
                @DescriptionAr   = @InvoiceNumber,
                @SourceReference = @InvoiceNumber,
                @BranchId        = @BranchId,
                @Actor           = @CashierName,
                @Lines           = @Entry,
                @EntryId         = @EntryId OUTPUT;

            EXEC fin.usp_RecordSaleCommission @SaleId = @SaleId;

            IF EXISTS (SELECT 1 FROM @Lines AS l
                       JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
                       WHERE i.RequiresPreparation = 1)
            BEGIN
                DECLARE @PrepId NVARCHAR(40) =
                    CONCAT(N'prp_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

                INSERT INTO sales.PreparationOrder
                    (PreparationId, OrderNumber, SaleId, BranchId, CustomerName, TotalH, Status, OrderType)
                SELECT
                    @PrepId, @InvoiceNumber, @SaleId, @BranchId,
                    (SELECT NameEn FROM core.Customer WHERE CustomerId = @CustomerId),
                    @TotalH, N'open', @OrderType;

                INSERT INTO sales.PreparationItem
                    (PreparationId, ItemId, NameAr, NameEn, Quantity, Note)
                SELECT @PrepId, l.ItemId, i.NameAr, i.NameEn, l.Quantity, l.Note
                FROM @Lines AS l
                JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
                WHERE i.RequiresPreparation = 1;
            END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;

        /*
          Two retries racing each other.

          Both passed the replay check before either committed, so the second
          hits the unique index. That is the index doing its job, not a fault —
          return the sale the winner created rather than an error, which is the
          same answer the replay check would have given a moment later.
        */
        IF ERROR_NUMBER() IN (2601, 2627) AND @IdempotencyKey IS NOT NULL
        BEGIN
            SELECT @SaleId = SaleId, @InvoiceNumber = InvoiceNumber
            FROM sales.Sale
            WHERE IdempotencyKey = @IdempotencyKey;

            IF @SaleId IS NOT NULL RETURN;
        END;  -- THROW requires the preceding statement to end with a semicolon

        THROW;
    END CATCH
END
GO
PRINT N'Creating Procedure [core].[usp_CopyBranchSettings]...';


GO

/*
  Copy one branch's configuration onto another.

  Through the save procedure rather than an INSERT ... SELECT, so a copy is
  held to exactly the rules an edit is — a source configured before a rule
  existed cannot smuggle a now-invalid value across.
*/
CREATE   PROCEDURE core.usp_CopyBranchSettings
    @SourceBranchId NVARCHAR(40),
    @TargetBranchId NVARCHAR(40),
    @Actor          NVARCHAR(160)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @SourceBranchId)
       OR NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @TargetBranchId)
        THROW 62050, N'No such branch.', 1;

    IF @SourceBranchId = @TargetBranchId
        THROW 62056, N'Choose a different branch to copy from.', 1;

    DECLARE @Mode NVARCHAR(20), @ServedBy NVARCHAR(20), @Negative BIT, @Bill NVARCHAR(40),
            @PrintCustomer BIT, @PrintGroups BIT, @Vat DECIMAL(5,2), @IncludesVat BIT;

    SELECT @Mode = DefaultCustomerMode, @ServedBy = ServedByRequirement,
           @Negative = AllowNegativeStock, @Bill = DefaultBillId,
           @PrintCustomer = AutoPrintCustomer, @PrintGroups = AutoPrintGroups,
           @Vat = VatRatePercent, @IncludesVat = PricesIncludeVat
    FROM core.BranchSettings WHERE BranchId = @SourceBranchId;

    IF @Mode IS NULL
        THROW 62055, N'That branch has no settings to copy yet.', 1;

    EXEC core.usp_SaveBranchSettings
         @BranchId = @TargetBranchId, @DefaultCustomerMode = @Mode,
         @ServedByRequirement = @ServedBy, @AllowNegativeStock = @Negative,
         @DefaultBillId = @Bill, @AutoPrintCustomer = @PrintCustomer,
         @AutoPrintGroups = @PrintGroups, @VatRatePercent = @Vat,
         @PricesIncludeVat = @IncludesVat, @Actor = @Actor;
END
GO
PRINT N'Creating Procedure [fin].[usp_CloseBalancePeriod]...';


GO

CREATE PROCEDURE fin.usp_CloseBalancePeriod
    @PeriodId          NVARCHAR(40),
    @ClosedOn          DATE,
    @ClosingCashH      BIGINT,
    @ClosingCardH      BIGINT,
    @ClosingCreditH    BIGINT,
    @ClosingBankH      BIGINT,
    @ClosingInventoryH BIGINT,
    @ClosingPayablesH  BIGINT,
    @ClosedBy          NVARCHAR(120),
    @Note              NVARCHAR(400) = NULL,
    @VarianceH         BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BranchId NVARCHAR(40), @From DATE;

    SELECT @BranchId = BranchId, @From = OpenedOn
    FROM fin.BalancePeriod WHERE PeriodId = @PeriodId AND Status = N'open';

    IF @From IS NULL THROW 56003, N'That period is not open.', 1;
    IF @ClosedOn < @From THROW 56004, N'The closing date is before the period opened.', 1;

    DECLARE @ExpectedH BIGINT = ISNULL((
        SELECT SUM(CASE WHEN l.AccountCode = N'2000' THEN -(l.CreditH - l.DebitH)
                        ELSE l.DebitH - l.CreditH END)
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode IN (N'1000', N'1150', N'1400', N'1100', N'1200', N'2000')
          AND CAST(e.PostedAtUtc AS DATE) >= @From
          AND CAST(e.PostedAtUtc AS DATE) <= @ClosedOn
          AND (e.BranchId = @BranchId OR e.BranchId IS NULL)), 0);

    DECLARE @CountedH BIGINT =
        @ClosingCashH + @ClosingCardH + @ClosingCreditH
        + @ClosingBankH + @ClosingInventoryH - @ClosingPayablesH;

    SET @VarianceH = @CountedH - @ExpectedH;

    BEGIN TRAN;

        /* Any gap posts as its own entry rather than being absorbed. */
        IF @VarianceH <> 0
        BEGIN
            DECLARE @Entry fin.JournalLineTable;

            IF @VarianceH > 0
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'1000', @VarianceH, 0, N'Closing overage'),
                    (N'6000', 0, @VarianceH, N'Closing variance');
            ELSE
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'6000', ABS(@VarianceH), 0, N'Closing variance'),
                    (N'1000', 0, ABS(@VarianceH), N'Closing shortage');

            DECLARE @EntryId NVARCHAR(40);
            EXEC fin.usp_PostJournalEntry
                @Kind = N'manual',
                @DescriptionEn = N'Period closing variance',
                @DescriptionAr = N'فرق إقفال الفترة',
                @SourceReference = @PeriodId, @BranchId = @BranchId,
                @Actor = @ClosedBy, @PostedAtUtc = @ClosedOn,
                @Lines = @Entry, @EntryId = @EntryId OUTPUT;
        END

        UPDATE fin.BalancePeriod
        SET Status            = N'closed',
            ClosedOn          = @ClosedOn,
            ClosingCashH      = @ClosingCashH,
            ClosingCardH      = @ClosingCardH,
            ClosingCreditH    = @ClosingCreditH,
            ClosingBankH      = @ClosingBankH,
            ClosingInventoryH = @ClosingInventoryH,
            ClosingPayablesH  = @ClosingPayablesH,
            ClosedBy          = @ClosedBy,
            Note              = ISNULL(@Note, Note),
            UpdatedAtUtc      = SYSUTCDATETIME()
        WHERE PeriodId = @PeriodId;

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_RecordSettlement]...';


GO

/*
  Record what the bank actually deposited.

  The gap between takings and deposit is the network's fee, and it is a real
  cost. Recognising it here is why the clearing account returns to zero instead
  of drifting down by the fee every month.
*/
CREATE PROCEDURE fin.usp_RecordSettlement
    @BranchId      NVARCHAR(40) = NULL,
    @CardSalesH    BIGINT,
    @DepositH      BIGINT,
    @SettledOn     DATE,
    @Note          NVARCHAR(400) = NULL,
    @Actor         NVARCHAR(120),
    @SettlementId  NVARCHAR(40) OUTPUT,
    @Reference     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @CardSalesH <= 0 THROW 55010, N'Enter the card takings this batch covers.', 1;
    IF @DepositH < 0     THROW 55011, N'A deposit cannot be negative.', 1;
    IF @DepositH > @CardSalesH
        THROW 55012, N'The deposit is more than the takings. Check the figures.', 1;

    DECLARE @FeeH BIGINT = @CardSalesH - @DepositH;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR fin.SettlementSequence;
        SET @SettlementId = CONCAT(N'set_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @Reference    = CONCAT(N'SET-', @Seq);

        INSERT INTO fin.CardSettlement
            (SettlementId, Reference, BranchId, CardSalesH, DepositH, FeeH,
             SettledOn, Status, Note, CreatedBy)
        VALUES
            (@SettlementId, @Reference, @BranchId, @CardSalesH, @DepositH, @FeeH,
             @SettledOn, N'reconciled', @Note, @Actor);

        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1100', @DepositH, 0, N'Bank deposit'),
            (N'6100', @FeeH, 0, N'Card fees'),
            (N'1150', 0, @CardSalesH, N'Card clearing');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'card_settlement',
            @DescriptionEn = N'Card settlement', @DescriptionAr = N'تسوية الشبكة',
            @SourceReference = @Reference, @BranchId = @BranchId,
            @Actor = @Actor, @PostedAtUtc = @SettledOn,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_ReverseJournalEntry]...';


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
PRINT N'Creating Procedure [fin].[usp_PayPayroll]...';


GO

CREATE PROCEDURE fin.usp_PayPayroll
    @RunId  NVARCHAR(40),
    @PaidOn DATE,
    @Actor  NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status NVARCHAR(20), @PeriodMonth CHAR(7), @BranchId NVARCHAR(40), @Reference NVARCHAR(40);

    SELECT @Status = Status, @PeriodMonth = PeriodMonth, @BranchId = BranchId, @Reference = Reference
    FROM fin.PayrollRun WHERE RunId = @RunId;

    IF @Status IS NULL THROW 56011, N'Payroll run not found.', 1;
    IF @Status = N'paid' THROW 56012, N'This payroll has already been paid.', 1;

    DECLARE @SalariesH   BIGINT = ISNULL((SELECT SUM(BaseSalaryH + AllowancesH) FROM fin.PayrollLine WHERE RunId = @RunId), 0);
    DECLARE @CommissionH BIGINT = ISNULL((SELECT SUM(CommissionH) FROM fin.PayrollLine WHERE RunId = @RunId), 0);
    DECLARE @DeductionsH BIGINT = ISNULL((SELECT SUM(DeductionsH) FROM fin.PayrollLine WHERE RunId = @RunId), 0);
    DECLARE @NetH        BIGINT = ISNULL((SELECT SUM(NetPayH) FROM fin.PayrollLine WHERE RunId = @RunId), 0);

    IF @NetH <= 0 THROW 56013, N'There is nothing to pay for this period.', 1;

    BEGIN TRAN;

        /* Deductions credit the expense back rather than being netted off the
           salary line, so the expense reflects what was earned and the cash
           reflects what was actually paid. */
        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'6200', @SalariesH, 0, N'Salaries'),
            (N'6300', @CommissionH, 0, N'Commission'),
            (N'6200', 0, @DeductionsH, N'Deductions'),
            (N'1100', 0, @NetH, N'Paid from bank');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'payroll',
            @DescriptionEn = @Reference, @DescriptionAr = @Reference,
            @SourceReference = @Reference, @BranchId = @BranchId,
            @Actor = @Actor, @PostedAtUtc = @PaidOn,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

        /* Claim the commission this run settles, so it stops showing as owed. */
        UPDATE fin.CommissionEntry
        SET PayrollRunId = @RunId
        WHERE PayrollRunId IS NULL
          AND CONVERT(CHAR(7), EarnedAtUtc, 126) = @PeriodMonth;

        UPDATE fin.PayrollRun
        SET Status = N'paid', PaidOn = @PaidOn, TotalH = @NetH,
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE RunId = @RunId;

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_CloseDrawer]...';


GO

/*
  Close the drawer.

  A variance posts as its own ledger entry rather than being absorbed. An
  unexplained forty riyals is a fact about the business, and quietly swallowing
  it is how a drawer problem survives for months.
*/
CREATE PROCEDURE fin.usp_CloseDrawer
    @SessionId    NVARCHAR(40),
    @CountedCashH BIGINT,
    @ClosedBy     NVARCHAR(120),
    @Note         NVARCHAR(400) = NULL,
    @VarianceH    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @CountedCashH < 0
        THROW 55003, N'A count cannot be negative.', 1;

    DECLARE @BranchId NVARCHAR(40), @From DATETIME2(3), @OpeningH BIGINT;

    SELECT @BranchId = BranchId, @From = OpenedAtUtc, @OpeningH = OpeningCashH
    FROM fin.DrawerSession
    WHERE SessionId = @SessionId AND ClosedAtUtc IS NULL;

    IF @From IS NULL
        THROW 55004, N'That drawer session is not open.', 1;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    DECLARE @Movement BIGINT = ISNULL((
        SELECT SUM(l.DebitH - l.CreditH)
        FROM fin.JournalEntry AS e
        JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
        WHERE l.AccountCode = N'1000'
          AND e.PostedAtUtc >= @From AND e.PostedAtUtc <= @Now
          AND (e.BranchId = @BranchId OR e.BranchId IS NULL)), 0);

    DECLARE @ExpectedH BIGINT = @OpeningH + @Movement;
    SET @VarianceH = @CountedCashH - @ExpectedH;

    BEGIN TRAN;

        IF @VarianceH <> 0
        BEGIN
            DECLARE @Entry fin.JournalLineTable;

            IF @VarianceH > 0
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'1000', @VarianceH, 0, N'Overage'),
                    (N'6000', 0, @VarianceH, N'Drawer variance');
            ELSE
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'6000', ABS(@VarianceH), 0, N'Drawer variance'),
                    (N'1000', 0, ABS(@VarianceH), N'Shortage');

            DECLARE @EntryId NVARCHAR(40);
            EXEC fin.usp_PostJournalEntry
                @Kind = N'manual',
                @DescriptionEn = N'Cash drawer variance',
                @DescriptionAr = N'فرق درج النقد',
                @SourceReference = @SessionId, @BranchId = @BranchId,
                @Actor = @ClosedBy, @Lines = @Entry, @EntryId = @EntryId OUTPUT;
        END

        UPDATE fin.DrawerSession
        SET ClosedAtUtc   = @Now,
            CountedCashH  = @CountedCashH,
            ExpectedCashH = @ExpectedH,
            VarianceH     = @VarianceH,
            ClosedBy      = @ClosedBy,
            Note          = @Note
        WHERE SessionId = @SessionId;

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_RecordCustomerCollection]...';


GO

/*------------------------------------------------------------- collections */

CREATE PROCEDURE fin.usp_RecordCustomerCollection
    @CustomerId NVARCHAR(40),
    @AmountH    BIGINT,
    @Method     NVARCHAR(20),
    @Reference  NVARCHAR(80) = NULL,
    @BranchId   NVARCHAR(40) = NULL,
    @Actor      NVARCHAR(120),
    @EntryId    NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AmountH <= 0
        THROW 52020, N'A collection must be above zero.', 1;

    DECLARE @Balance BIGINT = (SELECT BalanceH FROM core.Customer WHERE CustomerId = @CustomerId);

    IF @Balance IS NULL
        THROW 52021, N'Customer not found.', 1;

    /* Collecting more than is owed would leave a negative balance, which reads
       as the business owing the customer — a different thing entirely. */
    IF @AmountH > @Balance
        THROW 52022, N'That is more than this customer owes.', 1;

    BEGIN TRAN;

        UPDATE core.Customer
        SET BalanceH = BalanceH - @AmountH, UpdatedAtUtc = SYSUTCDATETIME()
        WHERE CustomerId = @CustomerId;

        DECLARE @Lines fin.JournalLineTable;

        INSERT INTO @Lines (AccountCode, DebitH, CreditH, Memo) VALUES
            (CASE WHEN @Method = N'cash' THEN N'1000' ELSE N'1100' END, @AmountH, 0, @Method),
            (N'1400', 0, @AmountH, N'Customer collection');

        EXEC fin.usp_PostJournalEntry
            @Kind            = N'customer_collection',
            @DescriptionEn   = N'Customer collection',
            @DescriptionAr   = N'تحصيل من عميل',
            @SourceReference = @CustomerId,
            @BranchId        = @BranchId,
            @Actor           = @Actor,
            @Lines           = @Lines,
            @EntryId         = @EntryId OUTPUT;

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_PostOpeningBalances]...';


GO

CREATE   PROCEDURE fin.usp_PostOpeningBalances
    @BranchId     NVARCHAR(40) = NULL,
    @AsOf         DATE,
    @CashH        BIGINT = 0,
    @BankH        BIGINT = 0,
    @InventoryH   BIGINT = 0,
    @ReceivablesH BIGINT = 0,
    @PayablesH    BIGINT = 0,
    @VatH         BIGINT = 0,
    @Note         NVARCHAR(400) = NULL,
    @Actor        NVARCHAR(120),
    @OpeningId    NVARCHAR(40) OUTPUT,
    @EntryId      NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AsOf IS NULL
        THROW 70001, N'Choose the date the balances are as of.', 1;

    IF @CashH < 0 OR @BankH < 0 OR @InventoryH < 0 OR @ReceivablesH < 0 OR @PayablesH < 0
        THROW 70002, N'Opening balances cannot be negative.', 1;

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId)
        THROW 70003, N'Unknown branch.', 1;

    DECLARE @AssetsH      BIGINT = ISNULL(@CashH, 0) + ISNULL(@BankH, 0) + ISNULL(@InventoryH, 0) + ISNULL(@ReceivablesH, 0)
                                   + CASE WHEN @VatH < 0 THEN -@VatH ELSE 0 END;
    DECLARE @LiabilitiesH BIGINT = ISNULL(@PayablesH, 0) + CASE WHEN @VatH > 0 THEN @VatH ELSE 0 END;
    DECLARE @EquityH      BIGINT = @AssetsH - @LiabilitiesH;

    IF @AssetsH = 0 AND @LiabilitiesH = 0
        THROW 70004, N'Enter at least one opening figure.', 1;

    BEGIN TRAN;

        /* One standing posting per scope. The range lock stops two at once. */
        IF EXISTS (SELECT 1
                   FROM fin.OpeningBalance AS o WITH (UPDLOCK, HOLDLOCK)
                   JOIN fin.JournalEntry AS e ON e.EntryId = o.EntryId
                   WHERE ISNULL(o.BranchId, N'') = ISNULL(@BranchId, N'')
                     AND e.ReversedByEntryId IS NULL)
            THROW 70000, N'Opening balances have already been posted. Reverse the entry in the ledger to correct them.', 1;

        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1000', @CashH, 0, N'Opening cash'),
            (N'1100', @BankH, 0, N'Opening bank'),
            (N'1200', @InventoryH, 0, N'Opening inventory'),
            (N'1400', @ReceivablesH, 0, N'Opening receivables'),
            (N'2000', 0, @PayablesH, N'Opening payables'),
            (N'2100', 0, CASE WHEN @VatH > 0 THEN @VatH ELSE 0 END, N'Opening VAT owed'),
            (N'1300', CASE WHEN @VatH < 0 THEN -@VatH ELSE 0 END, 0, N'Opening VAT reclaimable'),
            (N'3900', CASE WHEN @EquityH < 0 THEN -@EquityH ELSE 0 END,
                      CASE WHEN @EquityH > 0 THEN @EquityH ELSE 0 END, N'Opening equity');

        EXEC fin.usp_PostJournalEntry
            @Kind            = N'opening_balance',
            @DescriptionEn   = N'Opening balances',
            @DescriptionAr   = N'الأرصدة الافتتاحية',
            @SourceReference = N'OPENING',
            @BranchId        = @BranchId,
            @Actor           = @Actor,
            @PostedAtUtc     = @AsOf,
            @Lines           = @Entry,
            @EntryId         = @EntryId OUTPUT;

        SET @OpeningId = CONCAT(N'opn_', LEFT(LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')), 20));

        INSERT INTO fin.OpeningBalance
            (OpeningId, BranchId, AsOf, CashH, BankH, InventoryH, ReceivablesH, PayablesH,
             VatH, EquityH, EntryId, Note, PostedBy)
        VALUES
            (@OpeningId, @BranchId, @AsOf, @CashH, @BankH, @InventoryH, @ReceivablesH, @PayablesH,
             @VatH, @EquityH, @EntryId, NULLIF(LTRIM(RTRIM(@Note)), N''), @Actor);

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_RecordExpense]...';


GO

CREATE PROCEDURE fin.usp_RecordExpense
    @CategoryId    NVARCHAR(40),
    @BranchId      NVARCHAR(40) = NULL,
    @DescriptionEn NVARCHAR(400),
    @DescriptionAr NVARCHAR(400) = NULL,
    @AmountH       BIGINT,
    @VatH          BIGINT = 0,
    @PaymentMethod NVARCHAR(20),
    @PaidOn        DATE,
    @Recognition   NVARCHAR(20) = N'one_time',
    @PeriodStart   DATE = NULL,
    @PeriodEnd     DATE = NULL,
    @ExternalRef   NVARCHAR(80) = NULL,
    @Attachment    NVARCHAR(300) = NULL,
    @Actor         NVARCHAR(120),
    @ExpenseId     NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AmountH <= 0 THROW 54020, N'An expense must be above zero.', 1;
    IF @VatH < 0 OR @VatH > @AmountH THROW 54021, N'VAT cannot exceed the amount.', 1;

    SET @PeriodStart = ISNULL(@PeriodStart, @PaidOn);
    SET @PeriodEnd   = ISNULL(@PeriodEnd, @PaidOn);

    IF @PeriodEnd < @PeriodStart THROW 54022, N'The period must end after it starts.', 1;

    DECLARE @AccountCode NVARCHAR(10) =
        (SELECT AccountCode FROM fin.ExpenseCategory WHERE CategoryId = @CategoryId);

    IF @AccountCode IS NULL THROW 54023, N'Unknown expense category.', 1;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR fin.ExpenseSequence;
        SET @ExpenseId = CONCAT(N'exp_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO fin.Expense
            (ExpenseId, Reference, CategoryId, BranchId, DescriptionAr, DescriptionEn,
             AmountH, VatH, PaymentMethod, PaidOn, Recognition, PeriodStart, PeriodEnd,
             ExternalRef, AttachmentName, CreatedBy)
        VALUES
            (@ExpenseId, CONCAT(N'EXP-', @Seq), @CategoryId, @BranchId,
             @DescriptionAr, @DescriptionEn, @AmountH, @VatH, @PaymentMethod,
             @PaidOn, @Recognition, @PeriodStart, @PeriodEnd,
             @ExternalRef, @Attachment, @Actor);

        DECLARE @NetH BIGINT = @AmountH - @VatH;
        DECLARE @Spreads BIT = CASE WHEN @Recognition = N'one_time' THEN 0 ELSE 1 END;
        DECLARE @PaymentAccount NVARCHAR(10) =
            CASE @PaymentMethod WHEN N'cash' THEN N'1000'
                                WHEN N'credit' THEN N'2000'
                                ELSE N'1100' END;

        /* The payment leaves on the date it left, whatever period the cost
           belongs to. Anything spread over time parks in prepaid first. */
        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (CASE WHEN @Spreads = 1 THEN N'1500' ELSE @AccountCode END, @NetH, 0, @DescriptionEn),
            (N'1300', @VatH, 0, N'Input VAT'),
            (@PaymentAccount, 0, @AmountH, @PaymentMethod);

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'expense', @DescriptionEn = @DescriptionEn, @DescriptionAr = @DescriptionAr,
            @SourceReference = @ExpenseId, @BranchId = @BranchId, @Actor = @Actor,
            @PostedAtUtc = @PaidOn, @Lines = @Entry, @EntryId = @EntryId OUTPUT;

        EXEC fin.usp_BuildExpenseRecognition @ExpenseId = @ExpenseId;

        /* Release prepaid into the expense account, month by month. */
        IF @Spreads = 1
        BEGIN
            DECLARE @Month CHAR(7), @Slice BIGINT;

            DECLARE slices CURSOR LOCAL FAST_FORWARD FOR
                SELECT PeriodMonth, AmountH FROM fin.ExpenseRecognition
                WHERE ExpenseId = @ExpenseId;

            OPEN slices;
            FETCH NEXT FROM slices INTO @Month, @Slice;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @Release fin.JournalLineTable;
                DELETE FROM @Release;

                INSERT INTO @Release (AccountCode, DebitH, CreditH, Memo) VALUES
                    (@AccountCode, @Slice, 0, @Month),
                    (N'1500', 0, @Slice, N'Prepaid release');

                DECLARE @RelId NVARCHAR(40);
                EXEC fin.usp_PostJournalEntry
                    @Kind = N'expense_recognition',
                    @DescriptionEn = @DescriptionEn, @DescriptionAr = @DescriptionAr,
                    @SourceReference = @ExpenseId, @BranchId = @BranchId, @Actor = @Actor,
                    @PostedAtUtc = @Month, @Lines = @Release, @EntryId = @RelId OUTPUT;

                FETCH NEXT FROM slices INTO @Month, @Slice;
            END

            CLOSE slices;
            DEALLOCATE slices;
        END

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_OpenBalancePeriod]...';


GO

/*------------------------------------------------------------ balance periods */

/*
  Open a period and post the starting position.

  Modelled as a period rather than a single opening snapshot because the
  question an owner asks is not "what did I start with" but "what did I start
  with, what did I end with, and where did the difference go".
*/
CREATE PROCEDURE fin.usp_OpenBalancePeriod
    @BranchId          NVARCHAR(40),
    @Label             NVARCHAR(160),
    @OpenedOn          DATE,
    @OpeningCashH      BIGINT = 0,
    @OpeningCardH      BIGINT = 0,
    @OpeningCreditH    BIGINT = 0,
    @OpeningBankH      BIGINT = 0,
    @OpeningInventoryH BIGINT = 0,
    @OpeningPayablesH  BIGINT = 0,
    @OpenedBy          NVARCHAR(120),
    @Note              NVARCHAR(400) = NULL,
    @PeriodId          NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* One open period per branch. Two overlapping periods would each claim the
       same movements and neither closing figure would mean anything. */
    IF EXISTS (SELECT 1 FROM fin.BalancePeriod
               WHERE BranchId = @BranchId AND Status = N'open')
        THROW 56000, N'This branch already has an open period.', 1;

    IF @OpeningCashH < 0 OR @OpeningCardH < 0 OR @OpeningCreditH < 0
       OR @OpeningBankH < 0 OR @OpeningInventoryH < 0 OR @OpeningPayablesH < 0
        THROW 56001, N'Opening balances cannot be negative.', 1;

    BEGIN TRAN;

        SET @PeriodId = CONCAT(N'bpd_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO fin.BalancePeriod
            (PeriodId, BranchId, Label, OpenedOn,
             OpeningCashH, OpeningCardH, OpeningCreditH,
             OpeningBankH, OpeningInventoryH, OpeningPayablesH,
             Status, OpenedBy, Note)
        VALUES
            (@PeriodId, @BranchId, @Label, @OpenedOn,
             @OpeningCashH, @OpeningCardH, @OpeningCreditH,
             @OpeningBankH, @OpeningInventoryH, @OpeningPayablesH,
             N'open', @OpenedBy, @Note);

        /* Net worth of the position: what is held, less what is owed. Whatever
           does not net out goes to suspense so the entry balances without
           asking the owner to state their capital. */
        DECLARE @EquityH BIGINT =
            @OpeningCashH + @OpeningCardH + @OpeningCreditH
            + @OpeningBankH + @OpeningInventoryH - @OpeningPayablesH;

        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1000', @OpeningCashH, 0, N'Opening cash'),
            (N'1150', @OpeningCardH, 0, N'Opening card clearing'),
            (N'1400', @OpeningCreditH, 0, N'Opening receivables'),
            (N'1100', @OpeningBankH, 0, N'Opening bank'),
            (N'1200', @OpeningInventoryH, 0, N'Opening inventory'),
            (N'2000', 0, @OpeningPayablesH, N'Opening payables');

        IF @EquityH >= 0
            INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo)
            VALUES (N'3900', 0, @EquityH, N'Opening equity');
        ELSE
            INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo)
            VALUES (N'3900', ABS(@EquityH), 0, N'Opening equity');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'opening_balance',
            @DescriptionEn = @Label, @DescriptionAr = @Label,
            @SourceReference = @PeriodId, @BranchId = @BranchId,
            @Actor = @OpenedBy, @PostedAtUtc = @OpenedOn,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

    COMMIT;
END
GO
PRINT N'Creating Procedure [sales].[usp_VoidSale]...';


GO

/*--------------------------------------------------- void refuses a returned sale */

CREATE   PROCEDURE sales.usp_VoidSale
    @SaleId NVARCHAR(40),
    @Reason NVARCHAR(400),
    @Actor  NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM sales.Sale WHERE SaleId = @SaleId)
        THROW 52010, N'Sale not found.', 1;

    IF EXISTS (SELECT 1 FROM sales.Sale WHERE SaleId = @SaleId AND Status = N'voided')
        THROW 52011, N'This sale is already voided.', 1;

    IF LTRIM(RTRIM(ISNULL(@Reason, N''))) = N''
        THROW 52012, N'A void needs a reason on the record.', 1;

    /* Returned units were already restocked and refunded. Voiding would do
       both again. */
    IF EXISTS (SELECT 1 FROM sales.SaleReturn WHERE SaleId = @SaleId)
        THROW 67012, N'This sale has returns against it and cannot be voided.', 1;

    DECLARE @BranchId NVARCHAR(40), @InvoiceNumber NVARCHAR(40), @CustomerId NVARCHAR(40);
    SELECT @BranchId = BranchId, @InvoiceNumber = InvoiceNumber, @CustomerId = CustomerId
    FROM sales.Sale WHERE SaleId = @SaleId;

    BEGIN TRAN;

        /* Stock comes back. */
        UPDATE s
        SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = SYSUTCDATETIME()
        FROM inv.StockLevel AS s
        JOIN (SELECT sl.ItemId, SUM(sl.Quantity) AS Qty
              FROM sales.SaleLine AS sl
              JOIN core.CatalogItem AS i ON i.ItemId = sl.ItemId
              WHERE sl.SaleId = @SaleId AND i.TracksStock = 1
              GROUP BY sl.ItemId) AS agg ON agg.ItemId = s.ItemId
        WHERE s.BranchId = @BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, Actor)
        SELECT
            sl.ItemId, @BranchId, N'return', SUM(sl.Quantity),
            ISNULL(st.Quantity, 0), sl.UnitCostH,
            @InvoiceNumber, @Reason, @Reason, @Actor
        FROM sales.SaleLine AS sl
        JOIN core.CatalogItem AS i ON i.ItemId = sl.ItemId
        LEFT JOIN inv.StockLevel AS st ON st.ItemId = sl.ItemId AND st.BranchId = @BranchId
        WHERE sl.SaleId = @SaleId AND i.TracksStock = 1
        GROUP BY sl.ItemId, sl.UnitCostH, st.Quantity;

        /* Any credit taken is released. */
        DECLARE @CreditH BIGINT = ISNULL((
            SELECT SUM(AmountH) FROM sales.SalePayment
            WHERE SaleId = @SaleId AND Method = N'credit'), 0);

        IF @CreditH > 0 AND @CustomerId IS NOT NULL
        BEGIN
            UPDATE core.Customer
            SET BalanceH = BalanceH - @CreditH, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE CustomerId = @CustomerId;
        END

        /* Commission earned on a voided sale was never earned. */
        DELETE FROM fin.CommissionEntry
        WHERE SaleId = @SaleId AND PayrollRunId IS NULL;

        /* Reverse the ledger entry rather than deleting it. */
        DECLARE @OriginalEntryId NVARCHAR(40) = (
            SELECT TOP (1) EntryId FROM fin.JournalEntry
            WHERE SourceReference = @InvoiceNumber AND Kind = N'sale'
              AND ReversedByEntryId IS NULL
            ORDER BY PostedAtUtc DESC);

        IF @OriginalEntryId IS NOT NULL
        BEGIN
            DECLARE @ReversalId NVARCHAR(40);
            EXEC fin.usp_ReverseJournalEntry
                @EntryId = @OriginalEntryId, @Reason = @Reason,
                @Actor = @Actor, @NewEntryId = @ReversalId OUTPUT;
        END

        UPDATE sales.Sale
        SET Status = N'voided', UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE SaleId = @SaleId;

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_ReverseExpense]...';


GO

/* Reverse an expense. The original stays; the opposite is posted. */
CREATE PROCEDURE fin.usp_ReverseExpense
    @ExpenseId NVARCHAR(40),
    @Reason    NVARCHAR(400),
    @Actor     NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM fin.Expense WHERE ExpenseId = @ExpenseId)
        THROW 56030, N'Expense not found.', 1;

    IF EXISTS (SELECT 1 FROM fin.Expense WHERE ExpenseId = @ExpenseId AND Status = N'reversed')
        THROW 56031, N'This expense has already been reversed.', 1;

    IF LTRIM(RTRIM(ISNULL(@Reason, N''))) = N''
        THROW 56032, N'A reversal needs a reason on the record.', 1;

    BEGIN TRAN;

        DECLARE @EntryId NVARCHAR(40), @NewId NVARCHAR(40);

        DECLARE entries CURSOR LOCAL FAST_FORWARD FOR
            SELECT EntryId FROM fin.JournalEntry
            WHERE SourceReference = @ExpenseId
              AND ReversesEntryId IS NULL
              AND ReversedByEntryId IS NULL;

        OPEN entries;
        FETCH NEXT FROM entries INTO @EntryId;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC fin.usp_ReverseJournalEntry
                @EntryId = @EntryId, @Reason = @Reason,
                @Actor = @Actor, @NewEntryId = @NewId OUTPUT;

            FETCH NEXT FROM entries INTO @EntryId;
        END

        CLOSE entries;
        DEALLOCATE entries;

        UPDATE fin.Expense
        SET Status = N'reversed', UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
        WHERE ExpenseId = @ExpenseId;

    COMMIT;
END
GO
PRINT N'Creating Procedure [fin].[usp_RecordRecurringInstalment]...';


GO

/*---------------------------------------------------------- recurring payments */

/*
  Record an instalment.

  Creates a real expense, which posts, then rolls the schedule forward from the
  date that was due rather than from today. Paying late must not drag every
  future instalment along with it.
*/
CREATE PROCEDURE fin.usp_RecordRecurringInstalment
    @RecurringId NVARCHAR(40),
    @PaidOn      DATE,
    @Actor       NVARCHAR(120),
    @ExpenseId   NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CategoryId NVARCHAR(40), @BranchId NVARCHAR(40), @AmountH BIGINT,
            @Frequency NVARCHAR(20), @NextDueOn DATE,
            @Method NVARCHAR(20), @DescEn NVARCHAR(300), @DescAr NVARCHAR(300);

    SELECT @CategoryId = CategoryId, @BranchId = BranchId, @AmountH = AmountH,
           @Frequency = Frequency, @NextDueOn = NextDueOn, @Method = PaymentMethod,
           @DescEn = DescriptionEn, @DescAr = DescriptionAr
    FROM fin.RecurringPayment WHERE RecurringId = @RecurringId;

    IF @CategoryId IS NULL THROW 56020, N'Recurring payment not found.', 1;

    BEGIN TRAN;

        EXEC fin.usp_RecordExpense
            @CategoryId = @CategoryId, @BranchId = @BranchId,
            @DescriptionEn = @DescEn, @DescriptionAr = @DescAr,
            @AmountH = @AmountH, @VatH = 0,
            @PaymentMethod = @Method, @PaidOn = @PaidOn,
            @Recognition = N'one_time', @Actor = @Actor,
            @ExpenseId = @ExpenseId OUTPUT;

        UPDATE fin.RecurringPayment
        SET LastPaidOn   = @PaidOn,
            NextDueOn    = fin.fn_AdvanceDueDate(@NextDueOn, @Frequency),
            UpdatedAtUtc = SYSUTCDATETIME()
        WHERE RecurringId = @RecurringId;

    COMMIT;
END
GO
PRINT N'Checking existing data against newly created constraints';


GO
USE POSMAIN;


GO
ALTER TABLE [core].[Translation] WITH CHECK CHECK CONSTRAINT [FK_Translation_Language];

ALTER TABLE [core].[Notification] WITH CHECK CHECK CONSTRAINT [FK_Notification_Branch];

ALTER TABLE [core].[Notification] WITH CHECK CHECK CONSTRAINT [FK_Notification_User];

ALTER TABLE [core].[UserPermissionOverride] WITH CHECK CHECK CONSTRAINT [FK_UserOverride_Permission];

ALTER TABLE [core].[UserPermissionOverride] WITH CHECK CHECK CONSTRAINT [FK_UserOverride_User];

ALTER TABLE [core].[RolePermission] WITH CHECK CHECK CONSTRAINT [FK_RolePermission_Permission];

ALTER TABLE [core].[RolePermission] WITH CHECK CHECK CONSTRAINT [FK_RolePermission_Role];

ALTER TABLE [core].[UserBranch] WITH CHECK CHECK CONSTRAINT [FK_UserBranch_User];

ALTER TABLE [core].[UserBranch] WITH CHECK CHECK CONSTRAINT [FK_UserBranch_Branch];

ALTER TABLE [core].[BranchSettings] WITH CHECK CHECK CONSTRAINT [FK_BranchSettings_Bill];

ALTER TABLE [core].[BranchSettings] WITH CHECK CHECK CONSTRAINT [FK_BranchSettings_Branch];

ALTER TABLE [core].[RefreshToken] WITH CHECK CHECK CONSTRAINT [FK_RefreshToken_User];

ALTER TABLE [core].[AppUser] WITH CHECK CHECK CONSTRAINT [FK_AppUser_Role];

ALTER TABLE [core].[AppUser] WITH CHECK CHECK CONSTRAINT [FK_AppUser_DefaultBranch];

ALTER TABLE [core].[CatalogItem] WITH CHECK CHECK CONSTRAINT [FK_CatalogItem_Vendor];

ALTER TABLE [core].[CatalogItem] WITH CHECK CHECK CONSTRAINT [FK_CatalogItem_Category];

ALTER TABLE [core].[CatalogItem] WITH CHECK CHECK CONSTRAINT [FK_CatalogItem_PrintGroup];

ALTER TABLE [core].[BillTemplate] WITH CHECK CHECK CONSTRAINT [FK_BillTemplate_Group];

ALTER TABLE [device].[DeviceHeartbeat] WITH CHECK CHECK CONSTRAINT [FK_Heartbeat_Device];

ALTER TABLE [device].[PosDevice] WITH CHECK CHECK CONSTRAINT [FK_PosDevice_Branch];

ALTER TABLE [device].[DeviceEvent] WITH CHECK CHECK CONSTRAINT [FK_Event_Device];

ALTER TABLE [device].[DeviceCommand] WITH CHECK CHECK CONSTRAINT [FK_Command_Device];

ALTER TABLE [fin].[CommissionRuleItem] WITH CHECK CHECK CONSTRAINT [FK_CRI_Item];

ALTER TABLE [fin].[CommissionRuleItem] WITH CHECK CHECK CONSTRAINT [FK_CRI_Rule];

ALTER TABLE [fin].[JournalLine] WITH CHECK CHECK CONSTRAINT [FK_JournalLine_Account];

ALTER TABLE [fin].[JournalLine] WITH CHECK CHECK CONSTRAINT [FK_JournalLine_Entry];

ALTER TABLE [fin].[JournalEntry] WITH CHECK CHECK CONSTRAINT [FK_JournalEntry_Reverses];

ALTER TABLE [fin].[JournalEntry] WITH CHECK CHECK CONSTRAINT [FK_JournalEntry_Branch];

ALTER TABLE [fin].[CommissionEntry] WITH CHECK CHECK CONSTRAINT [FK_CommissionEntry_Sale];

ALTER TABLE [fin].[CommissionEntry] WITH CHECK CHECK CONSTRAINT [FK_CommissionEntry_Item];

ALTER TABLE [fin].[CommissionEntry] WITH CHECK CHECK CONSTRAINT [FK_CommissionEntry_User];

ALTER TABLE [fin].[CommissionEntry] WITH CHECK CHECK CONSTRAINT [FK_CommissionEntry_Run];

ALTER TABLE [fin].[RecurringPayment] WITH CHECK CHECK CONSTRAINT [FK_Recurring_Branch];

ALTER TABLE [fin].[RecurringPayment] WITH CHECK CHECK CONSTRAINT [FK_Recurring_Category];

ALTER TABLE [fin].[OpeningBalance] WITH CHECK CHECK CONSTRAINT [FK_OpeningBalance_Branch];

ALTER TABLE [fin].[OpeningBalance] WITH CHECK CHECK CONSTRAINT [FK_OpeningBalance_Entry];

ALTER TABLE [fin].[PayrollLine] WITH CHECK CHECK CONSTRAINT [FK_PayrollLine_Run];

ALTER TABLE [fin].[PayrollLine] WITH CHECK CHECK CONSTRAINT [FK_PayrollLine_User];

ALTER TABLE [fin].[ExpenseRecognition] WITH CHECK CHECK CONSTRAINT [FK_ExpenseRecognition_Expense];

ALTER TABLE [fin].[BalancePeriod] WITH CHECK CHECK CONSTRAINT [FK_BalancePeriod_Branch];

ALTER TABLE [fin].[CommissionRuleUser] WITH CHECK CHECK CONSTRAINT [FK_CRU_Rule];

ALTER TABLE [fin].[CommissionRuleUser] WITH CHECK CHECK CONSTRAINT [FK_CRU_User];

ALTER TABLE [fin].[ExpenseCategory] WITH CHECK CHECK CONSTRAINT [FK_ExpenseCategory_Account];

ALTER TABLE [fin].[Expense] WITH CHECK CHECK CONSTRAINT [FK_Expense_Branch];

ALTER TABLE [fin].[Expense] WITH CHECK CHECK CONSTRAINT [FK_Expense_Category];

ALTER TABLE [fin].[DrawerSession] WITH CHECK CHECK CONSTRAINT [FK_DrawerSession_Branch];

ALTER TABLE [fin].[CardSettlement] WITH CHECK CHECK CONSTRAINT [FK_CardSettlement_Branch];

ALTER TABLE [fin].[PayrollRun] WITH CHECK CHECK CONSTRAINT [FK_PayrollRun_Branch];

ALTER TABLE [inv].[StockLevel] WITH CHECK CHECK CONSTRAINT [FK_StockLevel_Branch];

ALTER TABLE [inv].[StockLevel] WITH CHECK CHECK CONSTRAINT [FK_StockLevel_Item];

ALTER TABLE [inv].[PurchaseLine] WITH CHECK CHECK CONSTRAINT [FK_PurchaseLine_Item];

ALTER TABLE [inv].[PurchaseLine] WITH CHECK CHECK CONSTRAINT [FK_PurchaseLine_Purchase];

ALTER TABLE [inv].[StockMovement] WITH CHECK CHECK CONSTRAINT [FK_StockMovement_Branch];

ALTER TABLE [inv].[StockMovement] WITH CHECK CHECK CONSTRAINT [FK_StockMovement_Item];

ALTER TABLE [inv].[VendorPayment] WITH CHECK CHECK CONSTRAINT [FK_VendorPayment_Entry];

ALTER TABLE [inv].[VendorPayment] WITH CHECK CHECK CONSTRAINT [FK_VendorPayment_Vendor];

ALTER TABLE [inv].[VendorPayment] WITH CHECK CHECK CONSTRAINT [FK_VendorPayment_Branch];

ALTER TABLE [inv].[Purchase] WITH CHECK CHECK CONSTRAINT [FK_Purchase_Branch];

ALTER TABLE [inv].[Purchase] WITH CHECK CHECK CONSTRAINT [FK_Purchase_Vendor];

ALTER TABLE [inv].[VendorPaymentAllocation] WITH CHECK CHECK CONSTRAINT [FK_VPA_Payment];

ALTER TABLE [inv].[VendorPaymentAllocation] WITH CHECK CHECK CONSTRAINT [FK_VPA_Purchase];

ALTER TABLE [sales].[SaleLine] WITH CHECK CHECK CONSTRAINT [FK_SaleLine_Sale];

ALTER TABLE [sales].[SaleLine] WITH CHECK CHECK CONSTRAINT [FK_SaleLine_Item];

ALTER TABLE [sales].[Sale] WITH CHECK CHECK CONSTRAINT [FK_Sale_ServedBy];

ALTER TABLE [sales].[Sale] WITH CHECK CHECK CONSTRAINT [FK_Sale_Customer];

ALTER TABLE [sales].[Sale] WITH CHECK CHECK CONSTRAINT [FK_Sale_Discount_Ref];

ALTER TABLE [sales].[Sale] WITH CHECK CHECK CONSTRAINT [FK_Sale_Branch];

ALTER TABLE [sales].[DiscountScope] WITH CHECK CHECK CONSTRAINT [FK_DiscountScope_Discount];

ALTER TABLE [sales].[SaleReturn] WITH CHECK CHECK CONSTRAINT [FK_SaleReturn_Sale];

ALTER TABLE [sales].[PreparationItem] WITH CHECK CHECK CONSTRAINT [FK_PreparationItem_Order];

ALTER TABLE [sales].[PreparationItem] WITH CHECK CHECK CONSTRAINT [FK_PreparationItem_Item];

ALTER TABLE [sales].[SalePayment] WITH CHECK CHECK CONSTRAINT [FK_SalePayment_Sale];

ALTER TABLE [sales].[SaleReturnLine] WITH CHECK CHECK CONSTRAINT [FK_SaleReturnLine_Return];

ALTER TABLE [sales].[SaleReturnLine] WITH CHECK CHECK CONSTRAINT [FK_SaleReturnLine_Line];

ALTER TABLE [sales].[PreparationOrder] WITH CHECK CHECK CONSTRAINT [FK_Preparation_Group];

ALTER TABLE [sales].[PreparationOrder] WITH CHECK CHECK CONSTRAINT [FK_Preparation_Sale];

ALTER TABLE [sales].[PreparationOrder] WITH CHECK CHECK CONSTRAINT [FK_Preparation_Branch];

ALTER TABLE [audit].[RequestTiming] WITH CHECK CHECK CONSTRAINT [CK_Timing_Ms];

ALTER TABLE [audit].[QueryTiming] WITH CHECK CHECK CONSTRAINT [CK_QueryTiming_Type];

ALTER TABLE [audit].[QueryTiming] WITH CHECK CHECK CONSTRAINT [CK_QueryTiming_Ms];

ALTER TABLE [audit].[AuditEntry] WITH CHECK CHECK CONSTRAINT [CK_Audit_Result];

ALTER TABLE [audit].[AuditEntry] WITH CHECK CHECK CONSTRAINT [CK_Audit_Action];

ALTER TABLE [core].[Category] WITH CHECK CHECK CONSTRAINT [CK_Category_AppliesTo];

ALTER TABLE [core].[Customer] WITH CHECK CHECK CONSTRAINT [CK_Customer_Type];

ALTER TABLE [core].[Customer] WITH CHECK CHECK CONSTRAINT [CK_Customer_Limit];

ALTER TABLE [core].[Notification] WITH CHECK CHECK CONSTRAINT [CK_Notification_Severity];

ALTER TABLE [core].[UserPermissionOverride] WITH CHECK CHECK CONSTRAINT [CK_UserOverride_Effect];

ALTER TABLE [core].[Company] WITH CHECK CHECK CONSTRAINT [CK_Company_Cr];

ALTER TABLE [core].[Company] WITH CHECK CHECK CONSTRAINT [CK_Company_Vat];

ALTER TABLE [core].[Company] WITH CHECK CHECK CONSTRAINT [CK_Company_SocialJson];

ALTER TABLE [core].[Vendor] WITH CHECK CHECK CONSTRAINT [CK_Vendor_Terms];

ALTER TABLE [core].[BranchSettings] WITH CHECK CHECK CONSTRAINT [CK_BS_Mode];

ALTER TABLE [core].[BranchSettings] WITH CHECK CHECK CONSTRAINT [CK_BS_Vat];

ALTER TABLE [core].[BranchSettings] WITH CHECK CHECK CONSTRAINT [CK_BS_ServedBy];

ALTER TABLE [core].[AppUser] WITH CHECK CHECK CONSTRAINT [CK_AppUser_Status];

ALTER TABLE [core].[AppUser] WITH CHECK CHECK CONSTRAINT [CK_AppUser_Salary];

ALTER TABLE [core].[CatalogItem] WITH CHECK CHECK CONSTRAINT [CK_CatalogItem_ServiceStock];

ALTER TABLE [core].[CatalogItem] WITH CHECK CHECK CONSTRAINT [CK_CatalogItem_Kind];

ALTER TABLE [core].[CatalogItem] WITH CHECK CHECK CONSTRAINT [CK_CatalogItem_Cost];

ALTER TABLE [core].[CatalogItem] WITH CHECK CHECK CONSTRAINT [CK_CatalogItem_Price];

ALTER TABLE [core].[BillTemplate] WITH CHECK CHECK CONSTRAINT [CK_BillTemplate_HeaderAlignment];

ALTER TABLE [core].[BillTemplate] WITH CHECK CHECK CONSTRAINT [CK_BillTemplate_LogoSize];

ALTER TABLE [core].[BillTemplate] WITH CHECK CHECK CONSTRAINT [CK_BillTemplate_Audience];

ALTER TABLE [core].[BillTemplate] WITH CHECK CHECK CONSTRAINT [CK_BillTemplate_GroupSet];

ALTER TABLE [core].[BillTemplate] WITH CHECK CHECK CONSTRAINT [CK_BillTemplate_Lang];

ALTER TABLE [core].[BillTemplate] WITH CHECK CHECK CONSTRAINT [CK_BillTemplate_Paper];

ALTER TABLE [core].[OtpChallenge] WITH CHECK CHECK CONSTRAINT [CK_Otp_Attempts];

ALTER TABLE [core].[OtpChallenge] WITH CHECK CHECK CONSTRAINT [CK_Otp_Purpose];

ALTER TABLE [core].[Permission] WITH CHECK CHECK CONSTRAINT [CK_Permission_Sensitivity];

ALTER TABLE [device].[PosDevice] WITH CHECK CHECK CONSTRAINT [CK_Device_Printer];

ALTER TABLE [device].[PosDevice] WITH CHECK CHECK CONSTRAINT [CK_Device_Battery];

ALTER TABLE [device].[PosDevice] WITH CHECK CHECK CONSTRAINT [CK_Device_Paper];

ALTER TABLE [device].[PosDevice] WITH CHECK CHECK CONSTRAINT [CK_Device_PaperStatus];

ALTER TABLE [device].[DeviceEvent] WITH CHECK CHECK CONSTRAINT [CK_Event_Severity];

ALTER TABLE [device].[DeviceCommand] WITH CHECK CHECK CONSTRAINT [CK_Cmd_Status];

ALTER TABLE [device].[DeviceCommand] WITH CHECK CHECK CONSTRAINT [CK_Cmd_Type];

ALTER TABLE [fin].[Account] WITH CHECK CHECK CONSTRAINT [CK_Account_Type];

ALTER TABLE [fin].[JournalLine] WITH CHECK CHECK CONSTRAINT [CK_JournalLine_NonNegative];

ALTER TABLE [fin].[JournalLine] WITH CHECK CHECK CONSTRAINT [CK_JournalLine_OneSided];

ALTER TABLE [fin].[CommissionRule] WITH CHECK CHECK CONSTRAINT [CK_CommissionRule_Basis];

ALTER TABLE [fin].[CommissionRule] WITH CHECK CHECK CONSTRAINT [CK_CommissionRule_Pct];

ALTER TABLE [fin].[CommissionRule] WITH CHECK CHECK CONSTRAINT [CK_CommissionRule_Value];

ALTER TABLE [fin].[JournalEntry] WITH CHECK CHECK CONSTRAINT [CK_JournalEntry_Kind];

ALTER TABLE [fin].[JournalEntry] WITH CHECK CHECK CONSTRAINT [CK_JournalEntry_Positive];

ALTER TABLE [fin].[JournalEntry] WITH CHECK CHECK CONSTRAINT [CK_JournalEntry_Balanced];

ALTER TABLE [fin].[CommissionEntry] WITH CHECK CHECK CONSTRAINT [CK_CommissionEntry_Amount];

ALTER TABLE [fin].[RecurringPayment] WITH CHECK CHECK CONSTRAINT [CK_Recurring_Frequency];

ALTER TABLE [fin].[RecurringPayment] WITH CHECK CHECK CONSTRAINT [CK_Recurring_Status];

ALTER TABLE [fin].[RecurringPayment] WITH CHECK CHECK CONSTRAINT [CK_Recurring_Amount];

ALTER TABLE [fin].[OpeningBalance] WITH CHECK CHECK CONSTRAINT [CK_OpeningBalance_NonNegative];

ALTER TABLE [fin].[PayrollLine] WITH CHECK CHECK CONSTRAINT [CK_PayrollLine_NonNegative];

ALTER TABLE [fin].[ExpenseRecognition] WITH CHECK CHECK CONSTRAINT [CK_ExpenseRecognition_Amount];

ALTER TABLE [fin].[BalancePeriod] WITH CHECK CHECK CONSTRAINT [CK_BalancePeriod_Dates];

ALTER TABLE [fin].[BalancePeriod] WITH CHECK CHECK CONSTRAINT [CK_BalancePeriod_Status];

ALTER TABLE [fin].[Expense] WITH CHECK CHECK CONSTRAINT [CK_Expense_Amount];

ALTER TABLE [fin].[Expense] WITH CHECK CHECK CONSTRAINT [CK_Expense_Recognition];

ALTER TABLE [fin].[Expense] WITH CHECK CHECK CONSTRAINT [CK_Expense_Status];

ALTER TABLE [fin].[Expense] WITH CHECK CHECK CONSTRAINT [CK_Expense_Period];

ALTER TABLE [fin].[Expense] WITH CHECK CHECK CONSTRAINT [CK_Expense_Method];

ALTER TABLE [fin].[Expense] WITH CHECK CHECK CONSTRAINT [CK_Expense_Vat];

ALTER TABLE [fin].[DrawerSession] WITH CHECK CHECK CONSTRAINT [CK_DrawerSession_Counted];

ALTER TABLE [fin].[DrawerSession] WITH CHECK CHECK CONSTRAINT [CK_DrawerSession_Opening];

ALTER TABLE [fin].[CardSettlement] WITH CHECK CHECK CONSTRAINT [CK_CardSettlement_Amount];

ALTER TABLE [fin].[CardSettlement] WITH CHECK CHECK CONSTRAINT [CK_CardSettlement_Fee];

ALTER TABLE [fin].[PayrollRun] WITH CHECK CHECK CONSTRAINT [CK_PayrollRun_Status];

ALTER TABLE [inv].[PurchaseLine] WITH CHECK CHECK CONSTRAINT [CK_PurchaseLine_Qty];

ALTER TABLE [inv].[PurchaseLine] WITH CHECK CHECK CONSTRAINT [CK_PurchaseLine_Cost];

ALTER TABLE [inv].[StockMovement] WITH CHECK CHECK CONSTRAINT [CK_StockMovement_Qty];

ALTER TABLE [inv].[StockMovement] WITH CHECK CHECK CONSTRAINT [CK_StockMovement_Type];

ALTER TABLE [inv].[VendorPayment] WITH CHECK CHECK CONSTRAINT [CK_VendorPayment_Method];

ALTER TABLE [inv].[VendorPayment] WITH CHECK CHECK CONSTRAINT [CK_VendorPayment_Amount];

ALTER TABLE [inv].[Purchase] WITH CHECK CHECK CONSTRAINT [CK_Purchase_Totals];

ALTER TABLE [inv].[Purchase] WITH CHECK CHECK CONSTRAINT [CK_Purchase_PaidH];

ALTER TABLE [inv].[VendorPaymentAllocation] WITH CHECK CHECK CONSTRAINT [CK_VPA_Amount];

ALTER TABLE [sales].[SaleLine] WITH CHECK CHECK CONSTRAINT [CK_SaleLine_Money];

ALTER TABLE [sales].[SaleLine] WITH CHECK CHECK CONSTRAINT [CK_SaleLine_Qty];

ALTER TABLE [sales].[SaleLine] WITH CHECK CHECK CONSTRAINT [CK_SaleLine_Returned];

ALTER TABLE [sales].[Sale] WITH CHECK CHECK CONSTRAINT [CK_Sale_NonNegative];

ALTER TABLE [sales].[Sale] WITH CHECK CHECK CONSTRAINT [CK_Sale_OrderType];

ALTER TABLE [sales].[Sale] WITH CHECK CHECK CONSTRAINT [CK_Sale_Status];

ALTER TABLE [sales].[Sale] WITH CHECK CHECK CONSTRAINT [CK_Sale_Totals];

ALTER TABLE [sales].[DiscountScope] WITH CHECK CHECK CONSTRAINT [CK_DiscountScope_Type];

ALTER TABLE [sales].[Discount] WITH CHECK CHECK CONSTRAINT [CK_Discount_Percent];

ALTER TABLE [sales].[Discount] WITH CHECK CHECK CONSTRAINT [CK_Discount_Type];

ALTER TABLE [sales].[Discount] WITH CHECK CHECK CONSTRAINT [CK_Discount_Value];

ALTER TABLE [sales].[Discount] WITH CHECK CHECK CONSTRAINT [CK_Discount_Applies];

ALTER TABLE [sales].[Discount] WITH CHECK CHECK CONSTRAINT [CK_Discount_Dates];

ALTER TABLE [sales].[SaleReturn] WITH CHECK CHECK CONSTRAINT [CK_SaleReturn_Method];

ALTER TABLE [sales].[SaleReturn] WITH CHECK CHECK CONSTRAINT [CK_SaleReturn_Reason];

ALTER TABLE [sales].[SaleReturn] WITH CHECK CHECK CONSTRAINT [CK_SaleReturn_Refund];

ALTER TABLE [sales].[PreparationItem] WITH CHECK CHECK CONSTRAINT [CK_PreparationItem_Done];

ALTER TABLE [sales].[PreparationItem] WITH CHECK CHECK CONSTRAINT [CK_PreparationItem_Qty];

ALTER TABLE [sales].[SalePayment] WITH CHECK CHECK CONSTRAINT [CK_SalePayment_Method];

ALTER TABLE [sales].[SalePayment] WITH CHECK CHECK CONSTRAINT [CK_SalePayment_Amount];

ALTER TABLE [sales].[SaleReturnLine] WITH CHECK CHECK CONSTRAINT [CK_SaleReturnLine_Qty];

ALTER TABLE [sales].[PreparationOrder] WITH CHECK CHECK CONSTRAINT [CK_Preparation_OrderType];

ALTER TABLE [sales].[PreparationOrder] WITH CHECK CHECK CONSTRAINT [CK_Preparation_Status];


GO
PRINT N'001 · Baseline schema ready.';


GO
