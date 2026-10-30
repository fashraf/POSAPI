/*==============================================================================
  001 — control database schema

  The SaaS control plane: who the tenants are, where each one's database is,
  what they pay for, and who administers the platform. No tenant business data
  lives here — sales, stock and staff stay in each tenant's own database, built
  from db-migrations/.

  Applied by the API at startup (Tenancy:ControlDatabase, poscontrol by
  default), which creates the database when it is missing and records each
  file in dbo.SchemaMigration. Conventions are those of db-migrations/README.md.
==============================================================================*/

/* Case-insensitive, accent-sensitive text, as the tenant databases use. */
CREATE COLLATION IF NOT EXISTS ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);

CREATE SCHEMA ctl;

/*----------------------------------------------------------------- tenants */

CREATE SEQUENCE ctl.TenantNumber AS integer START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE ctl.SubscriptionNumber AS integer START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE ctl.InvoiceNumber AS integer START WITH 10001 INCREMENT BY 1;
CREATE SEQUENCE ctl.IssueNumber AS integer START WITH 2001 INCREMENT BY 1;
CREATE SEQUENCE ctl.HardwareNumber AS integer START WITH 10001 INCREMENT BY 1;

CREATE TABLE ctl.Tenant (
    TenantId          varchar(20) COLLATE ci   NOT NULL CONSTRAINT PK_Tenant PRIMARY KEY,
    Name              varchar(160) COLLATE ci  NOT NULL,
    NameAr            varchar(160) COLLATE ci  NULL,
    BusinessType      varchar(40) COLLATE ci   NULL,
    City              varchar(120) COLLATE ci  NULL,
    Country           varchar(80) COLLATE ci   NULL,
    CrNumber          varchar(10) COLLATE ci   NULL,
    VatNumber         varchar(15) COLLATE ci   NULL,
    Email             varchar(160) COLLATE ci  NULL,
    Phone             varchar(30) COLLATE ci   NULL,
    /* Where its data is. The server comes from configuration
       (ConnectionStrings:TenantServer); only the catalog is per tenant. */
    DatabaseName      varchar(128) COLLATE ci  NOT NULL CONSTRAINT UQ_Tenant_Database UNIQUE,
    /* provisioning → active | suspended; failed when provisioning broke. */
    Status            varchar(20) COLLATE ci   NOT NULL DEFAULT 'provisioning',
    Source            varchar(20) COLLATE ci   NOT NULL DEFAULT 'admin',
    ProvisionError    varchar(2000) COLLATE ci NULL,
    SchemaVersion     varchar(200) COLLATE ci  NULL,
    MigratedAtUtc     timestamp(3)   NULL,
    /* Point of contact: the tenant's owner account. */
    PocUserId         varchar(40) COLLATE ci   NULL,
    PocName           varchar(160) COLLATE ci  NULL,
    PocUsername       varchar(60) COLLATE ci   NULL,
    PocMobile         varchar(30) COLLATE ci   NULL,
    PocEmail          varchar(160) COLLATE ci  NULL,
    /* Configuration captured by the wizard. */
    PaymentMethods    varchar(400) COLLATE ci  NULL,
    DefaultVat        numeric(5,2)   NOT NULL DEFAULT 15,
    PricesIncludeVat  boolean            NOT NULL DEFAULT true,
    ZatcaCertificate  text  NULL,
    CertificateExpiry date           NULL,
    BranchAddress     varchar(300) COLLATE ci  NULL,
    Latitude          varchar(30) COLLATE ci   NULL,
    Longitude         varchar(30) COLLATE ci   NULL,
    RegisteredBy      varchar(160) COLLATE ci  NULL,
    ActivatedBy       varchar(160) COLLATE ci  NULL,
    ActivatedAtUtc    timestamp(3)   NULL,
    SuspendedAtUtc    timestamp(3)   NULL,
    SuspendReason     varchar(400) COLLATE ci  NULL,
    CreatedAtUtc      timestamp(3)   NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    UpdatedAtUtc      timestamp(3)   NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT CK_Tenant_Status CHECK (Status IN ('provisioning', 'active', 'suspended', 'failed')),
    CONSTRAINT CK_Tenant_DbName CHECK (DatabaseName COLLATE "C" ~ '^[A-Za-z0-9_]*$')
);

