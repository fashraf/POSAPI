using Npgsql;
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

    /// <summary>Name of the control database.</summary>
    public string ControlDatabase { get; init; } = "poscontrol";

    /// <summary>New tenant databases are named prefix + tenant number, e.g. pos_cl00002.</summary>
    public string TenantDatabasePrefix { get; init; } = "pos_";

    /// <summary>
    /// A database built by apply-migrations to register as the first tenant
    /// when the control database does not know it yet — posmain, the demo or
    /// single-business install. Blank to skip.
    /// </summary>
    public string AdoptDatabase { get; init; } = "posmain";

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
/// — the same server with a different database — so one setting is enough.
///
/// Database names are lower case throughout. PostgreSQL folds an unquoted name
/// to lower case when it creates a database, but matches the name in a
/// connection string exactly: POS_CL00002 would be created as pos_cl00002 and
/// then not found.
///
/// Every connection asks for two things the code relies on: the session time
/// zone is UTC, so a UTC DateTime parameter lands in a timestamp column
/// unchanged; and error details are included, because a database function's
/// refusal carries its number there (DbErrors).
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
                           "Set ConnectionStrings:TenantServer (or PosMain): the PostgreSQL server that holds the tenant databases.");

        _server = Build(baseline, "postgres", "NazadPosApi");

        Control = configuration.GetConnectionString("Control") is { } control
            ? Build(control, new NpgsqlConnectionStringBuilder(control).Database ?? tenancy.ControlDatabase, "NazadPosControl")
            : Build(baseline, tenancy.ControlDatabase, "NazadPosControl");

        ControlDatabase = new NpgsqlConnectionStringBuilder(Control).Database!;
        ControlServer = Build(Control, "postgres", "NazadPosControl");
    }

    /// <summary>The control database.</summary>
    public string Control { get; }

    public string ControlDatabase { get; }

    /// <summary>The control database's server, connected to the postgres database (to create it).</summary>
    public string ControlServer { get; }

    /// <summary>The tenant server, connected to the postgres database (to create tenant databases).</summary>
    public string TenantServer => _server;

    /// <summary>A tenant's own database.</summary>
    public string ForTenant(string databaseName) => Build(_server, databaseName, "NazadPosApi");

    private static string Build(string connection, string database, string application) =>
        new NpgsqlConnectionStringBuilder(connection)
        {
            Database = database.ToLowerInvariant(),
            ApplicationName = application,
            Timezone = "UTC",
            IncludeErrorDetail = true
        }.ConnectionString;
}
