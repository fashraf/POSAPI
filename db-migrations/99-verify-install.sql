/*==============================================================================
  Nazad POS — Verify the install

  Read-only. Run this whenever something is not working and you want to know
  whether the database is the cause. Every line prints PASS or FAIL.
==============================================================================*/

USE POSMAIN;
GO

SET NOCOUNT ON;

PRINT N'';
PRINT N'--- Objects -----------------------------------------------------------';

SELECT
    CASE WHEN COUNT(*) >= 47 THEN N'PASS' ELSE N'FAIL' END + N'  Tables: '
    + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM sys.tables;

SELECT
    CASE WHEN COUNT(*) >= 8 THEN N'PASS' ELSE N'FAIL' END + N'  Procedures: '
    + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM sys.procedures;

/* The API cannot authenticate anyone without these three. */
SELECT
    CASE WHEN COUNT(*) = 3 THEN N'PASS' ELSE N'FAIL' END
    + N'  Auth tables present (' + CAST(COUNT(*) AS NVARCHAR(10)) + N'/3)' AS Result
FROM sys.tables
WHERE name IN (N'OtpChallenge', N'RefreshToken', N'LoginAttempt');

SELECT
    CASE WHEN COUNT(*) = 3 THEN N'PASS' ELSE N'FAIL' END
    + N'  Transaction procedures present (' + CAST(COUNT(*) AS NVARCHAR(10)) + N'/3)' AS Result
FROM sys.procedures
WHERE name IN (N'usp_CommitSale', N'usp_RegisterBusiness', N'usp_PostJournalEntry');

PRINT N'';
PRINT N'--- Sign-in ----------------------------------------------------------';

/* An account with no role, or a role with no permissions, cannot sign in. */
SELECT
    CASE WHEN COUNT(*) >= 1 THEN N'PASS' ELSE N'FAIL' END
    + N'  Active users: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.AppUser WHERE Status = N'active';

SELECT
    CASE WHEN COUNT(*) >= 1 THEN N'PASS' ELSE N'FAIL' END
    + N'  owner@demo.com exists and is active' AS Result
FROM core.AppUser WHERE Email = N'owner@demo.com' AND Status = N'active';

SELECT
    CASE WHEN COUNT(*) > 40 THEN N'PASS' ELSE N'FAIL' END
    + N'  Owner effective permissions: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.vw_EffectivePermission AS p
JOIN core.AppUser AS u ON u.UserId = p.UserId
WHERE u.Email = N'owner@demo.com';

SELECT
    CASE WHEN COUNT(*) >= 1 THEN N'PASS' ELSE N'FAIL' END
    + N'  Owner is assigned to a branch' AS Result
FROM core.UserBranch AS ub
JOIN core.AppUser AS u ON u.UserId = ub.UserId
WHERE u.Email = N'owner@demo.com';

PRINT N'';
PRINT N'--- Data -------------------------------------------------------------';

SELECT
    CASE WHEN COUNT(*) >= 1 THEN N'PASS' ELSE N'FAIL' END
    + N'  Branches: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.Branch WHERE IsActive = 1;

SELECT
    CASE WHEN COUNT(*) >= 1 THEN N'PASS' ELSE N'FAIL' END
    + N'  Catalog items: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.CatalogItem WHERE IsActive = 1;

SELECT
    CASE WHEN COUNT(*) >= 20 THEN N'PASS' ELSE N'FAIL' END
    + N'  Chart of accounts: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM fin.Account;

PRINT N'';
PRINT N'--- Integrity --------------------------------------------------------';

/* If the ledger does not balance, something bypassed the posting procedure. */
SELECT
    CASE WHEN NOT EXISTS (SELECT 1 FROM fin.vw_TrialBalanceCheck)
         THEN N'PASS  Ledger balances'
         ELSE N'FAIL  LEDGER DOES NOT BALANCE — investigate before trading'
    END AS Result;

/* Arabic must survive the round trip. Question marks mean the collation is
   wrong and every Arabic name already stored is damaged. */
SELECT
    CASE WHEN EXISTS (SELECT 1 FROM core.CatalogItem
                      WHERE NameAr LIKE N'%[؀-ۿ]%')
         THEN N'PASS  Arabic text stored correctly'
         ELSE N'FAIL  Arabic text is damaged — check the database collation'
    END AS Result;

PRINT N'';
PRINT N'--- Sample -----------------------------------------------------------';

SELECT TOP (3) ItemId, NameAr, NameEn, PriceH FROM core.CatalogItem ORDER BY ItemId;
GO
