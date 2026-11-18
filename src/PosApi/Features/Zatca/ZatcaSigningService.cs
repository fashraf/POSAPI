using Dapper;
using Npgsql;
using PosApi.Tenancy;

namespace PosApi.Features.Zatca;

/// <summary>
/// Signs what was left unsigned: a sale or credit note whose signing failed
/// or was interrupted after it was committed (see <see cref="ZatcaIssuer"/>).
/// Every minute, every tenant, oldest first. A tenant without an active EGS
/// unit costs one cheap query.
/// </summary>
public sealed class ZatcaSigningService(
    TenancyConnections connections, ZatcaIssuer issuer, ZatcaVault vault, ILogger<ZatcaSigningService> logger)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!vault.IsAvailable) return;

        /* Let startup and tenant migrations finish first. */
        await Task.Delay(TimeSpan.FromSeconds(20), stoppingToken);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await PassAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "ZATCA signing pass failed.");
            }

            await Task.Delay(TimeSpan.FromMinutes(1), stoppingToken);
        }
    }

    public async Task PassAsync(CancellationToken ct)
    {
        await using var control = new NpgsqlConnection(connections.Control);
        var tenants = (await control.QueryAsync<(string TenantId, string DatabaseName)>(new CommandDefinition(
            "SELECT TenantId, DatabaseName FROM ctl.Tenant WHERE Status IN ('active', 'suspended');",
            cancellationToken: ct))).ToList();

        foreach (var (tenantId, databaseName) in tenants)
        {
            try
            {
                await using var tenant = new NpgsqlConnection(connections.ForTenant(databaseName));
                await tenant.OpenAsync(ct);

                var hasUnit = await tenant.ExecuteScalarAsync<bool>(new CommandDefinition(
                    """
                    SELECT to_regclass('zatca.egsunit') IS NOT NULL
                       AND EXISTS (SELECT 1 FROM zatca.EgsUnit WHERE Status = 'active');
                    """, cancellationToken: ct));
                if (!hasUnit) continue;

                var signed = await issuer.SignPendingAsync(tenant, tenantId, ct);
                if (signed > 0) logger.LogInformation("ZATCA: signed {Count} pending document(s) for {Tenant}.", signed, tenantId);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "ZATCA signing pass failed for {Tenant}.", tenantId);
            }
        }
    }
}
