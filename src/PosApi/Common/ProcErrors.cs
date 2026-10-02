namespace PosApi.Common;

/// <summary>
/// The three ways a save procedure says no, as responses.
///
/// Every admin route maps its procedure's THROW numbers onto one of these. One
/// place for the shapes means a 422 from the user screen and a 422 from the
/// discount screen carry the same fields, so the client reads them one way.
/// </summary>
public static class ProcErrors
{
    /// <summary>422 naming the field, so the form can put the message beside it.</summary>
    public static IResult Field(string field, string messageEn, string messageAr) =>
        Results.UnprocessableEntity(ApiError.Create(
            "validation_failed", messageEn, messageAr,
            new Dictionary<string, string[]> { [field] = [messageEn] }));

    /// <summary>
    /// 409: the request was well formed, the record's current state is what
    /// prevents it.
    /// </summary>
    public static IResult Conflict(string code, string messageEn, string messageAr) =>
        Results.Conflict(ApiError.Create(code, messageEn, messageAr));

    public static IResult NotFound(string messageEn, string messageAr) =>
        Results.NotFound(ApiError.Create("not_found", messageEn, messageAr));

    public static IResult Forbidden(string code, string messageEn, string messageAr) =>
        Results.Json(ApiError.Create(code, messageEn, messageAr), statusCode: StatusCodes.Status403Forbidden);

    /// <summary>"" and whitespace are "not given", never a value.</summary>
    public static string? Blank(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    /// <summary>A distinct, trimmed, comma-joined set for a procedure's CSV parameter.</summary>
    public static string Csv(IEnumerable<string>? values) =>
        string.Join(',', (values ?? Array.Empty<string>()).Select(v => (v ?? string.Empty).Trim())
                                       .Where(v => v.Length > 0)
                                       .Distinct(StringComparer.OrdinalIgnoreCase));
}
