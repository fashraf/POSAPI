using System.Diagnostics;
using Dapper;
using PosApi.Tenancy;

namespace PosApi.Features.SuperAdmin;

/// <summary>An audit row as the console shows it.</summary>
public sealed record AuditRowDto
{
    public required string Id { get; init; }
    public DateTime At { get; init; }
    public string? Admin { get; init; }
    public required string Action { get; init; }
    public required string Label { get; init; }
    public string? Entity { get; init; }
    public string? ClientId { get; init; }
    public string? ClientName { get; init; }
    public string? Before { get; init; }
    public string? After { get; init; }
    public string? Reason { get; init; }
    public string? Method { get; init; }
    public string? Endpoint { get; init; }
    public string? Table { get; init; }
    public string? Operation { get; init; }
    public int? DurationMs { get; init; }
    public int? RowsAffected { get; init; }
    public string? Ip { get; init; }
    public required string Result { get; init; }
    public string? Error { get; init; }
}

/// <summary>
/// Records what an administrator did, in the control database, and hands the
/// row back.
///
/// Every console write returns the audit row it produced, so the screen can
/// say "recorded as AUD-5123" — a reference that finds the record later
/// without searching by time and hoping.
/// </summary>
public sealed class AdminAuditor
{
    private readonly TenantCatalog _catalog;
    private readonly CurrentAdmin _admin;
    private readonly IHttpContextAccessor _http;
    private readonly Stopwatch _watch = Stopwatch.StartNew();

    public AdminAuditor(TenantCatalog catalog, CurrentAdmin admin, IHttpContextAccessor http)
    {
        _catalog = catalog;
        _admin = admin;
        _http = http;
    }

    public async Task<AuditRowDto> RecordAsync(
        string action, string label, string? tenantId = null, string? entityId = null,
        string? before = null, string? after = null, string? reason = null,
        string? table = null, string operation = "UPDATE", int rowsAffected = 1,
        string? error = null, CancellationToken ct = default)
    {
        var request = _http.HttpContext?.Request;

        await using var control = _catalog.Control();

        var id = await control.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            INSERT INTO ctl.AdminAudit
                (AdminId, AdminName, Action, Label, TenantId, EntityId, BeforeValue, AfterValue, Reason,
                 Method, Endpoint, TableName, Operation, DurationMs, RowsAffected, IpAddress, Result, ErrorMessage)
            OUTPUT INSERTED.AuditId
            VALUES
                (@AdminId, @AdminName, @Action, @Label, @TenantId, @EntityId, @Before, @After, @Reason,
                 @Method, @Endpoint, @Table, @Operation, @DurationMs, @RowsAffected, @Ip, @Result, @Error);
            """,
            new
            {
                AdminId = Blank(_admin.AdminId), AdminName = Blank(_admin.Name), Action = action, Label = label,
                TenantId = tenantId, EntityId = entityId, Before = Cut(before), After = Cut(after), Reason = Cut(reason),
                Method = request?.Method, Endpoint = request?.Path.Value, Table = table, Operation = operation,
                DurationMs = (int)_watch.ElapsedMilliseconds, RowsAffected = rowsAffected,
                Ip = _http.HttpContext?.Connection.RemoteIpAddress?.ToString(),
                Result = error is null ? "success" : "failed", Error = error
            }, cancellationToken: ct));

        return (await ListAsync(control, null, id, 1, ct)).Single();
    }

    /// <summary>The result every console write returns.</summary>
    public async Task<object> ResultAsync(
        string action, string label, string? tenantId = null, string? entityId = null,
        string? before = null, string? after = null, string? reason = null,
        string? table = null, string operation = "UPDATE", int rowsAffected = 1,
        object? data = null, CancellationToken ct = default)
    {
        var audit = await RecordAsync(action, label, tenantId, entityId, before, after, reason,
                                      table, operation, rowsAffected, null, ct);
        return new { ok = true, audit, data };
    }

    public static async Task<IReadOnlyList<AuditRowDto>> ListAsync(
        System.Data.Common.DbConnection control, string? tenantId, long? auditId, int take, CancellationToken ct)
    {
        var rows = await control.QueryAsync<AuditRowDto>(new CommandDefinition(
            """
            SELECT TOP (@Take)
                   CONCAT(N'AUD-', a.AuditId) AS Id, a.AtUtc AS [At], a.AdminName AS Admin, a.Action, a.Label,
                   LEFT(a.Action, CHARINDEX(N'.', a.Action + N'.') - 1) AS Entity,
                   a.TenantId AS ClientId, t.Name AS ClientName, a.BeforeValue AS [Before], a.AfterValue AS [After],
                   a.Reason, a.Method, a.Endpoint, a.TableName AS [Table], a.Operation, a.DurationMs,
                   a.RowsAffected, a.IpAddress AS Ip, a.Result, a.ErrorMessage AS Error
            FROM ctl.AdminAudit AS a
            LEFT JOIN ctl.Tenant AS t ON t.TenantId = a.TenantId
            WHERE (@TenantId IS NULL OR a.TenantId = @TenantId)
              AND (@AuditId IS NULL OR a.AuditId = @AuditId)
            ORDER BY a.AuditId DESC;
            """, new { Take = take, TenantId = tenantId, AuditId = auditId }, cancellationToken: ct));

        return rows.ToList();
    }

    private static string? Blank(string value) => string.IsNullOrWhiteSpace(value) ? null : value;

    private static string? Cut(string? value) => value is { Length: > 400 } ? value[..400] : value;
}
