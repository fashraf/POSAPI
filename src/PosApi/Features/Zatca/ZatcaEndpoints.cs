using Dapper;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Tenancy;

namespace PosApi.Features.Zatca;

public sealed record TestUnitRequest(string BranchId);

/// <summary>
/// ZATCA status and documents.
///
///   GET  /api/zatca/units                each branch's EGS unit and its chain
///   GET  /api/zatca/documents?saleId=…   a signed document (or ?returnId=…), with its XML
///   POST /api/zatca/test-units           development only: a self-signed unit for a branch
/// </summary>
public static class ZatcaEndpoints
{
    public static void MapZatcaEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/zatca")
            .WithTags("ZATCA")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        group.MapGet("/units", UnitsAsync)
             .RequireAuthorization(PermissionPolicy.For("company.edit"));

        group.MapGet("/documents", DocumentAsync)
             .RequireAuthorization(PermissionPolicy.For("sales.view_details"));

        group.MapPost("/test-units", CreateTestUnitAsync)
             .RequireAuthorization(PermissionPolicy.For("company.edit"));
    }

    private static async Task<IResult> UnitsAsync(ISqlConnectionFactory db, ZatcaVault vault, CancellationToken ct)
    {
        await using var connection = db.Create();

        var units = await connection.QueryRowsAsync(new CommandDefinition(
            """
            SELECT b.BranchId, b.NameAr, b.NameEn,
                   u.Environment, u.Status, u.InvoiceTypes, u.LastIcv, u.ActivatedAtUtc, u.CertificateNotAfter,
                   COALESCE(d.Pending, 0) AS Pending, COALESCE(d.Rejected, 0) AS Rejected,
                   d.LastSignedAtUtc
            FROM core.Branch AS b
            LEFT JOIN zatca.EgsUnit AS u ON u.BranchId = b.BranchId
            LEFT JOIN LATERAL (
                SELECT COUNT(*) FILTER (WHERE x.ReportingStatus IN ('pending', 'retrying'))::int AS Pending,
                       COUNT(*) FILTER (WHERE x.ReportingStatus = 'rejected')::int AS Rejected,
                       MAX(x.SignedAtUtc) AS LastSignedAtUtc
                FROM zatca.Document AS x WHERE x.BranchId = b.BranchId
            ) AS d ON true
            WHERE b.IsActive
            ORDER BY b.NameEn;
            """, cancellationToken: ct));

        return Results.Ok(new { signingAvailable = vault.IsAvailable, units });
    }

    private static async Task<IResult> DocumentAsync(
        string? saleId, string? returnId, ISqlConnectionFactory db, ICurrentUser current, CancellationToken ct)
    {
        if ((saleId is null) == (returnId is null))
            return ProcErrors.Field("saleId", "Ask for one sale or one return.", "اطلب فاتورة واحدة أو مرتجعًا واحدًا.");

        await using var connection = db.Create();

        var document = await connection.QuerySingleRowOrDefaultAsync(new CommandDefinition(
            """
            SELECT DocumentId, BranchId, Icv, Kind, Simplified, SaleId, ReturnId, DocumentNumber, Uuid,
                   InvoiceHash, PreviousHash, QrPayload, Environment, IssuedAtUtc, SignedAtUtc,
                   ReportingStatus, Attempts, DeadlineAtUtc, ReportedAtUtc, Messages, SignedXml
            FROM zatca.Document
            WHERE (@SaleId IS NOT NULL AND SaleId = @SaleId AND Kind = 'invoice')
               OR (@ReturnId IS NOT NULL AND ReturnId = @ReturnId);
            """, new { SaleId = saleId, ReturnId = returnId }, cancellationToken: ct));

        if (document is null)
            return ProcErrors.NotFound("This document has not been signed.", "لم يُوقَّع هذا المستند.");
        if (!current.CanSeeBranch((string)document.BranchId)) return Results.Forbid();

        return Results.Ok(document);
    }

    private static async Task<IResult> CreateTestUnitAsync(
        TestUnitRequest request, ISqlConnectionFactory db, ITenantContext tenant, ZatcaIssuer issuer,
        IWebHostEnvironment environment, CancellationToken ct)
    {
        /* A self-signed unit signs documents ZATCA would never accept: never
           outside development. */
        if (!environment.IsDevelopment()) return Results.NotFound();

        await using var connection = await db.CreateOpenAsync(ct);

        var exists = await connection.ExecuteScalarAsync<bool>(new CommandDefinition(
            "SELECT EXISTS (SELECT 1 FROM core.Branch WHERE BranchId = @BranchId);",
            new { request.BranchId }, cancellationToken: ct));
        if (!exists) return ProcErrors.Field("branchId", "Unknown branch.", "فرع غير معروف.");

        try
        {
            await issuer.CreateTestUnitAsync(connection, tenant.Tenant!.TenantId, request.BranchId, ct);
        }
        catch (InvalidOperationException ex)
        {
            return ProcErrors.Conflict("zatca_unit", ex.Message, ex.Message);
        }

        return Results.Ok(new { request.BranchId, environment = "test", status = "active" });
    }
}

