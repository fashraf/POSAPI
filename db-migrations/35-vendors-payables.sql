/*==============================================================================
  Nazad POS — 35 · Vendors, purchases and payables

  Backs GET/POST/PUT /api/inventory/vendors, POST /api/inventory/vendors/{id}/
  payments, GET /api/inventory/vendors/{id}/ledger and GET
  /api/inventory/purchases.

  Where a vendor's balance lives
    core.Vendor still holds no balance column. What is owed is the unsettled
    part of every purchase not paid on receipt:

        owed = SUM(TotalH - PaidH) over inv.Purchase WHERE PaidOnReceipt = 0

    inv.Purchase.PaidH is new. A payment (inv.VendorPayment) is allocated to
    the vendor's oldest unsettled purchases first — or to one named purchase —
    through inv.VendorPaymentAllocation, and each allocation raises that
    purchase's PaidH in the same transaction. A purchase paid on receipt is
    settled at receipt (PaidH = TotalH). The ledger's 2000 account moves by the
    same amounts, so the two agree by construction:
        receive on credit : Dr 1200 + 1300 / Cr 2000   (unchanged)
        receive paid      : Dr 1200 + 1300 / Cr 1000   (unchanged)
        vendor payment    : Dr 2000 / Cr 1000 (cash) or 1100 (bank, card)

  Schema
    - core.Vendor gains City (the vendor form edits it).
    - inv.Purchase gains PaidH and Note (the receive form has a note).
    - inv.VendorPayment, inv.VendorPaymentAllocation, inv.VendorPaymentSequence.
    - inv.usp_ReceivePurchase takes @Note and settles a paid-on-receipt
      purchase at once. Otherwise unchanged.
    - core.usp_SaveVendor, inv.usp_RecordVendorPayment.

  core.usp_SetActive's vendor guard is updated to count only purchases with
  something still owed — in 38, once every column it touches exists.

  Error numbers 66000–66099.
==============================================================================*/

USE POSMAIN;
GO

/*---------------------------------------------------------------------- schema */

IF COL_LENGTH(N'core.Vendor', N'City') IS NULL
    ALTER TABLE core.Vendor ADD City NVARCHAR(120) NULL;
GO

IF COL_LENGTH(N'inv.Purchase', N'PaidH') IS NULL
    ALTER TABLE inv.Purchase ADD PaidH BIGINT NOT NULL
        CONSTRAINT DF_Purchase_PaidH DEFAULT (0);
GO

IF COL_LENGTH(N'inv.Purchase', N'Note') IS NULL
    ALTER TABLE inv.Purchase ADD Note NVARCHAR(400) NULL;
GO

/* Paid on receipt means settled. Rows from before PaidH existed are backfilled. */
UPDATE inv.Purchase SET PaidH = TotalH WHERE PaidOnReceipt = 1 AND PaidH <> TotalH;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Purchase_PaidH')
    ALTER TABLE inv.Purchase ADD CONSTRAINT CK_Purchase_PaidH
        CHECK (PaidH >= 0 AND PaidH <= TotalH);
GO

IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = N'VendorPaymentSequence'
                                            AND SCHEMA_NAME(schema_id) = N'inv')
    CREATE SEQUENCE inv.VendorPaymentSequence AS BIGINT START WITH 100 INCREMENT BY 1;
GO

