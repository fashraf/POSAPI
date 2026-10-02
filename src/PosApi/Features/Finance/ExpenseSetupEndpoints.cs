using System.Data;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Localization;

namespace PosApi.Features.Finance;

/// <summary>
/// An expense category. Keeps the names GET /api/expenses/categories always
/// returned (<c>categoryId</c>, <c>nameAr</c>, <c>nameEn</c>,
/// <c>accountCode</c>) and adds the rest.
/// </summary>
public sealed record ExpenseCategoryDto(
    string CategoryId,
    string NameAr,
    string NameEn,
    string Name,
    string AccountCode,
    string AccountNameAr,
    string AccountNameEn,
    bool IsActive,
    string Status,
    int ExpenseCount,
    int RecurringCount,
    DateTime CreatedAt,
    DateTime UpdatedAt);

public sealed record SaveExpenseCategoryRequest(
    string NameAr,
    string NameEn,
    string AccountCode,
    string? Status);

/// <summary>
/// A recurring schedule. <c>Description</c> fills <c>descriptionEn</c> when
/// that is not sent; <c>descriptionAr</c> defaults to the English text.
/// </summary>
public sealed record SaveRecurringRequest(
    string? Description,
    string? DescriptionEn,
    string? DescriptionAr,
    string CategoryId,
    string? BranchId,
    long AmountH,
    string Frequency,
    DateOnly? NextDueOn,
    string? PaymentMethod,
    string? Note,
    string? Status);

public sealed record SetRecurringStatusRequest(string Status);

public static partial class ExpenseSetupEndpoints
{
    public static void MapExpenseSetupEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/expenses")
            .WithTags("Expenses")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/categories", CategoriesAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapPost("/categories", CreateCategoryAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapPut("/categories/{categoryId}", UpdateCategoryAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapGet("/recurring", RecurringAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapGet("/recurring/{recurringId}", RecurringOneAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapPost("/recurring", CreateRecurringAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapPut("/recurring/{recurringId}", UpdateRecurringAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapPatch("/recurring/{recurringId}/status", SetRecurringStatusAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));

        group.MapGet("/recognition", RecognitionAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.expenses"));
    }

    [GeneratedRegex(@"^\d{4}-(0[1-9]|1[0-2])$")]
    private static partial Regex MonthPattern();

    /*---------------------------------------------------------- categories */

    /// <summary>Active categories; <c>includeInactive=true</c> for all.</summary>
    private static async Task<IResult> CategoriesAsync(
        ISqlConnectionFactory db, ILanguageContext language, bool? includeInactive, CancellationToken ct)
    {
        await using var connection = db.Create();
        return Results.Ok(await LoadCategoriesAsync(connection, null, includeInactive ?? false, language, ct));
    }

