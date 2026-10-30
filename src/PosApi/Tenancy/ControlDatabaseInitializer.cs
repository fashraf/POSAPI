using Dapper;
using Npgsql;
using Microsoft.Extensions.Options;
using PosApi.Auth;

namespace PosApi.Tenancy;

/// <summary>
/// Brings the control database up before the API takes a request.
///
///  1. Creates the control database if it is missing and applies db-control/ files.
///  2. Creates the first platform administrator from SuperAdmin:Mobile and
///     SuperAdmin:Password when there is none — a hash cannot be seeded
///     honestly from SQL, and an unusable seed admin is worse than none.
///  3. Adopts a database built by apply-migrations (Tenancy:AdoptDatabase,
///     posmain by default) as the first tenant, so a demo or single-business
///     install signs in without being provisioned through the console.
///
/// Runs synchronously at startup. If the control database cannot be reached
/// the API refuses to start: every sign-in depends on it, and an API that is
/// up but refuses everyone looks healthy when it is not.
/// </summary>
public sealed class ControlDatabaseInitializer
{
    private readonly TenancyConnections _connections;
    private readonly TenancyOptions _options;
    private readonly SqlScriptRunner _runner;
    private readonly LoginDirectory _directory;
    private readonly IPasswordHasher _hasher;
    private readonly IConfiguration _configuration;
    private readonly IWebHostEnvironment _environment;
    private readonly ILogger<ControlDatabaseInitializer> _logger;

    public ControlDatabaseInitializer(
        TenancyConnections connections, IOptions<TenancyOptions> options, SqlScriptRunner runner,
        LoginDirectory directory, IPasswordHasher hasher, IConfiguration configuration,
        IWebHostEnvironment environment, ILogger<ControlDatabaseInitializer> logger)
    {
        _connections = connections;
        _options = options.Value;
        _runner = runner;
        _directory = directory;
        _hasher = hasher;
        _configuration = configuration;
        _environment = environment;
        _logger = logger;
    }

    public async Task InitializeAsync(CancellationToken ct)
    {
        var folder = SqlScriptRunner.ResolveFolder(_options.ControlMigrationsPath, "db-control", _environment);
        var files = SqlScriptRunner.Files(folder, 1, 999);

        if (files.Count == 0)
            throw new InvalidOperationException($"No control database migrations found in {folder}.");

        var applied = await _runner.ApplyAsync(
            _connections.ControlServer, _connections.ControlDatabase, files, ct);

        _logger.LogInformation("Control database {Database}: {Count} migration(s) applied.",
            _connections.ControlDatabase, applied.Count);

        await SeedAdminAsync(ct);
        await AdoptAsync(ct);
    }

    private async Task SeedAdminAsync(CancellationToken ct)
    {
        await using var control = new NpgsqlConnection(_connections.Control);

        if (await control.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM ctl.Admin;", cancellationToken: ct)) > 0)
            return;

        var mobile = _configuration["SuperAdmin:Mobile"];
        var password = _configuration["SuperAdmin:Password"];

        if (string.IsNullOrWhiteSpace(mobile) || string.IsNullOrWhiteSpace(password))
        {
            _logger.LogWarning(
                "No platform administrator exists. Set SuperAdmin:Mobile and SuperAdmin:Password " +
                "(user-secrets or environment) and restart to create the first one.");
            return;
        }

        if (password.Length < 8)
            throw new InvalidOperationException("SuperAdmin:Password needs at least 8 characters.");

        var (hash, salt) = _hasher.Hash(password);

        await control.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO ctl.Admin (AdminId, Name, Mobile, Email, Role, PasswordHash, PasswordSalt, MustChangePassword)
            VALUES ('adm_root', @Name, @Mobile, @Email, 'Owner', @Hash, @Salt, false);
            """,
            new
            {
                Name = _configuration["SuperAdmin:Name"] ?? "Platform admin",
                Mobile = mobile.Trim(),
                Email = _configuration["SuperAdmin:Email"],
                Hash = hash,
                Salt = salt
            }, cancellationToken: ct));

        _logger.LogInformation("Created the first platform administrator ({Mobile}).", mobile);
    }

    private async Task AdoptAsync(CancellationToken ct)
    {
        var database = _options.AdoptDatabase.ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(database) || !SqlScriptRunner.IsSafeName(database)) return;

        await using var control = new NpgsqlConnection(_connections.Control);

        if (await control.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT 1 FROM ctl.Tenant WHERE DatabaseName = @Database;",
                new { Database = database }, cancellationToken: ct)) is not null)
            return;

        var tenantConnection = _connections.ForTenant(database);

        /* Only a database that really is a POS tenant: present, and built by
           the migrations (they record themselves in dbo.SchemaMigration). */
        var applied = await _runner.AppliedAsync(_connections.TenantServer, database, ct);
        if (applied.Count == 0)
        {
            _logger.LogInformation("Nothing to adopt: {Database} is missing or has no POS schema.", database);
            return;
        }

        await using var tenant = new NpgsqlConnection(tenantConnection);

        var company = await tenant.QueryFirstOrDefaultAsync<(string NameEn, string NameAr, string? City, string? CrNumber, string? VatNumber, string? Email, string? Phone)>(
            new CommandDefinition("SELECT NameEn, NameAr, City, CrNumber, VatNumber, Email, Phone FROM core.Company ORDER BY CompanyId LIMIT 1;",
                cancellationToken: ct));

        var owner = await tenant.QueryFirstOrDefaultAsync<(string UserId, string NameEn, string Username, string? Email, string? Phone)>(
            new CommandDefinition(
                "SELECT UserId, NameEn, Username, Email, Phone FROM core.AppUser WHERE RoleId = 'rol_owner' ORDER BY CreatedAtUtc LIMIT 1;",
                cancellationToken: ct));

        var number = await control.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT nextval('ctl.TenantNumber')::int;", cancellationToken: ct));
        var tenantId = $"CL-{number:00000}";
        var subNumber = await control.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT nextval('ctl.SubscriptionNumber')::int;", cancellationToken: ct));

        await control.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO ctl.Tenant
                (TenantId, Name, NameAr, BusinessType, City, Country, CrNumber, VatNumber, Email, Phone,
                 DatabaseName, Status, Source, PocUserId, PocName, PocUsername, PocMobile, PocEmail,
                 SchemaVersion, MigratedAtUtc, RegisteredBy, ActivatedBy, ActivatedAtUtc)
            VALUES
                (@TenantId, @Name, @NameAr, 'Retail', @City, 'Saudi Arabia', @CrNumber, @VatNumber, @Email, @Phone,
                 @Database, 'active', 'adopted', @PocUserId, @PocName, @PocUsername, @PocMobile, @PocEmail,
                 @Version, now() AT TIME ZONE 'utc', 'migration', 'migration', now() AT TIME ZONE 'utc');

            /* An adopted business keeps working as it did: no limits and a
               long term, to be put on a real plan from the console. */
            INSERT INTO ctl.Subscription (SubscriptionId, TenantId, PlanKey, Cycle, StartsOn, RenewsOn)
            VALUES (@SubscriptionId, @TenantId, 'Enterprise', 'annual',
                    (now() AT TIME ZONE 'utc')::date, ((now() AT TIME ZONE 'utc') + interval '1 year')::date);

            INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail)
            VALUES ('client_created', 'Client adopted', @TenantId, @Detail);
            """,
            new
            {
                TenantId = tenantId,
                Name = company.NameEn ?? database,
                company.NameAr,
                company.City,
                company.CrNumber,
                company.VatNumber,
                company.Email,
                company.Phone,
                Database = database,
                PocUserId = owner.UserId,
                PocName = owner.NameEn,
                PocUsername = owner.Username,
                PocMobile = owner.Phone,
                PocEmail = owner.Email,
                Version = applied.Max(StringComparer.Ordinal),
                SubscriptionId = $"SUB-{subNumber:00000}",
                Detail = $"Existing database {database} registered as a tenant"
            }, cancellationToken: ct));