IF OBJECT_ID(N'inv.VendorPayment') IS NULL
BEGIN
    CREATE TABLE inv.VendorPayment
    (
        PaymentId    NVARCHAR(40)  NOT NULL CONSTRAINT PK_VendorPayment PRIMARY KEY,
        Reference    NVARCHAR(40)  NOT NULL CONSTRAINT UQ_VendorPayment_Ref UNIQUE,
        VendorId     NVARCHAR(40)  NOT NULL CONSTRAINT FK_VendorPayment_Vendor REFERENCES core.Vendor (VendorId),
        BranchId     NVARCHAR(40)  NULL     CONSTRAINT FK_VendorPayment_Branch REFERENCES core.Branch (BranchId),
        AmountH      BIGINT        NOT NULL CONSTRAINT CK_VendorPayment_Amount CHECK (AmountH > 0),
        Method       NVARCHAR(20)  NOT NULL CONSTRAINT CK_VendorPayment_Method CHECK (Method IN (N'cash', N'card', N'bank')),
        Note         NVARCHAR(400) NULL,
        EntryId      NVARCHAR(40)  NULL     CONSTRAINT FK_VendorPayment_Entry REFERENCES fin.JournalEntry (EntryId),
        PaidAtUtc    DATETIME2(3)  NOT NULL CONSTRAINT DF_VendorPayment_PaidAt DEFAULT (SYSUTCDATETIME()),
        PaidBy       NVARCHAR(120) NOT NULL,
        CreatedAtUtc DATETIME2(3)  NOT NULL CONSTRAINT DF_VendorPayment_Created DEFAULT (SYSUTCDATETIME())
    );

    CREATE INDEX IX_VendorPayment_Vendor ON inv.VendorPayment (VendorId, PaidAtUtc);
END
GO

IF OBJECT_ID(N'inv.VendorPaymentAllocation') IS NULL
BEGIN
    CREATE TABLE inv.VendorPaymentAllocation
    (
        PaymentId  NVARCHAR(40) NOT NULL CONSTRAINT FK_VPA_Payment  REFERENCES inv.VendorPayment (PaymentId),
        PurchaseId NVARCHAR(40) NOT NULL CONSTRAINT FK_VPA_Purchase REFERENCES inv.Purchase (PurchaseId),
        AmountH    BIGINT       NOT NULL CONSTRAINT CK_VPA_Amount CHECK (AmountH > 0),
        CONSTRAINT PK_VendorPaymentAllocation PRIMARY KEY (PaymentId, PurchaseId)
    );

    CREATE INDEX IX_VPA_Purchase ON inv.VendorPaymentAllocation (PurchaseId);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Purchase_Vendor'
                                          AND object_id = OBJECT_ID(N'inv.Purchase'))
    CREATE INDEX IX_Purchase_Vendor ON inv.Purchase (VendorId, ReceivedAtUtc)
        INCLUDE (TotalH, PaidH, PaidOnReceipt);
GO

/*------------------------------------------------------------- save a vendor */

