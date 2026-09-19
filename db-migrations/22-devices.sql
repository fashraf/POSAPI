/*==============================================================================
  Nazad POS — 22 · POS device registry

  The server cannot reach a terminal. A SUNMI V2 on shop Wi-Fi sits behind NAT
  with no address to connect to, so every exchange is started by the device:
  it heartbeats, and collects any queued commands on the way past.

  That shapes the whole design. Commands are rows with a lifecycle, not calls.
==============================================================================*/

USE POSMAIN;
GO

IF SCHEMA_ID(N'device') IS NULL EXEC(N'CREATE SCHEMA device');
GO

/*------------------------------------------------------------------ registry */

CREATE TABLE device.PosDevice
(
    DeviceId            NVARCHAR(40)  NOT NULL CONSTRAINT PK_PosDevice PRIMARY KEY,

    DeviceName          NVARCHAR(120) NOT NULL,
    DeviceType          NVARCHAR(40)  NOT NULL CONSTRAINT DF_Device_Type DEFAULT (N'sunmi_v2'),
    DeviceModel         NVARCHAR(60)  NULL,

    /* Read from Android at registration, not typed by the admin. Unique, so a
       leaked code cannot enrol a second terminal alongside the first. */
    SerialNumber        NVARCHAR(80)  NULL,
    AndroidId           NVARCHAR(80)  NULL,

    BranchId            NVARCHAR(40)  NOT NULL,
    Location            NVARCHAR(120) NULL,
    Description         NVARCHAR(400) NULL,

    /* 58 or 80 millimetres. The receipt formatter needs it to know its width. */
    PaperWidth          INT           NOT NULL CONSTRAINT DF_Device_Paper DEFAULT (80),
    PrinterKind         NVARCHAR(40)  NOT NULL CONSTRAINT DF_Device_Printer DEFAULT (N'sunmi_builtin'),

    /* Single use, and it expires. */
    RegistrationCode    NVARCHAR(20)  NULL,
    CodeExpiresAtUtc    DATETIME2(0)  NULL,
    RegisteredAtUtc     DATETIME2(0)  NULL,

    /* Hashed. A token readable from the table is a token anyone with a query
       window can use to impersonate a till. */
    TokenHash           NVARCHAR(128) NULL,

    /*
      Last reported state.

      There is no IsOnline column on purpose. Nothing writes "I have gone
      offline" — a terminal that loses power simply stops, so a stored flag
      would stay green forever. Online is derived from the clock below.
    */
    LastHeartbeatAtUtc  DATETIME2(0)  NULL,
    PrinterStatus       NVARCHAR(20)  NOT NULL CONSTRAINT DF_Device_PrinterStatus DEFAULT (N'unknown'),
    PaperStatus         NVARCHAR(20)  NOT NULL CONSTRAINT DF_Device_PaperStatus   DEFAULT (N'unknown'),
    PrinterError        NVARCHAR(200) NULL,
    BatteryPercent      INT           NULL,
    NetworkType         NVARCHAR(20)  NULL,
    AppVersion          NVARCHAR(40)  NULL,

    IsActive            BIT           NOT NULL CONSTRAINT DF_Device_Active DEFAULT (1),
    CreatedAtUtc        DATETIME2(0)  NOT NULL CONSTRAINT DF_Device_Created DEFAULT (SYSUTCDATETIME()),
    CreatedBy           NVARCHAR(160) NULL,
    UpdatedAtUtc        DATETIME2(0)  NULL,
    UpdatedBy           NVARCHAR(160) NULL,

    CONSTRAINT FK_PosDevice_Branch FOREIGN KEY (BranchId) REFERENCES core.Branch (BranchId),
    CONSTRAINT CK_Device_Paper   CHECK (PaperWidth IN (58, 80)),
    CONSTRAINT CK_Device_Printer CHECK (PrinterStatus IN
        (N'ready', N'error', N'unavailable', N'unknown')),
    /* Unknown is a real value, not a default left lying around: an offline
       device has unknown paper, never "available" from twenty minutes ago. */
    CONSTRAINT CK_Device_PaperStatus CHECK (PaperStatus IN
        (N'available', N'low', N'empty', N'unknown')),
    CONSTRAINT CK_Device_Battery CHECK (BatteryPercent IS NULL
                                        OR (BatteryPercent BETWEEN 0 AND 100))
);
GO

/* A serial identifies one physical terminal, so it may enrol once. Filtered,
   because a device that has not registered yet has none. */
