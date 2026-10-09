using System.Collections.Concurrent;
using System.Text;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace PosApi.Tenancy;

/// <summary>
/// Applies numbered .sql files to a database, once each — the in-process twin
/// of apply-migrations.sh.
///
/// Same files, same dbo.SchemaMigration tracking table, so a database built by
/// the script can be updated here and the other way round. The files name their
/// database (USE POSMAIN / USE POSCONTROL); that name is replaced with the
/// target's, which is how one set of files builds every tenant.
/// </summary>
public sealed partial class SqlScriptRunner
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Locks = new(StringComparer.OrdinalIgnoreCase);

    private readonly ILogger<SqlScriptRunner> _logger;

    public SqlScriptRunner(ILogger<SqlScriptRunner> logger) => _logger = logger;

    [GeneratedRegex(@"^\s*GO\s*(?:--.*)?$", RegexOptions.Multiline | RegexOptions.IgnoreCase)]
    private static partial Regex GoSeparator();

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

    /// <summary>Which of the files a database has already run (empty when it does not exist).</summary>
    public async Task<HashSet<string>> AppliedAsync(string serverConnection, string database, CancellationToken ct)
    {
        await using var connection = new SqlConnection(serverConnection);
        await connection.OpenAsync(ct);

        var exists = await connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT 1 WHERE DB_ID(@Database) IS NOT NULL;", new { Database = database }, cancellationToken: ct));

        if (exists is null) return new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var rows = await connection.QueryAsync<string>(new CommandDefinition(
            $"""
            IF OBJECT_ID(N'{Quote(database)}.dbo.SchemaMigration') IS NOT NULL
                SELECT FileName FROM {Quote(database)}.dbo.SchemaMigration;
            """, cancellationToken: ct));

        return rows.ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Run every file the database has not run. Returns the names applied.
    /// Stops at the first failure: later files may depend on it.
    /// </summary>
    public async Task<IReadOnlyList<string>> ApplyAsync(
        string serverConnection,
        string database,
        string placeholder,
        IReadOnlyList<string> files,
        CancellationToken ct)
    {
        if (!IsSafeName(database))
            throw new InvalidOperationException($"'{database}' is not a valid database name.");

        var gate = Locks.GetOrAdd(database, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(ct);

        try
        {
            var applied = await AppliedAsync(serverConnection, database, ct);
            var ran = new List<string>();

            foreach (var file in files)
            {
                var name = Path.GetFileName(file);
                if (applied.Contains(name)) continue;

                _logger.LogInformation("Applying {File} to {Database}...", name, database);

                var sql = Regex.Replace(
                    await File.ReadAllTextAsync(file, Encoding.UTF8, ct),
                    $@"\b{Regex.Escape(placeholder)}\b", database, RegexOptions.IgnoreCase);

                await using (var connection = new SqlConnection(serverConnection))
                {
                    await connection.OpenAsync(ct);

                    foreach (var batch in GoSeparator().Split(sql))
                    {
                        if (string.IsNullOrWhiteSpace(batch)) continue;

                        await using var command = new SqlCommand(batch, connection) { CommandTimeout = 600 };
                        await command.ExecuteNonQueryAsync(ct);
                    }
                }

                await RecordAsync(serverConnection, database, name, ct);
                ran.Add(name);
            }

            return ran;
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Take over a database built before tracking existed (apply-migrations --adopt):
    /// record the baseline files as applied without running them. Later files
    /// are written to be safe to run twice, so they simply run.
    /// Returns false when the database has no POS schema at all.
    /// </summary>
    public async Task<bool> BaselineAsync(string serverConnection, string database, IEnumerable<string> files, CancellationToken ct)
    {
        await using var connection = new SqlConnection(serverConnection);
        await connection.OpenAsync(ct);

        var hasSchema = await connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            $"SELECT 1 WHERE DB_ID(@Database) IS NOT NULL AND EXISTS (SELECT 1 FROM {Quote(database)}.sys.schemas WHERE name = N'core');",
            new { Database = database }, cancellationToken: ct));

        if (hasSchema is null) return false;

        foreach (var file in files)
            await RecordAsync(serverConnection, database, Path.GetFileName(file), ct);

        return true;
    }

    private static async Task RecordAsync(string serverConnection, string database, string file, CancellationToken ct)
    {
        await using var connection = new SqlConnection(serverConnection);
        await connection.OpenAsync(ct);
        connection.ChangeDatabase(database);

        await connection.ExecuteAsync(new CommandDefinition(
            """
            IF OBJECT_ID(N'dbo.SchemaMigration') IS NULL
                CREATE TABLE dbo.SchemaMigration (
                    FileName NVARCHAR(200) NOT NULL CONSTRAINT PK_SchemaMigration PRIMARY KEY,
                    AppliedAtUtc DATETIME2(3) NOT NULL CONSTRAINT DF_SchemaMigration_At DEFAULT SYSUTCDATETIME(),
                    AppliedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_SchemaMigration_By DEFAULT SUSER_SNAME(),
                    Baselined BIT NOT NULL CONSTRAINT DF_SchemaMigration_Baselined DEFAULT 0);

            IF NOT EXISTS (SELECT 1 FROM dbo.SchemaMigration WHERE FileName = @File)
                INSERT INTO dbo.SchemaMigration (FileName) VALUES (@File);
            """, new { File = file }, cancellationToken: ct));
    }

    /// <summary>Letters, digits and underscore, starting with a letter: safe to splice as an identifier.</summary>
    public static bool IsSafeName(string name) => SafeName().IsMatch(name);

    [GeneratedRegex(@"^[A-Za-z][A-Za-z0-9_]{0,99}$")]
    private static partial Regex SafeName();

    private static string Quote(string name) => $"[{name.Replace("]", "]]")}]";

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
