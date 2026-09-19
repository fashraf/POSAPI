/*==============================================================================
  Nazad POS — 19 · Audit trail and request telemetry

  Two tables that record what happened and how long it took.

  Both are written outside the transaction of the work they describe. An audit
  row that rolls back with a failed sale records nothing about the attempt, and
  a failed attempt is often the thing worth seeing.
==============================================================================*/

USE POSMAIN;
GO

IF SCHEMA_ID(N'audit') IS NULL EXEC(N'CREATE SCHEMA audit');
GO

/*------------------------------------------------------------------- audit */

CREATE TABLE audit.AuditEntry
(
    AuditId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditEntry PRIMARY KEY,

    /* Who. The name is copied, not joined: an audit row must still read
       correctly after the account is renamed or removed. */
    UserId          NVARCHAR(40)   NULL,
    Username        NVARCHAR(120)  NULL,
    RoleId          NVARCHAR(40)   NULL,

    /* What. */
    Action          NVARCHAR(30)   NOT NULL,
    Module          NVARCHAR(60)   NOT NULL,
    EntityType      NVARCHAR(60)   NULL,
    EntityId        NVARCHAR(80)   NULL,

    /* Where from. */
    ApiPath         NVARCHAR(300)  NULL,
    HttpMethod      NVARCHAR(10)   NULL,
    CurrentPage     NVARCHAR(200)  NULL,
    PreviousPage    NVARCHAR(200)  NULL,
    BranchId        NVARCHAR(40)   NULL,

    /* What changed. JSON, and only for the fields that moved — storing whole
       rows makes the table enormous and the diff unreadable. */
    OldValue        NVARCHAR(MAX)  NULL,
    NewValue        NVARCHAR(MAX)  NULL,
    Details         NVARCHAR(MAX)  NULL,

    /* How it went. Failures are recorded too; an audit trail of successes only
       hides exactly the attempts worth reviewing. */
    Result          NVARCHAR(20)   NOT NULL CONSTRAINT DF_Audit_Result DEFAULT (N'success'),
    StatusCode      INT            NULL,
    ErrorMessage    NVARCHAR(600)  NULL,

    IpAddress       NVARCHAR(60)   NULL,
    UserAgent       NVARCHAR(400)  NULL,
    CorrelationId   NVARCHAR(40)   NULL,

    OccurredAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_Audit_At DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_Audit_Action CHECK (Action IN
        (N'CREATE', N'UPDATE', N'DELETE', N'VIEW', N'LOGIN', N'LOGOUT',
         N'PAYMENT', N'STATUS_CHANGE', N'VOID', N'REVERSE', N'EXPORT', N'LOGIN_FAILED')),
    CONSTRAINT CK_Audit_Result CHECK (Result IN (N'success', N'failure', N'denied'))
);
GO

/* The filters the audit page offers, each backed by an index. */
CREATE INDEX IX_Audit_Time   ON audit.AuditEntry (OccurredAtUtc DESC)
    INCLUDE (UserId, Action, Module, Result);
CREATE INDEX IX_Audit_User   ON audit.AuditEntry (UserId, OccurredAtUtc DESC);
CREATE INDEX IX_Audit_Entity ON audit.AuditEntry (EntityType, EntityId, OccurredAtUtc DESC);
CREATE INDEX IX_Audit_Module ON audit.AuditEntry (Module, OccurredAtUtc DESC);
GO

/*------------------------------------------------------------- performance */

CREATE TABLE audit.RequestTiming
(
    TimingId        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_RequestTiming PRIMARY KEY,

    CorrelationId   NVARCHAR(40)   NOT NULL,
    UserId          NVARCHAR(40)   NULL,
    Username        NVARCHAR(120)  NULL,

    ApiPath         NVARCHAR(300)  NOT NULL,
    HttpMethod      NVARCHAR(10)   NOT NULL,
    CurrentPage     NVARCHAR(200)  NULL,
    PreviousPage    NVARCHAR(200)  NULL,

    /* Milliseconds. Seconds are derived on read rather than stored, because two
       columns holding the same measurement drift apart the moment one is
       written and the other is not. */
    TotalMs         INT            NOT NULL,
    DatabaseMs      INT            NOT NULL CONSTRAINT DF_Timing_Db DEFAULT (0),
    QueryCount      INT            NOT NULL CONSTRAINT DF_Timing_Count DEFAULT (0),

    StatusCode      INT            NOT NULL,
    Succeeded       BIT            NOT NULL,
    ErrorMessage    NVARCHAR(600)  NULL,
    ResponseBytes   INT            NULL,

    OccurredAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_Timing_At DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_Timing_Ms CHECK (TotalMs >= 0 AND DatabaseMs >= 0)
);
GO

