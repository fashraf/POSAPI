using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;

namespace PosApi.Features.Catalog;

/// <summary>
/// Activating and deactivating records.
///
/// One route for every entity that carries IsActive. A route per type would be
/// ten near-identical handlers whose guards drift apart — and the guards are the
/// substance here, not the update.
///
/// There is no delete. A record that has been sold against, paid against or
/// reported on must stay, or last month's invoice stops adding up.
/// </summary>
public static partial class ActivationEndpoints
{
    public static void MapActivationEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/activation")
            .WithTags("Activation")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapPatch("/{entityType}/{entityId}", SetActiveAsync)
             .RequireAuthorization(PermissionPolicy.For("catalog.activate"));
    }

    private static async Task<IResult> SetActiveAsync(
        string entityType,
        string entityId,
        SetActiveRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct = default)
    {
        await using var connection = db.Create();

        var parameters = new DynamicParameters();
        parameters.Add("@EntityType", entityType);
        parameters.Add("@EntityId", entityId);
        parameters.Add("@IsActive", request.IsActive);
        parameters.Add("@Actor", current.Username);
        parameters.Add("@Blocked", dbType: System.Data.DbType.String,
                       direction: System.Data.ParameterDirection.Output, size: 400);

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SetActive", parameters,
                commandType: System.Data.CommandType.StoredProcedure,
                cancellationToken: ct));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 57001)
        {
            return Results.NotFound(ApiError.Create(
                "not_found", "No such record.", "لا يوجد سجل بهذا المعرف."));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 57000)
        {
            return Results.BadRequest(ApiError.Create(
                "not_activatable",
                "That kind of record cannot be activated or deactivated.",
                "لا يمكن تنشيط أو تعطيل هذا النوع من السجلات."));
        }

        var blocked = parameters.Get<string?>("@Blocked");

        if (!string.IsNullOrWhiteSpace(blocked))
        {
            /*
             * 409, not 400.
             *
             * The request was well formed; the record's current state is what
             * prevents it. The message names what is in the way so the person
             * can clear it, rather than being told "failed".
             */
            logger.LogInformation(
                "Deactivation of {Type} {Id} blocked: {Reason}", entityType, entityId, blocked);

            return Results.Conflict(ApiError.Create("deactivation_blocked", blocked, BlockedArabic(blocked)));
        }

        /* So the audit entry names the record, not just the route. */
        http.Items["AuditEntityId"] = entityId;
        http.Items["AuditNewValue"] = request.IsActive ? "active" : "inactive";

        return Results.Ok(new { entityType, entityId, isActive = request.IsActive });
    }
}

public sealed record SetActiveRequest(bool IsActive);

public static partial class ActivationEndpoints
{
    /*
     * core.usp_SetActive explains a refusal in English only. The client shows
     * messageAr to an Arabic user, so the known sentences are given their
     * Arabic here (with the count carried over); an unknown one falls back to
     * the English rather than to nothing.
     */
    private static string BlockedArabic(string blocked)
    {
        var count = System.Text.RegularExpressions.Regex.Match(blocked, @"\d+").Value;

        if (blocked.StartsWith("This category still has", StringComparison.Ordinal))
            return $"ما زال هذا التصنيف يحتوي على {count} من الأصناف النشطة. انقلها أو عطّلها أولًا.";
        if (blocked.StartsWith("This print group is still used", StringComparison.Ordinal))
            return "ما زالت أصناف نشطة تستخدم مجموعة الطباعة هذه. انقلها أولًا وإلا فلن تُطبع تذاكرها.";
        if (blocked.StartsWith("This customer still owes money", StringComparison.Ordinal))
            return "ما زال على هذا العميل مبلغ مستحق. سدّد الرصيد قبل التعطيل.";
        if (blocked.StartsWith("This vendor has", StringComparison.Ordinal))
            return $"لدى هذا المورد {count} من التوريدات غير المسددة. سدّدها قبل التعطيل.";
        if (blocked.StartsWith("This branch has an open cash drawer", StringComparison.Ordinal))
            return "يوجد درج نقد مفتوح في هذا الفرع. أغلقه أولًا.";
        if (blocked.StartsWith("This branch has an open balance period", StringComparison.Ordinal))
            return "توجد فترة أرصدة مفتوحة في هذا الفرع. أغلقها أولًا.";
        if (blocked.StartsWith("This is the only active branch", StringComparison.Ordinal))
            return "هذا هو الفرع النشط الوحيد. يجب أن يبقى فرع واحد على الأقل.";

        return blocked;
    }
}
