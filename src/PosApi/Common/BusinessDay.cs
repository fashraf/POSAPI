namespace PosApi.Common;

/// <summary>
/// The shop's calendar: Saudi time (UTC+3, no daylight saving).
///
/// Timestamps are stored in UTC, but "today" for the owner starts at midnight in
/// Riyadh, not in London. Counted in UTC, sales between midnight and 03:00
/// belonged to yesterday and "Today" showed two dates.
/// </summary>
public static class BusinessDay
{
    private static readonly TimeZoneInfo Zone = Find();

    private static TimeZoneInfo Find()
    {
        foreach (var id in new[] { "Asia/Riyadh", "Arab Standard Time" })
        {
            try { return TimeZoneInfo.FindSystemTimeZoneById(id); }
            catch (TimeZoneNotFoundException) { }
            catch (InvalidTimeZoneException) { }
        }

        return TimeZoneInfo.CreateCustomTimeZone("Asia/Riyadh", TimeSpan.FromHours(3), "Riyadh", "Riyadh");
    }

    /// <summary>Minutes to add to a UTC time to get Riyadh wall-clock time.</summary>
    public static int OffsetMinutes(DateTime utc) => (int)Zone.GetUtcOffset(utc).TotalMinutes;

    /// <summary>
    /// The start, in UTC, of the business day <paramref name="daysBack"/> days
    /// before today (0 = today's midnight in Riyadh).
    /// </summary>
    public static DateTime StartUtc(DateTime nowUtc, int daysBack = 0)
    {
        var local = TimeZoneInfo.ConvertTimeFromUtc(nowUtc, Zone).Date.AddDays(-daysBack);
        return TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(local, DateTimeKind.Unspecified), Zone);
    }
}
