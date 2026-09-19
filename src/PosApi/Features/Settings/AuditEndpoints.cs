using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Settings;

public static class AuditEndpoints
{
    public static void MapAuditEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/audit")
            .WithTags("Audit")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("audit.view"));

        group.MapGet("/{auditId:long}", GetAsync)
             .RequireAuthorization(PermissionPolicy.For("audit.view"));

        group.MapGet("/filters", FiltersAsync)
             .RequireAuthorization(PermissionPolicy.For("audit.view"));

        group.MapGet("/performance", PerformanceAsync)
             .RequireAuthorization(PermissionPolicy.For("audit.performance"));

        group.MapGet("/performance/slow", SlowAsync)
             .RequireAuthorization(PermissionPolicy.For("audit.performance"));

        group.MapGet("/performance/nplusone", NPlusOneAsync)
             .RequireAuthorization(PermissionPolicy.For("audit.performance"));
    }

    /// <summary>
    /// The audit trail, filtered.
    ///
    /// There is no write endpoint on purpose. Entries are produced by the
    /// middleware from what actually happened; an API that let a caller post its
    /// own audit rows would make the trail worth nothing as evidence.
    /// </summary>
    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db,
        string? userId, string? action, string? module, string? entityId,
        string? result, string? search, DateOnly? from, DateOnly? to,
        int page = 1, int pageSize = 25, CancellationToken ct = default)
    {
        var paging = new PageQuery { Page = page <= 0 ? 1 : page, PageSize = pageSize };

        await using var connection = db.Create();

        const string sql = """
            SELECT COUNT(*)
            FROM audit.AuditEntry AS a
            WHERE (@UserId   IS NULL OR a.UserId = @UserId)
              AND (@Action   IS NULL OR a.Action = @Action)
              AND (@Module   IS NULL OR a.Module = @Module)
              AND (@EntityId IS NULL OR a.EntityId = @EntityId)
              AND (@Result   IS NULL OR a.Result = @Result)
              AND (@From IS NULL OR CAST(a.OccurredAtUtc AS DATE) >= @From)
              AND (@To   IS NULL OR CAST(a.OccurredAtUtc AS DATE) <= @To)
              AND (@Search IS NULL
                   OR a.Username    LIKE N'%' + @Search + N'%'
                   OR a.ApiPath     LIKE N'%' + @Search + N'%'
                   OR a.EntityId    LIKE N'%' + @Search + N'%'
                   OR a.CurrentPage LIKE N'%' + @Search + N'%');

            SELECT a.AuditId, a.UserId, a.Username, a.RoleId, a.Action, a.Module,
                   a.EntityType, a.EntityId, a.ApiPath, a.HttpMethod,
                   a.CurrentPage, a.PreviousPage, a.BranchId,
                   a.Result, a.StatusCode, a.ErrorMessage,
                   a.IpAddress, a.CorrelationId, a.OccurredAtUtc,
                   /* The payloads can be large, so the list carries only whether
                      they exist. The detail endpoint returns them in full. */
                   CASE WHEN a.OldValue IS NOT NULL THEN 1 ELSE 0 END AS HasOldValue,
                   CASE WHEN a.NewValue IS NOT NULL THEN 1 ELSE 0 END AS HasNewValue
            FROM audit.AuditEntry AS a
            WHERE (@UserId   IS NULL OR a.UserId = @UserId)
              AND (@Action   IS NULL OR a.Action = @Action)
              AND (@Module   IS NULL OR a.Module = @Module)
              AND (@EntityId IS NULL OR a.EntityId = @EntityId)
              AND (@Result   IS NULL OR a.Result = @Result)
              AND (@From IS NULL OR CAST(a.OccurredAtUtc AS DATE) >= @From)
              AND (@To   IS NULL OR CAST(a.OccurredAtUtc AS DATE) <= @To)
              AND (@Search IS NULL
                   OR a.Username    LIKE N'%' + @Search + N'%'
                   OR a.ApiPath     LIKE N'%' + @Search + N'%'
                   OR a.EntityId    LIKE N'%' + @Search + N'%'
                   OR a.CurrentPage LIKE N'%' + @Search + N'%')
            ORDER BY a.OccurredAtUtc DESC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(sql,
            new
            {
                UserId = userId, Action = action, Module = module, EntityId = entityId,
                Result = result, From = from, To = to,
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                paging.Offset, paging.PageSize
            },
            cancellationToken: ct));

        var total = await multi.ReadSingleAsync<int>();
        var rows = (await multi.ReadAsync()).ToList();

        return Results.Ok(new PagedResult<object>
        {
            Items = rows.Cast<object>().ToList(),
            Page = paging.Page,
            PageSize = paging.PageSize,
            TotalCount = total
        });
    }

    private static async Task<IResult> GetAsync(
        long auditId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var entry = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            "SELECT * FROM audit.AuditEntry WHERE AuditId = @AuditId;",
            new { AuditId = auditId }, cancellationToken: ct));

        return entry is null ? Results.NotFound() : Results.Ok(entry);
    }

    /// <summary>The distinct values behind each filter, so the page can offer them.</summary>
    private static async Task<IResult> FiltersAsync(ISqlConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT DISTINCT Action FROM audit.AuditEntry ORDER BY Action;
            SELECT DISTINCT Module FROM audit.AuditEntry ORDER BY Module;
            SELECT DISTINCT UserId, Username FROM audit.AuditEntry
            WHERE UserId IS NOT NULL ORDER BY Username;
            """, cancellationToken: ct));

        return Results.Ok(new
        {
            actions = (await multi.ReadAsync<string>()).ToList(),
            modules = (await multi.ReadAsync<string>()).ToList(),
            users = (await multi.ReadAsync()).ToList()
        });
    }

    private static async Task<IResult> PerformanceAsync(
        ISqlConnectionFactory db, DateOnly? from, DateOnly? to, CancellationToken ct)
    {
        await using var connection = db.Create();

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT * FROM audit.vw_EndpointPerformance ORDER BY AvgMs DESC;

            SELECT
                COUNT(*)      AS TotalCalls,
                AVG(TotalMs)  AS AvgMs,
                MAX(TotalMs)  AS WorstMs,
                SUM(CASE WHEN Succeeded = 0 THEN 1 ELSE 0 END) AS Failures,
                SUM(CASE WHEN TotalMs >= 2000 THEN 1 ELSE 0 END) AS CriticalCalls,
                SUM(CASE WHEN TotalMs >= 1000 AND TotalMs < 2000 THEN 1 ELSE 0 END) AS SlowCalls
            FROM audit.RequestTiming
            WHERE (@From IS NULL OR CAST(OccurredAtUtc AS DATE) >= @From)
              AND (@To   IS NULL OR CAST(OccurredAtUtc AS DATE) <= @To);
            """,
            new { From = from, To = to }, cancellationToken: ct));

        var endpoints = (await multi.ReadAsync()).ToList();
        var summary = await multi.ReadSingleAsync();

        return Results.Ok(new { endpoints, summary });
    }

    /// <summary>The slowest individual requests, with the statements they ran.</summary>
    private static async Task<IResult> SlowAsync(
        ISqlConnectionFactory db, int thresholdMs = 300, int take = 50, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT TOP (@Take)
                r.CorrelationId, r.Username, r.ApiPath, r.HttpMethod,
                r.CurrentPage, r.PreviousPage,
                r.TotalMs, r.DatabaseMs, r.QueryCount,
                /* Seconds are derived, never stored — two columns holding the
                   same measurement drift apart. */
                CAST(r.TotalMs    / 1000.0 AS DECIMAL(10,3)) AS TotalSeconds,
                CAST(r.DatabaseMs / 1000.0 AS DECIMAL(10,3)) AS DatabaseSeconds,
                r.StatusCode, r.Succeeded, r.ErrorMessage, r.OccurredAtUtc
            FROM audit.RequestTiming AS r
            WHERE r.TotalMs >= @Threshold
            ORDER BY r.TotalMs DESC;

            SELECT TOP (@Take)
                q.CorrelationId, q.QueryType, q.CommandText, q.ParameterNames,
                q.DurationMs,
                CAST(q.DurationMs / 1000.0 AS DECIMAL(10,3)) AS DurationSeconds,
                q.RowsAffected, q.OccurredAtUtc
            FROM audit.QueryTiming AS q
            ORDER BY q.DurationMs DESC;
            """,
            new
            {
                Threshold = thresholdMs <= 0 ? 300 : thresholdMs,
                Take = take <= 0 ? 50 : Math.Min(take, 200)
            },
            cancellationToken: ct));

        var requests = (await multi.ReadAsync()).ToList();
        var queries = (await multi.ReadAsync()).ToList();

        return Results.Ok(new { requests, queries });
    }

    private static async Task<IResult> NPlusOneAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            "SELECT TOP (100) * FROM audit.vw_SuspectedNPlusOne ORDER BY Executions DESC;",
            cancellationToken: ct));

        return Results.Ok(rows);
    }
}
