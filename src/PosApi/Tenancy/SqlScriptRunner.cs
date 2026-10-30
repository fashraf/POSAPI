using System.Collections.Concurrent;
using System.Text;
using System.Text.RegularExpressions;
using Dapper;
using Npgsql;

namespace PosApi.Tenancy;

/// <summary>
/// Applies numbered .sql files to a database, once each — the in-process twin
/// of apply-migrations.sh.
///
/// Same files, same dbo.SchemaMigration tracking table, so a database built by
/// the script can be updated here and the other way round. The database is
/// created when it does not exist yet; the files themselves never name it,
/// which is how one set of files builds every tenant.
///
/// Each file runs in a transaction of its own, recorded in the same
/// transaction. PostgreSQL rolls DDL back like anything else, so a file that
/// fails half-way leaves the database exactly as it was before the file.
/// </summary>
public sealed partial class SqlScriptRunner
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Locks = new(StringComparer.OrdinalIgnoreCase);

    private readonly ILogger<SqlScriptRunner> _logger;

    public SqlScriptRunner(ILogger<SqlScriptRunner> logger) => _logger = logger;

    [GeneratedRegex(@"^\d{3}-.+\.sql$", RegexOptions.IgnoreCase)]
    private static partial Regex MigrationName();

    /// <summary>
    /// Migration files in a folder, in name order, between two numbers.
    /// Tenants take 001–899 (900+ are demo data and the read-only check).
    /// </summary>
    public static IReadOnlyList<string> Files(string folder, int from = 1, int to = 899) =>
        Directory.Exists(folder)
            ? Directory.GetFiles(folder, "*.sql")
                .Where(f => MigrationName().IsMatch(Path.GetFileName(f)))
                .Where(f => int.Parse(Path.GetFileName(f)[..3]) is var n && n >= from && n <= to)
                .OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal)
                .ToList()
            : [];

    /// <summary>Whether a database of that name exists on the server.</summary>
    public static async Task<bool> ExistsAsync(string serverConnection, string database, CancellationToken ct)
    {
        await using var connection = new NpgsqlConnection(serverConnection);
        return await connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT 1 FROM pg_database WHERE datname = @Database;",
            new { Database = database.ToLowerInvariant() }, cancellationToken: ct)) is not null;
    }

    /// <summary>Which of the files a database has already run (empty when it does not exist).</summary>
    public async Task<HashSet<string>> AppliedAsync(string serverConnection, string database, CancellationToken ct)
    {
        var applied = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!await ExistsAsync(serverConnection, database, ct)) return applied;

        await using var connection = new NpgsqlConnection(On(serverConnection, database));

        if (await connection.ExecuteScalarAsync<string?>(new CommandDefinition(
                "SELECT to_regclass('dbo.schemamigration')::text;", cancellationToken: ct)) is null)
            return applied;

        applied.UnionWith(await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT FileName FROM dbo.SchemaMigration;", cancellationToken: ct)));

        return applied;
    }

    /// <summary>
    /// Create the database if it is missing, then run every file it has not
    /// run. Returns the names applied. Stops at the first failure: later files
    /// may depend on it.
    /// </summary>
    public async Task<IReadOnlyList<string>> ApplyAsync(
        string serverConnection,
        string database,
        IReadOnlyList<string> files,
        CancellationToken ct)
    {
        database = database.ToLowerInvariant();

        if (!IsSafeName(database))
            throw new InvalidOperationException($"'{database}' is not a valid database name.");

        var gate = Locks.GetOrAdd(database, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(ct);

        try
        {
            await CreateIfMissingAsync(serverConnection, database, ct);

            var applied = await AppliedAsync(serverConnection, database, ct);
            var ran = new List<string>();

            foreach (var file in files)
            {
                var name = Path.GetFileName(file);
                if (applied.Contains(name)) continue;

                _logger.LogInformation("Applying {File} to {Database}...", name, database);

                var sql = await File.ReadAllTextAsync(file, Encoding.UTF8, ct);

                await using var connection = new NpgsqlConnection(On(serverConnection, database));
                await connection.OpenAsync(ct);
                await using var tx = await connection.BeginTransactionAsync(ct);

                /* No parameters: the file goes to the server as written, $$-quoted
                   function bodies and all. */
                await using (var command = new NpgsqlCommand(sql, connection, tx) { CommandTimeout = 600 })
                    await command.ExecuteNonQueryAsync(ct);

                await RecordAsync(connection, tx, name, ct);
                await tx.CommitAsync(ct);

                ran.Add(name);
            }

            return ran;
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Drop a database, closing any connection still open to it.</summary>
    public static async Task DropAsync(string serverConnection, string database, CancellationToken ct)
    {
        database = database.ToLowerInvariant();
        if (!IsSafeName(database))
            throw new InvalidOperationException($"'{database}' is not a valid database name.");

        NpgsqlConnection.ClearAllPools();

        await using var connection = new NpgsqlConnection(serverConnection);
        await connection.ExecuteAsync(new CommandDefinition(
            $"DROP DATABASE IF EXISTS {database} WITH (FORCE);", cancellationToken: ct));
    }

    private static async Task CreateIfMissingAsync(string serverConnection, string database, CancellationToken ct)
    {
        if (await ExistsAsync(serverConnection, database, ct)) return;

        await using var connection = new NpgsqlConnection(serverConnection);

        try
        {
            /* UTF-8 explicitly: Arabic must survive whatever the server's
               default encoding is. CREATE DATABASE takes no parameters, so the
               name is spliced — IsSafeName has already checked it. */
            await connection.ExecuteAsync(new CommandDefinition(
                $"CREATE DATABASE {database} ENCODING 'UTF8' TEMPLATE template0;", cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.SqlState == PostgresErrorCodes.DuplicateDatabase)
        {
            /* Another instance created it between the check and here. */
        }
    }

    private static async Task RecordAsync(NpgsqlConnection connection, NpgsqlTransaction tx, string file, CancellationToken ct)
    {
        await connection.ExecuteAsync(new CommandDefinition(
            """
            CREATE SCHEMA IF NOT EXISTS dbo;

            CREATE TABLE IF NOT EXISTS dbo.SchemaMigration (
                FileName     varchar(200) NOT NULL PRIMARY KEY,
                AppliedAtUtc timestamp(3) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
                AppliedBy    varchar(128) NOT NULL DEFAULT current_user);

            INSERT INTO dbo.SchemaMigration (FileName) VALUES (@File)
            ON CONFLICT (FileName) DO NOTHING;
            """, new { File = file }, tx, cancellationToken: ct));
    }

    /// <summary>The same server, another database.</summary>
    private static string On(string serverConnection, string database) =>
        new NpgsqlConnectionStringBuilder(serverConnection) { Database = database.ToLowerInvariant() }.ConnectionString;

    /// <summary>Letters, digits and underscore, starting with a letter: safe to splice as an identifier.</summary>
    public static bool IsSafeName(string name) => SafeName().IsMatch(name);

    [GeneratedRegex(@"^[A-Za-z][A-Za-z0-9_]{0,62}$")]
    private static partial Regex SafeName();

    /// <summary>Find a folder beside the app: published (content root) or in the repository.</summary>
    public static string ResolveFolder(string? configured, string name, IWebHostEnvironment environment)
    {
        if (!string.IsNullOrWhiteSpace(configured))
            return Path.GetFullPath(configured, environment.ContentRootPath);

        var candidates = new[]
        {
            Path.Combine(environment.ContentRootPath, name),
            Path.Combine(environment.ContentRootPath, "..", "..", name),
            Path.Combine(AppContext.BaseDirectory, name),
        };

        return candidates.Select(Path.GetFullPath).FirstOrDefault(Directory.Exists)
               ?? Path.GetFullPath(candidates[0]);
    }
}
