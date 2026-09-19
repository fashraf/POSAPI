namespace PosApi.Localization;

public interface ILanguageContext
{
    string Language { get; }
    bool IsRtl { get; }

    /// <summary>Pick the string for the caller's language.</summary>
    string Pick(string arabic, string english);
}

/// <summary>
/// Which language the caller wants.
///
/// Responses carry NameAr and NameEn as well as the resolved Name, so a client
/// that switches language in the UI does not need to refetch — it already holds
/// both. The resolved field exists for clients that would rather not choose.
/// </summary>
public sealed class LanguageContext : ILanguageContext
{
    private static readonly HashSet<string> Rtl =
        new(StringComparer.OrdinalIgnoreCase) { "ar", "ur", "fa", "he" };

    public LanguageContext(IHttpContextAccessor accessor)
    {
        var header = accessor.HttpContext?.Request.Headers["Accept-Language"].ToString();

        // Arabic by default: this is a Saudi product, and defaulting to English
        // makes the majority of users change a setting before they can read it.
        Language = ParseLanguage(header) ?? "ar";
    }

    public string Language { get; }
    public bool IsRtl => Rtl.Contains(Language);

    public string Pick(string arabic, string english)
        => Language.Equals("en", StringComparison.OrdinalIgnoreCase)
            ? english
            : arabic;

    private static string? ParseLanguage(string? header)
    {
        if (string.IsNullOrWhiteSpace(header)) return null;

        // "ar-SA,ar;q=0.9,en;q=0.8" -> "ar"
        var first = header.Split(',')[0].Split(';')[0].Trim();
        if (first.Length < 2) return null;

        return first[..2].ToLowerInvariant();
    }
}
