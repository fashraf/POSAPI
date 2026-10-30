using Dapper;
using Npgsql;
using PosApi.Data;
using Microsoft.Extensions.Options;

namespace PosApi.Tenancy;

public sealed record ProvisionRequest
{
    public required string Name { get; init; }
    public string? NameAr { get; init; }
    public string? BusinessType { get; init; }
    public string? City { get; init; }
    public string? Country { get; init; }
    public string? CrNumber { get; init; }
    public string? VatNumber { get; init; }
    public string? Email { get; init; }
    public string? Phone { get; init; }

    public required string OwnerName { get; init; }
    public required string OwnerEmail { get; init; }
    public string? OwnerPhone { get; init; }
    /// <summary>Blank signs in with the email, as self-registration always has.</summary>
    public string? OwnerUsername { get; init; }
    public string? OwnerPasswordHash { get; init; }
    public string? OwnerPasswordSalt { get; init; }

    public string BranchName { get; init; } = "Main Branch";
    public string? BranchAddress { get; init; }
    public string? Latitude { get; init; }
    public string? Longitude { get; init; }

    public string PlanKey { get; init; } = "Trial";
    public string Cycle { get; init; } = "annual";
    public DateOnly? StartsOn { get; init; }
    public bool Trial { get; init; }

    public IReadOnlyList<string>? PaymentMethods { get; init; }
    public decimal DefaultVat { get; init; } = 15;
    public bool PricesIncludeVat { get; init; } = true;
    public string? Certificate { get; init; }
    public DateOnly? CertificateExpiry { get; init; }

    /// <summary>admin | self-signup.</summary>
    public string Source { get; init; } = "admin";
    public string? RegisteredBy { get; init; }
}

public sealed record ProvisionResult(
    string TenantId, string DatabaseName, string OwnerUserId, string BranchId, string SubscriptionId);

/// <summary>A refusal the caller can show: which field, and why, in both languages.</summary>
public sealed class ProvisionException(string code, string messageEn, string messageAr, string? field = null)
    : Exception(messageEn)
{
    public string Code { get; } = code;
    public string MessageAr { get; } = messageAr;
    public string? Field { get; } = field;
}

/// <summary>
/// Creates a tenant: a control record, a database of its own built from
/// db-migrations/, the business inside it, a subscription, and its sign-in
/// identifiers in the directory.
///
/// All or nothing. If any step fails the database is dropped and the control
/// rows removed, so a failed attempt leaves neither a half-built business nor
/// an email that can never be registered again.
/// </summary>
public sealed class TenantProvisioner
{
    private readonly TenancyConnections _connections;
    private readonly TenancyOptions _options;
    private readonly SqlScriptRunner _runner;
    private readonly LoginDirectory _directory;
    private readonly IWebHostEnvironment _environment;
    private readonly ILogger<TenantProvisioner> _logger;

    public TenantProvisioner(
        TenancyConnections connections, IOptions<TenancyOptions> options, SqlScriptRunner runner,
        LoginDirectory directory, IWebHostEnvironment environment, ILogger<TenantProvisioner> logger)
    {
        _connections = connections;
        _options = options.Value;
        _runner = runner;
        _directory = directory;
        _environment = environment;
        _logger = logger;
    }

    public string MigrationsFolder =>
        SqlScriptRunner.ResolveFolder(_options.TenantMigrationsPath, "db-migrations", _environment);

