-- =============================================================================
-- V2.9.6 : Silver PRODUCT_FAMILY_MASTER keeps change history (replaces dedup of V2.5.1)
-- Why     : the previous version kept only the latest row per business key, so a
--           changed record was treated as a duplicate and the old version was
--           lost. Gold SCD2 dimensions need every version.
-- Dedup   : only exact re-sends are dropped - a row is removed when its ATTR_HASH
--           (business attributes, no effective dates or load metadata) equals the
--           previous row for the same FAMILY_CODE (the first copy is kept, so VERSION_START_TS is when the version first arrived).
--           Changes back to an earlier value (A -> B -> A) are kept.
-- Version : VERSION_START_TS = file arrival time (source has no effective dates).
-- Grain   : one row per FAMILY_CODE version; SILVER_SK = MD5 of key + version + source row.
--           IS_LATEST flags the newest version of each FAMILY_CODE.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           existing dynamic table in place (one reinitialisation).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.PRODUCT_FAMILY_MASTER (  -- create or evolve in place
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
  COMMENT      = 'Cleaned, versioned (change history) product family master'
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
),
src AS (   -- cleaned rows with record-level DQ (unchanged logic)
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
),
hashed AS (
  SELECT
    src.*,
    MD5(CONCAT_WS('|', FAMILY_CODE,
          COALESCE(FAMILY_NAME::VARCHAR, ''),
          COALESCE(CATEGORY_CODE::VARCHAR, ''),
          COALESCE(LAUNCH_YEAR::VARCHAR, ''),
          COALESCE(IS_ACTIVE::VARCHAR, ''),
          COALESCE(LIFECYCLE_STATUS::VARCHAR, '')))  AS ATTR_HASH,
    __FILE_LAST_MODIFIED_NTZ  AS VERSION_START_TS
  FROM src
),
kept AS (   -- exact re-sends removed, every real change kept
  SELECT * FROM hashed
  -- drop a row when the previous copy of the same key has the same attributes
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY FAMILY_CODE ORDER BY VERSION_START_TS, __FILE_NAME, __ROW_NUMBER) IS DISTINCT FROM ATTR_HASH
),
versioned AS (
  SELECT
    k.*,
    ROW_NUMBER() OVER (PARTITION BY FAMILY_CODE ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1  AS IS_LATEST
  FROM kept k
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
  RECORD_HASH,
  DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ,
  ATTR_HASH,
  VERSION_START_TS,
  IS_LATEST,
  MD5(CONCAT_WS('|', FAMILY_CODE, VERSION_START_TS::VARCHAR, __FILE_NAME, __ROW_NUMBER::VARCHAR))  AS SILVER_SK
FROM versioned;
