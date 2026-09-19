using System.Diagnostics;
using PosApi.Auth;

namespace PosApi.Audit;

/// <summary>
/// Times every request and audits the ones that change something.
///
/// Sits high in the pipeline so the measurement includes authentication,
/// authorization and model binding — the caller waits for all of it, so all of
/// it belongs in the number. Measuring only the handler produces a figure that
/// looks healthy while the user waits.
/// </summary>
public sealed class AuditMiddleware
{
    private readonly RequestDelegate _next;
    private readonly IAuditWriter _audit;

    /* Reads are not audited by default. Auditing every GET buries the writes
       that matter under thousands of list refreshes; these are the reads worth
       recording because they expose money or personal data. */
    private static readonly string[] AuditedReads =
    [
        "/api/finance/ledger",
        "/api/finance/payroll",
        "/api/customers/receivables",
        "/api/users",
        "/api/audit"
    ];

    public AuditMiddleware(RequestDelegate next, IAuditWriter audit)
    {
        _next = next;
        _audit = audit;
    }

    public async Task InvokeAsync(HttpContext context, ICurrentUser current)
    {
        var path = context.Request.Path.Value ?? string.Empty;

        // Static assets and the health checks would swamp the table.
        if (!path.StartsWith("/api", StringComparison.OrdinalIgnoreCase))
        {
            await _next(context);
            return;
        }

        var correlationId = Guid.NewGuid().ToString("N")[..16];
        context.Items["CorrelationId"] = correlationId;
        context.Response.Headers["X-Correlation-Id"] = correlationId;

        /* The page the user came from, for the navigation trail. Sent by the
           client; the Referer header is unreliable and often stripped. */
        var currentPage = context.Request.Headers["X-Current-Page"].ToString();
        var previousPage = context.Request.Headers["X-Previous-Page"].ToString();

        var stopwatch = Stopwatch.StartNew();
        string? error = null;

        try
        {
            await _next(context);
        }
        catch (Exception ex)
        {
            /* Record the failure, then let it propagate. Swallowing it here
               would turn a 500 into a silent success. */
            error = ex.Message;
            Audit(context, current, path, correlationId, currentPage, previousPage, ex.Message, 500);
            throw;
        }
        finally
        {
            stopwatch.Stop();

            _audit.RecordTiming(new RequestTiming
            {
                CorrelationId = correlationId,
                UserId = NullIfEmpty(current.UserId),
                Username = NullIfEmpty(current.Username),
                ApiPath = path,
                HttpMethod = context.Request.Method,
                CurrentPage = NullIfEmpty(currentPage),
                PreviousPage = NullIfEmpty(previousPage),
                TotalMs = (int)stopwatch.ElapsedMilliseconds,
                DatabaseMs = context.Items["DatabaseMs"] as int? ?? 0,
                QueryCount = context.Items["QueryCount"] as int? ?? 0,
                StatusCode = context.Response.StatusCode,
                Succeeded = context.Response.StatusCode < 400 && error is null,
                ErrorMessage = error
            });
        }

        if (error is null)
        {
            Audit(context, current, path, correlationId, currentPage, previousPage,
                  null, context.Response.StatusCode);
        }
    }

    private void Audit(
        HttpContext context, ICurrentUser current, string path, string correlationId,
        string currentPage, string previousPage, string? error, int status)
    {
        var method = context.Request.Method;
        var isWrite = method is "POST" or "PUT" or "PATCH" or "DELETE";
        var isAuditedRead = AuditedReads.Any(p => path.StartsWith(p, StringComparison.OrdinalIgnoreCase));

        if (!isWrite && !isAuditedRead) return;

        _audit.Record(new AuditEntry
        {
            UserId = NullIfEmpty(current.UserId),
            Username = NullIfEmpty(current.Username),
            RoleId = NullIfEmpty(current.RoleId),
            Action = ActionFor(path, method, status),
            Module = ModuleFor(path),
            EntityType = EntityTypeFor(path),
            EntityId = context.Items["AuditEntityId"] as string,
            ApiPath = path,
            HttpMethod = method,
            CurrentPage = NullIfEmpty(currentPage),
            PreviousPage = NullIfEmpty(previousPage),
            NewValue = context.Items["AuditNewValue"] as string,
            OldValue = context.Items["AuditOldValue"] as string,
            Result = status switch
            {
                403 => "denied",
                >= 400 => "failure",
                _ => "success"
            },
            StatusCode = status,
            ErrorMessage = error,
            IpAddress = context.Connection.RemoteIpAddress?.ToString(),
            UserAgent = Truncate(context.Request.Headers.UserAgent.ToString(), 400),
            CorrelationId = correlationId
        });
    }

    private static string ActionFor(string path, string method, int status)
    {
        if (path.Contains("/auth/verify") || path.Contains("/auth/login"))
            return status < 400 ? AuditAction.Login : AuditAction.LoginFailed;

        if (path.Contains("/auth/logout")) return AuditAction.Logout;
        if (path.Contains("/void")) return AuditAction.Void;
        if (path.Contains("/reverse")) return AuditAction.Reverse;
        if (path.Contains("/collect") || path.Contains("/pay")) return AuditAction.Payment;
        if (path.Contains("/status")) return AuditAction.StatusChange;
        if (path.Contains("/api/sales") && method == "POST") return AuditAction.Payment;

        return method switch
        {
            "POST" => AuditAction.Create,
            "PUT" or "PATCH" => AuditAction.Update,
            "DELETE" => AuditAction.Delete,
            _ => AuditAction.View
        };
    }

    private static string ModuleFor(string path)
    {
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 ? parts[1] : "unknown";
    }

    private static string? EntityTypeFor(string path)
    {
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 ? parts[1].TrimEnd('s') : null;
    }

    private static string? NullIfEmpty(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value;

    private static string? Truncate(string? value, int max) =>
        string.IsNullOrWhiteSpace(value) ? null
        : value.Length <= max ? value : value[..max];
}

public static class AuditMiddlewareExtensions
{
    public static IApplicationBuilder UseAuditTrail(this IApplicationBuilder app)
        => app.UseMiddleware<AuditMiddleware>();
}
