using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Tenancy;

namespace PosApi.Features.SuperAdmin;

public sealed record ReasonRequest(string? Reason);
public sealed record BlockUserRequest(bool Block, string? Reason);

public sealed record ClientCreateRequest
{
    public string? CompanyName { get; init; }
    public string? CompanyNameAr { get; init; }
    public string? Cr { get; init; }
    public string? Vat { get; init; }
    public string? Industry { get; init; }
    public string? BusinessType { get; init; }
    public string? Country { get; init; }
    public string? City { get; init; }
    public string? Email { get; init; }
    public string? Phone { get; init; }
    public string? Plan { get; init; }
    public string? Cycle { get; init; }
    public DateOnly? StartsOn { get; init; }
    public bool Trial { get; init; }
    public string? AdminName { get; init; }
    public string? AdminEmail { get; init; }
    public string? AdminPhone { get; init; }
    public string? AdminUsername { get; init; }
    public string? AdminPassword { get; init; }
    public string? BranchName { get; init; }
    public string? BranchAddress { get; init; }
    public string? Latitude { get; init; }
    public string? Longitude { get; init; }
    public List<string>? PaymentMethods { get; init; }
    public decimal? DefaultVat { get; init; }
    public bool? PricesIncludeVat { get; init; }
    public string? Certificate { get; init; }
    public string? CertificateExpiry { get; init; }
}

public sealed record ClientUpdateRequest
{
    public string? Name { get; init; }
    public string? NameAr { get; init; }
    public string? BusinessType { get; init; }
    public string? City { get; init; }
    public string? CrNumber { get; init; }
    public string? VatNumber { get; init; }
    public string? Email { get; init; }
    public string? Phone { get; init; }
    public string? PocName { get; init; }
    public string? PocMobile { get; init; }
    public string? PocEmail { get; init; }
    public List<string>? PaymentMethods { get; init; }
    public decimal? DefaultVat { get; init; }
    public bool? PricesIncludeVat { get; init; }
    public string? BranchAddress { get; init; }
    public string? Latitude { get; init; }
    public string? Longitude { get; init; }
}

public static partial class ClientEndpoints
{
    public static void MapClientEndpoints(this RouteGroupBuilder api)
    {
        var clients = api.MapGroup("/clients").WithTags("SuperAdmin · Clients");

        clients.MapGet("", ListAsync);
        clients.MapGet("/attention", AttentionAsync);
        clients.MapGet("/health", HealthAsync);
        clients.MapGet("/growth", GrowthAsync);
        clients.MapPost("", CreateAsync);

        clients.MapGet("/{id}", GetAsync);
        clients.MapPost("/{id}", UpdateAsync);
        clients.MapPut("/{id}", UpdateAsync);
        clients.MapGet("/{id}/branches", BranchesAsync);
        clients.MapGet("/{id}/devices", DevicesAsync);
        clients.MapGet("/{id}/users", UsersAsync);
        clients.MapGet("/{id}/usage", UsageAsync);
        clients.MapGet("/{id}/subscription", SubscriptionAsync);
        clients.MapGet("/{id}/issues", IssuesAsync);
        clients.MapGet("/{id}/activity", ActivityAsync);
        clients.MapGet("/{id}/transactions", TransactionsAsync);
        clients.MapGet("/{id}/hardware", HardwareAsync);

        clients.MapPost("/{id}/suspend", SuspendAsync);
        clients.MapPost("/{id}/activate", ActivateAsync);
        clients.MapPost("/{id}/restore", RestoreAsync);
        clients.MapPost("/{id}/support-session", SupportSessionAsync);
        clients.MapPost("/{id}/refresh", RefreshAsync);
        clients.MapPost("/{id}/users/{userId}/block", BlockUserAsync);
    }

    /*================================================================ reads */

    private static async Task<IResult> ListAsync(ClientReader reader, CancellationToken ct) =>
        Results.Ok(await reader.ListAsync(ct));

    private static async Task<IResult> AttentionAsync(ClientReader reader, CancellationToken ct)
    {
        var list = (await reader.ListAsync(ct))
            .Where(c => c.Health.Band != "healthy" && c.TenantStatus is "active" or "suspended")
            .OrderBy(c => c.Health.Band == "critical" ? 0 : 1)
            .ThenBy(c => c.DaysToRenewal ?? int.MaxValue)
            .Take(8)
            .Select(c => new
            {
                id = c.Id,
                name = c.Name,
                plan = c.Plan,
                issue = c.Health.Reasons.FirstOrDefault(),
                otherIssues = c.Health.Reasons.Skip(1).ToList(),
                priority = c.Health.Band == "critical" ? "high" : "medium"
            });

        return Results.Ok(list);
    }

