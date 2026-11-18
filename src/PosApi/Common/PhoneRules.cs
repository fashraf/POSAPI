using System.Text.RegularExpressions;

namespace PosApi.Common;

/// <summary>
/// Phone numbers on customer and vendor records: a Saudi mobile or landline,
/// or an international number written with its country code. The same rule
/// the dashboard applies (src/lib/phone.ts), so "123" is refused here too.
/// </summary>
public static partial class PhoneRules
{
    /// <summary>Strip spacing and turn local Saudi forms into +966…; blank stays blank.</summary>
    public static string Normalise(string? value)
    {
        var compact = Spacing().Replace(value ?? string.Empty, string.Empty);
        if (compact.Length == 0) return compact;
        if (compact.StartsWith("00", StringComparison.Ordinal)) return "+" + compact[2..];
        if (compact.StartsWith('+')) return compact;
        if (compact.StartsWith("966", StringComparison.Ordinal)) return "+" + compact;
        if (SaudiLocal().IsMatch(compact)) return "+966" + compact[1..];
        if (SaudiMobileBare().IsMatch(compact)) return "+966" + compact;
        return compact;
    }

    public static bool IsValid(string? value)
    {
        var phone = Normalise(value);
        return phone.StartsWith("+966", StringComparison.Ordinal)
            ? Saudi().IsMatch(phone)
            : International().IsMatch(phone);
    }

    [GeneratedRegex(@"[\s\-().]")]
    private static partial Regex Spacing();

    [GeneratedRegex(@"^0[1-9]\d{7,8}$")]
    private static partial Regex SaudiLocal();

    [GeneratedRegex(@"^5\d{8}$")]
    private static partial Regex SaudiMobileBare();

    [GeneratedRegex(@"^\+966(5\d{8}|[1-7]\d{7}|92\d{7}|800\d{7})$")]
    private static partial Regex Saudi();

    [GeneratedRegex(@"^\+[1-9]\d{7,14}$")]
    private static partial Regex International();
}
