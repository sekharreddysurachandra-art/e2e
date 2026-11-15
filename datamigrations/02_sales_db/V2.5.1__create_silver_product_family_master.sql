-- =============================================================================
-- V2.5.1 : Silver PRODUCT_FAMILY_MASTER dynamic table (Bronze -> Silver)
-- Grain   : one row per FAMILY_CODE.
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

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.PRODUCT_FAMILY_MASTER (  -- create only if missing
  FAMILY_CODE              COMMENT 'Product family code (business key, upper-case)',
  FAMILY_NAME              COMMENT 'Product family name',
  CATEGORY_CODE            COMMENT 'Product category code (FK to SILVER.PRODUCT_CATEGORY_MASTER)',
  LAUNCH_YEAR              COMMENT 'Year the family was launched',
  IS_ACTIVE                COMMENT 'Family is active',
  LIFECYCLE_STATUS         COMMENT 'Lifecycle status (e.g. ACTIVE)',
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
  COMMENT      = 'Cleaned, de-duplicated product family master'
AS
WITH cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(FAMILY_CODE), ''))      AS FAMILY_CODE,
    NULLIF(TRIM(FAMILY_NAME), '')             AS FAMILY_NAME,
    UPPER(NULLIF(TRIM(CATEGORY_CODE), ''))    AS CATEGORY_CODE,
    LAUNCH_YEAR,
    IS_ACTIVE,
    UPPER(NULLIF(TRIM(LIFECYCLE_STATUS), '')) AS LIFECYCLE_STATUS,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))    AS SOURCE_SYSTEM,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.PRODUCT_FAMILY_MASTER
  WHERE NULLIF(TRIM(FAMILY_CODE), '') IS NOT NULL   -- no business key, no row
)
SELECT
  FAMILY_CODE,
  FAMILY_NAME,
  CATEGORY_CODE,
  LAUNCH_YEAR,
  IS_ACTIVE,
  LIFECYCLE_STATUS,
  CREATED_AT,
  SOURCE_SYSTEM,
  MD5(CONCAT_WS('|', FAMILY_CODE,
                COALESCE(FAMILY_NAME::VARCHAR, ''),
                COALESCE(CATEGORY_CODE::VARCHAR, ''),
                COALESCE(LAUNCH_YEAR::VARCHAR, ''),
                COALESCE(IS_ACTIVE::VARCHAR, ''),
                COALESCE(LIFECYCLE_STATUS::VARCHAR, '')))  AS RECORD_HASH,
  IFF(ARRAY_SIZE(DQ_ISSUES) = 0, 'PASS', 'WARN')     AS DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ
FROM (
  SELECT
    c.*,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(FAMILY_NAME IS NULL,                                          'FAMILY_NAME_MISSING', NULL),
      IFF(CATEGORY_CODE IS NULL,                                        'CATEGORY_CODE_MISSING', NULL),
      IFF(LAUNCH_YEAR IS NULL OR LAUNCH_YEAR NOT BETWEEN 1976 AND 2100, 'LAUNCH_YEAR_INVALID', NULL),
      IFF(LIFECYCLE_STATUS IS NULL,                                     'LIFECYCLE_STATUS_MISSING', NULL),
      IFF(IS_ACTIVE IS NULL,                                            'IS_ACTIVE_MISSING', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                                        'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY FAMILY_CODE
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