    public async Task<ProvisionResult> ProvisionAsync(ProvisionRequest request, CancellationToken ct)
    {
        var ownerEmail = request.OwnerEmail.Trim().ToLowerInvariant();
        var ownerUsername = string.IsNullOrWhiteSpace(request.OwnerUsername)
            ? ownerEmail
            : request.OwnerUsername.Trim().ToLowerInvariant();
        var ownerPhone = string.IsNullOrWhiteSpace(request.OwnerPhone) ? null : request.OwnerPhone.Trim();

        /* Checked before anything is created: a clash found after the database
           exists would mean building and dropping a database for nothing. */
        var taken = await _directory.FirstTakenAsync("", null, [ownerEmail, ownerPhone, ownerUsername], ct);
        if (taken is not null)
        {
            var field = taken == ownerEmail ? "email" : taken == ownerPhone ? "mobile" : "username";
            throw new ProvisionException($"{field}_taken",
                $"'{taken}' is already used by an account on the platform.",
                $"'{taken}' مستخدم بالفعل لحساب على المنصة.", field);
        }

        if (SqlScriptRunner.Files(MigrationsFolder).Count == 0)
            throw new InvalidOperationException($"No tenant migrations found in {MigrationsFolder}.");

        await using var control = new NpgsqlConnection(_connections.Control);
        await control.OpenAsync(ct);

        var (tenantId, database) = await AllocateAsync(control, ct);
        var created = false;

        try
        {
            await control.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO ctl.Tenant
                    (TenantId, Name, NameAr, BusinessType, City, Country, CrNumber, VatNumber, Email, Phone,
                     DatabaseName, Status, Source, PocName, PocUsername, PocMobile, PocEmail,
                     PaymentMethods, DefaultVat, PricesIncludeVat, ZatcaCertificate, CertificateExpiry,
                     BranchAddress, Latitude, Longitude, RegisteredBy)
                VALUES
                    (@TenantId, @Name, @NameAr, @BusinessType, @City, @Country, @CrNumber, @VatNumber, @Email, @Phone,
                     @Database, 'provisioning', @Source, @OwnerName, @OwnerUsername, @OwnerPhone, @OwnerEmail,
                     @PaymentMethods, @DefaultVat, @PricesIncludeVat, @Certificate, @CertificateExpiry,
                     @BranchAddress, @Latitude, @Longitude, @RegisteredBy);
                """,
                new
                {
                    TenantId = tenantId, request.Name, request.NameAr, request.BusinessType, request.City,
                    Country = request.Country ?? "Saudi Arabia", request.CrNumber, request.VatNumber,
                    request.Email, request.Phone, Database = database, request.Source,
                    request.OwnerName, OwnerUsername = ownerUsername, OwnerPhone = ownerPhone, OwnerEmail = ownerEmail,
                    PaymentMethods = request.PaymentMethods is { Count: > 0 } pm ? string.Join(",", pm) : null,
                    request.DefaultVat, request.PricesIncludeVat, request.Certificate, request.CertificateExpiry,
                    request.BranchAddress, request.Latitude, request.Longitude, request.RegisteredBy
                }, cancellationToken: ct));

            /*------------------------------------------------ its own database */

            created = true;
            var applied = await _runner.ApplyAsync(
                _connections.TenantServer, database, SqlScriptRunner.Files(MigrationsFolder), ct);

            var tenantConnection = _connections.ForTenant(database);
            var (userId, branchId) = await RegisterBusinessAsync(tenantConnection, request, ownerEmail, ownerUsername, ownerPhone, ct);

            /*------------------------------------------------- subscription */

            var subscriptionId = await OpenSubscriptionAsync(control, tenantId, request, ct);

            await _directory.RebuildTenantAsync(tenantId, tenantConnection, ct);

            await control.ExecuteAsync(new CommandDefinition(
                """
                UPDATE ctl.Tenant
                SET Status = 'active', PocUserId = @UserId, SchemaVersion = @Version,
                    MigratedAtUtc = now() AT TIME ZONE 'utc', ActivatedAtUtc = now() AT TIME ZONE 'utc',
                    ActivatedBy = @ActivatedBy, UpdatedAtUtc = now() AT TIME ZONE 'utc'
                WHERE TenantId = @TenantId;

                INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail)
                VALUES ('client_created', 'Client created', @TenantId, @Detail);
                """,
                new
                {
                    TenantId = tenantId, UserId = userId, Version = applied.LastOrDefault(),
                    ActivatedBy = request.RegisteredBy ?? "self-signup",
                    Detail = request.Source == "self-signup" ? "Self sign-up, free trial" : $"{request.PlanKey} plan"
                }, cancellationToken: ct));

            _logger.LogInformation("Provisioned tenant {TenantId} in database {Database}.", tenantId, database);

            return new ProvisionResult(tenantId, database, userId, branchId, subscriptionId);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Provisioning {TenantId} failed; rolling it back.", tenantId);
            await RollBackAsync(tenantId, database, created);
            throw;
        }
    }

    /// <summary>The next tenant number whose database name is free.</summary>
    private async Task<(string TenantId, string Database)> AllocateAsync(NpgsqlConnection control, CancellationToken ct)
    {
        for (var attempt = 0; attempt < 50; attempt++)
        {
            var number = await control.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT nextval('ctl.TenantNumber')::int;", cancellationToken: ct));

            var tenantId = $"CL-{number:00000}";
            var database = $"{_options.TenantDatabasePrefix}cl{number:00000}".ToLowerInvariant();

            var exists = await SqlScriptRunner.ExistsAsync(_connections.TenantServer, database, ct);

            var known = await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.Tenant WHERE TenantId = @TenantId OR DatabaseName = @Database;",
                new { TenantId = tenantId, Database = database }, cancellationToken: ct));

            if (!exists && known is null) return (tenantId, database);
        }

        throw new InvalidOperationException("Could not find a free tenant number.");
    }

    private static async Task<(string UserId, string BranchId)> RegisterBusinessAsync(
        string tenantConnection, ProvisionRequest request, string ownerEmail, string ownerUsername,
        string? ownerPhone, CancellationToken ct)
    {
        await using var tenant = new NpgsqlConnection(tenantConnection);

        string userId, branchId;

        try
        {
            (userId, branchId) = await tenant.QuerySingleAsync<(string UserId, string BranchId)>(new CommandDefinition(
                """
                SELECT UserId, BranchId FROM core.usp_RegisterBusiness(
                    p_CompanyNameAr => @CompanyNameAr, p_CompanyNameEn => @CompanyNameEn,
                    p_CrNumber => @CrNumber, p_VatNumber => @VatNumber, p_City => @City,
                    p_BranchNameAr => @BranchNameAr, p_BranchNameEn => @BranchNameEn,
                    p_OwnerNameAr => @OwnerNameAr, p_OwnerNameEn => @OwnerNameEn,
                    p_OwnerEmail => @OwnerEmail, p_OwnerPhone => @OwnerPhone,
                    p_PasswordHash => @PasswordHash, p_PasswordSalt => @PasswordSalt);
                """,
                new
                {
                    CompanyNameAr = string.IsNullOrWhiteSpace(request.NameAr) ? request.Name : request.NameAr,
                    CompanyNameEn = request.Name,
                    request.CrNumber,
                    request.VatNumber,
                    request.City,
                    BranchNameAr = request.BranchName,
                    BranchNameEn = request.BranchName,
                    OwnerNameAr = request.OwnerName,
                    OwnerNameEn = request.OwnerName,
                    OwnerEmail = ownerEmail,
                    OwnerPhone = ownerPhone,
                    PasswordHash = request.OwnerPasswordHash,
                    PasswordSalt = request.OwnerPasswordSalt
                }, cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() is >= 53000 and < 54000)
        {
            throw ex.ErrorNumber() switch
            {
                53000 => new ProvisionException("name_required",
                    "The business needs a name.", "المنشأة تحتاج اسمًا.", "companyName"),
                53001 => new ProvisionException("email_required",
                    "An email address is required.", "البريد الإلكتروني مطلوب.", "email"),
                53004 => new ProvisionException("bad_vat",
                    "A Saudi VAT number is 15 digits beginning and ending with 3.",
                    "الرقم الضريبي السعودي ١٥ رقمًا يبدأ وينتهي بالرقم ٣.", "vatNumber"),
                _ => new ProvisionException("registration_failed",
                    "Registration could not be completed.", "تعذّر إكمال التسجيل.")
            };
        }

        await tenant.ExecuteAsync(new CommandDefinition(
            """
            UPDATE core.AppUser SET Username = @Username, UpdatedAtUtc = now() AT TIME ZONE 'utc' WHERE UserId = @UserId;
            UPDATE core.Company SET Email = COALESCE(@Email, Email), Phone = COALESCE(@Phone, Phone);
            UPDATE core.Branch SET AddressEn = @Address, AddressAr = @Address WHERE BranchId = @BranchId AND @Address IS NOT NULL;
            """,
            new
            {
                Username = ownerUsername, UserId = userId, request.Email, request.Phone,
                Address = request.BranchAddress, BranchId = branchId
            }, cancellationToken: ct));

        return (userId, branchId);
    }

    /// <summary>
    /// The first term. A trial runs for the configured trial length and bills
    /// nothing; a paid plan runs a month or a year and raises its first invoice.
    /// </summary>
    private static async Task<string> OpenSubscriptionAsync(
        NpgsqlConnection control, string tenantId, ProvisionRequest request, CancellationToken ct)
    {
        var plan = await control.QuerySingleOrDefaultAsync<(string PlanKey, long? MonthlyH, long? AnnualH)>(
            new CommandDefinition("SELECT PlanKey, MonthlyH, AnnualH FROM ctl.Plan WHERE PlanKey = @PlanKey;",
                new { request.PlanKey }, cancellationToken: ct));

        if (plan.PlanKey is null)
            throw new ProvisionException("unknown_plan", $"There is no plan '{request.PlanKey}'.",
                "الباقة غير موجودة.", "plan");

        var trialDays = int.TryParse(await control.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT Value FROM ctl.Setting WHERE SettingKey = 'trialDays';", cancellationToken: ct)), out var d) ? d : 15;

        var isTrial = request.Trial || request.PlanKey == "Trial";
        var cycle = request.Cycle == "monthly" ? "monthly" : "annual";
        var starts = request.StartsOn ?? DateOnly.FromDateTime(DateTime.UtcNow);
        var renews = isTrial ? starts.AddDays(trialDays)
                   : cycle == "monthly" ? starts.AddMonths(1) : starts.AddYears(1);

        var number = await control.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT nextval('ctl.SubscriptionNumber')::int;", cancellationToken: ct));
        var subscriptionId = $"SUB-{number:00000}";

        await control.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO ctl.Subscription (SubscriptionId, TenantId, PlanKey, Cycle, IsTrial, TrialDays, StartsOn, RenewsOn)
            VALUES (@SubscriptionId, @TenantId, @PlanKey, @Cycle, @IsTrial, @TrialDays, @StartsOn, @RenewsOn);
            """,
            new
            {
                SubscriptionId = subscriptionId, TenantId = tenantId, request.PlanKey, Cycle = cycle,
                IsTrial = isTrial, TrialDays = isTrial ? trialDays : (int?)null, StartsOn = starts, RenewsOn = renews
            }, cancellationToken: ct));

        var amount = isTrial ? null : cycle == "monthly" ? plan.MonthlyH : plan.AnnualH;
        if (amount is > 0)
        {
            await Billing.RaiseInvoiceAsync(control, null, tenantId, subscriptionId, request.PlanKey,
                amount.Value, starts, renews, "First term", ct);
        }

        return subscriptionId;
    }

    private async Task RollBackAsync(string tenantId, string database, bool created)
    {
        try
        {
            await using var control = new NpgsqlConnection(_connections.Control);
            await control.ExecuteAsync(
                """
                DELETE FROM ctl.LoginDirectory WHERE TenantId = @TenantId;
                DELETE FROM ctl.Invoice WHERE TenantId = @TenantId;
                DELETE FROM ctl.Subscription WHERE TenantId = @TenantId;
                DELETE FROM ctl.Tenant WHERE TenantId = @TenantId;
                """, new { TenantId = tenantId });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not remove the control rows of failed tenant {TenantId}.", tenantId);
        }

        if (!created || !SqlScriptRunner.IsSafeName(database)) return;

        try
        {
            await SqlScriptRunner.DropAsync(_connections.TenantServer, database, CancellationToken.None);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not drop database {Database} of failed tenant {TenantId}.", database, tenantId);
        }
    }
}

