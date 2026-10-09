using Dapper;
using PosApi.Tenancy;

namespace PosApi.Features.SuperAdmin;

public sealed record PocDto(
    string? Name, string? Username, string? Mobile, string? Email, string Role, string Status, DateTime? LastLoginAt);

public sealed record HealthDto(string Band, IReadOnlyList<string> Reasons, IReadOnlyList<string> Rules);

/// <summary>A client (tenant) as every console list and the detail page show it.</summary>
public sealed record ClientDto
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public string? NameAr { get; init; }
    public string? Plan { get; init; }
    public string? Region { get; init; }
    public string? Industry { get; init; }
    public string? BusinessType { get; init; }
    public required string Status { get; init; }
    public string? TenantStatus { get; init; }
    public int Branches { get; init; }
    public int Devices { get; init; }
    public int DevicesOnline { get; init; }
    public int Users { get; init; }
    public long Transactions { get; init; }
    public long SalesH { get; init; }
    public long MrrH { get; init; }
    public DateOnly CreatedOn { get; init; }
    public DateOnly? SubscriptionEnds { get; init; }
    public int? DaysToRenewal { get; init; }
    public int DaysSinceActivity { get; init; }
    public double ApiErrorRate { get; init; }
    public bool PaymentOverdue { get; init; }
    public required PocDto Poc { get; init; }
    public string? PocName { get; init; }
    public string? PocMobile { get; init; }
    public long BalanceH { get; init; }
    public IReadOnlyList<string> PaymentMethods { get; init; } = [];
    public decimal VatRate { get; init; }
    public bool PricesIncludeVat { get; init; }
    public string? CrNumber { get; init; }
    public string? VatNumber { get; init; }
    public string? Email { get; init; }
    public string? Phone { get; init; }
    public string? RegisteredBy { get; init; }
    public string? ActivatedBy { get; init; }
    public DateTime? ActivatedAtUtc { get; init; }
    public bool IsTrial { get; init; }
    public int? TrialDays { get; init; }
    public DateOnly? FirstLoginOn { get; init; }
    public DateOnly? LastRenewedOn { get; init; }
    public int Renewals { get; init; }
    public DateTime? LastLoginAt { get; init; }
    public DateTime? LastTransactionAt { get; init; }
    public decimal StorageGb { get; init; }
    public required HealthDto Health { get; init; }
    public int OpenIssues { get; init; }
    public string? SubscriptionId { get; init; }
    public string? Cycle { get; init; }
    public string? SuspendReason { get; init; }
    public DateTime? SuspendedAtUtc { get; init; }
    public string? DatabaseName { get; init; }
    public string? SchemaVersion { get; init; }
    public string? Source { get; init; }
    public bool Reachable { get; init; }
    public DateTime? CollectedAtUtc { get; init; }
    public string? CollectError { get; init; }
    public string? BranchAddress { get; init; }
    public string? Latitude { get; init; }
    public string? Longitude { get; init; }
}

/// <summary>
/// Builds clients from the control database: the tenant, its subscription and
/// plan, its last snapshot, its balance and open issues, and its health.
/// </summary>
public sealed class ClientReader
{
    /// <summary>The health rules, in the order the console lists them.</summary>
    public static readonly (string Key, string Label, string Weight)[] Rules =
    [
        ("suspended", "Account suspended", "critical"),
        ("payment", "Payment overdue", "critical"),
        ("no_activity", "No activity for 7 days or more", "critical"),
        ("devices_offline", "3 or more POS devices offline", "attention"),
        ("expiring", "Subscription ends within 14 days", "attention"),
        ("api_errors", "API error rate above 2%", "attention"),
        ("quiet", "Quiet for 2 to 6 days", "attention"),
    ];

    private readonly TenantCatalog _catalog;

    public ClientReader(TenantCatalog catalog) => _catalog = catalog;

