namespace PosApi.Features.SuperAdmin;

/// <summary>
/// The console's period picker: today, yesterday, 7d, 30d, month, 90d, 12m,
/// or custom (from/to). Each period has the one before it of the same length,
/// for the "vs previous" figures.
/// </summary>
public sealed record DateWindow(DateTime From, DateTime To, bool Monthly)
{
    public TimeSpan Length => To - From;
    public DateTime PreviousFrom => Monthly ? From.AddMonths(-12) : From - Length;
    public DateTime PreviousTo => From;

    public static DateWindow Parse(string? range, DateOnly? from = null, DateOnly? to = null)
    {
        var today = DateTime.UtcNow.Date;
        var tomorrow = today.AddDays(1);

        return range switch
        {
            "today" => new(today, tomorrow, false),
            "yesterday" => new(today.AddDays(-1), today, false),
            "7d" => new(today.AddDays(-6), tomorrow, false),
            "month" => new(new DateTime(today.Year, today.Month, 1, 0, 0, 0, DateTimeKind.Utc), tomorrow, false),
            "90d" => new(today.AddDays(-89), tomorrow, false),
            "12m" => new(new DateTime(today.Year, today.Month, 1, 0, 0, 0, DateTimeKind.Utc).AddMonths(-11), tomorrow, true),
            "custom" when from is { } f && to is { } t && t >= f =>
                new(f.ToDateTime(TimeOnly.MinValue), t.ToDateTime(TimeOnly.MinValue).AddDays(1), (t.DayNumber - f.DayNumber) > 92),
            _ => new(today.AddDays(-29), tomorrow, false),
        };
    }

    public sealed record Bucket(string Label, DateTime Start, DateTime End);

    public IEnumerable<Bucket> Buckets()
    {
        if (Monthly)
        {
            for (var m = new DateTime(From.Year, From.Month, 1); m < To; m = m.AddMonths(1))
                yield return new Bucket(m.ToString("MMM"), m, m.AddMonths(1) < To ? m.AddMonths(1) : To);
            yield break;
        }

        for (var d = From.Date; d < To; d = d.AddDays(1))
            yield return new Bucket(d.ToString("MM-dd"), d, d.AddDays(1));
    }
}