/// <summary>Invoices: numbered from the control database's own sequence.</summary>
public static class Billing
{
    public static async Task<string> RaiseInvoiceAsync(
        NpgsqlConnection control, NpgsqlTransaction? tx, string tenantId, string? subscriptionId, string planKey,
        long amountH, DateOnly periodStart, DateOnly periodEnd, string? notes, CancellationToken ct)
    {
        var number = await control.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT nextval('ctl.InvoiceNumber')::int;", transaction: tx, cancellationToken: ct));
        var invoiceId = $"INV-{number}";

        await control.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO ctl.Invoice (InvoiceId, TenantId, SubscriptionId, PlanKey, AmountH, Status, IssuedOn, PeriodStart, PeriodEnd, Notes)
            VALUES (@InvoiceId, @TenantId, @SubscriptionId, @PlanKey, @AmountH, 'pending', (now() AT TIME ZONE 'utc')::date, @PeriodStart, @PeriodEnd, @Notes);
            """,
            new
            {
                InvoiceId = invoiceId, TenantId = tenantId, SubscriptionId = subscriptionId, PlanKey = planKey,
                AmountH = amountH, PeriodStart = periodStart, PeriodEnd = periodEnd, Notes = notes
            }, tx, cancellationToken: ct));

        return invoiceId;
    }
}
