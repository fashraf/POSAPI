using System.Data.Common;
using Dapper;
using PosApi.Tenancy;

namespace PosApi.Features.SuperAdmin;

public sealed record RenewRequest(int? Days);
public sealed record PlanChangeRequest(string? Plan, string? Cycle, long? CustomMonthlyH, string? Reason);
public sealed record InvoiceStatusRequest(string? Status, string? Method, string? Notes);

/// <summary>
/// Subscriptions, invoices, revenue and the sales analytics. SaaS revenue (what
/// clients pay the platform) and client sales (what clients sell) are never
/// mixed: the first is in the control database, the second in the snapshots.
/// </summary>
public static class BillingEndpoints
{
    public static void MapBillingEndpoints(this RouteGroupBuilder api)
    {
        var subs = api.MapGroup("/subscriptions").WithTags("SuperAdmin · Subscriptions");
        subs.MapGet("", ListAsync);
        subs.MapGet("/plans", PlansAsync);
        subs.MapGet("/expiring", ExpiringAsync);
        subs.MapPost("/{id}/renew", RenewAsync);
        subs.MapPost("/{id}/cancel", CancelAsync);
        subs.MapPost("/{id}/plan", ChangePlanAsync);

        var revenue = api.MapGroup("/revenue").WithTags("SuperAdmin · Revenue");
        revenue.MapGet("", SummaryAsync);
        revenue.MapGet("/payments", PaymentsAsync);
        revenue.MapPost("/payments/{id}/status", InvoiceStatusAsync);

        var analytics = api.MapGroup("/analytics").WithTags("SuperAdmin · Analytics");
        analytics.MapGet("/client-sales", ClientSalesAsync);
        analytics.MapGet("/platform-revenue", PlatformRevenueAsync);
    }

    /*======================================================== subscriptions */

    public static async Task<IReadOnlyList<object>> SubscriptionsAsync(DbConnection control, string? tenantId, CancellationToken ct)
    {
        var rows = await control.QueryAsync<SubRow>(new CommandDefinition(
            """
            SELECT s.SubscriptionId, s.TenantId, t.Name AS ClientName, t.Status AS TenantStatus, t.BusinessType,
                   s.PlanKey, s.Cycle, s.IsTrial, s.TrialDays, s.StartsOn, s.RenewsOn, s.Status, s.CustomMonthlyH,
                   s.Renewals, s.LastRenewedOn, s.CancelledAtUtc, s.CancelReason,
                   p.MonthlyH, p.AnnualH, p.Transactions, p.StorageGb, p.Highlights,
                   COALESCE(c.Users, p.Users) AS Users, COALESCE(c.Devices, p.Devices) AS Devices,
                   COALESCE(c.Branches, p.Branches) AS Branches
            FROM ctl.Subscription AS s
            JOIN ctl.Tenant AS t ON t.TenantId = s.TenantId
            JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey
            LEFT JOIN ctl.PlanConfig AS c ON c.PlanKey = s.PlanKey AND c.BusinessType = t.BusinessType
            WHERE @TenantId IS NULL OR s.TenantId = @TenantId
            ORDER BY s.RenewsOn;
            """, new { TenantId = tenantId }, cancellationToken: ct));

        var today = DateOnly.FromDateTime(DateTime.UtcNow);

        return rows.Select(s =>
        {
            var mrr = ClientReader.Mrr(s.IsTrial, s.Status, s.TenantStatus, s.Cycle, s.CustomMonthlyH, s.MonthlyH, s.AnnualH);
            return (object)new
            {
                id = s.SubscriptionId,
                clientId = s.TenantId,
                clientName = s.ClientName,
                businessType = s.BusinessType,
                plan = s.PlanKey,
                cycle = s.Cycle,
                startsOn = s.StartsOn,
                renewsOn = s.RenewsOn,
                daysToRenewal = s.RenewsOn.DayNumber - today.DayNumber,
                mrrH = mrr,
                arrH = mrr * 12,
                status = s.Status == "cancelled" ? "cancelled"
                       : s.TenantStatus == "suspended" ? "suspended"
                       : s.IsTrial ? "trial" : "active",
                isTrial = s.IsTrial,
                trialDays = s.TrialDays,
                renewals = s.Renewals,
                lastRenewedOn = s.LastRenewedOn,
                cancelledAtUtc = s.CancelledAtUtc,
                cancelReason = s.CancelReason,
                customMonthlyH = s.CustomMonthlyH,
                limits = new
                {
                    key = s.PlanKey,
                    monthlyH = s.MonthlyH,
                    annualH = s.AnnualH,
                    branches = s.Branches,
                    devices = s.Devices,
                    users = s.Users,
                    transactions = s.Transactions,
                    storageGb = s.StorageGb,
                    features = (s.Highlights ?? "").Split('|', StringSplitOptions.RemoveEmptyEntries)
                }
            };
        }).ToList();
    }

