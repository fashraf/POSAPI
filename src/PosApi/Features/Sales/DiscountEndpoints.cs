using Dapper;
using PosApi.Auth;
using PosApi.Data;

namespace PosApi.Features.Sales;

public static class DiscountEndpoints
{
    public static void MapDiscountEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/discounts")
            .WithTags("Discounts")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("discounts.view"));

        group.MapGet("/applicable", ApplicableAsync)
             .RequireAuthorization(PermissionPolicy.For("pos.apply_discount"));
    }

    private static async Task<IResult> ListAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            "SELECT * FROM sales.Discount ORDER BY NameEn;",
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    /// <summary>
    /// Discounts that could apply right now.
    ///
    /// Day-of-week and date windows are filtered here so the till never offers
    /// something that will be refused at commit. Note that `isAutomatic` is
    /// returned rather than acted on: only a discount flagged automatic may
    /// apply itself, and everything else waits to be chosen.
    /// </summary>
    private static async Task<IResult> ApplicableAsync(
        ISqlConnectionFactory db, long subtotalH = 0, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
            DECLARE @Dow INT = DATEPART(WEEKDAY, @Today) - 1;   -- 0 = Sunday

            SELECT d.*
            FROM sales.Discount AS d
            WHERE d.IsActive = 1
              AND (d.StartsOn IS NULL OR d.StartsOn <= @Today)
              AND (d.EndsOn   IS NULL OR d.EndsOn   >= @Today)
              AND (d.MinSubtotalH <= @SubtotalH)
              AND (d.ActiveDays = N''
                   OR N',' + d.ActiveDays + N',' LIKE N'%,' + CAST(@Dow AS NVARCHAR(2)) + N',%')
            ORDER BY d.IsAutomatic DESC, d.NameEn;
            """,
            new { SubtotalH = subtotalH }, cancellationToken: ct));

        return Results.Ok(rows);
    }
}
