/*==============================================================================
  Nazad POS — What is missing from this database?

  Read-only. Lists every object the API needs, says whether it exists, and names
  the migration that creates it.

  Written because missing objects were being discovered one 500 at a time:
  the API only reports the first thing it could not find, so each fix revealed
  the next. This reports all of them at once.
==============================================================================*/

USE POSMAIN;
GO

SET NOCOUNT ON;

DECLARE @Required TABLE (ObjectName NVARCHAR(200), Migration NVARCHAR(80));

INSERT INTO @Required (ObjectName, Migration) VALUES
    (N'core.appuser', N'nazad-posmain-full.sql'),
    (N'core.billtemplate', N'nazad-posmain-full.sql'),
    (N'core.branch', N'nazad-posmain-full.sql'),
    (N'core.branchsettings', N'nazad-posmain-full.sql'),
    (N'core.catalogitem', N'nazad-posmain-full.sql'),
    (N'core.category', N'nazad-posmain-full.sql'),
    (N'core.company', N'nazad-posmain-full.sql'),
    (N'core.customer', N'nazad-posmain-full.sql'),
    (N'core.fn_text', N'nazad-posmain-full.sql'),
    (N'core.language', N'nazad-posmain-full.sql'),
    (N'core.permission', N'nazad-posmain-full.sql'),
    (N'core.printgroup', N'nazad-posmain-full.sql'),
    (N'core.role', N'nazad-posmain-full.sql'),
    (N'core.rolepermission', N'nazad-posmain-full.sql'),
    (N'core.translation', N'nazad-posmain-full.sql'),
    (N'core.userbranch', N'nazad-posmain-full.sql'),
    (N'core.userpermissionoverride', N'nazad-posmain-full.sql'),
    (N'core.vendor', N'nazad-posmain-full.sql'),
    (N'core.vw_effectivepermission', N'nazad-posmain-full.sql'),
    (N'fin.account', N'nazad-posmain-full.sql'),
    (N'fin.balanceperiod', N'nazad-posmain-full.sql'),
    (N'fin.cardsettlement', N'nazad-posmain-full.sql'),
    (N'fin.commissionentry', N'nazad-posmain-full.sql'),
    (N'fin.commissionrule', N'nazad-posmain-full.sql'),
    (N'fin.commissionruleitem', N'nazad-posmain-full.sql'),
    (N'fin.commissionruleuser', N'nazad-posmain-full.sql'),
    (N'fin.drawersession', N'nazad-posmain-full.sql'),
    (N'fin.expense', N'nazad-posmain-full.sql'),
    (N'fin.expensecategory', N'nazad-posmain-full.sql'),
    (N'fin.expenserecognition', N'nazad-posmain-full.sql'),
    (N'fin.fn_advanceduedate', N'nazad-posmain-full.sql'),
    (N'fin.fn_isdebitnormal', N'nazad-posmain-full.sql'),
    (N'fin.fn_vatfromgross', N'nazad-posmain-full.sql'),
    (N'fin.journalentry', N'nazad-posmain-full.sql'),
    (N'fin.journalline', N'nazad-posmain-full.sql'),
    (N'fin.journallinetable', N'nazad-posmain-full.sql'),
    (N'fin.journalsequence', N'nazad-posmain-full.sql'),
    (N'fin.payrollline', N'nazad-posmain-full.sql'),
    (N'fin.payrollrun', N'nazad-posmain-full.sql'),
    (N'fin.recurringpayment', N'nazad-posmain-full.sql'),
    (N'fin.usp_buildexpenserecognition', N'nazad-posmain-full.sql'),
    (N'fin.usp_postjournalentry', N'nazad-posmain-full.sql'),
    (N'fin.usp_rebuildcustomerbalances', N'nazad-posmain-full.sql'),
    (N'fin.usp_recordsalecommission', N'nazad-posmain-full.sql'),
    (N'fin.usp_reversejournalentry', N'nazad-posmain-full.sql'),
    (N'fin.vw_accountbalance', N'nazad-posmain-full.sql'),
    (N'fin.vw_commissionsummary', N'nazad-posmain-full.sql'),
    (N'fin.vw_receivables', N'nazad-posmain-full.sql'),
    (N'fin.vw_trialbalancecheck', N'nazad-posmain-full.sql'),
    (N'inv.purchase', N'nazad-posmain-full.sql'),
    (N'inv.purchaseline', N'nazad-posmain-full.sql'),
    (N'inv.stocklevel', N'nazad-posmain-full.sql'),
    (N'inv.stockmovement', N'nazad-posmain-full.sql'),
    (N'sales.discount', N'nazad-posmain-full.sql'),
    (N'sales.discountscope', N'nazad-posmain-full.sql'),
    (N'sales.preparationitem', N'nazad-posmain-full.sql'),
    (N'sales.preparationorder', N'nazad-posmain-full.sql'),
    (N'sales.sale', N'nazad-posmain-full.sql'),
    (N'sales.saleline', N'nazad-posmain-full.sql'),
    (N'sales.salepayment', N'nazad-posmain-full.sql'),
    (N'sales.salereturn', N'nazad-posmain-full.sql'),
    (N'sales.salereturnline', N'nazad-posmain-full.sql'),
    (N'core.loginattempt', N'11-api-auth-tables.sql'),
    (N'core.otpchallenge', N'11-api-auth-tables.sql'),
    (N'core.refreshtoken', N'11-api-auth-tables.sql'),
    (N'core.usp_purgeexpiredauth', N'11-api-auth-tables.sql'),
    (N'fin.usp_recordcustomercollection', N'12-sale-commit.sql'),
    (N'sales.invoicesequence', N'12-sale-commit.sql'),
    (N'sales.salelinetable', N'12-sale-commit.sql'),
    (N'sales.salepaymenttable', N'12-sale-commit.sql'),
    (N'sales.usp_commitsale', N'12-sale-commit.sql'),
    (N'sales.usp_voidsale', N'12-sale-commit.sql'),
    (N'core.branchsequence', N'13-registration.sql'),
    (N'core.usp_registerbusiness', N'13-registration.sql'),
    (N'fin.expensesequence', N'14-inventory-procs.sql'),
    (N'fin.usp_recordexpense', N'14-inventory-procs.sql'),
    (N'inv.purchaselinetable', N'14-inventory-procs.sql'),
    (N'inv.purchasesequence', N'14-inventory-procs.sql'),
    (N'inv.usp_adjuststock', N'14-inventory-procs.sql'),
    (N'inv.usp_receivepurchase', N'14-inventory-procs.sql'),
    (N'core.notification', N'15-finance-operations.sql'),
    (N'fin.settlementsequence', N'15-finance-operations.sql'),
    (N'fin.usp_closedrawer', N'15-finance-operations.sql'),
    (N'fin.usp_drawerexpectation', N'15-finance-operations.sql'),
    (N'fin.usp_opendrawer', N'15-finance-operations.sql'),
    (N'fin.usp_recordsettlement', N'15-finance-operations.sql'),
    (N'fin.payrollsequence', N'16-periods-payroll.sql'),
    (N'fin.usp_balanceperiodexpectation', N'16-periods-payroll.sql'),
    (N'fin.usp_closebalanceperiod', N'16-periods-payroll.sql'),
    (N'fin.usp_draftpayroll', N'16-periods-payroll.sql'),
    (N'fin.usp_openbalanceperiod', N'16-periods-payroll.sql'),
    (N'fin.usp_paypayroll', N'16-periods-payroll.sql'),
    (N'fin.usp_recordrecurringinstalment', N'16-periods-payroll.sql'),
    (N'fin.usp_reverseexpense', N'16-periods-payroll.sql'),
    (N'sales.vw_salesummary', N'18-sale-summary-fix.sql'),
    (N'audit.auditentry', N'19-audit-and-performance.sql'),
    (N'audit.querytiming', N'19-audit-and-performance.sql'),
    (N'audit.requesttiming', N'19-audit-and-performance.sql'),
    (N'audit.usp_purgetelemetry', N'19-audit-and-performance.sql'),
    (N'audit.vw_endpointperformance', N'19-audit-and-performance.sql'),
    (N'audit.vw_suspectednplusone', N'19-audit-and-performance.sql');

