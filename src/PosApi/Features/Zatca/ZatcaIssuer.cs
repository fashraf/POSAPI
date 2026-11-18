using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Dapper;
using Npgsql;

namespace PosApi.Features.Zatca;

/// <summary>
/// Signs sales and credit notes into their branch's chain (zatca.EgsUnit).
///
/// A sale is committed first, exactly as without ZATCA, and signed right
/// after in a transaction of its own: a signing failure never costs a sale.
/// What failed is signed by <see cref="ZatcaSigningService"/> on its next
/// pass, and until then the receipt carries the Phase 1 QR.
///
/// The unit's row is locked for the whole signing, so the chain advances one
/// document at a time; the head (LastIcv, LastHash) moves in the same
/// transaction that stores the document, whatever ZATCA later says about it.
/// Only branches with an active unit sign, and only documents dated from the
/// unit's activation on.
/// </summary>
public sealed class ZatcaIssuer(ZatcaVault vault, ILogger<ZatcaIssuer> logger)
{
    /// <summary>Saudi time has no daylight saving: UTC+3 all year.</summary>
    public static DateTime ToRiyadh(DateTime utc) => utc.AddHours(3);

    /// <summary>Sign a committed sale. Never throws; false when it was not signed now.</summary>
    public async Task<bool> TrySignSaleAsync(NpgsqlConnection connection, string tenantId, string saleId, CancellationToken ct)
    {
        try
        {
            return await SignSaleAsync(connection, tenantId, saleId, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "ZATCA: sale {SaleId} was not signed; it will be retried.", saleId);
            return false;
        }
    }

    /// <summary>Sign a committed credit note. Never throws; false when it was not signed now.</summary>
    public async Task<bool> TrySignReturnAsync(NpgsqlConnection connection, string tenantId, string returnId, CancellationToken ct)
    {
        try
        {
            return await SignReturnAsync(connection, tenantId, returnId, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "ZATCA: credit note {ReturnId} was not signed; it will be retried.", returnId);
            return false;
        }
    }

