using System.Data.Common;
using System.Text.RegularExpressions;
using Dapper;
using PosApi.Auth;
using PosApi.Tenancy;

namespace PosApi.Features.SuperAdmin;

public sealed record MasterItemRequest(string? Value, string? Label, string? LabelAr, string? Region, string? Icon, string? Kind, int? SortOrder);
public sealed record PlanConfigRequest(
    List<string>? Features, int? Users, int? Devices, int? Branches, int? Duration, string? DurationUnit,
    long? AmountH, string? Currency, string? Status, bool? CustomBilling, bool? AutoRenew, int? RenewalNoticeDays);
public sealed record PlanRequest(
    string? Label, long? MonthlyH, long? AnnualH, int? Branches, int? Devices, int? Users, int? Transactions,
    decimal? StorageGb, List<string>? Features, bool? IsActive);
public sealed record TrialDaysRequest(int Days);
public sealed record HardwareRequest
{
    public string? Id { get; init; }
    public string? Serial { get; init; }
    public string? Manufacturer { get; init; }
    public string? Model { get; init; }
    public string? Type { get; init; }
    public string? Os { get; init; }
    public string? MacAddress { get; init; }
    public string? Imei { get; init; }
    public DateOnly? PurchasedOn { get; init; }
    public DateOnly? WarrantyEndsOn { get; init; }
    public int? WarrantyMonths { get; init; }
    public string? ClientId { get; init; }
    public string? BranchId { get; init; }
    public string? BranchName { get; init; }
    public string? TerminalId { get; init; }
    public string? Notes { get; init; }
}
public sealed record HardwareMoveRequest(string? To, string? Reason, string? ClientId);
public sealed record AdminRequest(string? Name, string? Mobile, string? Email, string? Role, string? Permissions, string? Password);
public sealed record NotificationRuleRequest(string Key, bool On, string? Channel);

/// <summary>Maintenance: master data, features and plans, the hardware register, and settings.</summary>
public static partial class ConfigEndpoints
{
    private static readonly string[] MasterSets = ["cities", "services", "payment-methods", "deactivation-reasons"];

    /* Business types and plan keys are data ("Retail", "Pro"), not property
       names: the API's camel-casing of dictionary keys would turn them into
       "retail" and "pro", and the console's lookups would miss. */
    private static readonly System.Text.Json.JsonSerializerOptions DataKeys = new(System.Text.Json.JsonSerializerDefaults.Web)
    {
        DictionaryKeyPolicy = null,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never
    };

    public static void MapConfigEndpoints(this RouteGroupBuilder api)
    {
        var master = api.MapGroup("/master").WithTags("SuperAdmin · Master data");
        master.MapGet("/plans", MasterPlansAsync);
        master.MapGet("/{set}", MasterListAsync);
        master.MapPost("/{set}", MasterCreateAsync);
        master.MapPut("/{set}/{value}", MasterUpdateAsync);
        master.MapDelete("/{set}/{value}", MasterDeleteAsync);

        var features = api.MapGroup("/features").WithTags("SuperAdmin · Features");
        features.MapGet("", CatalogueAsync);
        features.MapGet("/by-type", ByTypeAsync);
        features.MapPut("/by-type/{type}", SetTypeFeaturesAsync);
        features.MapGet("/matrix", MatrixAsync);
        features.MapPut("/matrix/{type}/{plan}", SetPlanConfigAsync);
        features.MapGet("/orphans", OrphansAsync);

        api.MapPut("/subscriptions/plans/{key}", SavePlanAsync).WithTags("SuperAdmin · Subscriptions");
        api.MapPut("/settings/trial-days", TrialDaysAsync).WithTags("SuperAdmin · Settings");

        var devices = api.MapGroup("/devices").WithTags("SuperAdmin · Hardware");
        devices.MapGet("", HardwareListAsync);
        devices.MapGet("/warranty", WarrantyAsync);
        devices.MapGet("/{id}/history", HardwareHistoryAsync);
        devices.MapPost("", HardwareSaveAsync);
        devices.MapPost("/{id}/status", HardwareMoveAsync);

        var settings = api.MapGroup("/settings").WithTags("SuperAdmin · Settings");
        settings.MapGet("", SettingsAsync);
        settings.MapPut("", SaveSettingsAsync);
        settings.MapGet("/notifications", RulesAsync);
        settings.MapPut("/notifications", SaveRulesAsync);

        var admins = api.MapGroup("/admins").WithTags("SuperAdmin · Settings");
        admins.MapGet("", AdminsAsync);
        admins.MapPost("", CreateAdminAsync);
        admins.MapPost("/{id}/reset-password", ResetPasswordAsync);
    }

    /*=========================================================== master data */

    private static string ExtraName(string set) => set switch
    {
        "cities" => "region",
        "services" => "icon",
        "payment-methods" => "kind",
        _ => "extra"
    };

