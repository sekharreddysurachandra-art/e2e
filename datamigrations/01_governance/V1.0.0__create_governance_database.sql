-- =============================================================================
-- V1.0.0 : Governance database
-- Shared by DEV, QA and PROD. Holds all tags, masking and other policies
-- (architecture rule 3). Permanent database so it keeps fail-safe.
-- =============================================================================

CREATE DATABASE IF NOT EXISTS {{ governance_db }}          -- create only if missing; never replace
  DATA_RETENTION_TIME_IN_DAYS = 1                          -- time travel window in days
  COMMENT = 'Governance objects: tags, masking and other policies';  -- object purpose