    public async Task<bool> SignSaleAsync(NpgsqlConnection connection, string tenantId, string saleId, CancellationToken ct)
    {
        if (!vault.IsAvailable) return false;
        if (connection.State != System.Data.ConnectionState.Open) await connection.OpenAsync(ct);

        var branchId = await connection.QuerySingleOrDefaultAsync<string?>(new CommandDefinition(
            "SELECT BranchId FROM sales.Sale WHERE SaleId = @SaleId;", new { SaleId = saleId }, cancellationToken: ct));
        if (branchId is null) return false;

        await using var tx = await connection.BeginTransactionAsync(ct);

        var unit = await LockUnitAsync(connection, tx, branchId, ct);
        if (unit is null) return false;

        var sale = await connection.QuerySingleAsync<SaleRow>(new CommandDefinition(
            """
            SELECT SaleId, InvoiceNumber, SoldAtUtc, Status, DiscountH, TaxH, TotalH,
                   EXISTS (SELECT 1 FROM zatca.Document AS d WHERE d.SaleId = s.SaleId AND d.Kind = 'invoice') AS Signed
            FROM sales.Sale AS s WHERE SaleId = @SaleId;
            """, new { SaleId = saleId }, tx, cancellationToken: ct));

        if (sale.Signed || sale.Status == "voided" || sale.SoldAtUtc < unit.ActivatedAtUtc) return false;

        var lines = (await connection.QueryAsync<LineRow>(new CommandDefinition(
            """
            SELECT NameAr, NameEn, Quantity, LineNetH AS NetH, LineVatH AS VatH, VatRate, VatCategory
            FROM sales.SaleLine WHERE SaleId = @SaleId ORDER BY SaleLineId;
            """, new { SaleId = saleId }, tx, cancellationToken: ct))).ToList();

        var methods = (await connection.QueryAsync<string>(new CommandDefinition(
            "SELECT DISTINCT Method FROM sales.SalePayment WHERE SaleId = @SaleId AND AmountH > 0;",
            new { SaleId = saleId }, tx, cancellationToken: ct))).ToList();

        var document = new ZatcaDocument
        {
            Type = ZatcaDocumentType.Invoice,
            Simplified = true,
            Number = sale.InvoiceNumber,
            Uuid = Guid.NewGuid(),
            IssuedAtLocal = ToRiyadh(sale.SoldAtUtc),
            Icv = unit.LastIcv + 1,
            PreviousHash = unit.LastHash,
            Seller = await SellerAsync(connection, tx, ct),
            PaymentMeansCode = PaymentMeans(methods),
            Lines = lines.Select(ToLine).ToList(),
            AllowanceH = sale.DiscountH,
            TaxH = sale.TaxH
        };

        if (ZatcaXml.PayableH(document) != sale.TotalH)
            throw new InvalidOperationException(
                $"Sale {sale.InvoiceNumber}: the lines come to {ZatcaXml.PayableH(document)}, the sale to {sale.TotalH}.");

        var signed = Sign(document, unit, tenantId, branchId);
        await StoreAsync(connection, tx, unit, branchId, "invoice", saleId, null, document, signed, sale.SoldAtUtc, ct);

        await connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE sales.Sale
            SET ZatcaUuid = @Uuid, ZatcaCounter = @Icv, ZatcaInvoiceHash = @Hash,
                ZatcaPreviousHash = @Previous, ZatcaQrPayload = @Qr
            WHERE SaleId = @SaleId;
            """,
            new { document.Uuid, document.Icv, Hash = signed.InvoiceHash, Previous = document.PreviousHash, Qr = signed.QrBase64, SaleId = saleId },
            tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
        logger.LogInformation("ZATCA: {Invoice} signed as ICV {Icv} at {Branch}.", sale.InvoiceNumber, document.Icv, branchId);
        return true;
    }

    public async Task<bool> SignReturnAsync(NpgsqlConnection connection, string tenantId, string returnId, CancellationToken ct)
    {
        if (!vault.IsAvailable) return false;
        if (connection.State != System.Data.ConnectionState.Open) await connection.OpenAsync(ct);

        var branchId = await connection.QuerySingleOrDefaultAsync<string?>(new CommandDefinition(
            """
            SELECT COALESCE(r.BranchId, s.BranchId)
            FROM sales.SaleReturn AS r JOIN sales.Sale AS s ON s.SaleId = r.SaleId
            WHERE r.ReturnId = @ReturnId;
            """, new { ReturnId = returnId }, cancellationToken: ct));
        if (branchId is null) return false;

        await using var tx = await connection.BeginTransactionAsync(ct);

        var unit = await LockUnitAsync(connection, tx, branchId, ct);
        if (unit is null) return false;

        var note = await connection.QuerySingleAsync<ReturnRow>(new CommandDefinition(
            """
            SELECT r.ReturnId, r.NoteNumber, r.ReturnedAtUtc, r.RefundH, r.TaxH, r.ReasonCode, r.Note,
                   r.RefundMethod, s.InvoiceNumber,
                   EXISTS (SELECT 1 FROM zatca.Document AS d WHERE d.ReturnId = r.ReturnId) AS Signed
            FROM sales.SaleReturn AS r JOIN sales.Sale AS s ON s.SaleId = r.SaleId
            WHERE r.ReturnId = @ReturnId;
            """, new { ReturnId = returnId }, tx, cancellationToken: ct));

        if (note.Signed || note.ReturnedAtUtc < unit.ActivatedAtUtc || note.NoteNumber is null) return false;

        var lines = (await connection.QueryAsync<LineRow>(new CommandDefinition(
            """
            SELECT sl.NameAr, sl.NameEn, rl.Quantity, rl.LineNetH AS NetH, rl.LineVatH AS VatH,
                   rl.VatRate, rl.VatCategory
            FROM sales.SaleReturnLine AS rl JOIN sales.SaleLine AS sl ON sl.SaleLineId = rl.SaleLineId
            WHERE rl.ReturnId = @ReturnId ORDER BY rl.ReturnLineId;
            """, new { ReturnId = returnId }, tx, cancellationToken: ct))).ToList();

        var document = new ZatcaDocument
        {
            Type = ZatcaDocumentType.CreditNote,
            Simplified = true,
            Number = note.NoteNumber,
            Uuid = Guid.NewGuid(),
            IssuedAtLocal = ToRiyadh(note.ReturnedAtUtc),
            Icv = unit.LastIcv + 1,
            PreviousHash = unit.LastHash,
            Seller = await SellerAsync(connection, tx, ct),
            PaymentMeansCode = PaymentMeans(note.RefundMethod is null ? [] : [note.RefundMethod]),
            BillingReference = note.InvoiceNumber,
            Reason = Reason(note.ReasonCode, note.Note),
            Lines = lines.Select(ToLine).ToList(),
            TaxH = note.TaxH
        };

        if (ZatcaXml.PayableH(document) != note.RefundH)
            throw new InvalidOperationException(
                $"Credit note {note.NoteNumber}: the lines come to {ZatcaXml.PayableH(document)}, the refund to {note.RefundH}.");

        var signed = Sign(document, unit, tenantId, branchId);
        await StoreAsync(connection, tx, unit, branchId, "credit_note", null, returnId, document, signed, note.ReturnedAtUtc, ct);

        await connection.ExecuteAsync(new CommandDefinition(
            "UPDATE sales.SaleReturn SET ZatcaQrPayload = @Qr WHERE ReturnId = @ReturnId;",
            new { Qr = signed.QrBase64, ReturnId = returnId }, tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
        logger.LogInformation("ZATCA: {Note} signed as ICV {Icv} at {Branch}.", note.NoteNumber, document.Icv, branchId);
        return true;
    }

    /// <summary>
    /// Sign everything a branch with an active unit has left unsigned, oldest
    /// first: what a failed or interrupted signing left behind. Returns how
    /// many were signed.
    /// </summary>
    public async Task<int> SignPendingAsync(NpgsqlConnection connection, string tenantId, CancellationToken ct)
    {
        if (!vault.IsAvailable) return 0;

        var pending = (await connection.QueryAsync<(string Kind, string Id)>(new CommandDefinition(
            """
            SELECT k.Kind, k.Id FROM (
                SELECT 'sale' AS Kind, s.SaleId AS Id, s.SoldAtUtc AS At
                FROM sales.Sale AS s
                JOIN zatca.EgsUnit AS u ON u.BranchId = s.BranchId AND u.Status = 'active'
                WHERE s.ZatcaCounter IS NULL AND s.Status <> 'voided' AND s.SoldAtUtc >= u.ActivatedAtUtc
                UNION ALL
                SELECT 'return', r.ReturnId, r.ReturnedAtUtc
                FROM sales.SaleReturn AS r
                JOIN sales.Sale AS s ON s.SaleId = r.SaleId
                JOIN zatca.EgsUnit AS u ON u.BranchId = COALESCE(r.BranchId, s.BranchId) AND u.Status = 'active'
                WHERE r.ReturnedAtUtc >= u.ActivatedAtUtc
                  AND NOT EXISTS (SELECT 1 FROM zatca.Document AS d WHERE d.ReturnId = r.ReturnId)
            ) AS k
            ORDER BY k.At
            LIMIT 200;
            """, cancellationToken: ct))).ToList();

        var signed = 0;
        foreach (var (kind, id) in pending)
        {
            var ok = kind == "sale"
                ? await TrySignSaleAsync(connection, tenantId, id, ct)
                : await TrySignReturnAsync(connection, tenantId, id, ct);
            if (ok) signed++;
        }
        return signed;
    }

    /// <summary>
    /// A self-signed test unit (development only): a fresh P-256 key and a
    /// certificate that ZATCA would never accept, so nothing it signs is ever
    /// reported. Replaces any test unit the branch had; refuses a real one.
    /// </summary>
    public async Task CreateTestUnitAsync(NpgsqlConnection connection, string tenantId, string branchId, CancellationToken ct)
    {
        if (!vault.IsAvailable) throw new InvalidOperationException("The ZATCA vault has no key (Zatca:Kek).");

        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest($"CN=TEST-EGS-{branchId}, O=Nazad Test, C=SA", key, HashAlgorithmName.SHA256);
        var now = DateTimeOffset.UtcNow;
        using var certificate = request.CreateSelfSigned(now.AddMinutes(-5), now.AddYears(1));

        var keyPem = Encoding.UTF8.GetBytes(key.ExportPkcs8PrivateKeyPem());

        var rows = await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO zatca.EgsUnit (BranchId, Environment, Status, CertificateBase64, CertificateNotAfter,
                                       PrivateKeyCt, KekId, ActivatedAtUtc)
            VALUES (@BranchId, 'test', 'active', @Certificate, @NotAfter, @Key, @KekId, now() AT TIME ZONE 'utc')
            ON CONFLICT (BranchId) DO UPDATE
                SET CertificateBase64 = EXCLUDED.CertificateBase64, CertificateNotAfter = EXCLUDED.CertificateNotAfter,
                    PrivateKeyCt = EXCLUDED.PrivateKeyCt, KekId = EXCLUDED.KekId, Status = 'active',
                    UpdatedAtUtc = now() AT TIME ZONE 'utc'
                WHERE zatca.EgsUnit.Environment = 'test';
            """,
            new
            {
                BranchId = branchId,
                Certificate = Convert.ToBase64String(certificate.RawData),
                NotAfter = certificate.NotAfter.ToUniversalTime(),
                Key = vault.Seal(keyPem, ZatcaVault.Context(tenantId, branchId, "privateKey")),
                vault.KekId
            }, cancellationToken: ct));

        if (rows == 0)
            throw new InvalidOperationException("This branch is onboarded with ZATCA; a test unit cannot replace it.");
    }

    /*---------------------------------------------------------------- parts */

    private ZatcaSignedDocument Sign(ZatcaDocument document, UnitRow unit, string tenantId, string branchId)
    {
        var keyPem = Encoding.UTF8.GetString(vault.Open(unit.PrivateKeyCt, ZatcaVault.Context(tenantId, branchId, "privateKey")));
        var key = ECDsa.Create();
        key.ImportFromPem(keyPem);
        using var credential = new ZatcaCredential(new X509Certificate2(Convert.FromBase64String(unit.CertificateBase64)), key);
        return ZatcaSigner.Sign(document, credential, ToRiyadh(DateTime.UtcNow));
    }

    private static Task<UnitRow?> LockUnitAsync(NpgsqlConnection connection, NpgsqlTransaction tx, string branchId, CancellationToken ct) =>
        connection.QuerySingleOrDefaultAsync<UnitRow>(new CommandDefinition(
            """
            SELECT BranchId, Environment, CertificateBase64, PrivateKeyCt, LastIcv, LastHash, ActivatedAtUtc
            FROM zatca.EgsUnit WHERE BranchId = @BranchId AND Status = 'active'
            FOR UPDATE;
            """, new { BranchId = branchId }, tx, cancellationToken: ct));

    private static async Task StoreAsync(
        NpgsqlConnection connection, NpgsqlTransaction tx, UnitRow unit, string branchId, string kind,
        string? saleId, string? returnId, ZatcaDocument document, ZatcaSignedDocument signed, DateTime issuedAtUtc,
        CancellationToken ct)
    {
        var rows = await connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO zatca.Document
                (BranchId, Icv, Kind, Simplified, SaleId, ReturnId, DocumentNumber, Uuid, InvoiceHash,
                 PreviousHash, QrPayload, SignedXml, Environment, IssuedAtUtc, ReportingStatus, DeadlineAtUtc)
            VALUES
                (@BranchId, @Icv, @Kind, @Simplified, @SaleId, @ReturnId, @Number, @Uuid, @Hash,
                 @Previous, @Qr, @Xml, @Environment, @IssuedAtUtc, @Status, @IssuedAtUtc + interval '24 hours');

            UPDATE zatca.EgsUnit
            SET LastIcv = @Icv, LastHash = @Chain, UpdatedAtUtc = now() AT TIME ZONE 'utc'
            WHERE BranchId = @BranchId AND LastIcv = @Icv - 1;
            """,
            new
            {
                BranchId = branchId,
                document.Icv,
                Kind = kind,
                document.Simplified,
                SaleId = saleId,
                ReturnId = returnId,
                document.Number,
                document.Uuid,
                Hash = signed.InvoiceHash,
                Previous = document.PreviousHash,
                Qr = signed.QrBase64,
                Xml = signed.Xml,
                unit.Environment,
                IssuedAtUtc = issuedAtUtc,
                /* A test unit's documents are never sent anywhere. */
                Status = unit.Environment == "test" ? "not_reported" : "pending",
                Chain = signed.ChainValue
            }, tx, cancellationToken: ct));

        /* The document and the head move together, or neither does. */
        if (rows != 2)
            throw new InvalidOperationException($"The chain head of {branchId} moved while signing ICV {document.Icv}.");
    }

    private static async Task<ZatcaSeller> SellerAsync(NpgsqlConnection connection, NpgsqlTransaction? tx, CancellationToken ct)
    {
        var (seller, missing) = await CompanyAsync(connection, tx, ct);
        if (seller is null)
            throw new InvalidOperationException("The company profile is missing: "
                + string.Join(", ", missing.Select(m => CompanyField(m).En)) + ".");
        return seller;
    }

    /// <summary>What a company-profile code stands for, in English and Arabic.</summary>
    internal static (string En, string Ar) CompanyField(string code) => code switch
    {
        "vatNumber" => ("VAT number", "الرقم الضريبي"),
        "crNumber" => ("CR number", "رقم السجل التجاري"),
        "street" => ("street", "الشارع"),
        "buildingNumber" => ("building number", "رقم المبنى"),
        "district" => ("district", "الحي"),
        "city" => ("city", "المدينة"),
        "postalCode" => ("postal code", "الرمز البريدي"),
        "nameLength" => ("a company name of at most 127 bytes (about 60 Arabic letters)", "اسم منشأة لا يتجاوز 127 بايت (نحو 60 حرفًا عربيًا)"),
        "postalCodeFormat" => ("a 5-digit postal code", "رمز بريدي من 5 أرقام"),
        "company" => ("company profile", "ملف المنشأة"),
        _ => (code, code)
    };

    /// <summary>
    /// The seller as ZATCA documents state it, or what the company profile
    /// still lacks for that, as codes (see <see cref="CompanyField"/>).
    /// </summary>
    internal static async Task<(ZatcaSeller? Seller, List<string> Missing)> CompanyAsync(
        NpgsqlConnection connection, NpgsqlTransaction? tx, CancellationToken ct)
    {
        var c = await connection.QuerySingleOrDefaultAsync<CompanyRow>(new CommandDefinition(
            """
            SELECT NameAr, NameEn, VatNumber, CrNumber, Street, BuildingNumber, AdditionalNumber,
                   District, City, PostalCode
            FROM core.Company ORDER BY CompanyId LIMIT 1;
            """, transaction: tx, cancellationToken: ct));

        if (c is null) return (null, ["company"]);

        var missing = new[]
        {
            (c.VatNumber, "vatNumber"), (c.CrNumber, "crNumber"), (c.Street, "street"),
            (c.BuildingNumber, "buildingNumber"), (c.District, "district"), (c.City, "city"),
            (c.PostalCode, "postalCode")
        }.Where(f => string.IsNullOrWhiteSpace(f.Item1)).Select(f => f.Item2).ToList();

        var name = string.IsNullOrWhiteSpace(c.NameAr) ? c.NameEn : c.NameAr;
        if (Encoding.UTF8.GetByteCount(name) > 127) missing.Add("nameLength");
        if (!string.IsNullOrWhiteSpace(c.PostalCode) && !System.Text.RegularExpressions.Regex.IsMatch(c.PostalCode, "^[0-9]{5}$"))
            missing.Add("postalCodeFormat");

        if (missing.Count > 0) return (null, missing);

        return (new ZatcaSeller(name, c.VatNumber!, c.CrNumber!,
                    new ZatcaAddress(c.Street, c.BuildingNumber, c.AdditionalNumber, c.District, c.City, c.PostalCode)),
                missing);
    }

    private static ZatcaLine ToLine(LineRow l) => new(
        string.IsNullOrWhiteSpace(l.NameAr) ? l.NameEn : l.NameAr,
        l.Quantity,
        l.NetH ?? throw new InvalidOperationException("A line has no VAT split (migration 023)."),
        l.VatH ?? 0,
        l.VatRate ?? 15.00m,
        l.VatCategory);

    /// <summary>UNTDID 4461 for how it was paid; split or on account is "not defined" (1).</summary>
    private static string PaymentMeans(IReadOnlyList<string> methods) =>
        methods.Count != 1 ? "1" : methods[0] switch
        {
            "cash" => "10",
            "card" => "48",
            "bank" => "42",
            _ => "1"
        };

    private static string Reason(string? code, string? note)
    {
        var reason = code switch
        {
            "damaged" => "Damaged item returned",
            "not_as_described" => "Item not as described",
            "changed_mind" => "Customer changed their mind",
            "wrong_item" => "Wrong item supplied",
            _ => "Returned by the customer"
        };
        return string.IsNullOrWhiteSpace(note) ? reason : $"{reason}: {note.Trim()}";
    }

    private sealed record UnitRow(
        string BranchId, string Environment, string CertificateBase64, string PrivateKeyCt,
        long LastIcv, string LastHash, DateTime ActivatedAtUtc);

    private sealed record SaleRow(
        string SaleId, string InvoiceNumber, DateTime SoldAtUtc, string Status,
        long DiscountH, long TaxH, long TotalH, bool Signed);

    private sealed record ReturnRow(
        string ReturnId, string? NoteNumber, DateTime ReturnedAtUtc, long RefundH, long TaxH,
        string? ReasonCode, string? Note, string? RefundMethod, string InvoiceNumber, bool Signed);

    private sealed record LineRow(
        string NameAr, string NameEn, decimal Quantity, long? NetH, long? VatH, decimal? VatRate, string VatCategory);

    private sealed record CompanyRow(
        string NameAr, string NameEn, string? VatNumber, string? CrNumber, string? Street, string? BuildingNumber,
        string? AdditionalNumber, string? District, string? City, string? PostalCode);
}
