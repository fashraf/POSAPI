using Dapper;

namespace PosApi.Tenancy;

/// <summary>
/// Which tenant a POS device belongs to, before it has a token.
///
/// A terminal registers with a one-time code typed off the back office, and
/// announces itself on discovery by serial number. Neither names a business,
/// so the control database keeps code → tenant, and the hardware register
/// (assigned from the console) answers serial → tenant.
/// </summary>
public sealed class DeviceDirectory
{
    private readonly TenantCatalog _catalog;

    public DeviceDirectory(TenantCatalog catalog) => _catalog = catalog;

    /// <summary>Record a device's current code; any earlier code for it stops working.</summary>
    public async Task<bool> TryRecordCodeAsync(string tenantId, string deviceId, string code, CancellationToken ct)
    {
        await using var control = _catalog.Control();

        await control.ExecuteAsync(new CommandDefinition(
            """
            DELETE FROM ctl.DeviceCode WHERE TenantId = @TenantId AND DeviceId = @DeviceId;

            INSERT INTO ctl.DeviceCode (RegistrationCode, TenantId, DeviceId)
            SELECT @Code, @TenantId, @DeviceId
            WHERE NOT EXISTS (SELECT 1 FROM ctl.DeviceCode WHERE RegistrationCode = @Code);
            """,
            new { TenantId = tenantId, DeviceId = deviceId, Code = code }, cancellationToken: ct));

        /* False when another tenant's device already holds this code. */
        return await control.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT 1 FROM ctl.DeviceCode WHERE RegistrationCode = @Code AND TenantId = @TenantId AND DeviceId = @DeviceId;",
            new { Code = code, TenantId = tenantId, DeviceId = deviceId }, cancellationToken: ct)) is not null;
    }

    public async Task<string?> TenantForCodeAsync(string code, CancellationToken ct)
    {
        await using var control = _catalog.Control();
        return await control.QuerySingleOrDefaultAsync<string>(new CommandDefinition(
            "SELECT TenantId FROM ctl.DeviceCode WHERE RegistrationCode = @Code;",
            new { Code = code.Trim().ToUpperInvariant() }, cancellationToken: ct));
    }

    /// <summary>The tenant a serial number is assigned to in the hardware register.</summary>
    public async Task<string?> TenantForSerialAsync(string serial, CancellationToken ct)
    {
        await using var control = _catalog.Control();
        return await control.QuerySingleOrDefaultAsync<string>(new CommandDefinition(
            """
            SELECT TenantId FROM ctl.HardwareDevice
            WHERE Serial = @Serial AND Status IN (N'assigned', N'active', N'suspended');
            """,
            new { Serial = serial.Trim() }, cancellationToken: ct));
    }

    /// <summary>
    /// A terminal paired: consume its code, and if the serial is in the
    /// hardware register, link it and mark it active.
    /// </summary>
    public async Task PairedAsync(string tenantId, string code, string deviceId, string serial, CancellationToken ct)
    {
        await using var control = _catalog.Control();

        await control.ExecuteAsync(new CommandDefinition(
            """
            DELETE FROM ctl.DeviceCode WHERE RegistrationCode = @Code;

            UPDATE ctl.HardwareDevice
            SET TerminalId = @DeviceId, LastOnlineAtUtc = SYSUTCDATETIME(),
                Status = CASE WHEN Status = N'assigned' THEN N'active' ELSE Status END,
                InstalledOn = COALESCE(InstalledOn, CAST(SYSUTCDATETIME() AS DATE)),
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE Serial = @Serial AND TenantId = @TenantId;

            INSERT INTO ctl.HardwareDeviceEvent (DeviceId, Event, ByName, Detail)
            SELECT DeviceId, N'Paired with terminal', N'device', @DeviceId
            FROM ctl.HardwareDevice WHERE Serial = @Serial AND TenantId = @TenantId;

            INSERT INTO ctl.PlatformEvent (Kind, Label, TenantId, Detail)
            VALUES (N'pos_registered', N'POS registered', @TenantId, @Detail);
            """,
            new
            {
                Code = code.Trim().ToUpperInvariant(), DeviceId = deviceId, Serial = serial.Trim(),
                TenantId = tenantId, Detail = $"{deviceId} (serial {serial.Trim()})"
            }, cancellationToken: ct));
    }
}
