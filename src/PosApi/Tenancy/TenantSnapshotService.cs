using Dapper;
using Npgsql;
using Microsoft.Extensions.Options;

namespace PosApi.Tenancy;

/// <summary>
/// Collects each tenant's figures into the control database.
///
/// The console lists hundreds of clients with their branches, devices, sales
/// and activity. Opening every tenant database for every list refresh would
/// make the console's speed depend on the slowest tenant, so the figures are
/// collected here on a timer (and on demand for one client) and the lists read
/// the snapshot. A tenant that cannot be reached keeps its last figures and is
/// marked unreachable — never zeroed, which would read as "nobody sold
/// anything".
/// </summary>
public sealed class TenantSnapshotService : BackgroundService
{
    private readonly TenancyConnections _connections;
    private readonly TenancyOptions _options;
    private readonly ILogger<TenantSnapshotService> _logger;

    public DateTime? LastRunAtUtc { get; private set; }
    public int LastRunFailures { get; private set; }

    public TenantSnapshotService(
        TenancyConnections connections, IOptions<TenancyOptions> options, ILogger<TenantSnapshotService> logger)
    {
        _connections = connections;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        /* Give startup (and tenant migrations) a moment first. */
        await Task.Delay(TimeSpan.FromSeconds(10), stoppingToken);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await CollectAllAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Tenant snapshot pass failed.");
            }

