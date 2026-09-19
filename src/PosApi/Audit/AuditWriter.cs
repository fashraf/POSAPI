using System.Threading.Channels;
using Dapper;
using PosApi.Data;

namespace PosApi.Audit;

public interface IAuditWriter
{
    void Record(AuditEntry entry);
    void RecordTiming(RequestTiming timing);
}

/// <summary>
/// Writes audit and timing rows without making the caller wait.
///
/// Both are observations about a request, not part of it. Writing them inline
/// would add a database round trip to every call and — worse — a failure to
/// record an observation would fail the operation being observed. Queued here
/// and drained by a background reader instead.
///
/// The queue is bounded and drops the oldest entry when full. Unbounded would
/// mean a database outage turns into memory exhaustion, and telemetry taking
/// the process down is a worse outcome than losing telemetry.
/// </summary>
public sealed class AuditWriter : IAuditWriter
{
    private readonly Channel<object> _queue;
    private readonly ILogger<AuditWriter> _logger;

    public AuditWriter(ILogger<AuditWriter> logger)
    {
        _logger = logger;
        _queue = Channel.CreateBounded<object>(new BoundedChannelOptions(10_000)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true
        });
    }

    internal ChannelReader<object> Reader => _queue.Reader;

    public void Record(AuditEntry entry)
    {
        if (!_queue.Writer.TryWrite(entry))
        {
            _logger.LogWarning("Audit queue is full; an entry was dropped.");
        }
    }

    public void RecordTiming(RequestTiming timing) => _queue.Writer.TryWrite(timing);
}

/// <summary>Drains the queue into SQL Server.</summary>
public sealed class AuditDrainService : BackgroundService
{
    private readonly AuditWriter _writer;
    private readonly ISqlConnectionFactory _db;
    private readonly ILogger<AuditDrainService> _logger;

    public AuditDrainService(
        IAuditWriter writer, ISqlConnectionFactory db, ILogger<AuditDrainService> logger)
    {
        _writer = (AuditWriter)writer;
        _db = db;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var item in _writer.Reader.ReadAllAsync(stoppingToken))
        {
            try
            {
                await using var connection = _db.Create();

                if (item is AuditEntry entry)
                {
                    await connection.ExecuteAsync(
                        """
                        INSERT INTO audit.AuditEntry
                            (UserId, Username, RoleId, Action, Module, EntityType, EntityId,
                             ApiPath, HttpMethod, CurrentPage, PreviousPage, BranchId,
                             OldValue, NewValue, Details, Result, StatusCode, ErrorMessage,
                             IpAddress, UserAgent, CorrelationId)
                        VALUES
                            (@UserId, @Username, @RoleId, @Action, @Module, @EntityType, @EntityId,
                             @ApiPath, @HttpMethod, @CurrentPage, @PreviousPage, @BranchId,
                             @OldValue, @NewValue, @Details, @Result, @StatusCode, @ErrorMessage,
                             @IpAddress, @UserAgent, @CorrelationId);
                        """, entry);
                }
                else if (item is RequestTiming timing)
                {
                    await connection.ExecuteAsync(
                        """
                        INSERT INTO audit.RequestTiming
                            (CorrelationId, UserId, Username, ApiPath, HttpMethod,
                             CurrentPage, PreviousPage, TotalMs, DatabaseMs, QueryCount,
                             StatusCode, Succeeded, ErrorMessage, ResponseBytes)
                        VALUES
                            (@CorrelationId, @UserId, @Username, @ApiPath, @HttpMethod,
                             @CurrentPage, @PreviousPage, @TotalMs, @DatabaseMs, @QueryCount,
                             @StatusCode, @Succeeded, @ErrorMessage, @ResponseBytes);
                        """, timing);
                }
            }
            catch (Exception ex)
            {
                /* Never rethrow. A failure to record an observation must not
                   stop the drain, and must certainly not affect the request
                   that produced it — which has already completed. */
                _logger.LogError(ex, "Could not write an audit or timing row.");
            }
        }
    }
}
