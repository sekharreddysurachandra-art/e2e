-- =============================================================================
-- V1.1.0 : Governance tags
-- ENVIRONMENT : identifies which deployment environment an object belongs to.
-- =============================================================================

CREATE TAG IF NOT EXISTS {{ governance_db }}.TAGS.ENVIRONMENT  -- create only if missing
  ALLOWED_VALUES 'DEV', 'QA', 'PROD'                           -- only these values can be assigned
  COMMENT = 'Deployment environment of the object';            -- object purpose
