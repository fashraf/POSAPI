using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using PosApi.Features.Zatca;
using Xunit;
using Xunit.Abstractions;

namespace PosApi.Tests.Zatca;

/// <summary>
/// Documents we write and sign, as one chain: every kind the POS issues.
/// Checked here (hash, signature, chain, QR) and, when the ZATCA SDK is
/// unpacked beside POSAPI, by ZATCA's own validator.
/// </summary>
public sealed class ZatcaSigningTests(ITestOutputHelper output)
{
    private static readonly ZatcaSeller Seller = new(
        "متجر النور | Al Noor Store", "301234567800003", "1010010000",
        new ZatcaAddress("طريق الملك فهد | King Fahd Rd", "8228", "2121", "العليا | Olaya", "الرياض | Riyadh", "12211"));

    private static readonly ZatcaBuyer Buyer = new(
        "شركة أكمي | Acme Trading", "310122393500003", "CRN", "4030000000",
        new ZatcaAddress("التحلية | Tahlia St", "4321", null, "الروضة | Rawdah", "جدة | Jeddah", "23434"));

    /// <summary>The chain: what a branch would issue, in order.</summary>
    private static List<ZatcaDocument> Chain(DateTime day)
    {
        ZatcaDocument Doc(int icv, ZatcaDocumentType type, bool simplified, string number, ZatcaLine[] lines,
                          long taxH, long allowanceH = 0, string payment = "10", string? reference = null,
                          string? reason = null, ZatcaBuyer? buyer = null) => new()
        {
            Type = type,
            Simplified = simplified,
            Number = number,
            Uuid = Guid.NewGuid(),
            IssuedAtLocal = day.AddMinutes(icv),
            Icv = icv,
            PreviousHash = ZatcaHash.Genesis, // chained as they are signed
            Seller = Seller,
            Buyer = buyer,
            PaymentMeansCode = payment,
            BillingReference = reference,
            Reason = reason,
            Lines = lines,
            AllowanceH = allowanceH,
            TaxH = taxH
        };

        return
        [
            /* INV-1002 from the migration 023 test: a weighed quantity, a line
               discount and an invoice discount (stored figures, unchanged). */
            Doc(1, ZatcaDocumentType.Invoice, true, "INV-1002",
            [
                new("طماطم | Tomatoes (kg)", 0.333m, 304, 45),
                new("ماء <1.5L> & ثلج", 3m, 736, 111),
                new("قهوة | Coffee", 1m, 1043, 157)
            ], taxH: 295, allowanceH: 119, payment: "48"),

            /* CN-200: one of the three waters back, its share of the discount off. */
            Doc(2, ZatcaDocumentType.CreditNote, true, "CN-200",
                [new("ماء <1.5L> & ثلج", 1m, 231, 35)], taxH: 35, payment: "48",
                reference: "INV-1002", reason: "Damaged | تالف"),

            Doc(3, ZatcaDocumentType.DebitNote, true, "DN-1",
                [new("فرق سعر | Price correction", 1m, 87, 13)], taxH: 13,
                reference: "INV-1002", reason: "Price corrected | تصحيح السعر"),

            /* A standard (B2B) invoice and its credit note. */
            Doc(4, ZatcaDocumentType.Invoice, false, "INV-1003",
            [
                new("طابعة | Printer", 2m, 104348, 15652),
                new("ورق | Paper", 10m, 8696, 1304)
            ], taxH: 16956, payment: "42", buyer: Buyer),

            Doc(5, ZatcaDocumentType.CreditNote, false, "CN-201",
                [new("ورق | Paper", 5m, 4348, 652)], taxH: 652, payment: "42",
                reference: "INV-1003", reason: "Returned | مرتجع", buyer: Buyer),

            Doc(6, ZatcaDocumentType.Invoice, true, "INV-1004",
                [new("حلاقة | Haircut", 1m, 4348, 652)], taxH: 652)
        ];
    }

    private static ZatcaCredential TestCredential()
    {
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=TEST-EGS-0001, O=Nazad Test, C=SA", key, HashAlgorithmName.SHA256);
        var now = DateTimeOffset.UtcNow;
        using var certificate = request.CreateSelfSigned(now.AddDays(-1), now.AddDays(30));
        return new ZatcaCredential(new X509Certificate2(certificate.RawData), key);
    }

