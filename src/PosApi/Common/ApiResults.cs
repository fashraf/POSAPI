using System.Diagnostics;

namespace PosApi.Common;

/// <summary>
/// A bilingual error payload.
///
/// The frontend renders in Arabic or English depending on the user, so an error
/// carries both. Returning only English would leave an Arabic user with a
/// message they cannot read at the exact moment something went wrong.
/// </summary>
public sealed record ApiError
{
    public required string Code { get; init; }
    public required string MessageEn { get; init; }
    public required string MessageAr { get; init; }
    public IDictionary<string, string[]>? FieldErrors { get; init; }
    public string? TraceId { get; init; }

    public static ApiError Create(
        string code,
        string messageEn,
        string messageAr,
        IDictionary<string, string[]>? fieldErrors = null) =>
        new()
        {
            Code = code,
            MessageEn = messageEn,
            MessageAr = messageAr,
            FieldErrors = fieldErrors,
            TraceId = Activity.Current?.Id
        };
}

public sealed record PagedResult<T>
{
    public required IReadOnlyList<T> Items { get; init; }
    public required int Page { get; init; }
    public required int PageSize { get; init; }
    public required int TotalCount { get; init; }
    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling(TotalCount / (double)PageSize);
}

public sealed record PageQuery
{
    private const int MaxPageSize = 200;

    public int Page { get; init; } = 1;

    private readonly int _pageSize = 25;

    /// <summary>
    /// Capped. An unbounded page size lets one request pull the whole table and
    /// take the server down with it.
    /// </summary>
    public int PageSize
    {
        get => _pageSize;
        init => _pageSize = value switch
        {
            < 1 => 25,
            > MaxPageSize => MaxPageSize,
            _ => value
        };
    }

    public int Offset => (Math.Max(1, Page) - 1) * PageSize;
}
