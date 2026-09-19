using System.Data;
using Microsoft.Data.SqlClient;

namespace PosApi.Data;

public interface ISqlConnectionFactory
{
    SqlConnection Create();
    Task<SqlConnection> CreateOpenAsync(CancellationToken ct);
}

/// <summary>
/// Hands out connections to POSMAIN.
///
/// Dapper rather than an ORM: the schema already enforces the rules that matter
/// through constraints and stored procedures, and an ORM that generates its own
/// SQL would route around them. Every query here is parameterised — string
/// concatenation into SQL is how injection happens, and there is no case in
/// this codebase where it is warranted.
/// </summary>
public sealed class SqlConnectionFactory : ISqlConnectionFactory
{
    private readonly string _connectionString;

    public SqlConnectionFactory(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("PosMain")
            ?? throw new InvalidOperationException(
                "Connection string 'PosMain' is missing. Set it in appsettings.json or the environment.");
    }

    public SqlConnection Create() => new(_connectionString);

    public async Task<SqlConnection> CreateOpenAsync(CancellationToken ct)
    {
        var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(ct);
        return connection;
    }
}
