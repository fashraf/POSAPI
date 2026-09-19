/*==============================================================================
  Nazad POS — 11 · Tables the API layer needs

  Run this after the main migration. These support authentication and are not
  part of the business schema, which is why they were not in the first pass.
==============================================================================*/

USE POSMAIN;
GO

/*
  One-time codes.

  The code is stored hashed, exactly like a password. An OTP sitting in
  plaintext is a live credential for anyone with read access to the table.
*/
CREATE TABLE core.OtpChallenge
(
    ChallengeId     NVARCHAR(64)   NOT NULL CONSTRAINT PK_OtpChallenge PRIMARY KEY,
    Identifier      NVARCHAR(160)  NOT NULL,
    Purpose         NVARCHAR(40)   NOT NULL,
    CodeHash        NVARCHAR(400)  NOT NULL,
    CodeSalt        NVARCHAR(200)  NOT NULL,
    ExpiresAtUtc    DATETIME2(3)   NOT NULL,
    Attempts        INT            NOT NULL CONSTRAINT DF_Otp_Attempts DEFAULT (0),
    ConsumedAtUtc   DATETIME2(3)   NULL,
    CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_Otp_Created DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_Otp_Purpose  CHECK (Purpose IN (N'login', N'register', N'reset', N'verify')),
    CONSTRAINT CK_Otp_Attempts CHECK (Attempts >= 0)
);
GO

CREATE INDEX IX_Otp_Identifier ON core.OtpChallenge (Identifier, CreatedAtUtc DESC);
CREATE INDEX IX_Otp_Expiry     ON core.OtpChallenge (ExpiresAtUtc) WHERE ConsumedAtUtc IS NULL;
GO

/*
  Refresh tokens, stored hashed.

  These are bearer credentials with a long life, so the table must not be usable
  by whoever reads it. Rotation revokes the old row as the new one is written.
*/
CREATE TABLE core.RefreshToken
(
    TokenHash       NVARCHAR(200)  NOT NULL CONSTRAINT PK_RefreshToken PRIMARY KEY,
    UserId          NVARCHAR(40)   NOT NULL
        CONSTRAINT FK_RefreshToken_User REFERENCES core.AppUser (UserId) ON DELETE CASCADE,
    IssuedAtUtc     DATETIME2(3)   NOT NULL CONSTRAINT DF_Refresh_Issued DEFAULT (SYSUTCDATETIME()),
    ExpiresAtUtc    DATETIME2(3)   NOT NULL,
    RevokedAtUtc    DATETIME2(3)   NULL,
    UserAgent       NVARCHAR(300)  NULL,
    IpAddress       NVARCHAR(60)   NULL
);
GO

CREATE INDEX IX_RefreshToken_User ON core.RefreshToken (UserId) WHERE RevokedAtUtc IS NULL;
GO

/* Failed sign-in tracking, so an account can be locked after repeated misses. */
CREATE TABLE core.LoginAttempt
(
    AttemptId       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoginAttempt PRIMARY KEY,
    Identifier      NVARCHAR(160)  NOT NULL,
    Succeeded       BIT            NOT NULL,
    IpAddress       NVARCHAR(60)   NULL,
    UserAgent       NVARCHAR(300)  NULL,
    AttemptedAtUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_LoginAttempt_At DEFAULT (SYSUTCDATETIME())
);
GO

CREATE INDEX IX_LoginAttempt_Identifier
    ON core.LoginAttempt (Identifier, AttemptedAtUtc DESC) INCLUDE (Succeeded);
GO

/* Expired challenges and tokens are noise. Schedule this nightly. */
CREATE PROCEDURE core.usp_PurgeExpiredAuth
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM core.OtpChallenge
    WHERE ExpiresAtUtc < DATEADD(DAY, -1, SYSUTCDATETIME());

    DELETE FROM core.RefreshToken
    WHERE ExpiresAtUtc < DATEADD(DAY, -7, SYSUTCDATETIME());

    DELETE FROM core.LoginAttempt
    WHERE AttemptedAtUtc < DATEADD(DAY, -90, SYSUTCDATETIME());
END
GO

PRINT N'11 · API auth tables ready.';
GO
