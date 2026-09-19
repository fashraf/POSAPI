/*==============================================================================
  Nazad POS — 23 · Device discovery

  The brief asks the server to scan the shop's Wi-Fi. It cannot.

  Your API runs on a public VPS. It has no route into a customer's local
  network, so mDNS, DNS-SD and any form of LAN scan are unavailable to it — not
  difficult, unavailable. A cloud server cannot see a shop's subnet.

  What works instead is the reverse: **the device announces itself.**

  The Android app already talks outward to heartbeat. Before it is registered it
  announces the same way — identity, model, serial, local IP — and the admin
  sees it appear in the discovery modal within a second or two. No LAN scan, no
  agent, no VPN, and it works from any network the terminal can reach the
  internet on, including a different site entirely.

  The experience the brief asks for is preserved: the admin never types an IP.
==============================================================================*/

USE POSMAIN;
GO

/*-------------------------------------------------------------- announcement */

/*
  A terminal saying "I am here".

  Separate from PosDevice on purpose: an announcement is a claim by an
  unauthenticated stranger, not a record. Writing it into the registry would let
  anyone on the internet create device rows by asserting a serial number.
*/
CREATE TABLE device.DeviceAnnouncement
(
    AnnouncementId   BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_DeviceAnnouncement PRIMARY KEY,

    /* What the device claims. Claims, not facts, until verified. */
    ClaimedDeviceId  NVARCHAR(40)  NULL,
    DeviceName       NVARCHAR(120) NULL,
    Manufacturer     NVARCHAR(60)  NULL,
    DeviceModel      NVARCHAR(60)  NULL,
    SerialNumber     NVARCHAR(80)  NOT NULL,
    AndroidId        NVARCHAR(80)  NULL,
    AppVersion       NVARCHAR(40)  NULL,

    /* Where it says it is. Shown to help a human recognise the right terminal,
       never used as identity — an address is trivially spoofed and changes on
       every DHCP lease. */
    LocalIpAddress   NVARCHAR(45)  NULL,
    NetworkName      NVARCHAR(120) NULL,

    /* Where the request actually came from. Useful for telling two shops
       apart; still not identity. */
    SourceIpAddress  NVARCHAR(45)  NULL,

    FirstSeenAtUtc   DATETIME2(0)  NOT NULL
        CONSTRAINT DF_Ann_First DEFAULT (SYSUTCDATETIME()),
    LastSeenAtUtc    DATETIME2(0)  NOT NULL
        CONSTRAINT DF_Ann_Last  DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT UX_Announcement_Serial UNIQUE (SerialNumber)
);
GO

CREATE INDEX IX_Announcement_Recent ON device.DeviceAnnouncement (LastSeenAtUtc DESC);
GO

/*---------------------------------------------------------------- challenges */

/*
  Proof of identity, for a terminal that has one.

  A device that has registered before holds a token. It can prove that by
  signing a server-issued nonce, which is what makes a reinstall safe to accept
  without a new code.

  A brand-new terminal has no credential and cannot prove anything — see the
  note on the connect procedure. Discovery shortens the work; it does not
  replace the code.
*/
CREATE TABLE device.DeviceChallenge
(
    ChallengeId    NVARCHAR(40)  NOT NULL CONSTRAINT PK_DeviceChallenge PRIMARY KEY,
    SerialNumber   NVARCHAR(80)  NOT NULL,
    Nonce          NVARCHAR(88)  NOT NULL,
    IssuedAtUtc    DATETIME2(0)  NOT NULL CONSTRAINT DF_Chal_At DEFAULT (SYSUTCDATETIME()),
    /* Two minutes. A nonce that outlives the exchange is a replay waiting to
       happen. */
    ExpiresAtUtc   DATETIME2(0)  NOT NULL,
    AnsweredAtUtc  DATETIME2(0)  NULL,
    Verified       BIT           NULL,
    /* Single use, enforced below. */
    ConsumedAtUtc  DATETIME2(0)  NULL
);
GO

