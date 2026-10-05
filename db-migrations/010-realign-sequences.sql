USE POSMAIN;
GO

/*==============================================================================
  Nazad POS — 010 · Realign the numbering sequences

  The first recurring payment recorded on a fresh demo database failed with
  "EXP-401 already exists". 001 creates every sequence at its START WITH value
  (fin.ExpenseSequence at 400), while 900-demo-data.sql inserts rows with
  literal numbers (the demo insurance expense is EXP-401). The second expense
  ever recorded drew 401 and hit the unique key. Databases built by the old
  migration files can be behind in the same way.

  Every sequence except sales.InvoiceSequence (replaced in 003–009) is moved
  to just above the highest number its table already uses. A sequence that is
  already ahead is left alone, so this never hands out a number twice and is
  safe to run any number of times.

  900-demo-data.sql ends with the same block, because it runs after the
  numbered migrations on a new database and inserts the literal rows then.
==============================================================================*/

SET NOCOUNT ON;
GO

DECLARE @Map TABLE
(
    SequenceName SYSNAME       NOT NULL,   -- schema.name
    TableName    NVARCHAR(256) NOT NULL,   -- schema.table
    ColumnName   SYSNAME       NOT NULL,
    Prefix       NVARCHAR(10)  NOT NULL    -- the text before the number
);

INSERT INTO @Map (SequenceName, TableName, ColumnName, Prefix) VALUES
    (N'core.BranchSequence',          N'core.Branch',         N'BranchId',    N'brn_'),
    (N'fin.JournalSequence',          N'fin.JournalEntry',    N'Reference',   N'JE-'),
    (N'fin.JournalSequence',          N'fin.JournalEntry',    N'EntryId',     N'jrn_'),
    (N'fin.SettlementSequence',       N'fin.CardSettlement',  N'Reference',   N'SET-'),
    (N'fin.PayrollSequence',          N'fin.PayrollRun',      N'Reference',   N'PR-'),
    (N'fin.ExpenseSequence',          N'fin.Expense',         N'Reference',   N'EXP-'),
    (N'inv.VendorPaymentSequence',    N'inv.VendorPayment',   N'Reference',   N'VP-'),
    (N'inv.PurchaseSequence',         N'inv.Purchase',        N'Reference',   N'PO-'),
    (N'sales.CreditNoteSequence',     N'sales.SaleReturn',    N'NoteNumber',  N'CN-');

DECLARE @Seq SYSNAME, @Table NVARCHAR(256), @Column SYSNAME, @Prefix NVARCHAR(10),
        @Sql NVARCHAR(MAX), @Like NVARCHAR(20), @MaxUsed BIGINT, @Current BIGINT;

DECLARE map CURSOR LOCAL FAST_FORWARD FOR
    SELECT SequenceName, TableName, ColumnName, Prefix FROM @Map;

OPEN map;
FETCH NEXT FROM map INTO @Seq, @Table, @Column, @Prefix;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(@Table, N'U') IS NOT NULL
       AND EXISTS (SELECT 1 FROM sys.sequences WHERE object_id = OBJECT_ID(@Seq))
    BEGIN
        /* Only values that are the prefix followed by digits alone count:
           anything else (a hand-made reference) was never drawn from it. */
        SET @Sql = N'SELECT @MaxUsed = MAX(TRY_CAST(SUBSTRING(' + QUOTENAME(@Column) + N', '
                 + CAST(LEN(@Prefix) + 1 AS NVARCHAR(10)) + N', 40) AS BIGINT)) FROM '
                 + QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(PARSENAME(@Table, 1))
                 + N' WHERE ' + QUOTENAME(@Column) + N' LIKE @Like'
                 + N' AND SUBSTRING(' + QUOTENAME(@Column) + N', '
                 + CAST(LEN(@Prefix) + 1 AS NVARCHAR(10)) + N', 40) NOT LIKE N''%[^0-9]%'';';

        SET @MaxUsed = NULL;
        SET @Like = @Prefix + N'%';
        EXEC sys.sp_executesql @Sql, N'@Like NVARCHAR(20), @MaxUsed BIGINT OUTPUT',
             @Like = @Like, @MaxUsed = @MaxUsed OUTPUT;

        /* current_value is the last number issued (or the start, if none has
           been). Restarting at MaxUsed + 1 only when that is not already
           ahead keeps every number unique. */
        SELECT @Current = CAST(current_value AS BIGINT)
        FROM sys.sequences WHERE object_id = OBJECT_ID(@Seq);

        IF @MaxUsed IS NOT NULL AND @MaxUsed >= @Current
        BEGIN
            SET @Sql = N'ALTER SEQUENCE ' + QUOTENAME(PARSENAME(@Seq, 2)) + N'.' + QUOTENAME(PARSENAME(@Seq, 1))
                     + N' RESTART WITH ' + CAST(@MaxUsed + 1 AS NVARCHAR(20)) + N';';
            EXEC sys.sp_executesql @Sql;
            PRINT CONCAT(N'    ', @Seq, N' restarted at ', @MaxUsed + 1, N' (', @Table, N'.', @Column, N' uses up to ', @MaxUsed, N').');
        END
    END

    FETCH NEXT FROM map INTO @Seq, @Table, @Column, @Prefix;
END

CLOSE map;
DEALLOCATE map;
GO

PRINT N'010 · Sequences realigned.';
GO