    private static Task<IResult> CreateCategoryAsync(
        SaveExpenseCategoryRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveCategoryAsync(null, request, db, current, language, http, logger, ct);

    private static Task<IResult> UpdateCategoryAsync(
        string categoryId, SaveExpenseCategoryRequest request, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveCategoryAsync(categoryId, request, db, current, language, http, logger, ct);

    private static async Task<IResult> SaveCategoryAsync(
        string? categoryId,
        SaveExpenseCategoryRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (request.Status is not (null or "active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        var parameters = new DynamicParameters();
        parameters.Add("@CategoryId", categoryId);
        parameters.Add("@NameAr", request.NameAr?.Trim());
        parameters.Add("@NameEn", request.NameEn?.Trim());
        parameters.Add("@AccountCode", request.AccountCode?.Trim());
        parameters.Add("@IsActive", request.Status is null ? (bool?)null : request.Status == "active");
        parameters.Add("@Actor", current.Username);
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_SaveExpenseCategory", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapError(ex, request.NameAr) is { } mapped)
        {
            return mapped;
        }

        var savedId = parameters.Get<string>("@SavedId");

        logger.LogInformation("Expense category {CategoryId} {Action} by {Actor}.",
            savedId, categoryId is null ? "created" : "updated", current.Username);
        http.Items["AuditEntityId"] = savedId;

        var category = (await LoadCategoriesAsync(connection, savedId, true, language, ct)).Single();

        return categoryId is null
            ? Results.Created($"/api/expenses/categories/{savedId}", category)
            : Results.Ok(category);
    }

    private static async Task<List<ExpenseCategoryDto>> LoadCategoriesAsync(
        SqlConnection connection, string? categoryId, bool includeInactive,
        ILanguageContext language, CancellationToken ct)
    {
        var rows = await connection.QueryAsync<CategoryRow>(new CommandDefinition(
            """
            SELECT c.CategoryId, c.NameAr, c.NameEn, c.AccountCode,
                   a.NameAr AS AccountNameAr, a.NameEn AS AccountNameEn,
                   c.IsActive, c.CreatedAtUtc, c.UpdatedAtUtc,
                   (SELECT COUNT(*) FROM fin.Expense AS e WHERE e.CategoryId = c.CategoryId) AS ExpenseCount,
                   (SELECT COUNT(*) FROM fin.RecurringPayment AS r WHERE r.CategoryId = c.CategoryId) AS RecurringCount
            FROM fin.ExpenseCategory AS c
            JOIN fin.Account AS a ON a.AccountCode = c.AccountCode
            WHERE (@CategoryId IS NULL OR c.CategoryId = @CategoryId)
              AND (@IncludeInactive = 1 OR c.IsActive = 1)
            ORDER BY c.NameEn;
            """,
            new { CategoryId = categoryId, IncludeInactive = includeInactive }, cancellationToken: ct));

        return rows.Select(r => new ExpenseCategoryDto(
            r.CategoryId, r.NameAr, r.NameEn, language.Pick(r.NameAr, r.NameEn), r.AccountCode,
            r.AccountNameAr, r.AccountNameEn, r.IsActive, r.IsActive ? "active" : "inactive",
            r.ExpenseCount, r.RecurringCount, r.CreatedAtUtc, r.UpdatedAtUtc)).ToList();
    }

    /*----------------------------------------------------------- recurring */

    /// <summary>
    /// The schedules, soonest due first. Every route here returns rows of this
    /// one shape, so a save reads back the same way the list does.
    /// </summary>
    private const string RecurringSelect = """
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
        """;

    private static async Task<IResult> RecurringAsync(
        ISqlConnectionFactory db, string? branchId, CancellationToken ct = default)
    {
        await using var connection = db.Create();

        // Urgency is derived here rather than stored, so a payment that becomes
        // overdue overnight reads as overdue with nothing to refresh.
        var rows = await connection.QueryAsync(new CommandDefinition(
            $"""
            {RecurringSelect}
            WHERE (@BranchId IS NULL OR r.BranchId = @BranchId OR r.BranchId IS NULL)
            ORDER BY r.NextDueOn;
            """,
            new { BranchId = branchId }, cancellationToken: ct));

        return Results.Ok(rows);
    }

    private static async Task<IResult> RecurringOneAsync(
        string recurringId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();
        var row = await LoadRecurringAsync(connection, recurringId, ct);
        return row is null ? RecurringNotFound() : Results.Ok(row);
    }

    private static Task<dynamic?> LoadRecurringAsync(SqlConnection connection, string recurringId, CancellationToken ct) =>
        connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            $"{RecurringSelect} WHERE r.RecurringId = @RecurringId;",
            new { RecurringId = recurringId }, cancellationToken: ct));

    private static Task<IResult> CreateRecurringAsync(
        SaveRecurringRequest request, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveRecurringAsync(null, request, db, current, http, logger, ct);

    private static Task<IResult> UpdateRecurringAsync(
        string recurringId, SaveRecurringRequest request, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveRecurringAsync(recurringId, request, db, current, http, logger, ct);

    /// <summary>Through fin.usp_SaveRecurringPayment. Posts nothing.</summary>
    private static async Task<IResult> SaveRecurringAsync(
        string? recurringId,
        SaveRecurringRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        var branchId = ProcErrors.Blank(request.BranchId);
        if (!current.CanSeeBranch(branchId)) return Results.Forbid();

        var parameters = new DynamicParameters();
        parameters.Add("@RecurringId", recurringId);
        parameters.Add("@DescriptionEn", ProcErrors.Blank(request.DescriptionEn) ?? ProcErrors.Blank(request.Description));
        parameters.Add("@DescriptionAr", ProcErrors.Blank(request.DescriptionAr));
        parameters.Add("@CategoryId", request.CategoryId);
        parameters.Add("@BranchId", branchId);
        parameters.Add("@AmountH", request.AmountH);
        parameters.Add("@Frequency", request.Frequency?.Trim().ToLowerInvariant());
        parameters.Add("@NextDueOn", request.NextDueOn);
        parameters.Add("@PaymentMethod", ProcErrors.Blank(request.PaymentMethod)?.ToLowerInvariant() ?? "bank");
        parameters.Add("@Note", ProcErrors.Blank(request.Note));
        parameters.Add("@Status", ProcErrors.Blank(request.Status));
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_SaveRecurringPayment", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapError(ex, null) is { } mapped)
        {
            return mapped;
        }

        var savedId = parameters.Get<string>("@SavedId");

        logger.LogInformation("Recurring payment {RecurringId} {Action} by {Actor}.",
            savedId, recurringId is null ? "created" : "updated", current.Username);
        http.Items["AuditEntityId"] = savedId;

        var row = await LoadRecurringAsync(connection, savedId, ct);

        return recurringId is null
            ? Results.Created($"/api/expenses/recurring/{savedId}", row)
            : Results.Ok(row);
    }

    /// <summary>Pause or resume: {"status": "active" | "paused"}.</summary>
    private static async Task<IResult> SetRecurringStatusAsync(
        string recurringId, SetRecurringStatusRequest request, ISqlConnectionFactory db,
        ICurrentUser current, HttpContext http, ILogger<Program> logger, CancellationToken ct)
    {
        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_SetRecurringStatus",
                new { RecurringId = recurringId, Status = request.Status?.Trim().ToLowerInvariant() },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapError(ex, null) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Recurring payment {RecurringId} set {Status} by {Actor}.",
            recurringId, request.Status, current.Username);
        http.Items["AuditEntityId"] = recurringId;

        return Results.Ok(await LoadRecurringAsync(connection, recurringId, ct));
    }

    /*--------------------------------------------------------- recognition */

    /// <summary>
    /// How much of each posted expense belongs to each month, net of VAT, as
    /// fin.usp_BuildExpenseRecognition split it. Reversed expenses are left
    /// out. <c>month</c> (YYYY-MM) or <c>from</c>/<c>to</c> months.
    ///
    /// With a <c>branchId</c>, rows for that branch and business-wide rows
    /// (branchId null) are both returned, each carrying its branchId, and the
    /// totals are given separately so they are never folded together.
    /// </summary>
    private static async Task<IResult> RecognitionAsync(
        ISqlConnectionFactory db, ICurrentUser current, ILanguageContext language,
        string? month, string? from, string? to, string? branchId, string? categoryId,
        CancellationToken ct = default)
    {
        var start = ProcErrors.Blank(month) ?? ProcErrors.Blank(from) ?? DateTime.UtcNow.ToString("yyyy-MM");
        var end = ProcErrors.Blank(month) ?? ProcErrors.Blank(to) ?? start;

        if (!MonthPattern().IsMatch(start) || !MonthPattern().IsMatch(end))
            return ProcErrors.Field("month", "Months are YYYY-MM.", "الشهر بصيغة YYYY-MM.");

        if (string.CompareOrdinal(end, start) < 0)
            return ProcErrors.Field("to", "The end month is before the start month.", "شهر النهاية يسبق شهر البداية.");

        var branch = ProcErrors.Blank(branchId);
        if (!current.CanSeeBranch(branch)) return Results.Forbid();

        await using var connection = db.Create();

        var rows = (await connection.QueryAsync<RecognitionRow>(new CommandDefinition(
            """
            SELECT r.PeriodMonth, r.AmountH, e.ExpenseId, e.Reference, e.CategoryId,
                   c.NameAr AS CategoryNameAr, c.NameEn AS CategoryNameEn, c.AccountCode,
                   e.BranchId, e.DescriptionEn, e.DescriptionAr, e.Recognition, e.PaymentMethod,
                   e.PaidOn, e.PeriodStart, e.PeriodEnd, e.AmountH AS ExpenseAmountH, e.VatH
            FROM fin.ExpenseRecognition AS r
            JOIN fin.Expense AS e ON e.ExpenseId = r.ExpenseId
            JOIN fin.ExpenseCategory AS c ON c.CategoryId = e.CategoryId
            WHERE e.Status = N'posted'
              AND r.PeriodMonth >= @Start AND r.PeriodMonth <= @End
              AND (@BranchId IS NULL OR e.BranchId = @BranchId OR e.BranchId IS NULL)
              AND (@CategoryId IS NULL OR e.CategoryId = @CategoryId)
            ORDER BY r.PeriodMonth, c.NameEn, e.PaidOn;
            """,
            new { Start = start, End = end, BranchId = branch, CategoryId = ProcErrors.Blank(categoryId) },
            cancellationToken: ct))).ToList();

        var items = rows.Select(r => new
        {
            month = r.PeriodMonth,
            amountH = r.AmountH,
            expenseId = r.ExpenseId,
            reference = r.Reference,
            categoryId = r.CategoryId,
            categoryNameAr = r.CategoryNameAr,
            categoryNameEn = r.CategoryNameEn,
            accountCode = r.AccountCode,
            branchId = r.BranchId,
            descriptionEn = r.DescriptionEn ?? string.Empty,
            descriptionAr = r.DescriptionAr ?? string.Empty,
            recognition = r.Recognition,
            paymentMethod = r.PaymentMethod,
            paidOn = r.PaidOn,
            periodStart = r.PeriodStart,
            periodEnd = r.PeriodEnd,
            expenseAmountH = r.ExpenseAmountH,
            vatH = r.VatH
        }).ToList();

        return Results.Ok(new
        {
            from = start,
            to = end,
            branchId = branch,
            totalH = rows.Sum(r => r.AmountH),
            branchTotalH = branch is null ? (long?)null : rows.Where(r => r.BranchId is not null).Sum(r => r.AmountH),
            businessWideTotalH = rows.Where(r => r.BranchId is null).Sum(r => r.AmountH),
            byMonth = rows.GroupBy(r => r.PeriodMonth)
                .Select(g => new { month = g.Key, amountH = g.Sum(r => r.AmountH) }).ToList(),
            byCategory = rows.GroupBy(r => (r.CategoryId, r.CategoryNameAr, r.CategoryNameEn, r.AccountCode))
                .Select(g => new
                {
                    categoryId = g.Key.CategoryId,
                    nameAr = g.Key.CategoryNameAr,
                    nameEn = g.Key.CategoryNameEn,
                    name = language.Pick(g.Key.CategoryNameAr, g.Key.CategoryNameEn),
                    accountCode = g.Key.AccountCode,
                    amountH = g.Sum(r => r.AmountH)
                }).ToList(),
            byMonthCategory = rows.GroupBy(r => (r.PeriodMonth, r.CategoryId))
                .Select(g => new { month = g.Key.PeriodMonth, categoryId = g.Key.CategoryId, amountH = g.Sum(r => r.AmountH) })
                .ToList(),
            items
        });
    }

    /*------------------------------------------------------------- helpers */

    private static IResult RecurringNotFound() =>
        ProcErrors.NotFound("Recurring payment not found.", "الدفعة المتكرّرة غير موجودة.");

    private static IResult? MapError(SqlException ex, string? nameAr) => ex.Number switch
    {
        69000 => ProcErrors.Field(string.IsNullOrWhiteSpace(nameAr) ? "nameAr" : "nameEn",
            "Both names are required.", "الاسمان العربي والإنجليزي مطلوبان."),
        69001 => ProcErrors.Field("accountCode", "Choose an expense account.", "اختر حساب مصروفات."),
        69002 => ProcErrors.Field("nameEn", "Another category already uses this name.", "يوجد تصنيف آخر بهذا الاسم."),
        69003 => ProcErrors.NotFound("Expense category not found.", "تصنيف المصروف غير موجود."),
        69004 => ProcErrors.Conflict("category_in_use",
            "Active recurring payments still use this category. Pause or move them first.",
            "توجد دفعات متكرّرة نشطة على هذا التصنيف. أوقفها أو انقلها أولًا."),
        69100 => ProcErrors.Field("description", "Give the payment a description.", "أدخل وصفًا للدفعة."),
        69101 => ProcErrors.Field("amountH", "Enter an amount above zero.", "أدخل مبلغًا أكبر من صفر."),
        69102 => ProcErrors.Field("frequency",
            "Frequency is daily, weekly, monthly, quarterly or yearly.", "التكرار: يومي أو أسبوعي أو شهري أو ربع سنوي أو سنوي."),
        69103 => ProcErrors.Field("nextDueOn", "When is the next payment due?", "متى موعد الدفعة القادمة؟"),
        69104 => ProcErrors.Field("paymentMethod", "Pay by cash, card, bank or on credit.", "الدفع نقدًا أو بالبطاقة أو تحويلًا أو آجلًا."),
        69105 => ProcErrors.Field("categoryId", "Choose an active expense category.", "اختر تصنيف مصروف نشطًا."),
        69106 => ProcErrors.Field("branchId", "Unknown branch.", "فرع غير معروف."),
        69107 => RecurringNotFound(),
        69108 => ProcErrors.Field("status", "Status is active or paused.", "الحالة نشط أو موقوف."),
        _ => null
    };

    private sealed record CategoryRow
    {
        public string CategoryId { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string AccountCode { get; init; } = string.Empty;
        public string AccountNameAr { get; init; } = string.Empty;
        public string AccountNameEn { get; init; } = string.Empty;
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
        public int ExpenseCount { get; init; }
        public int RecurringCount { get; init; }
    }

    private sealed record RecognitionRow
    {
        public string PeriodMonth { get; init; } = string.Empty;
        public long AmountH { get; init; }
        public string ExpenseId { get; init; } = string.Empty;
        public string Reference { get; init; } = string.Empty;
        public string CategoryId { get; init; } = string.Empty;
        public string CategoryNameAr { get; init; } = string.Empty;
        public string CategoryNameEn { get; init; } = string.Empty;
        public string AccountCode { get; init; } = string.Empty;
        public string? BranchId { get; init; }
        public string? DescriptionEn { get; init; }
        public string? DescriptionAr { get; init; }
        public string Recognition { get; init; } = string.Empty;
        public string PaymentMethod { get; init; } = string.Empty;
        public DateOnly PaidOn { get; init; }
        public DateOnly PeriodStart { get; init; }
        public DateOnly PeriodEnd { get; init; }
        public long ExpenseAmountH { get; init; }
        public long VatH { get; init; }
    }
}