    public async Task<IReadOnlyList<ClientDto>> ListAsync(CancellationToken ct, string? tenantId = null)
    {
        await using var control = _catalog.Control();

        var rows = await control.QueryAsync<Row>(new CommandDefinition(
            """
            SELECT t.TenantId, t.Name, t.NameAr, t.BusinessType, t.City, t.Status AS TenantStatus, t.Source,
                   t.CrNumber, t.VatNumber, t.Email, t.Phone, t.DatabaseName, t.SchemaVersion,
                   t.PocName, t.PocUsername, t.PocMobile, t.PocEmail, t.PaymentMethods, t.DefaultVat, t.PricesIncludeVat,
                   t.RegisteredBy, t.ActivatedBy, t.ActivatedAtUtc, t.SuspendedAtUtc, t.SuspendReason, t.CreatedAtUtc,
                   t.BranchAddress, t.Latitude, t.Longitude,
                   s.SubscriptionId, s.PlanKey, s.Cycle, s.IsTrial, s.TrialDays, s.RenewsOn, s.Status AS SubscriptionStatus,
                   s.Renewals, s.LastRenewedOn, s.CustomMonthlyH,
                   p.MonthlyH, p.AnnualH,
                   n.Reachable, n.CollectedAtUtc, n.Error AS CollectError, n.Branches, n.Devices, n.DevicesOnline,
                   n.Users, n.Transactions, n.SalesH, n.ApiRequestsToday, n.ApiErrorsToday,
                   n.FirstLoginAtUtc, n.LastLoginAtUtc, n.LastTransactionAtUtc, n.DbSizeMb,
                   (SELECT ISNULL(SUM(i.AmountH), 0) FROM ctl.Invoice AS i
                     WHERE i.TenantId = t.TenantId AND i.Status IN (N'pending', N'failed')) AS BalanceH,
                   CAST(CASE WHEN EXISTS (SELECT 1 FROM ctl.Invoice AS i WHERE i.TenantId = t.TenantId
                         AND (i.Status = N'failed' OR (i.Status = N'pending' AND i.IssuedOn < DATEADD(DAY, -14, CAST(SYSUTCDATETIME() AS DATE)))))
                        THEN 1 ELSE 0 END AS BIT) AS PaymentOverdue,
                   (SELECT COUNT(*) FROM ctl.Issue AS x WHERE x.TenantId = t.TenantId AND x.Status <> N'resolved') AS OpenIssues
            FROM ctl.Tenant AS t
            LEFT JOIN ctl.Subscription AS s ON s.TenantId = t.TenantId
            LEFT JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey
            LEFT JOIN ctl.TenantSnapshot AS n ON n.TenantId = t.TenantId
            WHERE @TenantId IS NULL OR t.TenantId = @TenantId
            ORDER BY t.CreatedAtUtc DESC;
            """, new { TenantId = tenantId }, cancellationToken: ct));

        return rows.Select(Build).ToList();
    }

    public async Task<ClientDto?> GetAsync(string tenantId, CancellationToken ct) =>
        (await ListAsync(ct, tenantId)).SingleOrDefault();

    /// <summary>Monthly recurring revenue: a trial or a suspended client pays nothing this month.</summary>
    public static long Mrr(bool isTrial, string? subscriptionStatus, string? tenantStatus, string? cycle,
                           long? customMonthlyH, long? monthlyH, long? annualH)
    {
        if (isTrial || subscriptionStatus != "active" || tenantStatus != "active") return 0;
        return customMonthlyH ?? (cycle == "monthly" ? monthlyH : annualH / 12) ?? 0;
    }

    private static ClientDto Build(Row r)
    {
        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var lastActivity = new[] { r.LastLoginAtUtc, r.LastTransactionAtUtc }.Max() ?? r.CreatedAtUtc;
        var daysSinceActivity = Math.Max(0, (int)(DateTime.UtcNow - lastActivity).TotalDays);
        int? daysToRenewal = r.RenewsOn is { } renews ? renews.DayNumber - today.DayNumber : null;
        var apiErrorRate = r.ApiRequestsToday is > 0
            ? Math.Round(100.0 * (r.ApiErrorsToday ?? 0) / r.ApiRequestsToday.Value, 2) : 0;
        var devicesOffline = (r.Devices ?? 0) - (r.DevicesOnline ?? 0);

        var status = r.TenantStatus switch
        {
            "suspended" => "suspended",
            "active" when r.IsTrial == true => "trial",
            "active" => "active",
            var other => other ?? "active"
        };

        var failed = new List<string>();
        if (status == "suspended") failed.Add("suspended");
        if (r.PaymentOverdue) failed.Add("payment");
        if (status != "suspended" && daysSinceActivity >= 7) failed.Add("no_activity");
        if (devicesOffline >= 3) failed.Add("devices_offline");
        if (daysToRenewal is <= 14) failed.Add("expiring");
        if (apiErrorRate > 2) failed.Add("api_errors");
        if (daysSinceActivity is >= 2 and < 7) failed.Add("quiet");

        var band = failed.Any(f => Rules.First(x => x.Key == f).Weight == "critical") ? "critical"
                 : failed.Count > 0 ? "attention" : "healthy";

        return new ClientDto
        {
            Id = r.TenantId,
            Name = r.Name,
            NameAr = r.NameAr,
            Plan = r.PlanKey,
            Region = r.City,
            Industry = r.BusinessType,
            BusinessType = r.BusinessType,
            Status = status,
            TenantStatus = r.TenantStatus,
            Branches = r.Branches ?? 0,
            Devices = r.Devices ?? 0,
            DevicesOnline = r.DevicesOnline ?? 0,
            Users = r.Users ?? 0,
            Transactions = r.Transactions ?? 0,
            SalesH = r.SalesH ?? 0,
            MrrH = Mrr(r.IsTrial == true, r.SubscriptionStatus, r.TenantStatus, r.Cycle, r.CustomMonthlyH, r.MonthlyH, r.AnnualH),
            CreatedOn = DateOnly.FromDateTime(r.CreatedAtUtc),
            SubscriptionEnds = r.RenewsOn,
            DaysToRenewal = daysToRenewal,
            DaysSinceActivity = daysSinceActivity,
            ApiErrorRate = apiErrorRate,
            PaymentOverdue = r.PaymentOverdue,
            Poc = new PocDto(r.PocName, r.PocUsername, r.PocMobile, r.PocEmail, "Owner",
                             status == "suspended" ? "suspended" : "active", r.LastLoginAtUtc),
            PocName = r.PocName,
            PocMobile = r.PocMobile,
            BalanceH = r.BalanceH,
            PaymentMethods = (r.PaymentMethods ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries),
            VatRate = r.DefaultVat,
            PricesIncludeVat = r.PricesIncludeVat,
            CrNumber = r.CrNumber,
            VatNumber = r.VatNumber,
            Email = r.Email,
            Phone = r.Phone,
            RegisteredBy = r.RegisteredBy,
            ActivatedBy = r.ActivatedBy,
            ActivatedAtUtc = r.ActivatedAtUtc,
            IsTrial = r.IsTrial == true,
            TrialDays = r.TrialDays,
            FirstLoginOn = r.FirstLoginAtUtc is { } f ? DateOnly.FromDateTime(f) : null,
            LastRenewedOn = r.LastRenewedOn,
            Renewals = r.Renewals ?? 0,
            LastLoginAt = r.LastLoginAtUtc,
            LastTransactionAt = r.LastTransactionAtUtc,
            StorageGb = Math.Round((r.DbSizeMb ?? 0) / 1024m, 3),
            Health = new HealthDto(band,
                failed.Select(f => Rules.First(x => x.Key == f).Label).ToList(), failed),
            OpenIssues = r.OpenIssues,
            SubscriptionId = r.SubscriptionId,
            Cycle = r.Cycle,
            SuspendReason = r.SuspendReason,
            SuspendedAtUtc = r.SuspendedAtUtc,
            DatabaseName = r.DatabaseName,
            SchemaVersion = r.SchemaVersion,
            Source = r.Source,
            Reachable = r.Reachable ?? false,
            CollectedAtUtc = r.CollectedAtUtc,
            CollectError = r.CollectError,
            BranchAddress = r.BranchAddress,
            Latitude = r.Latitude,
            Longitude = r.Longitude
        };
    }