CREATE UNIQUE INDEX UX_PosDevice_Serial ON device.PosDevice (SerialNumber)
    WHERE SerialNumber IS NOT NULL;

CREATE UNIQUE INDEX UX_PosDevice_Code ON device.PosDevice (RegistrationCode)
    WHERE RegistrationCode IS NOT NULL;

CREATE INDEX IX_PosDevice_Branch ON device.PosDevice (BranchId, IsActive);
GO

/*---------------------------------------------------------------- heartbeats */

/*
  Every heartbeat, kept.

  The current state lives on PosDevice; this is the history behind it — when a
  printer started failing, how long a device was gone. A single "last seen"
  answers neither.
*/
CREATE TABLE device.DeviceHeartbeat
(
    HeartbeatId     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DeviceHeartbeat PRIMARY KEY,
    DeviceId        NVARCHAR(40)  NOT NULL,
    ReceivedAtUtc   DATETIME2(0)  NOT NULL CONSTRAINT DF_HB_At DEFAULT (SYSUTCDATETIME()),
    PrinterStatus   NVARCHAR(20)  NOT NULL,
    PaperStatus     NVARCHAR(20)  NOT NULL,
    PrinterError    NVARCHAR(200) NULL,
    BatteryPercent  INT           NULL,
    NetworkType     NVARCHAR(20)  NULL,
    AppVersion      NVARCHAR(40)  NULL,

    CONSTRAINT FK_Heartbeat_Device FOREIGN KEY (DeviceId)
        REFERENCES device.PosDevice (DeviceId) ON DELETE CASCADE
);
GO

CREATE INDEX IX_Heartbeat_Device ON device.DeviceHeartbeat (DeviceId, ReceivedAtUtc DESC);
GO

/*------------------------------------------------------------------ commands */

/*
  The queue.

  A command is a row with a lifecycle, not a call: pending until the device
  collects it, sent until it answers, then succeeded or failed. Expired covers
  the device that never came back — without it, a ping to a dead terminal would
  sit pending forever and the screen could never say so.
*/
CREATE TABLE device.DeviceCommand
(
    CommandId       NVARCHAR(40)  NOT NULL CONSTRAINT PK_DeviceCommand PRIMARY KEY,
    DeviceId        NVARCHAR(40)  NOT NULL,

    CommandType     NVARCHAR(40)  NOT NULL,
    /* JSON, so a new command needs no column. */
    Payload         NVARCHAR(MAX) NULL,

    Status          NVARCHAR(20)  NOT NULL CONSTRAINT DF_Cmd_Status DEFAULT (N'pending'),
    QueuedAtUtc     DATETIME2(3)  NOT NULL CONSTRAINT DF_Cmd_Queued DEFAULT (SYSUTCDATETIME()),
    SentAtUtc       DATETIME2(3)  NULL,
    CompletedAtUtc  DATETIME2(3)  NULL,
    ExpiresAtUtc    DATETIME2(0)  NOT NULL,

    Succeeded       BIT           NULL,
    ResultMessage   NVARCHAR(400) NULL,
    ResultData      NVARCHAR(MAX) NULL,
    /* Queued to answered, as the admin experiences it — not the device's own
       processing time, which would flatter the number. */
    RoundTripMs     INT           NULL,

    RequestedBy     NVARCHAR(160) NULL,

    CONSTRAINT FK_Command_Device FOREIGN KEY (DeviceId)
        REFERENCES device.PosDevice (DeviceId) ON DELETE CASCADE,
    CONSTRAINT CK_Cmd_Status CHECK (Status IN
        (N'pending', N'sent', N'succeeded', N'failed', N'expired')),
    CONSTRAINT CK_Cmd_Type CHECK (CommandType IN
        (N'ping', N'test_printer', N'refresh_status', N'print_test_receipt', N'get_info'))
);
GO

CREATE INDEX IX_Command_Pending ON device.DeviceCommand (DeviceId, Status, QueuedAtUtc)
    WHERE Status = N'pending';

CREATE INDEX IX_Command_Device ON device.DeviceCommand (DeviceId, QueuedAtUtc DESC);
GO

/*-------------------------------------------------------------------- events */

