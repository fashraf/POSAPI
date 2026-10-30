using Dapper;
using Npgsql;
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

        var session = await connection.QuerySingleRowOrDefaultAsync(new CommandDefinition(
            """
            SELECT * FROM fin.DrawerSession
            WHERE ClosedAtUtc IS NULL
              AND (@BranchId IS NULL OR BranchId = @BranchId)
            ORDER BY OpenedAtUtc DESC
            LIMIT 1;
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
            var row = await connection.QuerySingleRowAsync(new CommandDefinition(
                """
                SELECT OpeningCashH, CashSalesH, CashCollectionsH, OwnerContributionsH,
                       CashExpensesH, OwnerWithdrawalsH, CashRefundsH, ExpectedH
                FROM fin.usp_DrawerExpectation(p_SessionId => @SessionId);
                """,
                new { SessionId = sessionId }, cancellationToken: ct));

            return Results.Ok(row);
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 55000 && ex.ErrorNumber() < 56000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
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

        var row = await connection.QuerySingleRowOrDefaultAsync(new CommandDefinition(
            """
            WITH Session AS (
                SELECT BranchId, OpenedAtUtc AS FromUtc,
                       COALESCE(ClosedAtUtc, now() AT TIME ZONE 'utc') AS ToUtc
                FROM fin.DrawerSession WHERE SessionId = @SessionId
            ),
            SaleLines AS (
                SELECT l.AccountCode, l.DebitH
                FROM fin.JournalEntry AS e
                JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
                JOIN Session AS s ON e.PostedAtUtc >= s.FromUtc AND e.PostedAtUtc <= s.ToUtc
                WHERE e.Kind = 'sale'
                  AND (e.BranchId = s.BranchId OR e.BranchId IS NULL)
            )
            SELECT
                COALESCE((SELECT SUM(DebitH) FROM SaleLines WHERE AccountCode = '1000'), 0)::bigint AS CashH,
                COALESCE((SELECT SUM(DebitH) FROM SaleLines WHERE AccountCode = '1150'), 0)::bigint AS CardH,
                COALESCE((SELECT SUM(DebitH) FROM SaleLines WHERE AccountCode = '1400'), 0)::bigint AS CreditH,
                COALESCE((SELECT SUM(DebitH) FROM SaleLines
                          WHERE AccountCode IN ('1000', '1150', '1400')), 0)::bigint AS TotalH;
            """,
            new { SessionId = sessionId }, cancellationToken: ct));

        return Results.Ok(row);
    }

    private static async Task<IResult> DrawerHistoryAsync(
        ISqlConnectionFactory db, string? branchId, int take = 50, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryRowsAsync(new CommandDefinition(
            """
            SELECT * FROM fin.DrawerSession
            WHERE ClosedAtUtc IS NOT NULL
              AND (@BranchId IS NULL OR BranchId = @BranchId)
            ORDER BY ClosedAtUtc DESC
            LIMIT @Take;
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

        await using var connection = db.Create();

        string sessionId;

        try
        {
            sessionId = await connection.QuerySingleAsync<string>(new CommandDefinition(
                """
                SELECT SessionId FROM fin.usp_OpenDrawer(
                    p_BranchId => @BranchId, p_OpeningCashH => @OpeningCashH, p_OpenedBy => @OpenedBy);
                """,
                new { request.BranchId, request.OpeningCashH, OpenedBy = current.Username },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 55000 && ex.ErrorNumber() < 56000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { sessionId });
    }

    private static async Task<IResult> CloseDrawerAsync(
        string sessionId, CloseDrawerRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        long varianceH;

        try
        {
            varianceH = await connection.QuerySingleAsync<long>(new CommandDefinition(
                """
                SELECT VarianceH FROM fin.usp_CloseDrawer(
                    p_SessionId => @SessionId, p_CountedCashH => @CountedCashH,
                    p_ClosedBy => @ClosedBy, p_Note => @Note);
                """,
                new { SessionId = sessionId, request.CountedCashH, ClosedBy = current.Username, request.Note },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 55000 && ex.ErrorNumber() < 56000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { varianceH });
    }

    private static async Task<IResult> SettlementsAsync(
        ISqlConnectionFactory db, string? branchId, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryRowsAsync(new CommandDefinition(
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
            "SELECT COALESCE(SUM(DebitH - CreditH), 0)::bigint FROM fin.JournalLine WHERE AccountCode = '1150';",
            cancellationToken: ct));

        return Results.Ok(new { outstandingH = amount });
    }

    private static async Task<IResult> RecordSettlementAsync(
        RecordSettlementRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        (string SettlementId, string Reference) saved;

        try
        {
            saved = await connection.QuerySingleAsync<(string, string)>(new CommandDefinition(
                """
                SELECT SettlementId, Reference FROM fin.usp_RecordSettlement(
                    p_BranchId => @BranchId, p_CardSalesH => @CardSalesH, p_DepositH => @DepositH,
                    p_SettledOn => @SettledOn::date, p_Note => @Note, p_Actor => @Actor);
                """,
                new
                {
                    request.BranchId,
                    request.CardSalesH,
                    request.DepositH,
                    request.SettledOn,
                    request.Note,
                    Actor = current.Username
                },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 55000 && ex.ErrorNumber() < 56000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new
        {
            settlementId = saved.SettlementId,
            reference = saved.Reference
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