/*
 * Identifier → tenant, for signing in before any tenant database is known.
 * Emails, mobiles and usernames are unique across the platform because of it.
 */
CREATE TABLE ctl.LoginDirectory (
    Identifier   varchar(160) COLLATE ci NOT NULL CONSTRAINT PK_LoginDirectory PRIMARY KEY,
    TenantId     varchar(20) COLLATE ci  NOT NULL CONSTRAINT FK_LoginDirectory_Tenant REFERENCES ctl.Tenant (TenantId),
    UserId       varchar(40) COLLATE ci  NOT NULL,
    Kind         varchar(20) COLLATE ci  NOT NULL,
    UpdatedAtUtc timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
);
CREATE INDEX IX_LoginDirectory_User ON ctl.LoginDirectory (TenantId, UserId);

/* A POS device's one-time registration code → its tenant. */
CREATE TABLE ctl.DeviceCode (
    RegistrationCode varchar(20) COLLATE ci NOT NULL CONSTRAINT PK_DeviceCode PRIMARY KEY,
    TenantId         varchar(20) COLLATE ci NOT NULL CONSTRAINT FK_DeviceCode_Tenant REFERENCES ctl.Tenant (TenantId),
    DeviceId         varchar(40) COLLATE ci NOT NULL,
    CreatedAtUtc     timestamp(3) NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
);

/*------------------------------------------------------- plans and features */

CREATE TABLE ctl.Plan (
    PlanKey      varchar(20) COLLATE ci  NOT NULL CONSTRAINT PK_Plan PRIMARY KEY,
    Label        varchar(60) COLLATE ci  NOT NULL,
    IsTrial      boolean           NOT NULL DEFAULT false,
    MonthlyH     bigint        NULL,
    AnnualH      bigint        NULL,
    Branches     integer           NULL,
    Devices      integer           NULL,
    Users        integer           NULL,
    Transactions integer           NULL,
    StorageGb    numeric(9,2)  NULL,
    /* The plan card's bullet points, separated by |. */
    Highlights   varchar(400) COLLATE ci NULL,
    SortOrder    integer           NOT NULL DEFAULT 0,
    IsActive     boolean           NOT NULL DEFAULT true
);

CREATE TABLE ctl.Feature (
    FeatureKey varchar(40) COLLATE ci  NOT NULL CONSTRAINT PK_Feature PRIMARY KEY,
    Label      varchar(80) COLLATE ci  NOT NULL,
    Icon       varchar(40) COLLATE ci  NULL,
    Blurb      varchar(300) COLLATE ci NULL,
    IsCore     boolean           NOT NULL DEFAULT false,
    SortOrder  integer           NOT NULL DEFAULT 0
);

/* What a kind of business COULD use. */
CREATE TABLE ctl.TypeFeature (
    BusinessType varchar(40) COLLATE ci NOT NULL,
    FeatureKey   varchar(40) COLLATE ci NOT NULL CONSTRAINT FK_TypeFeature_Feature REFERENCES ctl.Feature (FeatureKey),
    CONSTRAINT PK_TypeFeature PRIMARY KEY (BusinessType, FeatureKey)
);

/* What a plan INCLUDES for a kind of business, and its limits. */
CREATE TABLE ctl.PlanConfig (
    BusinessType      varchar(40) COLLATE ci NOT NULL,
    PlanKey           varchar(20) COLLATE ci NOT NULL CONSTRAINT FK_PlanConfig_Plan REFERENCES ctl.Plan (PlanKey),
    Users             integer          NULL,
    Devices           integer          NULL,
    Branches          integer          NULL,
    Duration          integer          NOT NULL DEFAULT 12,
    DurationUnit      varchar(10) COLLATE ci NOT NULL DEFAULT 'months',
    AmountH           bigint       NULL,
    Currency          varchar(3) COLLATE ci  NOT NULL DEFAULT 'SAR',
    Status            varchar(10) COLLATE ci NOT NULL DEFAULT 'active',
    CustomBilling     boolean          NOT NULL DEFAULT false,
    AutoRenew         boolean          NOT NULL DEFAULT true,
    RenewalNoticeDays integer          NOT NULL DEFAULT 14,
    UpdatedAtUtc      timestamp(3) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT PK_PlanConfig PRIMARY KEY (BusinessType, PlanKey),
    CONSTRAINT CK_PlanConfig_Unit CHECK (DurationUnit IN ('days', 'weeks', 'months')),
    CONSTRAINT CK_PlanConfig_Status CHECK (Status IN ('active', 'inactive'))
);