/*--------------------------------------------------------------- the answer */

;WITH Present AS (
    /* OBJECT_ID finds tables, views, procedures and functions alike. Sequences
       and table types are not objects in that sense, so they are checked
       separately below. */
    SELECT r.ObjectName, r.Migration,
           CASE WHEN OBJECT_ID(r.ObjectName) IS NOT NULL THEN 1 ELSE 0 END AS Found
    FROM @Required AS r
    WHERE r.ObjectName NOT LIKE N'%Sequence'
      AND r.ObjectName NOT LIKE N'%Table'

    UNION ALL

    SELECT r.ObjectName, r.Migration,
           CASE WHEN EXISTS (SELECT 1 FROM sys.sequences AS s
                             JOIN sys.schemas AS sc ON sc.schema_id = s.schema_id
                             WHERE sc.name + N'.' + s.name = r.ObjectName)
                     OR EXISTS (SELECT 1 FROM sys.table_types AS t
                                JOIN sys.schemas AS sc ON sc.schema_id = t.schema_id
                                WHERE sc.name + N'.' + t.name = r.ObjectName)
                THEN 1 ELSE 0 END
    FROM @Required AS r
    WHERE r.ObjectName LIKE N'%Sequence' OR r.ObjectName LIKE N'%Table'
)
SELECT
    Migration                                   AS [Run this migration],
    COUNT(*)                                    AS [Objects it creates],
    SUM(Found)                                  AS [Already present],
    COUNT(*) - SUM(Found)                       AS [Missing],
    CASE WHEN SUM(Found) = COUNT(*) THEN N'OK - already applied'
         WHEN SUM(Found) = 0        THEN N'*** NOT APPLIED - RUN THIS ***'
         ELSE N'*** PARTIALLY APPLIED - RE-RUN ***'
    END                                         AS [Status]
