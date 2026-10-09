using Microsoft.Data.SqlClient;
using PosApi.Tenancy;

namespace PosApi.Data;

public interface ISqlConnectionFactory
{
    SqlConnection Create();
    Task<SqlConnection> CreateOpenAsync(CancellationToken ct);
}

/// <summary>
/// Hands out connections to the current tenant's own database.
///
/// Scoped to the request: the tenant comes from ITenantContext, set from the
/// token (TenantMiddleware) or by an anonymous endpoint once it knows the
/// tenant. There is no default database — a request that never resolved a
/// tenant gets an exception rather than somebody else's data.
///
/// Dapper rather than an ORM: the schema already enforces the rules that matter
/// through constraints and stored procedures, and an ORM that generates its own
/// SQL would route around them. Every query here is parameterised — string
/// concatenation into SQL is how injection happens, and there is no case in
/// this codebase where it is warranted.
/// </summary>
public sealed class SqlConnectionFactory : ISqlConnectionFactory
{
    private readonly ITenantContext _tenant;

    public SqlConnectionFactory(ITenantContext tenant) => _tenant = tenant;

    public SqlConnection Create() => new(_tenant.ConnectionString);

    public async Task<SqlConnection> CreateOpenAsync(CancellationToken ct)
    {
        var connection = new SqlConnection(_tenant.ConnectionString);
        await connection.OpenAsync(ct);
        return connection;
    }
}