public sealed record OnboardingRequest(string BranchId, string Otp, string? InvoiceTypes, string? BusinessCategory);

public sealed record RenewalRequest(string BranchId, string Otp, string? BusinessCategory);

/// <summary>
/// Onboarding a branch with ZATCA, for the owner:
///
///   GET  /api/zatca/readiness?branchId=…   what stops onboarding now
///   POST /api/zatca/onboarding             { branchId, otp, invoiceTypes: 0100|1100 }
///   POST /api/zatca/renewal                { branchId, otp }
///   GET  /api/zatca/onboarding?branchId=…  past attempts and their steps
/// </summary>
public static class ZatcaOnboardingEndpoints
{
    public static void MapZatcaOnboardingEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/zatca")
            .WithTags("ZATCA")
            .RequireAuthorization(PermissionPolicy.For("company.edit"))
            .RequireRateLimiting("standard");

        group.MapGet("/readiness", ReadinessAsync);
        group.MapGet("/onboarding", AttemptsAsync);
        group.MapPost("/onboarding", OnboardAsync);
        group.MapPost("/renewal", RenewAsync);
    }

    private static async Task<IResult> ReadinessAsync(
        string? branchId, ISqlConnectionFactory db, ZatcaOnboarding onboarding, CancellationToken ct)
    {
        await using var connection = db.Create();
        var problems = await onboarding.ReadinessAsync(connection, ProcErrors.Blank(branchId), ct);
        return Results.Ok(new { environment = onboarding.Environment, ready = problems.Count == 0, problems });
    }

    private static async Task<IResult> AttemptsAsync(string branchId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();
        var attempts = await connection.QueryRowsAsync(new CommandDefinition(
            """
            SELECT AttemptId, BranchId, Kind, Environment, InvoiceTypes, State, EgsSerial, ComplianceRequestId,
                   Steps, ErrorCode, ErrorMessage, StartedBy, StartedAtUtc, UpdatedAtUtc
            FROM zatca.Onboarding WHERE BranchId = @BranchId
            ORDER BY StartedAtUtc DESC LIMIT 20;
            """, new { BranchId = branchId }, cancellationToken: ct));
        return Results.Ok(attempts);
    }

    private static async Task<IResult> OnboardAsync(
        OnboardingRequest request, ISqlConnectionFactory db, ITenantContext tenant, ICurrentUser current,
        ZatcaOnboarding onboarding, CancellationToken ct)
    {
        if (Check(request.BranchId, request.Otp, current) is { } bad) return bad;

        var types = request.InvoiceTypes ?? "0100";
        if (types is not ("0100" or "1100"))
            return ProcErrors.Field("invoiceTypes", "Choose simplified only (0100) or standard and simplified (1100).",
                "اختر المبسطة فقط (0100) أو القياسية والمبسطة (1100).");

        await using var connection = await db.CreateOpenAsync(ct);
        try
        {
            var result = await onboarding.OnboardAsync(connection, tenant.Tenant!.TenantId, request.BranchId,
                request.Otp.Trim(), types, Category(request.BusinessCategory), current.Username, ct);
            return Results.Ok(result);
        }
        catch (InvalidOperationException ex)
        {
            return ProcErrors.Conflict("zatca_not_ready", ex.Message, ex.Message);
        }
    }

    private static async Task<IResult> RenewAsync(
        RenewalRequest request, ISqlConnectionFactory db, ITenantContext tenant, ICurrentUser current,
        ZatcaOnboarding onboarding, CancellationToken ct)
    {
        if (Check(request.BranchId, request.Otp, current) is { } bad) return bad;

        await using var connection = await db.CreateOpenAsync(ct);
        try
        {
            var result = await onboarding.RenewAsync(connection, tenant.Tenant!.TenantId, request.BranchId,
                request.Otp.Trim(), Category(request.BusinessCategory), current.Username, ct);
            return Results.Ok(result);
        }
        catch (InvalidOperationException ex)
        {
            return ProcErrors.Conflict("zatca_not_ready", ex.Message, ex.Message);
        }
    }

    private static IResult? Check(string? branchId, string? otp, ICurrentUser current)
    {
        if (string.IsNullOrWhiteSpace(branchId))
            return ProcErrors.Field("branchId", "Choose the branch.", "اختر الفرع.");
        if (!current.CanSeeBranch(branchId)) return Results.Forbid();
        if (otp is null || !System.Text.RegularExpressions.Regex.IsMatch(otp.Trim(), "^[0-9]{6}$"))
            return ProcErrors.Field("otp", "The OTP from the Fatoora portal is 6 digits.", "رمز التحقق من بوابة فاتورة 6 أرقام.");
        return null;
    }

    private static string Category(string? value) =>
        string.IsNullOrWhiteSpace(value) ? "Retail" : value.Trim()[..Math.Min(value.Trim().Length, 60)];
}
