using System.Collections;
using System.Collections.Concurrent;
using System.Data;
using System.Dynamic;
using System.Text.RegularExpressions;
using Dapper;

namespace PosApi.Data;

/// <summary>
/// Untyped rows with their column names as they are written.
///
/// PostgreSQL folds unquoted names to lower case, so a query written
/// SELECT SalesH ... returns a column called salesh. Typed queries do not care
/// — Dapper matches properties ignoring case — but an untyped row is sent to
/// the client as it is, and the JSON key would be salesh instead of salesH. A
/// dynamic row is also looked up case-sensitively, so row.SalesH would read
/// null.
///
/// Every name the SQL uses is written in PascalCase somewhere: in the query
/// itself, or in the migration files for SELECT * from a table or view. The
/// names are collected from both, and each lower-case column gets its written
/// name back.
/// </summary>
public static partial class DbRows
{
    private static readonly ConcurrentDictionary<string, string> Names = new(StringComparer.Ordinal);

    [GeneratedRegex(@"\b[A-Za-z_][A-Za-z0-9_]*\b")]
    private static partial Regex Identifier();

    /// <summary>Learn every name written in the migration files (done once at startup).</summary>
    public static void LearnFolder(string folder)
    {
        if (!Directory.Exists(folder)) return;
        foreach (var file in Directory.GetFiles(folder, "*.sql"))
            Learn(File.ReadAllText(file));
    }

    /// <summary>Learn the names a piece of SQL writes. The first spelling seen wins.</summary>
    public static void Learn(string sql)
    {
        foreach (Match m in Identifier().Matches(sql))
        {
            var name = m.Value;
            if (name.Any(char.IsUpper)) Names.TryAdd(name.ToLowerInvariant(), name);
        }
    }

    public static string NameOf(string column) =>
        Names.TryGetValue(column, out var name) ? name : column;

    private static DbRow Restore(object row) => new((IDictionary<string, object?>)row);

    /*----------------------------------------------------- connection helpers */

    public static async Task<List<dynamic>> QueryRowsAsync(this IDbConnection connection, CommandDefinition command)
    {
        Learn(command.CommandText);
        return (await connection.QueryAsync(command)).Select(r => (dynamic)Restore(r)).ToList();
    }

    public static async Task<dynamic?> QuerySingleRowOrDefaultAsync(this IDbConnection connection, CommandDefinition command)
    {
        Learn(command.CommandText);
        var row = await connection.QuerySingleOrDefaultAsync(command);
        return row is null ? null : Restore(row);
    }

    public static async Task<dynamic> QuerySingleRowAsync(this IDbConnection connection, CommandDefinition command)
    {
        Learn(command.CommandText);
        return Restore(await connection.QuerySingleAsync(command));
    }

    public static async Task<dynamic?> QueryFirstRowOrDefaultAsync(this IDbConnection connection, CommandDefinition command)
    {
        Learn(command.CommandText);
        var row = await connection.QueryFirstOrDefaultAsync(command);
        return row is null ? null : Restore(row);
    }

    /// <summary>QueryMultipleAsync, learning the batch's names for the untyped reads that follow.</summary>
    public static Task<SqlMapper.GridReader> QueryMultipleNamedAsync(this IDbConnection connection, CommandDefinition command)
    {
        Learn(command.CommandText);
        return connection.QueryMultipleAsync(command);
    }

    public static async Task<List<dynamic>> ReadRowsAsync(this SqlMapper.GridReader reader) =>
        (await reader.ReadAsync()).Select(r => (dynamic)Restore(r)).ToList();

    public static async Task<dynamic> ReadSingleRowAsync(this SqlMapper.GridReader reader) =>
        Restore(await reader.ReadSingleAsync());

    public static async Task<dynamic?> ReadSingleRowOrDefaultAsync(this SqlMapper.GridReader reader)
    {
        var row = await reader.ReadSingleOrDefaultAsync();
        return row is null ? null : Restore(row);
    }

    public static async Task<dynamic?> ReadFirstRowOrDefaultAsync(this SqlMapper.GridReader reader)
    {
        var row = await reader.ReadFirstOrDefaultAsync();
        return row is null ? null : Restore(row);
    }
}

/// <summary>
/// One row: a dictionary keyed by the written column names (so it serializes
/// as before), readable as a dynamic object ignoring case (so row.SalesH works).
/// </summary>
public sealed class DbRow : DynamicObject, IDictionary<string, object?>
{
    private readonly Dictionary<string, object?> _values = new(StringComparer.OrdinalIgnoreCase);

    public DbRow(IDictionary<string, object?> source)
    {
        foreach (var (key, value) in source)
            _values[DbRows.NameOf(key)] = value;
    }

    public override bool TryGetMember(GetMemberBinder binder, out object? result) =>
        _values.TryGetValue(binder.Name, out result);

    public override bool TrySetMember(SetMemberBinder binder, object? value)
    {
        _values[binder.Name] = value;
        return true;
    }

    public override IEnumerable<string> GetDynamicMemberNames() => _values.Keys;

    public object? this[string key] { get => _values[key]; set => _values[key] = value; }
    public ICollection<string> Keys => _values.Keys;
    public ICollection<object?> Values => _values.Values;
    public int Count => _values.Count;
    public bool IsReadOnly => false;
    public void Add(string key, object? value) => _values.Add(key, value);
    public void Add(KeyValuePair<string, object?> item) => _values.Add(item.Key, item.Value);
    public void Clear() => _values.Clear();
    public bool Contains(KeyValuePair<string, object?> item) => ((ICollection<KeyValuePair<string, object?>>)_values).Contains(item);
    public bool ContainsKey(string key) => _values.ContainsKey(key);
    public void CopyTo(KeyValuePair<string, object?>[] array, int arrayIndex) => ((ICollection<KeyValuePair<string, object?>>)_values).CopyTo(array, arrayIndex);
    public IEnumerator<KeyValuePair<string, object?>> GetEnumerator() => _values.GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => _values.GetEnumerator();
    public bool Remove(string key) => _values.Remove(key);
    public bool Remove(KeyValuePair<string, object?> item) => ((ICollection<KeyValuePair<string, object?>>)_values).Remove(item);
    public bool TryGetValue(string key, out object? value) => _values.TryGetValue(key, out value);
}