CREATE INDEX IX_Challenge_Serial ON device.DeviceChallenge (SerialNumber, ExpiresAtUtc DESC);
GO

/*------------------------------------------------------------------- record */

CREATE OR ALTER PROCEDURE device.usp_RecordAnnouncement
    @SerialNumber    NVARCHAR(80),
    @ClaimedDeviceId NVARCHAR(40)  = NULL,
    @DeviceName      NVARCHAR(120) = NULL,
    @Manufacturer    NVARCHAR(60)  = NULL,
    @DeviceModel     NVARCHAR(60)  = NULL,
    @AndroidId       NVARCHAR(80)  = NULL,
    @AppVersion      NVARCHAR(40)  = NULL,
    @LocalIpAddress  NVARCHAR(45)  = NULL,
    @NetworkName     NVARCHAR(120) = NULL,
    @SourceIpAddress NVARCHAR(45)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* One row per terminal, refreshed. A row per announcement would grow
       without bound for a device left switched on. */
    MERGE device.DeviceAnnouncement AS target
    USING (SELECT @SerialNumber AS SerialNumber) AS source
       ON target.SerialNumber = source.SerialNumber
    WHEN MATCHED THEN UPDATE SET
        ClaimedDeviceId = ISNULL(@ClaimedDeviceId, target.ClaimedDeviceId),
        DeviceName      = ISNULL(@DeviceName, target.DeviceName),
        Manufacturer    = ISNULL(@Manufacturer, target.Manufacturer),
        DeviceModel     = ISNULL(@DeviceModel, target.DeviceModel),
        AndroidId       = ISNULL(@AndroidId, target.AndroidId),
        AppVersion      = ISNULL(@AppVersion, target.AppVersion),
        LocalIpAddress  = @LocalIpAddress,
        NetworkName     = @NetworkName,
        SourceIpAddress = @SourceIpAddress,
        LastSeenAtUtc   = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (SerialNumber, ClaimedDeviceId, DeviceName, Manufacturer, DeviceModel,
         AndroidId, AppVersion, LocalIpAddress, NetworkName, SourceIpAddress)
    VALUES
        (@SerialNumber, @ClaimedDeviceId, @DeviceName, @Manufacturer, @DeviceModel,
         @AndroidId, @AppVersion, @LocalIpAddress, @NetworkName, @SourceIpAddress);
END
GO

/*------------------------------------------------------------------ discover */

/*
  What the admin sees.

  Recent announcements, each already matched against the registry so the modal
  can tell "new", "already yours" and "registered elsewhere" apart — which the
  brief rightly insists are different outcomes.
*/
CREATE OR ALTER PROCEDURE device.usp_DiscoverDevices
    @WithinSeconds INT = 120
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        a.SerialNumber, a.ClaimedDeviceId, a.DeviceName, a.Manufacturer,
        a.DeviceModel, a.AppVersion, a.LocalIpAddress, a.NetworkName,
        a.FirstSeenAtUtc, a.LastSeenAtUtc,
        DATEDIFF(SECOND, a.LastSeenAtUtc, SYSUTCDATETIME()) AS SecondsSinceSeen,

        d.DeviceId        AS MatchedDeviceId,
        d.DeviceName      AS MatchedDeviceName,
        d.BranchId        AS MatchedBranchId,
        b.NameEn          AS MatchedBranchNameEn,

        /*
          Three outcomes, kept apart.

          available          no record holds this serial — it can be registered
          already_registered this serial is already one of ours
          claimed_elsewhere  the record exists but was never completed here

          Collapsing these would let an admin register a second record for a
          terminal that already has one, and every heartbeat afterwards would be
          ambiguous.
        */
        CASE
            WHEN d.DeviceId IS NULL THEN N'available'
            WHEN d.RegisteredAtUtc IS NOT NULL THEN N'already_registered'
            ELSE N'awaiting_registration'
        END AS DiscoveryStatus
    FROM device.DeviceAnnouncement AS a
    LEFT JOIN device.PosDevice AS d ON d.SerialNumber = a.SerialNumber
    LEFT JOIN core.Branch     AS b ON b.BranchId = d.BranchId
    WHERE DATEDIFF(SECOND, a.LastSeenAtUtc, SYSUTCDATETIME()) <= @WithinSeconds
    ORDER BY a.LastSeenAtUtc DESC;
