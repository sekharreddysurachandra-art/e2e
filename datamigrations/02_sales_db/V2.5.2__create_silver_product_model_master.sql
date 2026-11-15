-- =============================================================================
-- V2.5.2 : Silver PRODUCT_MODEL_MASTER dynamic table (Bronze -> Silver)
-- Grain   : one row per MODEL_CODE (model names can repeat across years).
-- Dedup   : COPY does not reject duplicates, so the latest copy of a key wins
--           (newest file, then highest row number in that file).
-- Quality : codes trimmed/upper-cased, text trimmed, rows without a key are
--           dropped; record-level checks are exposed in DQ_STATUS / DQ_ISSUES.
-- Notes   : DISCONTINUE_DATE is text in Bronze and is cast to DATE here.
-- Keeps the 3 Bronze load metadata columns for lineage back to the file.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold consumers).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.PRODUCT_MODEL_MASTER (  -- create only if missing
  MODEL_CODE               COMMENT 'Product model code (business key, upper-case)',
  MODEL_NAME               COMMENT 'Product model name (not unique across years)',
  FAMILY_CODE              COMMENT 'Product family code (FK to SILVER.PRODUCT_FAMILY_MASTER)',
  LAUNCH_DATE              COMMENT 'Model launch date',
  DISCONTINUE_DATE         COMMENT 'Model discontinue date (NULL = still sold)',
  LIFECYCLE_STATUS         COMMENT 'Lifecycle status (e.g. ACTIVE)',
  IS_ACTIVE                COMMENT 'Model is active',
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
  COMMENT      = 'Cleaned, de-duplicated product model master'
AS
WITH cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(MODEL_CODE), ''))             AS MODEL_CODE,
    NULLIF(TRIM(MODEL_NAME), '')                    AS MODEL_NAME,
    UPPER(NULLIF(TRIM(FAMILY_CODE), ''))            AS FAMILY_CODE,
    LAUNCH_DATE,
    TRY_TO_DATE(NULLIF(TRIM(DISCONTINUE_DATE), '')) AS DISCONTINUE_DATE,
    UPPER(NULLIF(TRIM(LIFECYCLE_STATUS), ''))       AS LIFECYCLE_STATUS,
    IS_ACTIVE,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))          AS SOURCE_SYSTEM,
    NULLIF(TRIM(DISCONTINUE_DATE), '')              AS DISCONTINUE_DATE_RAW,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.PRODUCT_MODEL_MASTER
  WHERE NULLIF(TRIM(MODEL_CODE), '') IS NOT NULL   -- no business key, no row
)
SELECT
  MODEL_CODE,
  MODEL_NAME,
  FAMILY_CODE,
  LAUNCH_DATE,
  DISCONTINUE_DATE,
  LIFECYCLE_STATUS,
  IS_ACTIVE,
  CREATED_AT,
  SOURCE_SYSTEM,
  MD5(CONCAT_WS('|', MODEL_CODE,
                COALESCE(MODEL_NAME::VARCHAR, ''),
                COALESCE(FAMILY_CODE::VARCHAR, ''),
                COALESCE(LAUNCH_DATE::VARCHAR, ''),
                COALESCE(DISCONTINUE_DATE::VARCHAR, ''),
                COALESCE(LIFECYCLE_STATUS::VARCHAR, ''),
                COALESCE(IS_ACTIVE::VARCHAR, '')))  AS RECORD_HASH,
  IFF(ARRAY_SIZE(DQ_ISSUES) = 0, 'PASS', 'WARN')     AS DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ
FROM (
  SELECT
    c.*,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(MODEL_NAME IS NULL,                                            'MODEL_NAME_MISSING', NULL),
      IFF(FAMILY_CODE IS NULL,                                           'FAMILY_CODE_MISSING', NULL),
      IFF(LAUNCH_DATE IS NULL,                                           'LAUNCH_DATE_MISSING', NULL),
      IFF(DISCONTINUE_DATE_RAW IS NOT NULL AND DISCONTINUE_DATE IS NULL, 'DISCONTINUE_DATE_UNPARSEABLE', NULL),
      IFF(DISCONTINUE_DATE < LAUNCH_DATE,                                'DISCONTINUE_BEFORE_LAUNCH', NULL),
      IFF(IS_ACTIVE IS NULL,                                             'IS_ACTIVE_MISSING', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                                         'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY MODEL_CODE
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
