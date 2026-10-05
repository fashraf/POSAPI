using System.Data;
using System.Text.Json;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Localization;

namespace PosApi.Features.Settings;

public sealed record CompanyAddressDto(
    string Street, string District, string City, string PostalCode, string Country);

/// <summary>
/// The business as printed on every invoice.
///
/// Text fields come back as "" rather than missing when empty: the profile form
/// binds every one of them, and an absent key would arrive as undefined.
/// </summary>
public sealed record CompanyDto(
    string NameEn,
    string NameAr,
    string Name,
    string Description,
    string DescriptionAr,
    string DescriptionEn,
    string? LogoUrl,
    string CrNumber,
    string VatNumber,
    string Phone,
    string Email,
    string Website,
    CompanyAddressDto Address,
    IReadOnlyDictionary<string, string> Social,
    DateTime CreatedAt,
    DateTime UpdatedAt);

/// <summary>
/// Replace the company profile.
///
/// The screen has one description box. <c>Description</c> fills
/// DescriptionEn when that is not sent; either language column sent as null
/// keeps what is stored, so a form that only knows one language cannot wipe
/// the other. Send "" to clear one.
/// </summary>
public sealed record SaveCompanyRequest(
    string NameEn,
    string NameAr,
    string? Description,
    string? DescriptionAr,
    string? DescriptionEn,
    string? LogoUrl,
    string? CrNumber,
    string? VatNumber,
    string? Phone,
    string? Email,
    string? Website,
    CompanyAddressDto? Address,
    IReadOnlyDictionary<string, string?>? Social);

/// <summary>A bill or ticket layout. Field names match the bill builder.</summary>
public sealed record BillTemplateDto
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Audience { get; init; }
    public string? PrintGroupId { get; init; }
    public bool IsDefault { get; init; }
    public required string Status { get; init; }
    public required string PaperSize { get; init; }
    public required string Language { get; init; }
    public required string HeaderAlignment { get; init; }
    public bool ShowLogo { get; init; }
    public required string LogoSize { get; init; }
    public bool ShowCompanyName { get; init; }
    public bool ShowDescription { get; init; }
    public bool ShowVatNumber { get; init; }
    public bool ShowCrNumber { get; init; }
    public bool ShowAddress { get; init; }
    public bool ShowItemName { get; init; }
    public bool ShowSku { get; init; }
    public bool ShowBarcode { get; init; }
    public bool ShowUnitPrice { get; init; }
    public bool ShowQuantity { get; init; }
    public bool ShowLineTotal { get; init; }
    public bool ShowLineDiscount { get; init; }
    public bool ShowSubtotal { get; init; }
    public bool ShowDiscount { get; init; }
    public bool ShowVat { get; init; }
    public bool ShowGrandTotal { get; init; }
    public required string FooterEn { get; init; }
    public required string FooterAr { get; init; }
    public bool ShowZatcaQr { get; init; }
    public DateTime CreatedAt { get; init; }
    public DateTime UpdatedAt { get; init; }
}

/// <summary>
/// Create or edit a template. Anything left out takes the bill builder's own
/// default, so a field the client forgets does not silently turn off the
/// total on a receipt.
/// </summary>
public sealed record SaveBillTemplateRequest
{
    public string Name { get; init; } = string.Empty;
    public string Audience { get; init; } = "customer";
    public string? PrintGroupId { get; init; }
    public bool IsDefault { get; init; }
    public string Status { get; init; } = "active";
    public string PaperSize { get; init; } = "80mm";
    public string Language { get; init; } = "both";
    public string HeaderAlignment { get; init; } = "center";
    public bool ShowLogo { get; init; } = true;
    public string LogoSize { get; init; } = "md";
    public bool ShowCompanyName { get; init; } = true;
    public bool ShowDescription { get; init; } = true;
    public bool ShowVatNumber { get; init; } = true;
    public bool ShowCrNumber { get; init; } = true;
    public bool ShowAddress { get; init; }
    public bool ShowItemName { get; init; } = true;
    public bool ShowSku { get; init; }
    public bool ShowBarcode { get; init; }
    public bool ShowUnitPrice { get; init; } = true;
    public bool ShowQuantity { get; init; } = true;
    public bool ShowLineTotal { get; init; } = true;
    public bool ShowLineDiscount { get; init; }
    public bool ShowSubtotal { get; init; } = true;
    public bool ShowDiscount { get; init; } = true;
    public bool ShowVat { get; init; } = true;
    public bool ShowGrandTotal { get; init; } = true;
    public string? FooterEn { get; init; }
    public string? FooterAr { get; init; }
    public bool ShowZatcaQr { get; init; } = true;
}

