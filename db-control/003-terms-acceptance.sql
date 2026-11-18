/*==============================================================================
  003 — terms acceptance

  A self-registered business accepts the Terms of Use and Privacy Policy before
  its account is created. When, and which version, is kept on the tenant so it
  can be shown later. NULL for tenants created before this, or by the console.
==============================================================================*/

ALTER TABLE ctl.Tenant ADD COLUMN IF NOT EXISTS TermsAcceptedAtUtc timestamp(3) NULL;
ALTER TABLE ctl.Tenant ADD COLUMN IF NOT EXISTS TermsVersion varchar(20) COLLATE ci NULL;