    private static async Task<IResult> HealthAsync(ClientReader reader, CancellationToken ct)
    {
        var list = await reader.ListAsync(ct);

        return Results.Ok(new
        {
            counts = new
            {
                healthy = list.Count(c => c.Status != "suspended" && c.Health.Band == "healthy"),
                attention = list.Count(c => c.Status != "suspended" && c.Health.Band == "attention"),
                critical = list.Count(c => c.Status != "suspended" && c.Health.Band == "critical"),
                inactive = list.Count(c => c.Status == "suspended")
            },
            rules = ClientReader.Rules.Select(r => new { key = r.Key, label = r.Label, weight = r.Weight })
        });
    }

    private static async Task<IResult> GrowthAsync(string? range, TenantCatalog catalog, CancellationToken ct)
    {
        var window = DateWindow.Parse(range);
        await using var control = catalog.Control();

        var created = (await control.QueryAsync<DateTime>(new CommandDefinition(
            "SELECT CreatedAtUtc FROM ctl.Tenant WHERE CreatedAtUtc >= @From;",
            new { window.From }, cancellationToken: ct))).ToList();
        var activated = (await control.QueryAsync<DateTime>(new CommandDefinition(
            "SELECT ActivatedAtUtc FROM ctl.Tenant WHERE ActivatedAtUtc >= @From;",
            new { window.From }, cancellationToken: ct))).ToList();
        var suspended = (await control.QueryAsync<DateTime>(new CommandDefinition(
            "SELECT AtUtc FROM ctl.AdminAudit WHERE Action = N'client.suspend' AND Result = N'success' AND AtUtc >= @From;",
            new { window.From }, cancellationToken: ct))).ToList();
        var churned = (await control.QueryAsync<DateTime>(new CommandDefinition(
            "SELECT CancelledAtUtc FROM ctl.Subscription WHERE CancelledAtUtc >= @From;",
            new { window.From }, cancellationToken: ct))).ToList();

        int In(List<DateTime> xs, DateTime a, DateTime b) => xs.Count(x => x >= a && x < b);

        var series = window.Buckets().Select(b => new
        {
            label = b.Label,
            date = DateOnly.FromDateTime(b.Start),
            value = In(created, b.Start, b.End),
            created = In(created, b.Start, b.End),
            activated = In(activated, b.Start, b.End),
            churned = In(churned, b.Start, b.End),
            suspended = In(suspended, b.Start, b.End)
        }).ToList();

        return Results.Ok(new
        {
            series,
            totals = new
            {
                created = series.Sum(s => s.created),
                activated = series.Sum(s => s.activated),
                churned = series.Sum(s => s.churned),
                suspended = series.Sum(s => s.suspended),
                net = series.Sum(s => s.created) - series.Sum(s => s.churned)
            }
        });
    }

    private static async Task<IResult> GetAsync(
        string id, ClientReader reader, AdminAuditor audit, CancellationToken ct)
    {
        var client = await reader.GetAsync(id, ct);
        if (client is null) return NotFound();

        await audit.RecordAsync("client.view", "Viewed client", id, id, table: "ctl.Tenant",
            operation: "VIEW", rowsAffected: 1, ct: ct);

        return Results.Ok(client);
    }

