/*==============================================================================
  001 — control database schema (POSCONTROL)

  The SaaS control plane: who the tenants are, where each one's database is,
  what they pay for, and who administers the platform. No tenant business data
  lives here — sales, stock and staff stay in each tenant's own database, built
  from db-migrations/.

  Applied by the API at startup (Tenancy:Control), which creates the database
  when it is missing and records each file in dbo.SchemaMigration. The name
  POSCONTROL is replaced with the configured database name before running.
==============================================================================*/

USE master;
GO

IF DB_ID(N'POSCONTROL') IS NULL
    CREATE DATABASE POSCONTROL COLLATE Arabic_CI_AS;
GO

ALTER DATABASE POSCONTROL SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO

USE POSCONTROL;
GO

IF SCHEMA_ID(N'ctl') IS NOT NULL
    THROW 50001, N'POSCONTROL already has a schema. 001 only runs on an empty database.', 1;
GO

CREATE SCHEMA ctl;
GO

/*----------------------------------------------------------------- tenants */

CREATE SEQUENCE ctl.TenantNumber AS INT START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE ctl.SubscriptionNumber AS INT START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE ctl.InvoiceNumber AS INT START WITH 10001 INCREMENT BY 1;
CREATE SEQUENCE ctl.IssueNumber AS INT START WITH 2001 INCREMENT BY 1;
CREATE SEQUENCE ctl.HardwareNumber AS INT START WITH 10001 INCREMENT BY 1;
GO

CREATE TABLE ctl.Tenant (
    TenantId          NVARCHAR(20)   NOT NULL CONSTRAINT PK_Tenant PRIMARY KEY,
    Name              NVARCHAR(160)  NOT NULL,
    NameAr            NVARCHAR(160)  NULL,
    BusinessType      NVARCHAR(40)   NULL,
    City              NVARCHAR(120)  NULL,
    Country           NVARCHAR(80)   NULL,
    CrNumber          NVARCHAR(10)   NULL,
    VatNumber         NVARCHAR(15)   NULL,
    Email             NVARCHAR(160)  NULL,
    Phone             NVARCHAR(30)   NULL,
    /* Where its data is. The server comes from configuration
       (ConnectionStrings:TenantServer); only the catalog is per tenant. */
    DatabaseName      NVARCHAR(128)  NOT NULL CONSTRAINT UQ_Tenant_Database UNIQUE,
    /* provisioning → active | suspended; failed when provisioning broke. */
    Status            NVARCHAR(20)   NOT NULL CONSTRAINT DF_Tenant_Status DEFAULT N'provisioning',
    Source            NVARCHAR(20)   NOT NULL CONSTRAINT DF_Tenant_Source DEFAULT N'admin',
    ProvisionError    NVARCHAR(2000) NULL,
    SchemaVersion     NVARCHAR(200)  NULL,
    MigratedAtUtc     DATETIME2(3)   NULL,
    /* Point of contact: the tenant's owner account. */
    PocUserId         NVARCHAR(40)   NULL,
    PocName           NVARCHAR(160)  NULL,
    PocUsername       NVARCHAR(60)   NULL,
    PocMobile         NVARCHAR(30)   NULL,
    PocEmail          NVARCHAR(160)  NULL,
    /* Configuration captured by the wizard. */
    PaymentMethods    NVARCHAR(400)  NULL,
    DefaultVat        DECIMAL(5,2)   NOT NULL CONSTRAINT DF_Tenant_Vat DEFAULT 15,
    PricesIncludeVat  BIT            NOT NULL CONSTRAINT DF_Tenant_IncVat DEFAULT 1,
    ZatcaCertificate  NVARCHAR(MAX)  NULL,
    CertificateExpiry DATE           NULL,
    BranchAddress     NVARCHAR(300)  NULL,
    Latitude          NVARCHAR(30)   NULL,
    Longitude         NVARCHAR(30)   NULL,
    RegisteredBy      NVARCHAR(160)  NULL,
    ActivatedBy       NVARCHAR(160)  NULL,
    ActivatedAtUtc    DATETIME2(3)   NULL,
    SuspendedAtUtc    DATETIME2(3)   NULL,
    SuspendReason     NVARCHAR(400)  NULL,
    CreatedAtUtc      DATETIME2(3)   NOT NULL CONSTRAINT DF_Tenant_Created DEFAULT SYSUTCDATETIME(),
    UpdatedAtUtc      DATETIME2(3)   NOT NULL CONSTRAINT DF_Tenant_Updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_Tenant_Status CHECK (Status IN (N'provisioning', N'active', N'suspended', N'failed')),
    CONSTRAINT CK_Tenant_DbName CHECK (DatabaseName NOT LIKE N'%[^A-Za-z0-9_]%')
);
GO

