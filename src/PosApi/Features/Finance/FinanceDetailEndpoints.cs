using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Localization;

namespace PosApi.Features.Finance;

public sealed record JournalLineDto(
    long JournalLineId,
    string AccountCode,
    string AccountNameAr,
    string AccountNameEn,
    string AccountName,
    string AccountType,
    long DebitH,
    long CreditH,
    string Memo);

/// <summary>
/// A journal entry with its lines. The header fields carry the names GET
/// /api/finance/ledger rows already use (<c>entryId</c>, <c>postedAtUtc</c>,
/// …), so one mapper reads both.
/// </summary>
public sealed record JournalEntryDto(
    string EntryId,
    string Reference,
    string Kind,
    string? SourceReference,
    string? DescriptionAr,
    string DescriptionEn,
    DateTime PostedAtUtc,
    string? BranchId,
    string Actor,
    long TotalDebitH,
    long TotalCreditH,
    string? ReversesEntryId,
    string? ReversedByEntryId,
    string? ReversalReason,
    IReadOnlyList<JournalLineDto> Lines);

public sealed record CommissionEntryDto(
    string Id,
    string SaleId,
    string InvoiceNumber,
    string UserId,
    string UserNameAr,
    string UserNameEn,
    string ItemId,
    string ItemNameAr,
    string ItemNameEn,
    long LineGrossH,
    long AmountH,
    string Basis,
    int RateAtSale,
    string? BranchId,
    DateTime EarnedAt,
    string PeriodMonth,
    string? PayrollRunId,
    bool Paid,
    string SaleStatus);

public sealed record PostOpeningBalancesRequest(
    string? BranchId,
    DateOnly? AsOf,
    long CashH,
    long BankH,
    long InventoryH,
    long ReceivablesH,
    long PayablesH,
    long VatH,
    string? Note);

public sealed record OpeningBalanceDto(
    string OpeningId,
    string? BranchId,
    DateOnly AsOf,
    long CashH,
    long BankH,
    long InventoryH,
    long ReceivablesH,
    long PayablesH,
    long VatH,
    long AssetsH,
    long LiabilitiesH,
    long EquityH,
    string EntryId,
    string Reference,
    string Status,
    string? ReversedByEntryId,
    string Note,
    DateTime PostedAt,
    string Actor);

/// <summary>
/// The opening position for one scope. <c>Posted</c> is true while a posting
/// stands (its entry not reversed); its figures are then repeated at the top
/// level so the screen reads them directly. <c>History</c> lists every
/// posting for the scope, reversed ones included, newest first.
/// </summary>
public sealed record OpeningBalancesResponse(
    bool Posted,
    string? BranchId,
    OpeningBalanceDto? Current,
    string? OpeningId,
    DateOnly? AsOf,
    long? CashH,
    long? BankH,
    long? InventoryH,
    long? ReceivablesH,
    long? PayablesH,
    long? VatH,
    long? EquityH,
    string? EntryId,
    DateTime? PostedAt,
    string? Actor,
    IReadOnlyList<OpeningBalanceDto> History);

