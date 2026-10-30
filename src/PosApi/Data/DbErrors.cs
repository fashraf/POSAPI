using Npgsql;

namespace PosApi.Data;

/// <summary>
/// The number a database refusal carries, read the same way everywhere.
///
/// The database functions refuse with RAISE EXCEPTION '...' USING DETAIL =
/// '52003': the message is the sentence for the user, the detail the number the
/// endpoint maps to a response. These numbers are the ones the SQL Server
/// procedures used with THROW, so every endpoint's mapping carried over as it
/// was.
///
/// Constraint violations get the numbers SQL Server gave them, for the same
/// reason: 2627 for a duplicate key, 547 for a missing or still-referenced row.
/// </summary>
public static class DbErrors
{
    public const int UniqueViolation = 2627;
    public const int ForeignKeyViolation = 547;
    public const int CheckViolation = 547;

    public static int ErrorNumber(this PostgresException ex) => ex.SqlState switch
    {
        PostgresErrorCodes.RaiseException when int.TryParse(ex.Detail, out var number) => number,
        PostgresErrorCodes.UniqueViolation => UniqueViolation,
        PostgresErrorCodes.ForeignKeyViolation => ForeignKeyViolation,
        PostgresErrorCodes.CheckViolation => CheckViolation,
        _ => 0
    };

    /// <summary>True when a unique index or constraint refused the row.</summary>
    public static bool IsUniqueViolation(this PostgresException ex) =>
        ex.SqlState == PostgresErrorCodes.UniqueViolation;
}