    private static async Task<IResult> BranchesAsync(string id, TenantCatalog catalog, CancellationToken ct)
    {
        var (tenant, refused) = await OpenTenantAsync(catalog, id, ct);
        if (refused is not null) return refused;
        await using var db = tenant!.Connection;

        var rows = await db.QueryAsync(new CommandDefinition(
            """
            SELECT b.BranchId AS id, @ClientId AS clientId, @ClientName AS clientName, b.NameEn AS name,
                   b.NameAr AS nameAr, b.Code AS code, b.IsActive AS isActive, @City AS city,
                   (SELECT COUNT(*) FROM device.PosDevice AS d WHERE d.BranchId = b.BranchId AND d.IsActive = 1) AS devices,
                   (SELECT COUNT(*) FROM device.PosDevice AS d WHERE d.BranchId = b.BranchId AND d.IsActive = 1
                      AND d.LastHeartbeatAtUtc > DATEADD(SECOND, -120, SYSUTCDATETIME())) AS devicesOnline,
                   (SELECT COUNT(*) FROM core.UserBranch AS ub WHERE ub.BranchId = b.BranchId) AS users,
                   (SELECT COUNT(*) FROM sales.Sale AS s WHERE s.BranchId = b.BranchId AND s.Status = N'completed') AS transactions,
                   (SELECT ISNULL(SUM(s.TotalH), 0) FROM sales.Sale AS s WHERE s.BranchId = b.BranchId AND s.Status = N'completed') AS salesH
            FROM core.Branch AS b
            ORDER BY b.Code;
            """, new { ClientId = id, ClientName = tenant.Info.Name, City = tenant.City }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> DevicesAsync(string id, TenantCatalog catalog, CancellationToken ct)
    {
        var (tenant, refused) = await OpenTenantAsync(catalog, id, ct);
        if (refused is not null) return refused;
        await using var db = tenant!.Connection;

        return Results.Ok(await Terminals(db, id, tenant.Info.Name, ct));
    }

    /// <summary>A tenant's POS terminals, in the console's shape.</summary>
    public static async Task<IReadOnlyList<object>> Terminals(SqlConnection db, string clientId, string clientName, CancellationToken ct)
    {
        var rows = await db.QueryAsync<TerminalRow>(new CommandDefinition(
            """
            SELECT d.DeviceId, d.DeviceName, d.DeviceType, d.DeviceModel, d.SerialNumber, d.BranchId,
                   b.NameEn AS BranchName, d.PrinterStatus, d.PaperStatus, d.LastHeartbeatAtUtc, d.AppVersion,
                   d.IsActive, d.RegisteredAtUtc, d.BatteryPercent, d.NetworkType
            FROM device.PosDevice AS d
            LEFT JOIN core.Branch AS b ON b.BranchId = d.BranchId
            ORDER BY d.DeviceId;
            """, cancellationToken: ct));

        var now = DateTime.UtcNow;
        return rows.Select(d =>
        {
            int? seconds = d.LastHeartbeatAtUtc is { } at ? (int)(now - at).TotalSeconds : null;
            var online = d.IsActive && seconds is not null && seconds <= 120;

            /* Offline means unknown, never the last "ready" — a stale ready
               reads as a working printer. */
            var printer = !online ? "unknown"
                : (d.PrinterStatus ?? "").ToLowerInvariant() switch
                {
                    "ok" or "ready" or "normal" or "online" => "ready",
                    "" or "unknown" => "unknown",
                    _ => "error"
                };
            var paper = !online ? "unknown"
                : (d.PaperStatus ?? "").ToLowerInvariant() switch
                {
                    "ok" or "available" or "normal" => "available",
                    "low" or "near_end" or "out" or "empty" => "low",
                    _ => "unknown"
                };

            return (object)new
            {
                id = d.DeviceId,
                clientId,
                clientName,
                name = d.DeviceName,
                branchId = d.BranchId,
                branchName = d.BranchName,
                type = d.DeviceType,
                model = d.DeviceModel,
                serial = d.SerialNumber,
                status = online ? "online" : "offline",
                isActive = d.IsActive,
                registered = d.RegisteredAtUtc is not null,
                printer,
                paper,
                battery = d.BatteryPercent,
                network = d.NetworkType,
                lastSeenAt = d.LastHeartbeatAtUtc,
                secondsSince = seconds,
                firmware = d.AppVersion,
                ip = (string?)null
            };
        }).ToList();
    }

    private static async Task<IResult> UsersAsync(string id, TenantCatalog catalog, CancellationToken ct)
    {
        var (tenant, refused) = await OpenTenantAsync(catalog, id, ct);
        if (refused is not null) return refused;
        await using var db = tenant!.Connection;

        return Results.Ok(await TenantUsers(db, id, tenant.Info.Name, ct));
    }

    public static async Task<IReadOnlyList<dynamic>> TenantUsers(SqlConnection db, string clientId, string clientName, CancellationToken ct) =>
        (await db.QueryAsync(new CommandDefinition(
            """
            SELECT u.UserId AS id, @ClientId AS clientId, @ClientName AS clientName, N'client' AS scope,
                   u.NameEn AS name, u.Username AS username, u.Email AS email, u.Phone AS phone,
                   ISNULL(r.NameEn, u.RoleId) AS role, u.DefaultBranchId AS branchId, b.NameEn AS branchName,
                   u.LastLoginAtUtc AS lastLoginAt, u.Status AS status
            FROM core.AppUser AS u
            LEFT JOIN core.Role AS r ON r.RoleId = u.RoleId
            LEFT JOIN core.Branch AS b ON b.BranchId = COALESCE(u.DefaultBranchId,
                 (SELECT TOP (1) ub.BranchId FROM core.UserBranch AS ub WHERE ub.UserId = u.UserId ORDER BY ub.BranchId))
            ORDER BY u.NameEn;
            """, new { ClientId = clientId, ClientName = clientName }, cancellationToken: ct))).ToList();

    private static async Task<IResult> UsageAsync(string id, ClientReader reader, TenantCatalog catalog, CancellationToken ct)
    {
        var client = await reader.GetAsync(id, ct);
        if (client is null) return NotFound();

        var tenant = await catalog.GetAsync(id, ct);
        await using var control = catalog.Control();

        var snap = await control.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT n.TransactionsMonth, n.DbSizeMb, n.DbRows, n.DbTables, n.LargestTable, n.LargestTableRows,
                   p.Transactions AS TxLimit, p.StorageGb AS StorageLimit,
                   (SELECT ISNULL(SUM(d.Transactions), 0) FROM ctl.TenantDailyStat AS d
                     WHERE d.TenantId = n.TenantId
                       AND d.StatDate >= DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(SYSUTCDATETIME()), MONTH(SYSUTCDATETIME()), 1))
                       AND d.StatDate < DATEFROMPARTS(YEAR(SYSUTCDATETIME()), MONTH(SYSUTCDATETIME()), 1)) AS TxPrevious
            FROM ctl.TenantSnapshot AS n
            LEFT JOIN ctl.Subscription AS s ON s.TenantId = n.TenantId
            LEFT JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey
            WHERE n.TenantId = @TenantId;
            """, new { TenantId = id }, cancellationToken: ct));

        object Meter(double used, double? limit, double? previous) => new
        {
            used,
            limit,
            percent = limit is > 0 ? Math.Round(100 * used / limit.Value, 1) : (double?)null,
            previous = previous ?? used
        };

        double txMonth = snap?.TransactionsMonth ?? 0;
        double txPrevious = (double)(snap?.TxPrevious ?? 0L);
        double dbGb = (double)((decimal?)snap?.DbSizeMb ?? 0m) / 1024.0;
        var ageDays = Math.Max(1, (DateTime.UtcNow - client.CreatedOn.ToDateTime(TimeOnly.MinValue)).TotalDays);

        return Results.Ok(new
        {
            branches = Meter(client.Branches, tenant?.MaxBranches, null),
            devices = Meter(client.Devices, tenant?.MaxDevices, null),
            users = Meter(client.Users, tenant?.MaxUsers, null),
            transactions = Meter(txMonth, (double?)(int?)snap?.TxLimit, txPrevious),
            storage = Meter(Math.Round(dbGb, 3), (double?)(decimal?)snap?.StorageLimit, null),
            database = new
            {
                sizeGb = Math.Round(dbGb, 3),
                rows = (long?)snap?.DbRows ?? 0,
                tables = (int?)snap?.DbTables ?? 0,
                largestTable = (string?)snap?.LargestTable,
                largestTableRows = (long?)snap?.LargestTableRows ?? 0
            },
            files = new { sizeGb = 0, count = 0 },
            growth = new
            {
                storagePct = (double?)null,
                transactionsPct = txPrevious > 0 ? Math.Round(100 * (txMonth - txPrevious) / txPrevious, 1) : (double?)null,
                rowsPerDay = Math.Round(((long?)snap?.DbRows ?? 0) / ageDays)
            },
            collectedAtUtc = client.CollectedAtUtc,
            reachable = client.Reachable
        });
    }

    private static async Task<IResult> SubscriptionAsync(string id, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var list = await BillingEndpoints.SubscriptionsAsync(control, id, ct);
        return Results.Ok(list.FirstOrDefault());
    }

    private static async Task<IResult> IssuesAsync(string id, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await PlatformEndpoints.IssuesAsync(control, id, ct));
    }

    private static async Task<IResult> ActivityAsync(string id, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await AdminAuditor.ListAsync(control, id, null, 200, ct));
    }

    private static async Task<IResult> TransactionsAsync(string id, int? take, TenantCatalog catalog, CancellationToken ct)
    {
        var (tenant, refused) = await OpenTenantAsync(catalog, id, ct);
        if (refused is not null) return refused;
        await using var db = tenant!.Connection;

        var rows = await db.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (@Take)
                   s.SaleId AS id, s.InvoiceNumber AS invoiceNo, s.SoldAtUtc AS [at], s.BranchId AS branchId,
                   b.NameEn AS branchName, NULL AS deviceId, s.CashierName AS cashier,
                   (SELECT COUNT(*) FROM sales.SaleLine AS l WHERE l.SaleId = s.SaleId) AS items,
                   (SELECT TOP (1) p.Method FROM sales.SalePayment AS p WHERE p.SaleId = s.SaleId ORDER BY p.AmountH DESC) AS method,
                   s.TotalH - s.TaxH AS netH, s.TaxH AS vatH, s.TotalH AS totalH,
                   CASE s.Status WHEN N'returned' THEN -s.TotalH WHEN N'voided' THEN 0 ELSE s.TotalH END AS signedTotalH,
                   CASE s.Status WHEN N'returned' THEN N'refunded' WHEN N'voided' THEN N'void' ELSE N'completed' END AS status,
                   CASE WHEN s.CustomerId IS NULL THEN N'Walk-in' ELSE N'Account' END AS customer
            FROM sales.Sale AS s
            LEFT JOIN core.Branch AS b ON b.BranchId = s.BranchId
            ORDER BY s.SoldAtUtc DESC;
            """, new { Take = Math.Clamp(take ?? 240, 1, 2000) }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> HardwareAsync(string id, TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await ConfigEndpoints.HardwareAsync(control, id, ct));
    }

    /*=============================================================== writes */

    [GeneratedRegex(@"^\d{10}$")] private static partial Regex CrPattern();
    [GeneratedRegex(@"^\d{15}$")] private static partial Regex VatPattern();
    [GeneratedRegex(@"^0\d{9}$")] private static partial Regex MobilePattern();
    [GeneratedRegex(@"^[a-z0-9._-]{3,40}$")] private static partial Regex UsernamePattern();
    [GeneratedRegex(@"^[^@\s]+@[^@\s]+\.[^@\s]+$")] private static partial Regex EmailPattern();

    /// <summary>
    /// Create a client: provisions a tenant with a database of its own, its
    /// owner account and first branch, and its subscription.
    /// </summary>
    private static async Task<IResult> CreateAsync(
        ClientCreateRequest request, TenantProvisioner provisioner, IPasswordHasher hasher,
        CurrentAdmin admin, AdminAuditor audit, TenantSnapshotService snapshots, CancellationToken ct)
    {
        var errors = new Dictionary<string, string>();
        var name = request.CompanyName?.Trim() ?? "";
        var adminEmail = request.AdminEmail?.Trim().ToLowerInvariant() ?? "";
        var username = request.AdminUsername?.Trim().ToLowerInvariant();
        var password = string.IsNullOrEmpty(request.AdminPassword) ? null : request.AdminPassword;

        if (name.Length is 0 or > 120) errors["companyName"] = "The company name is required (120 characters at most).";
        if (!string.IsNullOrWhiteSpace(request.Cr) && !CrPattern().IsMatch(request.Cr)) errors["cr"] = "A CR number is 10 digits.";
        if (!string.IsNullOrWhiteSpace(request.Vat) && !VatPattern().IsMatch(request.Vat)) errors["vat"] = "A VAT number is 15 digits.";
        if (!string.IsNullOrWhiteSpace(request.Phone) && !MobilePattern().IsMatch(request.Phone)) errors["phone"] = "A mobile is 10 digits starting with 0.";
        if (string.IsNullOrWhiteSpace(request.AdminName)) errors["adminName"] = "The admin's name is required.";
        if (!EmailPattern().IsMatch(adminEmail)) errors["adminEmail"] = "A valid admin email is required.";
        if (!string.IsNullOrWhiteSpace(request.AdminPhone) && !MobilePattern().IsMatch(request.AdminPhone)) errors["adminPhone"] = "A mobile is 10 digits starting with 0.";
        if (username is not null && !UsernamePattern().IsMatch(username)) errors["adminUsername"] = "3–40 characters: letters, digits, dot, dash, underscore.";
        if (password is { Length: < 8 }) errors["adminPassword"] = "At least 8 characters.";
        if (request.Plan is not ("Basic" or "Pro" or "Enterprise" or "Trial")) errors["plan"] = "Choose a plan.";
        if (request.DefaultVat is < 0 or > 100) errors["defaultVat"] = "VAT is between 0 and 100.";

        if (errors.Count > 0)
        {
            return Results.Json(new
            {
                code = "validation_failed",
                message = errors.Values.First(),
                fieldErrors = errors.ToDictionary(e => e.Key, e => new[] { e.Value })
            }, statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        string? hash = null, salt = null;
        if (password is not null) (hash, salt) = hasher.Hash(password);

        ProvisionResult result;
        try
        {
            result = await provisioner.ProvisionAsync(new ProvisionRequest
            {
                Name = name,
                NameAr = request.CompanyNameAr,
                BusinessType = request.BusinessType ?? request.Industry,
                City = request.City,
                Country = request.Country,
                CrNumber = Blank(request.Cr),
                VatNumber = Blank(request.Vat),
                Email = Blank(request.Email),
                Phone = Blank(request.Phone),
                OwnerName = request.AdminName!.Trim(),
                OwnerEmail = adminEmail,
                OwnerPhone = Blank(request.AdminPhone),
                OwnerUsername = username,
                OwnerPasswordHash = hash,
                OwnerPasswordSalt = salt,
                BranchName = Blank(request.BranchName) ?? "Main Branch",
                BranchAddress = Blank(request.BranchAddress),
                Latitude = Blank(request.Latitude),
                Longitude = Blank(request.Longitude),
                PlanKey = request.Plan!,
                Cycle = request.Cycle ?? "annual",
                StartsOn = request.StartsOn,
                Trial = request.Trial,
                PaymentMethods = request.PaymentMethods,
                DefaultVat = request.DefaultVat ?? 15,
                PricesIncludeVat = request.PricesIncludeVat ?? true,
                Certificate = Blank(request.Certificate),
                CertificateExpiry = DateOnly.TryParse(request.CertificateExpiry, out var expiry) ? expiry : null,
                Source = "admin",
                RegisteredBy = admin.Name
            }, ct);
        }
        catch (ProvisionException ex)
        {
            await audit.RecordAsync("client.create", "Create client failed", null, null, null, name, null,
                "ctl.Tenant", "INSERT", 0, ex.Message, ct);

            var field = ex.Field switch { "email" => "adminEmail", "mobile" => "adminPhone", "username" => "adminUsername", var f => f };
            return Results.Json(new
            {
                code = ex.Code,
                message = ex.Message,
                fieldErrors = field is null ? null : new Dictionary<string, string[]> { [field] = [ex.Message] }
            }, statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        await snapshots.CollectAsync(result.TenantId, result.DatabaseName, ct);

        return Results.Ok(await audit.ResultAsync("client.create", "Created client", result.TenantId, result.TenantId,
            null, $"{name} · {request.Plan}{(request.Trial ? " (trial)" : "")} · {result.DatabaseName}", null,
            "ctl.Tenant", "INSERT", 1,
            new { clientId = result.TenantId, result.DatabaseName, result.SubscriptionId, ownerUserId = result.OwnerUserId }, ct));
    }

    /// <summary>Edit a client. Only what actually changed is written and recorded.</summary>
    private static async Task<IResult> UpdateAsync(
        string id, ClientUpdateRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var current = await control.QuerySingleOrDefaultAsync<ClientUpdateRequest>(new CommandDefinition(
            """
            SELECT Name, NameAr, BusinessType, City, CrNumber, VatNumber, Email, Phone, PocName, PocMobile, PocEmail,
                   DefaultVat, PricesIncludeVat, BranchAddress, Latitude, Longitude
            FROM ctl.Tenant WHERE TenantId = @Id;
            """, new { Id = id }, cancellationToken: ct));
        if (current is null) return NotFound();

        var methods = await control.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT PaymentMethods FROM ctl.Tenant WHERE TenantId = @Id;", new { Id = id }, cancellationToken: ct));

        var changes = new List<string>();
        var set = new Dictionary<string, object?>();

        void Track(string column, string label, string? was, string? now)
        {
            if (now is null) return;
            now = now.Trim();
            if (string.Equals(was ?? "", now, StringComparison.Ordinal)) return;
            set[column] = now.Length == 0 ? null : now;
            changes.Add($"{label}: {was ?? "—"} → {(now.Length == 0 ? "—" : now)}");
        }

        Track("Name", "name", current.Name, request.Name);
        Track("NameAr", "Arabic name", current.NameAr, request.NameAr);
        Track("BusinessType", "business type", current.BusinessType, request.BusinessType);
        Track("City", "city", current.City, request.City);
        Track("CrNumber", "CR", current.CrNumber, request.CrNumber);
        Track("VatNumber", "VAT number", current.VatNumber, request.VatNumber);
        Track("Email", "email", current.Email, request.Email);
        Track("Phone", "phone", current.Phone, request.Phone);
        Track("PocName", "contact", current.PocName, request.PocName);
        Track("PocMobile", "contact mobile", current.PocMobile, request.PocMobile);
        Track("PocEmail", "contact email", current.PocEmail, request.PocEmail);
        Track("BranchAddress", "address", current.BranchAddress, request.BranchAddress);
        Track("Latitude", "latitude", current.Latitude, request.Latitude);
        Track("Longitude", "longitude", current.Longitude, request.Longitude);
        if (request.PaymentMethods is not null)
            Track("PaymentMethods", "payment methods", methods, string.Join(",", request.PaymentMethods));
        if (request.DefaultVat is { } vat && vat != current.DefaultVat)
        {
            set["DefaultVat"] = vat;
            changes.Add($"VAT: {current.DefaultVat:0.##} → {vat:0.##}");
        }
        if (request.PricesIncludeVat is { } inc && inc != current.PricesIncludeVat)
        {
            set["PricesIncludeVat"] = inc;
            changes.Add($"prices include VAT: {current.PricesIncludeVat} → {inc}");
        }

        if (set.ContainsKey("Name") && set["Name"] is null)
            return Results.BadRequest(new { code = "name_required", message = "The company name cannot be blank." });

        if (changes.Count == 0)
            return Results.Ok(new { ok = true, unchanged = true, message = "Nothing changed." });

        var parameters = new DynamicParameters(set);
        parameters.Add("Id", id);
        await control.ExecuteAsync(new CommandDefinition(
            $"UPDATE ctl.Tenant SET {string.Join(", ", set.Keys.Select(k => $"{k} = @{k}"))}, UpdatedAtUtc = SYSUTCDATETIME() WHERE TenantId = @Id;",
            parameters, cancellationToken: ct));

        /* The tenant's own company record carries the same legal details;
           keep them in step so receipts and the console agree. */
        if (set.Keys.Any(k => k is "Name" or "NameAr" or "CrNumber" or "VatNumber" or "City"))
        {
            var tenant = await catalog.GetAsync(id, ct);
            if (tenant is not null)
            {
                try
                {
                    await using var db = new SqlConnection(tenant.ConnectionString);
                    await db.ExecuteAsync(new CommandDefinition(
                        """
                        UPDATE core.Company
                        SET NameEn = COALESCE(@Name, NameEn), NameAr = COALESCE(@NameAr, NameAr),
                            CrNumber = @CrNumber, VatNumber = @VatNumber, City = @City;
                        """,
                        new
                        {
                            Name = set.GetValueOrDefault("Name") as string ?? current.Name,
                            NameAr = set.GetValueOrDefault("NameAr") as string ?? current.NameAr,
                            CrNumber = set.TryGetValue("CrNumber", out var cr) ? cr as string : current.CrNumber,
                            VatNumber = set.TryGetValue("VatNumber", out var v) ? v as string : current.VatNumber,
                            City = set.TryGetValue("City", out var c) ? c as string : current.City
                        }, cancellationToken: ct));
                }
                catch (SqlException ex)
                {
                    return Results.Json(new { code = "tenant_update_failed", message = $"Saved in the console, but the client's own record refused it: {ex.Message}" },
                        statusCode: StatusCodes.Status422UnprocessableEntity);
                }
            }
        }

        catalog.Evict(id);

        return Results.Ok(await audit.ResultAsync("client.update", "Updated client", id, id,
            null, string.Join("; ", changes), null, "ctl.Tenant", "UPDATE", 1, new { changes }, ct));
    }

    /// <summary>
    /// Deactivate a client. Sign-in is refused and live sessions stop at their
    /// next request; the database, the subscription and its dates are untouched.
    /// </summary>
    private static async Task<IResult> SuspendAsync(
        string id, ReasonRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return Results.BadRequest(new { code = "reason_required", message = "A reason is required." });

        await using var control = catalog.Control();
        var affected = await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Tenant
            SET Status = N'suspended', SuspendedAtUtc = SYSUTCDATETIME(), SuspendReason = @Reason, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE TenantId = @Id AND Status = N'active';

            IF @@ROWCOUNT > 0
                INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail, Severity)
                VALUES (N'client_suspended', N'Client suspended', @Id, @Reason, N'warning');
            """, new { Id = id, request.Reason }, cancellationToken: ct));

        if (affected == 0) return Conflict("That client is not active, so it cannot be deactivated.");

        catalog.Evict(id);
        var revoked = await RevokeSessionsAsync(catalog, id, null, ct);

        return Results.Ok(await audit.ResultAsync("client.suspend", "Suspended client", id, id,
            "active", "suspended", request.Reason, "ctl.Tenant", "UPDATE", 1,
            new { sessionsEnded = revoked }, ct));
    }

    private static Task<IResult> ActivateAsync(
        string id, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct) =>
        ReactivateAsync(id, null, "client.activate", "Activated client", catalog, audit, ct);

    /// <summary>Undo a deactivation — recorded as its own action. No days are added.</summary>
    private static Task<IResult> RestoreAsync(
        string id, ReasonRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct) =>
        string.IsNullOrWhiteSpace(request.Reason)
            ? Task.FromResult(Results.BadRequest(new { code = "reason_required", message = "A reason is required." }))
            : ReactivateAsync(id, request.Reason, "client.restore", "Restored client", catalog, audit, ct);

    private static async Task<IResult> ReactivateAsync(
        string id, string? reason, string action, string label, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var affected = await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Tenant
            SET Status = N'active', SuspendedAtUtc = NULL, SuspendReason = NULL, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE TenantId = @Id AND Status = N'suspended';

            IF @@ROWCOUNT > 0
                INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail)
                VALUES (N'client_activated', @Label, @Id, @Reason);
            """, new { Id = id, Reason = reason, Label = label }, cancellationToken: ct));

        if (affected == 0) return Conflict("That client is not deactivated.");

        catalog.Evict(id);
        return Results.Ok(await audit.ResultAsync(action, label, id, id, "suspended", "active", reason,
            "ctl.Tenant", "UPDATE", 1, null, ct));
    }

    private static async Task<IResult> SupportSessionAsync(
        string id, ReasonRequest request, TenantCatalog catalog, CurrentAdmin admin, AdminAuditor audit, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return Results.BadRequest(new { code = "reason_required", message = "A reason is required." });

        await using var control = catalog.Control();
        if (await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.Tenant WHERE TenantId = @Id;", new { Id = id }, cancellationToken: ct)) is null)
            return NotFound();

        var sessionId = await control.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            INSERT INTO ctl.SupportSession (TenantId, AdminId, Reason) OUTPUT INSERTED.SessionId VALUES (@Id, @AdminId, @Reason);
            INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail) VALUES (N'support_session', N'Support session started', @Id, @Reason);
            """, new { Id = id, admin.AdminId, request.Reason }, cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("support.session", "Started support session", id, $"SS-{sessionId}",
            null, "active", request.Reason, "ctl.SupportSession", "INSERT", 1, new { sessionId }, ct));
    }

    private static async Task<IResult> RefreshAsync(
        string id, TenantCatalog catalog, TenantSnapshotService snapshots, ClientReader reader, CancellationToken ct)
    {
        var tenant = await catalog.GetAsync(id, ct);
        if (tenant is null) return NotFound();

        await snapshots.CollectAsync(id, tenant.DatabaseName, ct);
        return Results.Ok(await reader.GetAsync(id, ct));
    }

    /// <summary>Block or unblock one person, not the whole business.</summary>
    private static async Task<IResult> BlockUserAsync(
        string id, string userId, BlockUserRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (request.Block && string.IsNullOrWhiteSpace(request.Reason))
            return Results.BadRequest(new { code = "reason_required", message = "A reason is required." });

        var (tenant, refused) = await OpenTenantAsync(catalog, id, ct);
        if (refused is not null) return refused;
        await using var db = tenant!.Connection;

        var before = await db.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT Status FROM core.AppUser WHERE UserId = @UserId;", new { UserId = userId }, cancellationToken: ct));
        if (before is null) return NotFound("No such user in this client.");

        var after = request.Block ? "suspended" : "active";
        await db.ExecuteAsync(new CommandDefinition(
            "UPDATE core.AppUser SET Status = @Status, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = N'platform admin' WHERE UserId = @UserId;",
            new { Status = after, UserId = userId }, cancellationToken: ct));

        if (request.Block) await RevokeSessionsAsync(catalog, id, userId, ct);

        return Results.Ok(await audit.ResultAsync("user.block", request.Block ? "Blocked client user" : "Unblocked client user",
            id, userId, before, after, request.Reason, "core.AppUser", "UPDATE", 1, null, ct));
    }

    /*============================================================== helpers */

    public sealed record OpenTenant(TenantInfo Info, SqlConnection Connection, string? City);

    /// <summary>A tenant's own database, for the live detail tabs. Suspended tenants can still be inspected.</summary>
    public static async Task<(OpenTenant? Tenant, IResult? Refused)> OpenTenantAsync(TenantCatalog catalog, string id, CancellationToken ct)
    {
        var info = await catalog.GetAsync(id, ct);
        if (info is null) return (null, NotFound());
        if (info.Status is not ("active" or "suspended"))
            return (null, Conflict($"This client is {info.Status}; its database is not available."));

        await using var control = catalog.Control();
        var city = await control.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT City FROM ctl.Tenant WHERE TenantId = @Id;", new { Id = id }, cancellationToken: ct));

        var connection = new SqlConnection(info.ConnectionString);
        try
        {
            await connection.OpenAsync(ct);
        }
        catch (SqlException ex)
        {
            await connection.DisposeAsync();
            return (null, Results.Json(new { code = "tenant_unreachable", message = $"The client's database could not be reached: {ex.Message}" },
                statusCode: StatusCodes.Status503ServiceUnavailable));
        }

        return (new OpenTenant(info, connection, city), null);
    }

    private static async Task<int> RevokeSessionsAsync(TenantCatalog catalog, string id, string? userId, CancellationToken ct)
    {
        var info = await catalog.GetAsync(id, ct);
        if (info is null) return 0;

        try
        {
            await using var db = new SqlConnection(info.ConnectionString);
            return await db.ExecuteAsync(new CommandDefinition(
                "UPDATE core.RefreshToken SET RevokedAtUtc = SYSUTCDATETIME() WHERE RevokedAtUtc IS NULL AND (@UserId IS NULL OR UserId = @UserId);",
                new { UserId = userId }, cancellationToken: ct));
        }
        catch (SqlException)
        {
            /* Unreachable: the middleware still refuses every request, and the
               tokens die at expiry. */
            return 0;
        }
    }

    public static IResult NotFound(string message = "No such client.") =>
        Results.Json(new { code = "not_found", message }, statusCode: StatusCodes.Status404NotFound);

    public static IResult Conflict(string message) =>
        Results.Json(new { code = "conflict", message }, statusCode: StatusCodes.Status409Conflict);

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private sealed record TerminalRow
    {
        public string DeviceId { get; init; } = "";
        public string DeviceName { get; init; } = "";
        public string? DeviceType { get; init; }
        public string? DeviceModel { get; init; }
        public string? SerialNumber { get; init; }
        public string? BranchId { get; init; }
        public string? BranchName { get; init; }
        public string? PrinterStatus { get; init; }
        public string? PaperStatus { get; init; }
        public DateTime? LastHeartbeatAtUtc { get; init; }
        public string? AppVersion { get; init; }
        public bool IsActive { get; init; }
        public DateTime? RegisteredAtUtc { get; init; }
        public int? BatteryPercent { get; init; }
        public string? NetworkType { get; init; }
    }
}