    private static List<ZatcaSignedDocument> SignChain(ZatcaCredential credential, out List<ZatcaDocument> documents)
    {
        var riyadhNow = DateTime.UtcNow.AddHours(3);
        documents = Chain(new DateTime(riyadhNow.Year, riyadhNow.Month, riyadhNow.Day, riyadhNow.Hour, 0, 0, DateTimeKind.Unspecified).AddHours(-1));

        var signed = new List<ZatcaSignedDocument>();
        var previous = ZatcaHash.Genesis;
        for (var i = 0; i < documents.Count; i++)
        {
            documents[i] = documents[i] with { PreviousHash = previous };
            var result = ZatcaSigner.Sign(documents[i], credential);
            signed.Add(result);
            previous = result.ChainValue;
        }
        return signed;
    }

    [Fact]
    public void Signed_documents_hash_sign_and_chain_as_stated()
    {
        using var credential = TestCredential();
        var signed = SignChain(credential, out var documents);

        for (var i = 0; i < signed.Count; i++)
        {
            var s = signed[i];
            Assert.Equal(s.InvoiceHash, ZatcaHash.InvoiceHash(s.Xml));
            Assert.True(credential.Certificate.GetECDsaPublicKey()!.VerifyData(
                Convert.FromBase64String(s.InvoiceHash), Convert.FromBase64String(s.SignatureBase64),
                HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence));
            Assert.True(s.QrBase64.Length <= ZatcaTlv.MaxBase64Length);
            Assert.Equal(s.ChainValue, ZatcaHash.ChainValue(s.InvoiceHash));
            if (i > 0) Assert.Contains(signed[i - 1].ChainValue, s.Xml, StringComparison.Ordinal);

            var tags = ZatcaTlv.Decode(s.QrBase64);
            Assert.Equal(ZatcaXml.Money(ZatcaXml.PayableH(documents[i])), System.Text.Encoding.UTF8.GetString(tags[3].Value));
        }

        /* The figures the receipt states: 2396 gross − 137 discount = 22.59. */
        Assert.Contains("<cbc:PayableAmount currencyID=\"SAR\">22.59</cbc:PayableAmount>", signed[0].Xml, StringComparison.Ordinal);
        Assert.Contains("<cbc:TaxExclusiveAmount currencyID=\"SAR\">19.64</cbc:TaxExclusiveAmount>", signed[0].Xml, StringComparison.Ordinal);
    }

    [Fact]
    public void A_document_that_does_not_add_up_is_refused()
    {
        var bad = Chain(DateTime.Today)[1] with { BillingReference = null };
        Assert.Throws<ArgumentException>(() => ZatcaXml.Write(bad));

        var mixed = Chain(DateTime.Today)[0] with
        {
            Lines = [new("a", 1m, 100, 15), new("b", 1m, 100, 0, 0m, "Z")]
        };
        Assert.Throws<NotSupportedException>(() => ZatcaXml.Write(mixed));
    }

    /// <summary>The whole chain through ZATCA's validator (skipped when the SDK is not here).</summary>
    [Fact]
    public async Task Zatca_validator_accepts_the_signed_chain()
    {
        if (Paths.Sdk is null)
        {
            output.WriteLine("ZATCA SDK not found beside POSAPI (or ZATCA_SDK_HOME); validator run skipped.");
            return;
        }

        using var credential = TestCredential();
        var signed = SignChain(credential, out _);

        var folder = Path.Combine(AppContext.BaseDirectory, "zatca-signed");
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        Directory.CreateDirectory(folder);
        for (var i = 0; i < signed.Count; i++)
            File.WriteAllText(Path.Combine(folder, $"{i + 1:00}.xml"), signed[i].Xml, new System.Text.UTF8Encoding(false));

        var run = new ProcessStartInfo("bash", [Paths.ValidateScript, folder])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            Environment = { ["ZATCA_SDK_HOME"] = Paths.Sdk }
        };
        using var process = Process.Start(run)!;
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        output.WriteLine(stdout + stderr);

        Assert.True(process.ExitCode == 0, $"ZATCA's validator refused the chain:\n{stdout}{stderr}");
        Assert.DoesNotContain("[warning]", stdout, StringComparison.Ordinal);
    }
}