CREATE TABLE device.DeviceEvent
(
    EventId       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DeviceEvent PRIMARY KEY,
    DeviceId      NVARCHAR(40)  NOT NULL,
    EventType     NVARCHAR(40)  NOT NULL,
    Severity      NVARCHAR(20)  NOT NULL CONSTRAINT DF_Event_Sev DEFAULT (N'info'),
    MessageEn     NVARCHAR(300) NOT NULL,
    MessageAr     NVARCHAR(300) NOT NULL,
    OccurredAtUtc DATETIME2(0)  NOT NULL CONSTRAINT DF_Event_At DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT FK_Event_Device FOREIGN KEY (DeviceId)
        REFERENCES device.PosDevice (DeviceId) ON DELETE CASCADE,
    CONSTRAINT CK_Event_Severity CHECK (Severity IN (N'info', N'warning', N'error'))
);
GO

CREATE INDEX IX_Event_Device ON device.DeviceEvent (DeviceId, OccurredAtUtc DESC);
GO

/*--------------------------------------------------------------------- view */

/*
  Devices with their connection state worked out.

  Ninety seconds is three missed heartbeats at the ten-second interval — long
  enough that one dropped packet does not turn the light red, short enough that
  a genuinely dead till is noticed.
*/
CREATE VIEW device.vw_DeviceStatus
AS
SELECT
    d.DeviceId, d.DeviceName, d.DeviceType, d.DeviceModel, d.SerialNumber,
    d.BranchId, b.NameAr AS BranchNameAr, b.NameEn AS BranchNameEn,
    d.Location, d.Description, d.PaperWidth, d.PrinterKind,

    CASE WHEN d.RegisteredAtUtc IS NULL THEN N'unregistered'
         WHEN d.LastHeartbeatAtUtc IS NULL THEN N'unknown'
         WHEN DATEDIFF(SECOND, d.LastHeartbeatAtUtc, SYSUTCDATETIME()) <= 90 THEN N'online'
         ELSE N'offline'
    END AS ConnectionStatus,

    d.LastHeartbeatAtUtc,
    DATEDIFF(SECOND, d.LastHeartbeatAtUtc, SYSUTCDATETIME()) AS SecondsSinceHeartbeat,

    /*
      A stale device reports nothing, so its printer state is unknown — not
      whatever it last said. A green printer light under an offline device is
      the light that lies.
    */
    CASE WHEN d.LastHeartbeatAtUtc IS NULL
              OR DATEDIFF(SECOND, d.LastHeartbeatAtUtc, SYSUTCDATETIME()) > 90
         THEN N'unknown' ELSE d.PrinterStatus END AS PrinterStatus,

    CASE WHEN d.LastHeartbeatAtUtc IS NULL
              OR DATEDIFF(SECOND, d.LastHeartbeatAtUtc, SYSUTCDATETIME()) > 90
         THEN N'unknown' ELSE d.PaperStatus END AS PaperStatus,

    d.PrinterError, d.BatteryPercent, d.NetworkType, d.AppVersion,
    d.RegisteredAtUtc, d.RegistrationCode, d.CodeExpiresAtUtc,
    CAST(CASE WHEN d.RegisteredAtUtc IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsRegistered,
    d.IsActive, d.CreatedAtUtc,

    (SELECT COUNT(*) FROM device.DeviceCommand AS c
     WHERE c.DeviceId = d.DeviceId AND c.Status = N'pending') AS PendingCommands
FROM device.PosDevice AS d
JOIN core.Branch AS b ON b.BranchId = d.BranchId;
GO

PRINT N'22 · Device registry ready.';
GO

/*==============================================================================
  Procedures
==============================================================================*/

/*------------------------------------------------------------------ register */

CREATE OR ALTER PROCEDURE device.usp_RegisterDevice
    @RegistrationCode NVARCHAR(20),
    @SerialNumber     NVARCHAR(80),
    @AndroidId        NVARCHAR(80) = NULL,
    @DeviceModel      NVARCHAR(60) = NULL,
    @AppVersion       NVARCHAR(40) = NULL,
    @TokenHash        NVARCHAR(128),
    @DeviceId         NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @DeviceId = DeviceId FROM device.PosDevice
    WHERE RegistrationCode = @RegistrationCode;

    IF @DeviceId IS NULL
        THROW 58000, N'That registration code is not recognised.', 1;

    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE DeviceId = @DeviceId AND CodeExpiresAtUtc < SYSUTCDATETIME())
        THROW 58001, N'That registration code has expired. Ask for a new one.', 1;

    IF EXISTS (SELECT 1 FROM device.PosDevice WHERE DeviceId = @DeviceId AND IsActive = 0)
        THROW 58002, N'This device has been deactivated.', 1;

    /*
      A serial belongs to one device record.

      Re-registering the SAME terminal is fine — that is a reinstall. Presenting
      a different serial against a record that already has one means the code
      travelled, and enrolling a second till under one identity would make every
      heartbeat afterwards ambiguous.
    */
    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE SerialNumber = @SerialNumber AND DeviceId <> @DeviceId)
        THROW 58003, N'This terminal is already registered as another device.', 1;

    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE DeviceId = @DeviceId
                 AND SerialNumber IS NOT NULL
                 AND SerialNumber <> @SerialNumber)
        THROW 58004, N'This code was issued for a different terminal.', 1;

    BEGIN TRAN;

        UPDATE device.PosDevice
        SET SerialNumber     = @SerialNumber,
            AndroidId        = ISNULL(@AndroidId, AndroidId),
            DeviceModel      = ISNULL(@DeviceModel, DeviceModel),
            AppVersion       = ISNULL(@AppVersion, AppVersion),
            TokenHash        = @TokenHash,
            RegisteredAtUtc  = SYSUTCDATETIME(),
            /* Consumed. Single use is what stops a shared code enrolling a
               second terminal tomorrow. */
            RegistrationCode = NULL,
            CodeExpiresAtUtc = NULL,
            UpdatedAtUtc     = SYSUTCDATETIME()
        WHERE DeviceId = @DeviceId;

        INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
        VALUES (@DeviceId, N'registered', N'info',
                N'Device registered', N'تم تسجيل الجهاز');

    COMMIT;
