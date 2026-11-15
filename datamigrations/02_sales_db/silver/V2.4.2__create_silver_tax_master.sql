-- =============================================================================
-- V2.4.2 : Silver TAX_MASTER dynamic table (Bronze -> Silver)
-- Grain   : one row per TAX_CODE + EFFECTIVE_START_DATE (rates change over time).
-- Dedup   : COPY does not reject duplicates, so the latest copy of a key wins
--           (newest file, then highest row number in that file).
-- Quality : codes/types trimmed/upper-cased, rows without a key are dropped;
--           record-level checks are exposed in DQ_STATUS / DQ_ISSUES.
-- Keeps the 3 Bronze load metadata columns for lineage back to the file.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold consumers).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.TAX_MASTER (  -- create only if missing
  TAX_CODE                 COMMENT 'Tax code (business key, upper-case)',
  TAX_TYPE                 COMMENT 'Tax type (e.g. VAT, GST, SALES_TAX, NONE)',
  TAX_RATE                 COMMENT 'Tax rate as decimal fraction (0.2 = 20%)',
  TAX_RATE_PCT             COMMENT 'Tax rate as percentage (TAX_RATE * 100)',
  TAX_INCLUSIVE_FLAG       COMMENT 'Prices include tax',
  IS_ACTIVE                COMMENT 'Tax code is active',
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
  __FILE_LAST_MODIFIED_NTZ COMMENT 'Last modified time of the source file'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Bronze rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Cleaned, de-duplicated tax master'
AS
WITH cleaned AS (
  SELECT
    UPPER(TRIM(TAX_CODE))                            AS TAX_CODE,
    UPPER(NULLIF(TRIM(TAX_TYPE), ''))                AS TAX_TYPE,
    TAX_RATE,
    TAX_INCLUSIVE_FLAG,
    IS_ACTIVE,
    EFFECTIVE_START_DATE,
    EFFECTIVE_END_DATE,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))           AS SOURCE_SYSTEM,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.TAX_MASTER
  WHERE NULLIF(TRIM(TAX_CODE), '') IS NOT NULL      -- no business key, no row
)
SELECT
  TAX_CODE,
  TAX_TYPE,
  TAX_RATE,
  TAX_RATE * 100                                     AS TAX_RATE_PCT,
  TAX_INCLUSIVE_FLAG,
  IS_ACTIVE,
  EFFECTIVE_START_DATE,
  EFFECTIVE_END_DATE,
  EFFECTIVE_END_DATE = '9999-12-31'::DATE            AS IS_CURRENT,
  CREATED_AT,
  SOURCE_SYSTEM,
  MD5(CONCAT_WS('|', TAX_CODE, COALESCE(TAX_TYPE, ''),
                COALESCE(TAX_RATE::VARCHAR, ''),
                COALESCE(TAX_INCLUSIVE_FLAG::VARCHAR, ''),
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
      IFF(TAX_TYPE IS NULL,                       'TAX_TYPE_MISSING', NULL),
      IFF(TAX_RATE IS NULL OR TAX_RATE NOT BETWEEN 0 AND 1, 'TAX_RATE_OUT_OF_RANGE', NULL),
      IFF(TAX_TYPE = 'NONE' AND TAX_RATE <> 0,    'NONE_TYPE_WITH_RATE', NULL),
      IFF(TAX_INCLUSIVE_FLAG IS NULL,             'TAX_INCLUSIVE_FLAG_MISSING', NULL),
      IFF(IS_ACTIVE IS NULL,                      'IS_ACTIVE_MISSING', NULL),
      IFF(EFFECTIVE_START_DATE IS NULL,           'START_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE IS NULL,             'END_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE < EFFECTIVE_START_DATE, 'END_BEFORE_START', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                  'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY TAX_CODE, EFFECTIVE_START_DATE
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
