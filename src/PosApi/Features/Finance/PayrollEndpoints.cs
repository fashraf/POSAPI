using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
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

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT r.*,
                   (SELECT COUNT(*) FROM fin.PayrollLine WHERE RunId = r.RunId) AS EmployeeCount,
                   ISNULL((SELECT SUM(BaseSalaryH) FROM fin.PayrollLine WHERE RunId = r.RunId), 0) AS SalariesH,
                   ISNULL((SELECT SUM(CommissionH) FROM fin.PayrollLine WHERE RunId = r.RunId), 0) AS CommissionH,
                   ISNULL((SELECT SUM(DeductionsH) FROM fin.PayrollLine WHERE RunId = r.RunId), 0) AS DeductionsH
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

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT * FROM fin.PayrollRun WHERE RunId = @RunId;

            SELECT l.*, u.NameAr, u.NameEn, u.Username
            FROM fin.PayrollLine AS l
            JOIN core.AppUser AS u ON u.UserId = l.UserId
            WHERE l.RunId = @RunId
            ORDER BY u.NameEn;
            """,
            new { RunId = runId }, cancellationToken: ct));

        var run = await multi.ReadSingleOrDefaultAsync();
        if (run is null) return Results.NotFound();

        var lines = (await multi.ReadAsync()).ToList();
        return Results.Ok(new { run, lines });
    }

    private static async Task<IResult> DraftPayrollAsync(
        DraftPayrollRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PeriodMonth", request.PeriodMonth);
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@RunId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_DraftPayroll", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 56000 && ex.Number < 57000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { runId = parameters.Get<string>("@RunId") });
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
            UPDATE l
            SET BaseSalaryH = @BaseSalaryH,
                AllowancesH = @AllowancesH,
                DeductionsH = @DeductionsH
            FROM fin.PayrollLine AS l
            JOIN fin.PayrollRun AS r ON r.RunId = l.RunId
            WHERE l.RunId = @RunId AND l.UserId = @UserId AND r.Status = N'draft';

            UPDATE fin.PayrollRun
            SET TotalH = ISNULL((SELECT SUM(NetPayH) FROM fin.PayrollLine WHERE RunId = @RunId), 0)
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
                "fin.usp_PayPayroll",
                new { RunId = runId, request.PaidOn, Actor = current.Username },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 56000 && ex.Number < 57000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.NoContent();
    }

    /*------------------------------------------------------------- periods */

    private static async Task<IResult> PeriodsAsync(
        ISqlConnectionFactory db, string? branchId, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
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

        var period = await connection.QuerySingleOrDefaultAsync(new CommandDefinition(
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
            var row = await connection.QuerySingleAsync(new CommandDefinition(
                "fin.usp_BalancePeriodExpectation",
                new { PeriodId = periodId },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));

            return Results.Ok(row);
        }
        catch (SqlException ex) when (ex.Number >= 56000 && ex.Number < 57000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }
    }

    private static async Task<IResult> OpenPeriodAsync(
        OpenPeriodRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        if (!current.CanSeeBranch(request.BranchId)) return Results.Forbid();

        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@Label", request.Label);
        parameters.Add("@OpenedOn", request.OpenedOn);
        parameters.Add("@OpeningCashH", request.OpeningCashH);
        parameters.Add("@OpeningCardH", request.OpeningCardH);
        parameters.Add("@OpeningCreditH", request.OpeningCreditH);
        parameters.Add("@OpeningBankH", request.OpeningBankH);
        parameters.Add("@OpeningInventoryH", request.OpeningInventoryH);
        parameters.Add("@OpeningPayablesH", request.OpeningPayablesH);
        parameters.Add("@OpenedBy", current.Username);
        parameters.Add("@Note", request.Note);
        parameters.Add("@PeriodId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_OpenBalancePeriod", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 56000 && ex.Number < 57000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { periodId = parameters.Get<string>("@PeriodId") });
    }

    private static async Task<IResult> ClosePeriodAsync(
        string periodId, ClosePeriodRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@PeriodId", periodId);
        parameters.Add("@ClosedOn", request.ClosedOn);
        parameters.Add("@ClosingCashH", request.ClosingCashH);
        parameters.Add("@ClosingCardH", request.ClosingCardH);
        parameters.Add("@ClosingCreditH", request.ClosingCreditH);
        parameters.Add("@ClosingBankH", request.ClosingBankH);
        parameters.Add("@ClosingInventoryH", request.ClosingInventoryH);
        parameters.Add("@ClosingPayablesH", request.ClosingPayablesH);
        parameters.Add("@ClosedBy", current.Username);
        parameters.Add("@Note", request.Note);
        parameters.Add("@VarianceH", dbType: DbType.Int64, direction: ParameterDirection.Output);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_CloseBalancePeriod", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 56000 && ex.Number < 57000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { varianceH = parameters.Get<long>("@VarianceH") });
    }

    /*--------------------------------------------------- recurring, reversal */

    private static async Task<IResult> RecordInstalmentAsync(
        string recurringId, RecordInstalmentRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@RecurringId", recurringId);
        parameters.Add("@PaidOn", request.PaidOn);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@ExpenseId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_RecordRecurringInstalment", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 54000 && ex.Number < 57000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { expenseId = parameters.Get<string>("@ExpenseId") });
    }

    private static async Task<IResult> ReverseExpenseAsync(
        string expenseId, ReverseRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_ReverseExpense",
                new { ExpenseId = expenseId, request.Reason, Actor = current.Username },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 56000 && ex.Number < 57000)
        {
            return Results.Json(Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.NoContent();
    }

    private static async Task<IResult> ReverseEntryAsync(
        string entryId, ReverseRequest request, ISqlConnectionFactory db,
        ICurrentUser current, CancellationToken ct)
    {
        var parameters = new DynamicParameters();
        parameters.Add("@EntryId", entryId);
        parameters.Add("@Reason", request.Reason);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@NewEntryId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_ReverseJournalEntry", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 51000 && ex.Number < 52000)
        {
            var error = ex.Number switch
            {
                51010 => ApiError.Create("entry_not_found",
                    "Journal entry not found.", "القيد غير موجود."),
                51011 => ApiError.Create("already_reversed",
                    "This entry has already been reversed.", "هذا القيد معكوس مسبقًا."),
                51012 => ApiError.Create("reason_required",
                    "A reversal needs a reason.", "العكس يحتاج إلى سبب."),
                _ => ApiError.Create("reverse_failed", ex.Message, "تعذّر عكس القيد.")
            };

            return Results.Json(error, statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { entryId = parameters.Get<string>("@NewEntryId") });
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