CREATE INDEX IX_Timing_Time ON audit.RequestTiming (OccurredAtUtc DESC)
    INCLUDE (ApiPath, TotalMs, StatusCode);
CREATE INDEX IX_Timing_Slow ON audit.RequestTiming (TotalMs DESC)
    INCLUDE (ApiPath, HttpMethod, OccurredAtUtc);
GO

/*
  The statements a request ran.

  Parameter VALUES are never stored — only names. A query log holding the values
  would contain card references, phone numbers and every password reset token
  that ever went through a WHERE clause, which is a second copy of the sensitive
  data in a table nobody thinks of as sensitive.
*/
CREATE TABLE audit.QueryTiming
(
    QueryTimingId   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_QueryTiming PRIMARY KEY,
    CorrelationId   NVARCHAR(40)   NOT NULL,
    QueryType       NVARCHAR(20)   NOT NULL,
    /* Statement text with literals stripped. */
    CommandText     NVARCHAR(2000) NOT NULL,
    ParameterNames  NVARCHAR(600)  NULL,
    DurationMs      INT            NOT NULL,
    RowsAffected    INT            NULL,
    Succeeded       BIT            NOT NULL CONSTRAINT DF_QueryTiming_Ok DEFAULT (1),
    OccurredAtUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_QueryTiming_At DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT CK_QueryTiming_Type CHECK (QueryType IN
        (N'SELECT', N'INSERT', N'UPDATE', N'DELETE', N'PROCEDURE', N'OTHER')),
    CONSTRAINT CK_QueryTiming_Ms CHECK (DurationMs >= 0)
);
GO

CREATE INDEX IX_QueryTiming_Correlation ON audit.QueryTiming (CorrelationId);
CREATE INDEX IX_QueryTiming_Slow ON audit.QueryTiming (DurationMs DESC)
    INCLUDE (CommandText, OccurredAtUtc);
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

PRINT N'19 · Audit and performance ready.';
GO

/*==============================================================================
  Permissions

  An endpoint gated on a permission that does not exist is unreachable for every
  user, including the owner — the policy resolves to a requirement nobody holds.
  Seeding them is part of shipping the feature, not a follow-up.
==============================================================================*/

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
SELECT v.PermissionKey, v.Module, v.Action, v.Sensitivity
FROM (VALUES
    (N'audit.view',        N'audit', N'view',        N'personal'),
    (N'audit.performance', N'audit', N'performance', N'general')
) AS v (PermissionKey, Module, Action, Sensitivity)
WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p
                  WHERE p.PermissionKey = v.PermissionKey);
GO

/* The owner sees everything. */
INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT N'rol_owner', p.PermissionKey
FROM core.Permission AS p
WHERE p.PermissionKey IN (N'audit.view', N'audit.performance')
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                  WHERE rp.RoleId = N'rol_owner' AND rp.PermissionKey = p.PermissionKey);

/* A manager gets performance but not the audit trail: the trail records who did
   what, which is staff conduct, and that belongs with the owner. */
INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT N'rol_manager', N'audit.performance'
WHERE NOT EXISTS (SELECT 1 FROM core.RolePermission
                  WHERE RoleId = N'rol_manager' AND PermissionKey = N'audit.performance');
GO

SELECT
    CASE WHEN COUNT(*) = 2 THEN N'PASS' ELSE N'FAIL' END
    + N'  Audit permissions seeded (' + CAST(COUNT(*) AS NVARCHAR(10)) + N'/2)' AS Result
FROM core.Permission WHERE PermissionKey LIKE N'audit.%';
GO
