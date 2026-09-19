/*==============================================================================
  Why is the audit or performance page failing?

  Read-only, and safe to run whether or not migration 19 has been applied.

  The row counts use dynamic SQL on purpose. SQL Server resolves object names
  when it compiles a batch, not when it reaches the statement — so a plain
  SELECT from audit.AuditEntry fails at compile time even when guarded by
  IF EXISTS, and takes the whole diagnostic down with it. Dynamic SQL is
  compiled only when it actually runs.
==============================================================================*/

USE POSMAIN;
GO

SET NOCOUNT ON;

DECLARE @tables INT = (
    SELECT COUNT(*) FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE s.name = N'audit'
      AND t.name IN (N'AuditEntry', N'RequestTiming', N'QueryTiming'));

DECLARE @views INT = (
    SELECT COUNT(*) FROM sys.views AS v
    JOIN sys.schemas AS s ON s.schema_id = v.schema_id
    WHERE s.name = N'audit'
      AND v.name IN (N'vw_EndpointPerformance', N'vw_SuspectedNPlusOne'));

DECLARE @perms INT = (
    SELECT COUNT(*) FROM core.Permission
    WHERE PermissionKey IN (N'audit.view', N'audit.performance'));

DECLARE @granted INT = (
    SELECT COUNT(*) FROM core.vw_EffectivePermission AS p
    JOIN core.AppUser AS u ON u.UserId = p.UserId
    WHERE u.Email = N'owner@demo.com'
      AND p.PermissionKey IN (N'audit.view', N'audit.performance'));

PRINT N'';
PRINT N'--- Audit diagnostics -------------------------------------------------';
PRINT N'';

PRINT CASE WHEN @tables = 3
      THEN N'PASS  Audit tables exist (3/3)'
      ELSE N'FAIL  Audit tables missing (' + CAST(@tables AS NVARCHAR(2)) + N'/3)'
      END;

PRINT CASE WHEN @views = 2
      THEN N'PASS  Performance views exist (2/2)'
      ELSE N'FAIL  Performance views missing (' + CAST(@views AS NVARCHAR(2)) + N'/2)'
      END;

PRINT CASE WHEN @perms = 2
      THEN N'PASS  Audit permissions seeded (2/2)'
      ELSE N'FAIL  Audit permissions missing (' + CAST(@perms AS NVARCHAR(2)) + N'/2)'
      END;

PRINT CASE WHEN @granted = 2
      THEN N'PASS  owner@demo.com holds both'
      ELSE N'FAIL  Owner is missing a grant (' + CAST(@granted AS NVARCHAR(2)) + N'/2)'
      END;

/* Row counts only make sense once the tables are there. */
IF @tables = 3
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'
        DECLARE @a INT = (SELECT COUNT(*) FROM audit.AuditEntry);
        DECLARE @t INT = (SELECT COUNT(*) FROM audit.RequestTiming);

        PRINT CASE WHEN @a > 0
              THEN N''PASS  Audit rows captured: '' + CAST(@a AS NVARCHAR(10))
              ELSE N''INFO  No audit rows yet. Restart the API, sign in, re-check.''
              END;

        PRINT CASE WHEN @t > 0
              THEN N''PASS  Timing rows captured: '' + CAST(@t AS NVARCHAR(10))
              ELSE N''INFO  No timing rows yet. Use the app, then refresh.''
              END;';

    EXEC sp_executesql @sql;
END

PRINT N'';
PRINT N'--- What to do --------------------------------------------------------';
PRINT N'';

IF @tables < 3 OR @views < 2
BEGIN
    PRINT N'  Run 19-audit-and-performance.sql. It creates the tables, the views,';
    PRINT N'  the permissions and the role grants, all in one file.';
END
ELSE IF @perms < 2
BEGIN
    PRINT N'  Tables exist but the permissions do not. Re-run the permissions';
    PRINT N'  section at the end of 19-audit-and-performance.sql.';
END
ELSE IF @granted < 2
BEGIN
    PRINT N'  Permissions exist but the owner does not hold them. Re-run the';
    PRINT N'  role-grant section at the end of 19-audit-and-performance.sql.';
END
ELSE
BEGIN
    PRINT N'  The database is ready. If the page still fails, the API is running';
    PRINT N'  a build from before migration 19 — stop it, dotnet build, run again.';
    PRINT N'  Also confirm you are on v1.6.2, which fixes the /api/audit route.';
END

PRINT N'';
GO
