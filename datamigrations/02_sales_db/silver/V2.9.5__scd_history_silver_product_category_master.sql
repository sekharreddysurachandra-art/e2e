-- =============================================================================
-- V2.9.5 : Silver PRODUCT_CATEGORY_MASTER keeps change history (replaces dedup of V2.5.0)
-- Why     : the previous version kept only the latest row per business key, so a
--           changed record was treated as a duplicate and the old version was
--           lost. Gold SCD2 dimensions need every version.
-- Dedup   : only exact re-sends are dropped - a row is removed when its ATTR_HASH
--           (business attributes, no effective dates or load metadata) equals the
--           next row for the same CATEGORY_CODE + EFFECTIVE_START_DATE (the latest copy is kept, so a version closed by a new EFFECTIVE_END_DATE keeps the new end date).
--           Changes back to an earlier value (A -> B -> A) are kept.
-- Version : EFFECTIVE_START_DATE from source; VERSION_START_TS (file arrival) orders versions sharing a start date, flagged SAME_START_DIFFERENT_ATTRIBUTES.
-- Grain   : one row per CATEGORY_CODE version; SILVER_SK = MD5 of key + version + source row.
--           IS_LATEST flags the newest version of each CATEGORY_CODE.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           existing dynamic table in place (one reinitialisation).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.PRODUCT_CATEGORY_MASTER (  -- create or evolve in place
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
  COMMENT      = 'Cleaned, versioned (change history) product category master'
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
),
src AS (   -- cleaned rows with record-level DQ (unchanged logic)
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
),
hashed AS (
  SELECT
    src.*,
    MD5(CONCAT_WS('|', CATEGORY_CODE,
          COALESCE(CATEGORY_NAME::VARCHAR, ''),
          COALESCE(REPORTING_SEGMENT::VARCHAR, ''),
          COALESCE(IS_ACTIVE::VARCHAR, '')))  AS ATTR_HASH,
    __FILE_LAST_MODIFIED_NTZ  AS VERSION_START_TS
  FROM src
),
kept AS (   -- exact re-sends removed, every real change kept
  SELECT * FROM hashed
  -- drop a row when the next copy of the same version has the same attributes
  QUALIFY LEAD(ATTR_HASH) OVER (PARTITION BY CATEGORY_CODE, EFFECTIVE_START_DATE ORDER BY VERSION_START_TS, __FILE_NAME, __ROW_NUMBER) IS DISTINCT FROM ATTR_HASH
),
versioned AS (
  SELECT
    k.*,
    COUNT(*) OVER (PARTITION BY CATEGORY_CODE, EFFECTIVE_START_DATE) > 1  AS START_CONFLICT,
    ROW_NUMBER() OVER (PARTITION BY CATEGORY_CODE ORDER BY EFFECTIVE_START_DATE DESC, VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1  AS IS_LATEST
  FROM kept k
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
  IS_CURRENT,
  RECORD_HASH,
  IFF(START_CONFLICT OR DQ_STATUS = 'WARN', 'WARN', 'PASS')    AS DQ_STATUS,
  IFF(START_CONFLICT, ARRAY_APPEND(DQ_ISSUES, 'SAME_START_DIFFERENT_ATTRIBUTES'), DQ_ISSUES) AS DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ,
  ATTR_HASH,
  VERSION_START_TS,
  IS_LATEST,
  MD5(CONCAT_WS('|', CATEGORY_CODE, EFFECTIVE_START_DATE::VARCHAR, VERSION_START_TS::VARCHAR, __FILE_NAME, __ROW_NUMBER::VARCHAR))  AS SILVER_SK
FROM versioned;
