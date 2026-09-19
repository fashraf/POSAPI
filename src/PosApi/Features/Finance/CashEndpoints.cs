using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Finance;

public sealed record OpenDrawerRequest(string BranchId, long OpeningCashH);
public sealed record CloseDrawerRequest(long CountedCashH, string? Note);
public sealed record RecordSettlementRequest(
    string? BranchId, long CardSalesH, long DepositH, DateOnly SettledOn, string? Note);

public static class CashEndpoints
{
    public static void MapCashEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/finance")
            .WithTags("Cash")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/drawer/current", CurrentDrawerAsync)
             .RequireAuthorization(PermissionPolicy.For("pos.open_drawer"));

        group.MapGet("/drawer/{sessionId}/expectation", ExpectationAsync)
             .RequireAuthorization(PermissionPolicy.For("pos.open_drawer"));

        group.MapGet("/drawer/{sessionId}/takings", TakingsAsync)
             .RequireAuthorization(PermissionPolicy.For("pos.open_drawer"));

        group.MapGet("/drawer/history", DrawerHistoryAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapPost("/drawer/open", OpenDrawerAsync)
             .RequireAuthorization(PermissionPolicy.For("pos.open_drawer"));

        group.MapPost("/drawer/{sessionId}/close", CloseDrawerAsync)
             .RequireAuthorization(PermissionPolicy.For("pos.open_drawer"));

        group.MapGet("/settlements", SettlementsAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapGet("/settlements/outstanding", OutstandingAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapPost("/settlements", RecordSettlementAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));
    }

    private static async Task<IResult> CurrentDrawerAsync(
        ISqlConnectionFactory db, string? branchId, CancellationToken ct)
    {
        await using var connection = db.Create();

        var session = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT TOP (1) * FROM fin.DrawerSession
            WHERE ClosedAtUtc IS NULL
              AND (@BranchId IS NULL OR BranchId = @BranchId)
            ORDER BY OpenedAtUtc DESC;
            """,
            new { BranchId = branchId }, cancellationToken: ct));

        // No open drawer is a normal state, not an error. Returning 404 would
        // make the client treat "closed" as a failure.
        return Results.Ok(session);
    }

    private static async Task<IResult> ExpectationAsync(
        string sessionId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        try
        {
            var row = await connection.QuerySingleAsync(new CommandDefinition(
                "fin.usp_DrawerExpectation",
                new { SessionId = sessionId },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));

            return Results.Ok(row);
        }
        catch (SqlException ex) when (ex.Number >= 55000 && ex.Number < 56000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }
    }

    /// <summary>
    /// What the shift took, split by how it was paid.
    ///
    /// Card and credit are listed but do not affect the drawer — showing that
    /// distinction is the point, because it is what stops a cashier counting a
    /// day's card takings and concluding the till is short.
    /// </summary>
    private static async Task<IResult> TakingsAsync(
        string sessionId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var row = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            DECLARE @BranchId NVARCHAR(40), @From DATETIME2(3), @To DATETIME2(3);

            SELECT @BranchId = BranchId, @From = OpenedAtUtc,
                   @To = ISNULL(ClosedAtUtc, SYSUTCDATETIME())
            FROM fin.DrawerSession WHERE SessionId = @SessionId;

            WITH SaleLines AS (
                SELECT l.AccountCode, l.DebitH
                FROM fin.JournalEntry AS e
                JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
                WHERE e.Kind = N'sale'
                  AND e.PostedAtUtc >= @From AND e.PostedAtUtc <= @To
                  AND (e.BranchId = @BranchId OR e.BranchId IS NULL)
            )
            SELECT
                ISNULL((SELECT SUM(DebitH) FROM SaleLines WHERE AccountCode = N'1000'), 0) AS CashH,
                ISNULL((SELECT SUM(DebitH) FROM SaleLines WHERE AccountCode = N'1150'), 0) AS CardH,
                ISNULL((SELECT SUM(DebitH) FROM SaleLines WHERE AccountCode = N'1400'), 0) AS CreditH,
                ISNULL((SELECT SUM(DebitH) FROM SaleLines
                        WHERE AccountCode IN (N'1000', N'1150', N'1400')), 0) AS TotalH;
            """,
            new { SessionId = sessionId }, cancellationToken: ct));