    private static async Task<IResult> ListAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await SubscriptionsAsync(control, null, ct));
    }

    private static async Task<IResult> PlansAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await PlanListAsync(control, ct));
    }

    public static async Task<IReadOnlyList<object>> PlanListAsync(DbConnection control, CancellationToken ct)
    {
        var trialDays = await control.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT Value FROM ctl.Setting WHERE SettingKey = N'trialDays';", cancellationToken: ct));

        var plans = await control.QueryAsync(new CommandDefinition(
            """
            SELECT PlanKey, Label, IsTrial, MonthlyH, AnnualH, Branches, Devices, Users, Transactions, StorageGb, Highlights, IsActive
            FROM ctl.[Plan] ORDER BY SortOrder;
            """, cancellationToken: ct));

        return plans.Select(p => (object)new
        {
            key = (string)p.PlanKey,
            label = (string)p.Label,
            isTrial = (bool)p.IsTrial,
            trialDays = (bool)p.IsTrial ? int.TryParse(trialDays, out var d) ? d : 15 : (int?)null,
            monthlyH = (long?)p.MonthlyH,
            annualH = (long?)p.AnnualH,
            branches = (int?)p.Branches,
            devices = (int?)p.Devices,
            users = (int?)p.Users,
            transactions = (int?)p.Transactions,
            storageGb = (decimal?)p.StorageGb,
            isActive = (bool)p.IsActive,
            features = ((string?)p.Highlights ?? "").Split('|', StringSplitOptions.RemoveEmptyEntries)
        }).ToList();
    }

    private static async Task<IResult> ExpiringAsync(int? days, ClientReader reader, TenantCatalog catalog, CancellationToken ct)
    {
        var within = Math.Clamp(days ?? 30, 1, 3650);
        await using var control = catalog.Control();

        var subs = await SubscriptionsAsync(control, null, ct);
        var clients = (await reader.ListAsync(ct)).ToDictionary(c => c.Id);

        var rows = subs
            .Select(s => (dynamic)s)
            .Where(s => s.status != "cancelled" && s.daysToRenewal <= within)
            .OrderBy(s => (int)s.daysToRenewal)
            .Select(s =>
            {
                clients.TryGetValue((string)s.clientId, out var c);
                return new
                {
                    s.id, s.clientId, s.clientName, s.plan, s.cycle, s.startsOn, s.renewsOn, s.daysToRenewal,
                    s.mrrH, s.arrH, s.status, s.limits, s.isTrial,
                    businessType = c?.BusinessType,
                    poc = c?.Poc,
                    balanceH = c?.BalanceH ?? 0,
                    users = c?.Users ?? 0,
                    devices = c?.Devices ?? 0,
                    renewals = c?.Renewals ?? 0,
                    lastRenewedOn = c?.LastRenewedOn,
                    clientStatus = c?.Status
                };
            });

        return Results.Ok(rows);
    }

    /// <summary>
    /// Renew: the new term starts the day after the current one ends, so no
    /// paid days are lost. A renewal ends a trial and raises the invoice.
    /// </summary>
    private static async Task<IResult> RenewAsync(
        string id, RenewRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        var days = Math.Clamp(request.Days ?? 360, 1, 3650);
        await using var control = catalog.Control();
        await control.OpenAsync(ct);

        var sub = await control.QuerySingleOrDefaultAsync<SubRow>(new CommandDefinition(
            """
            SELECT s.SubscriptionId, s.TenantId, s.PlanKey, s.Cycle, s.IsTrial, s.RenewsOn, s.Status, s.CustomMonthlyH,
                   p.MonthlyH, p.AnnualH
            FROM ctl.Subscription AS s JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey
            WHERE s.SubscriptionId = @Id;
            """, new { Id = id }, cancellationToken: ct));
        if (sub is null) return ClientEndpoints.NotFound("No such subscription.");

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        /* Lapsed: the new term starts today, not in the past. */
        var start = sub.RenewsOn >= today ? sub.RenewsOn : today;
        var end = start.AddDays(days);

        await using var tx = await control.BeginTransactionAsync(ct);

        await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Subscription
            SET RenewsOn = @End, Renewals = Renewals + 1, LastRenewedOn = CAST(SYSUTCDATETIME() AS DATE),
                IsTrial = 0, Status = N'active', CancelledAtUtc = NULL, CancelReason = NULL,
                PlanKey = CASE WHEN PlanKey = N'Trial' THEN N'Basic' ELSE PlanKey END,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE SubscriptionId = @Id;

            INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail)
            VALUES (N'subscription_renewed', N'Subscription renewed', @TenantId, @Detail);
            """, new { End = end, Id = id, sub.TenantId, Detail = $"{days} days, to {end:yyyy-MM-dd}" }, tx, cancellationToken: ct));

        /* Priced at the list price for the cycle: an annual plan renewed for
           360 days costs exactly its annual price, a monthly one 12 months. */
        var plan = sub.PlanKey == "Trial" ? "Basic" : sub.PlanKey;
        var prices = await control.QuerySingleAsync<(long? MonthlyH, long? AnnualH)>(new CommandDefinition(
            "SELECT MonthlyH, AnnualH FROM ctl.[Plan] WHERE PlanKey = @Plan;", new { Plan = plan }, tx, cancellationToken: ct));

        long? amount = sub.CustomMonthlyH is { } custom ? (long)Math.Round(custom * days / 30.0)
                     : sub.Cycle == "annual" && prices.AnnualH is { } annual ? (long)Math.Round(annual * days / 360.0)
                     : prices.MonthlyH is { } monthly ? (long)Math.Round(monthly * days / 30.0)
                     : null;

        string? invoiceId = null;
        if (amount is > 0)
        {
            invoiceId = await Billing.RaiseInvoiceAsync(control, tx, sub.TenantId, id, plan,
                amount.Value, start, end, $"Renewal, {days} days", ct);
        }

        await tx.CommitAsync(ct);
        catalog.Evict(sub.TenantId);

        return Results.Ok(await audit.ResultAsync("subscription.renew", "Renewed subscription", sub.TenantId, id,
            sub.RenewsOn.ToString("yyyy-MM-dd"), $"{days} days", null, "ctl.Subscription", "UPDATE", 1,
            new { renewsOn = end, invoiceId }, ct));
    }

    private static async Task<IResult> CancelAsync(
        string id, ReasonRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Reason))
            return Results.BadRequest(new { code = "reason_required", message = "A reason is required." });

        await using var control = catalog.Control();
        var tenantId = await control.ExecuteScalarAsync<string?>(new CommandDefinition(
            """
            UPDATE ctl.Subscription
            SET Status = N'cancelled', CancelledAtUtc = SYSUTCDATETIME(), CancelReason = @Reason, UpdatedAtUtc = SYSUTCDATETIME()
            OUTPUT INSERTED.TenantId
            WHERE SubscriptionId = @Id AND Status = N'active';
            """, new { Id = id, request.Reason }, cancellationToken: ct));

        if (tenantId is null) return ClientEndpoints.Conflict("That subscription is not active.");

        catalog.Evict(tenantId);
        return Results.Ok(await audit.ResultAsync("subscription.cancel", "Cancelled subscription", tenantId, id,
            "active", "cancelled", request.Reason, "ctl.Subscription", "UPDATE", 1, null, ct));
    }

    private static async Task<IResult> ChangePlanAsync(
        string id, PlanChangeRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        await using var control = catalog.Control();

        var sub = await control.QuerySingleOrDefaultAsync<(string TenantId, string PlanKey, string Cycle)>(new CommandDefinition(
            "SELECT TenantId, PlanKey, Cycle FROM ctl.Subscription WHERE SubscriptionId = @Id;", new { Id = id }, cancellationToken: ct));
        if (sub.TenantId is null) return ClientEndpoints.NotFound("No such subscription.");

        var plan = request.Plan ?? sub.PlanKey;
        var cycle = request.Cycle is "monthly" or "annual" ? request.Cycle : sub.Cycle;

        if (await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.[Plan] WHERE PlanKey = @Plan AND IsActive = 1;", new { Plan = plan }, cancellationToken: ct)) is null)
            return Results.BadRequest(new { code = "unknown_plan", message = $"There is no active plan '{plan}'." });

        await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Subscription
            SET PlanKey = @Plan, Cycle = @Cycle, CustomMonthlyH = @Custom,
                IsTrial = CASE WHEN @Plan = N'Trial' THEN 1 ELSE IsTrial END, UpdatedAtUtc = SYSUTCDATETIME()
            WHERE SubscriptionId = @Id;

            INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail)
            VALUES (N'plan_upgraded', N'Plan changed', @TenantId, @Detail);
            """,
            new { Plan = plan, Cycle = cycle, Custom = request.CustomMonthlyH, Id = id, sub.TenantId, Detail = $"{sub.PlanKey} → {plan}" },
            cancellationToken: ct));

        catalog.Evict(sub.TenantId);
        return Results.Ok(await audit.ResultAsync("client.plan_change", "Changed plan", sub.TenantId, id,
            $"{sub.PlanKey} ({sub.Cycle})", $"{plan} ({cycle})", request.Reason, "ctl.Subscription", "UPDATE", 1, null, ct));
    }

    /*=============================================================== revenue */

    private static async Task<IResult> SummaryAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        var subs = (await SubscriptionsAsync(control, null, ct)).Select(s => (dynamic)s).ToList();

        var totals = await control.QuerySingleAsync(new CommandDefinition(
            """
            SELECT ISNULL(SUM(CASE WHEN Status = N'paid' THEN AmountH END), 0) AS CollectedH,
                   ISNULL(SUM(CASE WHEN Status = N'pending' THEN AmountH END), 0) AS OutstandingH,
                   ISNULL(SUM(CASE WHEN Status = N'failed' THEN AmountH END), 0) AS OverdueH,
                   ISNULL(SUM(CASE WHEN Status = N'refunded' THEN AmountH END), 0) AS RefundedH
            FROM ctl.Invoice;
            """, cancellationToken: ct));

        long mrr = subs.Sum(s => (long)s.mrrH);

        /* Last month's MRR, from subscriptions that existed then — an
           approximation that ignores mid-month plan changes. */
        var previous = await control.ExecuteScalarAsync<long?>(new CommandDefinition(
            """
            SELECT SUM(CASE WHEN s.CustomMonthlyH IS NOT NULL THEN s.CustomMonthlyH
                            WHEN s.Cycle = N'monthly' THEN p.MonthlyH ELSE p.AnnualH / 12 END)
            FROM ctl.Subscription AS s JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey
            WHERE s.IsTrial = 0 AND s.CreatedAtUtc < DATEADD(MONTH, -1, SYSUTCDATETIME())
              AND (s.CancelledAtUtc IS NULL OR s.CancelledAtUtc > DATEADD(MONTH, -1, SYSUTCDATETIME()));
            """, cancellationToken: ct)) ?? 0;

        return Results.Ok(new
        {
            mrrH = mrr,
            arrH = mrr * 12,
            collectedH = (long)totals.CollectedH,
            outstandingH = (long)totals.OutstandingH,
            overdueH = (long)totals.OverdueH,
            refundedH = (long)totals.RefundedH,
            previousMrrH = previous,
            byPlan = subs.Where(s => (long)s.mrrH > 0).GroupBy(s => (string)s.plan)
                         .Select(g => new { plan = g.Key, mrrH = g.Sum(s => (long)s.mrrH), clients = g.Count() }),
            byClient = subs.Where(s => s.status == "active").OrderByDescending(s => (long)s.mrrH).Take(25)
        });
    }

    private static async Task<IResult> PaymentsAsync(TenantCatalog catalog, CancellationToken ct)
    {
        await using var control = catalog.Control();
        return Results.Ok(await InvoicesAsync(control, null, ct));
    }

    public static async Task<IEnumerable<dynamic>> InvoicesAsync(DbConnection control, string? tenantId, CancellationToken ct) =>
        await control.QueryAsync(new CommandDefinition(
            """
            SELECT i.InvoiceId AS id, i.TenantId AS clientId, t.Name AS clientName, i.PlanKey AS [plan],
                   i.AmountH AS amountH, i.Method AS method, i.Status AS status,
                   CONVERT(CHAR(10), i.IssuedOn, 23) AS issuedOn, CONVERT(CHAR(10), i.PaidOn, 23) AS paidOn,
                   CONVERT(CHAR(10), i.PeriodStart, 23) AS periodStart, CONVERT(CHAR(10), i.PeriodEnd, 23) AS periodEnd,
                   i.Notes AS notes,
                   i.SubscriptionId AS subscriptionId
            FROM ctl.Invoice AS i JOIN ctl.Tenant AS t ON t.TenantId = i.TenantId
            WHERE @TenantId IS NULL OR i.TenantId = @TenantId
            ORDER BY i.IssuedOn DESC, i.InvoiceId DESC;
            """, new { TenantId = tenantId }, cancellationToken: ct));

    /// <summary>Record that an invoice was paid, failed or refunded.</summary>
    private static async Task<IResult> InvoiceStatusAsync(
        string id, InvoiceStatusRequest request, TenantCatalog catalog, AdminAuditor audit, CancellationToken ct)
    {
        if (request.Status is not ("paid" or "pending" or "failed" or "refunded"))
            return Results.BadRequest(new { code = "bad_status", message = "Status is paid, pending, failed or refunded." });

        await using var control = catalog.Control();
        var before = await control.QuerySingleOrDefaultAsync<(string TenantId, string Status)>(new CommandDefinition(
            "SELECT TenantId, Status FROM ctl.Invoice WHERE InvoiceId = @Id;", new { Id = id }, cancellationToken: ct));
        if (before.TenantId is null) return ClientEndpoints.NotFound("No such invoice.");

        await control.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ctl.Invoice
            SET Status = @Status, Method = COALESCE(@Method, Method), Notes = COALESCE(@Notes, Notes),
                PaidOn = CASE WHEN @Status = N'paid' THEN CAST(SYSUTCDATETIME() AS DATE) WHEN @Status = N'refunded' THEN PaidOn ELSE NULL END
            WHERE InvoiceId = @Id;

            IF @Status = N'failed'
                INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail, Severity)
                VALUES (N'payment_failed', N'Payment failed', @TenantId, @Id, N'warning');
            """, new { request.Status, request.Method, request.Notes, Id = id, before.TenantId }, cancellationToken: ct));

        return Results.Ok(await audit.ResultAsync("invoice.status", $"Invoice marked {request.Status}", before.TenantId, id,
            before.Status, request.Status, request.Notes, "ctl.Invoice", "UPDATE", 1, null, ct));
    }

    /*============================================================= analytics */

    private static async Task<IResult> ClientSalesAsync(
        string? range, DateOnly? from, DateOnly? to, TenantCatalog catalog, CancellationToken ct)
    {
        var window = DateWindow.Parse(range, from, to);
        await using var control = catalog.Control();

        var days = (await control.QueryAsync<(DateTime StatDate, long Transactions, long SalesH)>(new CommandDefinition(
            """
            SELECT StatDate, SUM(CAST(Transactions AS BIGINT)), SUM(SalesH)
            FROM ctl.TenantDailyStat WHERE StatDate >= @From AND StatDate < @To
            GROUP BY StatDate;
            """, new { From = window.From.Date, To = window.To.Date }, cancellationToken: ct))).ToList();

        var buckets = window.Buckets().Select(b =>
        {
            var inside = days.Where(d => d.StatDate >= b.Start && d.StatDate < b.End).ToList();
            var tx = inside.Sum(d => d.Transactions);
            var sales = inside.Sum(d => d.SalesH);
            return (b, tx, sales);
        }).ToList();

        return Results.Ok(new
        {
            volume = buckets.Select(x => new { label = x.b.Label, date = DateOnly.FromDateTime(x.b.Start), value = x.tx }),
            value = buckets.Select(x => new { label = x.b.Label, date = DateOnly.FromDateTime(x.b.Start), value = x.sales }),
            averageTicketH = buckets.Select(x => new
            {
                label = x.b.Label, date = DateOnly.FromDateTime(x.b.Start), value = x.tx > 0 ? x.sales / x.tx : 0
            })
        });
    }

    private static async Task<IResult> PlatformRevenueAsync(
        string? range, DateOnly? from, DateOnly? to, TenantCatalog catalog, CancellationToken ct)
    {
        var window = DateWindow.Parse(range, from, to);
        await using var control = catalog.Control();

        var subs = (await control.QueryAsync<SubRow>(new CommandDefinition(
            """
            SELECT s.SubscriptionId, s.TenantId, s.PlanKey, s.Cycle, s.IsTrial, s.StartsOn, s.RenewsOn, s.Status,
                   s.CustomMonthlyH, s.CancelledAtUtc, s.CreatedAtUtc, p.MonthlyH, p.AnnualH
            FROM ctl.Subscription AS s JOIN ctl.[Plan] AS p ON p.PlanKey = s.PlanKey;
            """, cancellationToken: ct))).ToList();

        long MonthlyOf(SubRow s) => s.CustomMonthlyH ?? (s.Cycle == "monthly" ? s.MonthlyH : s.AnnualH / 12) ?? 0;

        /* MRR at a moment: paid subscriptions that existed and were not cancelled. */
        long MrrAt(DateTime at) => subs
            .Where(s => !s.IsTrial && s.CreatedAtUtc <= at && (s.CancelledAtUtc is null || s.CancelledAtUtc > at))
            .Sum(MonthlyOf);

        var points = window.Buckets().Select(b => new
        {
            label = b.Label,
            date = DateOnly.FromDateTime(b.Start),
            value = MrrAt(b.End)
        }).ToList();

        var newMrr = subs.Where(s => !s.IsTrial && s.CreatedAtUtc >= window.From && s.CreatedAtUtc < window.To).Sum(MonthlyOf);
        var churned = subs.Where(s => s.CancelledAtUtc >= window.From && s.CancelledAtUtc < window.To).Sum(MonthlyOf);

        return Results.Ok(new { mrr = points, newMrrH = newMrr, churnedMrrH = churned, netMrrH = newMrr - churned });
    }

    private sealed record SubRow
    {
        public string SubscriptionId { get; init; } = "";
        public string TenantId { get; init; } = "";
        public string? ClientName { get; init; }
        public string? TenantStatus { get; init; }
        public string? BusinessType { get; init; }
        public string PlanKey { get; init; } = "";
        public string Cycle { get; init; } = "annual";
        public bool IsTrial { get; init; }
        public int? TrialDays { get; init; }
        public DateOnly StartsOn { get; init; }
        public DateOnly RenewsOn { get; init; }
        public string Status { get; init; } = "";
        public long? CustomMonthlyH { get; init; }
        public int Renewals { get; init; }
        public DateOnly? LastRenewedOn { get; init; }
        public DateTime? CancelledAtUtc { get; init; }
        public string? CancelReason { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public long? MonthlyH { get; init; }
        public long? AnnualH { get; init; }
        public int? Transactions { get; init; }
        public decimal? StorageGb { get; init; }
        public string? Highlights { get; init; }
        public int? Users { get; init; }
        public int? Devices { get; init; }
        public int? Branches { get; init; }
    }
}
