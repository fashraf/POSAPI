using Dapper;
using PosApi.Auth;
using PosApi.Data;

namespace PosApi.Features.Settings;

public static class NotificationEndpoints
{
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

    /// <summary>
    /// A null UserId means the notification is for everyone, so both are
    /// returned. Filtering to the current user alone would hide branch-wide
    /// alerts from the person who needs to act on them.
    /// </summary>
    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, ICurrentUser current, bool? unreadOnly, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (50) *
            FROM core.Notification
            WHERE (UserId = @UserId OR UserId IS NULL)
              AND (@UnreadOnly = 0 OR ReadAtUtc IS NULL)
            ORDER BY CreatedAtUtc DESC;
            """,
            new { current.UserId, UnreadOnly = unreadOnly ?? false },
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> MarkReadAsync(
        string notificationId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE core.Notification
            SET ReadAtUtc = SYSUTCDATETIME()
            WHERE NotificationId = @NotificationId
              AND (UserId = @UserId OR UserId IS NULL)
              AND ReadAtUtc IS NULL;
            """,
            new { NotificationId = notificationId, current.UserId },
            cancellationToken: ct));

        return Results.NoContent();
    }

    private static async Task<IResult> MarkAllReadAsync(
        ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE core.Notification
            SET ReadAtUtc = SYSUTCDATETIME()
            WHERE (UserId = @UserId OR UserId IS NULL) AND ReadAtUtc IS NULL;
            """,
            new { current.UserId }, cancellationToken: ct));

        return Results.NoContent();
    }
}
