using System.Text.Json;

namespace PosApi.Data;

/// <summary>
/// A list handed to a database function as one jsonb parameter.
///
/// The functions read it with jsonb_populate_recordset(NULL::sales.SaleLineTable,
/// @Lines), which matches keys to the row type's fields by exact name — and
/// PostgreSQL stores those names in lower case. The keys are written in lower
/// case to match; anything else would arrive as NULL in every field.
///
/// Pass the result with a cast in the SQL: sales.usp_CommitSale(p_Lines =>
/// @Lines::jsonb, ...). A string parameter is text, and text does not convert to
/// jsonb implicitly.
/// </summary>
public static class DbList
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = new LowerCase()
    };

    public static string Json<T>(IEnumerable<T> rows) => JsonSerializer.Serialize(rows, Options);

    private sealed class LowerCase : JsonNamingPolicy
    {
        public override string ConvertName(string name) => name.ToLowerInvariant();
    }
}