CREATE OR ALTER PROCEDURE core.usp_SaveVendor
    @VendorId        NVARCHAR(40)  = NULL,   -- null creates
    @NameAr          NVARCHAR(160),
    @NameEn          NVARCHAR(160),
    @ContactPerson   NVARCHAR(160) = NULL,
    @Phone           NVARCHAR(30)  = NULL,
    @Email           NVARCHAR(160) = NULL,
    @VatNumber       NVARCHAR(15)  = NULL,
    @City            NVARCHAR(120) = NULL,
    @PaymentTermDays INT           = NULL,   -- null keeps (0 on create)
    @IsActive        BIT           = 1,
    @Actor           NVARCHAR(120),
    @SavedId         NVARCHAR(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NameAr = NULLIF(LTRIM(RTRIM(@NameAr)), N'');
    SET @NameEn = NULLIF(LTRIM(RTRIM(@NameEn)), N'');
    SET @Phone = NULLIF(LTRIM(RTRIM(@Phone)), N'');
    SET @VatNumber = NULLIF(LTRIM(RTRIM(@VatNumber)), N'');

    IF @NameAr IS NULL OR @NameEn IS NULL
        THROW 66000, N'Both names are required.', 1;

    /* The phone is how a missing delivery gets chased. */
    IF @Phone IS NULL
        THROW 66001, N'A phone number is required.', 1;

    IF @VatNumber IS NOT NULL AND (LEN(@VatNumber) <> 15 OR @VatNumber LIKE N'%[^0-9]%')
        THROW 66002, N'A Saudi VAT number is exactly 15 digits.', 1;

    IF @VatNumber IS NOT NULL AND EXISTS (
        SELECT 1 FROM core.Vendor
        WHERE VatNumber = @VatNumber AND (@VendorId IS NULL OR VendorId <> @VendorId))
        THROW 66003, N'Another vendor already uses this VAT number.', 1;

    IF EXISTS (SELECT 1 FROM core.Vendor
               WHERE NameEn = @NameEn AND (@VendorId IS NULL OR VendorId <> @VendorId))
        THROW 66004, N'Another vendor already uses this name.', 1;

    IF @PaymentTermDays < 0
        THROW 66005, N'Payment terms cannot be negative.', 1;

    IF @VendorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.Vendor WHERE VendorId = @VendorId)
        THROW 66006, N'Vendor not found.', 1;

    /* Switching a vendor off while money is owed hides a debt; the same rule
       core.usp_SetActive applies. */
    IF @VendorId IS NOT NULL AND @IsActive = 0 AND EXISTS (
        SELECT 1 FROM core.Vendor WHERE VendorId = @VendorId AND IsActive = 1)
       AND EXISTS (SELECT 1 FROM inv.Purchase
                   WHERE VendorId = @VendorId AND PaidOnReceipt = 0 AND PaidH < TotalH)
        THROW 66007, N'This vendor still has unpaid deliveries.', 1;

    IF @VendorId IS NULL
    BEGIN
        SET @SavedId = CONCAT(N'ven_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

        INSERT INTO core.Vendor
            (VendorId, NameAr, NameEn, ContactPerson, Phone, Email, VatNumber, City,
             PaymentTermDays, IsActive, CreatedBy, UpdatedBy)
        VALUES
            (@SavedId, @NameAr, @NameEn, NULLIF(LTRIM(RTRIM(@ContactPerson)), N''), @Phone,
             NULLIF(LTRIM(RTRIM(@Email)), N''), @VatNumber, NULLIF(LTRIM(RTRIM(@City)), N''),
             ISNULL(@PaymentTermDays, 0), ISNULL(@IsActive, 1), @Actor, @Actor);
    END
    ELSE
    BEGIN
        SET @SavedId = @VendorId;

        UPDATE core.Vendor
        SET NameAr          = @NameAr,
            NameEn          = @NameEn,
            ContactPerson   = NULLIF(LTRIM(RTRIM(@ContactPerson)), N''),
            Phone           = @Phone,
            Email           = NULLIF(LTRIM(RTRIM(@Email)), N''),
            VatNumber       = @VatNumber,
            City            = NULLIF(LTRIM(RTRIM(@City)), N''),
            PaymentTermDays = ISNULL(@PaymentTermDays, PaymentTermDays),
            IsActive        = ISNULL(@IsActive, IsActive),
            UpdatedAtUtc    = SYSUTCDATETIME(),
            UpdatedBy       = @Actor
        WHERE VendorId = @VendorId;
    END
END
GO

/*---------------------------------------------------------- pay a vendor */

/*
  Pay a supplier.

  The amount is allocated to the oldest unsettled purchases first, or only to
  @PurchaseId when one is named. More than is owed is refused: an overpayment
  would leave a debit balance on payables that nothing explains.
*/
CREATE OR ALTER PROCEDURE inv.usp_RecordVendorPayment
    @VendorId   NVARCHAR(40),
    @AmountH    BIGINT,
    @Method     NVARCHAR(20),
    @PurchaseId NVARCHAR(40)  = NULL,
    @BranchId   NVARCHAR(40)  = NULL,
    @Note       NVARCHAR(400) = NULL,
    @Actor      NVARCHAR(120),
    @PaymentId  NVARCHAR(40)  OUTPUT,
    @Reference  NVARCHAR(40)  OUTPUT,
    @EntryId    NVARCHAR(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AmountH IS NULL OR @AmountH <= 0
        THROW 66010, N'A payment must be above zero.', 1;

    IF @Method IS NULL OR @Method NOT IN (N'cash', N'card', N'bank')
        THROW 66013, N'Pay by cash, card or bank.', 1;

    DECLARE @VendorNameEn NVARCHAR(160), @VendorNameAr NVARCHAR(160);
    SELECT @VendorNameEn = NameEn, @VendorNameAr = NameAr FROM core.Vendor WHERE VendorId = @VendorId;

    IF @VendorNameEn IS NULL
        THROW 66011, N'Vendor not found.', 1;

    BEGIN TRAN;

        /* Locked, so two payments at once cannot both settle the same debt. */
        DECLARE @Open TABLE (PurchaseId NVARCHAR(40) PRIMARY KEY, BranchId NVARCHAR(40) NULL,
                             OwedH BIGINT, Seq INT);

        INSERT INTO @Open (PurchaseId, BranchId, OwedH, Seq)
        SELECT p.PurchaseId, p.BranchId, p.TotalH - p.PaidH,
               ROW_NUMBER() OVER (ORDER BY p.ReceivedAtUtc, p.Reference)
        FROM inv.Purchase AS p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.VendorId = @VendorId
          AND p.PaidOnReceipt = 0
          AND p.PaidH < p.TotalH
          AND (@PurchaseId IS NULL OR p.PurchaseId = @PurchaseId);

        IF @PurchaseId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @Open)
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM inv.Purchase WHERE PurchaseId = @PurchaseId AND VendorId = @VendorId)
                THROW 66014, N'That purchase is not from this vendor.', 1;
            ELSE
                THROW 66015, N'That purchase is already settled.', 1;
        END;

        IF @AmountH > ISNULL((SELECT SUM(OwedH) FROM @Open), 0)
            THROW 66012, N'That is more than is owed to this vendor.', 1;

        /* Oldest first: each purchase takes what it still owes, the last one
           takes whatever is left of the payment. */
        DECLARE @Alloc TABLE (PurchaseId NVARCHAR(40) PRIMARY KEY, BranchId NVARCHAR(40) NULL, AmountH BIGINT);

        INSERT INTO @Alloc (PurchaseId, BranchId, AmountH)
        SELECT PurchaseId, BranchId,
               CASE WHEN RunningH <= @AmountH THEN OwedH ELSE @AmountH - (RunningH - OwedH) END
        FROM (SELECT PurchaseId, BranchId, OwedH,
                     SUM(OwedH) OVER (ORDER BY Seq ROWS UNBOUNDED PRECEDING) AS RunningH
              FROM @Open) AS o
        WHERE RunningH - OwedH < @AmountH;

        /* No branch given: the branch of what was settled, when that is one. */
        IF @BranchId IS NULL AND (SELECT COUNT(DISTINCT BranchId) FROM @Alloc) = 1
           AND NOT EXISTS (SELECT 1 FROM @Alloc WHERE BranchId IS NULL)
            SET @BranchId = (SELECT TOP (1) BranchId FROM @Alloc);

        DECLARE @Seq BIGINT = NEXT VALUE FOR inv.VendorPaymentSequence;
        SET @PaymentId = CONCAT(N'vpy_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @Reference = CONCAT(N'VP-', @Seq);

        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'2000', @AmountH, 0, N'Accounts payable'),
            (CASE WHEN @Method = N'cash' THEN N'1000' ELSE N'1100' END, 0, @AmountH, @Method);

        DECLARE @DescEn NVARCHAR(400) = CONCAT(N'Vendor payment ', @Reference, N' — ', @VendorNameEn);
        DECLARE @DescAr NVARCHAR(400) = CONCAT(N'سداد مورد ', @Reference, N' — ', @VendorNameAr);

        EXEC fin.usp_PostJournalEntry
            @Kind            = N'supplier_payment',
            @DescriptionEn   = @DescEn,
            @DescriptionAr   = @DescAr,
            @SourceReference = @Reference,
            @BranchId        = @BranchId,
            @Actor           = @Actor,
            @Lines           = @Entry,
            @EntryId         = @EntryId OUTPUT;

        INSERT INTO inv.VendorPayment
            (PaymentId, Reference, VendorId, BranchId, AmountH, Method, Note, EntryId, PaidBy)
        VALUES
            (@PaymentId, @Reference, @VendorId, @BranchId, @AmountH, @Method,
             NULLIF(LTRIM(RTRIM(@Note)), N''), @EntryId, @Actor);

        INSERT INTO inv.VendorPaymentAllocation (PaymentId, PurchaseId, AmountH)
        SELECT @PaymentId, PurchaseId, AmountH FROM @Alloc WHERE AmountH > 0;

        UPDATE p
        SET PaidH = p.PaidH + a.AmountH
        FROM inv.Purchase AS p
        JOIN @Alloc AS a ON a.PurchaseId = p.PurchaseId;

    COMMIT;