        var entries = await _directory.RebuildTenantAsync(tenantId, tenantConnection, ct);

        _logger.LogInformation(
            "Adopted existing database {Database} as tenant {TenantId} ({Entries} sign-in identifiers).",
            database, tenantId, entries);
    }
}

/// <summary>
/// Applies new tenant migrations to every tenant database.
///
/// In the background at startup, so a platform with many tenants is not held
/// offline while each is updated; the console can also run it on demand. One
/// tenant failing is logged and recorded, and the others carry on.
/// </summary>
public sealed class TenantMigrationService : BackgroundService
{
    private readonly TenancyConnections _connections;
    private readonly TenancyOptions _options;
    private readonly SqlScriptRunner _runner;
    private readonly TenantProvisioner _provisioner;
    private readonly ILogger<TenantMigrationService> _logger;

    public TenantMigrationService(
        TenancyConnections connections, IOptions<TenancyOptions> options, SqlScriptRunner runner,
        TenantProvisioner provisioner, ILogger<TenantMigrationService> logger)
    {
        _connections = connections;
        _options = options.Value;
        _runner = runner;
        _provisioner = provisioner;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.MigrateTenantsOnStartup) return;

        try
        {
            await MigrateAllAsync(stoppingToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogError(ex, "Tenant migration pass failed.");
        }
    }

    public sealed record MigrationOutcome(string TenantId, string Database, IReadOnlyList<string> Applied, string? Error);

    public async Task<IReadOnlyList<MigrationOutcome>> MigrateAllAsync(CancellationToken ct)
    {
        var files = SqlScriptRunner.Files(_provisioner.MigrationsFolder);
        if (files.Count == 0) return [];

        await using var control = new NpgsqlConnection(_connections.Control);
        var tenants = (await control.QueryAsync<(string TenantId, string DatabaseName)>(new CommandDefinition(
            "SELECT TenantId, DatabaseName FROM ctl.Tenant WHERE Status IN ('active', 'suspended') ORDER BY TenantId;",
            cancellationToken: ct))).ToList();

        var outcomes = new List<MigrationOutcome>();

        foreach (var (tenantId, database) in tenants)
        {
            try
            {
                var applied = await _runner.ApplyAsync(_connections.TenantServer, database, files, ct);

                if (applied.Count > 0)
                {
                    _logger.LogInformation("Tenant {TenantId}: applied {Files}.", tenantId, string.Join(", ", applied));

                    await control.ExecuteAsync(new CommandDefinition(
                        "UPDATE ctl.Tenant SET SchemaVersion = @Version, MigratedAtUtc = now() AT TIME ZONE 'utc' WHERE TenantId = @TenantId;",
                        new { Version = applied[^1], TenantId = tenantId }, cancellationToken: ct));
                }

                outcomes.Add(new MigrationOutcome(tenantId, database, applied, null));
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Tenant {TenantId} ({Database}) could not be migrated.", tenantId, database);
                outcomes.Add(new MigrationOutcome(tenantId, database, [], ex.Message));

                await control.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail, Severity)
                    VALUES ('migration_failed', 'Database update failed', @TenantId, @Detail, 'warning');
                    """,
                    new { TenantId = tenantId, Detail = ex.Message.Length > 400 ? ex.Message[..400] : ex.Message },
                    cancellationToken: ct));
            }
        }

        return outcomes;
    }
}