public static class FinanceDetailEndpoints
{
    public static void MapFinanceDetailEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/finance")
            .WithTags("Finance")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/ledger/{entryId}", EntryAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.ledger"));

        group.MapGet("/commission/entries", CommissionEntriesAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.commission"));

        group.MapGet("/opening-balances", OpeningBalancesAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.view"));

        group.MapPost("/opening-balances", PostOpeningBalancesAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.opening_balances"));
    }

    /*--------------------------------------------------------------- ledger */

    private static async Task<IResult> EntryAsync(
        string entryId, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, CancellationToken ct)
    {
        await using var connection = db.Create();

        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT EntryId, Reference, Kind, SourceReference, DescriptionAr, DescriptionEn, PostedAtUtc,
                   BranchId, Actor, TotalDebitH, TotalCreditH, ReversesEntryId, ReversedByEntryId, ReversalReason
            FROM fin.JournalEntry WHERE EntryId = @EntryId;

            SELECT l.JournalLineId, l.AccountCode, a.NameAr, a.NameEn, a.AccountType, l.DebitH, l.CreditH, l.Memo
            FROM fin.JournalLine AS l
            JOIN fin.Account AS a ON a.AccountCode = l.AccountCode
            WHERE l.EntryId = @EntryId
            ORDER BY CASE WHEN l.DebitH > 0 THEN 0 ELSE 1 END, l.JournalLineId;
            """,
            new { EntryId = entryId }, cancellationToken: ct));

        var e = await multi.ReadSingleOrDefaultAsync<EntryRow>();
        if (e is null) return ProcErrors.NotFound("Journal entry not found.", "القيد غير موجود.");
        if (!current.CanSeeBranch(e.BranchId)) return Results.Forbid();

        var lines = (await multi.ReadAsync<LineRow>()).Select(l => new JournalLineDto(
            l.JournalLineId, l.AccountCode, l.NameAr, l.NameEn, language.Pick(l.NameAr, l.NameEn),
            l.AccountType, l.DebitH, l.CreditH, l.Memo ?? string.Empty)).ToList();

        return Results.Ok(new JournalEntryDto(
            e.EntryId, e.Reference, e.Kind, e.SourceReference, e.DescriptionAr, e.DescriptionEn,
            e.PostedAtUtc, e.BranchId, e.Actor, e.TotalDebitH, e.TotalCreditH,
            e.ReversesEntryId, e.ReversedByEntryId, e.ReversalReason, lines));
    }

    /*----------------------------------------------------------- commission */

    /// <summary>
    /// The commission rows behind the summary: one per service line sold,
    /// frozen at the sale. Filters: userId, month (YYYY-MM), saleId,
    /// branchId, paid.
    /// </summary>
    private static async Task<IResult> CommissionEntriesAsync(
        ISqlConnectionFactory db, ICurrentUser current,
        string? userId, string? month, string? saleId, string? branchId, bool? paid,
        CancellationToken ct = default)
    {
        var branch = ProcErrors.Blank(branchId);
        if (!current.CanSeeBranch(branch)) return Results.Forbid();

        await using var connection = db.Create();

        var rows = await connection.QueryAsync<CommissionRow>(new CommandDefinition(
            """
            SELECT TOP (2000)
                   e.CommissionId, e.SaleId, e.InvoiceNumber, e.UserId, u.NameAr AS UserNameAr, u.NameEn AS UserNameEn,
                   e.ItemId, e.ItemNameAr, e.ItemNameEn, e.LineGrossH, e.AmountH, e.Basis, e.RateAtSale,
                   e.BranchId, e.EarnedAtUtc, CONVERT(CHAR(7), e.EarnedAtUtc, 126) AS PeriodMonth,
                   e.PayrollRunId, s.Status AS SaleStatus
            FROM fin.CommissionEntry AS e
            JOIN core.AppUser AS u ON u.UserId = e.UserId
            JOIN sales.Sale AS s ON s.SaleId = e.SaleId
            WHERE (@UserId IS NULL OR e.UserId = @UserId)
              AND (@Month IS NULL OR CONVERT(CHAR(7), e.EarnedAtUtc, 126) = @Month)
              AND (@SaleId IS NULL OR e.SaleId = @SaleId)
              AND (@BranchId IS NULL OR e.BranchId = @BranchId)
              AND (@Paid IS NULL OR (@Paid = 1 AND e.PayrollRunId IS NOT NULL)
                                 OR (@Paid = 0 AND e.PayrollRunId IS NULL))
            ORDER BY e.EarnedAtUtc DESC;
            """,
            new
            {
                UserId = ProcErrors.Blank(userId),
                Month = ProcErrors.Blank(month),
                SaleId = ProcErrors.Blank(saleId),
                BranchId = branch,
                Paid = paid
            },
            cancellationToken: ct));

        return Results.Ok(rows.Select(r => new CommissionEntryDto(
            r.CommissionId, r.SaleId, r.InvoiceNumber, r.UserId, r.UserNameAr, r.UserNameEn,
            r.ItemId, r.ItemNameAr, r.ItemNameEn, r.LineGrossH, r.AmountH, r.Basis, r.RateAtSale,
            r.BranchId, r.EarnedAtUtc, r.PeriodMonth, r.PayrollRunId, r.PayrollRunId is not null,
            r.SaleStatus)).ToList());
    }

    /*----------------------------------------------------- opening balances */

    /// <summary><c>branchId</c> omitted = the whole business.</summary>
    private static async Task<IResult> OpeningBalancesAsync(
        ISqlConnectionFactory db, ICurrentUser current, string? branchId, CancellationToken ct)
    {
        var branch = ProcErrors.Blank(branchId);
        if (!current.CanSeeBranch(branch)) return Results.Forbid();

        await using var connection = db.Create();
        return Results.Ok(await LoadOpeningAsync(connection, branch, ct));
    }

    /// <summary>
    /// Post the opening position as one entry (fin.usp_PostOpeningBalances).
    /// Refused with 409 while a posting for the same scope stands; reverse
    /// its entry to correct it.
    /// </summary>
    private static async Task<IResult> PostOpeningBalancesAsync(
        PostOpeningBalancesRequest request, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct)
    {
        var branch = ProcErrors.Blank(request.BranchId);
        if (!current.CanSeeBranch(branch)) return Results.Forbid();

        var negative = new (string Field, long Value)[]
        {
            ("cashH", request.CashH), ("bankH", request.BankH), ("inventoryH", request.InventoryH),
            ("receivablesH", request.ReceivablesH), ("payablesH", request.PayablesH)
        }.FirstOrDefault(f => f.Value < 0);

        if (negative.Field is not null)
            return ProcErrors.Field(negative.Field, "Opening balances cannot be negative.", "لا يمكن أن تكون الأرصدة الافتتاحية سالبة.");

        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branch);
        parameters.Add("@AsOf", request.AsOf);
        parameters.Add("@CashH", request.CashH);
        parameters.Add("@BankH", request.BankH);
        parameters.Add("@InventoryH", request.InventoryH);
        parameters.Add("@ReceivablesH", request.ReceivablesH);
        parameters.Add("@PayablesH", request.PayablesH);
        parameters.Add("@VatH", request.VatH);
        parameters.Add("@Note", ProcErrors.Blank(request.Note));
        parameters.Add("@Actor", current.Username);
        parameters.Add("@OpeningId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);
        parameters.Add("@EntryId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_PostOpeningBalances", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapOpeningError(ex) is { } mapped)
        {
            return mapped;
        }

        var openingId = parameters.Get<string>("@OpeningId");

        logger.LogInformation("Opening balances {OpeningId} posted for {Scope} by {Actor}.",
            openingId, branch ?? "business", current.Username);
        http.Items["AuditEntityId"] = openingId;

        return Results.Created("/api/finance/opening-balances", await LoadOpeningAsync(connection, branch, ct));
    }

    private static IResult? MapOpeningError(SqlException ex) => ex.Number switch
    {
        70000 => ProcErrors.Conflict("already_posted",
            "Opening balances have already been posted. Reverse the entry in the ledger to correct them.",
            "تم ترحيل الأرصدة الافتتاحية مسبقًا. اعكس القيد في دفتر اليومية لتصحيحها."),
        70001 => ProcErrors.Field("asOf", "Choose the date the balances are as of.", "اختر تاريخ الأرصدة."),
        70002 => ProcErrors.Field("cashH", "Opening balances cannot be negative.", "لا يمكن أن تكون الأرصدة الافتتاحية سالبة."),
        70003 => ProcErrors.Field("branchId", "Unknown branch.", "فرع غير معروف."),
        70004 => Results.UnprocessableEntity(ApiError.Create("nothing_to_post",
            "Enter at least one opening figure.", "أدخل رصيدًا افتتاحيًا واحدًا على الأقل.")),
        _ => null
    };

    private static async Task<OpeningBalancesResponse> LoadOpeningAsync(
        SqlConnection connection, string? branchId, CancellationToken ct)
    {
        var rows = (await connection.QueryAsync<OpeningRow>(new CommandDefinition(
            """
            SELECT o.OpeningId, o.BranchId, o.AsOf, o.CashH, o.BankH, o.InventoryH, o.ReceivablesH,
                   o.PayablesH, o.VatH, o.EquityH, o.EntryId, e.Reference, e.ReversedByEntryId,
                   o.Note, o.PostedAtUtc, o.PostedBy
            FROM fin.OpeningBalance AS o
            JOIN fin.JournalEntry AS e ON e.EntryId = o.EntryId
            WHERE ISNULL(o.BranchId, N'') = ISNULL(@BranchId, N'')
            ORDER BY o.PostedAtUtc DESC;
            """,
            new { BranchId = branchId }, cancellationToken: ct))).ToList();

        var history = rows.Select(r =>
        {
            var assets = r.CashH + r.BankH + r.InventoryH + r.ReceivablesH + Math.Max(0, -r.VatH);
            var liabilities = r.PayablesH + Math.Max(0, r.VatH);
            return new OpeningBalanceDto(
                r.OpeningId, r.BranchId, r.AsOf, r.CashH, r.BankH, r.InventoryH, r.ReceivablesH,
                r.PayablesH, r.VatH, assets, liabilities, r.EquityH, r.EntryId, r.Reference,
                r.ReversedByEntryId is null ? "posted" : "reversed", r.ReversedByEntryId,
                r.Note ?? string.Empty, r.PostedAtUtc, r.PostedBy);
        }).ToList();

        var c = history.FirstOrDefault(h => h.Status == "posted");

        return new OpeningBalancesResponse(
            c is not null, branchId, c, c?.OpeningId, c?.AsOf, c?.CashH, c?.BankH, c?.InventoryH,
            c?.ReceivablesH, c?.PayablesH, c?.VatH, c?.EquityH, c?.EntryId, c?.PostedAt, c?.Actor, history);
    }

    /*----------------------------------------------------------------- rows */

    private sealed record EntryRow
    {
        public string EntryId { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public string Kind { get; init; } = string.Empty;
        public string? SourceReference { get; init; }
        public string? DescriptionAr { get; init; }
        public string DescriptionEn { get; init; } = string.Empty;
        public DateTime PostedAtUtc { get; init; }
        public string? BranchId { get; init; }
        public string Actor { get; init; } = string.Empty;
        public long TotalDebitH { get; init; }
        public long TotalCreditH { get; init; }
        public string? ReversesEntryId { get; init; }
        public string? ReversedByEntryId { get; init; }
        public string? ReversalReason { get; init; }
    }

    private sealed record LineRow
    {
        public long JournalLineId { get; init; }
        public string AccountCode { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string AccountType { get; init; } = string.Empty;
        public long DebitH { get; init; }
        public long CreditH { get; init; }
        public string? Memo { get; init; }
    }

    private sealed record CommissionRow
    {
        public string CommissionId { get; init; } = string.Empty;
        public string SaleId { get; init; } = string.Empty;
        public string InvoiceNumber { get; init; } = string.Empty;
        public string UserId { get; init; } = string.Empty;
        public string UserNameAr { get; init; } = string.Empty;
        public string UserNameEn { get; init; } = string.Empty;
        public string ItemId { get; init; } = string.Empty;
        public string ItemNameAr { get; init; } = string.Empty;
        public string ItemNameEn { get; init; } = string.Empty;
        public long LineGrossH { get; init; }
        public long AmountH { get; init; }
        public string Basis { get; init; } = string.Empty;
        public int RateAtSale { get; init; }
        public string? BranchId { get; init; }
        public DateTime EarnedAtUtc { get; init; }
        public string PeriodMonth { get; init; } = string.Empty;
        public string? PayrollRunId { get; init; }
        public string SaleStatus { get; init; } = string.Empty;
    }

    private sealed record OpeningRow
    {
        public string OpeningId { get; init; } = string.Empty;
        public string? BranchId { get; init; }
        public DateOnly AsOf { get; init; }
        public long CashH { get; init; }
        public long BankH { get; init; }
        public long InventoryH { get; init; }
        public long ReceivablesH { get; init; }
        public long PayablesH { get; init; }
        public long VatH { get; init; }
        public long EquityH { get; init; }
        public string EntryId { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public string? ReversedByEntryId { get; init; }
        public string? Note { get; init; }
        public DateTime PostedAtUtc { get; init; }
        public string PostedBy { get; init; } = string.Empty;
    }
}
