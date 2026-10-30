# Database migrations (PostgreSQL 16)

Every tenant database is built from these files. The API applies them itself: when it provisions a tenant, and to every tenant at startup (`Tenancy:MigrateTenantsOnStartup`). `apply-migrations.sh` does the same from a shell, for the demo database `posmain`. Both record each file in `dbo.SchemaMigration`, so either can update a database the other built.

| File | What it is |
|---|---|
| `001-schema.sql` | Tables, keys, checks, indexes, sequences, list types |
| `002-reference-data.sql` | Languages, permissions, roles and grants, chart of accounts, expense categories, invoice counter, default bill |
| `003-functions-views.sql` | Helper functions and views |
| `010`–`019` | The database functions the API calls (one file per schema) |
| `020`–`899` | Later changes, once each, in order |
| `900-demo-data.sql` | Demo company, branches, staff (password `1234`), catalog and history — `apply-migrations.sh --demo` only |
| `999-verify-install.sql` | Read-only health check |

Each file runs in one transaction. PostgreSQL rolls DDL back too, so a file that fails leaves the database as it was before that file.

## Adding a change

1. Create the next number, e.g. `020-loyalty-points.sql`. Never edit a file that has run anywhere: its name is recorded, and the edit would reach no existing database.
2. Write it so it is safe to run twice (`CREATE OR REPLACE FUNCTION`, `ADD COLUMN IF NOT EXISTS`, `ON CONFLICT DO NOTHING`). The runner runs it once, but someone will run it by hand.
3. Do not name the database. The runner connects to the right one.

## Conventions

These came from SQL Server; they keep the API's SQL and its behaviour the same.

**Names.** Unquoted PascalCase: `SELECT SaleId FROM sales.Sale`. PostgreSQL folds unquoted names to lower case, so the table is `sales.sale` and the column `saleid`. Dapper matches columns to properties ignoring case, so `saleid` still fills `SaleId`. Never quote a name: `"SaleId"` is a different, non-existent column.

**Text is case-insensitive.** Short text columns are `varchar(n) COLLATE ci`, an ICU collation that ignores case but not accents (as `Arabic_CI_AS` did). `=`, `IN`, unique keys, `GROUP BY` and `ORDER BY` ignore case automatically. The cost: `LIKE`, `ILIKE`, regular expressions, `replace()`, `strpos()` and `position()` refuse a case-insensitive collation. On a `ci` column write

```sql
WHERE NameEn COLLATE "default" ILIKE @Pattern
```

`ILIKE`, not `LIKE`: once the column's collation is set aside, `ILIKE` is what keeps the search case-insensitive.

**Time.** Timestamps are `timestamp(3)` holding UTC. "Now" is `now() AT TIME ZONE 'utc'`; today is `(now() AT TIME ZONE 'utc')::date`. The API sends every `DateTime` as `timestamp` (Npgsql legacy timestamp mode, set at startup) and every connection runs in UTC.

**Booleans** are `boolean`: `WHERE IsActive`, `SET IsActive = false`. `IsActive = 1` is an error.

**Money** is `bigint` halalas. **Quantities** are `numeric(18,3)`.

**Result types must be what the C# reads.** Dapper fills a record through its constructor only when every column's type matches exactly.
- `COUNT(*)` is `bigint`: write `COUNT(*)::int` where the C# field is `int`.
- `SUM` of a `bigint` is `numeric`: write `SUM(AmountH)::bigint`. `SUM` of an `int` is `bigint`.
- `AVG` is `numeric`. SQL Server's integer `AVG` truncated: `trunc(AVG(TotalMs))::int`.

**Lists.** `IN @Ids` becomes `= ANY(@Ids)`. Npgsql sends a C# array as a PostgreSQL array, and Dapper does not expand it.

**Paging.** `OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY` works as written. `TOP (n)` becomes `LIMIT n` at the end.

**Upserts.** `MERGE` becomes `INSERT ... ON CONFLICT (...) DO UPDATE SET Col = EXCLUDED.Col`. `OUTPUT INSERTED.Id` becomes `RETURNING Id`. Sequences: `nextval('fin.ExpenseSequence')`.

## Database functions

Each SQL Server procedure became a PL/pgSQL function with the same schema and name, e.g. `sales.usp_CommitSale`.

```sql
CREATE OR REPLACE FUNCTION sales.usp_CommitSale(
    p_BranchId       text,
    p_CustomerId     text DEFAULT NULL,
    p_DiscountH      bigint DEFAULT 0,
    p_Lines          jsonb DEFAULT '[]',
    ...)
RETURNS TABLE (SaleId varchar, InvoiceNumber varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_Seq bigint;
BEGIN
    ...
    RETURN QUERY SELECT v_SaleId::varchar, v_InvoiceNumber::varchar;
END $$;
```

