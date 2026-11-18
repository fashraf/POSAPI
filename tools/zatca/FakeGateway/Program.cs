// A stand-in for ZATCA's e-invoicing gateway (Fatoora API v2), for development
// and tests. Never point a production server at it: the API refuses a gateway
// override outside Development, and only on a loopback address.
//
// It behaves the way the real one was measured to (developer kit, 2026):
//   - Accept-Version must be V2 (406 otherwise);
//   - POST  /{env}/compliance            OTP 123456 issues a compliance CSID for the
//                                        CSR's key; any other OTP is HTTP 400
//   - POST  /{env}/compliance/invoices   checks the invoice hash and signature: PASS (200)
//   - POST  /{env}/production/csids      a production CSID for the same key
//   - PATCH /{env}/production/csids      renewal: new CSR, OTP, current CSID
//   - POST  /{env}/invoices/reporting/single, /clearance/single
//
// FAKE_ZATCA_MODE changes one answer for a test: "production-timeout" holds the
// production-CSID call for 60 s; "report-400" rejects every report;
// "report-500" fails every report; "report-401" refuses the credential.
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json.Nodes;
using PosApi.Features.Zatca;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

using var caKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
var caRequest = new CertificateRequest("CN=FAKE-ZATCA-CA, DC=fake, DC=local", caKey, HashAlgorithmName.SHA256);
caRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
using var ca = caRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(5));

var credentials = new ConcurrentDictionary<string, (string Secret, string Kind, X509Certificate2 Cert, long RequestId)>();
var mode = () => Environment.GetEnvironmentVariable("FAKE_ZATCA_MODE") ?? "";
long nextRequestId = 1234567890000;

IResult Json(int status, JsonNode body) =>
    Results.Content(body.ToJsonString(), "application/json", Encoding.UTF8, status);

JsonObject Validation(string status, params string[] errors) => new()
{
    ["validationResults"] = new JsonObject
    {
        ["infoMessages"] = new JsonArray(),
        ["warningMessages"] = new JsonArray(),
        ["errorMessages"] = new JsonArray(errors.Select(e => (JsonNode)new JsonObject { ["code"] = "FAKE", ["message"] = e }).ToArray()),
        ["status"] = status
    }
};

bool Versioned(HttpRequest request) => request.Headers["Accept-Version"] == "V2";

(string Token, string Secret, string Kind, X509Certificate2 Cert, long RequestId)? Caller(HttpRequest request)
{
    var header = request.Headers.Authorization.ToString();
    if (!header.StartsWith("Basic ", StringComparison.Ordinal)) return null;
    var pair = Encoding.UTF8.GetString(Convert.FromBase64String(header[6..])).Split(':', 2);
    return pair.Length == 2 && credentials.TryGetValue(pair[0], out var c) && c.Secret == pair[1]
        ? (pair[0], c.Secret, c.Kind, c.Cert, c.RequestId) : null;
}

JsonObject Issue(string csrApiText, string kind)
{
    var pem = Encoding.UTF8.GetString(Convert.FromBase64String(csrApiText));
    var csr = CertificateRequest.LoadSigningRequestPem(pem, HashAlgorithmName.SHA256,
        CertificateRequestLoadOptions.UnsafeLoadCertificateExtensions);
    var serial = RandomNumberGenerator.GetBytes(12);
    serial[0] &= 0x7F;
    using var issued = csr.Create(ca, DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(1), serial);
    var cert = new X509Certificate2(issued.RawData);
    var token = Convert.ToBase64String(Encoding.ASCII.GetBytes(Convert.ToBase64String(cert.RawData)));
    var secret = Convert.ToBase64String(RandomNumberGenerator.GetBytes(24));
    var requestId = Interlocked.Increment(ref nextRequestId);
    credentials[token] = (secret, kind, cert, requestId);
    return new JsonObject
    {
        ["requestID"] = requestId,
        ["dispositionMessage"] = "ISSUED",
        ["binarySecurityToken"] = token,
        ["secret"] = secret,
        ["errors"] = null
    };
}

