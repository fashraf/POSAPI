using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Finance;

/// <summary>
/// A commission rule. <c>Value</c> is basis points of a percent for
/// 'percentage' (2000 = 20%) and halalas for 'fixed' — the units
/// fin.usp_RecordSaleCommission computes with. Empty <c>UserIds</c> means
/// everyone without a more specific rule; empty <c>ItemIds</c>, every service.
/// </summary>
public sealed record CommissionRuleDto(
    string Id,
    IReadOnlyList<string> UserIds,
    string Basis,
    int Value,
    IReadOnlyList<string> ItemIds,
    string Status,
    DateTime CreatedAt,
    DateTime UpdatedAt);

public sealed record SaveCommissionRuleRequest(
    IReadOnlyList<string>? UserIds,
    string Basis,
    int Value,
    IReadOnlyList<string>? ItemIds,
    string? Status);

public static class CommissionRuleEndpoints
{
    public static void MapCommissionRuleEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/finance/commission-rules")
            .WithTags("Commission rules")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("", ListAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.commission"));

        group.MapGet("/{ruleId}", GetAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.commission"));

        group.MapPost("", CreateAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.commission_rules"));

        group.MapPut("/{ruleId}", UpdateAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.commission_rules"));

        group.MapDelete("/{ruleId}", DeleteAsync)
             .RequireAuthorization(PermissionPolicy.For("finance.commission_rules"));
    }

    private static async Task<IResult> ListAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();
        return Results.Ok(await LoadAsync(connection, null, ct));
    }

    private static async Task<IResult> GetAsync(string ruleId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var rule = (await LoadAsync(connection, ruleId, ct)).SingleOrDefault();

        return rule is null ? NotFound() : Results.Ok(rule);
    }

    private static Task<IResult> CreateAsync(
        SaveCommissionRuleRequest request, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveAsync(null, request, db, current, http, logger, ct);

    private static Task<IResult> UpdateAsync(
        string ruleId, SaveCommissionRuleRequest request, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveAsync(ruleId, request, db, current, http, logger, ct);

    /// <summary>
    /// The rule and its user and service sets in one procedure call. Editing
    /// changes future sales only: commission already earned was frozen at the
    /// moment of sale.
    /// </summary>
    private static async Task<IResult> SaveAsync(
        string? ruleId,
        SaveCommissionRuleRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (request.Status is not (null or "active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        var parameters = new DynamicParameters();
        parameters.Add("@RuleId", ruleId);
        parameters.Add("@Basis", request.Basis);
        parameters.Add("@Value", request.Value);
        parameters.Add("@UserIds", ProcErrors.Csv(request.UserIds));
        parameters.Add("@ItemIds", ProcErrors.Csv(request.ItemIds));
        parameters.Add("@IsActive", request.Status != "inactive");
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_SaveCommissionRule", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapError(ex) is { } mapped)
        {
            return mapped;
        }

        var savedId = parameters.Get<string>("@SavedId");

        logger.LogInformation("Commission rule {RuleId} {Action} by {Actor}.",
            savedId, ruleId is null ? "created" : "updated", current.Username);
        http.Items["AuditEntityId"] = savedId;

        var rule = (await LoadAsync(connection, savedId, ct)).Single();

        return ruleId is null
            ? Results.Created($"/api/finance/commission-rules/{savedId}", rule)
            : Results.Ok(rule);
    }

    /// <summary>
    /// A real delete. Earned commission does not point back at its rule — each
    /// entry froze its basis and rate — so removing one changes future sales
    /// only. Use status "inactive" to pause a rule instead.
    /// </summary>
    private static async Task<IResult> DeleteAsync(
        string ruleId, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct)
    {
        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "fin.usp_DeleteCommissionRule", new { RuleId = ruleId },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapError(ex) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Commission rule {RuleId} deleted by {Actor}.", ruleId, current.Username);
        http.Items["AuditEntityId"] = ruleId;

        return Results.NoContent();
    }

    private static IResult NotFound() =>
        ProcErrors.NotFound("No such commission rule.", "لا توجد قاعدة عمولة بهذا المعرف.");

    private static IResult? MapError(SqlException ex) => ex.Number switch
    {
        64005 => NotFound(),
        64000 => ProcErrors.Field("basis", "Commission is a percentage or a fixed amount.", "العمولة إما نسبة أو مبلغ ثابت."),
        64001 => ProcErrors.Field("value", "Enter a value above zero.", "أدخل قيمة أكبر من صفر."),
        64002 => ProcErrors.Field("value", "A commission cannot exceed 100%.", "لا يمكن أن تتجاوز العمولة ١٠٠٪."),
        64003 => ProcErrors.Field("userIds", "One of those people does not exist.", "أحد هؤلاء الأشخاص غير موجود."),
        64004 => ProcErrors.Field("itemIds",
            "Commission rules cover services only, and one of those is not a service.",
            "قواعد العمولة للخدمات فقط، وأحد هذه الأصناف ليس خدمة."),
        _ => null
    };

    private static async Task<List<CommissionRuleDto>> LoadAsync(
        SqlConnection connection, string? ruleId, CancellationToken ct)
    {
        await using var multi = await connection.QueryMultipleAsync(new CommandDefinition(
            """
            SELECT RuleId, Basis, Value, IsActive, CreatedAtUtc, UpdatedAtUtc
            FROM fin.CommissionRule
            WHERE @RuleId IS NULL OR RuleId = @RuleId
            ORDER BY CreatedAtUtc;

            SELECT RuleId, UserId FROM fin.CommissionRuleUser
            WHERE @RuleId IS NULL OR RuleId = @RuleId ORDER BY UserId;

            SELECT RuleId, ItemId FROM fin.CommissionRuleItem
            WHERE @RuleId IS NULL OR RuleId = @RuleId ORDER BY ItemId;
            """,
            new { RuleId = ruleId }, cancellationToken: ct));

        var rows = (await multi.ReadAsync<RuleRow>()).ToList();
        var users = (await multi.ReadAsync<(string RuleId, string UserId)>()).ToLookup(u => u.RuleId, u => u.UserId);
        var items = (await multi.ReadAsync<(string RuleId, string ItemId)>()).ToLookup(i => i.RuleId, i => i.ItemId);

        return rows.Select(r => new CommissionRuleDto(
            r.RuleId, users[r.RuleId].ToList(), r.Basis, r.Value, items[r.RuleId].ToList(),
            r.IsActive ? "active" : "inactive", r.CreatedAtUtc, r.UpdatedAtUtc)).ToList();
    }

    private sealed record RuleRow
    {
        public string RuleId { get; init; } = string.Empty;
        public string Basis { get; init; } = string.Empty;
        public int Value { get; init; }
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
    }
}