CREATE TABLE ctl.PlanConfigFeature (
    BusinessType varchar(40) COLLATE ci NOT NULL,
    PlanKey      varchar(20) COLLATE ci NOT NULL,
    FeatureKey   varchar(40) COLLATE ci NOT NULL CONSTRAINT FK_PlanConfigFeature_Feature REFERENCES ctl.Feature (FeatureKey),
    CONSTRAINT PK_PlanConfigFeature PRIMARY KEY (BusinessType, PlanKey, FeatureKey),
    CONSTRAINT FK_PlanConfigFeature_Config FOREIGN KEY (BusinessType, PlanKey)
        REFERENCES ctl.PlanConfig (BusinessType, PlanKey) ON DELETE CASCADE
);

/*------------------------------------------------ subscriptions and billing */

/* One row per tenant: its current term. Renewals extend it in place and are
   counted; the history is in ctl.Invoice and ctl.AdminAudit. */
CREATE TABLE ctl.Subscription (
    SubscriptionId varchar(20) COLLATE ci  NOT NULL CONSTRAINT PK_Subscription PRIMARY KEY,
    TenantId       varchar(20) COLLATE ci  NOT NULL CONSTRAINT FK_Subscription_Tenant REFERENCES ctl.Tenant (TenantId)
                                          CONSTRAINT UQ_Subscription_Tenant UNIQUE,
    PlanKey        varchar(20) COLLATE ci  NOT NULL CONSTRAINT FK_Subscription_Plan REFERENCES ctl.Plan (PlanKey),
    Cycle          varchar(10) COLLATE ci  NOT NULL DEFAULT 'annual',
    IsTrial        boolean           NOT NULL DEFAULT false,
    TrialDays      integer           NULL,
    StartsOn       date          NOT NULL,
    RenewsOn       date          NOT NULL,
    Status         varchar(20) COLLATE ci  NOT NULL DEFAULT 'active',
    /* Monthly price agreed outside the list price (Enterprise). */
    CustomMonthlyH bigint        NULL,
    Renewals       integer           NOT NULL DEFAULT 0,
    LastRenewedOn  date          NULL,
    CancelledAtUtc timestamp(3)  NULL,
    CancelReason   varchar(400) COLLATE ci NULL,
    CreatedAtUtc   timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    UpdatedAtUtc   timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT CK_Subscription_Cycle CHECK (Cycle IN ('monthly', 'annual')),
    CONSTRAINT CK_Subscription_Status CHECK (Status IN ('active', 'cancelled'))
);

CREATE TABLE ctl.Invoice (
    InvoiceId      varchar(20) COLLATE ci  NOT NULL CONSTRAINT PK_Invoice PRIMARY KEY,
    TenantId       varchar(20) COLLATE ci  NOT NULL CONSTRAINT FK_Invoice_Tenant REFERENCES ctl.Tenant (TenantId),
    SubscriptionId varchar(20) COLLATE ci  NULL,
    PlanKey        varchar(20) COLLATE ci  NOT NULL,
    AmountH        bigint        NOT NULL,
    Method         varchar(30) COLLATE ci  NULL,
    Status         varchar(20) COLLATE ci  NOT NULL DEFAULT 'pending',
    IssuedOn       date          NOT NULL,
    PaidOn         date          NULL,
    PeriodStart    date          NULL,
    PeriodEnd      date          NULL,
    Notes          varchar(400) COLLATE ci NULL,
    CreatedAtUtc   timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT CK_Invoice_Status CHECK (Status IN ('paid', 'pending', 'failed', 'refunded'))
);
CREATE INDEX IX_Invoice_Tenant ON ctl.Invoice (TenantId, IssuedOn DESC);

/*--------------------------------------------------------------- support */