public static partial class CompanyEndpoints
{
    /// <summary>The platforms the profile screen offers. Anything else is dropped.</summary>
    private static readonly string[] SocialKeys = ["instagram", "facebook", "x", "tiktok", "linkedin", "youtube"];

    public static void MapCompanyEndpoints(this IEndpointRouteBuilder app)
    {
        var company = app.MapGroup("/api/company")
            .WithTags("Company")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        company.MapGet("", GetCompanyAsync)
               .RequireAuthorization(PermissionPolicy.For("company.view"));

        company.MapPut("", SaveCompanyAsync)
               .RequireAuthorization(PermissionPolicy.For("company.edit"));

        var bills = app.MapGroup("/api/bill-templates")
            .WithTags("Bill templates")
            .RequireAuthorization()
            .RequireRateLimiting("standard");

        bills.MapGet("", ListTemplatesAsync)
             .RequireAuthorization(PermissionPolicy.For("bill_builder.view"));

        /* Any signed-in user: the till resolves a template at print time, and a
           cashier does not hold bill_builder.view. */
        bills.MapGet("/resolve", ResolveTemplateAsync);

        bills.MapGet("/{billId}", GetTemplateAsync)
             .RequireAuthorization(PermissionPolicy.For("bill_builder.view"));

        bills.MapPost("", CreateTemplateAsync)
             .RequireAuthorization(PermissionPolicy.For("bill_builder.edit"));

        bills.MapPut("/{billId}", UpdateTemplateAsync)
             .RequireAuthorization(PermissionPolicy.For("bill_builder.edit"));

        bills.MapDelete("/{billId}", DeleteTemplateAsync)
             .RequireAuthorization(PermissionPolicy.For("bill_builder.edit"));
    }

    [GeneratedRegex(@"^[^\s@]+@[^\s@]+\.[^\s@]+$")]
    private static partial Regex EmailPattern();

    /*================================================================= company */

    private static async Task<IResult> GetCompanyAsync(
        ISqlConnectionFactory db, ILanguageContext language, CancellationToken ct)
    {
        await using var connection = db.Create();

        var company = await LoadCompanyAsync(connection, language, ct);

        return company is null
            ? ProcErrors.NotFound("No company record exists.", "لا يوجد سجل للشركة.")
            : Results.Ok(company);
    }

    private static async Task<IResult> SaveCompanyAsync(
        SaveCompanyRequest request,
        ISqlConnectionFactory db,
        ICurrentUser current,
        ILanguageContext language,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        var email = ProcErrors.Blank(request.Email);

        if (email is not null && !EmailPattern().IsMatch(email))
            return ProcErrors.Field("email", "Enter a valid email address, or leave it empty.",
                                    "أدخل بريدًا إلكترونيًا صحيحًا أو اتركه فارغًا.");

        await using var connection = db.Create();

        var stored = await connection.QuerySingleOrDefaultAsync<(string? DescriptionAr, string? DescriptionEn)>(
            new CommandDefinition("SELECT TOP (1) DescriptionAr, DescriptionEn FROM core.Company;",
                                  cancellationToken: ct));

        /* Only the known platforms, and only those filled in. */
        var social = SocialKeys
            .Select(k => (Key: k, Value: request.Social?.GetValueOrDefault(k)?.Trim()))
            .Where(s => !string.IsNullOrEmpty(s.Value))
            .ToDictionary(s => s.Key, s => s.Value!);

        var parameters = new DynamicParameters();
        parameters.Add("@NameAr", request.NameAr?.Trim());
        parameters.Add("@NameEn", request.NameEn?.Trim());
        parameters.Add("@DescriptionAr",
            request.DescriptionAr is null ? stored.DescriptionAr : ProcErrors.Blank(request.DescriptionAr));
        parameters.Add("@DescriptionEn",
            request.DescriptionEn is not null ? ProcErrors.Blank(request.DescriptionEn)
            : request.Description is not null ? ProcErrors.Blank(request.Description)
            : stored.DescriptionEn);
        parameters.Add("@LogoUrl", ProcErrors.Blank(request.LogoUrl));
        parameters.Add("@CrNumber", ProcErrors.Blank(request.CrNumber));
        parameters.Add("@VatNumber", ProcErrors.Blank(request.VatNumber));
        parameters.Add("@Phone", ProcErrors.Blank(request.Phone));
        parameters.Add("@Email", email);
        parameters.Add("@Website", ProcErrors.Blank(request.Website));
        parameters.Add("@Street", ProcErrors.Blank(request.Address?.Street));
        parameters.Add("@District", ProcErrors.Blank(request.Address?.District));
        parameters.Add("@City", ProcErrors.Blank(request.Address?.City));
        parameters.Add("@PostalCode", ProcErrors.Blank(request.Address?.PostalCode));
        parameters.Add("@Country", ProcErrors.Blank(request.Address?.Country));
        parameters.Add("@SocialLinks", social.Count == 0 ? null : JsonSerializer.Serialize(social));

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SaveCompany", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is >= 62000 and < 62020)
        {
            return ex.Number switch
            {
                62003 => ProcErrors.NotFound("No company record exists.", "لا يوجد سجل للشركة."),
                62000 => ProcErrors.Field(string.IsNullOrWhiteSpace(request.NameAr) ? "nameAr" : "nameEn",
                    "Both company names are required.", "اسما الشركة العربي والإنجليزي مطلوبان."),
                62001 => ProcErrors.Field("vatNumber",
                    "A Saudi VAT number is 15 digits, starting and ending with 3.",
                    "الرقم الضريبي ١٥ رقمًا يبدأ وينتهي بالرقم ٣."),
                62002 => ProcErrors.Field("crNumber", "A CR number is 10 digits.", "رقم السجل التجاري ١٠ أرقام."),
                _ => ProcErrors.Field("social", "The social links are not valid.", "روابط التواصل غير صالحة.")
            };
        }

        logger.LogInformation("Company profile updated by {Actor}.", current.Username);
        http.Items["AuditEntityId"] = "company";

        return Results.Ok(await LoadCompanyAsync(connection, language, ct));
    }

