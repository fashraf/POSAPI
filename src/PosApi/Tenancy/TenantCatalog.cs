using System.Collections.Concurrent;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PosApi.Common;

namespace PosApi.Tenancy;

/// <summary>A tenant as the POS side needs it: where its data is and whether it may trade.</summary>
public sealed record TenantInfo
{
    public required string TenantId { get; init; }
    public required string Name { get; init; }
    public required string DatabaseName { get; init; }
    public required string Status { get; init; }
    public required string ConnectionString { get; init; }
    public string? PlanKey { get; init; }
    public string? BusinessType { get; init; }
    public bool IsTrial { get; init; }
    public DateOnly? RenewsOn { get; init; }
    public string? SubscriptionStatus { get; init; }
    public int? MaxUsers { get; init; }
    public int? MaxDevices { get; init; }
    public int? MaxBranches { get; init; }
}

/// <summary>
/// Reads tenants from the control database, with a short cache.
///
/// Every authenticated POS request asks for its tenant, so a database round trip
/// each time would double the load on the control database. The cache is short
/// enough that suspending a client takes effect within seconds; the console
/// also evicts the entry directly when it changes a tenant.
/// </summary>
public sealed class TenantCatalog
{
    private readonly TenancyConnections _connections;
    private readonly TimeSpan _ttl;
    private readonly ConcurrentDictionary<string, (TenantInfo? Tenant, DateTime At)> _cache =
        new(StringComparer.OrdinalIgnoreCase);

    public TenantCatalog(TenancyConnections connections, IOptions<TenancyOptions> options)
    {
        _connections = connections;
        _ttl = TimeSpan.FromSeconds(Math.Max(1, options.Value.CatalogCacheSeconds));
    }

    public SqlConnection Control() => new(_connections.Control);

    public async Task<TenantInfo?> GetAsync(string tenantId, CancellationToken ct)
    {
        if (_cache.TryGetValue(tenantId, out var hit) && DateTime.UtcNow - hit.At < _ttl)
            return hit.Tenant;

        await using var connection = Control();

        var row = await connection.QuerySingleOrDefaultAsync<TenantRow>(new CommandDefinition(
            """
            SELECT t.TenantId, t.Name, t.DatabaseName, t.Status, t.BusinessType,
                   s.PlanKey, s.IsTrial, s.RenewsOn, s.Status AS SubscriptionStatus,
                   COALESCE(c.Users, p.Users) AS MaxUsers,
                   COALESCE(c.Devices, p.Devices) AS MaxDevices,
                   COALESCE(c.Branches, p.Branches) AS MaxBranches
            FROM ctl.Tenant AS t
            LEFT JOIN ctl.Subscription AS s ON s.TenantId = t.TenantId
            LEFT JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey
            LEFT JOIN ctl.PlanConfig AS c ON c.PlanKey = s.PlanKey AND c.BusinessType = t.BusinessType
            WHERE t.TenantId = @TenantId;
            """, new { TenantId = tenantId }, cancellationToken: ct));

        var tenant = row is null ? null : new TenantInfo
        {
            TenantId = row.TenantId,
            Name = row.Name,
            DatabaseName = row.DatabaseName,
            Status = row.Status,
            ConnectionString = _connections.ForTenant(row.DatabaseName),
            PlanKey = row.PlanKey,
            BusinessType = row.BusinessType,
            IsTrial = row.IsTrial ?? false,
            RenewsOn = row.RenewsOn,
            SubscriptionStatus = row.SubscriptionStatus,
            MaxUsers = row.MaxUsers,
            MaxDevices = row.MaxDevices,
            MaxBranches = row.MaxBranches
        };

        _cache[tenantId] = (tenant, DateTime.UtcNow);
        return tenant;
    }

    /// <summary>Forget a tenant, so the next request reads its new state.</summary>
    public void Evict(string tenantId) => _cache.TryRemove(tenantId, out _);

    /// <summary>
    /// Whether a tenant may be used right now, and if not, the refusal.
    ///
    /// Suspended refuses everything. An expired or cancelled subscription
    /// refuses too — the platform settings say sign-in is refused on expiry —
    /// but the data is untouched and renewing restores access at once.
    /// </summary>
    public static ApiError? Refusal(TenantInfo tenant)
    {
        if (tenant.Status == "suspended")
            return ApiError.Create("tenant_suspended",
                "This business account has been suspended. Contact support.",
                "تم إيقاف حساب هذه المنشأة. تواصل مع الدعم.");

        if (tenant.Status != "active")
            return ApiError.Create("tenant_unavailable",
                "This business account is not available yet.",
                "حساب هذه المنشأة غير متاح بعد.");

        if (tenant.SubscriptionStatus == "cancelled")
            return ApiError.Create("subscription_cancelled",
                "This business's subscription has been cancelled.",
                "تم إلغاء اشتراك هذه المنشأة.");

        if (tenant.RenewsOn is { } ends && ends < DateOnly.FromDateTime(DateTime.UtcNow))
            return ApiError.Create("subscription_expired",
                tenant.IsTrial
                    ? "The free trial has ended. Contact us to subscribe."
                    : "This business's subscription has expired. Renew to continue.",
                tenant.IsTrial
                    ? "انتهت الفترة التجريبية. تواصل معنا للاشتراك."
                    : "انتهى اشتراك هذه المنشأة. جدّد الاشتراك للمتابعة.");

        return null;
    }

    private sealed record TenantRow
    {
        public string TenantId { get; init; } = "";
        public string Name { get; init; } = "";
        public string DatabaseName { get; init; } = "";
        public string Status { get; init; } = "";
        public string? BusinessType { get; init; }
        public string? PlanKey { get; init; }
        public bool? IsTrial { get; init; }
        public DateOnly? RenewsOn { get; init; }
        public string? SubscriptionStatus { get; init; }
        public int? MaxUsers { get; init; }
        public int? MaxDevices { get; init; }
        public int? MaxBranches { get; init; }
    }
}