    private static async Task<IEnumerable<IDictionary<string, object?>>> MasterRowsAsync(DbConnection control, string set, bool all, CancellationToken ct)
    {
        var rows = await control.QueryAsync(new CommandDefinition(
            """
            SELECT Value, Label, LabelAr, Extra, SortOrder, IsActive FROM ctl.MasterItem
            WHERE SetKey = @Set AND (@All = 1 OR IsActive = 1) ORDER BY SortOrder, Label;
            """, new { Set = set, All = all }, cancellationToken: ct));

        return rows.Select(r =>
        {
            var item = new Dictionary<string, object?>
            {
                ["value"] = (string)r.Value,
                ["label"] = (string)r.Label,
                ["labelAr"] = (string?)r.LabelAr,
                ["isActive"] = (bool)r.IsActive,
                ["sortOrder"] = (int)r.SortOrder
            };
            if (set != "deactivation-reasons") item[ExtraName(set)] = (string?)r.Extra;
            return (IDictionary<string, object?>)item;
        });
    }

    private static async Task<IResult> MasterListAsync(string set, bool? all, TenantCatalog catalog, CancellationToken ct)
    {
        if (!MasterSets.Contains(set)) return ClientEndpoints.NotFound($"No master list '{set}'.");
        await using var control = catalog.Control();
        return Results.Ok(await MasterRowsAsync(control, set, all == true, ct));
    }