    private static async Task<CompanyDto?> LoadCompanyAsync(
        SqlConnection connection, ILanguageContext language, CancellationToken ct)
    {
        var r = await connection.QuerySingleOrDefaultAsync<CompanyRow>(new CommandDefinition(
            """
            SELECT TOP (1) NameAr, NameEn, DescriptionAr, DescriptionEn, LogoUrl, CrNumber,
                   VatNumber, Phone, Email, Website, Street, District, City, PostalCode,
                   Country, SocialLinks, CreatedAtUtc, UpdatedAtUtc
            FROM core.Company ORDER BY CompanyId;
            """,
            cancellationToken: ct));

        if (r is null) return null;

        Dictionary<string, string>? stored = null;
        if (!string.IsNullOrWhiteSpace(r.SocialLinks))
        {
            try { stored = JsonSerializer.Deserialize<Dictionary<string, string>>(r.SocialLinks); }
            catch (JsonException) { /* A hand-edited value: show nothing rather than fail the page. */ }
        }

        var social = SocialKeys.ToDictionary(k => k, k => stored?.GetValueOrDefault(k) ?? string.Empty);

        return new CompanyDto(
            r.NameEn, r.NameAr, language.Pick(r.NameAr, r.NameEn),
            language.Pick(r.DescriptionAr ?? r.DescriptionEn ?? string.Empty,
                          r.DescriptionEn ?? r.DescriptionAr ?? string.Empty),
            r.DescriptionAr ?? string.Empty, r.DescriptionEn ?? string.Empty,
            r.LogoUrl, r.CrNumber ?? string.Empty, r.VatNumber ?? string.Empty,
            r.Phone ?? string.Empty, r.Email ?? string.Empty, r.Website ?? string.Empty,
            new CompanyAddressDto(r.Street ?? string.Empty, r.District ?? string.Empty,
                                  r.City ?? string.Empty, r.PostalCode ?? string.Empty,
                                  r.Country ?? string.Empty),
            social, r.CreatedAtUtc, r.UpdatedAtUtc);
    }

    /*=========================================================== bill templates */

    private static async Task<IResult> ListTemplatesAsync(ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();
        return Results.Ok(await LoadTemplatesAsync(connection, null, ct));
    }

    private static async Task<IResult> GetTemplateAsync(
        string billId, ISqlConnectionFactory db, CancellationToken ct)
    {
        await using var connection = db.Create();

        var template = (await LoadTemplatesAsync(connection, billId, ct)).SingleOrDefault();

        return template is null ? TemplateNotFound() : Results.Ok(template);
    }