            await Task.Delay(TimeSpan.FromMinutes(Math.Max(1, _options.SnapshotMinutes)), stoppingToken);
        }
    }

    public async Task CollectAllAsync(CancellationToken ct)
    {
        await using var control = new NpgsqlConnection(_connections.Control);
        var tenants = (await control.QueryAsync<(string TenantId, string DatabaseName)>(new CommandDefinition(
            "SELECT TenantId, DatabaseName FROM ctl.Tenant WHERE Status IN ('active', 'suspended');",
            cancellationToken: ct))).ToList();

        var failures = 0;

        /* A few at a time: enough to finish quickly, few enough not to load
           the server the tenants are trading on. */
        await Parallel.ForEachAsync(tenants, new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = ct },
            async (tenant, token) =>
            {
                if (!await CollectAsync(tenant.TenantId, tenant.DatabaseName, token))
                    Interlocked.Increment(ref failures);
            });

        LastRunAtUtc = DateTime.UtcNow;
        LastRunFailures = failures;
    }

    /// <summary>Collect one tenant now. False when its database could not be read.</summary>
    public async Task<bool> CollectAsync(string tenantId, string databaseName, CancellationToken ct)
    {
        await using var control = new NpgsqlConnection(_connections.Control);

        try
        {
            await using var tenant = new NpgsqlConnection(_connections.ForTenant(databaseName));
            await tenant.OpenAsync(ct);

            var figures = await tenant.QuerySingleAsync<Figures>(new CommandDefinition(
                """
                WITH Bounds AS (
                    SELECT date_trunc('day', now() AT TIME ZONE 'utc') AS Today,
                           date_trunc('month', now() AT TIME ZONE 'utc') AS Month),
                Tables AS (
                    SELECT schemaname || '.' || relname AS Name, n_live_tup AS Rows
                    FROM pg_stat_user_tables)
                SELECT
                    (SELECT COUNT(*)::int FROM core.Branch WHERE IsActive) AS Branches,
                    (SELECT COUNT(*)::int FROM device.PosDevice WHERE IsActive) AS Devices,
                    (SELECT COUNT(*)::int FROM device.PosDevice
                      WHERE IsActive AND LastHeartbeatAtUtc > (now() AT TIME ZONE 'utc') - make_interval(secs => @Window)) AS DevicesOnline,
                    (SELECT COUNT(*)::int FROM core.AppUser) AS Users,
                    (SELECT COUNT(*)::int FROM core.AppUser WHERE Status = 'active') AS ActiveUsers,
                    (SELECT COUNT(*) FROM sales.Sale WHERE Status = 'completed') AS Transactions,
                    (SELECT COALESCE(SUM(TotalH), 0)::bigint FROM sales.Sale WHERE Status = 'completed') AS SalesH,
                    (SELECT COUNT(*)::int FROM sales.Sale WHERE Status = 'completed' AND SoldAtUtc >= b.Today) AS TransactionsToday,
                    (SELECT COALESCE(SUM(TotalH), 0)::bigint FROM sales.Sale WHERE Status = 'completed' AND SoldAtUtc >= b.Today) AS SalesTodayH,
                    (SELECT COUNT(*)::int FROM sales.Sale WHERE Status = 'completed' AND SoldAtUtc >= b.Month) AS TransactionsMonth,
                    (SELECT COUNT(*)::int FROM core.AppUser WHERE LastLoginAtUtc >= b.Today) AS LoginsToday,
                    (SELECT COUNT(*)::int FROM device.DeviceHeartbeat WHERE ReceivedAtUtc >= b.Today) AS HeartbeatsToday,
                    (SELECT COUNT(*)::int FROM audit.RequestTiming WHERE OccurredAtUtc >= b.Today) AS ApiRequestsToday,
                    (SELECT COUNT(*)::int FROM audit.RequestTiming WHERE OccurredAtUtc >= b.Today AND StatusCode >= 500) AS ApiErrorsToday,
                    (SELECT COUNT(*)::int FROM audit.RequestTiming WHERE OccurredAtUtc >= b.Month) AS ApiRequestsMonth,
                    (SELECT COUNT(*)::int FROM core.AppUser WHERE LastLoginAtUtc >= b.Month) AS ActiveUsersMonth,
                    (SELECT MIN(OccurredAtUtc) FROM audit.AuditEntry WHERE Action = 'LOGIN') AS FirstLoginAtUtc,
                    (SELECT MAX(LastLoginAtUtc) FROM core.AppUser) AS LastLoginAtUtc,
                    (SELECT MAX(SoldAtUtc) FROM sales.Sale) AS LastTransactionAtUtc,
                    round(pg_database_size(current_database()) / 1048576.0, 2) AS DbSizeMb,
                    (SELECT COALESCE(SUM(Rows), 0)::bigint FROM Tables) AS DbRows,
                    (SELECT COUNT(*)::int FROM Tables) AS DbTables,
                    (SELECT Name FROM Tables ORDER BY Rows DESC LIMIT 1) AS LargestTable,
                    (SELECT Rows FROM Tables ORDER BY Rows DESC LIMIT 1) AS LargestTableRows
                FROM Bounds AS b;
                """, new { Window = 90 }, cancellationToken: ct));

            /* Daily sales: the whole history the first time, then the last few
               days (late sales and voids change recent days). */
            var known = await control.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM ctl.TenantDailyStat WHERE TenantId = @TenantId;",
                new { TenantId = tenantId }, cancellationToken: ct));

            var days = (await tenant.QueryAsync<(DateTime StatDate, int Transactions, long SalesH)>(new CommandDefinition(
                """
                SELECT SoldAtUtc::date::timestamp AS StatDate, COUNT(*)::int AS Transactions, COALESCE(SUM(TotalH), 0)::bigint AS SalesH
                FROM sales.Sale
                WHERE Status = 'completed' AND SoldAtUtc >= (now() AT TIME ZONE 'utc')::date - @Days
                GROUP BY SoldAtUtc::date;
                """, new { Days = known == 0 ? 800 : 7 }, cancellationToken: ct))).ToList();

            await control.OpenAsync(ct);
            await using var tx = await control.BeginTransactionAsync(ct);

            await control.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO ctl.TenantSnapshot
                    (TenantId, CollectedAtUtc, Reachable, Branches, Devices, DevicesOnline, Users, ActiveUsers,
                     Transactions, SalesH, TransactionsToday, SalesTodayH, TransactionsMonth, LoginsToday,
                     HeartbeatsToday, ApiRequestsToday, ApiErrorsToday, ApiRequestsMonth, ActiveUsersMonth,
                     FirstLoginAtUtc, LastLoginAtUtc,
                     LastTransactionAtUtc, DbSizeMb, DbRows, DbTables, LargestTable, LargestTableRows)
                VALUES
                    (@TenantId, now() AT TIME ZONE 'utc', true, @Branches, @Devices, @DevicesOnline, @Users, @ActiveUsers,
                     @Transactions, @SalesH, @TransactionsToday, @SalesTodayH, @TransactionsMonth, @LoginsToday,
                     @HeartbeatsToday, @ApiRequestsToday, @ApiErrorsToday, @ApiRequestsMonth, @ActiveUsersMonth,
                     @FirstLoginAtUtc, @LastLoginAtUtc,
                     @LastTransactionAtUtc, @DbSizeMb, @DbRows, @DbTables, @LargestTable, COALESCE(@LargestTableRows, 0))
                ON CONFLICT (TenantId) DO UPDATE SET
                    CollectedAtUtc = EXCLUDED.CollectedAtUtc, Reachable = true, Error = NULL,
                    Branches = EXCLUDED.Branches, Devices = EXCLUDED.Devices, DevicesOnline = EXCLUDED.DevicesOnline,
                    Users = EXCLUDED.Users, ActiveUsers = EXCLUDED.ActiveUsers, Transactions = EXCLUDED.Transactions,
                    SalesH = EXCLUDED.SalesH, TransactionsToday = EXCLUDED.TransactionsToday,
                    SalesTodayH = EXCLUDED.SalesTodayH, TransactionsMonth = EXCLUDED.TransactionsMonth,
                    LoginsToday = EXCLUDED.LoginsToday, HeartbeatsToday = EXCLUDED.HeartbeatsToday,
                    ApiRequestsToday = EXCLUDED.ApiRequestsToday, ApiErrorsToday = EXCLUDED.ApiErrorsToday,
                    ApiRequestsMonth = EXCLUDED.ApiRequestsMonth, ActiveUsersMonth = EXCLUDED.ActiveUsersMonth,
                    FirstLoginAtUtc = EXCLUDED.FirstLoginAtUtc, LastLoginAtUtc = EXCLUDED.LastLoginAtUtc,
                    LastTransactionAtUtc = EXCLUDED.LastTransactionAtUtc, DbSizeMb = EXCLUDED.DbSizeMb,
                    DbRows = EXCLUDED.DbRows, DbTables = EXCLUDED.DbTables, LargestTable = EXCLUDED.LargestTable,
                    LargestTableRows = EXCLUDED.LargestTableRows;
                """,
                new
                {
                    TenantId = tenantId, figures.Branches, figures.Devices, figures.DevicesOnline, figures.Users,
                    figures.ActiveUsers, figures.Transactions, figures.SalesH, figures.TransactionsToday,
                    figures.SalesTodayH, figures.TransactionsMonth, figures.LoginsToday, figures.HeartbeatsToday,
                    figures.ApiRequestsToday, figures.ApiErrorsToday, figures.ApiRequestsMonth, figures.ActiveUsersMonth,
                    figures.FirstLoginAtUtc, figures.LastLoginAtUtc,
                    figures.LastTransactionAtUtc, figures.DbSizeMb, figures.DbRows, figures.DbTables,
                    figures.LargestTable, figures.LargestTableRows
                }, tx, cancellationToken: ct));

            foreach (var day in days)
            {
                await control.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT INTO ctl.TenantDailyStat (TenantId, StatDate, Transactions, SalesH)
                    VALUES (@TenantId, @StatDate, @Transactions, @SalesH)
                    ON CONFLICT (TenantId, StatDate) DO UPDATE SET
                        Transactions = EXCLUDED.Transactions, SalesH = EXCLUDED.SalesH;
                    """,
                    new { TenantId = tenantId, StatDate = day.StatDate.Date, day.Transactions, day.SalesH },
                    tx, cancellationToken: ct));
            }

            /* The hardware register's last-online comes from the terminal's
               own heartbeat, matched by serial. */
            var heartbeats = (await tenant.QueryAsync<(string Serial, DateTime At)>(new CommandDefinition(
                "SELECT SerialNumber, LastHeartbeatAtUtc FROM device.PosDevice WHERE SerialNumber IS NOT NULL AND LastHeartbeatAtUtc IS NOT NULL;",
                cancellationToken: ct))).ToList();

            foreach (var hb in heartbeats)
            {
                await control.ExecuteAsync(new CommandDefinition(
                    "UPDATE ctl.HardwareDevice SET LastOnlineAtUtc = @At WHERE Serial = @Serial AND TenantId = @TenantId AND (LastOnlineAtUtc IS NULL OR LastOnlineAtUtc < @At);",
                    new { hb.At, hb.Serial, TenantId = tenantId }, tx, cancellationToken: ct));
            }

            await tx.CommitAsync(ct);
            return true;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning("Could not collect tenant {TenantId}: {Message}", tenantId, ex.Message);

            await using var mark = new NpgsqlConnection(_connections.Control);
            await mark.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO ctl.TenantSnapshot (TenantId, CollectedAtUtc, Reachable, Error)
                VALUES (@TenantId, now() AT TIME ZONE 'utc', false, @Error)
                ON CONFLICT (TenantId) DO UPDATE SET
                    Reachable = false, Error = EXCLUDED.Error, CollectedAtUtc = EXCLUDED.CollectedAtUtc;
                """,
                new { TenantId = tenantId, Error = ex.Message.Length > 1000 ? ex.Message[..1000] : ex.Message },
                cancellationToken: ct));

            return false;
        }
    }

    private sealed record Figures
    {
        public int Branches { get; init; }
        public int Devices { get; init; }
        public int DevicesOnline { get; init; }
        public int Users { get; init; }
        public int ActiveUsers { get; init; }
        public long Transactions { get; init; }
        public long SalesH { get; init; }
        public int TransactionsToday { get; init; }
        public long SalesTodayH { get; init; }
        public int TransactionsMonth { get; init; }
        public int LoginsToday { get; init; }
        public int HeartbeatsToday { get; init; }
        public int ApiRequestsToday { get; init; }
        public int ApiErrorsToday { get; init; }
        public int ApiRequestsMonth { get; init; }
        public int ActiveUsersMonth { get; init; }
        public DateTime? FirstLoginAtUtc { get; init; }
        public DateTime? LastLoginAtUtc { get; init; }
        public DateTime? LastTransactionAtUtc { get; init; }
        public decimal DbSizeMb { get; init; }
        public long DbRows { get; init; }
        public int DbTables { get; init; }
        public string? LargestTable { get; init; }
        public long? LargestTableRows { get; init; }
    }
}