/*
 * Identifier → tenant, for signing in before any tenant database is known.
 * Emails, mobiles and usernames are unique across the platform because of it.
 */
CREATE TABLE ctl.LoginDirectory (
    Identifier   NVARCHAR(160) NOT NULL CONSTRAINT PK_LoginDirectory PRIMARY KEY,
    TenantId     NVARCHAR(20)  NOT NULL CONSTRAINT FK_LoginDirectory_Tenant REFERENCES ctl.Tenant (TenantId),
    UserId       NVARCHAR(40)  NOT NULL,
    Kind         NVARCHAR(20)  NOT NULL,
    UpdatedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_LoginDirectory_At DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_LoginDirectory_User ON ctl.LoginDirectory (TenantId, UserId);
GO

/* A POS device's one-time registration code → its tenant. */
CREATE TABLE ctl.DeviceCode (
    RegistrationCode NVARCHAR(20) NOT NULL CONSTRAINT PK_DeviceCode PRIMARY KEY,
    TenantId         NVARCHAR(20) NOT NULL CONSTRAINT FK_DeviceCode_Tenant REFERENCES ctl.Tenant (TenantId),
    DeviceId         NVARCHAR(40) NOT NULL,
    CreatedAtUtc     DATETIME2(3) NOT NULL CONSTRAINT DF_DeviceCode_At DEFAULT SYSUTCDATETIME()
);
GO

/*------------------------------------------------------- plans and features */

CREATE TABLE ctl.[Plan] (
    PlanKey      NVARCHAR(20)  NOT NULL CONSTRAINT PK_Plan PRIMARY KEY,
    Label        NVARCHAR(60)  NOT NULL,
    IsTrial      BIT           NOT NULL CONSTRAINT DF_Plan_Trial DEFAULT 0,
    MonthlyH     BIGINT        NULL,
    AnnualH      BIGINT        NULL,
    Branches     INT           NULL,
    Devices      INT           NULL,
    Users        INT           NULL,
    Transactions INT           NULL,
    StorageGb    DECIMAL(9,2)  NULL,
    /* The plan card's bullet points, separated by |. */
    Highlights   NVARCHAR(400) NULL,
    SortOrder    INT           NOT NULL CONSTRAINT DF_Plan_Sort DEFAULT 0,
    IsActive     BIT           NOT NULL CONSTRAINT DF_Plan_Active DEFAULT 1
);

CREATE TABLE ctl.Feature (
    FeatureKey NVARCHAR(40)  NOT NULL CONSTRAINT PK_Feature PRIMARY KEY,
    Label      NVARCHAR(80)  NOT NULL,
    Icon       NVARCHAR(40)  NULL,
    Blurb      NVARCHAR(300) NULL,
    IsCore     BIT           NOT NULL CONSTRAINT DF_Feature_Core DEFAULT 0,
    SortOrder  INT           NOT NULL CONSTRAINT DF_Feature_Sort DEFAULT 0
);

/* What a kind of business COULD use. */
CREATE TABLE ctl.TypeFeature (
    BusinessType NVARCHAR(40) NOT NULL,
    FeatureKey   NVARCHAR(40) NOT NULL CONSTRAINT FK_TypeFeature_Feature REFERENCES ctl.Feature (FeatureKey),
    CONSTRAINT PK_TypeFeature PRIMARY KEY (BusinessType, FeatureKey)
);

/* What a plan INCLUDES for a kind of business, and its limits. */
CREATE TABLE ctl.PlanConfig (
    BusinessType      NVARCHAR(40) NOT NULL,
    PlanKey           NVARCHAR(20) NOT NULL CONSTRAINT FK_PlanConfig_Plan REFERENCES ctl.[Plan] (PlanKey),
    Users             INT          NULL,
    Devices           INT          NULL,
    Branches          INT          NULL,
    Duration          INT          NOT NULL CONSTRAINT DF_PlanConfig_Duration DEFAULT 12,
    DurationUnit      NVARCHAR(10) NOT NULL CONSTRAINT DF_PlanConfig_Unit DEFAULT N'months',
    AmountH           BIGINT       NULL,
    Currency          NVARCHAR(3)  NOT NULL CONSTRAINT DF_PlanConfig_Currency DEFAULT N'SAR',
    Status            NVARCHAR(10) NOT NULL CONSTRAINT DF_PlanConfig_Status DEFAULT N'active',
    CustomBilling     BIT          NOT NULL CONSTRAINT DF_PlanConfig_Custom DEFAULT 0,
    AutoRenew         BIT          NOT NULL CONSTRAINT DF_PlanConfig_Renew DEFAULT 1,
    RenewalNoticeDays INT          NOT NULL CONSTRAINT DF_PlanConfig_Notice DEFAULT 14,
    UpdatedAtUtc      DATETIME2(3) NOT NULL CONSTRAINT DF_PlanConfig_At DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_PlanConfig PRIMARY KEY (BusinessType, PlanKey),
    CONSTRAINT CK_PlanConfig_Unit CHECK (DurationUnit IN (N'days', N'weeks', N'months')),
    CONSTRAINT CK_PlanConfig_Status CHECK (Status IN (N'active', N'inactive'))
);

CREATE TABLE ctl.PlanConfigFeature (
    BusinessType NVARCHAR(40) NOT NULL,
    PlanKey      NVARCHAR(20) NOT NULL,
    FeatureKey   NVARCHAR(40) NOT NULL CONSTRAINT FK_PlanConfigFeature_Feature REFERENCES ctl.Feature (FeatureKey),
    CONSTRAINT PK_PlanConfigFeature PRIMARY KEY (BusinessType, PlanKey, FeatureKey),
    CONSTRAINT FK_PlanConfigFeature_Config FOREIGN KEY (BusinessType, PlanKey)
        REFERENCES ctl.PlanConfig (BusinessType, PlanKey) ON DELETE CASCADE
);
GO

/*------------------------------------------------ subscriptions and billing */

/* One row per tenant: its current term. Renewals extend it in place and are
   counted; the history is in ctl.Invoice and ctl.AdminAudit. */
CREATE TABLE ctl.Subscription (
    SubscriptionId NVARCHAR(20)  NOT NULL CONSTRAINT PK_Subscription PRIMARY KEY,
    TenantId       NVARCHAR(20)  NOT NULL CONSTRAINT FK_Subscription_Tenant REFERENCES ctl.Tenant (TenantId)
                                          CONSTRAINT UQ_Subscription_Tenant UNIQUE,
    PlanKey        NVARCHAR(20)  NOT NULL CONSTRAINT FK_Subscription_Plan REFERENCES ctl.[Plan] (PlanKey),
    Cycle          NVARCHAR(10)  NOT NULL CONSTRAINT DF_Subscription_Cycle DEFAULT N'annual',
    IsTrial        BIT           NOT NULL CONSTRAINT DF_Subscription_Trial DEFAULT 0,
    TrialDays      INT           NULL,
    StartsOn       DATE          NOT NULL,
    RenewsOn       DATE          NOT NULL,
    Status         NVARCHAR(20)  NOT NULL CONSTRAINT DF_Subscription_Status DEFAULT N'active',
    /* Monthly price agreed outside the list price (Enterprise). */
    CustomMonthlyH BIGINT        NULL,
    Renewals       INT           NOT NULL CONSTRAINT DF_Subscription_Renewals DEFAULT 0,
    LastRenewedOn  DATE          NULL,
    CancelledAtUtc DATETIME2(3)  NULL,
    CancelReason   NVARCHAR(400) NULL,
    CreatedAtUtc   DATETIME2(3)  NOT NULL CONSTRAINT DF_Subscription_Created DEFAULT SYSUTCDATETIME(),
    UpdatedAtUtc   DATETIME2(3)  NOT NULL CONSTRAINT DF_Subscription_Updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_Subscription_Cycle CHECK (Cycle IN (N'monthly', N'annual')),
    CONSTRAINT CK_Subscription_Status CHECK (Status IN (N'active', N'cancelled'))
);

CREATE TABLE ctl.Invoice (
    InvoiceId      NVARCHAR(20)  NOT NULL CONSTRAINT PK_Invoice PRIMARY KEY,
    TenantId       NVARCHAR(20)  NOT NULL CONSTRAINT FK_Invoice_Tenant REFERENCES ctl.Tenant (TenantId),
    SubscriptionId NVARCHAR(20)  NULL,
    PlanKey        NVARCHAR(20)  NOT NULL,
    AmountH        BIGINT        NOT NULL,
    Method         NVARCHAR(30)  NULL,
    Status         NVARCHAR(20)  NOT NULL CONSTRAINT DF_Invoice_Status DEFAULT N'pending',
    IssuedOn       DATE          NOT NULL,
    PaidOn         DATE          NULL,
    PeriodStart    DATE          NULL,
    PeriodEnd      DATE          NULL,
    Notes          NVARCHAR(400) NULL,
    CreatedAtUtc   DATETIME2(3)  NOT NULL CONSTRAINT DF_Invoice_Created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_Invoice_Status CHECK (Status IN (N'paid', N'pending', N'failed', N'refunded'))
);
CREATE INDEX IX_Invoice_Tenant ON ctl.Invoice (TenantId, IssuedOn DESC);
GO

/*--------------------------------------------------------------- support */

CREATE TABLE ctl.Issue (
    IssueId       NVARCHAR(20)   NOT NULL CONSTRAINT PK_Issue PRIMARY KEY,
    TenantId      NVARCHAR(20)   NOT NULL CONSTRAINT FK_Issue_Tenant REFERENCES ctl.Tenant (TenantId),
    Title         NVARCHAR(200)  NOT NULL,
    Description   NVARCHAR(2000) NULL,
    Priority      NVARCHAR(10)   NOT NULL CONSTRAINT DF_Issue_Priority DEFAULT N'medium',
    Status        NVARCHAR(10)   NOT NULL CONSTRAINT DF_Issue_Status DEFAULT N'open',
    Assignee      NVARCHAR(160)  NULL,
    OpenedAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_Issue_Opened DEFAULT SYSUTCDATETIME(),
    ResolvedAtUtc DATETIME2(3)   NULL,
    CONSTRAINT CK_Issue_Priority CHECK (Priority IN (N'high', N'medium', N'low')),
    CONSTRAINT CK_Issue_Status CHECK (Status IN (N'open', N'waiting', N'resolved'))
);

CREATE TABLE ctl.SupportSession (
    SessionId    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SupportSession PRIMARY KEY,
    TenantId     NVARCHAR(20)  NOT NULL CONSTRAINT FK_SupportSession_Tenant REFERENCES ctl.Tenant (TenantId),
    AdminId      NVARCHAR(40)  NOT NULL,
    Reason       NVARCHAR(400) NOT NULL,
    StartedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_SupportSession_At DEFAULT SYSUTCDATETIME(),
    EndedAtUtc   DATETIME2(3)  NULL
);
GO

/*---------------------------------------------------------- administrators */

CREATE TABLE ctl.Admin (
    AdminId            NVARCHAR(40)  NOT NULL CONSTRAINT PK_Admin PRIMARY KEY,
    Name               NVARCHAR(160) NOT NULL,
    Mobile             NVARCHAR(30)  NOT NULL CONSTRAINT UQ_Admin_Mobile UNIQUE,
    Email              NVARCHAR(160) NULL,
    Role               NVARCHAR(40)  NOT NULL CONSTRAINT DF_Admin_Role DEFAULT N'Owner',
    /* Comma-separated navigation keys; NULL means everything. */
    Permissions        NVARCHAR(400) NULL,
    PasswordHash       NVARCHAR(400) NOT NULL,
    PasswordSalt       NVARCHAR(200) NOT NULL,
    Status             NVARCHAR(20)  NOT NULL CONSTRAINT DF_Admin_Status DEFAULT N'active',
    MustChangePassword BIT           NOT NULL CONSTRAINT DF_Admin_Must DEFAULT 0,
    FailedLogins       INT           NOT NULL CONSTRAINT DF_Admin_Failed DEFAULT 0,
    LockedUntilUtc     DATETIME2(3)  NULL,
    /* Bumped on a password reset: tokens minted before it stop working. */
    SessionVersion     INT           NOT NULL CONSTRAINT DF_Admin_SessionVersion DEFAULT 1,
    LastLoginAtUtc     DATETIME2(3)  NULL,
    CreatedAtUtc       DATETIME2(3)  NOT NULL CONSTRAINT DF_Admin_Created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_Admin_Status CHECK (Status IN (N'active', N'suspended'))
);

CREATE TABLE ctl.AdminOtp (
    ChallengeId   NVARCHAR(64)  NOT NULL CONSTRAINT PK_AdminOtp PRIMARY KEY,
    AdminId       NVARCHAR(40)  NOT NULL CONSTRAINT FK_AdminOtp_Admin REFERENCES ctl.Admin (AdminId),
    CodeHash      NVARCHAR(400) NOT NULL,
    CodeSalt      NVARCHAR(200) NOT NULL,
    ExpiresAtUtc  DATETIME2(3)  NOT NULL,
    Attempts      INT           NOT NULL CONSTRAINT DF_AdminOtp_Attempts DEFAULT 0,
    ConsumedAtUtc DATETIME2(3)  NULL,
    CreatedAtUtc  DATETIME2(3)  NOT NULL CONSTRAINT DF_AdminOtp_At DEFAULT SYSUTCDATETIME()
);
GO

/* Every administrative action, and the reads worth recording. */
CREATE TABLE ctl.AdminAudit (
    AuditId      BIGINT IDENTITY(5001,1) NOT NULL CONSTRAINT PK_AdminAudit PRIMARY KEY,
    AtUtc        DATETIME2(3)   NOT NULL CONSTRAINT DF_AdminAudit_At DEFAULT SYSUTCDATETIME(),
    AdminId      NVARCHAR(40)   NULL,
    AdminName    NVARCHAR(160)  NULL,
    Action       NVARCHAR(60)   NOT NULL,
    Label        NVARCHAR(160)  NOT NULL,
    TenantId     NVARCHAR(20)   NULL,
    EntityId     NVARCHAR(60)   NULL,
    BeforeValue  NVARCHAR(400)  NULL,
    AfterValue   NVARCHAR(400)  NULL,
    Reason       NVARCHAR(400)  NULL,
    Method       NVARCHAR(10)   NULL,
    Endpoint     NVARCHAR(300)  NULL,
    TableName    NVARCHAR(100)  NULL,
    Operation    NVARCHAR(10)   NULL,
    DurationMs   INT            NULL,
    RowsAffected INT            NULL,
    IpAddress    NVARCHAR(60)   NULL,
    Result       NVARCHAR(10)   NOT NULL CONSTRAINT DF_AdminAudit_Result DEFAULT N'success',
    ErrorMessage NVARCHAR(1000) NULL
);
CREATE INDEX IX_AdminAudit_Tenant ON ctl.AdminAudit (TenantId, AtUtc DESC);
CREATE INDEX IX_AdminAudit_At ON ctl.AdminAudit (AtUtc DESC);
GO

/* The platform's activity feed: things that happened to tenants. */
CREATE TABLE ctl.PlatformEvent (
    EventId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PlatformEvent PRIMARY KEY,
    AtUtc    DATETIME2(3)  NOT NULL CONSTRAINT DF_PlatformEvent_At DEFAULT SYSUTCDATETIME(),
    Kind     NVARCHAR(40)  NOT NULL,
    Label    NVARCHAR(160) NOT NULL,
    TenantId NVARCHAR(20)  NULL,
    Detail   NVARCHAR(400) NULL,
    Severity NVARCHAR(10)  NOT NULL CONSTRAINT DF_PlatformEvent_Severity DEFAULT N'info'
);
CREATE INDEX IX_PlatformEvent_At ON ctl.PlatformEvent (AtUtc DESC);
GO

/*------------------------------------------------------- hardware register */

CREATE TABLE ctl.HardwareDevice (
    DeviceId        NVARCHAR(20)  NOT NULL CONSTRAINT PK_HardwareDevice PRIMARY KEY,
    Serial          NVARCHAR(80)  NOT NULL CONSTRAINT UQ_HardwareDevice_Serial UNIQUE,
    Manufacturer    NVARCHAR(60)  NULL,
    Model           NVARCHAR(60)  NOT NULL,
    DeviceType      NVARCHAR(40)  NULL,
    Os              NVARCHAR(60)  NULL,
    MacAddress      NVARCHAR(17)  NULL,
    Imei            NVARCHAR(20)  NULL,
    PurchasedOn     DATE          NULL,
    WarrantyEndsOn  DATE          NULL,
    WarrantyMonths  INT           NULL,
    Status          NVARCHAR(20)  NOT NULL CONSTRAINT DF_HardwareDevice_Status DEFAULT N'available',
    TenantId        NVARCHAR(20)  NULL CONSTRAINT FK_HardwareDevice_Tenant REFERENCES ctl.Tenant (TenantId),
    BranchId        NVARCHAR(40)  NULL,
    BranchName      NVARCHAR(160) NULL,
    TerminalId      NVARCHAR(40)  NULL,
    InstalledOn     DATE          NULL,
    LastOnlineAtUtc DATETIME2(3)  NULL,
    Notes           NVARCHAR(1000) NULL,
    CreatedAtUtc    DATETIME2(3)  NOT NULL CONSTRAINT DF_HardwareDevice_Created DEFAULT SYSUTCDATETIME(),
    UpdatedAtUtc    DATETIME2(3)  NOT NULL CONSTRAINT DF_HardwareDevice_Updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_HardwareDevice_Status CHECK (Status IN (N'available', N'assigned', N'active', N'suspended', N'retired')),
    /* Assigned, active and suspended belong to someone. */
    CONSTRAINT CK_HardwareDevice_Owner CHECK (Status IN (N'available', N'retired') OR TenantId IS NOT NULL)
);

CREATE TABLE ctl.HardwareDeviceEvent (
    EventId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_HardwareDeviceEvent PRIMARY KEY,
    DeviceId NVARCHAR(20)  NOT NULL CONSTRAINT FK_HardwareDeviceEvent_Device REFERENCES ctl.HardwareDevice (DeviceId),
    AtUtc    DATETIME2(3)  NOT NULL CONSTRAINT DF_HardwareDeviceEvent_At DEFAULT SYSUTCDATETIME(),
    Event    NVARCHAR(80)  NOT NULL,
    ByName   NVARCHAR(160) NULL,
    Detail   NVARCHAR(400) NULL
);
GO

/*----------------------------------------------- figures read from tenants */

/* The latest snapshot of each tenant, collected by TenantSnapshotService. A
   tenant that cannot be reached keeps its last figures and is marked, not
   zeroed. */
CREATE TABLE ctl.TenantSnapshot (
    TenantId             NVARCHAR(20)   NOT NULL CONSTRAINT PK_TenantSnapshot PRIMARY KEY
                                                 CONSTRAINT FK_TenantSnapshot_Tenant REFERENCES ctl.Tenant (TenantId),
    CollectedAtUtc       DATETIME2(3)   NOT NULL,
    Reachable            BIT            NOT NULL,
    Error                NVARCHAR(1000) NULL,
    Branches             INT            NOT NULL CONSTRAINT DF_Snap_Branches DEFAULT 0,
    Devices              INT            NOT NULL CONSTRAINT DF_Snap_Devices DEFAULT 0,
    DevicesOnline        INT            NOT NULL CONSTRAINT DF_Snap_Online DEFAULT 0,
    Users                INT            NOT NULL CONSTRAINT DF_Snap_Users DEFAULT 0,
    ActiveUsers          INT            NOT NULL CONSTRAINT DF_Snap_ActiveUsers DEFAULT 0,
    Transactions         BIGINT         NOT NULL CONSTRAINT DF_Snap_Tx DEFAULT 0,
    SalesH               BIGINT         NOT NULL CONSTRAINT DF_Snap_Sales DEFAULT 0,
    TransactionsToday    INT            NOT NULL CONSTRAINT DF_Snap_TxToday DEFAULT 0,
    SalesTodayH          BIGINT         NOT NULL CONSTRAINT DF_Snap_SalesToday DEFAULT 0,
    TransactionsMonth    INT            NOT NULL CONSTRAINT DF_Snap_TxMonth DEFAULT 0,
    LoginsToday          INT            NOT NULL CONSTRAINT DF_Snap_Logins DEFAULT 0,
    HeartbeatsToday      INT            NOT NULL CONSTRAINT DF_Snap_Heartbeats DEFAULT 0,
    ApiRequestsToday     INT            NOT NULL CONSTRAINT DF_Snap_Api DEFAULT 0,
    ApiErrorsToday       INT            NOT NULL CONSTRAINT DF_Snap_ApiErr DEFAULT 0,
    ApiRequestsMonth     INT            NOT NULL CONSTRAINT DF_Snap_ApiMonth DEFAULT 0,
    ActiveUsersMonth     INT            NOT NULL CONSTRAINT DF_Snap_UsersMonth DEFAULT 0,
    FirstLoginAtUtc      DATETIME2(3)   NULL,
    LastLoginAtUtc       DATETIME2(3)   NULL,
    LastTransactionAtUtc DATETIME2(3)   NULL,
    DbSizeMb             DECIMAL(12,2)  NOT NULL CONSTRAINT DF_Snap_Size DEFAULT 0,
    DbRows               BIGINT         NOT NULL CONSTRAINT DF_Snap_Rows DEFAULT 0,
    DbTables             INT            NOT NULL CONSTRAINT DF_Snap_Tables DEFAULT 0,
    LargestTable         NVARCHAR(200)  NULL,
    LargestTableRows     BIGINT         NOT NULL CONSTRAINT DF_Snap_Largest DEFAULT 0
);

/* Per-day sales, for the analytics charts. */
CREATE TABLE ctl.TenantDailyStat (
    TenantId     NVARCHAR(20) NOT NULL CONSTRAINT FK_TenantDailyStat_Tenant REFERENCES ctl.Tenant (TenantId),
    StatDate     DATE         NOT NULL,
    Transactions INT          NOT NULL,
    SalesH       BIGINT       NOT NULL,
    CONSTRAINT PK_TenantDailyStat PRIMARY KEY (TenantId, StatDate)
);
GO

/*------------------------------------------------- master data and settings */

/* cities · services (business types) · payment-methods · deactivation-reasons.
   Extra holds the set's own column: a city's region, a type's icon, a payment
   method's kind. Removing an item deactivates it; whoever uses it keeps it. */
CREATE TABLE ctl.MasterItem (
    SetKey    NVARCHAR(40)  NOT NULL,
    Value     NVARCHAR(60)  NOT NULL,
    Label     NVARCHAR(120) NOT NULL,
    LabelAr   NVARCHAR(120) NULL,
    Extra     NVARCHAR(60)  NULL,
    SortOrder INT           NOT NULL CONSTRAINT DF_MasterItem_Sort DEFAULT 0,
    IsActive  BIT           NOT NULL CONSTRAINT DF_MasterItem_Active DEFAULT 1,
    CONSTRAINT PK_MasterItem PRIMARY KEY (SetKey, Value)
);

CREATE TABLE ctl.Setting (
    SettingKey   NVARCHAR(60)  NOT NULL CONSTRAINT PK_Setting PRIMARY KEY,
    Value        NVARCHAR(400) NOT NULL,
    UpdatedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_Setting_At DEFAULT SYSUTCDATETIME(),
    UpdatedBy    NVARCHAR(160) NULL
);

CREATE TABLE ctl.NotificationRule (
    RuleKey   NVARCHAR(40)  NOT NULL CONSTRAINT PK_NotificationRule PRIMARY KEY,
    Label     NVARCHAR(160) NOT NULL,
    Channel   NVARCHAR(20)  NOT NULL,
    IsOn      BIT           NOT NULL CONSTRAINT DF_NotificationRule_On DEFAULT 1,
    SortOrder INT           NOT NULL CONSTRAINT DF_NotificationRule_Sort DEFAULT 0
);
GO