END
GO

/*----------------------------------------------------------------- heartbeat */

/*
  One call does three things: records the state, answers with any queued
  commands, and tells the device how soon to come back.

  Folding the command collection into the heartbeat is the whole design. A
  separate poll would double the traffic to learn the same thing.
*/
CREATE OR ALTER PROCEDURE device.usp_RecordHeartbeat
    @DeviceId       NVARCHAR(40),
    @PrinterStatus  NVARCHAR(20),
    @PaperStatus    NVARCHAR(20),
    @PrinterError   NVARCHAR(200) = NULL,
    @BatteryPercent INT = NULL,
    @NetworkType    NVARCHAR(20) = NULL,
    @AppVersion     NVARCHAR(40) = NULL,
    @NextIntervalMs INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @WasPrinter NVARCHAR(20), @WasPaper NVARCHAR(20), @WasSeen DATETIME2(0);

    SELECT @WasPrinter = PrinterStatus, @WasPaper = PaperStatus, @WasSeen = LastHeartbeatAtUtc
    FROM device.PosDevice WHERE DeviceId = @DeviceId;

    BEGIN TRAN;

        UPDATE device.PosDevice
        SET LastHeartbeatAtUtc = SYSUTCDATETIME(),
            PrinterStatus  = @PrinterStatus,
            PaperStatus    = @PaperStatus,
            PrinterError   = @PrinterError,
            BatteryPercent = @BatteryPercent,
            NetworkType    = @NetworkType,
            AppVersion     = ISNULL(@AppVersion, AppVersion)
        WHERE DeviceId = @DeviceId;

        INSERT INTO device.DeviceHeartbeat
            (DeviceId, PrinterStatus, PaperStatus, PrinterError,
             BatteryPercent, NetworkType, AppVersion)
        VALUES
            (@DeviceId, @PrinterStatus, @PaperStatus, @PrinterError,
             @BatteryPercent, @NetworkType, @AppVersion);

        /* An event per heartbeat would bury everything else. Only changes. */
        IF @WasPaper <> @PaperStatus AND @PaperStatus IN (N'low', N'empty')
        BEGIN
            INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
            VALUES (@DeviceId, N'paper', N'warning',
                    CONCAT(N'Paper ', @PaperStatus), N'حالة الورق تغيّرت');
        END

        IF @WasPrinter <> @PrinterStatus AND @PrinterStatus = N'error'
        BEGIN
            INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
            VALUES (@DeviceId, N'printer', N'error',
                    ISNULL(@PrinterError, N'Printer error'), N'خطأ في الطابعة');
        END

        /* Coming back after a gap is worth recording; it explains a missing
           receipt far better than an absence of rows. */
        IF @WasSeen IS NOT NULL AND DATEDIFF(SECOND, @WasSeen, SYSUTCDATETIME()) > 90
        BEGIN
            INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
            VALUES (@DeviceId, N'reconnected', N'info',
                    CONCAT(N'Back online after ',
                           DATEDIFF(SECOND, @WasSeen, SYSUTCDATETIME()), N's'),
                    N'عاد الاتصال');
        END

        /* Anything queued is now the device's. */
        UPDATE device.DeviceCommand
        SET Status = N'sent', SentAtUtc = SYSUTCDATETIME()
        WHERE DeviceId = @DeviceId AND Status = N'pending'
          AND ExpiresAtUtc > SYSUTCDATETIME();

        UPDATE device.DeviceCommand
        SET Status = N'expired', CompletedAtUtc = SYSUTCDATETIME(),
            ResultMessage = N'The device did not collect this in time.'
        WHERE DeviceId = @DeviceId AND Status IN (N'pending', N'sent')
          AND ExpiresAtUtc <= SYSUTCDATETIME();

    COMMIT;

    /*
      Come back sooner while there is work.

      Two seconds when something is outstanding, ten when idle. A ping then
      answers in about two seconds without holding a socket open all day — which
      is the compromise that makes polling acceptable here.
    */
    SET @NextIntervalMs = CASE
        WHEN EXISTS (SELECT 1 FROM device.DeviceCommand
                     WHERE DeviceId = @DeviceId AND Status IN (N'pending', N'sent'))
        THEN 2000 ELSE 10000 END;

    /* The commands to run, returned to the caller. */
    SELECT CommandId, CommandType, Payload
    FROM device.DeviceCommand
    WHERE DeviceId = @DeviceId AND Status = N'sent' AND CompletedAtUtc IS NULL
    ORDER BY QueuedAtUtc;