    /// <summary>
    /// The template a document should print with: the active ticket for that
    /// print group if there is one, otherwise the default customer bill. A
    /// group with no ticket layout still prints — on the customer layout —
    /// rather than not at all.
    /// </summary>
    private static async Task<IResult> ResolveTemplateAsync(
        ISqlConnectionFactory db, string? audience, string? printGroupId, CancellationToken ct)
    {
        await using var connection = db.Create();

        var all = await LoadTemplatesAsync(connection, null, ct);

        var match =
            (audience == "group" && printGroupId is not null
                ? all.FirstOrDefault(t => t.Audience == "group" && t.PrintGroupId == printGroupId
                                          && t.Status == "active")
                : null)
            ?? all.FirstOrDefault(t => t.Audience == "customer" && t.IsDefault && t.Status == "active")
            ?? all.FirstOrDefault(t => t.Audience == "customer" && t.Status == "active");

        return match is null ? TemplateNotFound() : Results.Ok(match);
    }

    private static Task<IResult> CreateTemplateAsync(
        SaveBillTemplateRequest request, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveTemplateAsync(null, request, db, current, http, logger, ct);

    private static Task<IResult> UpdateTemplateAsync(
        string billId, SaveBillTemplateRequest request, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct) =>
        SaveTemplateAsync(billId, request, db, current, http, logger, ct);

    /// <summary>
    /// Through core.usp_SaveBillTemplate, which keeps one default per audience
    /// and refuses a customer receipt without a total.
    /// </summary>
    private static async Task<IResult> SaveTemplateAsync(
        string? billId,
        SaveBillTemplateRequest r,
        ISqlConnectionFactory db,
        ICurrentUser current,
        HttpContext http,
        ILogger<Program> logger,
        CancellationToken ct)
    {
        if (r.Status is not ("active" or "inactive"))
            return ProcErrors.Field("status", "Status must be active or inactive.", "الحالة إما نشط أو غير نشط.");

        var parameters = new DynamicParameters();
        parameters.Add("@BillId", billId);
        parameters.Add("@Name", r.Name?.Trim());
        parameters.Add("@Audience", r.Audience);
        parameters.Add("@PrintGroupId", ProcErrors.Blank(r.PrintGroupId));
        parameters.Add("@IsDefault", r.IsDefault);
        parameters.Add("@PaperSize", r.PaperSize?.ToLowerInvariant());
        parameters.Add("@BillLanguage", r.Language);
        parameters.Add("@HeaderAlignment", r.HeaderAlignment);
        parameters.Add("@LogoSize", r.LogoSize);
        parameters.Add("@ShowLogo", r.ShowLogo);
        parameters.Add("@ShowCompanyName", r.ShowCompanyName);
        parameters.Add("@ShowDescription", r.ShowDescription);
        parameters.Add("@ShowVatNumber", r.ShowVatNumber);
        parameters.Add("@ShowCrNumber", r.ShowCrNumber);
        parameters.Add("@ShowAddress", r.ShowAddress);
        parameters.Add("@ShowItemName", r.ShowItemName);
        parameters.Add("@ShowSku", r.ShowSku);
        parameters.Add("@ShowBarcode", r.ShowBarcode);
        parameters.Add("@ShowUnitPrice", r.ShowUnitPrice);
        parameters.Add("@ShowQuantity", r.ShowQuantity);
        parameters.Add("@ShowLineTotal", r.ShowLineTotal);
        parameters.Add("@ShowLineDiscount", r.ShowLineDiscount);
        parameters.Add("@ShowSubtotal", r.ShowSubtotal);
        parameters.Add("@ShowDiscount", r.ShowDiscount);
        parameters.Add("@ShowVat", r.ShowVat);
        parameters.Add("@ShowGrandTotal", r.ShowGrandTotal);
        parameters.Add("@ShowZatcaQr", r.ShowZatcaQr);
        parameters.Add("@FooterAr", ProcErrors.Blank(r.FooterAr));
        parameters.Add("@FooterEn", ProcErrors.Blank(r.FooterEn));
        parameters.Add("@IsActive", r.Status == "active");
        parameters.Add("@SavedId", dbType: DbType.String, direction: ParameterDirection.Output, size: 40);

        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_SaveBillTemplate", parameters,
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapTemplateError(ex) is { } mapped)
        {
            return mapped;
        }

        var savedId = parameters.Get<string>("@SavedId");

        logger.LogInformation("Bill template {BillId} {Action} by {Actor}.",
            savedId, billId is null ? "created" : "updated", current.Username);
        http.Items["AuditEntityId"] = savedId;

        var template = (await LoadTemplatesAsync(connection, savedId, ct)).Single();

        return billId is null
            ? Results.Created($"/api/bill-templates/{savedId}", template)
            : Results.Ok(template);
    }