CREATE TABLE ctl.Issue (
    IssueId       varchar(20) COLLATE ci   NOT NULL CONSTRAINT PK_Issue PRIMARY KEY,
    TenantId      varchar(20) COLLATE ci   NOT NULL CONSTRAINT FK_Issue_Tenant REFERENCES ctl.Tenant (TenantId),
    Title         varchar(200) COLLATE ci  NOT NULL,
    Description   varchar(2000) COLLATE ci NULL,
    Priority      varchar(10) COLLATE ci   NOT NULL DEFAULT 'medium',
    Status        varchar(10) COLLATE ci   NOT NULL DEFAULT 'open',
    Assignee      varchar(160) COLLATE ci  NULL,
    OpenedAtUtc   timestamp(3)   NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    ResolvedAtUtc timestamp(3)   NULL,
    CONSTRAINT CK_Issue_Priority CHECK (Priority IN ('high', 'medium', 'low')),
    CONSTRAINT CK_Issue_Status CHECK (Status IN ('open', 'waiting', 'resolved'))
);

CREATE TABLE ctl.SupportSession (
    SessionId    bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 1) NOT NULL CONSTRAINT PK_SupportSession PRIMARY KEY,
    TenantId     varchar(20) COLLATE ci  NOT NULL CONSTRAINT FK_SupportSession_Tenant REFERENCES ctl.Tenant (TenantId),
    AdminId      varchar(40) COLLATE ci  NOT NULL,
    Reason       varchar(400) COLLATE ci NOT NULL,
    StartedAtUtc timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    EndedAtUtc   timestamp(3)  NULL
);

/*---------------------------------------------------------- administrators */

CREATE TABLE ctl.Admin (
    AdminId            varchar(40) COLLATE ci  NOT NULL CONSTRAINT PK_Admin PRIMARY KEY,
    Name               varchar(160) COLLATE ci NOT NULL,
    Mobile             varchar(30) COLLATE ci  NOT NULL CONSTRAINT UQ_Admin_Mobile UNIQUE,
    Email              varchar(160) COLLATE ci NULL,
    Role               varchar(40) COLLATE ci  NOT NULL DEFAULT 'Owner',
    /* Comma-separated navigation keys; NULL means everything. */
    Permissions        varchar(400) COLLATE ci NULL,
    PasswordHash       varchar(400) COLLATE ci NOT NULL,
    PasswordSalt       varchar(200) COLLATE ci NOT NULL,
    Status             varchar(20) COLLATE ci  NOT NULL DEFAULT 'active',
    MustChangePassword boolean           NOT NULL DEFAULT false,
    FailedLogins       integer           NOT NULL DEFAULT 0,
    LockedUntilUtc     timestamp(3)  NULL,
    /* Bumped on a password reset: tokens minted before it stop working. */
    SessionVersion     integer           NOT NULL DEFAULT 1,
    LastLoginAtUtc     timestamp(3)  NULL,
    CreatedAtUtc       timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT CK_Admin_Status CHECK (Status IN ('active', 'suspended'))
);

CREATE TABLE ctl.AdminOtp (
    ChallengeId   varchar(64) COLLATE ci  NOT NULL CONSTRAINT PK_AdminOtp PRIMARY KEY,
    AdminId       varchar(40) COLLATE ci  NOT NULL CONSTRAINT FK_AdminOtp_Admin REFERENCES ctl.Admin (AdminId),
    CodeHash      varchar(400) COLLATE ci NOT NULL,
    CodeSalt      varchar(200) COLLATE ci NOT NULL,
    ExpiresAtUtc  timestamp(3)  NOT NULL,
    Attempts      integer           NOT NULL DEFAULT 0,
    ConsumedAtUtc timestamp(3)  NULL,
    CreatedAtUtc  timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
);

