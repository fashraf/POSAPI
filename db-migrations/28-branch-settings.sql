/*==============================================================================
  Nazad POS — 28 · Branch settings

  Backs PUT /api/branches/{branchId}/settings and
  POST /api/branches/{branchId}/settings/copy.

  Saving is an upsert. A branch created before its settings row existed should
  be configurable from the screen, not need a database session first.

  Error numbers 62050–62069.
==============================================================================*/

USE POSMAIN;
GO

CREATE OR ALTER PROCEDURE core.usp_SaveBranchSettings
    @BranchId            NVARCHAR(40),
    @DefaultCustomerMode NVARCHAR(20),
    @ServedByRequirement NVARCHAR(20),
    @AllowNegativeStock  BIT,
    @DefaultBillId       NVARCHAR(40) = NULL,
    @AutoPrintCustomer   BIT,
    @AutoPrintGroups     BIT,
    @VatRatePercent      DECIMAL(5,2),
    @PricesIncludeVat    BIT,
    @Actor               NVARCHAR(160)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId)
        THROW 62050, N'No such branch.', 1;

    IF @DefaultCustomerMode NOT IN (N'walkin', N'customer')
        THROW 62051, N'The default customer mode is walkin or customer.', 1;

    IF @ServedByRequirement NOT IN (N'off', N'optional', N'required')
        THROW 62052, N'Served-by is off, optional or required.', 1;

    IF @VatRatePercent IS NULL OR @VatRatePercent < 0 OR @VatRatePercent > 100
        THROW 62053, N'Enter a VAT rate between 0 and 100.', 1;

    /* The branch default is what prints on a customer's receipt. A kitchen
       ticket there would hand the customer a bill with no total. */
    IF @DefaultBillId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM core.BillTemplate
        WHERE BillId = @DefaultBillId AND Audience = N'customer' AND IsActive = 1)
        THROW 62054, N'The default bill must be an active customer template.', 1;

    UPDATE core.BranchSettings
    SET DefaultCustomerMode = @DefaultCustomerMode,
        ServedByRequirement = @ServedByRequirement,
        AllowNegativeStock  = @AllowNegativeStock,
        DefaultBillId       = @DefaultBillId,
        AutoPrintCustomer   = @AutoPrintCustomer,
        AutoPrintGroups     = @AutoPrintGroups,
        VatRatePercent      = @VatRatePercent,
        PricesIncludeVat    = @PricesIncludeVat,
        UpdatedAtUtc        = SYSUTCDATETIME(),
        UpdatedBy           = @Actor
    WHERE BranchId = @BranchId;

    IF @@ROWCOUNT = 0
        INSERT INTO core.BranchSettings
            (BranchId, DefaultCustomerMode, ServedByRequirement, AllowNegativeStock,
             DefaultBillId, AutoPrintCustomer, AutoPrintGroups, VatRatePercent,
             PricesIncludeVat, UpdatedBy)
        VALUES
            (@BranchId, @DefaultCustomerMode, @ServedByRequirement, @AllowNegativeStock,
             @DefaultBillId, @AutoPrintCustomer, @AutoPrintGroups, @VatRatePercent,
             @PricesIncludeVat, @Actor);
END
GO

/*
  Copy one branch's configuration onto another.

  Through the save procedure rather than an INSERT ... SELECT, so a copy is
  held to exactly the rules an edit is — a source configured before a rule
  existed cannot smuggle a now-invalid value across.
*/
CREATE OR ALTER PROCEDURE core.usp_CopyBranchSettings
    @SourceBranchId NVARCHAR(40),
    @TargetBranchId NVARCHAR(40),
    @Actor          NVARCHAR(160)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @SourceBranchId)
       OR NOT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @TargetBranchId)
        THROW 62050, N'No such branch.', 1;

    IF @SourceBranchId = @TargetBranchId
        THROW 62056, N'Choose a different branch to copy from.', 1;

    DECLARE @Mode NVARCHAR(20), @ServedBy NVARCHAR(20), @Negative BIT, @Bill NVARCHAR(40),
            @PrintCustomer BIT, @PrintGroups BIT, @Vat DECIMAL(5,2), @IncludesVat BIT;

    SELECT @Mode = DefaultCustomerMode, @ServedBy = ServedByRequirement,
           @Negative = AllowNegativeStock, @Bill = DefaultBillId,
           @PrintCustomer = AutoPrintCustomer, @PrintGroups = AutoPrintGroups,
           @Vat = VatRatePercent, @IncludesVat = PricesIncludeVat
    FROM core.BranchSettings WHERE BranchId = @SourceBranchId;

    IF @Mode IS NULL
        THROW 62055, N'That branch has no settings to copy yet.', 1;

    EXEC core.usp_SaveBranchSettings
         @BranchId = @TargetBranchId, @DefaultCustomerMode = @Mode,
         @ServedByRequirement = @ServedBy, @AllowNegativeStock = @Negative,
         @DefaultBillId = @Bill, @AutoPrintCustomer = @PrintCustomer,
         @AutoPrintGroups = @PrintGroups, @VatRatePercent = @Vat,
         @PricesIncludeVat = @IncludesVat, @Actor = @Actor;
END
GO

PRINT N'28 · Branch settings ready.';
GO

SELECT
    CASE WHEN OBJECT_ID(N'core.usp_SaveBranchSettings') IS NULL
              OR OBJECT_ID(N'core.usp_CopyBranchSettings') IS NULL
              THEN N'FAIL  procedures missing'
         ELSE N'PASS  Branch settings ready'
    END AS Result;
GO
