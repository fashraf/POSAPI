using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Finance;

public static class FinanceEndpoints
{
    public static void MapFinanceEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/finance")
            .WithTags("Finance")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/ledger", LedgerAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.ledger"));

        group.MapGet("/accounts", AccountsAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapGet("/summary", SummaryAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapGet("/commission", CommissionAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.commission"));
    }

    private static async Task<IResult> LedgerAsync(
        ISqlConnectionFactory db,
        string? branchId, string? accountCode, string? kind,
        DateOnly? from, DateOnly? to, string? search,
        int page = 1, int pageSize = 25, CancellationToken ct = default)
    {
        var paging = new PageQuery { Page = page <= 0 ? 1 : page, PageSize = pageSize };

        await using var connection = db.Create();

        // A null BranchId on an entry means "not branch-specific", so it stays
        // visible from every branch — the same rule the frontend applies.
        const string sql = """
            SELECT COUNT(*)
            FROM fin.JournalEntry AS e
            WHERE (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
              AND (@Kind IS NULL OR e.Kind = @Kind)
              AND (@From IS NULL OR CAST(e.PostedAtUtc AS DATE) >= @From)
              AND (@To   IS NULL OR CAST(e.PostedAtUtc AS DATE) <= @To)
              AND (@Search IS NULL OR e.Reference LIKE N'%' + @Search + N'%'
                                   OR e.SourceReference LIKE N'%' + @Search + N'%'
                                   OR e.DescriptionEn LIKE N'%' + @Search + N'%')
              AND (@AccountCode IS NULL OR EXISTS (
                    SELECT 1 FROM fin.JournalLine AS l
                    WHERE l.EntryId = e.EntryId AND l.AccountCode = @AccountCode));

            SELECT e.EntryId, e.Reference, e.Kind, e.SourceReference,
                   e.DescriptionAr, e.DescriptionEn, e.PostedAtUtc, e.BranchId,
                   e.Actor, e.TotalDebitH, e.TotalCreditH,
                   e.ReversesEntryId, e.ReversedByEntryId
            FROM fin.JournalEntry AS e
            WHERE (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
              AND (@Kind IS NULL OR e.Kind = @Kind)
              AND (@From IS NULL OR CAST(e.PostedAtUtc AS DATE) >= @From)
              AND (@To   IS NULL OR CAST(e.PostedAtUtc AS DATE) <= @To)
              AND (@Search IS NULL OR e.Reference LIKE N'%' + @Search + N'%'
                                   OR e.SourceReference LIKE N'%' + @Search + N'%'
                                   OR e.DescriptionEn LIKE N'%' + @Search + N'%')
              AND (@AccountCode IS NULL OR EXISTS (
                    SELECT 1 FROM fin.JournalLine AS l
                    WHERE l.EntryId = e.EntryId AND l.AccountCode = @AccountCode))
            ORDER BY e.PostedAtUtc DESC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """;

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(sql,
            new
            {
                BranchId = branchId,
                AccountCode = accountCode,
                Kind = kind,
                From = from,
                To = to,
                Search = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
                paging.Offset,
                paging.PageSize
            },
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

    private static async Task<IResult> AccountsAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            "SELECT * FROM fin.vw_AccountBalance ORDER BY AccountCode;",
            cancellationToken: ct));

        return Results.Ok(rows);
    }

    /// <summary>
    /// The finance dashboard figures for one month.
    ///
    /// Derived from the ledger rather than recomputed from sales, so every
    /// number on the screen can be traced to the entries behind it.
    /// </summary>
    private static async Task<IResult> SummaryAsync(
        ISqlConnectionFactory db, string? branchId, string? month, CancellationToken ct = default)
    {
        var period = string.IsNullOrWhiteSpace(month)
            ? DateTime.UtcNow.ToString("yyyy-MM")
            : month;

        await using var connection = db.Create();

        const string sql = """
            DECLARE @Start DATE = CAST(@Period + '-01' AS DATE);
            DECLARE @Next  DATE = DATEADD(MONTH, 1, @Start);

            WITH Scoped AS (
                SELECT l.AccountCode, l.DebitH, l.CreditH
                FROM fin.JournalEntry AS e
                JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
                WHERE e.PostedAtUtc >= @Start AND e.PostedAtUtc < @Next
                  AND (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
            ),
            AllTime AS (
                SELECT l.AccountCode, l.DebitH, l.CreditH
                FROM fin.JournalEntry AS e
                JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
                WHERE (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
            )
            SELECT
                ISNULL((SELECT SUM(CreditH - DebitH) FROM Scoped WHERE AccountCode = '4100'), 0) AS RevenueH,
                ISNULL((SELECT SUM(DebitH - CreditH) FROM Scoped WHERE AccountCode = '5100'), 0) AS CogsH,
                ISNULL((SELECT SUM(DebitH - CreditH) FROM Scoped
                        WHERE AccountCode IN ('6000','6100','6200','6300','5200')), 0) AS ExpensesH,
                ISNULL((SELECT SUM(DebitH - CreditH) FROM AllTime WHERE AccountCode IN ('1000','1100')), 0) AS CashH,
                ISNULL((SELECT SUM(DebitH - CreditH) FROM AllTime WHERE AccountCode = '1400'), 0) AS ReceivableH,
                ISNULL((SELECT SUM(CreditH - DebitH) FROM AllTime WHERE AccountCode = '2000'), 0) AS PayableH,
                ISNULL((SELECT SUM(DebitH - CreditH) FROM AllTime WHERE AccountCode = '1500'), 0) AS PrepaidH,
                ISNULL((SELECT SUM(DebitH - CreditH) FROM AllTime WHERE AccountCode = '1150'), 0) AS CardClearingH;
            """;

        var summary = await connection.QuerySingleAsync(new CommandDefinition(sql,
            new { Period = period, BranchId = branchId }, cancellationToken: ct));

        return Results.Ok(summary);
    }

    private static async Task<IResult> CommissionAsync(
        ISqlConnectionFactory db, string? userId, string? month, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var rows = await connection.QueryAsync(new CommandDefinition(
            """
            SELECT * FROM fin.vw_CommissionSummary
            WHERE (@UserId IS NULL OR UserId = @UserId)
              AND (@Month  IS NULL OR PeriodMonth = @Month)
            ORDER BY EarnedH DESC;
            """,
            new { UserId = userId, Month = month }, cancellationToken: ct));

        return Results.Ok(rows);
    }
}
