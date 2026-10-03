/*==============================================================================
  Nazad POS — 999 · Verify the install

  Read-only. apply-migrations.cmd runs it after every apply; run it by hand
  whenever something is not working and you want to know whether the database
  is the cause. Each line prints PASS, FAIL or INFO.

  FAIL is something every install must have: the full schema from 001, the
  reference data from 002, a balanced ledger, Arabic stored intact.
  INFO is business data, which a new install does not have until the first
  owner registers (or 900 loads the demo).
==============================================================================*/

USE POSMAIN;
GO

SET NOCOUNT ON;

PRINT N'';
PRINT N'--- Schema (001) ------------------------------------------------------';

SELECT CASE WHEN COUNT(*) >= 62 THEN N'PASS' ELSE N'FAIL' END
       + N'  Tables: ' + CAST(COUNT(*) AS NVARCHAR(10)) + N' (expected 62)' AS Result
FROM sys.tables WHERE is_ms_shipped = 0 AND name <> N'SchemaMigration';

SELECT CASE WHEN COUNT(*) >= 58 THEN N'PASS' ELSE N'FAIL' END
       + N'  Procedures: ' + CAST(COUNT(*) AS NVARCHAR(10)) + N' (expected 58)' AS Result
FROM sys.procedures WHERE is_ms_shipped = 0;

SELECT CASE WHEN COUNT(*) >= 9 THEN N'PASS' ELSE N'FAIL' END
       + N'  Views: ' + CAST(COUNT(*) AS NVARCHAR(10)) + N' (expected 9)' AS Result
FROM sys.views WHERE is_ms_shipped = 0;

SELECT CASE WHEN COUNT(*) >= 9 THEN N'PASS' ELSE N'FAIL' END
       + N'  Sequences: ' + CAST(COUNT(*) AS NVARCHAR(10)) + N' (expected 9)' AS Result
FROM sys.sequences;

/* The API cannot sign anyone in, or sell anything, without these. */
SELECT CASE WHEN COUNT(*) = 4 THEN N'PASS' ELSE N'FAIL' END
       + N'  Core procedures present (' + CAST(COUNT(*) AS NVARCHAR(10)) + N'/4)' AS Result
FROM sys.procedures
WHERE SCHEMA_NAME(schema_id) + N'.' + name IN
      (N'sales.usp_CommitSale', N'core.usp_RegisterBusiness',
       N'fin.usp_PostJournalEntry', N'core.usp_SaveUser');

/* The latest sale commit balances cash and change (it declares @CashDueH). */
SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID(N'sales.usp_CommitSale')) LIKE N'%@CashDueH%'
            THEN N'PASS  Sale commit is the current version'
            ELSE N'FAIL  Sale commit is an old version — the schema is out of date' END AS Result;

PRINT N'';
PRINT N'--- Reference data (002) ----------------------------------------------';

SELECT CASE WHEN COUNT(*) >= 23 THEN N'PASS' ELSE N'FAIL' END
       + N'  Chart of accounts: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM fin.Account;

SELECT CASE WHEN COUNT(*) >= 77 THEN N'PASS' ELSE N'FAIL' END
       + N'  Permission keys: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.Permission;

SELECT CASE WHEN COUNT(*) >= 6 THEN N'PASS' ELSE N'FAIL' END
       + N'  Built-in roles: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.Role WHERE IsBuiltIn = 1;

/* The owner role must hold every key, or the first owner is locked out of
   whatever is missing. */
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM core.Permission AS p
                             WHERE NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                                               WHERE rp.RoleId = N'rol_owner'
                                                 AND rp.PermissionKey = p.PermissionKey))
            THEN N'PASS  Owner role holds every permission'
            ELSE N'FAIL  Owner role is missing permissions' END AS Result;

SELECT CASE WHEN EXISTS (SELECT 1 FROM core.BillTemplate
                         WHERE Audience = N'customer' AND IsDefault = 1 AND IsActive = 1)
            THEN N'PASS  Default customer bill present'
            ELSE N'FAIL  No default customer bill — the till cannot print a receipt' END AS Result;

PRINT N'';
PRINT N'--- Integrity --------------------------------------------------------';

/* If the ledger does not balance, something bypassed the posting procedure. */
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM fin.vw_TrialBalanceCheck)
            THEN N'PASS  Ledger balances'
            ELSE N'FAIL  LEDGER DOES NOT BALANCE — investigate before trading' END AS Result;

/* Arabic must survive the round trip. Compared under a binary collation:
   under Arabic_CI_AS a [؀-ۿ] range follows dictionary order, not code points,
   and reported intact text as damaged. */
SELECT CASE WHEN EXISTS (SELECT 1 FROM core.Language
                         WHERE Code = N'ar'
                           AND NameNative COLLATE Latin1_General_BIN2 LIKE N'%[؀-ۿ]%')
            THEN N'PASS  Arabic text stored correctly'
            ELSE N'FAIL  Arabic text is damaged — the script was not read as UTF-8 (sqlcmd -f 65001)' END AS Result;

PRINT N'';
PRINT N'--- Business data (INFO: none until the first owner registers) -------';

SELECT N'INFO  Companies: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result FROM core.Company;
SELECT N'INFO  Active branches: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result FROM core.Branch WHERE IsActive = 1;
SELECT N'INFO  Active owners: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.AppUser WHERE RoleId = N'rol_owner' AND Status = N'active';
SELECT N'INFO  Owners able to sign in with a password: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.AppUser WHERE RoleId = N'rol_owner' AND Status = N'active' AND PasswordHash IS NOT NULL;
SELECT N'INFO  Active catalog items: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result FROM core.CatalogItem WHERE IsActive = 1;
GO
