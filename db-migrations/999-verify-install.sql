/*==============================================================================
  Nazad POS — 999 · Verify the install

  Read-only. apply-migrations.sh / .cmd run it after every apply; run it by
  hand whenever something is not working and you want to know whether the
  database is the cause:

      psql -d posmain -f db-migrations/999-verify-install.sql

  Each line says PASS, FAIL or INFO.

  FAIL is something every install must have: the full schema from 001, the
  database functions from 010-019, the reference data from 002, a balanced
  ledger, Arabic stored intact.
  INFO is business data, which a new install does not have until the first
  owner registers (or 900 loads the demo).

  One statement, a SELECT: nothing here writes, so it is safe on a live
  database at any time. (The scripts also run it in a read-only session.)
==============================================================================*/

WITH Checks (Ord, Result) AS (

    SELECT 100, '--- Schema (001) ------------------------------------------------------'

    UNION ALL
    SELECT 110, CASE WHEN COUNT(*) >= 64 THEN 'PASS' ELSE 'FAIL' END
                || '  Tables: ' || COUNT(*) || ' (expected 64)'
    FROM pg_tables
    WHERE schemaname IN ('audit', 'core', 'dbo', 'device', 'fin', 'inv', 'sales')
      AND tablename <> 'schemamigration'

    /* Every SQL Server procedure became a function of the same name. */
    UNION ALL
    SELECT 120, CASE WHEN COUNT(*) >= 62 THEN 'PASS' ELSE 'FAIL' END
                || '  Database functions: ' || COUNT(*) || ' (expected 62)'
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('audit', 'core', 'dbo', 'device', 'fin', 'inv', 'sales')
      AND p.proname LIKE 'usp\_%'

    UNION ALL
    SELECT 130, CASE WHEN COUNT(*) >= 9 THEN 'PASS' ELSE 'FAIL' END
                || '  Views: ' || COUNT(*) || ' (expected 9)'
    FROM pg_views
    WHERE schemaname IN ('audit', 'core', 'dbo', 'device', 'fin', 'inv', 'sales')

    /* The numbering sequences, not the ones behind identity columns. Invoice
       numbers come from sales.InvoiceCounter, so there are 8, not 9. */
    UNION ALL
    SELECT 140, CASE WHEN COUNT(*) >= 8 THEN 'PASS' ELSE 'FAIL' END
                || '  Sequences: ' || COUNT(*) || ' (expected 8)'
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE c.relkind = 'S'
      AND n.nspname IN ('audit', 'core', 'dbo', 'device', 'fin', 'inv', 'sales')
      AND NOT EXISTS (SELECT 1 FROM pg_depend AS d WHERE d.objid = c.oid AND d.deptype = 'i')

    /* The API cannot sign anyone in, or sell anything, without these. */
    UNION ALL
    SELECT 150, CASE WHEN COUNT(DISTINCT n.nspname || '.' || p.proname) = 4 THEN 'PASS' ELSE 'FAIL' END
                || '  Core functions present (' || COUNT(DISTINCT n.nspname || '.' || p.proname) || '/4)'
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname || '.' || p.proname IN
          ('sales.usp_commitsale', 'core.usp_registerbusiness',
           'fin.usp_postjournalentry', 'core.usp_saveuser')

    /* The latest sale commit balances cash and change (it declares v_CashDueH). */
    UNION ALL
    SELECT 160, CASE WHEN EXISTS (SELECT 1 FROM pg_proc AS p
                                  JOIN pg_namespace AS n ON n.oid = p.pronamespace
                                  WHERE n.nspname = 'sales' AND p.proname = 'usp_commitsale'
                                    AND p.prosrc ILIKE '%v_CashDueH%')
                     THEN 'PASS  Sale commit is the current version'
                     ELSE 'FAIL  Sale commit is an old version — the schema is out of date' END

    UNION ALL
    SELECT 200, ''
    UNION ALL
    SELECT 201, '--- Reference data (002) ----------------------------------------------'

    UNION ALL
    SELECT 210, CASE WHEN COUNT(*) >= 23 THEN 'PASS' ELSE 'FAIL' END
                || '  Chart of accounts: ' || COUNT(*)
    FROM fin.Account

    UNION ALL
    SELECT 220, CASE WHEN COUNT(*) >= 77 THEN 'PASS' ELSE 'FAIL' END
                || '  Permission keys: ' || COUNT(*)
    FROM core.Permission

    UNION ALL
    SELECT 230, CASE WHEN COUNT(*) >= 6 THEN 'PASS' ELSE 'FAIL' END
                || '  Built-in roles: ' || COUNT(*)
    FROM core.Role WHERE IsBuiltIn

    /* The owner role must hold every key, or the first owner is locked out of
       whatever is missing. */
    UNION ALL
    SELECT 240, CASE WHEN NOT EXISTS (SELECT 1 FROM core.Permission AS p
                                      WHERE NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                                                        WHERE rp.RoleId = 'rol_owner'
                                                          AND rp.PermissionKey = p.PermissionKey))
                     THEN 'PASS  Owner role holds every permission'
                     ELSE 'FAIL  Owner role is missing permissions' END

    UNION ALL
    SELECT 250, CASE WHEN EXISTS (SELECT 1 FROM core.BillTemplate
                                  WHERE Audience = 'customer' AND IsDefault AND IsActive)
                     THEN 'PASS  Default customer bill present'
                     ELSE 'FAIL  No default customer bill — the till cannot print a receipt' END

    UNION ALL
    SELECT 260, CASE WHEN EXISTS (SELECT 1 FROM sales.InvoiceCounter WHERE CounterKey = 'invoice')
                     THEN 'PASS  Invoice counter present'
                     ELSE 'FAIL  No invoice counter — the till cannot number a sale' END

    UNION ALL
    SELECT 300, ''
    UNION ALL
    SELECT 301, '--- Integrity --------------------------------------------------------'

    /* If the ledger does not balance, something bypassed the posting function. */
    UNION ALL
    SELECT 310, CASE WHEN NOT EXISTS (SELECT 1 FROM fin.vw_TrialBalanceCheck)
                     THEN 'PASS  Ledger balances'
                     ELSE 'FAIL  LEDGER DOES NOT BALANCE — investigate before trading' END

    /* Arabic must survive the round trip. Compared under the C collation, so
       the range is code points (U+0600 to U+06FF), not dictionary order, and
       because a regular expression refuses the ci collation. */
    UNION ALL
    SELECT 320, CASE WHEN EXISTS (SELECT 1 FROM core.Language
                                  WHERE Code = 'ar'
                                    AND NameNative COLLATE "C" ~ '[؀-ۿ]')
                     THEN 'PASS  Arabic text stored correctly'
                     ELSE 'FAIL  Arabic text is damaged — the script was not read as UTF-8 (PGCLIENTENCODING=UTF8)' END

    UNION ALL
    SELECT 330, CASE WHEN pg_encoding_to_char(encoding) = 'UTF8'
                     THEN 'PASS  Database encoding is UTF8'
                     ELSE 'FAIL  Database encoding is ' || pg_encoding_to_char(encoding)
                          || ' — Arabic cannot be stored; recreate it with ENCODING ''UTF8'' TEMPLATE template0' END
    FROM pg_database WHERE datname = current_database()

    UNION ALL
    SELECT 400, ''
    UNION ALL
    SELECT 401, '--- Business data (INFO: none until the first owner registers) -------'

    UNION ALL
    SELECT 410, 'INFO  Companies: ' || COUNT(*) FROM core.Company
    UNION ALL
    SELECT 420, 'INFO  Active branches: ' || COUNT(*) FROM core.Branch WHERE IsActive
    UNION ALL
    SELECT 430, 'INFO  Active owners: ' || COUNT(*)
    FROM core.AppUser WHERE RoleId = 'rol_owner' AND Status = 'active'
    UNION ALL
    SELECT 440, 'INFO  Owners able to sign in with a password: ' || COUNT(*)
    FROM core.AppUser WHERE RoleId = 'rol_owner' AND Status = 'active' AND PasswordHash IS NOT NULL
    UNION ALL
    SELECT 450, 'INFO  Active catalog items: ' || COUNT(*) FROM core.CatalogItem WHERE IsActive
)
SELECT Result FROM Checks ORDER BY Ord;