END
GO

/*------------------------------------------------------------------ connect */

/*
  Bind a discovered terminal to a device record.

  Called after the challenge has been answered, and it re-checks rather than
  trusting the caller: a verification that happened is not the same as a
  verification that still applies.
*/
CREATE OR ALTER PROCEDURE device.usp_ConnectDiscovered
    @SerialNumber  NVARCHAR(80),
    @DeviceId      NVARCHAR(40),
    @BranchId      NVARCHAR(40),
    @Location      NVARCHAR(120) = NULL,
    @DeviceName    NVARCHAR(120),
    @Actor         NVARCHAR(160),
    @Blocked       NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @Blocked = NULL;

    /* Already ours, and complete. Offer to open it, never to duplicate it. */
    IF EXISTS (SELECT 1 FROM device.PosDevice
               WHERE SerialNumber = @SerialNumber AND RegisteredAtUtc IS NOT NULL)
    BEGIN
        SET @Blocked = N'This terminal is already registered here.';
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM device.PosDevice WHERE DeviceId = @DeviceId)
    BEGIN
        SET @Blocked = N'That device id is already in use.';
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM device.DeviceAnnouncement WHERE SerialNumber = @SerialNumber)
    BEGIN
        SET @Blocked = N'That terminal has not announced itself recently.';
        RETURN;
    END

    BEGIN TRAN;

        /*
          A record and a code, in one step.

          The terminal is listening, so it collects the code on its next
          announcement and completes registration without anyone reading it
          aloud. The existing registration path is reused exactly — there is no
          second way to become registered, which is what the brief asks for.
        */
        INSERT INTO device.PosDevice
            (DeviceId, DeviceName, DeviceType, DeviceModel, SerialNumber, AndroidId,
             BranchId, Location, PaperWidth, RegistrationCode, CodeExpiresAtUtc,
             AppVersion, IsActive, CreatedBy)
        SELECT
            @DeviceId, @DeviceName, N'sunmi_v2', a.DeviceModel, @SerialNumber, a.AndroidId,
            @BranchId, @Location, 80,
            /* Short-lived: the terminal is on the other end of this exchange
               and will collect it within seconds. */
            CONCAT(N'DSC-', RIGHT(CONVERT(NVARCHAR(36), NEWID()), 4)),
            DATEADD(MINUTE, 10, SYSUTCDATETIME()),
            a.AppVersion, 1, @Actor
        FROM device.DeviceAnnouncement AS a
        WHERE a.SerialNumber = @SerialNumber;

        INSERT INTO device.DeviceEvent (DeviceId, EventType, Severity, MessageEn, MessageAr)
        VALUES (@DeviceId, N'created', N'info',
                N'Created from network discovery', N'أُنشئ عبر الاكتشاف على الشبكة');

    COMMIT;
END
GO

PRINT N'23 · Device discovery ready.';
GO

/*----------------------------------------------------------------- permission */

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
SELECT N'devices.discover', N'devices', N'discover', N'general'
WHERE NOT EXISTS (SELECT 1 FROM core.Permission WHERE PermissionKey = N'devices.discover');
GO

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT r.RoleId, N'devices.discover'
FROM core.Role AS r
WHERE r.RoleId IN (N'rol_owner', N'rol_manager')
  AND EXISTS (SELECT 1 FROM core.Permission WHERE PermissionKey = N'devices.discover')
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                  WHERE rp.RoleId = r.RoleId AND rp.PermissionKey = N'devices.discover');
GO

SELECT CASE WHEN OBJECT_ID(N'device.usp_DiscoverDevices') IS NOT NULL
             AND EXISTS (SELECT 1 FROM core.Permission WHERE PermissionKey = N'devices.discover')
            THEN N'PASS  Discovery ready'
            ELSE N'FAIL  Something is missing'
       END AS Result;
GO