/* Every administrative action, and the reads worth recording. */
CREATE TABLE ctl.AdminAudit (
    AuditId      bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 5001) NOT NULL CONSTRAINT PK_AdminAudit PRIMARY KEY,
    AtUtc        timestamp(3)   NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    AdminId      varchar(40) COLLATE ci   NULL,
    AdminName    varchar(160) COLLATE ci  NULL,
    Action       varchar(60) COLLATE ci   NOT NULL,
    Label        varchar(160) COLLATE ci  NOT NULL,
    TenantId     varchar(20) COLLATE ci   NULL,
    EntityId     varchar(60) COLLATE ci   NULL,
    BeforeValue  varchar(400) COLLATE ci  NULL,
    AfterValue   varchar(400) COLLATE ci  NULL,
    Reason       varchar(400) COLLATE ci  NULL,
    Method       varchar(10) COLLATE ci   NULL,
    Endpoint     varchar(300) COLLATE ci  NULL,
    TableName    varchar(100) COLLATE ci  NULL,
    Operation    varchar(10) COLLATE ci   NULL,
    DurationMs   integer            NULL,
    RowsAffected integer            NULL,
    IpAddress    varchar(60) COLLATE ci   NULL,
    Result       varchar(10) COLLATE ci   NOT NULL DEFAULT 'success',
    ErrorMessage varchar(1000) COLLATE ci NULL
);
CREATE INDEX IX_AdminAudit_Tenant ON ctl.AdminAudit (TenantId, AtUtc DESC);
CREATE INDEX IX_AdminAudit_At ON ctl.AdminAudit (AtUtc DESC);

/* The platform's activity feed: things that happened to tenants. */
CREATE TABLE ctl.PlatformEvent (
    EventId  bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 1) NOT NULL CONSTRAINT PK_PlatformEvent PRIMARY KEY,
    AtUtc    timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    Kind     varchar(40) COLLATE ci  NOT NULL,
    Label    varchar(160) COLLATE ci NOT NULL,
    TenantId varchar(20) COLLATE ci  NULL,
    Detail   varchar(400) COLLATE ci NULL,
    Severity varchar(10) COLLATE ci  NOT NULL DEFAULT 'info'
);
CREATE INDEX IX_PlatformEvent_At ON ctl.PlatformEvent (AtUtc DESC);

/*------------------------------------------------------- hardware register */

CREATE TABLE ctl.HardwareDevice (
    DeviceId        varchar(20) COLLATE ci  NOT NULL CONSTRAINT PK_HardwareDevice PRIMARY KEY,
    Serial          varchar(80) COLLATE ci  NOT NULL CONSTRAINT UQ_HardwareDevice_Serial UNIQUE,
    Manufacturer    varchar(60) COLLATE ci  NULL,
    Model           varchar(60) COLLATE ci  NOT NULL,
    DeviceType      varchar(40) COLLATE ci  NULL,
    Os              varchar(60) COLLATE ci  NULL,
    MacAddress      varchar(17) COLLATE ci  NULL,
    Imei            varchar(20) COLLATE ci  NULL,
    PurchasedOn     date          NULL,
    WarrantyEndsOn  date          NULL,
    WarrantyMonths  integer           NULL,
    Status          varchar(20) COLLATE ci  NOT NULL DEFAULT 'available',
    TenantId        varchar(20) COLLATE ci  NULL CONSTRAINT FK_HardwareDevice_Tenant REFERENCES ctl.Tenant (TenantId),
    BranchId        varchar(40) COLLATE ci  NULL,
    BranchName      varchar(160) COLLATE ci NULL,
    TerminalId      varchar(40) COLLATE ci  NULL,
    InstalledOn     date          NULL,
    LastOnlineAtUtc timestamp(3)  NULL,
    Notes           varchar(1000) COLLATE ci NULL,
    CreatedAtUtc    timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    UpdatedAtUtc    timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT CK_HardwareDevice_Status CHECK (Status IN ('available', 'assigned', 'active', 'suspended', 'retired')),
    /* Assigned, active and suspended belong to someone. */
    CONSTRAINT CK_HardwareDevice_Owner CHECK (Status IN ('available', 'retired') OR TenantId IS NOT NULL)
);

CREATE TABLE ctl.HardwareDeviceEvent (
    EventId  bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 1) NOT NULL CONSTRAINT PK_HardwareDeviceEvent PRIMARY KEY,
    DeviceId varchar(20) COLLATE ci  NOT NULL CONSTRAINT FK_HardwareDeviceEvent_Device REFERENCES ctl.HardwareDevice (DeviceId),
    AtUtc    timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    Event    varchar(80) COLLATE ci  NOT NULL,
    ByName   varchar(160) COLLATE ci NULL,
    Detail   varchar(400) COLLATE ci NULL
);

/*----------------------------------------------- figures read from tenants */

/* The latest snapshot of each tenant, collected by TenantSnapshotService. A
   tenant that cannot be reached keeps its last figures and is marked, not
   zeroed. */
