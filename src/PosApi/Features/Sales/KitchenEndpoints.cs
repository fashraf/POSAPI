using Dapper;
using PosApi.Auth;
using PosApi.Data;

namespace PosApi.Features.Sales;

public sealed record SetPreparationStatusRequest(string Status);
public sealed record SetItemProgressRequest(decimal CompletedQuantity);

public static class KitchenEndpoints
{
    public static void MapKitchenEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/kitchen")
            .WithTags("Kitchen")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/orders", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("kitchen.view"));

        group.MapPost("/orders/{preparationId}/status", SetStatusAsync)
             .RequireAuthorization(PermissionPolicy.For("kitchen.update"));

        group.MapPost("/orders/{preparationId}/items/{itemId:long}", SetProgressAsync)
             .RequireAuthorization(PermissionPolicy.For("kitchen.update"));
    }

    /// <summary>
    /// The board.
    ///
    /// Elapsed time comes from the created timestamp on every read rather than
    /// being stored, so a ticket ages correctly without anything updating it.
    /// </summary>
    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, string? branchId, bool? includeCompleted, CancellationToken ct)
    {
        await using var connection = db.Create();

        await using var multi = await connection.QueryMultipleNamedAsync(new CommandDefinition(
            """
            SELECT o.PreparationId, o.OrderNumber, o.SaleId, o.BranchId, o.PrintGroupId,
                   o.CustomerName, o.TotalH, o.Status, o.OrderType, o.CreatedAtUtc, o.UpdatedAtUtc,
                   /* Second boundaries crossed, as DATEDIFF(SECOND, ...) counted them. */
                   (extract(epoch FROM date_trunc('second', now() AT TIME ZONE 'utc'))
                    - extract(epoch FROM date_trunc('second', o.CreatedAtUtc)))::int AS ElapsedSeconds
            FROM sales.PreparationOrder AS o
            WHERE (@BranchId IS NULL OR o.BranchId = @BranchId OR o.BranchId IS NULL)
              AND (@IncludeCompleted OR o.Status <> 'completed')
            ORDER BY o.CreatedAtUtc;

            SELECT i.*
            FROM sales.PreparationItem AS i
            JOIN sales.PreparationOrder AS o ON o.PreparationId = i.PreparationId
            WHERE (@BranchId IS NULL OR o.BranchId = @BranchId OR o.BranchId IS NULL)
              AND (@IncludeCompleted OR o.Status <> 'completed');
            """,
            new { BranchId = branchId, IncludeCompleted = includeCompleted ?? false },
            cancellationToken: ct));

        var orders = (await multi.ReadRowsAsync()).ToList();
        var items = (await multi.ReadRowsAsync()).ToList();

        return Results.Ok(new { orders, items });
    }

    private static async Task<IResult> SetStatusAsync(
        string preparationId,
        SetPreparationStatusRequest request,
        ISqlConnectionFactory db,
        CancellationToken ct)
    {
        var allowed = new[] { "open", "preparing", "ready", "completed" };

        if (!allowed.Contains(request.Status, StringComparer.OrdinalIgnoreCase))
        {
            return Results.BadRequest(Common.ApiError.Create(
                "bad_status", "That is not a valid status.", "هذه الحالة غير صحيحة."));
        }

        var status = request.Status.ToLowerInvariant();

        await using var connection = db.Create();

        /* Ready and completed mean every line is done, so the lines are brought
           up in the same statement. The board used to send one request per line
           first and the status last; one failure in between left an order
           marked ready with lines still open, and "Mark ready" depended on
           the browser finishing a chain of calls. One statement is one
           transaction: both updates happen or neither does. */
        var affected = await connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            WITH Updated AS (
                UPDATE sales.PreparationOrder
                SET Status = @Status, UpdatedAtUtc = now() AT TIME ZONE 'utc'
                WHERE PreparationId = @PreparationId
                RETURNING PreparationId
            ),
            Lines AS (
                UPDATE sales.PreparationItem AS i
                SET CompletedQty = i.Quantity
                FROM Updated AS u
                WHERE i.PreparationId = u.PreparationId
                  AND @Status IN ('ready', 'completed')
                  AND i.CompletedQty < i.Quantity
            )
            SELECT COUNT(*)::int FROM Updated;
            """,
            new { PreparationId = preparationId, Status = status },
            cancellationToken: ct));

        return affected == 0 ? Results.NotFound() : Results.NoContent();
    }

    private static async Task<IResult> SetProgressAsync(
        string preparationId,
        long itemId,
        SetItemProgressRequest request,
        ISqlConnectionFactory db,
        CancellationToken ct = default)
    {
        await using var connection = db.Create();

        // The CHECK constraint keeps completed within the ordered quantity, so
        // clamping here is about a clear message rather than data safety.
        var affected = await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE sales.PreparationItem
            SET CompletedQty = CASE
                                   WHEN @Completed < 0 THEN 0
                                   WHEN @Completed > Quantity THEN Quantity
                                   ELSE @Completed
                               END
            WHERE PreparationItemId = @ItemId AND PreparationId = @PreparationId;
            """,
            new { PreparationId = preparationId, ItemId = itemId, Completed = request.CompletedQuantity },
            cancellationToken: ct));

        return affected == 0 ? Results.NotFound() : Results.NoContent();
    }
}
