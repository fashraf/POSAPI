using System.Collections.Concurrent;
using System.Data.Common;
using System.Diagnostics;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PosApi.Tenancy;

namespace PosApi.Features.SuperAdmin;

public sealed record IssueRequest(string? ClientId, string? Title, string? Description, string? Priority, string? Status, string? Assignee);

/// <summary>Overview, platform health and usage, the fleet, support, search and maintenance.</summary>
public static class PlatformEndpoints
{
    public static void MapPlatformEndpoints(this RouteGroupBuilder api)
    {
        api.MapGet("/overview", OverviewAsync).WithTags("SuperAdmin · Overview");
        api.MapGet("/activity", ActivityAsync).WithTags("SuperAdmin · Overview");
        api.MapGet("/search", SearchAsync).WithTags("SuperAdmin · Search");
        api.MapGet("/audit", AuditAsync).WithTags("SuperAdmin · Audit");

        var platform = api.MapGroup("/platform").WithTags("SuperAdmin · Platform");
        platform.MapGet("/health", HealthAsync);
        platform.MapGet("/devices", FleetDevicesAsync);
        platform.MapGet("/users", FleetUsersAsync);
        platform.MapGet("/usage", UsageAsync);
        platform.MapGet("/tenants", TenantsAsync);
        platform.MapPost("/migrate", MigrateAsync);
        platform.MapPost("/snapshot", SnapshotAsync);

        var support = api.MapGroup("/support").WithTags("SuperAdmin · Support");
        support.MapGet("/issues", ListIssuesAsync);
        support.MapPost("/issues", CreateIssueAsync);
        support.MapPost("/issues/{id}", UpdateIssueAsync);
    }

    /*============================================================ overview */

    private static async Task<IResult> OverviewAsync(
        string? range, DateOnly? from, DateOnly? to, ClientReader reader, TenantCatalog catalog,
        PlatformMetrics metrics, CancellationToken ct)
    {
        var window = DateWindow.Parse(range ?? "today", from, to);
        var clients = await reader.ListAsync(ct);
        var live = clients.Where(c => c.TenantStatus is "active" or "suspended").ToList();

        await using var control = catalog.Control();

        var stats = await control.QuerySingleAsync(new CommandDefinition(
            """
            SELECT
              (SELECT ISNULL(SUM(CAST(Transactions AS BIGINT)), 0) FROM ctl.TenantDailyStat WHERE StatDate >= @From AND StatDate < @To) AS Tx,
              (SELECT ISNULL(SUM(SalesH), 0) FROM ctl.TenantDailyStat WHERE StatDate >= @From AND StatDate < @To) AS Sales,
              (SELECT ISNULL(SUM(CAST(Transactions AS BIGINT)), 0) FROM ctl.TenantDailyStat WHERE StatDate >= @PFrom AND StatDate < @PTo) AS PrevTx,
              (SELECT ISNULL(SUM(SalesH), 0) FROM ctl.TenantDailyStat WHERE StatDate >= @PFrom AND StatDate < @PTo) AS PrevSales,
              (SELECT COUNT(*) FROM ctl.Tenant WHERE Status IN (N'active', N'suspended') AND CreatedAtUtc < @PTo) AS PrevClients,
              (SELECT COUNT(*) FROM ctl.Issue WHERE Status <> N'resolved') AS OpenIssues,
              (SELECT COUNT(*) FROM ctl.Issue WHERE OpenedAtUtc < @PTo AND (ResolvedAtUtc IS NULL OR ResolvedAtUtc >= @PTo)) AS PrevIssues;
            """,
            new { From = window.From.Date, To = window.To.Date, PFrom = window.PreviousFrom.Date, PTo = window.PreviousTo.Date },
            cancellationToken: ct));

        var subs = (await control.QueryAsync<(bool IsTrial, string Cycle, long? Custom, long? Monthly, long? Annual, DateTime Created, DateTime? Cancelled)>(
            new CommandDefinition(
                """
                SELECT s.IsTrial, s.Cycle, s.CustomMonthlyH, p.MonthlyH, p.AnnualH, s.CreatedAtUtc, s.CancelledAtUtc
                FROM ctl.Subscription AS s JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey;
                """, cancellationToken: ct))).ToList();
        long previousMrr = subs
            .Where(s => !s.IsTrial && s.Created <= window.PreviousTo && (s.Cancelled is null || s.Cancelled > window.PreviousTo))
            .Sum(s => s.Custom ?? (s.Cycle == "monthly" ? s.Monthly : s.Annual / 12) ?? 0);

        var minutes = (int)Math.Min(window.Length.TotalMinutes, 24 * 60);
        var now = metrics.Over(Math.Max(1, minutes));
        var before = metrics.Over(Math.Max(1, minutes), Math.Max(1, minutes));
        double Uptime(PlatformMetrics.Window w) => w.Requests == 0 ? 100 : Math.Round(100.0 * (w.Requests - w.Errors) / w.Requests, 2);

        object Kpi(double total, double previous) => new { total, previous };

        return Results.Ok(new
        {
            clients = Kpi(live.Count, (int)stats.PrevClients),
            active = Kpi(live.Count(c => c.Status == "active"), live.Count(c => c.Status == "active")),
            trial = Kpi(live.Count(c => c.Status == "trial"), live.Count(c => c.Status == "trial")),
            suspended = Kpi(live.Count(c => c.Status == "suspended"), live.Count(c => c.Status == "suspended")),
            devices = Kpi(live.Sum(c => c.Devices), live.Sum(c => c.Devices)),
            devicesOnline = Kpi(live.Sum(c => c.DevicesOnline), live.Sum(c => c.DevicesOnline)),
            transactions = Kpi((long)stats.Tx, (long)stats.PrevTx),
            clientSalesH = Kpi((long)stats.Sales, (long)stats.PrevSales),
            mrrH = Kpi(live.Sum(c => c.MrrH), previousMrr),
            expiring = Kpi(live.Count(c => c.DaysToRenewal is >= 0 and <= 14), live.Count(c => c.DaysToRenewal is >= 0 and <= 14)),
            uptime = Kpi(Uptime(now), Uptime(before)),
            openIssues = Kpi((int)stats.OpenIssues, (int)stats.PrevIssues),
            collectedAtUtc = live.Max(c => c.CollectedAtUtc)
        });
    }

