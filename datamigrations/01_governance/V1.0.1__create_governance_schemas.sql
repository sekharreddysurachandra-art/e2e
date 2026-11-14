-- =============================================================================
-- V1.0.1 : Governance schemas
-- TAGS     : tag objects (environment, chargeback, classification)
-- POLICIES : masking, row access and other policies (populated later)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS {{ governance_db }}.TAGS       -- create only if missing
  COMMENT = 'Tags for classification and chargeback';      -- object purpose

CREATE SCHEMA IF NOT EXISTS {{ governance_db }}.POLICIES   -- create only if missing
  COMMENT = 'Masking, row access and other policies';      -- object purpose
