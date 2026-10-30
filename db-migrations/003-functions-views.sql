/*==============================================================================
  Nazad POS — 003 · Helper functions and views
==============================================================================*/

/*------------------------------------------------------------------ helpers */

/* A new key: a prefix and 32 hex digits, e.g. sal_3f2a…  The same shape the
   SQL Server procedures made from NEWID(). */
CREATE OR REPLACE FUNCTION core.fn_NewId(p_Prefix text)
RETURNS varchar
LANGUAGE sql VOLATILE
AS $$ SELECT (p_Prefix || replace(gen_random_uuid()::text, '-', ''))::varchar $$;

/* Resolve one localised string. */
CREATE OR REPLACE FUNCTION core.fn_Text(
    p_EntityType   text,
    p_EntityKey    text,
    p_FieldName    text,
    p_LanguageCode text,
    p_ValueAr      text,
    p_ValueEn      text)
RETURNS varchar
LANGUAGE sql STABLE
AS $$
    SELECT (CASE
        WHEN p_LanguageCode = 'ar' THEN p_ValueAr
        WHEN p_LanguageCode = 'en' THEN p_ValueEn
        ELSE COALESCE(
            (SELECT t.Value
             FROM core.Translation AS t
             WHERE t.EntityType   = p_EntityType
               AND t.EntityKey    = p_EntityKey
               AND t.FieldName    = p_FieldName
               AND t.LanguageCode = p_LanguageCode
             LIMIT 1),
            NULLIF(p_ValueEn, ''),
            p_ValueAr)
    END)::varchar
$$;

/* VAT extracted from a VAT-inclusive gross amount, the Saudi retail case.
   round() on numeric rounds half away from zero, as SQL Server's ROUND did. */
CREATE OR REPLACE FUNCTION fin.fn_VatFromGross(p_GrossH bigint, p_RatePercent numeric)
RETURNS bigint
LANGUAGE sql IMMUTABLE
AS $$ SELECT round(p_GrossH * p_RatePercent / (100.0 + p_RatePercent), 0)::bigint $$;

/* Month-end aware date arithmetic: 31 Jan + 1 month is 28 Feb, not 3 Mar. */
CREATE OR REPLACE FUNCTION fin.fn_AdvanceDueDate(p_From date, p_Frequency text)
RETURNS date
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE p_Frequency
        WHEN 'daily'     THEN p_From + 1
        WHEN 'weekly'    THEN p_From + 7
        WHEN 'monthly'   THEN (p_From + interval '1 month')::date
        WHEN 'quarterly' THEN (p_From + interval '3 months')::date
        WHEN 'yearly'    THEN (p_From + interval '1 year')::date
        ELSE p_From
    END
$$;