    private static async Task<IResult> ActivityAsync(int? take, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var rows = await control.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (@Take) CONCAT(N'EV-', e.EventId) AS id, e.AtUtc AS [at], e.Kind AS kind, e.Label AS label,
                   e.TenantId AS clientId, t.Name AS clientName, e.Detail AS detail, e.Severity AS severity
            FROM ctl.PlatformEvent AS e LEFT JOIN ctl.Tenant AS t ON t.TenantId = e.TenantId
            ORDER BY e.EventId DESC;
            """, new { Take = Math.Clamp(take ?? 12, 1, 200) }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> AuditAsync(string? clientId, int? take, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await AdminAuditor.ListAsync(control, string.IsNullOrWhiteSpace(clientId) ? null : clientId,
            null, Math.Clamp(take ?? 500, 1, 5000), ct));
    }

    /*============================================================== health */

    private static async Task<IResult> HealthAsync(
        TenantCatalog catalog, PlatformMetrics metrics, TenantSnapshotService snapshots,
        IOptions<TenancyOptions> options, CancellationToken ct)
    {
        var watch = Stopwatch.StartNew();
        await using var control = catalog.Control();
        await control.OpenAsync(ct);
        var dbMs = (int)watch.ElapsedMilliseconds;

        var tenants = await control.QuerySingleAsync(new CommandDefinition(
            """
            SELECT COUNT(*) AS Total,
                   SUM(CASE WHEN n.Reachable = 0 THEN 1 ELSE 0 END) AS Unreachable,
                   (SELECT COUNT(*) FROM ctl.PlatformEvent WHERE Kind = N'migration_failed' AND AtUtc >= DATEADD(DAY, -1, SYSUTCDATETIME())) AS FailedToday,
                   (SELECT COUNT(*) FROM ctl.PlatformEvent WHERE Kind = N'migration_failed'
                      AND AtUtc >= DATEADD(DAY, -2, SYSUTCDATETIME()) AND AtUtc < DATEADD(DAY, -1, SYSUTCDATETIME())) AS FailedYesterday
            FROM ctl.Tenant AS t LEFT JOIN ctl.TenantSnapshot AS n ON n.TenantId = t.TenantId
            WHERE t.Status IN (N'active', N'suspended');
            """, cancellationToken: ct));

        DateTime? lastBackup = null;
        try
        {
            lastBackup = await control.ExecuteScalarAsync<DateTime?>(new CommandDefinition(
                "SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset WHERE database_name = DB_NAME();", cancellationToken: ct));
        }
        catch (SqlException)
        {
            /* No permission on msdb: unknown, not "never". */
        }

        var hour = metrics.Over(60);
        var previousHour = metrics.Over(60, 60);
        var day = metrics.Over(24 * 60);
        double Rate(PlatformMetrics.Window w) => w.Requests == 0 ? 0 : Math.Round(100.0 * w.Errors / w.Requests, 2);
        double Up(PlatformMetrics.Window w) => w.Requests == 0 ? 100 : Math.Round(100.0 * (w.Requests - w.Errors) / w.Requests, 2);

        int total = tenants.Total, unreachable = tenants.Unreachable ?? 0;
        var snapshotLate = snapshots.LastRunAtUtc is null
            || DateTime.UtcNow - snapshots.LastRunAtUtc > TimeSpan.FromMinutes(options.Value.SnapshotMinutes * 2 + 1);

        return Results.Ok(new
        {
            services = new object[]
            {
                new { key = "api", label = "API", status = Rate(hour) > 5 ? "degraded" : "operational",
                      uptime = Up(day), latencyMs = (int?)Math.Round(hour.AverageMs), errorRate = Rate(hour) },
                new { key = "database", label = "Control database", status = dbMs > 1000 ? "degraded" : "operational",
                      uptime = 100.0, latencyMs = (int?)dbMs, errorRate = 0.0 },
                new { key = "tenants", label = "Tenant databases",
                      status = total == 0 || unreachable == 0 ? "operational" : unreachable == total ? "down" : "degraded",
                      uptime = total == 0 ? 100.0 : Math.Round(100.0 * (total - unreachable) / total, 2),
                      latencyMs = (int?)null, errorRate = total == 0 ? 0.0 : Math.Round(100.0 * unreachable / total, 2) },
                new { key = "jobs", label = "Background jobs",
                      status = snapshots.LastRunFailures > 0 || (int)tenants.FailedToday > 0 ? "degraded"
                             : snapshotLate ? "degraded" : "operational",
                      uptime = 100.0, latencyMs = (int?)null, errorRate = 0.0 },
            },
            metrics = new
            {
                apiResponseMs = Math.Round(hour.AverageMs),
                apiResponsePreviousMs = Math.Round(previousHour.AverageMs),
                errorRatePct = Rate(hour),
                errorRatePreviousPct = Rate(previousHour),
                failedJobs = snapshots.LastRunFailures + (int)tenants.FailedToday,
                failedJobsPrevious = (int)tenants.FailedYesterday,
                lastBackupAt = lastBackup,
                lastSnapshotAt = snapshots.LastRunAtUtc,
                metricsSince = metrics.StartedAtUtc,
                tenants = total,
                unreachableTenants = unreachable
            }
        });
    }

    /*=============================================================== fleet */

    /// <summary>Run a read against every live tenant database, a few at a time; unreachable ones are skipped.</summary>
    private static async Task<List<T>> FanOutAsync<T>(
        TenantCatalog catalog, Func<SqlConnection, string, string, Task<IEnumerable<T>>> read, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var tenants = (await control.QueryAsync<(string TenantId, string Name)>(new CommandDefinition(
            "SELECT TenantId, Name FROM ctl.Tenant WHERE Status IN (N'active', N'suspended');", cancellationToken: ct))).ToList();

        var bag = new ConcurrentBag<T>();
        await Parallel.ForEachAsync(tenants, new ParallelOptions { MaxDegreeOfParallelism = 6, CancellationToken = ct },
            async (t, token) =>
            {
                try
                {
                    var info = await catalog.GetAsync(t.TenantId, token);
                    if (info is null) return;
                    await using var db = new SqlConnection(info.ConnectionString);
                    await db.OpenAsync(token);
                    foreach (var row in await read(db, t.TenantId, t.Name)) bag.Add(row);
                }
                catch (SqlException)
                {
                    /* Marked unreachable by the snapshot; not fatal to the list. */
                }
            });

        return bag.ToList();
    }

    private static async Task<IResult> FleetDevicesAsync(TenantCatalog catalog, CancellationToken ct) =>
        Results.Ok(await FanOutAsync<object>(catalog, async (db, id, name) => await ClientEndpoints.Terminals(db, id, name, ct), ct));

    private static async Task<IResult> FleetUsersAsync(TenantCatalog catalog, CancellationToken ct) =>
        Results.Ok(await FanOutAsync<object>(catalog,
            async (db, id, name) => (await ClientEndpoints.TenantUsers(db, id, name, ct)).Cast<object>(), ct));

    private static async Task<IResult> UsageAsync(TenantCatalog catalog, PlatformMetrics metrics, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var s = await control.QuerySingleAsync(new CommandDefinition(
            """
            SELECT ISNULL(SUM(n.ApiRequestsToday), 0) AS ApiToday, ISNULL(SUM(CAST(n.ApiRequestsMonth AS BIGINT)), 0) AS ApiMonth,
                   ISNULL(SUM(n.TransactionsToday), 0) AS TxToday, ISNULL(SUM(CAST(n.TransactionsMonth AS BIGINT)), 0) AS TxMonth,
                   ISNULL(SUM(n.LoginsToday), 0) AS UsersToday, ISNULL(SUM(n.ActiveUsersMonth), 0) AS UsersMonth,
                   ISNULL(SUM(n.HeartbeatsToday), 0) AS HbToday, ISNULL(SUM(n.DbSizeMb), 0) AS DbMb,
                   CASE WHEN EXISTS (SELECT 1 FROM ctl.Subscription AS s JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey
                                     WHERE s.Status = N'active' AND p.StorageGb IS NULL) THEN NULL
                        ELSE (SELECT SUM(p.StorageGb) FROM ctl.Subscription AS s JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey
                              WHERE s.Status = N'active') END AS LimitGb
            FROM ctl.TenantSnapshot AS n JOIN ctl.Tenant AS t ON t.TenantId = n.TenantId
            WHERE t.Status IN (N'active', N'suspended');
            """, cancellationToken: ct));

        var minutesToday = Math.Max(1, (DateTime.UtcNow - DateTime.UtcNow.Date).TotalMinutes);
        var lastMinute = metrics.Over(1);
        var day = metrics.Over(24 * 60);
        var dbGb = Math.Round((double)(decimal)s.DbMb / 1024.0, 3);

        return Results.Ok(new
        {
            api = new { today = (int)s.ApiToday, month = (long)s.ApiMonth, perMinute = lastMinute.Requests, peakPerMinute = day.PeakPerMinute },
            transactions = new { today = (int)s.TxToday, month = (long)s.TxMonth, perMinute = Math.Round((int)s.TxToday / minutesToday, 2) },
            activeUsers = new { today = (int)s.UsersToday, month = (int)s.UsersMonth },
            heartbeats = new { today = (int)s.HbToday, perMinute = Math.Round((int)s.HbToday / minutesToday, 2) },
            storage = new { usedGb = dbGb, limitGb = (decimal?)s.LimitGb, databaseGb = dbGb, filesGb = 0 },
            /* No notification sender is configured yet; zeros, not invented figures. */
            notifications = new { today = 0, month = 0, failed = 0 }
        });
    }

    /// <summary>Tenant databases: where each one is and which migration it is on.</summary>
    private static async Task<IResult> TenantsAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await control.QueryAsync(new CommandDefinition(
            """
            SELECT t.TenantId AS id, t.Name AS name, t.DatabaseName AS databaseName, t.Status AS status,
                   t.Source AS source, t.SchemaVersion AS schemaVersion, t.MigratedAtUtc AS migratedAtUtc,
                   n.Reachable AS reachable, n.CollectedAtUtc AS collectedAtUtc, n.Error AS error, n.DbSizeMb AS dbSizeMb
            FROM ctl.Tenant AS t LEFT JOIN ctl.TenantSnapshot AS n ON n.TenantId = t.TenantId
            ORDER BY t.TenantId;
            """, cancellationToken: ct)));
    }

    private static async Task<IResult> MigrateAsync(
        TenantMigrationService migrations, AdminAuditor audit, CancellationToken ct)
    {
        var outcomes = await migrations.MigrateAllAsync(ct);
        var failed = outcomes.Count(o => o.Error is not null);
        var applied = outcomes.Sum(o => o.Applied.Count);

        return Results.Ok(await audit.ResultAsync("platform.migrate", "Updated tenant databases", null, null,
            null, $"{outcomes.Count} tenants, {applied} files applied, {failed} failed", null, "dbo.SchemaMigration",
            "UPDATE", applied, outcomes, ct));
    }

    private static async Task<IResult> SnapshotAsync(TenantSnapshotService snapshots, AdminAuditor audit, CancellationToken ct)
    {
        await snapshots.CollectAllAsync(ct);
        return Results.Ok(await audit.ResultAsync("platform.snapshot", "Refreshed client figures", null, null,
            null, $"{snapshots.LastRunFailures} unreachable", null, "ctl.TenantSnapshot", "UPDATE", 0, null, ct));
    }

    /*============================================================= support */

    public static async Task<IEnumerable<dynamic>> IssuesAsync(DbConnection control, string? tenantId, CancellationToken ct) =>
        await control.QueryAsync(new CommandDefinition(
            """
            SELECT i.IssueId AS id, i.TenantId AS clientId, t.Name AS clientName, i.Title AS title,
                   i.Description AS description, i.Priority AS priority, i.Status AS status,
                   i.OpenedAtUtc AS openedAt, i.ResolvedAtUtc AS resolvedAt,
                   DATEDIFF(HOUR, i.OpenedAtUtc, ISNULL(i.ResolvedAtUtc, SYSUTCDATETIME())) AS ageHours,
                   ISNULL(i.Assignee, N'Unassigned') AS assignee
            FROM ctl.Issue AS i JOIN ctl.Tenant AS t ON t.TenantId = i.TenantId
            WHERE @TenantId IS NULL OR i.TenantId = @TenantId
            ORDER BY CASE i.Status WHEN N'open' THEN 0 WHEN N'waiting' THEN 1 ELSE 2 END,
                     CASE i.Priority WHEN N'high' THEN 0 WHEN N'medium' THEN 1 ELSE 2 END, i.OpenedAtUtc DESC;
            """, new { TenantId = tenantId }, cancellationToken: ct));

    private static async Task<IResult> ListIssuesAsync(string? clientId, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await IssuesAsync(control, string.IsNullOrWhiteSpace(clientId) ? null : clientId, ct));
    }

    private static async Task<IResult> CreateIssueAsync(IssueRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.ClientId) || string.IsNullOrWhiteSpace(request.Title))
            return Results.BadRequest(new { code = "required", message = "A client and a title are required." });

        var priority = request.Priority is "high" or "low" ? request.Priority : "medium";
        await using var control = catalog.Control();

        if (await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.Tenant WHERE TenantId = @Id;", new { Id = request.ClientId }, cancellationToken: ct)) is null)
            return ClientEndpoints.NotFound();

        var number = await control.ExecuteScalarAsync<int>(new CommandDefinition("SELECT NEXT VALUE FOR ctl.IssueNumber;", cancellationToken: ct));
        var id = $"ISS-{number}";

        await control.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO ctl.Issue (IssueId, TenantId, Title, Description, Priority, Assignee)
            VALUES (@Id, @ClientId, @Title, @Description, @Priority, @Assignee);
            """, new { Id = id, request.ClientId, Title = request.Title.Trim(), request.Description, Priority = priority, request.Assignee },
            cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("issue.create", "Opened issue", request.ClientId, id,
            null, request.Title, null, "ctl.Issue", "INSERT", 1, new { id }, ct));
    }

    private static async Task<IResult> UpdateIssueAsync(string id, IssueRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (request.Status is not (null or "open" or "waiting" or "resolved") || request.Priority is not (null or "high" or "medium" or "low"))
            return Results.BadRequest(new { code = "bad_value", message = "Status is open, waiting or resolved; priority high, medium or low." });

        await using var control = catalog.Control();
        var before = await control.QuerySingleOrDefaultAsync<(string TenantId, string Status)>(new CommandDefinition(
            "SELECT TenantId, Status FROM ctl.Issue WHERE IssueId = @Id;", new { Id = id }, cancellationToken: ct));
        if (before.TenantId is null) return ClientEndpoints.NotFound("No such issue.");

        await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Issue
            SET Status = COALESCE(@Status, Status), Priority = COALESCE(@Priority, Priority),
                Assignee = COALESCE(@Assignee, Assignee), Title = COALESCE(@Title, Title),
                Description = COALESCE(@Description, Description),
                ResolvedAtUtc = CASE WHEN @Status = N'resolved' AND ResolvedAtUtc IS NULL THEN SYSUTCDATETIME()
                                     WHEN @Status IN (N'open', N'waiting') THEN NULL ELSE ResolvedAtUtc END
            WHERE IssueId = @Id;
            """, new { request.Status, request.Priority, request.Assignee, request.Title, request.Description, Id = id }, cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("issue.update", "Updated issue", before.TenantId, id,
            before.Status, request.Status ?? before.Status, null, "ctl.Issue", "UPDATE", 1, null, ct));
    }

    /*============================================================== search */

    private static async Task<IResult> SearchAsync(string? q, TenantCatalog catalog, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) return Results.Ok(Array.Empty<object>());

        var like = $"%{q.Trim().Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]")}%";
        await using var control = catalog.Control();

        var rows = await control.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (4) N'client' AS kind, t.TenantId AS id, t.Name AS title,
                   CONCAT(ISNULL(s.PlanKey, N'—'), N' · ', ISNULL(t.City, N'—'), N' · ', ISNULL(n.Branches, 0), N' branches') AS subtitle,
                   CONCAT(N'/superadmin/clients/', t.TenantId) AS [to]
            FROM ctl.Tenant AS t LEFT JOIN ctl.Subscription AS s ON s.TenantId = t.TenantId
            LEFT JOIN ctl.TenantSnapshot AS n ON n.TenantId = t.TenantId
            WHERE t.Name LIKE @Like OR t.NameAr LIKE @Like OR t.TenantId LIKE @Like OR t.PocName LIKE @Like
               OR t.PocMobile LIKE @Like OR t.PocEmail LIKE @Like OR t.VatNumber LIKE @Like OR t.CrNumber LIKE @Like
            UNION ALL
            SELECT TOP (4) N'device', h.DeviceId, CONCAT(ISNULL(h.Manufacturer + N' ', N''), h.Model, N' · ', h.Serial),
                   CONCAT(ISNULL(t.Name, N'Unassigned'), N' · ', ISNULL(h.BranchName, N'—'), N' · ', h.Status),
                   N'/superadmin/maintenance/devices'
            FROM ctl.HardwareDevice AS h LEFT JOIN ctl.Tenant AS t ON t.TenantId = h.TenantId
            WHERE h.Serial LIKE @Like OR h.DeviceId LIKE @Like OR h.MacAddress LIKE @Like OR h.Imei LIKE @Like
            UNION ALL
            SELECT TOP (4) N'user', d.Identifier, d.Identifier, CONCAT(t.Name, N' · ', d.Kind),
                   CONCAT(N'/superadmin/clients/', d.TenantId)
            FROM ctl.LoginDirectory AS d JOIN ctl.Tenant AS t ON t.TenantId = d.TenantId
            WHERE d.Identifier LIKE @Like
            UNION ALL
            SELECT TOP (4) N'subscription', s.SubscriptionId, CONCAT(s.SubscriptionId, N' · ', t.Name),
                   CONCAT(t.Name, N' · ', s.PlanKey, N' · renews ', CONVERT(NVARCHAR(10), s.RenewsOn, 23)),
                   N'/superadmin/subscriptions'
            FROM ctl.Subscription AS s JOIN ctl.Tenant AS t ON t.TenantId = s.TenantId
            WHERE s.SubscriptionId LIKE @Like
            UNION ALL
            SELECT TOP (4) N'invoice', i.InvoiceId, i.InvoiceId, CONCAT(t.Name, N' · ', i.Status), N'/superadmin/revenue/payments'
            FROM ctl.Invoice AS i JOIN ctl.Tenant AS t ON t.TenantId = i.TenantId
            WHERE i.InvoiceId LIKE @Like
            UNION ALL
            SELECT TOP (4) N'issue', i.IssueId, i.Title, CONCAT(t.Name, N' · ', i.Priority), N'/superadmin/support'
            FROM ctl.Issue AS i JOIN ctl.Tenant AS t ON t.TenantId = i.TenantId
            WHERE i.IssueId LIKE @Like OR i.Title LIKE @Like
            UNION ALL
            SELECT TOP (3) N'audit', CONCAT(N'AUD-', a.AuditId), a.Label,
                   CONCAT(ISNULL(t.Name, N'Platform'), N' · ', CONVERT(NVARCHAR(16), a.AtUtc, 120)), N'/superadmin/audit'
            FROM ctl.AdminAudit AS a LEFT JOIN ctl.Tenant AS t ON t.TenantId = a.TenantId
            WHERE CONCAT(N'AUD-', a.AuditId) LIKE @Like OR a.Label LIKE @Like OR a.Reason LIKE @Like;
            """, new { Like = like }, cancellationToken: ct));

        return Results.Ok(rows);
    }
}
