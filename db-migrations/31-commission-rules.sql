/*==============================================================================
  Nazad POS — 31 · Commission rules

  Backs POST/PUT/DELETE /api/finance/commission-rules.

  fin.usp_SaveCommissionRule as captured in 25 accepted bases the table refuses
  ('percent_of_sale', 'percent_of_margin', 'fixed_per_sale' against the CHECK's
  'percentage' / 'fixed') and treated a percentage as whole percent where the
  table and fin.usp_RecordSaleCommission use basis points. It also saved only
  the rate, not who or what the rule covers. This replaces it: the rule and its
  user and service sets are saved together.

  Value: basis points of a percent (2000 = 20%) for 'percentage', halalas for
  'fixed' — the same units usp_RecordSaleCommission computes with.

  Error numbers 64000–64049.
==============================================================================*/

USE POSMAIN;
GO

CREATE OR ALTER PROCEDURE fin.usp_SaveCommissionRule
    @RuleId   NVARCHAR(40)  = NULL,   -- null creates
    @Basis    NVARCHAR(20),           -- percentage | fixed
    @Value    INT,
    @UserIds  NVARCHAR(MAX) = NULL,   -- comma separated; empty: everyone without their own rule
    @ItemIds  NVARCHAR(MAX) = NULL,   -- comma separated; empty: every service
    @IsActive BIT = 1,
    @SavedId  NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Basis NOT IN (N'percentage', N'fixed')
        THROW 64000, N'Commission is a percentage or a fixed amount.', 1;

    IF ISNULL(@Value, 0) <= 0
        THROW 64001, N'Enter a value above zero.', 1;

    /* A percentage above 100 pays out more than the sale brought in. */
    IF @Basis = N'percentage' AND @Value > 10000
        THROW 64002, N'A commission cannot exceed 100%.', 1;

    IF @RuleId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fin.CommissionRule WHERE RuleId = @RuleId)
        THROW 64005, N'No such commission rule.', 1;

    DECLARE @Users TABLE (UserId NVARCHAR(40) PRIMARY KEY);
    INSERT INTO @Users (UserId)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@UserIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    IF EXISTS (SELECT 1 FROM @Users AS u
               WHERE NOT EXISTS (SELECT 1 FROM core.AppUser WHERE UserId = u.UserId))
        THROW 64003, N'One of those people does not exist.', 1;

    DECLARE @Items TABLE (ItemId NVARCHAR(40) PRIMARY KEY);
    INSERT INTO @Items (ItemId)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(ISNULL(@ItemIds, N''), N',')
    WHERE LTRIM(RTRIM(value)) <> N'';

    /* Commission is earned on work performed. usp_RecordSaleCommission only
       ever looks at service lines, so a product here would be a rule that
       silently never pays. */
    IF EXISTS (SELECT 1 FROM @Items AS i
               WHERE NOT EXISTS (SELECT 1 FROM core.CatalogItem
                                 WHERE ItemId = i.ItemId AND Kind = N'service'))
        THROW 64004, N'Commission rules cover services only, and one of those is not a service.', 1;

    BEGIN TRAN;

        IF @RuleId IS NULL
        BEGIN
            SET @SavedId = CONCAT(N'crl_',
                LOWER(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'')));

            INSERT INTO fin.CommissionRule (RuleId, Basis, Value, IsActive)
            VALUES (@SavedId, @Basis, @Value, @IsActive);
        END
        ELSE
        BEGIN
            SET @SavedId = @RuleId;

            /*
              Editing a rule does not change commission already earned.

              fin.CommissionEntry records the amount at the moment of each sale,
              so past entries keep the rate that applied then. Recalculating them
              would rewrite what someone was told they had earned.
            */
            UPDATE fin.CommissionRule
            SET Basis = @Basis, Value = @Value, IsActive = @IsActive,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE RuleId = @RuleId;
        END

        DELETE FROM fin.CommissionRuleUser WHERE RuleId = @SavedId;
        INSERT INTO fin.CommissionRuleUser (RuleId, UserId) SELECT @SavedId, UserId FROM @Users;

        DELETE FROM fin.CommissionRuleItem WHERE RuleId = @SavedId;
        INSERT INTO fin.CommissionRuleItem (RuleId, ItemId) SELECT @SavedId, ItemId FROM @Items;

    COMMIT;
END
GO

/*
  A real delete.

  Commission already earned does not point back at its rule — each entry froze
  its basis and rate at the moment of sale — so removing a rule changes future
  sales only, which is what removing it means. The user and item sets cascade.
*/
CREATE OR ALTER PROCEDURE fin.usp_DeleteCommissionRule
    @RuleId NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM fin.CommissionRule WHERE RuleId = @RuleId;

    IF @@ROWCOUNT = 0 THROW 64005, N'No such commission rule.', 1;
END
GO

PRINT N'31 · Commission rules ready.';
GO

SELECT
    CASE WHEN OBJECT_ID(N'fin.usp_DeleteCommissionRule') IS NULL
              THEN N'FAIL  procedures missing'
         WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID(N'fin.usp_SaveCommissionRule')
                            AND name = N'@ItemIds')
              THEN N'FAIL  save procedure not replaced'
         ELSE N'PASS  Commission rules ready'
    END AS Result;
GO
