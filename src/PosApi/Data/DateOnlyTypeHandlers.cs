using System.Data;
using Dapper;

namespace PosApi.Data;

/// <summary>
/// Teach Dapper to pass DateOnly and TimeOnly to SQL Server.
///
/// Microsoft.Data.SqlClient has no conversion for these types. Handing one to a
/// parameter throws "Failed to convert parameter value from a DateOnly to a
/// DateTime" — which surfaces as a 500 on any endpoint that takes a date filter,
/// with nothing in the message connecting it to the date.
///
/// Reading has the same gap in reverse: a DATE column comes back as DateTime,
/// and Dapper cannot map it onto a DateOnly property without being told how.
/// That one hides until a row has a non-null date — so it passes every test
/// against seed data where the column happens to be empty.
/// </summary>
public sealed class DateOnlyTypeHandler : SqlMapper.TypeHandler<DateOnly>
{
    public override void SetValue(IDbDataParameter parameter, DateOnly value)
    {
        parameter.DbType = DbType.Date;
        parameter.Value = value.ToDateTime(TimeOnly.MinValue);
    }

    public override DateOnly Parse(object value) => value switch
    {
        DateTime dateTime => DateOnly.FromDateTime(dateTime),
        DateOnly dateOnly => dateOnly,
        string text => DateOnly.Parse(text),
        _ => throw new InvalidCastException(
            $"Cannot read {value?.GetType().Name ?? "null"} as a DateOnly.")
    };
}

public sealed class TimeOnlyTypeHandler : SqlMapper.TypeHandler<TimeOnly>
{
    public override void SetValue(IDbDataParameter parameter, TimeOnly value)
    {
        parameter.DbType = DbType.Time;
        parameter.Value = value.ToTimeSpan();
    }

    public override TimeOnly Parse(object value) => value switch
    {
        TimeSpan span => TimeOnly.FromTimeSpan(span),
        DateTime dateTime => TimeOnly.FromDateTime(dateTime),
        TimeOnly timeOnly => timeOnly,
        string text => TimeOnly.Parse(text),
        _ => throw new InvalidCastException(
            $"Cannot read {value?.GetType().Name ?? "null"} as a TimeOnly.")
    };
}

public static class DapperConfiguration
{
    /// <summary>
    /// Register the handlers. Call once, before any query runs.
    ///
    /// The nullable variants are registered explicitly: Dapper resolves
    /// DateOnly? separately from DateOnly, and a filter left blank arrives as
    /// the nullable form — which is the common case for a date range.
    /// </summary>
    public static void Configure()
    {
        SqlMapper.AddTypeHandler(new DateOnlyTypeHandler());
        SqlMapper.AddTypeHandler(new TimeOnlyTypeHandler());

        SqlMapper.AddTypeMap(typeof(DateOnly), DbType.Date);
        SqlMapper.AddTypeMap(typeof(DateOnly?), DbType.Date);
        SqlMapper.AddTypeMap(typeof(TimeOnly), DbType.Time);
        SqlMapper.AddTypeMap(typeof(TimeOnly?), DbType.Time);
    }
}
