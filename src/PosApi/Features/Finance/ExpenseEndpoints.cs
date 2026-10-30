using Dapper;
using Npgsql;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Features.Catalog;

namespace PosApi.Features.Finance;

public sealed record RecordExpenseRequest(
    string CategoryId,
    string? BranchId,
    string DescriptionEn,
    string? DescriptionAr,
    long AmountH,
    long VatH,
    string PaymentMethod,
    DateOnly PaidOn,
    string Recognition,
    DateOnly? PeriodStart,
    DateOnly? PeriodEnd,
    string? ExternalRef,
    string? AttachmentName);

public static class ExpenseEndpoints
{
    public static void MapExpenseEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/expenses")
            .WithTags("Expenses")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapPost("", RecordAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        /* Categories, recurring schedules and recognition: ExpenseSetupEndpoints. */
    }

    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, string? branchId, string? categoryId,
        DateOnly? from, DateOnly? to, int page = 1, int pageSize = 25, CancellationToken ct = default)
    {
        var paging = new PageQuery { Page = page <= 0 ? 1 : page, PageSize = pageSize };

        await using var connection = db.Create();

        const string sql = """
            SELECT COUNT(*)::int FROM fin.Expense AS e
            WHERE (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
              AND (@CategoryId IS NULL OR e.CategoryId = @CategoryId)
              AND (@From::date IS NULL OR e.PaidOn >= @From::date)
              AND (@To::date IS NULL OR e.PaidOn <= @To::date);

            SELECT e.*, c.NameAr AS CategoryNameAr, c.NameEn AS CategoryNameEn
            FROM fin.Expense AS e
            JOIN fin.ExpenseCategory AS c ON c.CategoryId = e.CategoryId
            WHERE (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
              AND (@CategoryId IS NULL OR e.CategoryId = @CategoryId)
              AND (@From::date IS NULL OR e.PaidOn >= @From::date)
              AND (@To::date IS NULL OR e.PaidOn <= @To::date)
            ORDER BY e.PaidOn DESC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;

        await using var multi = await connection.QueryMultipleNamedAsync(new CommandDefinition(sql,
            new { BranchId = branchId, CategoryId = categoryId, From = from, To = to,
                  paging.Offset, paging.PageSize },
            cancellationToken: ct));

        var total = await multi.ReadSingleAsync<int>();
        var rows = (await multi.ReadRowsAsync()).ToList();

        return Results.Ok(new PagedResult<object>
        {
            Items = rows.Cast<object>().ToList(),
            Page = paging.Page,
            PageSize = paging.PageSize,
            TotalCount = total
        });
    }

    /// <summary>
    /// Record an expense.
    ///
    /// The procedure posts the payment and then spreads the cost across the
    /// months it covers. Paying a year of rent up front is one cash movement and
    /// twelve monthly costs, and reporting it any other way makes January look
    /// catastrophic and the rest of the year better than it was.
    /// </summary>
    private static async Task<IResult> RecordAsync(
        RecordExpenseRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        CancellationToken ct)
    {
        await using var connection = db.Create();

        string expenseId;

        try
        {
            expenseId = await connection.QuerySingleAsync<string>(new CommandDefinition(
                """
                SELECT ExpenseId FROM fin.usp_RecordExpense(
                    p_CategoryId => @CategoryId, p_BranchId => @BranchId,
                    p_DescriptionEn => @DescriptionEn, p_DescriptionAr => @DescriptionAr,
                    p_AmountH => @AmountH, p_VatH => @VatH, p_PaymentMethod => @PaymentMethod,
                    p_PaidOn => @PaidOn::date, p_Recognition => @Recognition,
                    p_PeriodStart => @PeriodStart::date, p_PeriodEnd => @PeriodEnd::date,
                    p_ExternalRef => @ExternalRef, p_Attachment => @Attachment, p_Actor => @Actor);
                """,
                new
                {
                    request.CategoryId,
                    request.BranchId,
                    request.DescriptionEn,
                    request.DescriptionAr,
                    request.AmountH,
                    request.VatH,
                    request.PaymentMethod,
                    request.PaidOn,
                    request.Recognition,
                    request.PeriodStart,
                    request.PeriodEnd,
                    request.ExternalRef,
                    Attachment = request.AttachmentName,
                    Actor = current.Username
                },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (MapRecordError(ex) is { } mapped)
        {
            return mapped;
        }

        return Results.Ok(new { expenseId });
    }

    /// <summary>
    /// What fin.usp_RecordExpense (directly, or through a recurring
    /// instalment) can refuse, as responses. A duplicate key — an expense
    /// number already taken — is a 409 the user can retry, never a 500.
    /// </summary>
    internal static IResult? MapRecordError(PostgresException ex) => ex.ErrorNumber() switch
    {
        54024 => ProcErrors.Field("categoryId",
            "Salaries and commission are paid through payroll, not as an expense. Choose another category.",
            "الرواتب والعمولات تُصرف من خلال مسير الرواتب وليس كمصروف. اختر تصنيفًا آخر."),
        54025 => ProcErrors.Conflict("already_posted",
            "This expense is already posted.", "هذا المصروف مرحّل مسبقًا."),
        2601 or 2627 => ProcErrors.Conflict("duplicate_reference",
            "That expense number was just taken. Try again — the next number will be used.",
            "رقم المصروف هذا مستخدم للتو. أعد المحاولة وسيُستخدم الرقم التالي."),
        >= 54000 and < 55000 => Results.Json(InventoryEndpoints.Translate(ex.ErrorNumber(), ex.MessageText),
            statusCode: StatusCodes.Status422UnprocessableEntity),
        _ => null
    };
}