END
GO

/*------------------------------------------------------------ command result */

CREATE OR ALTER PROCEDURE device.usp_CompleteCommand
    @CommandId     NVARCHAR(40),
    @DeviceId      NVARCHAR(40),
    @Succeeded     BIT,
    @ResultMessage NVARCHAR(400) = NULL,
    @ResultData    NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Queued DATETIME2(3);
    SELECT @Queued = QueuedAtUtc FROM device.DeviceCommand
    WHERE CommandId = @CommandId AND DeviceId = @DeviceId;

    IF @Queued IS NULL
        THROW 58010, N'No such command for this device.', 1;

    UPDATE device.DeviceCommand
    SET Status         = CASE WHEN @Succeeded = 1 THEN N'succeeded' ELSE N'failed' END,
        CompletedAtUtc = SYSUTCDATETIME(),
        Succeeded      = @Succeeded,
        ResultMessage  = @ResultMessage,
        ResultData     = @ResultData,
        /* Queued to answered, as the admin experienced it. Measuring only the
           device's own work would report 40ms for a wait of several seconds. */
        RoundTripMs    = DATEDIFF(MILLISECOND, @Queued, SYSUTCDATETIME())
    WHERE CommandId = @CommandId;

    INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
    SELECT @DeviceId, c.CommandType,
           CASE WHEN @Succeeded = 1 THEN N'info' ELSE N'error' END,
           CONCAT(c.CommandType, N': ', ISNULL(@ResultMessage, N'done')),
           CONCAT(c.CommandType, N': ', ISNULL(@ResultMessage, N'تم'))
    FROM device.DeviceCommand AS c WHERE c.CommandId = @CommandId;
END
GO

PRINT N'22 · Device procedures ready.';
GO

/*-------------------------------------------------------------- permissions */

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
SELECT v.k, N'devices', v.a, N'general'
FROM (VALUES (N'devices.view', N'view'),
             (N'devices.manage', N'manage'),
             (N'devices.command', N'command')) AS v (k, a)
WHERE NOT EXISTS (SELECT 1 FROM core.Permission WHERE PermissionKey = v.k);
GO

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT r.RoleId, p.PermissionKey
FROM core.Role AS r
CROSS JOIN core.Permission AS p
WHERE p.PermissionKey IN (N'devices.view', N'devices.manage', N'devices.command')
  AND (r.RoleId = N'rol_owner'
       OR (r.RoleId = N'rol_manager' AND p.PermissionKey <> N'devices.manage'))
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionKey = p.PermissionKey);
GO

SELECT CASE WHEN (SELECT COUNT(*) FROM core.Permission
                  WHERE PermissionKey LIKE N'devices.%') = 3
            THEN N'PASS  Device module ready'
            ELSE N'FAIL  Permissions incomplete'
       END AS Result;
GO