FROM Present
GROUP BY Migration
ORDER BY Migration;

/*------------------------------------------------------- the missing objects */

;WITH Present AS (
    SELECT r.ObjectName, r.Migration,
           CASE WHEN OBJECT_ID(r.ObjectName) IS NOT NULL THEN 1 ELSE 0 END AS Found
    FROM @Required AS r
    WHERE r.ObjectName NOT LIKE N'%Sequence' AND r.ObjectName NOT LIKE N'%Table'
    UNION ALL
    SELECT r.ObjectName, r.Migration,
           CASE WHEN EXISTS (SELECT 1 FROM sys.sequences AS s
                             JOIN sys.schemas AS sc ON sc.schema_id = s.schema_id
                             WHERE sc.name + N'.' + s.name = r.ObjectName)
                     OR EXISTS (SELECT 1 FROM sys.table_types AS t
                                JOIN sys.schemas AS sc ON sc.schema_id = t.schema_id
                                WHERE sc.name + N'.' + t.name = r.ObjectName)
                THEN 1 ELSE 0 END
    FROM @Required AS r
    WHERE r.ObjectName LIKE N'%Sequence' OR r.ObjectName LIKE N'%Table'
)
SELECT Migration AS [From migration], ObjectName AS [Missing object]
FROM Present
WHERE Found = 0
ORDER BY Migration, ObjectName;
GO

PRINT N'';
PRINT N'Run the migrations marked NOT APPLIED, in filename order, then re-run this.';
PRINT N'An empty second result set means the database has everything the API needs.';
GO
