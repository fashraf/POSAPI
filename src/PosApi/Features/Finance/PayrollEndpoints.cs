using Dapper;
using Npgsql;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Finance;

public sealed record DraftPayrollRequest(string PeriodMonth, string? BranchId);
public sealed record PayPayrollRequest(DateOnly PaidOn);
public sealed record UpdatePayrollLineRequest(long BaseSalaryH, long AllowancesH, long DeductionsH);

public sealed record OpenPeriodRequest(
    string BranchId, string Label, DateOnly OpenedOn,
    long OpeningCashH, long OpeningCardH, long OpeningCreditH,
    long OpeningBankH, long OpeningInventoryH, long OpeningPayablesH,
    string? Note);

public sealed record ClosePeriodRequest(
    DateOnly ClosedOn,
    long ClosingCashH, long ClosingCardH, long ClosingCreditH,
    long ClosingBankH, long ClosingInventoryH, long ClosingPayablesH,
    string? Note);

public sealed record RecordInstalmentRequest(DateOnly PaidOn);
public sealed record ReverseRequest(string Reason);

public static class PayrollEndpoints
{
    public static void MapPayrollEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/finance")
            .WithTags("Payroll & periods")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        /* Payroll */
        group.MapGet("/payroll", PayrollRunsAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.payroll"));

        group.MapGet("/payroll/{runId}", PayrollRunAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.payroll"));

        group.MapPost("/payroll/draft", DraftPayrollAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.payroll"));

        group.MapPut("/payroll/{runId}/lines/{userId}", UpdateLineAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.payroll"));

        group.MapPost("/payroll/{runId}/pay", PayPayrollAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.payroll"));

        /* Balance periods */
        group.MapGet("/periods", PeriodsAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapGet("/periods/{periodId}", PeriodAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapGet("/periods/{periodId}/expectation", PeriodExpectationAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapPost("/periods", OpenPeriodAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapPost("/periods/{periodId}/close", ClosePeriodAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        /* Recurring and reversals */
        group.MapPost("/recurring/{recurringId}/record", RecordInstalmentAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapPost("/expenses/{expenseId}/reverse", ReverseExpenseAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.reverse"));

        group.MapPost("/ledger/{entryId}/reverse", ReverseEntryAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.reverse"));
    }

    /*------------------------------------------------------------- payroll */

    /// <summary>
    /// Every recent period, run or not.
    ///
    /// A list of completed runs cannot show you the month nobody paid, which is
    /// the thing worth spotting.
    /// </summary>
    private static async Task<IResult> PayrollRunsAsync(
        ISqlConnectionFactory db, string? branchId, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryRowsAsync(new CommandDefinition(
            """
            SELECT r.*,
                   (SELECT COUNT(*)::int FROM fin.PayrollLine WHERE RunId = r.RunId) AS EmployeeCount,
                   COALESCE((SELECT SUM(BaseSalaryH) FROM fin.PayrollLine WHERE RunId = r.RunId), 0)::bigint AS SalariesH,
                   COALESCE((SELECT SUM(CommissionH) FROM fin.PayrollLine WHERE RunId = r.RunId), 0)::bigint AS CommissionH,
                   COALESCE((SELECT SUM(AllowancesH) FROM fin.PayrollLine WHERE RunId = r.RunId), 0)::bigint AS AllowancesH,
                   COALESCE((SELECT SUM(DeductionsH) FROM fin.PayrollLine WHERE RunId = r.RunId), 0)::bigint AS DeductionsH
            FROM fin.PayrollRun AS r
            WHERE (@BranchId IS NULL OR r.BranchId = @BranchId OR r.BranchId IS NULL)
            ORDER BY r.PeriodMonth DESC;
            """,
            new { BranchId = branchId }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> PayrollRunAsync(
        string runId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        await using var multi = await connection.QueryMultipleNamedAsync(new CommandDefinition(
            """
            SELECT * FROM fin.PayrollRun WHERE RunId = @RunId;

            SELECT l.*, u.NameAr, u.NameEn, u.Username
            FROM fin.PayrollLine AS l
            JOIN core.AppUser AS u ON u.UserId = l.UserId
            WHERE l.RunId = @RunId
            ORDER BY u.NameEn;
            """,
            new { RunId = runId }, cancellationToken: ct));

        var run = await multi.ReadSingleRowOrDefaultAsync();
        if (run is null) return Results.NotFound();

        var lines = (await multi.ReadRowsAsync()).ToList();
        return Results.Ok(new { run, lines });
    }

    private static async Task<IResult> DraftPayrollAsync(
        DraftPayrollRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        string runId;

        try
        {
            runId = await connection.QuerySingleAsync<string>(new CommandDefinition(
                """
                SELECT RunId FROM fin.usp_DraftPayroll(
                    p_PeriodMonth => @PeriodMonth, p_BranchId => @BranchId, p_Actor => @Actor);
                """,
                new { request.PeriodMonth, request.BranchId, Actor = current.Username },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 56000 && ex.ErrorNumber() < 57000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { runId });
    }

    /// <summary>
    /// Adjust a line before paying.
    ///
    /// Commission is deliberately not editable: it is a record of what was
    /// earned at each sale, not a figure to negotiate afterwards.
    /// </summary>
    private static async Task<IResult> UpdateLineAsync(
        string runId, string userId, UpdatePayrollLineRequest request,
        ISqlConnectionFactory db, CancellationToken ct)
    {
        if (request.BaseSalaryH < 0 || request.AllowancesH < 0 || request.DeductionsH < 0)
        {
            return Results.BadRequest(ApiError.Create(
                "negative_amount", "Amounts cannot be negative.", "لا يمكن أن تكون المبالغ سالبة."));
        }

        await using var connection = db.Create();

        var affected = await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.PayrollLine AS l
            SET BaseSalaryH = @BaseSalaryH,
                AllowancesH = @AllowancesH,
                DeductionsH = @DeductionsH
            FROM fin.PayrollRun AS r
            WHERE r.RunId = l.RunId
              AND l.RunId = @RunId AND l.UserId = @UserId AND r.Status = 'draft';

            UPDATE fin.PayrollRun
            SET TotalH = COALESCE((SELECT SUM(NetPayH) FROM fin.PayrollLine WHERE RunId = @RunId), 0)::bigint
            WHERE RunId = @RunId;
            """,
            new { RunId = runId, UserId = userId, request.BaseSalaryH, request.AllowancesH, request.DeductionsH },
            cancellationToken: ct));

        return affected == 0 ? Results.NotFound() : Results.NoContent();
    }

    private static async Task<IResult> PayPayrollAsync(
        string runId, PayPayrollRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "SELECT fin.usp_PayPayroll(p_RunId => @RunId, p_PaidOn => @PaidOn::date, p_Actor => @Actor);",
                new { RunId = runId, request.PaidOn, Actor = current.Username },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 56000 && ex.ErrorNumber() < 57000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.NoContent();
    }

    /*------------------------------------------------------------- periods */

    private static async Task<IResult> PeriodsAsync(
        ISqlConnectionFactory db, string? branchId, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryRowsAsync(new CommandDefinition(
            """
            SELECT p.*, b.NameAr AS BranchNameAr, b.NameEn AS BranchNameEn
            FROM fin.BalancePeriod AS p
            LEFT JOIN core.Branch AS b ON b.BranchId = p.BranchId
            WHERE (@BranchId IS NULL OR p.BranchId = @BranchId)
            ORDER BY p.OpenedOn DESC;
            """,
            new { BranchId = branchId }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> PeriodAsync(
        string periodId, ISqlConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var period = await connection.QuerySingleRowOrDefaultAsync(new CommandDefinition(
            "SELECT * FROM fin.BalancePeriod WHERE PeriodId = @PeriodId;",
            new { PeriodId = periodId }, cancellationToken: ct));

        return period is null ? Results.NotFound() : Results.Ok(period);
    }

    private static async Task<IResult> PeriodExpectationAsync(
        string periodId, ISqlConnectionFactory db, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        try
        {
            var row = await connection.QuerySingleRowAsync(new CommandDefinition(
                """
                SELECT CashH, CardH, CreditH, BankH, InventoryH, PayablesH
                FROM fin.usp_BalancePeriodExpectation(p_PeriodId => @PeriodId);
                """,
                new { PeriodId = periodId }, cancellationToken: ct));

            return Results.Ok(row);
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 56000 && ex.ErrorNumber() < 57000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }
    }

    private static async Task<IResult> OpenPeriodAsync(
        OpenPeriodRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        if (!current.CanSeeBranch(request.BranchId)) return Results.Forbid();

        await using var connection = db.Create();

        string periodId;

        try
        {
            periodId = await connection.QuerySingleAsync<string>(new CommandDefinition(
                """
                SELECT PeriodId FROM fin.usp_OpenBalancePeriod(
                    p_BranchId => @BranchId, p_Label => @Label, p_OpenedOn => @OpenedOn::date,
                    p_OpeningCashH => @OpeningCashH, p_OpeningCardH => @OpeningCardH,
                    p_OpeningCreditH => @OpeningCreditH, p_OpeningBankH => @OpeningBankH,
                    p_OpeningInventoryH => @OpeningInventoryH, p_OpeningPayablesH => @OpeningPayablesH,
                    p_OpenedBy => @OpenedBy, p_Note => @Note);
                """,
                new
                {
                    request.BranchId,
                    request.Label,
                    request.OpenedOn,
                    request.OpeningCashH,
                    request.OpeningCardH,
                    request.OpeningCreditH,
                    request.OpeningBankH,
                    request.OpeningInventoryH,
                    request.OpeningPayablesH,
                    OpenedBy = current.Username,
                    request.Note
                },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 56000 && ex.ErrorNumber() < 57000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { periodId });
    }

    private static async Task<IResult> ClosePeriodAsync(
        string periodId, ClosePeriodRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        long varianceH;

        try
        {
            varianceH = await connection.QuerySingleAsync<long>(new CommandDefinition(
                """
                SELECT VarianceH FROM fin.usp_CloseBalancePeriod(
                    p_PeriodId => @PeriodId, p_ClosedOn => @ClosedOn::date,
                    p_ClosingCashH => @ClosingCashH, p_ClosingCardH => @ClosingCardH,
                    p_ClosingCreditH => @ClosingCreditH, p_ClosingBankH => @ClosingBankH,
                    p_ClosingInventoryH => @ClosingInventoryH, p_ClosingPayablesH => @ClosingPayablesH,
                    p_ClosedBy => @ClosedBy, p_Note => @Note);
                """,
                new
                {
                    PeriodId = periodId,
                    request.ClosedOn,
                    request.ClosingCashH,
                    request.ClosingCardH,
                    request.ClosingCreditH,
                    request.ClosingBankH,
                    request.ClosingInventoryH,
                    request.ClosingPayablesH,
                    ClosedBy = current.Username,
                    request.Note
                },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 56000 && ex.ErrorNumber() < 57000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { varianceH });
    }

    /*--------------------------------------------------- recurring, reversal */

    private static async Task<IResult> RecordInstalmentAsync(
        string recurringId, RecordInstalmentRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        string expenseId;

        try
        {
            expenseId = await connection.QuerySingleAsync<string>(new CommandDefinition(
                """
                SELECT ExpenseId FROM fin.usp_RecordRecurringInstalment(
                    p_RecurringId => @RecurringId, p_PaidOn => @PaidOn::date, p_Actor => @Actor);
                """,
                new { RecurringId = recurringId, request.PaidOn, Actor = current.Username },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ExpenseEndpoints.MapRecordError(ex) is { } mapped)
        {
            return mapped;
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 56000 && ex.ErrorNumber() < 57000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { expenseId });
    }

    private static async Task<IResult> ReverseExpenseAsync(
        string expenseId, ReverseRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "SELECT fin.usp_ReverseExpense(p_ExpenseId => @ExpenseId, p_Reason => @Reason, p_Actor => @Actor);",
                new { ExpenseId = expenseId, request.Reason, Actor = current.Username },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 56000 && ex.ErrorNumber() < 57000)
        {
            return Results.Json(Translate(ex.ErrorNumber(), ex.MessageText),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.NoContent();
    }

    private static async Task<IResult> ReverseEntryAsync(
        string entryId, ReverseRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        string newEntryId;

        try
        {
            newEntryId = await connection.QuerySingleAsync<string>(new CommandDefinition(
                """
                SELECT NewEntryId FROM fin.usp_ReverseJournalEntry(
                    p_EntryId => @EntryId, p_Reason => @Reason, p_Actor => @Actor);
                """,
                new { EntryId = entryId, request.Reason, Actor = current.Username },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.ErrorNumber() >= 51000 && ex.ErrorNumber() < 52000)
        {
            var error = ex.ErrorNumber() switch
            {
                51010 => ApiError.Create("entry_not_found",
                    "Journal entry not found.", "القيد غير موجود."),
                51011 => ApiError.Create("already_reversed",
                    "This entry has already been reversed.", "هذا القيد معكوس مسبقًا."),
                51012 => ApiError.Create("reason_required",
                    "A reversal needs a reason.", "العكس يحتاج إلى سبب."),
                _ => ApiError.Create("reverse_failed", ex.MessageText, "تعذّر عكس القيد.")
            };

            return Results.Json(error, statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { entryId = newEntryId });
    }

    internal static ApiError Translate(int number, string fallback) => number switch
    {
        56000 => ApiError.Create("period_open",
            "This branch already has an open period.", "يوجد فترة مفتوحة لهذا الفرع."),
        56001 => ApiError.Create("negative_opening",
            "Opening balances cannot be negative.", "لا يمكن أن تكون الأرصدة الافتتاحية سالبة."),
        56002 => ApiError.Create("period_not_found",
            "Balance period not found.", "الفترة غير موجودة."),
        56003 => ApiError.Create("period_closed",
            "That period is not open.", "الفترة ليست مفتوحة."),
        56004 => ApiError.Create("bad_close_date",
            "The closing date is before the period opened.", "تاريخ الإقفال يسبق تاريخ الفتح."),
        56010 => ApiError.Create("payroll_paid",
            "Payroll for this period has already been paid.", "رواتب هذه الفترة مصروفة مسبقًا."),
        56011 => ApiError.Create("run_not_found",
            "Payroll run not found.", "دورة الرواتب غير موجودة."),
        56012 => ApiError.Create("already_paid",
            "This payroll has already been paid.", "هذه الرواتب مصروفة مسبقًا."),
        56013 => ApiError.Create("nothing_to_pay",
            "There is nothing to pay for this period.", "لا يوجد ما يُصرف لهذه الفترة."),
        56020 => ApiError.Create("recurring_not_found",
            "Recurring payment not found.", "الدفعة المتكرّرة غير موجودة."),
        56030 => ApiError.Create("expense_not_found",
            "Expense not found.", "المصروف غير موجود."),
        56031 => ApiError.Create("already_reversed",
            "This expense has already been reversed.", "هذا المصروف معكوس مسبقًا."),
        56032 => ApiError.Create("reason_required",
            "A reversal needs a reason.", "العكس يحتاج إلى سبب."),
        _ => ApiError.Create("operation_failed", fallback, "تعذّر إتمام العملية.")
    };
}
