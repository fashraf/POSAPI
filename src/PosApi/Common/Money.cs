namespace PosApi.Common;

/// <summary>
/// Money is a whole number of halalas. 15.30 SAR is 1530.
///
/// The type is long everywhere — never decimal, never double. Floating point
/// cannot represent 0.10 exactly, so a few thousand additions drift, and a
/// ledger that drifts is a ledger that stops balancing.
/// </summary>
public static class Money
{
    public const decimal VatRate = 0.15m;

    /// <summary>
    /// VAT contained within a VAT-inclusive amount. Saudi retail quotes gross,
    /// so this is the direction a sale uses.
    /// </summary>
    public static long VatFromGross(long grossH, decimal rate)
        => (long)Math.Round(grossH * rate / (1 + rate), MidpointRounding.AwayFromZero);

    /// <summary>
    /// VAT added on top of a net amount. A supplier invoice runs this way —
    /// the opposite direction to a retail sale, and mixing the two is the most
    /// common VAT bug there is.
    /// </summary>
    public static long VatOnNet(long netH, decimal rate)
        => (long)Math.Round(netH * rate, MidpointRounding.AwayFromZero);

    public static long FromDecimal(decimal amount)
        => (long)Math.Round(amount * 100, MidpointRounding.AwayFromZero);

    public static decimal ToDecimal(long halalas) => halalas / 100m;
}