    /// <summary>
    /// A real delete: a printed receipt does not record which layout drew it,
    /// so nothing historical is orphaned. The audience default, and a template
    /// a branch uses as its default bill, are refused with 409 instead.
    /// </summary>
    private static async Task<IResult> DeleteTemplateAsync(
        string billId, ISqlConnectionFactory db, ICurrentUser current,
        HttpContext http, ILogger<Program> logger, CancellationToken ct)
    {
        await using var connection = db.Create();

        try
        {
            await connection.ExecuteAsync(new CommandDefinition(
                "core.usp_DeleteBillTemplate", new { BillId = billId },
                commandType: CommandType.StoredProcedure, cancellationToken: ct));
        }
        catch (SqlException ex) when (MapTemplateError(ex) is { } mapped)
        {
            return mapped;
        }

        logger.LogInformation("Bill template {BillId} deleted by {Actor}.", billId, current.Username);
        http.Items["AuditEntityId"] = billId;

        return Results.NoContent();
    }

    private static IResult TemplateNotFound() =>
        ProcErrors.NotFound("No such template.", "لا يوجد قالب بهذا المعرف.");

    private static IResult? MapTemplateError(SqlException ex) => ex.Number switch
    {
        62026 => TemplateNotFound(),
        62029 => ProcErrors.Conflict("default_template",
            "Make another template the default before deleting this one.",
            "اجعل قالبًا آخر افتراضيًا قبل حذف هذا القالب."),
        62030 => ProcErrors.Conflict("template_in_use",
            "A branch uses this as its default bill. Change that branch first.",
            "أحد الفروع يستخدم هذا القالب كفاتورة افتراضية. غيّر إعداد الفرع أولًا."),
        62020 => ProcErrors.Field("name", "Give the template a name.", "أدخل اسمًا للقالب."),
        62021 => ProcErrors.Field("paperSize", "Paper size must be 58mm, 80mm or a4.", "حجم الورق 58mm أو 80mm أو a4."),
        62022 => ProcErrors.Field("audience", "A template is for the customer or for a print group.", "القالب إما للعميل أو لمجموعة طباعة."),
        62023 => ProcErrors.Field("printGroupId", "Choose which print group this ticket is for.", "اختر مجموعة الطباعة لهذه التذكرة."),
        62024 => ProcErrors.Field("printGroupId", "No such print group.", "لا توجد مجموعة طباعة بهذا المعرف."),
        62025 => ProcErrors.Field("showGrandTotal", "A customer receipt must show the total.", "يجب أن تظهر فاتورة العميل الإجمالي."),
        /* ZATCA simplified tax invoice fields — see core.usp_SaveBillTemplate. */
        62031 => ProcErrors.Field("showVatNumber", "A customer receipt is a tax invoice and must show the VAT number.",
            "فاتورة العميل فاتورة ضريبية ويجب أن يظهر فيها الرقم الضريبي."),
        62032 => ProcErrors.Field("showVat", "A customer receipt is a tax invoice and must show the VAT amount.",
            "فاتورة العميل فاتورة ضريبية ويجب أن يظهر فيها مبلغ الضريبة."),
        62033 => ProcErrors.Field("showZatcaQr", "A customer receipt is a tax invoice and must show the ZATCA QR code.",
            "فاتورة العميل فاتورة ضريبية ويجب أن يظهر فيها رمز الاستجابة السريعة (زاتكا)."),
        62027 => ProcErrors.Field("language", "Language must be ar, en or both.", "اللغة ar أو en أو both."),
        62028 => ProcErrors.Field("headerAlignment", "That header layout is not recognised.", "تنسيق الترويسة غير معروف."),
        _ => null
    };

