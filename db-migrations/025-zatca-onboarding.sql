/*
  025 — ZATCA onboarding: a branch gets its EGS unit's certificate from
  ZATCA with the owner's OTP.

  zatca.Onboarding keeps every attempt, step by step, so a failure says
  where it stopped and an interrupted attempt is never repeated blindly:

    csr_ready → compliance_issued → samples_passed → active
    side exits: otp_rejected (wrong or used OTP: ask the owner for a new one),
                samples_failed, failed, fate_unknown (the production CSID call
                timed out: ZATCA may have issued it; start again with a new
                OTP rather than repeat the call)

  The private key and the CSID secrets are sealed by the API (ZatcaVault);
  the OTP is never stored. Kind 'renewal' is a new key and certificate for
  a unit that is already active; its chain carries on.

  zatca.EgsUnit gains what reporting needs: ZATCA's binarySecurityToken
  exactly as issued, the invoice types the certificate allows (0100
  simplified only, 1100 standard and simplified) and the EGS serial named in
  its request. 'developer-portal' joins the environments: ZATCA's sandbox.
*/

ALTER TABLE zatca.EgsUnit ADD COLUMN IF NOT EXISTS BinarySecurityToken text NULL;
ALTER TABLE zatca.EgsUnit ADD COLUMN IF NOT EXISTS InvoiceTypes varchar(4) COLLATE ci NULL;
ALTER TABLE zatca.EgsUnit ADD COLUMN IF NOT EXISTS EgsSerial varchar(200) COLLATE ci NULL;

ALTER TABLE zatca.EgsUnit DROP CONSTRAINT IF EXISTS CK_EgsUnit_Environment;
ALTER TABLE zatca.EgsUnit ADD CONSTRAINT CK_EgsUnit_Environment
    CHECK (Environment IN ('test', 'developer-portal', 'simulation', 'core'));

CREATE TABLE IF NOT EXISTS zatca.Onboarding (
    AttemptId            varchar(40) COLLATE ci NOT NULL,
    BranchId             varchar(40) COLLATE ci NOT NULL,
    Kind                 varchar(12) COLLATE ci NOT NULL DEFAULT 'onboarding',
    Environment          varchar(20) COLLATE ci NOT NULL,
    InvoiceTypes         varchar(4) COLLATE ci NOT NULL,
    State                varchar(20) COLLATE ci NOT NULL,
    EgsSerial            varchar(200) COLLATE ci NOT NULL,
    Csr                  text NOT NULL,
    PrivateKeyCt         text NOT NULL,
    KekId                varchar(40) COLLATE ci NOT NULL,
    /* The compliance CSID itself is used within the attempt and never stored. */
    ComplianceRequestId  varchar(40) COLLATE ci NULL,
    /* Each step's outcome: ZATCA's status codes and messages, never a secret. */
    Steps                jsonb NOT NULL DEFAULT '[]',
    ErrorCode            varchar(40) COLLATE ci NULL,
    ErrorMessage         varchar(1000) COLLATE ci NULL,
    StartedBy            varchar(120) COLLATE ci NULL,
    StartedAtUtc         timestamp(3) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    UpdatedAtUtc         timestamp(3) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
    CONSTRAINT PK_ZatcaOnboarding PRIMARY KEY (AttemptId),
    CONSTRAINT FK_ZatcaOnboarding_Branch FOREIGN KEY (BranchId) REFERENCES core.Branch (BranchId),
    CONSTRAINT CK_ZatcaOnboarding_Kind CHECK (Kind IN ('onboarding', 'renewal')),
    CONSTRAINT CK_ZatcaOnboarding_Types CHECK (InvoiceTypes IN ('0100', '1100')),
    CONSTRAINT CK_ZatcaOnboarding_State CHECK (State IN
        ('csr_ready', 'compliance_issued', 'samples_passed', 'active',
         'otp_rejected', 'samples_failed', 'failed', 'fate_unknown'))
);

CREATE INDEX IF NOT EXISTS IX_ZatcaOnboarding_Branch ON zatca.Onboarding (BranchId, StartedAtUtc DESC);