- **Parameters** are `p_` plus the old name, and locals are `v_` plus the old name. In PL/pgSQL a variable with a column's name makes the column reference ambiguous.
- **Parameter types:** text is `text`, money `bigint`, other whole numbers `integer` (or `bigint` where the C# sends a `long`), quantities and rates `numeric`, flags `boolean`, dates `date`, times `timestamp`. A C# `long` does not convert to an `integer` parameter: the call fails with "function does not exist".
- **OUTPUT parameters** become the columns of `RETURNS TABLE`, with the same names, so the C# reads them as a row. `#variable_conflict use_column` lets those names stay unqualified in queries. Use them only in the final `RETURN QUERY`, and keep the working values in `v_` variables.
- **RETURN QUERY types must match the declared columns exactly.** `varchar` is not `text` and `bigint` is not `integer`: cast in the select list.
- **A procedure that returned a result set** returns `TABLE (...)` the same way. One that returned nothing returns `void`.
- **Called from C# with named arguments**, so parameter order and defaults cannot drift:

  ```csharp
  connection.QuerySingleAsync<(string SaleId, string InvoiceNumber)>(
      "SELECT SaleId, InvoiceNumber FROM sales.usp_CommitSale(p_BranchId => @BranchId, p_Lines => @Lines::jsonb, ...);",
      new { request.BranchId, Lines = DbList.Json(lines) });
  ```

- **List parameters** (SQL Server table types) are `jsonb`, read with the row type of the same name:

  ```sql
  v_Lines := ARRAY(SELECT jsonb_populate_recordset(NULL::sales.SaleLineTable, p_Lines));
  ... FROM unnest(v_Lines) AS l ...
  ```

  `jsonb_populate_recordset` matches keys to the type's lower-case field names. `DbList.Json` writes them that way, and `to_jsonb(array)` does too, for a function that passes a list on to another.
- **Errors.** `THROW 52003, N'Not enough stock.', 1;` becomes

  ```sql
  RAISE EXCEPTION 'Not enough stock.' USING DETAIL = '52003';
  ```

  The API reads the number back with `PostgresException.ErrorNumber()` (`Data/DbErrors.cs`), which also maps a duplicate key to 2627 and a foreign-key failure to 547, as SQL Server numbered them. A `%` in the message must be written `%%`.
- **Transactions.** A function runs inside its caller's transaction and is atomic on its own, so `BEGIN TRAN`, `COMMIT`, `SET XACT_ABORT` and a `TRY/CATCH` that only rolls back all go. A `CATCH` that recovers becomes `BEGIN ... EXCEPTION WHEN unique_violation THEN ... END`, which rolls back just that block. `ERROR_NUMBER() IN (2601, 2627)` is `unique_violation`; rethrow with `RAISE;`.
- **Locks.** `WITH (UPDLOCK, HOLDLOCK)` on a row read becomes `SELECT ... FOR UPDATE`, and an `UPDATE` locks its rows anyway. `UPDATE ... SET @v = Col, Col = Col + 1` becomes `UPDATE ... SET Col = Col + 1 RETURNING Col - 1 INTO v_v`. `HOLDLOCK` guarding "check, then insert" has no PostgreSQL equivalent (no range locks): rely on the unique key, or take `pg_advisory_xact_lock(hashtext('<what>'))`. `sp_getapplock` is `pg_advisory_xact_lock`.
- **SELECT INTO.** `SELECT @a = Col FROM ...` becomes `SELECT Col INTO v_a FROM ...`. When no row matches, PostgreSQL sets `v_a` to NULL, where SQL Server left it unchanged. Where the old code relied on the earlier value, keep it explicitly.
- **Other translations:**

  | T-SQL | PostgreSQL |
  |---|---|
  | `CONCAT(N'sal_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')))` | `core.fn_NewId('sal_')` |
  | `@@ROWCOUNT` | `GET DIAGNOSTICS v_Rows = ROW_COUNT;` or `FOUND` |
  | `STRING_SPLIT(@Csv, N',')` | `unnest(string_to_array(p_Csv, ','))`, trimmed |
  | `DATEADD(DAY, n, d)` | `d + n` (date) or `d + make_interval(days => n)` |
  | `DATEADD(MONTH, n, d)` | `(d + make_interval(months => n))::date`, month-end aware like SQL Server |
  | `DATEDIFF(DAY, a, b)` | `b::date - a::date` |
  | `DATEFROMPARTS(y, m, d)` | `make_date(y, m, d)` |
  | `EOMONTH(d)` | `(date_trunc('month', d) + interval '1 month - 1 day')::date` |
  | `FORMAT(n, 'D4')` | `lpad(n::text, 4, '0')` |
  | Weekday, 0 = Sunday | `extract(dow FROM d)::int` |
  | `CURSOR` / `WHILE` | `FOR r IN SELECT ... LOOP ... END LOOP;` |
  | `ISNULL(a, b)` | `COALESCE(a, b)` |
  | `LEN(s)` | `length(s)` |
  | `s1 + s2` (text) | `s1 \|\| s2` |
