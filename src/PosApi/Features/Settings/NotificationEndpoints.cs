using System.Data;
using Dapper;
using PosApi.Auth;
using PosApi.Data;

namespace PosApi.Features.Settings;

/// <summary>A notification as the bell reads it.</summary>
public sealed record NotificationDto(
    string NotificationId,
    string Kind,
    string Severity,
    string? BranchId,
    string TitleAr,
    string TitleEn,
    string? BodyAr,
    string? BodyEn,
    string? LinkPath,
    DateTime? ReadAtUtc,
    DateTime CreatedAtUtc);

public static class NotificationEndpoints
{
    /*
     * The refresh is cheap but not free, and the bell of every signed-in user
     * asks. Once every few seconds is fresh enough for "a sale just took this
     * item below its reorder level" and keeps a busy shop from running it on
     * every request.
     */
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromSeconds(15);
    private static long _lastRefreshTicks;

    public static void MapNotificationEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/notifications")
            .WithTags("Notifications")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync);
        group.MapPost("/{notificationId}/read", MarkReadAsync);
        group.MapPost("/read-all", MarkAllReadAsync);
    }

    /*
     * Who sees a row.
     *
     * Addressed to the caller, or to everyone (UserId NULL). Of the broadcast
     * ones, only those the caller can act on: a PermissionKey they hold (a
     * cashier is not told about overdue rent) and a branch they can see (the
     * Jeddah stock is not the Riyadh cashier's problem). Read state for a
     * broadcast row is per user, in core.NotificationRead.
     */
    private const string VisibleRows = """
        FROM core.Notification AS n
        LEFT JOIN core.NotificationRead AS r
               ON r.NotificationId = n.NotificationId AND r.UserId = @UserId
        WHERE n.ResolvedAtUtc IS NULL
          AND (n.UserId = @UserId
               OR (n.UserId IS NULL
                   AND (n.PermissionKey IS NULL
                        OR n.PermissionKey IN (SELECT value FROM STRING_SPLIT(@Permissions, N',')))
                   AND (n.BranchId IS NULL OR @AllBranches = 1
                        OR n.BranchId IN (SELECT value FROM STRING_SPLIT(@Branches, N',')))))
        """;

    private static object Scope(ICurrentUser current) => new
    {
        current.UserId,
        Permissions = string.Join(',', current.Permissions),
        Branches = string.Join(',', current.BranchIds),
        AllBranches = current.BranchIds.Count == 0
    };

    /// <summary>
    /// The caller's open notifications, newest first. Stock, recurring
    /// payments, credit limits and open drawers are brought up to date first
    /// (core.usp_RefreshNotifications), so what the bell shows is the state of
    /// the business now, not when someone last wrote a row.
    /// </summary>
    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, ICurrentUser current, ILogger<Program> logger,
        bool? unreadOnly, CancellationToken ct)
    {
        await using var connection = db.Create();

        await RefreshIfDueAsync(connection, logger, ct);

        var rows = await connection.QueryAsync<NotificationDto>(new CommandDefinition(
            $"""
            SELECT TOP (50)
                n.NotificationId, n.Kind, n.Severity, n.BranchId, n.TitleAr, n.TitleEn,
                n.BodyAr, n.BodyEn, n.LinkPath,
                CASE WHEN n.UserId IS NULL THEN r.ReadAtUtc ELSE n.ReadAtUtc END AS ReadAtUtc,
                n.CreatedAtUtc
            {VisibleRows}
              AND (@UnreadOnly = 0
                   OR (CASE WHEN n.UserId IS NULL THEN r.ReadAtUtc ELSE n.ReadAtUtc END) IS NULL)
            ORDER BY n.CreatedAtUtc DESC;
            """,
            new DynamicParameters(Scope(current)).With("UnreadOnly", unreadOnly ?? false),
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    /*
     * A failed refresh must not take the bell down with it: the stored rows
     * are still worth showing. It is logged and the list goes ahead.
     */
    private static async Task RefreshIfDueAsync(
        Microsoft.Data.SqlClient.SqlConnection connection, ILogger logger, CancellationToken ct)
    {
        var now = DateTime.UtcNow.Ticks;
        var last = Interlocked.Read(ref _lastRefreshTicks);

        if (now - last < RefreshInterval.Ticks) return;
        if (Interlocked.CompareExchange(ref _lastRefreshTicks, now, last) != last) return;

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_RefreshNotifications",
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Refreshing notifications failed; listing the stored ones.");
        }
    }

    private static async Task<IResult> MarkReadAsync(
        string notificationId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            $"""
            /* Addressed to the caller: the row's own ReadAtUtc. */
            UPDATE core.Notification
            SET ReadAtUtc = SYSUTCDATETIME()
            WHERE NotificationId = @NotificationId AND UserId = @UserId AND ReadAtUtc IS NULL;

            /* Broadcast: a read mark for this user only. */
            INSERT INTO core.NotificationRead (NotificationId, UserId)
            SELECT n.NotificationId, @UserId
            {VisibleRows}
              AND n.NotificationId = @NotificationId
              AND n.UserId IS NULL
              AND r.NotificationId IS NULL;
            """,
            new DynamicParameters(Scope(current)).With("NotificationId", notificationId),
            cancellationToken: ct));

        return Results.NoContent();
    }

    private static async Task<IResult> MarkAllReadAsync(
        ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            $"""
            UPDATE core.Notification
            SET ReadAtUtc = SYSUTCDATETIME()
            WHERE UserId = @UserId AND ReadAtUtc IS NULL;

            INSERT INTO core.NotificationRead (NotificationId, UserId)
            SELECT n.NotificationId, @UserId
            {VisibleRows}
              AND n.UserId IS NULL
              AND r.NotificationId IS NULL;
            """,
            new DynamicParameters(Scope(current)), cancellationToken: ct));

        return Results.NoContent();
    }

    private static DynamicParameters With(this DynamicParameters parameters, string name, object value)
    {
        parameters.Add(name, value);
        return parameters;
    }
}