    private static async Task<List<BillTemplateDto>> LoadTemplatesAsync(
        SqlConnection connection, string? billId, CancellationToken ct)
    {
        var rows = await connection.QueryAsync<BillTemplateRow>(new CommandDefinition(
            """
            SELECT BillId, Name, Audience, PrintGroupId, IsDefault, PaperSize, BillLanguage,
                   HeaderAlignment, LogoSize, ShowLogo, ShowCompanyName, ShowDescription,
                   ShowVatNumber, ShowCrNumber, ShowAddress, ShowItemName, ShowSku, ShowBarcode,
                   ShowUnitPrice, ShowQuantity, ShowLineTotal, ShowLineDiscount, ShowSubtotal,
                   ShowDiscount, ShowVat, ShowGrandTotal, ShowZatcaQr, FooterAr, FooterEn,
                   IsActive, CreatedAtUtc, UpdatedAtUtc
            FROM core.BillTemplate
            WHERE @BillId IS NULL OR BillId = @BillId
            ORDER BY CASE Audience WHEN N'customer' THEN 0 ELSE 1 END, Name;
            """,
            new { BillId = billId }, cancellationToken: ct));

        return rows.Select(t => new BillTemplateDto
        {
            Id = t.BillId,
            Name = t.Name,
            Audience = t.Audience,
            PrintGroupId = t.PrintGroupId,
            IsDefault = t.IsDefault,
            Status = t.IsActive ? "active" : "inactive",
            PaperSize = t.PaperSize.ToLowerInvariant(),
            Language = t.BillLanguage,
            HeaderAlignment = t.HeaderAlignment,
            ShowLogo = t.ShowLogo,
            LogoSize = t.LogoSize,
            ShowCompanyName = t.ShowCompanyName,
            ShowDescription = t.ShowDescription,
            ShowVatNumber = t.ShowVatNumber,
            ShowCrNumber = t.ShowCrNumber,
            ShowAddress = t.ShowAddress,
            ShowItemName = t.ShowItemName,
            ShowSku = t.ShowSku,
            ShowBarcode = t.ShowBarcode,
            ShowUnitPrice = t.ShowUnitPrice,
            ShowQuantity = t.ShowQuantity,
            ShowLineTotal = t.ShowLineTotal,
            ShowLineDiscount = t.ShowLineDiscount,
            ShowSubtotal = t.ShowSubtotal,
            ShowDiscount = t.ShowDiscount,
            ShowVat = t.ShowVat,
            ShowGrandTotal = t.ShowGrandTotal,
            FooterEn = t.FooterEn ?? string.Empty,
            FooterAr = t.FooterAr ?? string.Empty,
            ShowZatcaQr = t.ShowZatcaQr,
            CreatedAt = t.CreatedAtUtc,
            UpdatedAt = t.UpdatedAtUtc
        }).ToList();
    }

    private sealed record CompanyRow
    {
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? DescriptionAr { get; init; }
        public string? DescriptionEn { get; init; }
        public string? LogoUrl { get; init; }
        public string? CrNumber { get; init; }
        public string? VatNumber { get; init; }
        public string? Phone { get; init; }
        public string? Email { get; init; }
        public string? Website { get; init; }
        public string? Street { get; init; }
        public string? District { get; init; }
        public string? City { get; init; }
        public string? PostalCode { get; init; }
        public string? Country { get; init; }
        public string? SocialLinks { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
    }

    private sealed record BillTemplateRow
    {
        public string BillId { get; init; } = string.Empty;
        public string Name { get; init; } = string.Empty;
        public string Audience { get; init; } = string.Empty;
        public string? PrintGroupId { get; init; }
        public bool IsDefault { get; init; }
        public string PaperSize { get; init; } = string.Empty;
        public string BillLanguage { get; init; } = string.Empty;
        public string HeaderAlignment { get; init; } = string.Empty;
        public string LogoSize { get; init; } = string.Empty;
        public bool ShowLogo { get; init; }
        public bool ShowCompanyName { get; init; }
        public bool ShowDescription { get; init; }
        public bool ShowVatNumber { get; init; }
        public bool ShowCrNumber { get; init; }
        public bool ShowAddress { get; init; }
        public bool ShowItemName { get; init; }
        public bool ShowSku { get; init; }
        public bool ShowBarcode { get; init; }
        public bool ShowUnitPrice { get; init; }
        public bool ShowQuantity { get; init; }
        public bool ShowLineTotal { get; init; }
        public bool ShowLineDiscount { get; init; }
        public bool ShowSubtotal { get; init; }
        public bool ShowDiscount { get; init; }
        public bool ShowVat { get; init; }
        public bool ShowGrandTotal { get; init; }
        public bool ShowZatcaQr { get; init; }
        public string? FooterAr { get; init; }
        public string? FooterEn { get; init; }
        public bool IsActive { get; init; }
        public DateTime CreatedAtUtc { get; init; }
        public DateTime UpdatedAtUtc { get; init; }
    }
}
