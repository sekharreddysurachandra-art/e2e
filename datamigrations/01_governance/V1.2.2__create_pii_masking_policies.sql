-- =============================================================================
-- V1.2.2 : PII masking policies (tag-based)
-- Approach: tag-based masking - the policies are attached once to the tag
--           TAGS.PII_TYPE; every column tagged PII_TYPE is masked automatically
--           in every table, layer and environment (and in new tables once tagged).
-- Access  : PII_READER (V1.2.0, inherited by SYSADMIN) sees clear values; all
--           other roles see obfuscated values. IS_ROLE_IN_SESSION with a constant
--           role name respects role hierarchy and keeps downstream dynamic tables
--           on incremental refresh.
-- Obfuscation (non-readers), chosen per PII_TYPE value of the column:
--   NAME          first letter + '***'              (Jane     -> J***)
--   EMAIL         first letter + '***@' + domain    (jane@x.com -> j***@x.com)
--   PHONE         '***-***-' + last 4 digits        (+1 555 123 4567 -> ***-***-4567)
--   ADDRESS       '*** MASKED ***'
--   POSTAL_CODE   first 2 characters + '***'        (94105 -> 94***)
--   DATE_OF_BIRTH 1 January of the birth year       (1990-07-15 -> 1990-01-01)
--   other / NULL  '*** MASKED ***'
-- Year of birth, e-mail domain and the postal prefix stay usable for analytics.
-- =============================================================================

CREATE MASKING POLICY IF NOT EXISTS {{ governance_db }}.POLICIES.MASK_PII_STRING  -- create only if missing
  AS (VAL STRING) RETURNS STRING ->
  CASE
    WHEN VAL IS NULL                     THEN NULL
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    ELSE
      CASE SYSTEM$GET_TAG_ON_CURRENT_COLUMN('{{ governance_db }}.TAGS.PII_TYPE')
        WHEN 'NAME'        THEN LEFT(VAL, 1) || '***'
        WHEN 'EMAIL'       THEN LEFT(VAL, 1) || '***@' || SPLIT_PART(VAL, '@', 2)
        WHEN 'PHONE'       THEN '***-***-' || RIGHT(REGEXP_REPLACE(VAL, '[^0-9]', ''), 4)
        WHEN 'POSTAL_CODE' THEN LEFT(VAL, 2) || '***'
        ELSE '*** MASKED ***'
      END
  END
  COMMENT = 'Tag-based mask for STRING PII (tag TAGS.PII_TYPE); clear for PII_READER, obfuscated by PII type for others';

CREATE MASKING POLICY IF NOT EXISTS {{ governance_db }}.POLICIES.MASK_PII_DATE    -- create only if missing
  AS (VAL DATE) RETURNS DATE ->
  CASE
    WHEN VAL IS NULL                     THEN NULL
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    ELSE DATE_FROM_PARTS(YEAR(VAL), 1, 1)          -- keep the birth year only
  END
  COMMENT = 'Tag-based mask for DATE PII (tag TAGS.PII_TYPE); clear for PII_READER, year only for others';

-- Attach both policies to the tag: one policy per data type is allowed on a tag.
ALTER TAG {{ governance_db }}.TAGS.PII_TYPE SET
  MASKING POLICY {{ governance_db }}.POLICIES.MASK_PII_STRING,
  MASKING POLICY {{ governance_db }}.POLICIES.MASK_PII_DATE;