    private sealed record Row
    {
        public string TenantId { get; init; } = "";
        public string Name { get; init; } = "";
        public string? NameAr { get; init; }
        public string? BusinessType { get; init; }
        public string? City { get; init; }
        public string? TenantStatus { get; init; }
        public string? Source { get; init; }
        public string? CrNumber { get; init; }
        public string? VatNumber { get; init; }
        public string? Email { get; init; }
        public string? Phone { get; init; }
        public string? DatabaseName { get; init; }
        public string? SchemaVersion { get; init; }
        public string? PocName { get; init; }
        public string? PocUsername { get; init; }
        public string? PocMobile { get; init; }
        public string? PocEmail { get; init; }
        public string? PaymentMethods { get; init; }
        public decimal DefaultVat { get; init; }
        public bool PricesIncludeVat { get; init; }
        public string? RegisteredBy { get; init; }
        public string? ActivatedBy { get; init; }
        public DateTime? ActivatedAtUtc { get; init; }
        public DateTime? SuspendedAtUtc { get; init; }
        public string? SuspendReason { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public string? BranchAddress { get; init; }
        public string? Latitude { get; init; }
        public string? Longitude { get; init; }
        public string? SubscriptionId { get; init; }
        public string? PlanKey { get; init; }
        public string? Cycle { get; init; }
        public bool? IsTrial { get; init; }
        public int? TrialDays { get; init; }
        public DateOnly? RenewsOn { get; init; }
        public string? SubscriptionStatus { get; init; }
        public int? Renewals { get; init; }
        public DateOnly? LastRenewedOn { get; init; }
        public long? CustomMonthlyH { get; init; }
        public long? MonthlyH { get; init; }
        public long? AnnualH { get; init; }
        public bool? Reachable { get; init; }
        public DateTime? CollectedAtUtc { get; init; }
        public string? CollectError { get; init; }
        public int? Branches { get; init; }
        public int? Devices { get; init; }
        public int? DevicesOnline { get; init; }
        public int? Users { get; init; }
        public long? Transactions { get; init; }
        public long? SalesH { get; init; }
        public int? ApiRequestsToday { get; init; }
        public int? ApiErrorsToday { get; init; }
        public DateTime? FirstLoginAtUtc { get; init; }
        public DateTime? LastLoginAtUtc { get; init; }
        public DateTime? LastTransactionAtUtc { get; init; }
        public decimal? DbSizeMb { get; init; }
        public long BalanceH { get; init; }
        public bool PaymentOverdue { get; init; }
        public int OpenIssues { get; init; }
    }
}
