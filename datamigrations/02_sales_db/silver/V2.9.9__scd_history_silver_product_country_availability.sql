-- =============================================================================
-- V2.9.9 : Silver PRODUCT_COUNTRY_AVAILABILITY keeps change history (replaces dedup of V2.5.4)
-- Why     : the previous version kept only the latest row per business key, so a
--           changed record was treated as a duplicate and the old version was
--           lost. Gold SCD2 dimensions need every version.
-- Dedup   : only exact re-sends are dropped - a row is removed when its ATTR_HASH
--           (business attributes, no effective dates or load metadata) equals the
--           previous row for the same SKU_CODE, COUNTRY_CODE (the first copy is kept, so VERSION_START_TS is when the version first arrived).
--           Changes back to an earlier value (A -> B -> A) are kept.
-- Version : VERSION_START_TS = file arrival time (source has no effective dates).
-- Grain   : one row per SKU_CODE, COUNTRY_CODE version; SILVER_SK = MD5 of key + version + source row.
--           IS_LATEST flags the newest version of each SKU_CODE, COUNTRY_CODE.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           existing dynamic table in place (one reinitialisation).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.PRODUCT_COUNTRY_AVAILABILITY (  -- create or evolve in place
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
  COMMENT      = 'Cleaned, versioned (change history) product country availability'
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
),
src AS (   -- cleaned rows with record-level DQ (unchanged logic)
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
),
hashed AS (
  SELECT
    src.*,
    MD5(CONCAT_WS('|', SKU_CODE,
          COALESCE(COUNTRY_CODE::VARCHAR, ''),
          COALESCE(LOCAL_PART_NUMBER::VARCHAR, ''),
          COALESCE(LOCAL_LAUNCH_DATE::VARCHAR, ''),
          COALESCE(LOCAL_DISCONTINUE_DATE::VARCHAR, ''),
          COALESCE(IS_AVAILABLE::VARCHAR, '')))  AS ATTR_HASH,
    __FILE_LAST_MODIFIED_NTZ  AS VERSION_START_TS
  FROM src
),
kept AS (   -- exact re-sends removed, every real change kept
  SELECT * FROM hashed
  -- drop a row when the previous copy of the same key has the same attributes
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY SKU_CODE, COUNTRY_CODE ORDER BY VERSION_START_TS, __FILE_NAME, __ROW_NUMBER) IS DISTINCT FROM ATTR_HASH
),
versioned AS (
  SELECT
    k.*,
    ROW_NUMBER() OVER (PARTITION BY SKU_CODE, COUNTRY_CODE ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1  AS IS_LATEST
  FROM kept k
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
  RECORD_HASH,
  DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ,
  ATTR_HASH,
  VERSION_START_TS,
  IS_LATEST,
  MD5(CONCAT_WS('|', SKU_CODE, COUNTRY_CODE, VERSION_START_TS::VARCHAR, __FILE_NAME, __ROW_NUMBER::VARCHAR))  AS SILVER_SK
FROM versioned;