    private static async Task<IResult> MasterPlansAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await BillingEndpoints.PlanListAsync(control, ct));
    }

    private static string? ExtraOf(string set, MasterItemRequest r) => set switch
    {
        "cities" => r.Region,
        "services" => r.Icon,
        "payment-methods" => r.Kind,
        _ => null
    };

    private static IResult? ValidateMaster(string set, MasterItemRequest r)
    {
        if (!MasterSets.Contains(set)) return ClientEndpoints.NotFound($"No master list '{set}'.");
        if (string.IsNullOrWhiteSpace(r.Label)) return Results.BadRequest(new { code = "required", message = "A label is required." });
        if (set == "cities" && string.IsNullOrWhiteSpace(r.Region)) return Results.BadRequest(new { code = "required", message = "A region is required." });
        if (set == "payment-methods" && r.Kind is not ("cash" or "card" or "wallet" or "bank" or "credit"))
            return Results.BadRequest(new { code = "required", message = "Kind is cash, card, wallet, bank or credit." });
        return null;
    }

    private static async Task<IResult> MasterCreateAsync(string set, MasterItemRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (ValidateMaster(set, request) is { } invalid) return invalid;

        /* The key is the label without spaces, as the console has always made it. */
        var value = string.IsNullOrWhiteSpace(request.Value) ? Regex.Replace(request.Label!.Trim(), @"\s+", "") : request.Value.Trim();
        await using var control = catalog.Control();

        var clash = await control.QueryFirstOrDefaultAsync<(string Value, bool IsActive)>(new CommandDefinition(
            "SELECT Value, IsActive FROM ctl.MasterItem WHERE SetKey = @Set AND (Value = @Value OR Label = @Label);",
            new { Set = set, Value = value, Label = request.Label!.Trim() }, cancellationToken: ct));

        if (clash.Value is not null && clash.IsActive)
            return ClientEndpoints.Conflict($"'{request.Label}' is already on the list.");

        await control.ExecuteAsync(new CommandDefinition(
            clash.Value is not null
                ? "UPDATE ctl.MasterItem SET Label = @Label, LabelAr = @LabelAr, Extra = @Extra, IsActive = 1 WHERE SetKey = @Set AND Value = @Existing;"
                : """
                  INSERT INTO ctl.MasterItem (SetKey, Value, Label, LabelAr, Extra, SortOrder)
                  VALUES (@Set, @Value, @Label, @LabelAr, @Extra,
                          ISNULL(@Sort, (SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM ctl.MasterItem WHERE SetKey = @Set)));
                  """,
            new
            {
                Set = set, Value = value, Existing = clash.Value, Label = request.Label!.Trim(),
                LabelAr = request.LabelAr?.Trim(), Extra = ExtraOf(set, request), Sort = request.SortOrder
            }, cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("master.create", $"Added to {set}", null, value, null, request.Label,
            null, "ctl.MasterItem", "INSERT", 1, new { value }, ct));
    }

    private static async Task<IResult> MasterUpdateAsync(string set, string value, MasterItemRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (ValidateMaster(set, request) is { } invalid) return invalid;
        await using var control = catalog.Control();

        var before = await control.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT Label FROM ctl.MasterItem WHERE SetKey = @Set AND Value = @Value;", new { Set = set, Value = value }, cancellationToken: ct));
        if (before is null) return ClientEndpoints.NotFound("No such item.");

        if (await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.MasterItem WHERE SetKey = @Set AND Label = @Label AND Value <> @Value AND IsActive = 1;",
                new { Set = set, Label = request.Label!.Trim(), Value = value }, cancellationToken: ct)) is not null)
            return ClientEndpoints.Conflict($"'{request.Label}' is already on the list.");

        /* The key never changes: clients store it. */
        await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.MasterItem SET Label = @Label, LabelAr = @LabelAr, Extra = @Extra, SortOrder = ISNULL(@Sort, SortOrder)
            WHERE SetKey = @Set AND Value = @Value;
            """, new { Set = set, Value = value, Label = request.Label!.Trim(), LabelAr = request.LabelAr?.Trim(), Extra = ExtraOf(set, request), Sort = request.SortOrder },
            cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("master.update", $"Edited {set}", null, value, before, request.Label,
            null, "ctl.MasterItem", "UPDATE", 1, null, ct));
    }

    /// <summary>Removes it from the choices; clients already using it keep it.</summary>
    private static async Task<IResult> MasterDeleteAsync(string set, string value, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (!MasterSets.Contains(set)) return ClientEndpoints.NotFound($"No master list '{set}'.");
        await using var control = catalog.Control();

        var affected = await control.ExecuteAsync(new CommandDefinition(
            "UPDATE ctl.MasterItem SET IsActive = 0 WHERE SetKey = @Set AND Value = @Value AND IsActive = 1;",
            new { Set = set, Value = value }, cancellationToken: ct));
        if (affected == 0) return ClientEndpoints.NotFound("No such item.");

        return Results.Ok(await audit.ResultAsync("master.remove", $"Removed from {set}", null, value, "active", "removed",
            null, "ctl.MasterItem", "UPDATE", 1, null, ct));
    }

    /*============================================================== features */

    private static async Task<IResult> CatalogueAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await control.QueryAsync(new CommandDefinition(
            "SELECT FeatureKey AS [key], Label AS label, Icon AS icon, Blurb AS blurb, IsCore AS core FROM ctl.Feature ORDER BY SortOrder;",
            cancellationToken: ct)));
    }

    private static async Task<Dictionary<string, List<string>>> TypeMapAsync(DbConnection control, CancellationToken ct)
    {
        var rows = await control.QueryAsync<(string BusinessType, string FeatureKey)>(new CommandDefinition(
            """
            SELECT tf.BusinessType, tf.FeatureKey FROM ctl.TypeFeature AS tf
            JOIN ctl.Feature AS f ON f.FeatureKey = tf.FeatureKey ORDER BY tf.BusinessType, f.SortOrder;
            """, cancellationToken: ct));

        var map = rows.GroupBy(r => r.BusinessType).ToDictionary(g => g.Key, g => g.Select(r => r.FeatureKey).ToList());

        /* Every business type on the master list appears, even one with nothing chosen yet. */
        foreach (var type in await control.QueryAsync<string>(new CommandDefinition(
                     "SELECT Value FROM ctl.MasterItem WHERE SetKey = N'services' AND IsActive = 1;", cancellationToken: ct)))
            map.TryAdd(type, []);

        return map;
    }

    private static async Task<IResult> ByTypeAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Json(await TypeMapAsync(control, ct), DataKeys);
    }

    /// <summary>What a business type may use. POS cannot be turned off.</summary>
    private static async Task<IResult> SetTypeFeaturesAsync(string type, List<string> features, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        await using var control = catalog.Control();
        await control.OpenAsync(ct);

        var known = (await control.QueryAsync<(string Key, bool IsCore)>(new CommandDefinition(
            "SELECT FeatureKey, IsCore FROM ctl.Feature;", cancellationToken: ct))).ToList();

        var wanted = features.Where(f => known.Any(k => k.Key == f)).Distinct().ToList();
        foreach (var core in known.Where(k => k.IsCore).Select(k => k.Key))
            if (!wanted.Contains(core)) wanted.Insert(0, core);

        var before = (await TypeMapAsync(control, ct)).GetValueOrDefault(type) ?? [];

        await using var tx = await control.BeginTransactionAsync(ct);
        await control.ExecuteAsync(new CommandDefinition(
            "DELETE FROM ctl.TypeFeature WHERE BusinessType = @Type;", new { Type = type }, tx, cancellationToken: ct));
        foreach (var f in wanted)
            await control.ExecuteAsync(new CommandDefinition(
                "INSERT INTO ctl.TypeFeature (BusinessType, FeatureKey) VALUES (@Type, @Feature);",
                new { Type = type, Feature = f }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);

        /* Plans may now include something this type no longer allows. They are
           reported, not silently dropped: a client may be paying for it. */
        var orphans = await control.QueryAsync<(string PlanKey, string FeatureKey)>(new CommandDefinition(
            """
            SELECT p.PlanKey, p.FeatureKey FROM ctl.PlanConfigFeature AS p
            WHERE p.BusinessType = @Type
              AND NOT EXISTS (SELECT 1 FROM ctl.TypeFeature AS t WHERE t.BusinessType = p.BusinessType AND t.FeatureKey = p.FeatureKey);
            """, new { Type = type }, cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("features.type", $"Changed features for {type}", null, type,
            string.Join(",", before), string.Join(",", wanted), null, "ctl.TypeFeature", "UPDATE", wanted.Count,
            new { features = wanted, orphans = orphans.Select(o => new { plan = o.PlanKey, feature = o.FeatureKey }) }, ct));
    }

    private static async Task<IResult> MatrixAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();

        var configs = await control.QueryAsync<ConfigRow>(new CommandDefinition(
            """
            SELECT BusinessType, PlanKey, Users, Devices, Branches, Duration, DurationUnit, AmountH, Currency, Status,
                   CustomBilling, AutoRenew, RenewalNoticeDays FROM ctl.PlanConfig;
            """, cancellationToken: ct));
        var included = (await control.QueryAsync<(string BusinessType, string PlanKey, string FeatureKey)>(new CommandDefinition(
            """
            SELECT c.BusinessType, c.PlanKey, c.FeatureKey FROM ctl.PlanConfigFeature AS c
            JOIN ctl.Feature AS f ON f.FeatureKey = c.FeatureKey ORDER BY f.SortOrder;
            """, cancellationToken: ct))).ToList();

        var matrix = configs.GroupBy(c => c.BusinessType).ToDictionary(g => g.Key, g => g.ToDictionary(c => c.PlanKey, c => (object)new
        {
            features = included.Where(i => i.BusinessType == c.BusinessType && i.PlanKey == c.PlanKey).Select(i => i.FeatureKey).ToList(),
            users = c.Users,
            devices = c.Devices,
            branches = c.Branches,
            duration = c.Duration,
            durationUnit = c.DurationUnit,
            amountH = c.AmountH,
            currency = c.Currency,
            status = c.Status,
            customBilling = c.CustomBilling,
            autoRenew = c.AutoRenew,
            renewalNoticeDays = c.RenewalNoticeDays
        }));

        return Results.Json(matrix, DataKeys);
    }

    /// <summary>
    /// What a plan includes for a business type, and its limits. Only features
    /// the type allows may be added; blank limits mean unlimited.
    /// </summary>
    private static async Task<IResult> SetPlanConfigAsync(
        string type, string plan, PlanConfigRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (request.DurationUnit is not (null or "days" or "weeks" or "months"))
            return Results.BadRequest(new { code = "bad_unit", message = "Duration is in days, weeks or months." });
        if (request.Currency is not (null or "SAR" or "USD" or "AED"))
            return Results.BadRequest(new { code = "bad_currency", message = "Currency is SAR, USD or AED." });
        if (request.Users is < 0 || request.Devices is < 0 || request.Branches is < 0 || request.Duration is <= 0)
            return Results.BadRequest(new { code = "bad_limit", message = "Limits cannot be negative." });

        await using var control = catalog.Control();
        await control.OpenAsync(ct);

        if (await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.[Plan] WHERE PlanKey = @Plan;", new { Plan = plan }, cancellationToken: ct)) is null)
            return ClientEndpoints.NotFound($"No plan '{plan}'.");

        var allowed = (await TypeMapAsync(control, ct)).GetValueOrDefault(type) ?? [];
        var features = (request.Features ?? []).Distinct().ToList();
        var refused = features.Where(f => !allowed.Contains(f)).ToList();
        if (refused.Count > 0)
            return Results.BadRequest(new { code = "not_applicable", message = $"{type} does not allow: {string.Join(", ", refused)}.", refused });

        await using var tx = await control.BeginTransactionAsync(ct);
        await control.ExecuteAsync(new CommandDefinition(
            """
            MERGE ctl.PlanConfig AS c
            USING (SELECT @Type AS BusinessType, @Plan AS PlanKey) AS src
               ON c.BusinessType = src.BusinessType AND c.PlanKey = src.PlanKey
            WHEN MATCHED THEN UPDATE SET
                Users = @Users, Devices = @Devices, Branches = @Branches, Duration = ISNULL(@Duration, Duration),
                DurationUnit = ISNULL(@Unit, DurationUnit), AmountH = @AmountH, Currency = ISNULL(@Currency, Currency),
                Status = ISNULL(@Status, Status), CustomBilling = ISNULL(@CustomBilling, CustomBilling),
                AutoRenew = ISNULL(@AutoRenew, AutoRenew), RenewalNoticeDays = ISNULL(@Notice, RenewalNoticeDays),
                UpdatedAtUtc = SYSUTCDATETIME()
            WHEN NOT MATCHED THEN INSERT
                (BusinessType, PlanKey, Users, Devices, Branches, Duration, DurationUnit, AmountH, Currency, Status,
                 CustomBilling, AutoRenew, RenewalNoticeDays)
            VALUES (@Type, @Plan, @Users, @Devices, @Branches, ISNULL(@Duration, 12), ISNULL(@Unit, N'months'), @AmountH,
                    ISNULL(@Currency, N'SAR'), ISNULL(@Status, N'active'), ISNULL(@CustomBilling, 0), ISNULL(@AutoRenew, 1),
                    ISNULL(@Notice, 30));

            DELETE FROM ctl.PlanConfigFeature WHERE BusinessType = @Type AND PlanKey = @Plan;
            """,
            new
            {
                Type = type, Plan = plan, request.Users, request.Devices, request.Branches, request.Duration,
                Unit = request.DurationUnit, request.AmountH, request.Currency, request.Status,
                request.CustomBilling, request.AutoRenew, Notice = request.RenewalNoticeDays
            }, tx, cancellationToken: ct));

        foreach (var f in features)
            await control.ExecuteAsync(new CommandDefinition(
                "INSERT INTO ctl.PlanConfigFeature (BusinessType, PlanKey, FeatureKey) VALUES (@Type, @Plan, @Feature);",
                new { Type = type, Plan = plan, Feature = f }, tx, cancellationToken: ct));

        await tx.CommitAsync(ct);

        return Results.Ok(await audit.ResultAsync("features.plan", $"Changed {plan} for {type}", null, $"{type}/{plan}",
            null, $"{features.Count} features; users {request.Users?.ToString() ?? "∞"}, devices {request.Devices?.ToString() ?? "∞"}, branches {request.Branches?.ToString() ?? "∞"}",
            null, "ctl.PlanConfig", "UPDATE", 1, null, ct));
    }

    private static async Task<IResult> OrphansAsync(string type, string plan, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await control.QueryAsync<string>(new CommandDefinition(
            """
            SELECT p.FeatureKey FROM ctl.PlanConfigFeature AS p
            WHERE p.BusinessType = @Type AND p.PlanKey = @Plan
              AND NOT EXISTS (SELECT 1 FROM ctl.TypeFeature AS t WHERE t.BusinessType = p.BusinessType AND t.FeatureKey = p.FeatureKey);
            """, new { Type = type, Plan = plan }, cancellationToken: ct)));
    }

    private static async Task<IResult> SavePlanAsync(string key, PlanRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var affected = await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.[Plan]
            SET Label = ISNULL(@Label, Label), MonthlyH = @MonthlyH, AnnualH = @AnnualH, Branches = @Branches,
                Devices = @Devices, Users = @Users, Transactions = @Transactions, StorageGb = @StorageGb,
                Highlights = ISNULL(@Highlights, Highlights), IsActive = ISNULL(@IsActive, IsActive)
            WHERE PlanKey = @Key;
            """,
            new
            {
                Key = key, request.Label, request.MonthlyH, request.AnnualH, request.Branches, request.Devices, request.Users,
                request.Transactions, request.StorageGb,
                Highlights = request.Features is null ? null : string.Join("|", request.Features), request.IsActive
            }, cancellationToken: ct));

        if (affected == 0) return ClientEndpoints.NotFound($"No plan '{key}'.");

        return Results.Ok(await audit.ResultAsync("plan.update", $"Changed plan {key}", null, key, null,
            $"monthly {request.MonthlyH?.ToString() ?? "agreement"}, annual {request.AnnualH?.ToString() ?? "agreement"}",
            null, "ctl.Plan", "UPDATE", 1, null, ct));
    }

    /// <summary>Applies to clients created from now on, not to trials already running.</summary>
    private static async Task<IResult> TrialDaysAsync(TrialDaysRequest request, TenantCatalog catalog, CurrentAdmin admin, AdminAuditor audit, CancellationToken ct)
    {
        if (request.Days is < 1 or > 90)
            return Results.BadRequest(new { code = "bad_days", message = "A trial lasts between 1 and 90 days." });

        await using var control = catalog.Control();
        var before = await control.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT Value FROM ctl.Setting WHERE SettingKey = N'trialDays';", cancellationToken: ct));
        await control.ExecuteAsync(new CommandDefinition(
            "UPDATE ctl.Setting SET Value = @Value, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @By WHERE SettingKey = N'trialDays';",
            new { Value = request.Days.ToString(), By = admin.Name }, cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("settings.update", "Changed trial length", null, "trialDays",
            before, $"{request.Days} days", null, "ctl.Setting", "UPDATE", 1, null, ct));
    }

    /*====================================================== hardware register */

    private static readonly Dictionary<string, string[]> Lifecycle = new()
    {
        ["available"] = ["assigned", "retired"],
        ["assigned"] = ["active", "available", "retired"],
        ["active"] = ["suspended", "available", "retired"],
        ["suspended"] = ["active", "available", "retired"],
        ["retired"] = []
    };

    public static async Task<IEnumerable<dynamic>> HardwareAsync(DbConnection control, string? tenantId, CancellationToken ct) =>
        await control.QueryAsync(new CommandDefinition(
            """
            SELECT h.DeviceId AS id, h.Serial AS serial,
                   CONCAT(ISNULL(h.Manufacturer + N' ', N''), h.Model) AS name,
                   h.Manufacturer AS manufacturer, h.Model AS model, h.DeviceType AS type, h.Os AS os,
                   h.MacAddress AS macAddress, h.Imei AS imei, CONVERT(CHAR(10), h.PurchasedOn, 23) AS purchasedOn,
                   CONVERT(CHAR(10), h.WarrantyEndsOn, 23) AS warrantyEndsOn, h.WarrantyMonths AS warrantyMonths, h.Status AS status,
                   h.TenantId AS clientId, t.Name AS clientName, h.BranchId AS branchId, h.BranchName AS branchName,
                   h.TerminalId AS terminalId, CONVERT(CHAR(10), h.InstalledOn, 23) AS installedOn, h.LastOnlineAtUtc AS lastOnlineAt,
                   h.Notes AS notes,
                   DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), h.WarrantyEndsOn) AS daysOfWarranty
            FROM ctl.HardwareDevice AS h LEFT JOIN ctl.Tenant AS t ON t.TenantId = h.TenantId
            WHERE @TenantId IS NULL OR h.TenantId = @TenantId
            ORDER BY h.DeviceId;
            """, new { TenantId = tenantId }, cancellationToken: ct));

    private static async Task<IResult> HardwareListAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await HardwareAsync(control, null, ct));
    }

    private static async Task<IResult> WarrantyAsync(int? days, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var within = days ?? 90;
        var all = await HardwareAsync(control, null, ct);
        return Results.Ok(all.Where(d => d.status != "retired" && d.daysOfWarranty is not null && d.daysOfWarranty <= within)
                             .OrderBy(d => (int)d.daysOfWarranty));
    }

    private static async Task<IResult> HardwareHistoryAsync(string id, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await control.QueryAsync(new CommandDefinition(
            "SELECT AtUtc AS [at], Event AS [event], ByName AS [by], Detail AS detail FROM ctl.HardwareDeviceEvent WHERE DeviceId = @Id ORDER BY EventId DESC;",
            new { Id = id }, cancellationToken: ct)));
    }

    [GeneratedRegex(@"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")] private static partial Regex MacPattern();

    /// <summary>Add or edit a device in the register. The server assigns new ids.</summary>
    private static async Task<IResult> HardwareSaveAsync(HardwareRequest request, TenantCatalog catalog, CurrentAdmin admin, AdminAuditor audit, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Serial) || string.IsNullOrWhiteSpace(request.Model))
            return Results.BadRequest(new { code = "required", message = "Serial and model are required." });
        if (!string.IsNullOrWhiteSpace(request.MacAddress) && !MacPattern().IsMatch(request.MacAddress))
            return Results.BadRequest(new { code = "bad_mac", message = "A MAC address looks like 00:1A:2B:3C:4D:5E." });
        if (request.PurchasedOn is { } p && request.WarrantyEndsOn is { } w && w < p)
            return Results.BadRequest(new { code = "bad_warranty", message = "The warranty cannot end before the purchase." });

        await using var control = catalog.Control();
        await control.OpenAsync(ct);

        (string DeviceId, string Status, string? TenantId)? existing = string.IsNullOrWhiteSpace(request.Id) ? null
            : await control.QuerySingleOrDefaultAsync<(string DeviceId, string Status, string? TenantId)>(new CommandDefinition(
                "SELECT DeviceId, Status, TenantId FROM ctl.HardwareDevice WHERE DeviceId = @Id;", new { request.Id }, cancellationToken: ct));
        if (!string.IsNullOrWhiteSpace(request.Id) && existing?.DeviceId is null) return ClientEndpoints.NotFound("No such device.");

        if (await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.HardwareDevice WHERE Serial = @Serial AND DeviceId <> ISNULL(@Id, N'');",
                new { Serial = request.Serial.Trim(), request.Id }, cancellationToken: ct)) is not null)
            return ClientEndpoints.Conflict("Another device already has that serial number.");

        var clientId = string.IsNullOrWhiteSpace(request.ClientId) ? null : request.ClientId;
        if (clientId is not null && await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.Tenant WHERE TenantId = @Id;", new { Id = clientId }, cancellationToken: ct)) is null)
            return ClientEndpoints.NotFound("No such client.");

        /* Giving an available device a client assigns it; taking the client
           away returns it to stock and clears where it was. */
        var status = existing?.Status ?? "available";
        if (status == "retired") return ClientEndpoints.Conflict("A retired device cannot be changed.");
        if (clientId is not null && status == "available") status = "assigned";
        if (clientId is null && status is "assigned" or "active" or "suspended") status = "available";

        var warrantyMonths = request.WarrantyMonths ?? (request.Type is "Printer" or "Label printer" ? 12 : 24);
        var warrantyEnds = request.WarrantyEndsOn ?? request.PurchasedOn?.AddMonths(warrantyMonths);

        string id;
        if (existing?.DeviceId is null)
        {
            var number = await control.ExecuteScalarAsync<int>(new CommandDefinition("SELECT NEXT VALUE FOR ctl.HardwareNumber;", cancellationToken: ct));
            id = $"DEV-{number}";
        }
        else id = existing.Value.DeviceId;

        await control.ExecuteAsync(new CommandDefinition(
            """
            MERGE ctl.HardwareDevice AS h
            USING (SELECT @Id AS DeviceId) AS src ON h.DeviceId = src.DeviceId
            WHEN MATCHED THEN UPDATE SET
                Serial = @Serial, Manufacturer = @Manufacturer, Model = @Model, DeviceType = @Type, Os = @Os,
                MacAddress = @Mac, Imei = @Imei, PurchasedOn = @PurchasedOn, WarrantyEndsOn = @WarrantyEnds,
                WarrantyMonths = @WarrantyMonths, Status = @Status, TenantId = @ClientId,
                BranchId = CASE WHEN @ClientId IS NULL THEN NULL ELSE @BranchId END,
                BranchName = CASE WHEN @ClientId IS NULL THEN NULL ELSE @BranchName END,
                TerminalId = CASE WHEN @ClientId IS NULL THEN NULL ELSE @TerminalId END,
                LastOnlineAtUtc = CASE WHEN @ClientId IS NULL THEN NULL ELSE LastOnlineAtUtc END,
                Notes = @Notes, UpdatedAtUtc = SYSUTCDATETIME()
            WHEN NOT MATCHED THEN INSERT
                (DeviceId, Serial, Manufacturer, Model, DeviceType, Os, MacAddress, Imei, PurchasedOn, WarrantyEndsOn,
                 WarrantyMonths, Status, TenantId, BranchId, BranchName, TerminalId, Notes)
            VALUES (@Id, @Serial, @Manufacturer, @Model, @Type, @Os, @Mac, @Imei, @PurchasedOn, @WarrantyEnds,
                    @WarrantyMonths, @Status, @ClientId, @BranchId, @BranchName, @TerminalId, @Notes);

            INSERT INTO ctl.HardwareDeviceEvent (DeviceId, Event, ByName, Detail)
            VALUES (@Id, @Event, @By, @Detail);
            """,
            new
            {
                Id = id, Serial = request.Serial.Trim(), request.Manufacturer, Model = request.Model.Trim(), request.Type,
                request.Os, Mac = request.MacAddress, Imei = request.Imei, request.PurchasedOn, WarrantyEnds = warrantyEnds,
                WarrantyMonths = warrantyMonths, Status = status, ClientId = clientId, request.BranchId, request.BranchName,
                request.TerminalId, request.Notes,
                Event = existing?.DeviceId is null ? "Received into stock" : status == "assigned" && existing?.Status == "available" ? "Assigned to client" : "Details updated",
                By = admin.Name, Detail = clientId
            }, cancellationToken: ct));

        var saved = (await HardwareAsync(control, null, ct)).First(d => d.id == id);
        return Results.Ok(await audit.ResultAsync("device.save", "Saved device", clientId, id,
            existing?.Status, status, null, "ctl.HardwareDevice", existing?.DeviceId is null ? "INSERT" : "UPDATE", 1, saved, ct));
    }

    /// <summary>Move a device along its lifecycle — only the moves the lifecycle allows.</summary>
    private static async Task<IResult> HardwareMoveAsync(string id, HardwareMoveRequest request, TenantCatalog catalog, CurrentAdmin admin, AdminAuditor audit, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var device = await control.QuerySingleOrDefaultAsync<(string Status, string? TenantId)>(new CommandDefinition(
            "SELECT Status, TenantId FROM ctl.HardwareDevice WHERE DeviceId = @Id;", new { Id = id }, cancellationToken: ct));
        if (device.Status is null) return ClientEndpoints.NotFound("No such device.");

        var to = request.To ?? "";
        if (!Lifecycle.TryGetValue(device.Status, out var allowed) || !allowed.Contains(to))
            return ClientEndpoints.Conflict($"A device cannot move from {device.Status} to {to}.");

        var clientId = request.ClientId ?? device.TenantId;
        if (to is "assigned" or "active" or "suspended" && clientId is null)
            return ClientEndpoints.Conflict("Assign it to a client first.");
        if (to == "retired" && string.IsNullOrWhiteSpace(request.Reason))
            return Results.BadRequest(new { code = "reason_required", message = "Retiring needs a reason; it cannot be undone." });

        var clears = to is "available" or "retired";
        await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.HardwareDevice
            SET Status = @To,
                TenantId = CASE WHEN @Clears = 1 THEN NULL ELSE @ClientId END,
                BranchId = CASE WHEN @Clears = 1 THEN NULL ELSE BranchId END,
                BranchName = CASE WHEN @Clears = 1 THEN NULL ELSE BranchName END,
                TerminalId = CASE WHEN @Clears = 1 THEN NULL ELSE TerminalId END,
                LastOnlineAtUtc = CASE WHEN @Clears = 1 THEN NULL ELSE LastOnlineAtUtc END,
                InstalledOn = CASE WHEN @To = N'active' THEN COALESCE(InstalledOn, CAST(SYSUTCDATETIME() AS DATE)) ELSE InstalledOn END,
                Notes = CASE WHEN @Reason IS NULL THEN Notes ELSE @Reason END,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE DeviceId = @Id;

            INSERT INTO ctl.HardwareDeviceEvent (DeviceId, Event, ByName, Detail)
            VALUES (@Id, @Event, @By, @Reason);
            """,
            new
            {
                Id = id, To = to, Clears = clears, ClientId = clientId, request.Reason, By = admin.Name,
                Event = to switch { "assigned" => "Assigned to client", "active" => "Activated", "suspended" => "Suspended", "retired" => "Retired", _ => "Returned to stock" }
            }, cancellationToken: ct));

        var saved = (await HardwareAsync(control, null, ct)).First(d => d.id == id);
        return Results.Ok(await audit.ResultAsync("device.status", $"Device moved to {to}", clientId, id,
            device.Status, to, request.Reason, "ctl.HardwareDevice", "UPDATE", 1, saved, ct));
    }

    /*============================================================== settings */

    private static async Task<IResult> SettingsAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var rows = await control.QueryAsync<(string Key, string Value)>(new CommandDefinition(
            "SELECT SettingKey, Value FROM ctl.Setting;", cancellationToken: ct));
        return Results.Ok(rows.ToDictionary(r => r.Key, r => (object)(int.TryParse(r.Value, out var n) ? n
            : bool.TryParse(r.Value, out var b) ? b : r.Value)));
    }

    private static async Task<IResult> SaveSettingsAsync(Dictionary<string, string> values, TenantCatalog catalog, CurrentAdmin admin, AdminAuditor audit, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var known = (await control.QueryAsync<(string Key, string Value)>(new CommandDefinition(
            "SELECT SettingKey, Value FROM ctl.Setting;", cancellationToken: ct))).ToDictionary(r => r.Key, r => r.Value);

        var changes = values.Where(v => known.TryGetValue(v.Key, out var was) && was != v.Value).ToList();
        if (values.Keys.FirstOrDefault(k => !known.ContainsKey(k)) is { } unknown)
            return Results.BadRequest(new { code = "unknown_setting", message = $"There is no setting '{unknown}'." });

        foreach (var (key, value) in changes)
            await control.ExecuteAsync(new CommandDefinition(
                "UPDATE ctl.Setting SET Value = @Value, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @By WHERE SettingKey = @Key;",
                new { Key = key, Value = value, By = admin.Name }, cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("settings.update", "Changed platform setting", null, null,
            string.Join("; ", changes.Select(c => $"{c.Key}={known[c.Key]}")),
            string.Join("; ", changes.Select(c => $"{c.Key}={c.Value}")), null, "ctl.Setting", "UPDATE", changes.Count, null, ct));
    }

    private static async Task<IResult> RulesAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await control.QueryAsync(new CommandDefinition(
            "SELECT RuleKey AS [key], Label AS label, Channel AS channel, IsOn AS [on] FROM ctl.NotificationRule ORDER BY SortOrder;",
            cancellationToken: ct)));
    }

    private static async Task<IResult> SaveRulesAsync(List<NotificationRuleRequest> rules, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var changed = 0;
        foreach (var rule in rules)
        {
            changed += await control.ExecuteAsync(new CommandDefinition(
                """
                UPDATE ctl.NotificationRule SET IsOn = @On, Channel = ISNULL(@Channel, Channel)
                WHERE RuleKey = @Key AND (IsOn <> @On OR (@Channel IS NOT NULL AND Channel <> @Channel));
                """, new { rule.Key, rule.On, rule.Channel }, cancellationToken: ct));
        }

        return Results.Ok(await audit.ResultAsync("settings.update", "Changed notification rules", null, null, null,
            string.Join(", ", rules.Select(r => $"{r.Key} {(r.On ? "on" : "off")}")), null, "ctl.NotificationRule", "UPDATE", changed, null, ct));
    }

    private static async Task<IResult> AdminsAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await control.QueryAsync(new CommandDefinition(
            """
            SELECT AdminId AS id, Name AS name, Mobile AS mobile, Email AS email, Role AS role,
                   ISNULL(Permissions, N'Everything') AS permissions, LastLoginAtUtc AS lastLogin, Status AS status,
                   MustChangePassword AS mustChangePassword
            FROM ctl.Admin ORDER BY CreatedAtUtc;
            """, cancellationToken: ct)));
    }

    private static async Task<IResult> CreateAdminAsync(AdminRequest request, TenantCatalog catalog, IPasswordHasher hasher, AdminAuditor audit, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Name) || string.IsNullOrWhiteSpace(request.Mobile))
            return Results.BadRequest(new { code = "required", message = "A name and a mobile number are required." });
        if (request.Password is not { Length: >= 8 })
            return Results.BadRequest(new { code = "weak_password", message = "A starting password of at least 8 characters is required." });

        await using var control = catalog.Control();
        if (await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.Admin WHERE Mobile = @Mobile;", new { Mobile = request.Mobile.Trim() }, cancellationToken: ct)) is not null)
            return ClientEndpoints.Conflict("An administrator already uses that mobile number.");

        var (hash, salt) = hasher.Hash(request.Password);
        var id = $"adm_{Guid.NewGuid():N}"[..16];

        await control.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO ctl.Admin (AdminId, Name, Mobile, Email, Role, Permissions, PasswordHash, PasswordSalt, MustChangePassword)
            VALUES (@Id, @Name, @Mobile, @Email, ISNULL(@Role, N'Operations'), @Permissions, @Hash, @Salt, 1);
            """,
            new { Id = id, Name = request.Name.Trim(), Mobile = request.Mobile.Trim(), request.Email, request.Role, request.Permissions, Hash = hash, Salt = salt },
            cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("admin.create", "Added administrator", null, id, null, request.Name,
            null, "ctl.Admin", "INSERT", 1, new { id }, ct));
    }

    /// <summary>
    /// Reset an administrator's password: every session they have ends now,
    /// and they must choose a new password at next sign-in.
    /// </summary>
    private static async Task<IResult> ResetPasswordAsync(
        string id, ReasonRequest request, TenantCatalog catalog, IPasswordHasher hasher, AdminSessions sessions,
        AdminAuditor audit, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return Results.BadRequest(new { code = "reason_required", message = "A reason is required." });

        var temporary = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(9))
            .Replace('+', 'x').Replace('/', 'y');
        var (hash, salt) = hasher.Hash(temporary);

        await using var control = catalog.Control();
        var affected = await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Admin
            SET PasswordHash = @Hash, PasswordSalt = @Salt, MustChangePassword = 1,
                SessionVersion = SessionVersion + 1, FailedLogins = 0, LockedUntilUtc = NULL
            WHERE AdminId = @Id;
            """, new { Hash = hash, Salt = salt, Id = id }, cancellationToken: ct));
        if (affected == 0) return ClientEndpoints.NotFound("No such administrator.");

        sessions.Evict(id);

        /* The temporary password is shown once, to the admin who reset it, and
           never stored or logged in plain text. */
        return Results.Ok(await audit.ResultAsync("admin.reset_password", "Reset administrator password", null, id,
            null, "sessions ended", request.Reason, "ctl.Admin", "UPDATE", 1, new { temporaryPassword = temporary }, ct));
    }

    private sealed record ConfigRow
    {
        public string BusinessType { get; init; } = "";
        public string PlanKey { get; init; } = "";
        public int? Users { get; init; }
        public int? Devices { get; init; }
        public int? Branches { get; init; }
        public int Duration { get; init; }
        public string DurationUnit { get; init; } = "";
        public long? AmountH { get; init; }
        public string Currency { get; init; } = "";
        public string Status { get; init; } = "";
        public bool CustomBilling { get; init; }
        public bool AutoRenew { get; init; }
        public int RenewalNoticeDays { get; init; }
    }
}
