-- =============================================================================
-- V2.5.3 : Silver PRODUCT_SKU_MASTER dynamic table (Bronze -> Silver)
-- Grain   : one row per SKU_CODE.
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

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.PRODUCT_SKU_MASTER (  -- create only if missing
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
  __FILE_LAST_MODIFIED_NTZ COMMENT 'Last modified time of the source file'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Bronze rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Cleaned, de-duplicated product SKU master'
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
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY SKU_CODE
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
