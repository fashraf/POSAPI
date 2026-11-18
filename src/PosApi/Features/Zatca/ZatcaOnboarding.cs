using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json.Nodes;
using Dapper;
using Npgsql;

namespace PosApi.Features.Zatca;

/// <summary>Something that stops onboarding, in both languages.</summary>
public sealed record ZatcaProblem(string Code, string MessageEn, string MessageAr);

/// <summary>The outcome of an onboarding or renewal attempt, for the owner's screen.</summary>
public sealed record ZatcaOnboardingResult(
    string AttemptId, string State, string? ErrorCode, string? Message, JsonNode Steps);

/// <summary>
/// Gets a branch's EGS unit its certificate from ZATCA, in one sitting:
///
///  1. a fresh P-256 key and a certificate request (ZatcaCsr);
///  2. a compliance CSID for it, with the owner's OTP from the Fatoora portal;
///  3. the compliance samples (simplified invoice, credit and debit note; the
///     standard three as well for invoice types 1100), signed with the
///     compliance certificate on a chain of their own;
///  4. the production CSID;
///  5. the unit goes active: from now on the branch's sales are signed.
///
/// Each step is saved before the next (zatca.Onboarding), so a failure says
/// where it stopped. A wrong OTP stops at otp_rejected. A production-CSID
/// call that times out is fate_unknown: ZATCA may have issued it, so it is
/// not called again; the owner starts over with a new OTP. Nothing secret is
/// saved but the sealed private key; the OTP and compliance CSID live only
/// for the request.
///
/// The environment is the server's (Zatca:Environment): a production server
/// is "core", a staging server "simulation" or "developer-portal". A branch
/// never signs real sales under a test certificate.
/// </summary>
public sealed class ZatcaOnboarding(
    ZatcaGateway gateway, ZatcaVault vault, IConfiguration configuration, ILogger<ZatcaOnboarding> logger)
{
    public string? Environment
    {
        get
        {
            var value = configuration["Zatca:Environment"]?.Trim().ToLowerInvariant();
            return value is not null && ZatcaGateway.Environments.Contains(value) ? value : null;
        }
    }

    /// <summary>What stops this branch from onboarding now (empty when nothing does).</summary>
    public async Task<List<ZatcaProblem>> ReadinessAsync(NpgsqlConnection connection, string? branchId, CancellationToken ct)
    {
        var problems = new List<ZatcaProblem>();
        if (Environment is null)
            problems.Add(new("not_configured", "ZATCA is not set up on this server (Zatca:Environment).",
                "لم يُعدّ الربط مع الهيئة على هذا الخادم (Zatca:Environment)."));
        if (!vault.IsAvailable)
            problems.Add(new("no_vault", "The server has no key-encryption key for ZATCA credentials (Zatca:KekFile).",
                "لا يوجد على الخادم مفتاح تشفير لبيانات اعتماد الهيئة (Zatca:KekFile)."));

        var (_, missing) = await ZatcaIssuer.CompanyAsync(connection, null, ct);
        if (missing.Count > 0)
            problems.Add(new("company_profile",
                "Complete the company profile: " + string.Join(", ", missing.Select(m => ZatcaIssuer.CompanyField(m).En)) + ".",
                "أكمل ملف المنشأة: " + string.Join("، ", missing.Select(m => ZatcaIssuer.CompanyField(m).Ar)) + "."));

        if (branchId is not null)
        {
            var unit = await connection.QuerySingleOrDefaultAsync<(string Environment, long Documents)?>(new CommandDefinition(
                """
                SELECT u.Environment, (SELECT COUNT(*) FROM zatca.Document AS d WHERE d.BranchId = u.BranchId)
                FROM zatca.EgsUnit AS u WHERE u.BranchId = @BranchId;
                """, new { BranchId = branchId }, cancellationToken: ct));

            if (unit is { } u && u.Documents > 0 && u.Environment != Environment)
                problems.Add(new("environment_change",
                    $"This branch has documents signed under the {u.Environment} environment; its chain cannot move to {Environment}.",
                    $"لهذا الفرع مستندات موقّعة في بيئة {u.Environment}؛ لا يمكن نقل سلسلته إلى {Environment}."));
        }

        return problems;
    }

    public async Task<ZatcaOnboardingResult> OnboardAsync(
        NpgsqlConnection connection, string tenantId, string branchId, string otp, string invoiceTypes,
        string businessCategory, string actor, CancellationToken ct)
    {
        var env = Environment ?? throw new InvalidOperationException("ZATCA is not set up on this server.");
        if (connection.State != System.Data.ConnectionState.Open) await connection.OpenAsync(ct);

        await using var branchLock = await BranchLockAsync(connection, branchId, ct);

        var problems = await ReadinessAsync(connection, branchId, ct);
        if (problems.Count > 0) throw new InvalidOperationException(string.Join(" ", problems.Select(p => p.MessageEn)));

        var (seller, _) = await ZatcaIssuer.CompanyAsync(connection, null, ct);
        var branch = await connection.QuerySingleAsync<(string NameAr, string NameEn)>(new CommandDefinition(
            "SELECT NameAr, NameEn FROM core.Branch WHERE BranchId = @BranchId;", new { BranchId = branchId }, cancellationToken: ct));
        var companyEn = await connection.QuerySingleAsync<string>(new CommandDefinition(
            "SELECT NameEn FROM core.Company ORDER BY CompanyId LIMIT 1;", cancellationToken: ct));

        /* 1. key and request */
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var serial = $"1-Nazad|2-NazadPOS|3-{Guid.NewGuid():D}";
        var csr = ZatcaCsr.Build(new ZatcaCsrSubject(
            CommonName: $"NZD-{branchId}-{seller!.VatNumber}",
            SerialNumber: serial,
            VatNumber: seller.VatNumber,
            OrganizationUnit: Ascii(branch.NameEn, branch.NameAr),
            OrganizationName: Ascii(companyEn, seller.RegistrationName),
            InvoiceTypes: invoiceTypes,
            LocationAddress: Address(seller.Address),
            BusinessCategory: businessCategory), env, key);

        var attempt = new Attempt(this, connection, "zat_" + Guid.NewGuid().ToString("N")[..20]);
        var keyCt = vault.Seal(Encoding.UTF8.GetBytes(key.ExportPkcs8PrivateKeyPem()), ZatcaVault.Context(tenantId, branchId, "privateKey"));

        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO zatca.Onboarding (AttemptId, BranchId, Kind, Environment, InvoiceTypes, State, EgsSerial,
                                          Csr, PrivateKeyCt, KekId, StartedBy)
            VALUES (@AttemptId, @BranchId, 'onboarding', @Env, @Types, 'csr_ready', @Serial, @Csr, @Key, @KekId, @Actor);
            """,
            new { AttemptId = attempt.Id, BranchId = branchId, Env = env, Types = invoiceTypes, Serial = serial,
                  Csr = ZatcaCsr.Pem(csr), Key = keyCt, vault.KekId, Actor = actor }, cancellationToken: ct));

        /* 2. compliance CSID */
        var compliance = await gateway.ComplianceCsidAsync(env, otp, ZatcaCsr.ForApi(csr), ct);
        await attempt.StepAsync("compliance_csid", compliance, ct);

        if (compliance.Outcome == "response" && compliance.Status == 400)
            return await attempt.EndAsync("otp_rejected", "otp_rejected",
                "ZATCA did not accept the OTP or the request. OTPs work once and expire after an hour: create a new one in the Fatoora portal.", ct);
        if (!compliance.Ok || compliance.Text("binarySecurityToken") is not { } complianceToken
            || compliance.Text("secret") is not { } complianceSecret || compliance.Text("requestID") is not { } requestId)
            return await attempt.EndAsync("failed", Unreachable(compliance), "ZATCA did not issue a compliance certificate.", ct);

        await attempt.StateAsync("compliance_issued", ct, requestId);
        var complianceCsid = new ZatcaCsid(complianceToken, complianceSecret);

        /* 3. compliance samples */
        using (var credential = new ZatcaCredential(Certificate(complianceToken), CopyKey(key)))
        {
            var previous = ZatcaHash.Genesis;
            var icv = 0;
            foreach (var sample in ZatcaSamples.For(seller, invoiceTypes, ZatcaIssuer.ToRiyadh(DateTime.UtcNow)))
            {
                var document = sample with { Icv = ++icv, PreviousHash = previous };
                var signed = ZatcaSigner.Sign(document, credential);
                previous = signed.ChainValue;

                var check = await gateway.ComplianceInvoiceAsync(env, complianceCsid, signed, document.Uuid, ct);
                await attempt.StepAsync($"sample_{icv}_{(document.Simplified ? "simplified" : "standard")}_{(int)document.Type}", check, ct);

                if (!check.Ok || string.Equals(check.Body?["validationResults"]?["status"]?.ToString(), "ERROR", StringComparison.OrdinalIgnoreCase))
                    return await attempt.EndAsync("samples_failed", check.Ok ? "samples_failed" : Unreachable(check),
                        "ZATCA refused a compliance sample; see the steps for its messages.", ct);
            }
        }
        await attempt.StateAsync("samples_passed", ct);

        /* 4. production CSID: never repeated after a timeout */
        var production = await gateway.ProductionCsidAsync(env, complianceCsid, requestId, ct);
        await attempt.StepAsync("production_csid", production, ct);

        if (production.Outcome == "timeout")
            return await attempt.EndAsync("fate_unknown", "fate_unknown",
                "ZATCA did not answer in time and may have issued the certificate. Start again with a new OTP.", ct);
        if (!production.Ok || production.Text("binarySecurityToken") is not { } token || production.Text("secret") is not { } secret)
            return await attempt.EndAsync("failed", Unreachable(production), "ZATCA did not issue the production certificate.", ct);

        /* 5. the unit goes active */
        using var certificate = Certificate(token);
        await ActivateAsync(connection, tenantId, branchId, env, certificate, token, secret, keyCt, invoiceTypes, serial, ct);

        logger.LogInformation("ZATCA: branch {Branch} onboarded ({Environment}, {Types}).", branchId, env, invoiceTypes);
        return await attempt.EndAsync("active", null, null, ct);
    }

    /// <summary>
    /// A new key and certificate for an active unit (before its certificate
    /// expires, or after it was compromised), with a fresh OTP. The chain
    /// carries on.
    /// </summary>
    public async Task<ZatcaOnboardingResult> RenewAsync(
        NpgsqlConnection connection, string tenantId, string branchId, string otp, string businessCategory, string actor, CancellationToken ct)
    {
        var env = Environment ?? throw new InvalidOperationException("ZATCA is not set up on this server.");
        if (connection.State != System.Data.ConnectionState.Open) await connection.OpenAsync(ct);

        await using var branchLock = await BranchLockAsync(connection, branchId, ct);

        var unit = await connection.QuerySingleOrDefaultAsync<(string Environment, string? Token, string? SecretCt, string? InvoiceTypes)>(
            new CommandDefinition(
                "SELECT Environment, BinarySecurityToken, SecretCt, InvoiceTypes FROM zatca.EgsUnit WHERE BranchId = @BranchId AND Status = 'active';",
                new { BranchId = branchId }, cancellationToken: ct));
        if (unit.Token is null || unit.SecretCt is null || unit.Environment != env)
            throw new InvalidOperationException("This branch has no ZATCA certificate to renew. Onboard it instead.");

        var (seller, missing) = await ZatcaIssuer.CompanyAsync(connection, null, ct);
        if (seller is null)
            throw new InvalidOperationException("Complete the company profile: "
                + string.Join(", ", missing.Select(m => ZatcaIssuer.CompanyField(m).En)) + ".");
        var branch = await connection.QuerySingleAsync<(string NameAr, string NameEn)>(new CommandDefinition(
            "SELECT NameAr, NameEn FROM core.Branch WHERE BranchId = @BranchId;", new { BranchId = branchId }, cancellationToken: ct));
        var companyEn = await connection.QuerySingleAsync<string>(new CommandDefinition(
            "SELECT NameEn FROM core.Company ORDER BY CompanyId LIMIT 1;", cancellationToken: ct));

        var types = unit.InvoiceTypes ?? "0100";
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var serial = $"1-Nazad|2-NazadPOS|3-{Guid.NewGuid():D}";
        var csr = ZatcaCsr.Build(new ZatcaCsrSubject(
            $"NZD-{branchId}-{seller.VatNumber}", serial, seller.VatNumber, Ascii(branch.NameEn, branch.NameAr),
            Ascii(companyEn, seller.RegistrationName), types, Address(seller.Address), businessCategory), env, key);

        var attempt = new Attempt(this, connection, "zat_" + Guid.NewGuid().ToString("N")[..20]);
        var keyCt = vault.Seal(Encoding.UTF8.GetBytes(key.ExportPkcs8PrivateKeyPem()), ZatcaVault.Context(tenantId, branchId, "privateKey"));
        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO zatca.Onboarding (AttemptId, BranchId, Kind, Environment, InvoiceTypes, State, EgsSerial,
                                          Csr, PrivateKeyCt, KekId, StartedBy)
            VALUES (@AttemptId, @BranchId, 'renewal', @Env, @Types, 'csr_ready', @Serial, @Csr, @Key, @KekId, @Actor);
            """,
            new { AttemptId = attempt.Id, BranchId = branchId, Env = env, Types = types, Serial = serial,
                  Csr = ZatcaCsr.Pem(csr), Key = keyCt, vault.KekId, Actor = actor }, cancellationToken: ct));

        var current = new ZatcaCsid(unit.Token,
            Encoding.UTF8.GetString(vault.Open(unit.SecretCt, ZatcaVault.Context(tenantId, branchId, "secret"))));
        var renewed = await gateway.RenewProductionCsidAsync(env, current, otp, ZatcaCsr.ForApi(csr), ct);
        await attempt.StepAsync("renew_production_csid", renewed, ct);

        if (renewed.Outcome == "response" && renewed.Status == 400)
            return await attempt.EndAsync("otp_rejected", "otp_rejected",
                "ZATCA did not accept the OTP or the request. Create a new OTP in the Fatoora portal.", ct);
        if (renewed.Outcome == "timeout")
            return await attempt.EndAsync("fate_unknown", "fate_unknown",
                "ZATCA did not answer in time. The current certificate stays in use; try again with a new OTP.", ct);
        if (!renewed.Ok || renewed.Text("binarySecurityToken") is not { } token || renewed.Text("secret") is not { } secret)
            return await attempt.EndAsync("failed", Unreachable(renewed), "ZATCA did not renew the certificate.", ct);

        using var certificate = Certificate(token);
        await ActivateAsync(connection, tenantId, branchId, env, certificate, token, secret, keyCt, types, serial, ct);

        logger.LogInformation("ZATCA: branch {Branch} certificate renewed.", branchId);
        return await attempt.EndAsync("active", null, null, ct);
    }

    /// <summary>
    /// Store the production credential and make the unit active. A unit in the
    /// same environment keeps its chain (renewal, re-onboarding); a new one, or
    /// one that only had a test certificate, starts at the beginning.
    /// </summary>
    private async Task ActivateAsync(
        NpgsqlConnection connection, string tenantId, string branchId, string env, X509Certificate2 certificate,
        string token, string secret, string keyCt, string invoiceTypes, string serial, CancellationToken ct)
    {
        await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO zatca.EgsUnit (BranchId, Environment, Status, CertificateBase64, CertificateNotAfter, PrivateKeyCt,
                                       SecretCt, KekId, BinarySecurityToken, InvoiceTypes, EgsSerial, ActivatedAtUtc)
            VALUES (@BranchId, @Env, 'active', @Certificate, @NotAfter, @Key, @Secret, @KekId, @Token, @Types, @Serial,
                    now() AT TIME ZONE 'utc')
            ON CONFLICT (BranchId) DO UPDATE SET
                LastIcv        = CASE WHEN zatca.EgsUnit.Environment = EXCLUDED.Environment THEN zatca.EgsUnit.LastIcv ELSE 0 END,
                LastHash       = CASE WHEN zatca.EgsUnit.Environment = EXCLUDED.Environment THEN zatca.EgsUnit.LastHash
                                      ELSE 'NWZlY2ViNjZmZmM4NmYzOGQ5NTI3ODZjNmQ2OTZjNzljMmRiYzIzOWRkNGU5MWI0NjcyOWQ3M2EyN2ZiNTdlOQ==' END,
                ActivatedAtUtc = CASE WHEN zatca.EgsUnit.Environment = EXCLUDED.Environment THEN zatca.EgsUnit.ActivatedAtUtc
                                      ELSE EXCLUDED.ActivatedAtUtc END,
                Environment = EXCLUDED.Environment, Status = 'active',
                CertificateBase64 = EXCLUDED.CertificateBase64, CertificateNotAfter = EXCLUDED.CertificateNotAfter,
                PrivateKeyCt = EXCLUDED.PrivateKeyCt, SecretCt = EXCLUDED.SecretCt, KekId = EXCLUDED.KekId,
                BinarySecurityToken = EXCLUDED.BinarySecurityToken, InvoiceTypes = EXCLUDED.InvoiceTypes,
                EgsSerial = EXCLUDED.EgsSerial, UpdatedAtUtc = now() AT TIME ZONE 'utc';
            """,
            new
            {
                BranchId = branchId, Env = env,
                Certificate = Convert.ToBase64String(certificate.RawData),
                NotAfter = certificate.NotAfter.ToUniversalTime(),
                Key = keyCt,
                Secret = vault.Seal(Encoding.UTF8.GetBytes(secret), ZatcaVault.Context(tenantId, branchId, "secret")),
                vault.KekId, Token = token, Types = invoiceTypes, Serial = serial
            }, cancellationToken: ct));
    }

    /*---------------------------------------------------------------- parts */

    /// <summary>One attempt at a time per branch, across every API process.</summary>
    private static async Task<IAsyncDisposable> BranchLockAsync(NpgsqlConnection connection, string branchId, CancellationToken ct)
    {
        var lockKey = "zatca-onboarding:" + branchId;
        var taken = await connection.ExecuteScalarAsync<bool>(new CommandDefinition(
            "SELECT pg_try_advisory_lock(hashtext(@Key));", new { Key = lockKey }, cancellationToken: ct));
        if (!taken) throw new InvalidOperationException("Another ZATCA onboarding for this branch is running. Wait for it to finish.");
        return new Release(connection, lockKey);
    }

    private sealed class Release(NpgsqlConnection connection, string lockKey) : IAsyncDisposable
    {
        public async ValueTask DisposeAsync() =>
            await connection.ExecuteAsync("SELECT pg_advisory_unlock(hashtext(@Key));", new { Key = lockKey });
    }

    /// <summary>The certificate inside a binarySecurityToken (base64 of the certificate's base64 text).</summary>
    internal static X509Certificate2 Certificate(string binarySecurityToken) =>
        new(Convert.FromBase64String(Encoding.ASCII.GetString(Convert.FromBase64String(binarySecurityToken))));

    private static ECDsa CopyKey(ECDsa key)
    {
        var copy = ECDsa.Create();
        copy.ImportParameters(key.ExportParameters(includePrivateParameters: true));
        return copy;
    }

    private static string Unreachable(ZatcaCallResult result) =>
        result.Outcome == "response" ? $"zatca_{result.Status}" : "zatca_unreachable";

    /// <summary>The English name when there is one; ZATCA's portal shows these.</summary>
    private static string Ascii(string preferred, string fallback) =>
        string.IsNullOrWhiteSpace(preferred) ? fallback.Trim() : preferred.Trim();

    private static string Address(ZatcaAddress a) =>
        string.Join(" ", new[] { a.BuildingNumber, a.Street, a.District, a.City, a.PostalCode }
            .Where(p => !string.IsNullOrWhiteSpace(p)));

    /// <summary>The attempt's row: its state and the record of each step.</summary>
    private sealed class Attempt(ZatcaOnboarding owner, NpgsqlConnection connection, string id)
    {
        private readonly JsonArray _steps = [];
        public string Id { get; } = id;

        public async Task StepAsync(string name, ZatcaCallResult result, CancellationToken ct)
        {
            var step = result.Summary().AsObject();
            step["step"] = name;
            step["at"] = DateTime.UtcNow.ToString("O");
            _steps.Add(step);
            await connection.ExecuteAsync(new CommandDefinition(
                "UPDATE zatca.Onboarding SET Steps = @Steps::jsonb, UpdatedAtUtc = now() AT TIME ZONE 'utc' WHERE AttemptId = @Id;",
                new { Steps = _steps.ToJsonString(), Id }, cancellationToken: ct));
        }

        public Task StateAsync(string state, CancellationToken ct, string? complianceRequestId = null) =>
            connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE zatca.Onboarding
                SET State = @State, ComplianceRequestId = COALESCE(@RequestId, ComplianceRequestId),
                    UpdatedAtUtc = now() AT TIME ZONE 'utc'
                WHERE AttemptId = @Id;
                """, new { State = state, RequestId = complianceRequestId, Id }, cancellationToken: ct));

        public async Task<ZatcaOnboardingResult> EndAsync(string state, string? errorCode, string? message, CancellationToken ct)
        {
            await connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE zatca.Onboarding
                SET State = @State, ErrorCode = @Code, ErrorMessage = @Message, UpdatedAtUtc = now() AT TIME ZONE 'utc'
                WHERE AttemptId = @Id;
                """, new { State = state, Code = errorCode, Message = message, Id }, cancellationToken: ct));

            if (errorCode is not null)
                owner.Log(Id, state, errorCode);

            return new ZatcaOnboardingResult(Id, state, errorCode, message, _steps.DeepClone());
        }
    }

    private void Log(string attemptId, string state, string code) =>
        logger.LogWarning("ZATCA onboarding {Attempt} ended {State} ({Code}).", attemptId, state, code);
}

/// <summary>The compliance samples ZATCA asks for before it issues a production CSID.</summary>
internal static class ZatcaSamples
{
    private static readonly ZatcaBuyer Buyer = new(
        "Compliance Sample Buyer LLC", "310122393500003", "CRN", "1010101010",
        new ZatcaAddress("King Abdulaziz Rd", "1234", null, "Al Malqa", "Riyadh", "13521"));

    public static IEnumerable<ZatcaDocument> For(ZatcaSeller seller, string invoiceTypes, DateTime nowLocal)
    {
        var kinds = new List<bool> { true };       // simplified
        if (invoiceTypes == "1100") kinds.Insert(0, false); // standard first, as ZATCA lists them

        foreach (var simplified in kinds)
        {
            foreach (var type in new[] { ZatcaDocumentType.Invoice, ZatcaDocumentType.CreditNote, ZatcaDocumentType.DebitNote })
            {
                yield return new ZatcaDocument
                {
                    Type = type,
                    Simplified = simplified,
                    Number = $"SME-{(simplified ? "S" : "T")}{(int)type}",
                    Uuid = Guid.NewGuid(),
                    IssuedAtLocal = nowLocal,
                    Icv = 1,
                    PreviousHash = ZatcaHash.Genesis,
                    Seller = seller,
                    Buyer = simplified ? null : Buyer,
                    PaymentMeansCode = "10",
                    BillingReference = type == ZatcaDocumentType.Invoice ? null : $"SME-{(simplified ? "S" : "T")}388",
                    Reason = type == ZatcaDocumentType.Invoice ? null : "Compliance sample",
                    Lines = [new ZatcaLine("Compliance sample item", 1m, 10000, 1500)],
                    TaxH = 1500
                };
            }
        }
    }
}
