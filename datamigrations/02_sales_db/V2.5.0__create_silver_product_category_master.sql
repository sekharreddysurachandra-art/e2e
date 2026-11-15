-- =============================================================================
-- V2.5.0 : Silver PRODUCT_CATEGORY_MASTER dynamic table (Bronze -> Silver)
-- Grain   : one row per CATEGORY_CODE + EFFECTIVE_START_DATE (SCD2-style master).
-- Dedup   : COPY does not reject duplicates, so the latest copy of a key wins
--           (newest file, then highest row number in that file).
-- Quality : codes trimmed/upper-cased, text trimmed, rows without a key are
--           dropped; record-level checks are exposed in DQ_STATUS / DQ_ISSUES.
-- Keeps the 3 Bronze load metadata columns for lineage back to the file.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold consumers).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.PRODUCT_CATEGORY_MASTER (  -- create only if missing
  CATEGORY_CODE            COMMENT 'Product category code (business key, upper-case)',
  CATEGORY_NAME            COMMENT 'Product category name',
  REPORTING_SEGMENT        COMMENT 'Financial reporting segment (e.g. iPhone, Mac)',
  IS_ACTIVE                COMMENT 'Category is active',
  EFFECTIVE_START_DATE     COMMENT 'Record valid from',
  EFFECTIVE_END_DATE       COMMENT 'Record valid to (9999-12-31 = current)',
  CREATED_AT               COMMENT 'Created timestamp in source',
  SOURCE_SYSTEM            COMMENT 'Source system of the record',
  IS_CURRENT               COMMENT 'TRUE when EFFECTIVE_END_DATE = 9999-12-31',
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
  COMMENT      = 'Cleaned, de-duplicated product category master'
AS
WITH cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(CATEGORY_CODE), '')) AS CATEGORY_CODE,
    NULLIF(TRIM(CATEGORY_NAME), '')        AS CATEGORY_NAME,
    NULLIF(TRIM(REPORTING_SEGMENT), '')    AS REPORTING_SEGMENT,
    IS_ACTIVE,
    EFFECTIVE_START_DATE,
    EFFECTIVE_END_DATE,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), '')) AS SOURCE_SYSTEM,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.PRODUCT_CATEGORY_MASTER
  WHERE NULLIF(TRIM(CATEGORY_CODE), '') IS NOT NULL
    AND EFFECTIVE_START_DATE IS NOT NULL   -- no business key, no row
)
SELECT
  CATEGORY_CODE,
  CATEGORY_NAME,
  REPORTING_SEGMENT,
  IS_ACTIVE,
  EFFECTIVE_START_DATE,
  EFFECTIVE_END_DATE,
  CREATED_AT,
  SOURCE_SYSTEM,
  EFFECTIVE_END_DATE = '9999-12-31'::DATE     AS IS_CURRENT,
  MD5(CONCAT_WS('|', CATEGORY_CODE,
                COALESCE(CATEGORY_NAME::VARCHAR, ''),
                COALESCE(REPORTING_SEGMENT::VARCHAR, ''),
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
      IFF(CATEGORY_NAME IS NULL,                     'CATEGORY_NAME_MISSING', NULL),
      IFF(REPORTING_SEGMENT IS NULL,                 'REPORTING_SEGMENT_MISSING', NULL),
      IFF(EFFECTIVE_START_DATE IS NULL,              'START_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE IS NULL,                'END_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE < EFFECTIVE_START_DATE, 'END_BEFORE_START', NULL),
      IFF(IS_ACTIVE IS NULL,                         'IS_ACTIVE_MISSING', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                     'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY CATEGORY_CODE, EFFECTIVE_START_DATE
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