        return Results.Ok(row);
    }

    private static async Task<IResult> DrawerHistoryAsync(
        ISqlConnectionFactory db, string? branchId, int take = 50, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT TOP (@Take) * FROM fin.DrawerSession
            WHERE ClosedAtUtc IS NOT NULL
              AND (@BranchId IS NULL OR BranchId = @BranchId)
            ORDER BY ClosedAtUtc DESC;
            """,
            new { BranchId = branchId, Take = take <= 0 ? 20 : Math.Min(take, 200) },
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> OpenDrawerAsync(
        OpenDrawerRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        if (!current.CanSeeBranch(request.BranchId)) return Results.Forbid();

        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@OpeningCashH", request.OpeningCashH);
        parameters.Add("@OpenedBy", current.Username);
        parameters.Add("@SessionId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_OpenDrawer", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 55000 && ex.Number < 56000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { sessionId = parameters.Get<string>("@SessionId") });
    }

    private static async Task<IResult> CloseDrawerAsync(
        string sessionId, CloseDrawerRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@SessionId", sessionId);
        parameters.Add("@CountedCashH", request.CountedCashH);
        parameters.Add("@ClosedBy", current.Username);
        parameters.Add("@Note", request.Note);
        parameters.Add("@VarianceH", dbType: DbType.Int64, direction: ParameterDirection.Output);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_CloseDrawer", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 55000 && ex.Number < 56000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { varianceH = parameters.Get<long>("@VarianceH") });
    }

    private static async Task<IResult> SettlementsAsync(
        ISqlConnectionFactory db, string? branchId, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT * FROM fin.CardSettlement
            WHERE (@BranchId IS NULL OR BranchId = @BranchId OR BranchId IS NULL)
            ORDER BY SettledOn DESC;
            """,
            new { BranchId = branchId }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    /// <summary>Card takings the bank has not deposited yet.</summary>
    private static async Task<IResult> OutstandingAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var amount = await connection.QuerySingleAsync<long>(new CommandDefinition(
            "SELECT ISNULL(SUM(DebitH - CreditH), 0) FROM fin.JournalLine WHERE AccountCode = N'1150';",
            cancellationToken: ct));

        return Results.Ok(new { outstandingH = amount });
    }

    private static async Task<IResult> RecordSettlementAsync(
        RecordSettlementRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct = default)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@CardSalesH", request.CardSalesH);
        parameters.Add("@DepositH", request.DepositH);
        parameters.Add("@SettledOn", request.SettledOn);
        parameters.Add("@Note", request.Note);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@SettlementId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);
        parameters.Add("@Reference", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_RecordSettlement", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 55000 && ex.Number < 56000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new
        {
            settlementId = parameters.Get<string>("@SettlementId"),
            reference = parameters.Get<string>("@Reference")
        });
    }

    internal static ApiError Translate(int number, string fallback) => number switch
    {
        55000 => ApiError.Create("negative_float",
            "An opening float cannot be negative.", "لا يمكن أن يكون الرصيد الافتتاحي سالبًا."),
        55001 => ApiError.Create("drawer_open",
            "A drawer is already open at this branch.", "يوجد درج مفتوح في هذا الفرع."),
        55002 => ApiError.Create("session_not_found",
            "Drawer session not found.", "جلسة الدرج غير موجودة."),
        55003 => ApiError.Create("negative_count",
            "A count cannot be negative.", "لا يمكن أن يكون العدّ سالبًا."),
        55004 => ApiError.Create("session_closed",
            "That drawer session is not open.", "جلسة الدرج ليست مفتوحة."),
        55010 => ApiError.Create("no_takings",
            "Enter the card takings this batch covers.", "أدخل متحصلات الشبكة لهذه الدفعة."),
        55011 => ApiError.Create("negative_deposit",
            "A deposit cannot be negative.", "لا يمكن أن يكون الإيداع سالبًا."),
        55012 => ApiError.Create("deposit_exceeds",
            "The deposit is more than the takings. Check the figures.",
            "الإيداع أكبر من المتحصلات. راجع الأرقام."),
        _ => ApiError.Create("cash_failed", fallback, "تعذّر إتمام العملية.")
    };
}
