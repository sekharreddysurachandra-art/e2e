-- =============================================================================
-- V2.5.4 : Silver PRODUCT_COUNTRY_AVAILABILITY dynamic table (Bronze -> Silver)
-- Grain   : one row per SKU_CODE + COUNTRY_CODE.
-- Dedup   : COPY does not reject duplicates, so the latest copy of a key wins
--           (newest file, then highest row number in that file).
-- Quality : codes trimmed/upper-cased, text trimmed, rows without a key are
--           dropped; record-level checks are exposed in DQ_STATUS / DQ_ISSUES.
-- Notes   : LOCAL_DISCONTINUE_DATE is text in Bronze and is cast to DATE here.
--           LOCAL_PART_NUMBER is not unique (the same part can be sold in several countries).
-- Keeps the 3 Bronze load metadata columns for lineage back to the file.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold consumers).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.PRODUCT_COUNTRY_AVAILABILITY (  -- create only if missing
  SKU_CODE                 COMMENT 'SKU code (FK to SILVER.PRODUCT_SKU_MASTER)',
  COUNTRY_CODE             COMMENT 'ISO 2-letter country code (FK to SILVER.COUNTRY_MASTER)',
  LOCAL_PART_NUMBER        COMMENT 'Country-specific part number',
  LOCAL_LAUNCH_DATE        COMMENT 'Launch date in the country',
  LOCAL_DISCONTINUE_DATE   COMMENT 'Discontinue date in the country (NULL = still sold)',
  IS_AVAILABLE             COMMENT 'SKU is available in the country',
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
  COMMENT      = 'Cleaned, de-duplicated product country availability'
AS
WITH cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(SKU_CODE), ''))                     AS SKU_CODE,
    UPPER(NULLIF(TRIM(COUNTRY_CODE), ''))                 AS COUNTRY_CODE,
    UPPER(NULLIF(TRIM(LOCAL_PART_NUMBER), ''))            AS LOCAL_PART_NUMBER,
    LOCAL_LAUNCH_DATE,
    TRY_TO_DATE(NULLIF(TRIM(LOCAL_DISCONTINUE_DATE), '')) AS LOCAL_DISCONTINUE_DATE,
    IS_AVAILABLE,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))                AS SOURCE_SYSTEM,
    NULLIF(TRIM(LOCAL_DISCONTINUE_DATE), '')              AS LOCAL_DISCONTINUE_DATE_RAW,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.PRODUCT_COUNTRY_AVAILABILITY
  WHERE NULLIF(TRIM(SKU_CODE), '') IS NOT NULL
    AND NULLIF(TRIM(COUNTRY_CODE), '') IS NOT NULL   -- no business key, no row
)
SELECT
  SKU_CODE,
  COUNTRY_CODE,
  LOCAL_PART_NUMBER,
  LOCAL_LAUNCH_DATE,
  LOCAL_DISCONTINUE_DATE,
  IS_AVAILABLE,
  CREATED_AT,
  SOURCE_SYSTEM,
  MD5(CONCAT_WS('|', SKU_CODE,
                COALESCE(COUNTRY_CODE::VARCHAR, ''),
                COALESCE(LOCAL_PART_NUMBER::VARCHAR, ''),
                COALESCE(LOCAL_LAUNCH_DATE::VARCHAR, ''),
                COALESCE(LOCAL_DISCONTINUE_DATE::VARCHAR, ''),
                COALESCE(IS_AVAILABLE::VARCHAR, '')))  AS RECORD_HASH,
  IFF(ARRAY_SIZE(DQ_ISSUES) = 0, 'PASS', 'WARN')     AS DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ
FROM (
  SELECT
    c.*,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(COUNTRY_CODE IS NULL OR NOT REGEXP_LIKE(COUNTRY_CODE, '[A-Z]{2}'),         'COUNTRY_CODE_NOT_ISO2', NULL),
      IFF(LOCAL_PART_NUMBER IS NULL,                                                 'LOCAL_PART_NUMBER_MISSING', NULL),
      IFF(LOCAL_LAUNCH_DATE IS NULL,                                                 'LAUNCH_DATE_MISSING', NULL),
      IFF(LOCAL_DISCONTINUE_DATE_RAW IS NOT NULL AND LOCAL_DISCONTINUE_DATE IS NULL, 'DISCONTINUE_DATE_UNPARSEABLE', NULL),
      IFF(LOCAL_DISCONTINUE_DATE < LOCAL_LAUNCH_DATE,                                'DISCONTINUE_BEFORE_LAUNCH', NULL),
      IFF(IS_AVAILABLE IS NULL,                                                      'IS_AVAILABLE_MISSING', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                                                     'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY SKU_CODE, COUNTRY_CODE
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
