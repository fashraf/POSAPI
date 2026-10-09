namespace PosApi.Tenancy;

/// <summary>
/// Request counts and latency for the console's health and usage pages, in
/// memory, per minute, for the last 24 hours.
///
/// In memory because these are figures about this process: they reset on a
/// restart, and that is stated rather than hidden (StartedAtUtc). Writing a
/// row per request to the control database would make the console's own
/// health figure the thing that slows the platform down.
/// </summary>
public sealed class PlatformMetrics
{
    private const int Minutes = 24 * 60;

    private readonly object _gate = new();
    private readonly long[] _requests = new long[Minutes];
    private readonly long[] _errors = new long[Minutes];
    private readonly long[] _totalMs = new long[Minutes];
    private readonly long[] _stamp = new long[Minutes];

    public DateTime StartedAtUtc { get; } = DateTime.UtcNow;

    public void Record(int elapsedMs, bool failed)
    {
        var minute = DateTime.UtcNow.Ticks / TimeSpan.TicksPerMinute;
        var slot = (int)(minute % Minutes);

        lock (_gate)
        {
            if (_stamp[slot] != minute)
            {
                _stamp[slot] = minute;
                _requests[slot] = 0;
                _errors[slot] = 0;
                _totalMs[slot] = 0;
            }

            _requests[slot]++;
            _totalMs[slot] += elapsedMs;
            if (failed) _errors[slot]++;
        }
    }

    public sealed record Window(long Requests, long Errors, double AverageMs, long PeakPerMinute);

    /// <summary>Totals over the last <paramref name="minutes"/>, ending <paramref name="endingMinutesAgo"/> ago.</summary>
    public Window Over(int minutes, int endingMinutesAgo = 0)
    {
        var now = DateTime.UtcNow.Ticks / TimeSpan.TicksPerMinute - endingMinutesAgo;
        long requests = 0, errors = 0, totalMs = 0, peak = 0;

        lock (_gate)
        {
            for (var i = 0; i < Math.Min(minutes, Minutes); i++)
            {
                var minute = now - i;
                if (minute < 0) break;
                var slot = (int)(minute % Minutes);
                if (_stamp[slot] != minute) continue;

                requests += _requests[slot];
                errors += _errors[slot];
                totalMs += _totalMs[slot];
                peak = Math.Max(peak, _requests[slot]);
            }
        }

        return new Window(requests, errors, requests == 0 ? 0 : (double)totalMs / requests, peak);
    }
}
