-- =============================================================================
-- V1.2.1 : PII classification tag
-- PII_TYPE : marks a column as personal data and says which kind, so one
--            tag-based masking policy per data type can obfuscate it the right
--            way (V1.2.2). Applied to customer columns in Bronze, Silver, Gold.
-- =============================================================================

CREATE TAG IF NOT EXISTS {{ governance_db }}.TAGS.PII_TYPE             -- create only if missing
  ALLOWED_VALUES 'NAME', 'EMAIL', 'PHONE', 'ADDRESS', 'POSTAL_CODE', 'DATE_OF_BIRTH'
  COMMENT = 'Personal data category of a column; drives tag-based masking in GOVERNANCE.POLICIES';
