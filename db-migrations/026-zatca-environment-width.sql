/*
  026 — room for the 'developer-portal' environment.

  024 made zatca.EgsUnit.Environment and zatca.Document.Environment
  varchar(12); 025 added 'developer-portal' (16 characters) to the allowed
  values, so activating a unit onboarded on ZATCA's developer portal failed
  with "value too long for type character varying(12)". Widening a varchar
  rewrites nothing and keeps every value.
*/

ALTER TABLE zatca.EgsUnit ALTER COLUMN Environment TYPE varchar(20) COLLATE ci;
ALTER TABLE zatca.Document ALTER COLUMN Environment TYPE varchar(20) COLLATE ci;