/* A document is accepted when its hash is what it states and its signature is the caller's key's. */
string? CheckDocument(JsonNode body, X509Certificate2 cert)
{
    var xml = Encoding.UTF8.GetString(Convert.FromBase64String(body["invoice"]!.ToString()));
    var hash = ZatcaHash.InvoiceHash(xml);
    if (hash != body["invoiceHash"]?.ToString()) return "invoiceHash does not match the invoice";
    if (!xml.Contains(body["uuid"]!.ToString(), StringComparison.Ordinal)) return "uuid does not match the invoice";
    var signature = System.Text.RegularExpressions.Regex.Match(xml, "<ds:SignatureValue>([^<]+)<").Groups[1].Value;
    var ok = cert.GetECDsaPublicKey()!.VerifyData(Convert.FromBase64String(hash), Convert.FromBase64String(signature),
        HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
    return ok ? null : "the signature does not verify against the certificate";
}

app.MapPost("/{env}/compliance", async (HttpRequest request) =>
{
    if (!Versioned(request)) return Results.StatusCode(406);
    var body = await JsonNode.ParseAsync(request.Body);
    if (request.Headers["OTP"] != "123456")
        return Json(400, new JsonObject { ["errors"] = new JsonArray("Invalid-OTP") });
    return Json(200, Issue(body!["csr"]!.ToString(), "compliance"));
});

app.MapPost("/{env}/compliance/invoices", async (HttpRequest request) =>
{
    if (!Versioned(request)) return Results.StatusCode(406);
    if (Caller(request) is not { Kind: "compliance" } caller) return Results.StatusCode(401);
    var body = await JsonNode.ParseAsync(request.Body);
    var problem = CheckDocument(body!, caller.Cert);
    var result = problem is null ? Validation("PASS") : Validation("ERROR", problem);
    result["reportingStatus"] = problem is null ? "REPORTED" : "NOT_REPORTED";
    return Json(problem is null ? 200 : 400, result);
});

app.MapPost("/{env}/production/csids", async (HttpRequest request) =>
{
    if (!Versioned(request)) return Results.StatusCode(406);
    if (Caller(request) is not { Kind: "compliance" } caller) return Results.StatusCode(401);
    var body = await JsonNode.ParseAsync(request.Body);
    if (body?["compliance_request_id"]?.ToString() != caller.RequestId.ToString(System.Globalization.CultureInfo.InvariantCulture))
        return Json(400, new JsonObject { ["errors"] = new JsonArray("Invalid-Request-ID") });
    if (mode() == "production-timeout") await Task.Delay(TimeSpan.FromSeconds(60));

    /* A production certificate for the compliance certificate's key. */
    var key = caller.Cert.GetECDsaPublicKey()!;
    var req = new CertificateRequest(caller.Cert.SubjectName, key, HashAlgorithmName.SHA256);
    foreach (var extension in caller.Cert.Extensions) req.CertificateExtensions.Add(extension);
    var serial = RandomNumberGenerator.GetBytes(12);
    serial[0] &= 0x7F;
    using var issued = req.Create(ca, DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(1), serial);
    var cert = new X509Certificate2(issued.RawData);
    var token = Convert.ToBase64String(Encoding.ASCII.GetBytes(Convert.ToBase64String(cert.RawData)));
    var secret = Convert.ToBase64String(RandomNumberGenerator.GetBytes(24));
    credentials[token] = (secret, "production", cert, Interlocked.Increment(ref nextRequestId));
    return Json(200, new JsonObject
    {
        ["requestID"] = credentials[token].RequestId, ["dispositionMessage"] = "ISSUED",
        ["binarySecurityToken"] = token, ["secret"] = secret, ["errors"] = null
    });
});

app.MapMethods("/{env}/production/csids", ["PATCH"], async (HttpRequest request) =>
{
    if (!Versioned(request)) return Results.StatusCode(406);
    if (Caller(request) is not { Kind: "production" }) return Results.StatusCode(401);
    var body = await JsonNode.ParseAsync(request.Body);
    if (request.Headers["OTP"] != "123456")
        return Json(400, new JsonObject { ["errors"] = new JsonArray("Invalid-OTP") });
    return Json(200, Issue(body!["csr"]!.ToString(), "production"));
});

app.MapPost("/{env}/invoices/{kind}/single", async (string kind, HttpRequest request) =>
{
    if (!Versioned(request)) return Results.StatusCode(406);
    if (mode() == "report-401" || Caller(request) is not { Kind: "production" } caller) return Results.StatusCode(401);
    if (mode() == "report-500") return Results.StatusCode(500);
    var body = await JsonNode.ParseAsync(request.Body);
    var problem = mode() == "report-400" ? "rejected by FAKE_ZATCA_MODE" : CheckDocument(body!, caller.Cert);
    var result = problem is null ? Validation("PASS") : Validation("ERROR", problem);
    if (kind == "clearance")
    {
        result["clearanceStatus"] = problem is null ? "CLEARED" : "NOT_CLEARED";
        if (problem is null) result["clearedInvoice"] = body!["invoice"]!.ToString();
    }
    else
    {
        result["reportingStatus"] = problem is null ? "REPORTED" : "NOT_REPORTED";
    }
    return Json(problem is null ? 200 : 400, result);
});

app.Run();
