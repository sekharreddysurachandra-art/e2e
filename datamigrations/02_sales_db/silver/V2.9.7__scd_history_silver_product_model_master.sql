-- =============================================================================
-- V2.9.7 : Silver PRODUCT_MODEL_MASTER keeps change history (replaces dedup of V2.5.2)
-- Why     : the previous version kept only the latest row per business key, so a
--           changed record was treated as a duplicate and the old version was
--           lost. Gold SCD2 dimensions need every version.
-- Dedup   : only exact re-sends are dropped - a row is removed when its ATTR_HASH
--           (business attributes, no effective dates or load metadata) equals the
--           previous row for the same MODEL_CODE (the first copy is kept, so VERSION_START_TS is when the version first arrived).
--           Changes back to an earlier value (A -> B -> A) are kept.
-- Version : VERSION_START_TS = file arrival time (source has no effective dates).
-- Grain   : one row per MODEL_CODE version; SILVER_SK = MD5 of key + version + source row.
--           IS_LATEST flags the newest version of each MODEL_CODE.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           existing dynamic table in place (one reinitialisation).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.PRODUCT_MODEL_MASTER (  -- create or evolve in place
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
  __FILE_LAST_MODIFIED_NTZ COMMENT 'Last modified time of the source file',
  ATTR_HASH                COMMENT 'MD5 of business attributes (no effective dates/metadata) - change detection',
  VERSION_START_TS         COMMENT 'Version valid from: file arrival time',
  IS_LATEST                COMMENT 'TRUE for the newest version of the business key',
  SILVER_SK                COMMENT 'MD5 of business key + version + source file/row (unique row id)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Bronze rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Cleaned, versioned (change history) product model master'
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
),
src AS (   -- cleaned rows with record-level DQ (unchanged logic)
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
),
hashed AS (
  SELECT
    src.*,
    MD5(CONCAT_WS('|', MODEL_CODE,
          COALESCE(MODEL_NAME::VARCHAR, ''),
          COALESCE(FAMILY_CODE::VARCHAR, ''),
          COALESCE(LAUNCH_DATE::VARCHAR, ''),
          COALESCE(DISCONTINUE_DATE::VARCHAR, ''),
          COALESCE(LIFECYCLE_STATUS::VARCHAR, ''),
          COALESCE(IS_ACTIVE::VARCHAR, '')))  AS ATTR_HASH,
    __FILE_LAST_MODIFIED_NTZ  AS VERSION_START_TS
  FROM src
),
kept AS (   -- exact re-sends removed, every real change kept
  SELECT * FROM hashed
  -- drop a row when the previous copy of the same key has the same attributes
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY MODEL_CODE ORDER BY VERSION_START_TS, __FILE_NAME, __ROW_NUMBER) IS DISTINCT FROM ATTR_HASH
),
versioned AS (
  SELECT
    k.*,
    ROW_NUMBER() OVER (PARTITION BY MODEL_CODE ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1  AS IS_LATEST
  FROM kept k
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
  RECORD_HASH,
  DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ,
  ATTR_HASH,
  VERSION_START_TS,
  IS_LATEST,
  MD5(CONCAT_WS('|', MODEL_CODE, VERSION_START_TS::VARCHAR, __FILE_NAME, __ROW_NUMBER::VARCHAR))  AS SILVER_SK
FROM versioned;
