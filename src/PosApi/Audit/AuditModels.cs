namespace PosApi.Audit;

/// <summary>What happened. Failures are recorded as well as successes.</summary>
public static class AuditAction
{
    public const string Create = "CREATE";
    public const string Update = "UPDATE";
    public const string Delete = "DELETE";
    public const string View = "VIEW";
    public const string Login = "LOGIN";
    public const string LoginFailed = "LOGIN_FAILED";
    public const string Logout = "LOGOUT";
    public const string Payment = "PAYMENT";
    public const string StatusChange = "STATUS_CHANGE";
    public const string Void = "VOID";
    public const string Reverse = "REVERSE";
    public const string Export = "EXPORT";
}

public sealed record AuditEntry
{
    public string? UserId { get; init; }
    public string? Username { get; init; }
    public string? RoleId { get; init; }

    public required string Action { get; init; }
    public required string Module { get; init; }
    public string? EntityType { get; init; }
    public string? EntityId { get; init; }

    public string? ApiPath { get; init; }
    public string? HttpMethod { get; init; }
    public string? CurrentPage { get; init; }
    public string? PreviousPage { get; init; }
    public string? BranchId { get; init; }

    public string? OldValue { get; init; }
    public string? NewValue { get; init; }
    public string? Details { get; init; }

    public string Result { get; init; } = "success";
    public int? StatusCode { get; init; }
    public string? ErrorMessage { get; init; }

    public string? IpAddress { get; init; }
    public string? UserAgent { get; init; }
    public string? CorrelationId { get; init; }
}

public sealed record RequestTiming
{
    public required string CorrelationId { get; init; }
    public string? UserId { get; init; }
    public string? Username { get; init; }
    public required string ApiPath { get; init; }
    public required string HttpMethod { get; init; }
    public string? CurrentPage { get; init; }
    public string? PreviousPage { get; init; }
    public required int TotalMs { get; init; }
    public int DatabaseMs { get; init; }
    public int QueryCount { get; init; }
    public required int StatusCode { get; init; }
    public required bool Succeeded { get; init; }
    public string? ErrorMessage { get; init; }
    public int? ResponseBytes { get; init; }
}
