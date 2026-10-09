using Dapper;
using Microsoft.Data.SqlClient;
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
        await using var control = new SqlConnection(_connections.Control);
        var tenants = (await control.QueryAsync<(string TenantId, string DatabaseName)>(new CommandDefinition(
            "SELECT TenantId, DatabaseName FROM ctl.Tenant WHERE Status IN (N'active', N'suspended');",
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
        await using var control = new SqlConnection(_connections.Control);

        try
        {
            await using var tenant = new SqlConnection(_connections.ForTenant(databaseName));
            await tenant.OpenAsync(ct);

            var figures = await tenant.QuerySingleAsync<Figures>(new CommandDefinition(
                """
                DECLARE @Today DATETIME2(3) = CAST(CAST(SYSUTCDATETIME() AS DATE) AS DATETIME2(3));
                DECLARE @Month DATETIME2(3) = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);

                SELECT
                    (SELECT COUNT(*) FROM core.Branch WHERE IsActive = 1) AS Branches,
                    (SELECT COUNT(*) FROM device.PosDevice WHERE IsActive = 1) AS Devices,
                    (SELECT COUNT(*) FROM device.PosDevice
                      WHERE IsActive = 1 AND LastHeartbeatAtUtc > DATEADD(SECOND, -@Window, SYSUTCDATETIME())) AS DevicesOnline,
                    (SELECT COUNT(*) FROM core.AppUser) AS Users,
                    (SELECT COUNT(*) FROM core.AppUser WHERE Status = N'active') AS ActiveUsers,
                    (SELECT COUNT_BIG(*) FROM sales.Sale WHERE Status = N'completed') AS Transactions,
                    (SELECT ISNULL(SUM(TotalH), 0) FROM sales.Sale WHERE Status = N'completed') AS SalesH,
                    (SELECT COUNT(*) FROM sales.Sale WHERE Status = N'completed' AND SoldAtUtc >= @Today) AS TransactionsToday,
                    (SELECT ISNULL(SUM(TotalH), 0) FROM sales.Sale WHERE Status = N'completed' AND SoldAtUtc >= @Today) AS SalesTodayH,
                    (SELECT COUNT(*) FROM sales.Sale WHERE Status = N'completed' AND SoldAtUtc >= @Month) AS TransactionsMonth,
                    (SELECT COUNT(*) FROM core.AppUser WHERE LastLoginAtUtc >= @Today) AS LoginsToday,
                    (SELECT COUNT(*) FROM device.DeviceHeartbeat WHERE ReceivedAtUtc >= @Today) AS HeartbeatsToday,
                    (SELECT COUNT(*) FROM audit.RequestTiming WHERE OccurredAtUtc >= @Today) AS ApiRequestsToday,
                    (SELECT COUNT(*) FROM audit.RequestTiming WHERE OccurredAtUtc >= @Today AND StatusCode >= 500) AS ApiErrorsToday,
                    (SELECT COUNT(*) FROM audit.RequestTiming WHERE OccurredAtUtc >= @Month) AS ApiRequestsMonth,
                    (SELECT COUNT(*) FROM core.AppUser WHERE LastLoginAtUtc >= @Month) AS ActiveUsersMonth,
                    (SELECT MIN(OccurredAtUtc) FROM audit.AuditEntry WHERE Action = N'LOGIN') AS FirstLoginAtUtc,
                    (SELECT MAX(LastLoginAtUtc) FROM core.AppUser) AS LastLoginAtUtc,
                    (SELECT MAX(SoldAtUtc) FROM sales.Sale) AS LastTransactionAtUtc,
                    (SELECT CAST(SUM(CAST(size AS BIGINT)) * 8 / 1024.0 AS DECIMAL(12,2)) FROM sys.database_files) AS DbSizeMb,
                    (SELECT ISNULL(SUM(p.rows), 0) FROM sys.partitions AS p JOIN sys.tables AS t ON t.object_id = p.object_id
                      WHERE p.index_id IN (0, 1)) AS DbRows,
                    (SELECT COUNT(*) FROM sys.tables) AS DbTables,
                    (SELECT TOP (1) CONCAT(SCHEMA_NAME(t.schema_id), N'.', t.name)
                       FROM sys.partitions AS p JOIN sys.tables AS t ON t.object_id = p.object_id
                      WHERE p.index_id IN (0, 1) GROUP BY t.schema_id, t.name ORDER BY SUM(p.rows) DESC) AS LargestTable,
                    (SELECT TOP (1) SUM(p.rows)
                       FROM sys.partitions AS p JOIN sys.tables AS t ON t.object_id = p.object_id
                      WHERE p.index_id IN (0, 1) GROUP BY t.object_id ORDER BY SUM(p.rows) DESC) AS LargestTableRows;
                """, new { Window = 90 }, cancellationToken: ct));

            /* Daily sales: the whole history the first time, then the last few
               days (late sales and voids change recent days). */
            var known = await control.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM ctl.TenantDailyStat WHERE TenantId = @TenantId;",
                new { TenantId = tenantId }, cancellationToken: ct));

            var days = (await tenant.QueryAsync<(DateTime StatDate, int Transactions, long SalesH)>(new CommandDefinition(
                """
                SELECT CAST(SoldAtUtc AS DATE) AS StatDate, COUNT(*) AS Transactions, ISNULL(SUM(TotalH), 0) AS SalesH
                FROM sales.Sale
                WHERE Status = N'completed' AND SoldAtUtc >= DATEADD(DAY, -@Days, CAST(SYSUTCDATETIME() AS DATE))
                GROUP BY CAST(SoldAtUtc AS DATE);
                """, new { Days = known == 0 ? 800 : 7 }, cancellationToken: ct))).ToList();

            await control.OpenAsync(ct);
            await using var tx = await control.BeginTransactionAsync(ct);

            await control.ExecuteAsync(new CommandDefinition(
                """
                MERGE ctl.TenantSnapshot AS s
                USING (SELECT @TenantId AS TenantId) AS src ON s.TenantId = src.TenantId
                WHEN MATCHED THEN UPDATE SET
                    CollectedAtUtc = SYSUTCDATETIME(), Reachable = 1, Error = NULL,
                    Branches = @Branches, Devices = @Devices, DevicesOnline = @DevicesOnline, Users = @Users,
                    ActiveUsers = @ActiveUsers, Transactions = @Transactions, SalesH = @SalesH,
                    TransactionsToday = @TransactionsToday, SalesTodayH = @SalesTodayH,
                    TransactionsMonth = @TransactionsMonth, LoginsToday = @LoginsToday,
                    HeartbeatsToday = @HeartbeatsToday, ApiRequestsToday = @ApiRequestsToday,
                    ApiErrorsToday = @ApiErrorsToday, ApiRequestsMonth = @ApiRequestsMonth,
                    ActiveUsersMonth = @ActiveUsersMonth, FirstLoginAtUtc = @FirstLoginAtUtc,
                    LastLoginAtUtc = @LastLoginAtUtc, LastTransactionAtUtc = @LastTransactionAtUtc,
                    DbSizeMb = @DbSizeMb, DbRows = @DbRows, DbTables = @DbTables,
                    LargestTable = @LargestTable, LargestTableRows = ISNULL(@LargestTableRows, 0)
                WHEN NOT MATCHED THEN INSERT
                    (TenantId, CollectedAtUtc, Reachable, Branches, Devices, DevicesOnline, Users, ActiveUsers,
                     Transactions, SalesH, TransactionsToday, SalesTodayH, TransactionsMonth, LoginsToday,
                     HeartbeatsToday, ApiRequestsToday, ApiErrorsToday, ApiRequestsMonth, ActiveUsersMonth,
                     FirstLoginAtUtc, LastLoginAtUtc,
                     LastTransactionAtUtc, DbSizeMb, DbRows, DbTables, LargestTable, LargestTableRows)
                VALUES
                    (@TenantId, SYSUTCDATETIME(), 1, @Branches, @Devices, @DevicesOnline, @Users, @ActiveUsers,
                     @Transactions, @SalesH, @TransactionsToday, @SalesTodayH, @TransactionsMonth, @LoginsToday,
                     @HeartbeatsToday, @ApiRequestsToday, @ApiErrorsToday, @ApiRequestsMonth, @ActiveUsersMonth,
                     @FirstLoginAtUtc, @LastLoginAtUtc,
                     @LastTransactionAtUtc, @DbSizeMb, @DbRows, @DbTables, @LargestTable, ISNULL(@LargestTableRows, 0));
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
                    MERGE ctl.TenantDailyStat AS d
                    USING (SELECT @TenantId AS TenantId, @StatDate AS StatDate) AS src
                       ON d.TenantId = src.TenantId AND d.StatDate = src.StatDate
                    WHEN MATCHED THEN UPDATE SET Transactions = @Transactions, SalesH = @SalesH
                    WHEN NOT MATCHED THEN INSERT (TenantId, StatDate, Transactions, SalesH)
                         VALUES (@TenantId, @StatDate, @Transactions, @SalesH);
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

            await using var mark = new SqlConnection(_connections.Control);
            await mark.ExecuteAsync(new CommandDefinition(
                """
                MERGE ctl.TenantSnapshot AS s
                USING (SELECT @TenantId AS TenantId) AS src ON s.TenantId = src.TenantId
                WHEN MATCHED THEN UPDATE SET Reachable = 0, Error = @Error, CollectedAtUtc = SYSUTCDATETIME()
                WHEN NOT MATCHED THEN INSERT (TenantId, CollectedAtUtc, Reachable, Error)
                     VALUES (@TenantId, SYSUTCDATETIME(), 0, @Error);
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