END
GO

/*------------------------------------------------------ receive a delivery */

/*
  Receive a delivery.

  As in 14, plus @Note, and a purchase paid on receipt is settled at once
  (PaidH = TotalH) so it never shows as owed.

  Cost is recalculated as a weighted average rather than overwritten. Taking the
  latest supplier price as the cost makes reported margin lurch every time a
  supplier changes their price, even on stock bought months earlier.
*/
CREATE OR ALTER PROCEDURE inv.usp_ReceivePurchase
    @VendorId      NVARCHAR(40),
    @BranchId      NVARCHAR(40),
    @InvoiceNumber NVARCHAR(60) = NULL,
    @VatRate       DECIMAL(5,2) = 15.00,
    @PaidOnReceipt BIT = 0,
    @ReceivedBy    NVARCHAR(120),
    @Lines         inv.PurchaseLineTable READONLY,
    @PurchaseId    NVARCHAR(40) OUTPUT,
    @Reference     NVARCHAR(40) OUTPUT,
    @Note          NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM @Lines)
        THROW 54000, N'A delivery needs at least one line.', 1;

    IF EXISTS (SELECT 1 FROM @Lines WHERE Quantity <= 0 OR UnitCostH < 0)
        THROW 54001, N'Quantities must be above zero and costs cannot be negative.', 1;

    IF EXISTS (SELECT 1 FROM @Lines AS l
               JOIN core.CatalogItem AS i ON i.ItemId = l.ItemId
               WHERE i.TracksStock = 0)
        THROW 54002, N'A service cannot be received into stock.', 1;

    /* Purchase VAT is added on top of the net supplier price — the opposite
       direction to a retail sale, where it is extracted from the gross. */
    DECLARE @SubtotalH BIGINT = (SELECT SUM(Quantity * UnitCostH) FROM @Lines);
    DECLARE @TaxH      BIGINT = CAST(ROUND(@SubtotalH * @VatRate / 100.0, 0) AS BIGINT);
    DECLARE @TotalH    BIGINT = @SubtotalH + @TaxH;

    BEGIN TRAN;

        DECLARE @Seq BIGINT = NEXT VALUE FOR inv.PurchaseSequence;
        SET @PurchaseId = CONCAT(N'pur_', LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));
        SET @Reference  = CONCAT(N'PO-', @Seq);

        INSERT INTO inv.Purchase
            (PurchaseId, Reference, VendorId, BranchId, InvoiceNumber,
             SubtotalH, TaxH, TotalH, PaidOnReceipt, PaidH, Note, ReceivedBy)
        VALUES
            (@PurchaseId, @Reference, @VendorId, @BranchId, @InvoiceNumber,
             @SubtotalH, @TaxH, @TotalH, @PaidOnReceipt,
             CASE WHEN @PaidOnReceipt = 1 THEN @TotalH ELSE 0 END,
             NULLIF(LTRIM(RTRIM(@Note)), N''), @ReceivedBy);

        INSERT INTO inv.PurchaseLine (PurchaseId, ItemId, Quantity, UnitCostH)
        SELECT @PurchaseId, ItemId, Quantity, UnitCostH FROM @Lines;

        /* Weighted average: (existing value + incoming value) / total units. */
        UPDATE i
        SET CostH = CASE
                        WHEN ISNULL(s.Quantity, 0) + agg.Qty = 0 THEN agg.AvgCost
                        ELSE CAST(
                            (ISNULL(s.Quantity, 0) * i.CostH + agg.Qty * agg.AvgCost)
                            / (ISNULL(s.Quantity, 0) + agg.Qty) AS BIGINT)
                    END,
            UpdatedAtUtc = SYSUTCDATETIME()
        FROM core.CatalogItem AS i
        JOIN (SELECT ItemId, SUM(Quantity) AS Qty,
                     SUM(Quantity * UnitCostH) / NULLIF(SUM(Quantity), 0) AS AvgCost
              FROM @Lines GROUP BY ItemId) AS agg ON agg.ItemId = i.ItemId
        LEFT JOIN inv.StockLevel AS s ON s.ItemId = i.ItemId AND s.BranchId = @BranchId;

        /* Create the stock row if this branch has never held the item. */
        INSERT INTO inv.StockLevel (ItemId, BranchId, Quantity)
        SELECT DISTINCT l.ItemId, @BranchId, 0
        FROM @Lines AS l
        WHERE NOT EXISTS (SELECT 1 FROM inv.StockLevel AS s
                          WHERE s.ItemId = l.ItemId AND s.BranchId = @BranchId);

        UPDATE s
        SET Quantity = s.Quantity + agg.Qty, UpdatedAtUtc = SYSUTCDATETIME()
        FROM inv.StockLevel AS s
        JOIN (SELECT ItemId, SUM(Quantity) AS Qty FROM @Lines GROUP BY ItemId) AS agg
             ON agg.ItemId = s.ItemId
        WHERE s.BranchId = @BranchId;

        INSERT INTO inv.StockMovement
            (ItemId, BranchId, MovementType, Quantity, BalanceAfter, UnitCostH,
             Reference, ReasonEn, ReasonAr, Actor)
        SELECT
            agg.ItemId, @BranchId, N'purchase', agg.Qty, s.Quantity, agg.AvgCost,
            @Reference, N'Delivery received', N'استلام بضاعة', @ReceivedBy
        FROM (SELECT ItemId, SUM(Quantity) AS Qty,
                     SUM(Quantity * UnitCostH) / NULLIF(SUM(Quantity), 0) AS AvgCost
              FROM @Lines GROUP BY ItemId) AS agg
        JOIN inv.StockLevel AS s ON s.ItemId = agg.ItemId AND s.BranchId = @BranchId;

        /* Stock arriving is an asset swap, not a cost. It becomes a cost when
           it is sold, through COGS. */
        DECLARE @Entry fin.JournalLineTable;
        INSERT INTO @Entry (AccountCode, DebitH, CreditH, Memo) VALUES
            (N'1200', @SubtotalH, 0, N'Inventory'),
            (N'1300', @TaxH, 0, N'Input VAT'),
            (CASE WHEN @PaidOnReceipt = 1 THEN N'1000' ELSE N'2000' END, 0, @TotalH, N'Supplier');

        DECLARE @EntryId NVARCHAR(40);
        EXEC fin.usp_PostJournalEntry
            @Kind = N'purchase', @DescriptionEn = N'Delivery received',
            @DescriptionAr = N'استلام بضاعة', @SourceReference = @Reference,
            @BranchId = @BranchId, @Actor = @ReceivedBy,
            @Lines = @Entry, @EntryId = @EntryId OUTPUT;

    COMMIT;
END
GO

PRINT N'35 · Vendors, purchases and payables ready.';
GO

SELECT
    CASE WHEN COL_LENGTH(N'inv.Purchase', N'PaidH') IS NULL THEN N'FAIL  PaidH missing'
         WHEN OBJECT_ID(N'inv.usp_RecordVendorPayment') IS NULL THEN N'FAIL  payment proc missing'
         WHEN OBJECT_ID(N'core.usp_SaveVendor') IS NULL THEN N'FAIL  save proc missing'
         WHEN EXISTS (SELECT 1 FROM inv.Purchase WHERE PaidOnReceipt = 1 AND PaidH <> TotalH)
              THEN N'FAIL  paid-on-receipt purchases not settled'
         ELSE N'PASS  Vendors and payables ready'
    END AS Result;
GO
