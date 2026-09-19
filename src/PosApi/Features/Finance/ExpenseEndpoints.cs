using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
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

        group.MapGet("/categories", CategoriesAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapGet("/recurring", RecurringAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));
    }

    private static async Task<IResult> ListAsync(
        ISqlConnectionFactory db, string? branchId, string? categoryId,
        DateOnly? from, DateOnly? to, int page = 1, int pageSize = 25, CancellationToken ct = default)
    {
        var paging = new PageQuery { Page = page <= 0 ? 1 : page, PageSize = pageSize };

        await using var connection = db.Create();

        const string sql = """
            SELECT COUNT(*) FROM fin.Expense AS e
            WHERE (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
              AND (@CategoryId IS NULL OR e.CategoryId = @CategoryId)
              AND (@From IS NULL OR e.PaidOn >= @From)
              AND (@To IS NULL OR e.PaidOn <= @To);

            SELECT e.*, c.NameAr AS CategoryNameAr, c.NameEn AS CategoryNameEn
            FROM fin.Expense AS e
            JOIN fin.ExpenseCategory AS c ON c.CategoryId = e.CategoryId
            WHERE (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
              AND (@CategoryId IS NULL OR e.CategoryId = @CategoryId)
              AND (@From IS NULL OR e.PaidOn >= @From)
              AND (@To IS NULL OR e.PaidOn <= @To)
            ORDER BY e.PaidOn DESC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(sql,
            new { BranchId = branchId, CategoryId = categoryId, From = from, To = to,
                  paging.Offset, paging.PageSize },
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
        var parameters = new DynamicParameters();
        parameters.Add("@CategoryId", request.CategoryId);
        parameters.Add("@BranchId", request.BranchId);
        parameters.Add("@DescriptionEn", request.DescriptionEn);
        parameters.Add("@DescriptionAr", request.DescriptionAr);
        parameters.Add("@AmountH", request.AmountH);
        parameters.Add("@VatH", request.VatH);
        parameters.Add("@PaymentMethod", request.PaymentMethod);
        parameters.Add("@PaidOn", request.PaidOn);
        parameters.Add("@Recognition", request.Recognition);
        parameters.Add("@PeriodStart", request.PeriodStart);
        parameters.Add("@PeriodEnd", request.PeriodEnd);
        parameters.Add("@ExternalRef", request.ExternalRef);
        parameters.Add("@Attachment", request.AttachmentName);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@ExpenseId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_RecordExpense", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number >= 54000 && ex.Number < 55000)
        {
            return Results.Json(InventoryEndpoints.Translate(ex.Number, ex.Message),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        return Results.Ok(new { expenseId = parameters.Get<string>("@ExpenseId") });
    }

    private static async Task<IResult> CategoriesAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            "SELECT CategoryId, NameAr, NameEn, AccountCode FROM fin.ExpenseCategory WHERE IsActive = 1 ORDER BY NameEn;",
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> RecurringAsync(
        ISqlConnectionFactory db, string? branchId, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        // Urgency is derived here rather than stored, so a payment that becomes
        // overdue overnight reads as overdue with nothing to refresh.
        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT r.*, c.NameAr AS CategoryNameAr, c.NameEn AS CategoryNameEn,
                   DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), r.NextDueOn) AS DaysUntilDue,
                   CASE
                       WHEN r.NextDueOn <  CAST(SYSUTCDATETIME() AS DATE) THEN N'overdue'
                       WHEN r.NextDueOn =  CAST(SYSUTCDATETIME() AS DATE) THEN N'today'
                       WHEN DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), r.NextDueOn) <= 5 THEN N'soon'
                       ELSE N'normal'
                   END AS Urgency
            FROM fin.RecurringPayment AS r
            JOIN fin.ExpenseCategory AS c ON c.CategoryId = r.CategoryId
            WHERE (@BranchId IS NULL OR r.BranchId = @BranchId OR r.BranchId IS NULL)
            ORDER BY r.NextDueOn;
            """,
            new { BranchId = branchId }, cancellationToken: ct));

        return Results.Ok(rows);
    }
}
