-- =============================================================================
-- V2.9.2 : Silver CURRENCY_MASTER keeps change history (replaces dedup of V2.4.1)
-- Why     : the previous version kept only the latest row per business key, so a
--           changed record was treated as a duplicate and the old version was
--           lost. Gold SCD2 dimensions need every version.
-- Dedup   : only exact re-sends are dropped - a row is removed when its ATTR_HASH
--           (business attributes, no effective dates or load metadata) equals the
--           next row for the same CURRENCY_CODE + EFFECTIVE_START_DATE (the latest copy is kept, so a version closed by a new EFFECTIVE_END_DATE keeps the new end date).
--           Changes back to an earlier value (A -> B -> A) are kept.
-- Version : EFFECTIVE_START_DATE from source; VERSION_START_TS (file arrival) orders versions sharing a start date, flagged SAME_START_DIFFERENT_ATTRIBUTES.
-- Grain   : one row per CURRENCY_CODE version; SILVER_SK = MD5 of key + version + source row.
--           IS_LATEST flags the newest version of each CURRENCY_CODE.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           existing dynamic table in place (one reinitialisation).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.CURRENCY_MASTER (  -- create or evolve in place
  CURRENCY_CODE            COMMENT 'ISO 4217 currency code (business key, upper-case)',
  CURRENCY_NAME            COMMENT 'Currency name',
  CURRENCY_SYMBOL          COMMENT 'Currency symbol',
  MINOR_UNIT               COMMENT 'Number of decimal places',
  IS_ACTIVE                COMMENT 'Currency is active',
  EFFECTIVE_START_DATE     COMMENT 'Record valid from',
  EFFECTIVE_END_DATE       COMMENT 'Record valid to (9999-12-31 = current)',
  IS_CURRENT               COMMENT 'TRUE when EFFECTIVE_END_DATE = 9999-12-31',
  CREATED_AT               COMMENT 'Created timestamp in source',
  SOURCE_SYSTEM            COMMENT 'Source system of the record',
  RECORD_HASH              COMMENT 'MD5 of business attributes for change detection',
  DQ_STATUS                COMMENT 'PASS or WARN from record-level quality checks',
  DQ_ISSUES                COMMENT 'List of failed quality checks (empty when PASS)',
  __FILE_NAME              COMMENT 'Stage file the row was loaded from',
  __ROW_NUMBER             COMMENT 'Row number within the source file',
  __FILE_LAST_MODIFIED_NTZ COMMENT 'Last modified time of the source file',
  ATTR_HASH                COMMENT 'MD5 of business attributes (no effective dates/metadata) - change detection',
  VERSION_START_TS         COMMENT 'Arrival of this version (file time) - orders versions with the same start date',
  IS_LATEST                COMMENT 'TRUE for the newest version of the business key',
  SILVER_SK                COMMENT 'MD5 of business key + version + source file/row (unique row id)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Bronze rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Cleaned, versioned (change history) currency master'
AS
WITH cleaned AS (
  SELECT
    UPPER(TRIM(CURRENCY_CODE))                       AS CURRENCY_CODE,
    NULLIF(TRIM(CURRENCY_NAME), '')                  AS CURRENCY_NAME,
    NULLIF(TRIM(CURRENCY_SYMBOL), '')                AS CURRENCY_SYMBOL,
    MINOR_UNIT,
    IS_ACTIVE,
    EFFECTIVE_START_DATE,
    EFFECTIVE_END_DATE,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))           AS SOURCE_SYSTEM,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.CURRENCY_MASTER
  WHERE NULLIF(TRIM(CURRENCY_CODE), '') IS NOT NULL -- no business key, no row
),
src AS (   -- cleaned rows with record-level DQ (unchanged logic)
SELECT
  CURRENCY_CODE,
  CURRENCY_NAME,
  CURRENCY_SYMBOL,
  MINOR_UNIT,
  IS_ACTIVE,
  EFFECTIVE_START_DATE,
  EFFECTIVE_END_DATE,
  EFFECTIVE_END_DATE = '9999-12-31'::DATE            AS IS_CURRENT,
  CREATED_AT,
  SOURCE_SYSTEM,
  MD5(CONCAT_WS('|', CURRENCY_CODE, COALESCE(CURRENCY_NAME, ''),
                COALESCE(CURRENCY_SYMBOL, ''),
                COALESCE(MINOR_UNIT::VARCHAR, ''),
                COALESCE(IS_ACTIVE::VARCHAR, ''),
                COALESCE(EFFECTIVE_START_DATE::VARCHAR, ''),
                COALESCE(EFFECTIVE_END_DATE::VARCHAR, '')))  AS RECORD_HASH,
  IFF(ARRAY_SIZE(DQ_ISSUES) = 0, 'PASS', 'WARN')     AS DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ
FROM (
  SELECT
    c.*,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(NOT REGEXP_LIKE(CURRENCY_CODE, '[A-Z]{3}'), 'CURRENCY_CODE_NOT_ISO', NULL),
      IFF(CURRENCY_NAME IS NULL,                  'CURRENCY_NAME_MISSING', NULL),
      IFF(MINOR_UNIT IS NULL OR MINOR_UNIT NOT BETWEEN 0 AND 4, 'MINOR_UNIT_INVALID', NULL),
      IFF(IS_ACTIVE IS NULL,                      'IS_ACTIVE_MISSING', NULL),
      IFF(EFFECTIVE_START_DATE IS NULL,           'START_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE IS NULL,             'END_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE < EFFECTIVE_START_DATE, 'END_BEFORE_START', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                  'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
),
hashed AS (
  SELECT
    src.*,
    MD5(CONCAT_WS('|', CURRENCY_CODE, COALESCE(CURRENCY_NAME, ''),
          COALESCE(CURRENCY_SYMBOL, ''),
          COALESCE(MINOR_UNIT::VARCHAR, ''),
          COALESCE(IS_ACTIVE::VARCHAR, '')))  AS ATTR_HASH,
    __FILE_LAST_MODIFIED_NTZ  AS VERSION_START_TS
  FROM src
),
kept AS (   -- exact re-sends removed, every real change kept
  SELECT * FROM hashed
  -- drop a row when the next copy of the same version has the same attributes
  QUALIFY LEAD(ATTR_HASH) OVER (PARTITION BY CURRENCY_CODE, EFFECTIVE_START_DATE ORDER BY VERSION_START_TS, __FILE_NAME, __ROW_NUMBER) IS DISTINCT FROM ATTR_HASH
),
versioned AS (
  SELECT
    k.*,
    COUNT(*) OVER (PARTITION BY CURRENCY_CODE, EFFECTIVE_START_DATE) > 1  AS START_CONFLICT,
    ROW_NUMBER() OVER (PARTITION BY CURRENCY_CODE ORDER BY EFFECTIVE_START_DATE DESC, VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1  AS IS_LATEST
  FROM kept k
)
SELECT
  CURRENCY_CODE,
  CURRENCY_NAME,
  CURRENCY_SYMBOL,
  MINOR_UNIT,
  IS_ACTIVE,
  EFFECTIVE_START_DATE,
  EFFECTIVE_END_DATE,
  IS_CURRENT,
  CREATED_AT,
  SOURCE_SYSTEM,
  RECORD_HASH,
  IFF(START_CONFLICT OR DQ_STATUS = 'WARN', 'WARN', 'PASS')    AS DQ_STATUS,
  IFF(START_CONFLICT, ARRAY_APPEND(DQ_ISSUES, 'SAME_START_DIFFERENT_ATTRIBUTES'), DQ_ISSUES) AS DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ,
  ATTR_HASH,
  VERSION_START_TS,
  IS_LATEST,
  MD5(CONCAT_WS('|', CURRENCY_CODE, EFFECTIVE_START_DATE::VARCHAR, VERSION_START_TS::VARCHAR, __FILE_NAME, __ROW_NUMBER::VARCHAR))  AS SILVER_SK
FROM versioned;
