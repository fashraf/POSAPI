using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace PosApi.Tenancy;

/// <summary>
/// Where the control database and the tenant databases are.
///
/// One control database (POSCONTROL) holds the tenants, plans, subscriptions
/// and administrators. Every tenant has a database of its own on the tenant
/// server, built from db-migrations/. Nothing a tenant sells or stocks is ever
/// written to the control database, and no tenant database knows the others
/// exist.
/// </summary>
public sealed class TenancyOptions
{
    public const string SectionName = "Tenancy";

    /// <summary>Catalog name of the control database.</summary>
    public string ControlDatabase { get; init; } = "POSCONTROL";

    /// <summary>New tenant databases are named prefix + tenant number, e.g. POS_CL00002.</summary>
    public string TenantDatabasePrefix { get; init; } = "POS_";

    /// <summary>
    /// An existing single-tenant database to register as the first tenant
    /// when the control database has none — the POSMAIN that existed before
    /// tenancy. Blank to skip.
    /// </summary>
    public string AdoptDatabase { get; init; } = "POSMAIN";

    /// <summary>Folder of tenant migrations; blank finds db-migrations/ beside the app.</summary>
    public string? TenantMigrationsPath { get; init; }

    /// <summary>Folder of control migrations; blank finds db-control/ beside the app.</summary>
    public string? ControlMigrationsPath { get; init; }

    /// <summary>Bring every tenant database up to date in the background at startup.</summary>
    public bool MigrateTenantsOnStartup { get; init; } = true;

    /// <summary>How often tenant figures are collected for the console.</summary>
    public int SnapshotMinutes { get; init; } = 15;

    /// <summary>How long tenant status is cached before the control database is asked again.</summary>
    public int CatalogCacheSeconds { get; init; } = 30;
}

/// <summary>
/// Builds every connection string from configuration, once.
///
/// ConnectionStrings:Control and ConnectionStrings:TenantServer may be set
/// explicitly. When they are not, both are derived from ConnectionStrings:PosMain
/// — the same server with a different catalog — so an existing deployment
/// keeps working without a configuration change.
/// </summary>
public sealed class TenancyConnections
{
    private readonly string _server;

    public TenancyConnections(IConfiguration configuration, IOptions<TenancyOptions> options)
    {
        var tenancy = options.Value;

        var baseline = configuration.GetConnectionString("TenantServer")
                       ?? configuration.GetConnectionString("PosMain")
                       ?? throw new InvalidOperationException(
                           "Set ConnectionStrings:TenantServer (or PosMain): the SQL Server that holds the tenant databases.");

        _server = new SqlConnectionStringBuilder(baseline) { InitialCatalog = "master" }.ConnectionString;

        Control = configuration.GetConnectionString("Control")
                  ?? new SqlConnectionStringBuilder(baseline)
                  {
                      InitialCatalog = tenancy.ControlDatabase,
                      ApplicationName = "NazadPosControl"
                  }.ConnectionString;

        ControlDatabase = new SqlConnectionStringBuilder(Control).InitialCatalog;
        ControlServer = new SqlConnectionStringBuilder(Control) { InitialCatalog = "master" }.ConnectionString;
    }

    /// <summary>The control database.</summary>
    public string Control { get; }

    public string ControlDatabase { get; }

    /// <summary>The control database's server, connected to master (to create it).</summary>
    public string ControlServer { get; }

    /// <summary>The tenant server, connected to master (to create tenant databases).</summary>
    public string TenantServer => _server;

    /// <summary>A tenant's own database.</summary>
    public string ForTenant(string databaseName) =>
        new SqlConnectionStringBuilder(_server)
        {
            InitialCatalog = databaseName,
            ApplicationName = "NazadPosApi"
        }.ConnectionString;
}
