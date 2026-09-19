/*==============================================================================
  Nazad POS — 17 · Development passwords

  Single-step login needs something to check a password against, and every
  seeded user has PasswordHash NULL because the system was OTP-only.

  These are real PBKDF2-HMAC-SHA256 hashes of "1234", 210,000 iterations, each
  with its own salt — the same format PasswordHasher.cs produces and verifies.
  Storing a real hash rather than skipping the check means the login path is the
  genuine one, and a wrong password is genuinely rejected.

  DEVELOPMENT ONLY. "1234" is not a password. Before this database is used for
  anything real, run the reset at the bottom of this file.
==============================================================================*/

USE POSMAIN;
GO

/* Every demo account gets the password 1234. */
;WITH DevPasswords (UserId, PasswordHash, PasswordSalt) AS
(
    SELECT * FROM (VALUES
    (N'usr_001', N'pbkdf2$210000$qZqQrmEZg/a0vYFT4EwxFkXkjiv9l3RvTSKK7VMBp1I=', N'9/+4xax1zmYyqtIJb8PoUw=='),
    (N'usr_002', N'pbkdf2$210000$dDdnRScHH9/dcz6zJQPjdTnOopc+WHoJG8aFanEzADM=', N'IpkoigRknMnmg62ZGvcuGA=='),
    (N'usr_003', N'pbkdf2$210000$lexo/qs7fb3hHDXefDjKKWXYW8F1lEjwexKTpJ529P4=', N'BblS/wJ5t+BzU0uG4C4STg=='),
    (N'usr_004', N'pbkdf2$210000$gHaqGnI+jKyQrShyOqEeefIDlAr3841qSWt9nmQKwSQ=', N'M+76N5jye/RyXIQ8s0lwFQ=='),
    (N'usr_006', N'pbkdf2$210000$a8ABqd1tYWOWvM9G6aGDXX+wCE7DFA/uej920gTQZQQ=', N'khpIdNYVfF33LNiK11ZgeQ==')
    ) AS v (UserId, PasswordHash, PasswordSalt)
)
UPDATE u
SET PasswordHash = d.PasswordHash,
    PasswordSalt = d.PasswordSalt,
    UpdatedAtUtc = SYSUTCDATETIME(),
    UpdatedBy    = N'dev-seed'
FROM core.AppUser AS u
JOIN DevPasswords AS d ON d.UserId = u.UserId;
GO

PRINT N'17 · Development passwords set (1234). Development only.';
GO

/*------------------------------------------------------------------ check */

SELECT
    CASE WHEN COUNT(*) = 5 THEN N'PASS' ELSE N'FAIL' END
    + N'  Accounts with a password: ' + CAST(COUNT(*) AS NVARCHAR(10)) AS Result
FROM core.AppUser
WHERE PasswordHash IS NOT NULL;
GO

/*--------------------------------------------------------- before going live

    Clear every development password. With PasswordHash NULL the single-step
    login refuses the account outright, so this cannot silently leave 1234
    working in production.

    UPDATE core.AppUser SET PasswordHash = NULL, PasswordSalt = NULL;

----------------------------------------------------------------------------*/
