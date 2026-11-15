-- =============================================================================
-- V1.2.0 : PII access role
-- PII_READER : the only role that sees customer PII in clear text. Every other
--              role sees obfuscated values (GOVERNANCE.POLICIES masking policies).
-- SYSADMIN inherits it because the Silver/Gold dynamic tables refresh as their
-- owner SYSADMIN: without it they would copy masked values downstream.
-- Grant PII_READER to other roles/users only with a business need.
-- =============================================================================

CREATE ROLE IF NOT EXISTS PII_READER                                  -- create only if missing
  COMMENT = 'Sees customer PII unmasked (names, e-mail, phone, address, postal code, date of birth)';

GRANT ROLE PII_READER TO ROLE SYSADMIN;                               -- pipeline owner must read real values