CREATE TABLE ctl.TenantSnapshot (
    TenantId             varchar(20) COLLATE ci   NOT NULL CONSTRAINT PK_TenantSnapshot PRIMARY KEY
                                                 CONSTRAINT FK_TenantSnapshot_Tenant REFERENCES ctl.Tenant (TenantId),
    CollectedAtUtc       timestamp(3)   NOT NULL,
    Reachable            boolean            NOT NULL,
    Error                varchar(1000) COLLATE ci NULL,
    Branches             integer            NOT NULL DEFAULT 0,
    Devices              integer            NOT NULL DEFAULT 0,
    DevicesOnline        integer            NOT NULL DEFAULT 0,
    Users                integer            NOT NULL DEFAULT 0,
    ActiveUsers          integer            NOT NULL DEFAULT 0,
    Transactions         bigint         NOT NULL DEFAULT 0,
    SalesH               bigint         NOT NULL DEFAULT 0,
    TransactionsToday    integer            NOT NULL DEFAULT 0,
    SalesTodayH          bigint         NOT NULL DEFAULT 0,
    TransactionsMonth    integer            NOT NULL DEFAULT 0,
    LoginsToday          integer            NOT NULL DEFAULT 0,
    HeartbeatsToday      integer            NOT NULL DEFAULT 0,
    ApiRequestsToday     integer            NOT NULL DEFAULT 0,
    ApiErrorsToday       integer            NOT NULL DEFAULT 0,
    ApiRequestsMonth     integer            NOT NULL DEFAULT 0,
    ActiveUsersMonth     integer            NOT NULL DEFAULT 0,
    FirstLoginAtUtc      timestamp(3)   NULL,
    LastLoginAtUtc       timestamp(3)   NULL,
    LastTransactionAtUtc timestamp(3)   NULL,
    DbSizeMb             numeric(12,2)  NOT NULL DEFAULT 0,
    DbRows               bigint         NOT NULL DEFAULT 0,
    DbTables             integer            NOT NULL DEFAULT 0,
    LargestTable         varchar(200) COLLATE ci  NULL,
    LargestTableRows     bigint         NOT NULL DEFAULT 0
);

/* Per-day sales, for the analytics charts. */
CREATE TABLE ctl.TenantDailyStat (
    TenantId     varchar(20) COLLATE ci NOT NULL CONSTRAINT FK_TenantDailyStat_Tenant REFERENCES ctl.Tenant (TenantId),
    StatDate     date         NOT NULL,
    Transactions integer          NOT NULL,
    SalesH       bigint       NOT NULL,
    CONSTRAINT PK_TenantDailyStat PRIMARY KEY (TenantId, StatDate)
);

/*------------------------------------------------- master data and settings */

/* cities · services (business types) · payment-methods · deactivation-reasons.
   Extra holds the set's own column: a city's region, a type's icon, a payment
   method's kind. Removing an item deactivates it; whoever uses it keeps it. */
CREATE TABLE ctl.MasterItem (
    SetKey    varchar(40) COLLATE ci  NOT NULL,
    Value     varchar(60) COLLATE ci  NOT NULL,
    Label     varchar(120) COLLATE ci NOT NULL,
    LabelAr   varchar(120) COLLATE ci NULL,
    Extra     varchar(60) COLLATE ci  NULL,
    SortOrder integer           NOT NULL DEFAULT 0,
    IsActive  boolean           NOT NULL DEFAULT true,
    CONSTRAINT PK_MasterItem PRIMARY KEY (SetKey, Value)
);

CREATE TABLE ctl.Setting (
    SettingKey   varchar(60) COLLATE ci  NOT NULL CONSTRAINT PK_Setting PRIMARY KEY,
    Value        varchar(400) COLLATE ci NOT NULL,
    UpdatedAtUtc timestamp(3)  NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    UpdatedBy    varchar(160) COLLATE ci NULL
);

CREATE TABLE ctl.NotificationRule (
    RuleKey   varchar(40) COLLATE ci  NOT NULL CONSTRAINT PK_NotificationRule PRIMARY KEY,
    Label     varchar(160) COLLATE ci NOT NULL,
    Channel   varchar(20) COLLATE ci  NOT NULL,
    IsOn      boolean           NOT NULL DEFAULT true,
    SortOrder integer           NOT NULL DEFAULT 0
);
