/*==============================================================================
  Nazad POS — 023 · Stocktake

  The inventory.stocktake permission existed with nothing behind it. This adds
  the posting: a branch's counted quantities, all in one transaction.

  inv.usp_PostStocktake takes the counted lines (inv.StocktakeLineTable) for a
  branch and, for every line whose count differs from the system quantity:
    - sets the stock level to the count,
    - writes a 'stocktake' movement carrying the stocktake reference
      (STK-yyyymmdd-XXXXXX) and the reason "Stocktake" / "جرد",
  then posts ONE journal entry for the whole count: shrinkage debits stock
  variance (5200) and credits inventory (1200); a surplus the reverse — the
  same accounts inv.usp_AdjustStock uses for a single adjustment.

  Lines whose count equals the system quantity are skipped. A stocktake in
  which nothing changed is refused (54033) — there is nothing to post, and an
  empty reference in the history would only confuse.

  The count replaces whatever the system holds at the moment of posting: that
  is what a count means. The screen shows the system quantity it loaded, and
  the response lists each line's quantity before and after.

  Errors: 54030 no lines · 54031 negative or duplicate line · 54032 an item
  that is unknown or does not track stock · 54033 nothing changed ·
  54034 unknown or inactive branch.

  Re-runnable: the type only if missing; CREATE OR ALTER.
==============================================================================*/

USE POSMAIN;
GO

IF TYPE_ID(N'inv.StocktakeLineTable') IS NULL
    CREATE TYPE inv.StocktakeLineTable AS TABLE
    (
        ItemId          NVARCHAR(40)  NOT NULL,
        CountedQuantity DECIMAL(18,3) NOT NULL
    );
GO

CREATE OR ALTER PROCEDURE inv.usp_PostStocktake
    @BranchId  NVARCHAR(40),
    @Lines     inv.StocktakeLineTable READONLY,
    @Note      NVARCHAR(400) = NULL,
    @Actor     NVARCHAR(120),
    @Reference NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId AND IsActive = 1)
        THROW 54034, N'Unknown or inactive branch.', 1;

    IF NOT EXISTS (SELECT 1 FROM @Lines)
        THROW 54030, N'A stocktake needs at least one counted line.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE CountedQuantity < 0)
       OR EXISTS (SELECT ItemId FROM @Lines GROUP BY ItemId HAVING COUNT(*) > 1)
        THROW 54031, N'Counts cannot be negative, and each item is counted once.', 1;

    IF EXISTS (SELECT 1 FROM @Lines AS l
               LEFT JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId AND i.TracksStock = 1
               WHERE i.ItemId IS NULL)
        THROW 54032, N'Only items that track stock can be counted.', 1;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRAN;

        /* Every counted item gets a stock row, so "no row" and "zero" are the same. */
        INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
        SELECT l.ItemId, @BranchId, 0
        FROM @Lines AS l
        WHERE NOT EXISTS (SELECT 1 FROM inv.StockLevel AS s
                          WHERE s.ItemId = l.ItemId AND s.BranchId = @BranchId);

        /* Read the system quantities under an update lock, so a sale cannot
           move them between reading and writing. */
        DECLARE @Diff TABLE
        (
            ItemId    NVARCHAR(40)  NOT NULL PRIMARY KEY,
            OldQty    DECIMAL(18,3) NOT NULL,
            NewQty    DECIMAL(18,3) NOT NULL,
            CostH     BIGINT        NOT NULL
        );

        INSERT INTO @Diff (ItemId, OldQty, NewQty, CostH)
        SELECT l.ItemId, s.Quantity, l.CountedQuantity, i.CostH
        FROM @Lines AS l
        JOIN inv.StockLevel AS s WITH (UPDLOCK, HOLDLOCK)
             ON s.ItemId = l.ItemId AND s.BranchId = @BranchId
        JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
        WHERE s.Quantity <> l.CountedQuantity;

        IF NOT EXISTS (SELECT 1 FROM @Diff)
            THROW 54033, N'Nothing changed: every count matches the system quantity.', 1;

        SET @Reference = CONCAT(N'STK-', FORMAT(DATEADD(HOUR, 3, @Now), N'yyyyMMdd'), N'-',
                                UPPER(LEFT(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''), 6)));

        DECLARE @ReasonEn NVARCHAR(400) =
            LEFT(CONCAT(N'Stocktake ', @Reference, ISNULL(N' — ' + NULLIF(LTRIM(RTRIM(@Note)), N''), N'')), 400);
        DECLARE @ReasonAr NVARCHAR(400) =
            LEFT(CONCAT(N'جرد ', @Reference, ISNULL(N' — ' + NULLIF(LTRIM(RTRIM(@Note)), N''), N'')), 400);

        UPDATE s
        SET Quantity = d.NewQty, UpdatedAtUtc = @Now
        FROM inv.StockLevel AS s
        JOIN @Diff AS d ON d.ItemId = s.ItemId
        WHERE s.BranchId = @BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, OccurredAtUtc, Actor)
        SELECT d.ItemId, @BranchId, N'stocktake', d.NewQty - d.OldQty, d.NewQty, d.CostH,
               @Reference, @ReasonEn, @ReasonAr, @Now, @Actor
        FROM @Diff AS d;

        /* One entry for the whole count: what was lost, and what was found. */
        DECLARE @LossH BIGINT = ISNULL((SELECT SUM(CAST(ROUND((OldQty - NewQty) * CostH, 0) AS BIGINT))
                                        FROM @Diff WHERE NewQty < OldQty), 0);
        DECLARE @GainH BIGINT = ISNULL((SELECT SUM(CAST(ROUND((NewQty - OldQty) * CostH, 0) AS BIGINT))
                                        FROM @Diff WHERE NewQty > OldQty), 0);

        IF @LossH > 0 OR @GainH > 0
        BEGIN
            DECLARE @Entry fin.JournalLineTable;

            IF @LossH > 0
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'5200', @LossH, 0, N'Stock variance — stocktake shrinkage'),
                    (N'1200', 0, @LossH, N'Inventory');

            IF @GainH > 0
                INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
                    (N'1200', @GainH, 0, N'Inventory'),
                    (N'5200', 0, @GainH, N'Stock variance — stocktake surplus');

            DECLARE @EntryId NVARCHAR(40);
            EXEC fin.usp_PostJournalEntry
                @Kind = N'stock_adjustment', @DescriptionEn = @ReasonEn,
                @DescriptionAr = @ReasonAr, @SourceReference = @Reference,
                @BranchId = @BranchId, @Actor = @Actor,
                @Lines = @Entry, @EntryId = @EntryId OUTPUT;
        END

    COMMIT;

    /* What changed, for the screen's summary. */
    SELECT d.ItemId, i.NameAr, i.NameEn, i.Sku, d.OldQty AS SystemQuantity,
           d.NewQty AS CountedQuantity, d.NewQty - d.OldQty AS Difference,
           CAST(ROUND((d.NewQty - d.OldQty) * d.CostH, 0) AS BIGINT) AS ValueH
    FROM @Diff AS d
    JOIN core.CatalogItem AS i ON i.ItemId = d.ItemId
    ORDER BY i.NameEn;
END
GO