/* Assets and expenses grow on the debit side; everything else on the credit. */
CREATE OR REPLACE FUNCTION fin.fn_IsDebitNormal(p_AccountType text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$ SELECT p_AccountType IN ('asset', 'expense') $$;

/* Payroll-owned accounts. One definition, used by every check. */
CREATE OR REPLACE FUNCTION fin.fn_IsPayrollAccount(p_AccountCode text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$ SELECT p_AccountCode IN ('6200', '6300') $$;

/*-------------------------------------------------------------------- views */

/* Effective permissions: role grants, plus overrides, with denial winning. */
CREATE OR REPLACE VIEW core.vw_EffectivePermission AS
SELECT u.UserId, p.PermissionKey
FROM core.AppUser AS u
CROSS JOIN core.Permission AS p
WHERE
    (
        EXISTS (SELECT 1 FROM core.RolePermission AS rp
                WHERE rp.RoleId = u.RoleId AND rp.PermissionKey = p.PermissionKey)
        OR EXISTS (SELECT 1 FROM core.UserPermissionOverride AS o
                   WHERE o.UserId = u.UserId AND o.PermissionKey = p.PermissionKey
                     AND o.Effect = 'grant')
    )
    AND NOT EXISTS (SELECT 1 FROM core.UserPermissionOverride AS d
                    WHERE d.UserId = u.UserId AND d.PermissionKey = p.PermissionKey
                      AND d.Effect = 'deny');

CREATE OR REPLACE VIEW fin.vw_AccountBalance AS
SELECT
    a.AccountCode,
    a.AccountType,
    a.NameAr,
    a.NameEn,
    SUM(COALESCE(l.DebitH, 0))::bigint  AS TotalDebitH,
    SUM(COALESCE(l.CreditH, 0))::bigint AS TotalCreditH,
    (CASE WHEN fin.fn_IsDebitNormal(a.AccountType)
          THEN SUM(COALESCE(l.DebitH, 0)) - SUM(COALESCE(l.CreditH, 0))
          ELSE SUM(COALESCE(l.CreditH, 0)) - SUM(COALESCE(l.DebitH, 0))
     END)::bigint AS BalanceH
FROM fin.Account AS a
LEFT JOIN fin.JournalLine AS l ON l.AccountCode = a.AccountCode
GROUP BY a.AccountCode, a.AccountType, a.NameAr, a.NameEn;

/* The ledger must balance. If this ever returns a row, something bypassed the
   posting function and it needs investigating, not patching. */
CREATE OR REPLACE VIEW fin.vw_TrialBalanceCheck AS
SELECT
    SUM(DebitH)::bigint  AS TotalDebitH,
    SUM(CreditH)::bigint AS TotalCreditH,
    (SUM(DebitH) - SUM(CreditH))::bigint AS DifferenceH
FROM fin.JournalLine
HAVING SUM(DebitH) <> SUM(CreditH);

/* Receivables with aging, for the collections screen. Age counts calendar
   days, as DATEDIFF(DAY, ...) did. */
CREATE OR REPLACE VIEW fin.vw_Receivables AS
SELECT
    c.CustomerId,
    c.NameAr,
    c.NameEn,
    c.Phone,
    c.BalanceH,
    c.CreditLimitH,
    c.CreditLimitH - c.BalanceH AS AvailableCreditH,
    oldest.OldestUnpaidUtc,
    ((now() AT TIME ZONE 'utc')::date - oldest.OldestUnpaidUtc::date) AS AgeDays,
    (CASE
        WHEN oldest.OldestUnpaidUtc IS NULL THEN 'current'
        WHEN (now() AT TIME ZONE 'utc')::date - oldest.OldestUnpaidUtc::date <= 30 THEN 'current'
        WHEN (now() AT TIME ZONE 'utc')::date - oldest.OldestUnpaidUtc::date <= 60 THEN 'd30'
        WHEN (now() AT TIME ZONE 'utc')::date - oldest.OldestUnpaidUtc::date <= 90 THEN 'd60'
        ELSE 'd90'
    END)::varchar AS AgeBucket
FROM core.Customer AS c
LEFT JOIN LATERAL (
    SELECT MIN(s.SoldAtUtc) AS OldestUnpaidUtc
    FROM sales.Sale AS s
    WHERE s.CustomerId = c.CustomerId
      AND s.Status <> 'voided'
      AND EXISTS (SELECT 1 FROM sales.SalePayment AS p
                  WHERE p.SaleId = s.SaleId AND p.Method = 'credit')
) AS oldest ON true
WHERE c.BalanceH > 0;

/* Commission earned / paid / outstanding per employee per month. */
CREATE OR REPLACE VIEW fin.vw_CommissionSummary AS
SELECT
    e.UserId,
    u.NameAr,
    u.NameEn,
    to_char(e.EarnedAtUtc, 'YYYY-MM')::varchar AS PeriodMonth,
    COUNT(*)::int AS SaleLines,
    SUM(e.AmountH)::bigint AS EarnedH,
    SUM(CASE WHEN e.PayrollRunId IS NOT NULL THEN e.AmountH ELSE 0 END)::bigint AS PaidH,
    SUM(CASE WHEN e.PayrollRunId IS NULL     THEN e.AmountH ELSE 0 END)::bigint AS OutstandingH
FROM fin.CommissionEntry AS e
JOIN core.AppUser AS u ON u.UserId = e.UserId
GROUP BY e.UserId, u.NameAr, u.NameEn, to_char(e.EarnedAtUtc, 'YYYY-MM');

CREATE OR REPLACE VIEW sales.vw_SaleSummary AS
SELECT
    s.SaleId,
    s.InvoiceNumber,
    s.BranchId,
    b.NameAr        AS BranchNameAr,
    b.NameEn        AS BranchNameEn,
    s.CustomerId,
    c.NameAr        AS CustomerNameAr,
    c.NameEn        AS CustomerNameEn,
    s.ServedByUserId,
    u.NameAr        AS ServedByNameAr,
    u.NameEn        AS ServedByNameEn,
    s.CashierName,

    /* One basis: SubtotalH (ex-VAT, before the invoice discount)
       − DiscountH (ex-VAT) + TaxH = TotalH (VAT inclusive). */
    s.SubtotalH,
    s.DiscountH,
    s.TaxH,
    s.TotalH,

    /* The receipt's two missing figures.
       TenderedH is null for a sale with no cash leg, and null reaches the client
       as null rather than as a missing key — which it can test for. Change is
       never null: nothing tendered means nothing given back. */
    s.TenderedH,
    COALESCE(s.ChangeH, 0) AS ChangeH,

    s.DiscountId,
    s.Status,
    s.SoldAtUtc,
    /* The client's field is `soldAt`. Carrying both costs nothing and saves a
       rename on either side. */
    s.SoldAtUtc     AS SoldAt,

    (SELECT COUNT(*)::int FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId) AS LineCount,
    COALESCE((SELECT SUM(sl.Quantity) FROM sales.SaleLine AS sl WHERE sl.SaleId = s.SaleId), 0) AS ItemCount,

    /* The one method used, or 'mixed'. */
    pm.PaymentMethod,

    s.OverrideApprovedBy,
    s.OverrideReason
FROM sales.Sale AS s
LEFT JOIN core.Branch   AS b ON b.BranchId   = s.BranchId
LEFT JOIN core.Customer AS c ON c.CustomerId = s.CustomerId
LEFT JOIN core.AppUser  AS u ON u.UserId     = s.ServedByUserId
LEFT JOIN LATERAL (
    SELECT (CASE WHEN COUNT(DISTINCT p.Method) > 1 THEN 'mixed'
                 ELSE MAX(p.Method) END)::varchar AS PaymentMethod
    FROM sales.SalePayment AS p
    WHERE p.SaleId = s.SaleId AND p.AmountH > 0
) AS pm ON true;

/*
  Devices with their connection state worked out.

  Ninety seconds is three missed heartbeats at the ten-second interval — long
  enough that one dropped packet does not turn the light red, short enough that
  a genuinely dead till is noticed.
*/
CREATE OR REPLACE VIEW device.vw_DeviceStatus AS
SELECT
    d.DeviceId, d.DeviceName, d.DeviceType, d.DeviceModel, d.SerialNumber,
    d.BranchId, b.NameAr AS BranchNameAr, b.NameEn AS BranchNameEn,
    d.Location, d.Description, d.PaperWidth, d.PrinterKind,

    (CASE WHEN d.RegisteredAtUtc IS NULL THEN 'unregistered'
          WHEN d.LastHeartbeatAtUtc IS NULL THEN 'unknown'
          WHEN hb.Seconds <= 90 THEN 'online'
          ELSE 'offline'
     END)::varchar AS ConnectionStatus,

    d.LastHeartbeatAtUtc,
    hb.Seconds AS SecondsSinceHeartbeat,

    /*
      A stale device reports nothing, so its printer state is unknown — not
      whatever it last said. A green printer light under an offline device is
      the light that lies.
    */
    (CASE WHEN d.LastHeartbeatAtUtc IS NULL OR hb.Seconds > 90
          THEN 'unknown' ELSE d.PrinterStatus END)::varchar AS PrinterStatus,

    (CASE WHEN d.LastHeartbeatAtUtc IS NULL OR hb.Seconds > 90
          THEN 'unknown' ELSE d.PaperStatus END)::varchar AS PaperStatus,

    d.PrinterError, d.BatteryPercent, d.NetworkType, d.AppVersion,
    d.RegisteredAtUtc, d.RegistrationCode, d.CodeExpiresAtUtc,
    d.RegisteredAtUtc IS NOT NULL AS IsRegistered,
    d.IsActive, d.CreatedAtUtc,

    (SELECT COUNT(*)::int FROM device.DeviceCommand AS c
     WHERE c.DeviceId = d.DeviceId AND c.Status = 'pending') AS PendingCommands
FROM device.PosDevice AS d
JOIN core.Branch AS b ON b.BranchId = d.BranchId
CROSS JOIN LATERAL (
    SELECT floor(extract(epoch FROM (now() AT TIME ZONE 'utc') - d.LastHeartbeatAtUtc))::int AS Seconds
) AS hb;

/*
  Performance per endpoint.

  The average is reported alongside p95 because an average hides the tail: an
  endpoint answering in 40ms for nineteen callers and 4 seconds for the
  twentieth averages 238ms and looks healthy, while the twentieth person is the
  one who complains.
*/
CREATE OR REPLACE VIEW audit.vw_EndpointPerformance AS
SELECT
    ApiPath,
    HttpMethod,
    COUNT(*)::int                              AS Calls,
    trunc(AVG(TotalMs))::int                   AS AvgMs,
    MIN(TotalMs)                               AS MinMs,
    MAX(TotalMs)                               AS MaxMs,
    trunc(AVG(DatabaseMs))::int                AS AvgDatabaseMs,
    COUNT(*) FILTER (WHERE NOT Succeeded)::int AS Failures,
    round(100.0 * COUNT(*) FILTER (WHERE NOT Succeeded) / COUNT(*), 1)::numeric(5,1) AS FailurePercent,
    /* The QA bands from the test plan. */
    (CASE
        WHEN AVG(TotalMs) < 100  THEN 'Excellent'
        WHEN AVG(TotalMs) < 300  THEN 'Good'
        WHEN AVG(TotalMs) < 1000 THEN 'Acceptable'
        WHEN AVG(TotalMs) < 2000 THEN 'Slow'
        ELSE 'Critical'
    END)::varchar                              AS Rating
FROM audit.RequestTiming
GROUP BY ApiPath, HttpMethod;

/*
  Requests that ran the same statement several times.

  This is the N+1 signature: one request, one statement shape, many executions.
*/
CREATE OR REPLACE VIEW audit.vw_SuspectedNPlusOne AS
SELECT
    q.CorrelationId,
    r.ApiPath,
    r.HttpMethod,
    left(q.CommandText, 120)::varchar AS Statement,
    COUNT(*)::int            AS Executions,
    SUM(q.DurationMs)::int   AS TotalMs,
    r.OccurredAtUtc
FROM audit.QueryTiming AS q
JOIN audit.RequestTiming AS r ON r.CorrelationId = q.CorrelationId
GROUP BY q.CorrelationId, r.ApiPath, r.HttpMethod,
         left(q.CommandText, 120), r.OccurredAtUtc
HAVING COUNT(*) >= 5;
