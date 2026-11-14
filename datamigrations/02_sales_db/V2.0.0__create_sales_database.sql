-- =============================================================================
-- V2.0.0 : Sales database for the target environment ({{ env }})
-- DEV and QA are TRANSIENT (no fail-safe cost, architecture rule 1).
-- PROD is permanent.
-- =============================================================================

CREATE {% if env in ['DEV', 'QA'] %}TRANSIENT {% endif %}DATABASE IF NOT EXISTS SALES_{{ env }}  -- transient for DEV/QA only; never replace
  DATA_RETENTION_TIME_IN_DAYS = 1                          -- time travel window in days
  COMMENT = 'Apple sales analytics - {{ env }} environment';  -- object purpose
