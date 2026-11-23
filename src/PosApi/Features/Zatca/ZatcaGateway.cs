using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PosApi.Features.Zatca;

/// <summary>ZATCA's answer to one call, or how the call failed to get one.</summary>
public sealed record ZatcaCallResult(
    /* "response", "timeout" or "network". */
    string Outcome,
    int? Status,
    JsonNode? Body)
{
    public bool Ok => Outcome == "response" && Status is 200 or 202;

    public string? Text(string property) => Body?[property]?.ToString();

    /// <summary>
    /// ZATCA's own reason for refusing, as one line: the codes and messages of
    /// "errors" (strings or objects), "message"/"code" and the validation
    /// errors. Empty when the answer carries none.
    /// </summary>
    public string Reason()
    {
        var parts = new List<string>();

        void Add(JsonNode? node)
        {
            switch (node)
            {
                case JsonArray array:
                    foreach (var item in array) Add(item);
                    break;
                case JsonObject item:
                    var code = item["code"]?.ToString();
                    var message = item["message"]?.ToString();
                    var text = string.Join(": ", new[] { code, message }.Where(t => !string.IsNullOrWhiteSpace(t)));
                    if (text.Length > 0) parts.Add(text);
                    break;
                case JsonValue value when !string.IsNullOrWhiteSpace(value.ToString()):
                    parts.Add(value.ToString());
                    break;
            }
        }

        Add(Body?["errors"]);
        Add(Body?["validationResults"]?["errorMessages"]);
        if (parts.Count == 0 && Body is JsonObject body && (body["message"] is not null || body["code"] is not null)) Add(body);
        if (parts.Count == 0 && Body?["dispositionMessage"] is { } disposition) Add(disposition);

        return string.Join("; ", parts.Distinct());
    }

    /// <summary>True when ZATCA names the OTP as the problem (or gives no reason at all, as an OTP refusal often does).</summary>
    public bool BlamesOtp()
    {
        var reason = Reason();
        return reason.Length == 0 || reason.Contains("OTP", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>ZATCA's messages, for the record: codes and texts, never a secret.</summary>
    public JsonNode Summary()
    {
        var summary = new JsonObject { ["outcome"] = Outcome, ["status"] = Status };
        foreach (var key in new[] { "validationResults", "errors", "dispositionMessage", "reportingStatus", "clearanceStatus", "message", "code" })
        {
            if (Body?[key] is { } value) summary[key] = value.DeepClone();
        }
        return summary;
    }
}

/// <summary>A CSID: ZATCA's binarySecurityToken (base64 of the certificate's base64) and its secret.</summary>
public sealed record ZatcaCsid(string BinarySecurityToken, string Secret);

/// <summary>
/// The calls to ZATCA's e-invoicing gateway (Fatoora API v2), and nothing else.
///
/// One fixed origin, https://gw-fatoora.zatca.gov.sa/e-invoicing/{developer-portal
/// | simulation | core}; Zatca:GatewayBaseUrl overrides it only for a loopback
/// test server in development. No redirects. The OTP and the CSID go into
/// headers per call and are never logged; ZatcaCallResult.Summary keeps only
/// codes and messages.
///
/// Measured behaviour the callers rely on (developer kit, 2026): a wrong OTP is
/// HTTP 400, not 401; a compliance check that passes with warnings is 202.
/// </summary>
public sealed class ZatcaGateway(HttpClient http, IConfiguration configuration, IWebHostEnvironment environment)
{
    public const string Origin = "https://gw-fatoora.zatca.gov.sa/e-invoicing/";

    public static readonly string[] Environments = ["developer-portal", "simulation", "core"];

    private Uri Base(string zatcaEnvironment)
    {
        if (!Environments.Contains(zatcaEnvironment))
            throw new ArgumentOutOfRangeException(nameof(zatcaEnvironment), zatcaEnvironment, "Not a ZATCA environment.");

        var testBase = configuration["Zatca:GatewayBaseUrl"];
        if (!string.IsNullOrWhiteSpace(testBase))
        {
            var uri = new Uri(testBase.TrimEnd('/') + "/");
            if (!environment.IsDevelopment() || !uri.IsLoopback)
                throw new InvalidOperationException("Zatca:GatewayBaseUrl is for a loopback test server in development only.");
            return new Uri(uri, zatcaEnvironment + "/");
        }

        return new Uri(Origin + zatcaEnvironment + "/");
    }

    /// <summary>POST /compliance: a compliance CSID for the CSR, with the owner's OTP.</summary>
    public Task<ZatcaCallResult> ComplianceCsidAsync(string env, string otp, string csrForApi, CancellationToken ct) =>
        SendAsync(HttpMethod.Post, env, "compliance", new JsonObject { ["csr"] = csrForApi }, otp: otp, ct: ct);

    /// <summary>POST /compliance/invoices: one compliance sample, signed with the compliance CSID's key.</summary>
    public Task<ZatcaCallResult> ComplianceInvoiceAsync(string env, ZatcaCsid csid, ZatcaSignedDocument document, Guid uuid, CancellationToken ct) =>
        SendAsync(HttpMethod.Post, env, "compliance/invoices", InvoiceBody(document, uuid), csid, ct: ct);

    /// <summary>POST /production/csids: the production CSID, after the samples passed.</summary>
    public Task<ZatcaCallResult> ProductionCsidAsync(string env, ZatcaCsid compliance, string complianceRequestId, CancellationToken ct) =>
        SendAsync(HttpMethod.Post, env, "production/csids",
            new JsonObject { ["compliance_request_id"] = complianceRequestId }, compliance, ct: ct);

    /// <summary>PATCH /production/csids: renewal, a new CSR with a fresh OTP, authenticated by the current CSID.</summary>
    public Task<ZatcaCallResult> RenewProductionCsidAsync(string env, ZatcaCsid current, string otp, string csrForApi, CancellationToken ct) =>
        SendAsync(HttpMethod.Patch, env, "production/csids", new JsonObject { ["csr"] = csrForApi }, current, otp, ct: ct);

    /// <summary>POST /invoices/reporting/single: a simplified document (within 24 hours).</summary>
    public Task<ZatcaCallResult> ReportAsync(string env, ZatcaCsid csid, string invoiceHash, Guid uuid, string signedXml, CancellationToken ct) =>
        SendAsync(HttpMethod.Post, env, "invoices/reporting/single", InvoiceBody(invoiceHash, uuid, signedXml), csid,
            clearanceStatus: "0", ct: ct);

    /// <summary>POST /invoices/clearance/single: a standard document, cleared before the buyer gets it.</summary>
    public Task<ZatcaCallResult> ClearAsync(string env, ZatcaCsid csid, string invoiceHash, Guid uuid, string signedXml, CancellationToken ct) =>
        SendAsync(HttpMethod.Post, env, "invoices/clearance/single", InvoiceBody(invoiceHash, uuid, signedXml), csid,
            clearanceStatus: "1", ct: ct);

    private static JsonObject InvoiceBody(ZatcaSignedDocument document, Guid uuid) =>
        InvoiceBody(document.InvoiceHash, uuid, document.Xml);

    private static JsonObject InvoiceBody(string invoiceHash, Guid uuid, string signedXml) => new()
    {
        ["invoiceHash"] = invoiceHash,
        ["uuid"] = uuid.ToString("D"),
        ["invoice"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(signedXml))
    };

    private async Task<ZatcaCallResult> SendAsync(
        HttpMethod method, string env, string path, JsonObject body,
        ZatcaCsid? csid = null, string? otp = null, string? clearanceStatus = null, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(method, new Uri(Base(env), path))
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json")
        };
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.AcceptLanguage.Add(new StringWithQualityHeaderValue("en"));
        request.Headers.Add("Accept-Version", "V2");
        if (otp is not null) request.Headers.Add("OTP", otp);
        if (clearanceStatus is not null) request.Headers.Add("Clearance-Status", clearanceStatus);
        if (csid is not null)
            request.Headers.Authorization = new AuthenticationHeaderValue("Basic",
                Convert.ToBase64String(Encoding.UTF8.GetBytes($"{csid.BinarySecurityToken}:{csid.Secret}")));

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));

        try
        {
            using var response = await http.SendAsync(request, timeout.Token);
            var text = await response.Content.ReadAsStringAsync(timeout.Token);
            JsonNode? parsed = null;
            try { parsed = string.IsNullOrWhiteSpace(text) ? null : JsonNode.Parse(text); }
            catch (JsonException) { /* not JSON: kept as no body */ }
            return new ZatcaCallResult("response", (int)response.StatusCode, parsed);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return new ZatcaCallResult("timeout", null, null);
        }
        catch (HttpRequestException)
        {
            return new ZatcaCallResult("network", null, null);
        }
    }

    /// <summary>The handler: no redirects, no cookies.</summary>
    public static HttpMessageHandler Handler() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.All
    };
}
