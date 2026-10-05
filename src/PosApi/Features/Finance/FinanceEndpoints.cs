using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Localization;

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
    /// number on the screen can be traced to the entries behind it. The
    /// payment mix and refunds are the exception: they describe how sales
    /// were tendered, which lives on the sale.
    ///
    /// Branch scoping: with no <c>branchId</c> the figures cover every entry.
    /// With one, the top-level figures cover only entries tagged to that
    /// branch, and entries with no branch (business-wide costs such as rent
    /// or payroll recorded without a branch) are reported separately under
    /// <c>businessWide</c> — never folded into every branch's figures.
    /// </summary>
    private static async Task<IResult> SummaryAsync(
        ISqlConnectionFactory db, ICurrentUser current, ILanguageContext language,
        string? branchId, string? month, CancellationToken ct = default)
    {
        var period = string.IsNullOrWhiteSpace(month)
            ? DateTime.UtcNow.ToString("yyyy-MM")
            : month.Trim();

        if (!DateOnly.TryParseExact(period + "-01", "yyyy-MM-dd", out _))
            return ProcErrors.Field("month", "Months are YYYY-MM.", "الشهر بصيغة YYYY-MM.");

        var branch = ProcErrors.Blank(branchId);
        if (!current.CanSeeBranch(branch)) return Results.Forbid();

        await using var connection = db.Create();

        const string sql = """
            DECLARE @Start DATE = CAST(@Period + '-01' AS DATE);
            DECLARE @Next  DATE = DATEADD(MONTH, 1, @Start);

            -- 1. Per account, per scope: the month's movement and the all-time balance.
            SELECT
                CASE WHEN e.BranchId IS NULL THEN N'business' ELSE N'branch' END AS Scope,
                l.AccountCode,
                SUM(CASE WHEN e.PostedAtUtc >= @Start AND e.PostedAtUtc < @Next THEN l.DebitH  ELSE 0 END) AS PeriodDebitH,
                SUM(CASE WHEN e.PostedAtUtc >= @Start AND e.PostedAtUtc < @Next THEN l.CreditH ELSE 0 END) AS PeriodCreditH,
                SUM(CASE WHEN e.PostedAtUtc >= @Start AND e.PostedAtUtc < @Next AND e.Kind = N'return'
                         THEN l.DebitH - l.CreditH ELSE 0 END) AS PeriodReturnNetH,
                SUM(l.DebitH)  AS TotalDebitH,
                SUM(l.CreditH) AS TotalCreditH
            FROM fin.JournalEntry AS e
            JOIN fin.JournalLine  AS l ON l.EntryId = e.EntryId
            WHERE (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
            GROUP BY CASE WHEN e.BranchId IS NULL THEN N'business' ELSE N'branch' END, l.AccountCode;

            -- 2. Operating expense accounts, for the per-account split.
            SELECT AccountCode, NameAr, NameEn FROM fin.Account
            WHERE AccountType = N'expense' AND AccountCode <> N'5100'
            ORDER BY AccountCode;

            -- 3. How the month's sales were tendered (voided sales excluded).
            SELECT p.Method, SUM(p.AmountH) AS AmountH
            FROM sales.SalePayment AS p
            JOIN sales.Sale AS s ON s.SaleId = p.SaleId
            WHERE s.Status <> N'voided' AND s.SoldAtUtc >= @Start AND s.SoldAtUtc < @Next
              AND (@BranchId IS NULL OR s.BranchId = @BranchId)
            GROUP BY p.Method;

            SELECT ISNULL(SUM(s.ChangeH), 0) AS ChangeH, COUNT(*) AS SaleCount
            FROM sales.Sale AS s
            WHERE s.Status <> N'voided' AND s.SoldAtUtc >= @Start AND s.SoldAtUtc < @Next
              AND (@BranchId IS NULL OR s.BranchId = @BranchId);

            -- 4. Refunds on credit notes issued in the month.
            SELECT ISNULL(r.RefundMethod, N'cash') AS Method, SUM(r.RefundH) AS AmountH, COUNT(*) AS NoteCount
            FROM sales.SaleReturn AS r
            WHERE r.ReturnedAtUtc >= @Start AND r.ReturnedAtUtc < @Next
              AND (@BranchId IS NULL OR r.BranchId = @BranchId)
            GROUP BY ISNULL(r.RefundMethod, N'cash');

            -- 5. Cost sold that the ledger does not carry, per scope: each
            --    sale's (and credit note's) line cost less what its own entry
            --    put through 5100. Today that is services and untracked items,
            --    whose cost never moves stock and so is never posted.
            SELECT Scope, SUM(CostH) AS CostH
            FROM (
                SELECT CASE WHEN s.BranchId IS NULL THEN N'business' ELSE N'branch' END AS Scope,
                       ISNULL(lc.CostH, 0) - ISNULL(gl.PostedH, 0) AS CostH
                FROM sales.Sale AS s
                OUTER APPLY (SELECT SUM(CAST(ROUND(l.UnitCostH * l.Quantity, 0) AS BIGINT)) AS CostH
                             FROM sales.SaleLine AS l WHERE l.SaleId = s.SaleId) AS lc
                OUTER APPLY (SELECT SUM(jl.DebitH - jl.CreditH) AS PostedH
                             FROM fin.JournalEntry AS je
                             JOIN fin.JournalLine AS jl ON jl.EntryId = je.EntryId AND jl.AccountCode = N'5100'
                             WHERE je.Kind = N'sale' AND je.SourceReference = s.InvoiceNumber
                               AND je.ReversesEntryId IS NULL) AS gl
                WHERE s.Status <> N'voided' AND s.SoldAtUtc >= @Start AND s.SoldAtUtc < @Next
                  AND (@BranchId IS NULL OR s.BranchId = @BranchId OR s.BranchId IS NULL)

                UNION ALL

                SELECT CASE WHEN r.BranchId IS NULL THEN N'business' ELSE N'branch' END,
                       -(ISNULL(rc.CostH, 0) - ISNULL(gl.PostedH, 0))
                FROM sales.SaleReturn AS r
                OUTER APPLY (SELECT SUM(CAST(ROUND(rl.UnitCostH * rl.Quantity, 0) AS BIGINT)) AS CostH
                             FROM sales.SaleReturnLine AS rl WHERE rl.ReturnId = r.ReturnId) AS rc
                OUTER APPLY (SELECT SUM(jl.CreditH - jl.DebitH) AS PostedH
                             FROM fin.JournalLine AS jl
                             WHERE jl.EntryId = r.EntryId AND jl.AccountCode = N'5100') AS gl
                WHERE r.ReturnedAtUtc >= @Start AND r.ReturnedAtUtc < @Next
                  AND (@BranchId IS NULL OR r.BranchId = @BranchId OR r.BranchId IS NULL)
            ) AS c
            GROUP BY Scope;
            """;

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(sql,
            new { Period = period, BranchId = branch }, cancellationToken: ct));

        var accounts = (await multi.ReadAsync<SummaryAccountRow>()).ToList();
        var expenseAccounts = (await multi.ReadAsync<(string AccountCode, string NameAr, string NameEn)>()).ToList();
        var tendered = (await multi.ReadAsync<(string Method, long AmountH)>()).ToDictionary(r => r.Method, r => r.AmountH);
        var sales = await multi.ReadSingleAsync<(long ChangeH, int SaleCount)>();
        var refunds = (await multi.ReadAsync<(string Method, long AmountH, int NoteCount)>()).ToList();
        var offLedgerCost = (await multi.ReadAsync<(string Scope, long CostH)>()).ToList();

        /*
         * Gross profit — the one rule every screen uses (the dashboard's
         * GET /api/sales/analytics computes the same thing from the sales):
         *
         *   net revenue  = sales excluding VAT, less returns excluding VAT
         *                  (4100 credits less its return debits)
         *   cost of sales = cost of the goods AND services sold, less the cost
         *                  of what came back (5100, plus the line cost of
         *                  services and untracked items, which the ledger
         *                  never posts — query 5)
         *   gross profit = net revenue − cost of sales
         *   gross margin = gross profit ÷ net revenue (never the VAT-inclusive price)
         */
        SummaryFigures Figures(Func<SummaryAccountRow, bool> inScope, Func<string, bool> scopeMatches)
        {
            var rows = accounts.Where(inScope).ToList();

            long Period(string code, bool debitNormal) => rows.Where(r => r.AccountCode == code)
                .Sum(r => debitNormal ? r.PeriodDebitH - r.PeriodCreditH : r.PeriodCreditH - r.PeriodDebitH);

            long Balance(bool debitNormal, params string[] codes) => rows.Where(r => codes.Contains(r.AccountCode))
                .Sum(r => debitNormal ? r.TotalDebitH - r.TotalCreditH : r.TotalCreditH - r.TotalDebitH);

            var byAccount = expenseAccounts.Select(a => new ExpenseAccountAmount(
                a.AccountCode, a.NameAr, a.NameEn, language.Pick(a.NameAr, a.NameEn),
                Period(a.AccountCode, true))).ToList();

            var revenueH = Period("4100", false);
            var goodsCostH = Period("5100", true);
            var serviceCostH = offLedgerCost.Where(c => scopeMatches(c.Scope)).Sum(c => c.CostH);
            var cogsH = goodsCostH + serviceCostH;
            var grossProfitH = revenueH - cogsH;

            return new SummaryFigures(
                revenueH,
                rows.Where(r => r.AccountCode == "4100").Sum(r => r.PeriodReturnNetH),
                cogsH,
                goodsCostH,
                serviceCostH,
                grossProfitH,
                revenueH > 0 ? Math.Round((decimal)grossProfitH / revenueH, 4) : null,
                byAccount.Sum(a => a.AmountH),
                byAccount,
                Balance(true, "1000", "1100"),
                Balance(true, "1400"),
                Balance(false, "2000"),
                Balance(true, "1500"),
                Balance(true, "1150"));
        }

        var top = Figures(r => branch is null || r.Scope == "branch", scope => branch is null || scope == "branch");

        long Tender(string method) => tendered.TryGetValue(method, out var v) ? v : 0;
        long Refund(string method) => refunds.Where(r => r.Method == method).Sum(r => r.AmountH);

        var cashNet = Math.Max(0, Tender("cash") - sales.ChangeH);

        return Results.Ok(new
        {
            period,
            branchId = branch,
            revenueH = top.RevenueH,
            returnsH = top.ReturnsH,
            cogsH = top.CogsH,
            goodsCostH = top.GoodsCostH,
            serviceCostH = top.ServiceCostH,
            grossProfitH = top.GrossProfitH,
            grossMargin = top.GrossMargin,
            expensesH = top.ExpensesH,
            expensesByAccount = top.ExpensesByAccount,
            cashH = top.CashH,
            receivableH = top.ReceivableH,
            payableH = top.PayableH,
            prepaidH = top.PrepaidH,
            cardClearingH = top.CardClearingH,
            paymentMix = new
            {
                cashH = cashNet,
                cardH = Tender("card"),
                creditH = Tender("credit"),
                bankH = Tender("bank"),
                totalH = cashNet + Tender("card") + Tender("credit") + Tender("bank"),
                saleCount = sales.SaleCount
            },
            refunds = new
            {
                cashH = Refund("cash"),
                cardH = Refund("card"),
                creditH = Refund("credit"),
                bankH = Refund("bank"),
                totalH = refunds.Sum(r => r.AmountH),
                noteCount = refunds.Sum(r => r.NoteCount)
            },
            businessWide = branch is null ? null : Figures(r => r.Scope == "business", scope => scope == "business")
        });
    }

    public sealed record ExpenseAccountAmount(
        string AccountCode, string NameAr, string NameEn, string Name, long AmountH);

    /// <summary>One scope's figures: period movement for P&amp;L lines, all-time balances for the rest.</summary>
    public sealed record SummaryFigures(
        long RevenueH,
        long ReturnsH,
        /// <summary>Cost of goods and services sold: <c>GoodsCostH + ServiceCostH</c>.</summary>
        long CogsH,
        /// <summary>5100, as posted for stocked goods.</summary>
        long GoodsCostH,
        /// <summary>Line cost of services and untracked items, net of returns; not in the ledger.</summary>
        long ServiceCostH,
        long GrossProfitH,
        decimal? GrossMargin,
        long ExpensesH,
        IReadOnlyList<ExpenseAccountAmount> ExpensesByAccount,
        long CashH,
        long ReceivableH,
        long PayableH,
        long PrepaidH,
        long CardClearingH);

    private sealed record SummaryAccountRow
    {
        public string Scope { get; init; } = string.Empty;
        public string AccountCode { get; init; } = string.Empty;
        public long PeriodDebitH { get; init; }
        public long PeriodCreditH { get; init; }
        public long PeriodReturnNetH { get; init; }
        public long TotalDebitH { get; init; }
        public long TotalCreditH { get; init; }
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
