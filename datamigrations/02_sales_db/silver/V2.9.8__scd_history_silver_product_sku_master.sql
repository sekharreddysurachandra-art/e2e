-- =============================================================================
-- V2.9.8 : Silver PRODUCT_SKU_MASTER keeps change history (replaces dedup of V2.5.3)
-- Why     : the previous version kept only the latest row per business key, so a
--           changed record was treated as a duplicate and the old version was
--           lost. Gold SCD2 dimensions need every version.
-- Dedup   : only exact re-sends are dropped - a row is removed when its ATTR_HASH
--           (business attributes, no effective dates or load metadata) equals the
--           previous row for the same SKU_CODE (the first copy is kept, so VERSION_START_TS is when the version first arrived).
--           Changes back to an earlier value (A -> B -> A) are kept.
-- Version : VERSION_START_TS = file arrival time (source has no effective dates).
-- Grain   : one row per SKU_CODE version; SILVER_SK = MD5 of key + version + source row.
--           IS_LATEST flags the newest version of each SKU_CODE.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           existing dynamic table in place (one reinitialisation).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.PRODUCT_SKU_MASTER (  -- create or evolve in place
  SKU_CODE                 COMMENT 'Stock keeping unit code (business key, upper-case)',
  MODEL_CODE               COMMENT 'Product model code (FK to SILVER.PRODUCT_MODEL_MASTER)',
  VARIANT                  COMMENT 'Variant description (capacity, colour, size)',
  PRICE_TIER               COMMENT 'Price tier (Standard, Premium, Ultra)',
  GLOBAL_LAUNCH_DATE       COMMENT 'Global launch date of the SKU',
  IS_ACTIVE                COMMENT 'SKU is active',
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
  COMMENT      = 'Cleaned, versioned (change history) product SKU master'
AS
WITH cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(SKU_CODE), ''))      AS SKU_CODE,
    UPPER(NULLIF(TRIM(MODEL_CODE), ''))    AS MODEL_CODE,
    NULLIF(TRIM(VARIANT), '')              AS VARIANT,
    NULLIF(TRIM(PRICE_TIER), '')           AS PRICE_TIER,
    GLOBAL_LAUNCH_DATE,
    IS_ACTIVE,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), '')) AS SOURCE_SYSTEM,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.PRODUCT_SKU_MASTER
  WHERE NULLIF(TRIM(SKU_CODE), '') IS NOT NULL   -- no business key, no row
),
src AS (   -- cleaned rows with record-level DQ (unchanged logic)
SELECT
  SKU_CODE,
  MODEL_CODE,
  VARIANT,
  PRICE_TIER,
  GLOBAL_LAUNCH_DATE,
  IS_ACTIVE,
  CREATED_AT,
  SOURCE_SYSTEM,
  MD5(CONCAT_WS('|', SKU_CODE,
                COALESCE(MODEL_CODE::VARCHAR, ''),
                COALESCE(VARIANT::VARCHAR, ''),
                COALESCE(PRICE_TIER::VARCHAR, ''),
                COALESCE(GLOBAL_LAUNCH_DATE::VARCHAR, ''),
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
      IFF(MODEL_CODE IS NULL,                                                       'MODEL_CODE_MISSING', NULL),
      IFF(VARIANT IS NULL,                                                          'VARIANT_MISSING', NULL),
      IFF(PRICE_TIER IS NULL OR PRICE_TIER NOT IN ('Standard', 'Premium', 'Ultra'), 'PRICE_TIER_INVALID', NULL),
      IFF(GLOBAL_LAUNCH_DATE IS NULL,                                               'LAUNCH_DATE_MISSING', NULL),
      IFF(IS_ACTIVE IS NULL,                                                        'IS_ACTIVE_MISSING', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                                                    'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
),
hashed AS (
  SELECT
    src.*,
    MD5(CONCAT_WS('|', SKU_CODE,
          COALESCE(MODEL_CODE::VARCHAR, ''),
          COALESCE(VARIANT::VARCHAR, ''),
          COALESCE(PRICE_TIER::VARCHAR, ''),
          COALESCE(GLOBAL_LAUNCH_DATE::VARCHAR, ''),
          COALESCE(IS_ACTIVE::VARCHAR, '')))  AS ATTR_HASH,
    __FILE_LAST_MODIFIED_NTZ  AS VERSION_START_TS
  FROM src
),
kept AS (   -- exact re-sends removed, every real change kept
  SELECT * FROM hashed
  -- drop a row when the previous copy of the same key has the same attributes
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY SKU_CODE ORDER BY VERSION_START_TS, __FILE_NAME, __ROW_NUMBER) IS DISTINCT FROM ATTR_HASH
),
versioned AS (
  SELECT
    k.*,
    ROW_NUMBER() OVER (PARTITION BY SKU_CODE ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1  AS IS_LATEST
  FROM kept k
)
SELECT
  SKU_CODE,
  MODEL_CODE,
  VARIANT,
  PRICE_TIER,
  GLOBAL_LAUNCH_DATE,
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
  MD5(CONCAT_WS('|', SKU_CODE, VERSION_START_TS::VARCHAR, __FILE_NAME, __ROW_NUMBER::VARCHAR))  AS SILVER_SK
FROM versioned;
