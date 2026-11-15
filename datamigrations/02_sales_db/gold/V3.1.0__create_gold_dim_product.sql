-- =============================================================================
-- V3.1.0 : Gold DIM_PRODUCT dynamic table (Silver -> Gold), SCD Type 2
-- Sources : SILVER.PRODUCT_SKU_MASTER (driver), PRODUCT_MODEL_MASTER,
--           PRODUCT_FAMILY_MASTER, PRODUCT_CATEGORY_MASTER (versioned, V2.9.x).
--           Hierarchy SKU -> model -> family -> category is flattened onto the SKU.
--           PRODUCT_COUNTRY_AVAILABILITY has a different grain (SKU x country)
--           and is its own dimension, GOLD.DIM_PRODUCT_COUNTRY (V3.1.1).
-- Grain   : one row per SKU_CODE + EFFECTIVE_START_DATE. A new version starts
--           whenever the SKU OR its model, family or category changes (same
--           interval logic as DIM_COUNTRY), clipped to the SKU version window.
-- Versions: category uses its source effective dates; SKU, model and family have
--           none, so a version starts on the day it arrived (VERSION_START_TS).
--           The first version of each code starts 1900-01-01 so facts dated
--           before the first load (e.g. 2019 sales) still find a row.
-- Key     : PRODUCT_SK = MD5(SKU_CODE|EFFECTIVE_START_DATE) - deterministic hash.
-- SCD2    : inclusive end dates (9999-12-31 = open), IS_CURRENT, RECORD_HASH;
--           consecutive segments with identical attributes are merged.
-- Lookups : equality joins + QUALIFY (incremental refresh does not allow outer
--           joins with range predicates); missing parents are shown in DQ_ISSUES.
-- Keys    : NOT NULL enforced on key/SCD columns; dynamic tables do not allow
--           PRIMARY KEY / UNIQUE, so uniqueness is asserted by the check below.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold facts).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.DIM_PRODUCT (  -- create only if missing
  PRODUCT_SK                 VARCHAR(32) NOT NULL COMMENT 'Surrogate key: MD5(SKU_CODE|EFFECTIVE_START_DATE) (logical PK)',
  SKU_CODE                   VARCHAR     NOT NULL COMMENT 'Stock keeping unit code (business key)',
  VARIANT                                         COMMENT 'Variant description (capacity, colour, size)',
  PRICE_TIER                                      COMMENT 'Price tier (Standard, Premium, Ultra)',
  SKU_GLOBAL_LAUNCH_DATE                          COMMENT 'Global launch date of the SKU',
  SKU_IS_ACTIVE                                   COMMENT 'SKU is active in source',
  MODEL_CODE                                      COMMENT 'Product model code',
  MODEL_NAME                                      COMMENT 'Product model name (not unique across years)',
  MODEL_LAUNCH_DATE                               COMMENT 'Model launch date',
  MODEL_DISCONTINUE_DATE                          COMMENT 'Model discontinue date (NULL = still sold)',
  MODEL_LIFECYCLE_STATUS                          COMMENT 'Model lifecycle status',
  MODEL_IS_ACTIVE                                 COMMENT 'Model is active in source',
  FAMILY_CODE                                     COMMENT 'Product family code',
  FAMILY_NAME                                     COMMENT 'Product family name',
  FAMILY_LAUNCH_YEAR                              COMMENT 'Year the family was launched',
  FAMILY_LIFECYCLE_STATUS                         COMMENT 'Family lifecycle status',
  FAMILY_IS_ACTIVE                                COMMENT 'Family is active in source',
  CATEGORY_CODE                                   COMMENT 'Product category code',
  CATEGORY_NAME                                   COMMENT 'Product category name',
  REPORTING_SEGMENT                               COMMENT 'Financial reporting segment (e.g. iPhone, Mac)',
  CATEGORY_IS_ACTIVE                              COMMENT 'Category is active in source',
  EFFECTIVE_START_DATE       DATE        NOT NULL COMMENT 'SCD2 version valid from (inclusive; first version = 1900-01-01)',
  EFFECTIVE_END_DATE         DATE        NOT NULL COMMENT 'SCD2 version valid to (inclusive, 9999-12-31 = open)',
  IS_CURRENT                 BOOLEAN     NOT NULL COMMENT 'TRUE for the open (current) version of the SKU',
  RECORD_HASH                VARCHAR(32) NOT NULL COMMENT 'MD5 of Type-2 attributes for change detection',
  DQ_STATUS                  VARCHAR(4)  NOT NULL COMMENT 'PASS or WARN from dimension-level quality checks',
  DQ_ISSUES                                       COMMENT 'List of failed quality checks (empty when PASS)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Silver rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Product dimension (SCD2): SKU + model + family + category, hash surrogate key PRODUCT_SK'
AS
-- Version windows per source: one version per code per day (latest arrival),
-- unchanged days dropped, first version back-dated to 1900-01-01.
WITH sku_d AS (
  SELECT *, VERSION_START_TS::DATE AS V_DATE FROM SALES_{{ env }}.SILVER.PRODUCT_SKU_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SKU_CODE, VERSION_START_TS::DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
sku_c AS (
  SELECT * FROM sku_d
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY SKU_CODE ORDER BY V_DATE) IS DISTINCT FROM ATTR_HASH
),
sku AS (
  SELECT x.*,
    IFF(ROW_NUMBER() OVER (PARTITION BY SKU_CODE ORDER BY V_DATE) = 1, '1900-01-01'::DATE, V_DATE) AS V_START,
    COALESCE(DATEADD(DAY, -1, LEAD(V_DATE) OVER (PARTITION BY SKU_CODE ORDER BY V_DATE)), '9999-12-31'::DATE) AS V_END
  FROM sku_c x
),
mdl_d AS (
  SELECT *, VERSION_START_TS::DATE AS V_DATE FROM SALES_{{ env }}.SILVER.PRODUCT_MODEL_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY MODEL_CODE, VERSION_START_TS::DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
mdl_c AS (
  SELECT * FROM mdl_d
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY MODEL_CODE ORDER BY V_DATE) IS DISTINCT FROM ATTR_HASH
),
mdl AS (
  SELECT x.*,
    IFF(ROW_NUMBER() OVER (PARTITION BY MODEL_CODE ORDER BY V_DATE) = 1, '1900-01-01'::DATE, V_DATE) AS V_START,
    COALESCE(DATEADD(DAY, -1, LEAD(V_DATE) OVER (PARTITION BY MODEL_CODE ORDER BY V_DATE)), '9999-12-31'::DATE) AS V_END
  FROM mdl_c x
),
fam_d AS (
  SELECT *, VERSION_START_TS::DATE AS V_DATE FROM SALES_{{ env }}.SILVER.PRODUCT_FAMILY_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY FAMILY_CODE, VERSION_START_TS::DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
fam_c AS (
  SELECT * FROM fam_d
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY FAMILY_CODE ORDER BY V_DATE) IS DISTINCT FROM ATTR_HASH
),
fam AS (
  SELECT x.*,
    IFF(ROW_NUMBER() OVER (PARTITION BY FAMILY_CODE ORDER BY V_DATE) = 1, '1900-01-01'::DATE, V_DATE) AS V_START,
    COALESCE(DATEADD(DAY, -1, LEAD(V_DATE) OVER (PARTITION BY FAMILY_CODE ORDER BY V_DATE)), '9999-12-31'::DATE) AS V_END
  FROM fam_c x
),
cat_d AS (   -- category has source effective dates: latest arrival per code + start date
  SELECT * FROM SALES_{{ env }}.SILVER.PRODUCT_CATEGORY_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CATEGORY_CODE, EFFECTIVE_START_DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
cat AS (
  SELECT x.*,
    IFF(ROW_NUMBER() OVER (PARTITION BY CATEGORY_CODE ORDER BY EFFECTIVE_START_DATE) = 1,
        '1900-01-01'::DATE, EFFECTIVE_START_DATE) AS V_START,
    EFFECTIVE_END_DATE AS V_END
  FROM cat_d x
),
-- Change points per SKU version: its own start plus every start / end+1 of a
-- model, family or category version reachable from it, inside the SKU window.
points AS (
  SELECT SKU_CODE, V_START AS PT, V_START AS S_START, V_END AS S_END FROM sku
  UNION
  SELECT s.SKU_CODE, p.PT, s.V_START, s.V_END
  FROM sku s
  JOIN (SELECT MODEL_CODE, V_START AS PT FROM mdl
        UNION ALL SELECT MODEL_CODE, DATEADD(DAY, 1, V_END) FROM mdl WHERE V_END < '9999-12-31') p
    ON p.MODEL_CODE = s.MODEL_CODE AND p.PT > s.V_START AND p.PT <= s.V_END
  UNION
  SELECT s.SKU_CODE, p.PT, s.V_START, s.V_END
  FROM sku s
  JOIN mdl m ON m.MODEL_CODE = s.MODEL_CODE
  JOIN (SELECT FAMILY_CODE, V_START AS PT FROM fam
        UNION ALL SELECT FAMILY_CODE, DATEADD(DAY, 1, V_END) FROM fam WHERE V_END < '9999-12-31') p
    ON p.FAMILY_CODE = m.FAMILY_CODE AND p.PT > s.V_START AND p.PT <= s.V_END
  UNION
  SELECT s.SKU_CODE, p.PT, s.V_START, s.V_END
  FROM sku s
  JOIN mdl m ON m.MODEL_CODE = s.MODEL_CODE
  JOIN fam f ON f.FAMILY_CODE = m.FAMILY_CODE
  JOIN (SELECT CATEGORY_CODE, V_START AS PT FROM cat
        UNION ALL SELECT CATEGORY_CODE, DATEADD(DAY, 1, V_END) FROM cat WHERE V_END < '9999-12-31') p
    ON p.CATEGORY_CODE = f.CATEGORY_CODE AND p.PT > s.V_START AND p.PT <= s.V_END
),
segments AS (   -- [point, next point - 1] clipped to the SKU version window
  SELECT
    SKU_CODE, S_START,
    PT AS SEG_START,
    COALESCE(DATEADD(DAY, -1, LEAD(PT) OVER (PARTITION BY SKU_CODE, S_START ORDER BY PT)), S_END) AS SEG_END
  FROM points
),
-- Walk the hierarchy: pick the model, then family, then category version that is
-- valid at the segment start (equality join on the code + QUALIFY).
seg_m AS (
  SELECT
    g.SKU_CODE, g.SEG_START, g.SEG_END,
    s.VARIANT, s.PRICE_TIER, s.GLOBAL_LAUNCH_DATE AS SKU_GLOBAL_LAUNCH_DATE, s.IS_ACTIVE AS SKU_IS_ACTIVE,
    s.MODEL_CODE, s.DQ_STATUS AS SKU_DQ_STATUS,
    COALESCE(g.SEG_START BETWEEN m.V_START AND m.V_END, FALSE) AS M_OK,
    IFF(M_OK, m.MODEL_NAME, NULL)       AS MODEL_NAME,
    IFF(M_OK, m.LAUNCH_DATE, NULL)      AS MODEL_LAUNCH_DATE,
    IFF(M_OK, m.DISCONTINUE_DATE, NULL) AS MODEL_DISCONTINUE_DATE,
    IFF(M_OK, m.LIFECYCLE_STATUS, NULL) AS MODEL_LIFECYCLE_STATUS,
    IFF(M_OK, m.IS_ACTIVE, NULL)        AS MODEL_IS_ACTIVE,
    IFF(M_OK, m.FAMILY_CODE, NULL)      AS FAMILY_CODE
  FROM segments g
  JOIN sku s ON s.SKU_CODE = g.SKU_CODE AND s.V_START = g.S_START
  LEFT JOIN mdl m ON m.MODEL_CODE = s.MODEL_CODE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY g.SKU_CODE, g.SEG_START ORDER BY M_OK DESC) = 1
),
seg_f AS (
  SELECT
    sm.*,
    COALESCE(sm.SEG_START BETWEEN f.V_START AND f.V_END, FALSE) AS F_OK,
    IFF(F_OK, f.FAMILY_NAME, NULL)      AS FAMILY_NAME,
    IFF(F_OK, f.LAUNCH_YEAR, NULL)      AS FAMILY_LAUNCH_YEAR,
    IFF(F_OK, f.LIFECYCLE_STATUS, NULL) AS FAMILY_LIFECYCLE_STATUS,
    IFF(F_OK, f.IS_ACTIVE, NULL)        AS FAMILY_IS_ACTIVE,
    IFF(F_OK, f.CATEGORY_CODE, NULL)    AS CATEGORY_CODE
  FROM seg_m sm
  LEFT JOIN fam f ON f.FAMILY_CODE = sm.FAMILY_CODE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY sm.SKU_CODE, sm.SEG_START ORDER BY F_OK DESC) = 1
),
seg_c AS (
  SELECT
    sf.*,
    COALESCE(sf.SEG_START BETWEEN c.V_START AND c.V_END, FALSE) AS C_OK,
    IFF(C_OK, c.CATEGORY_NAME, NULL)     AS CATEGORY_NAME,
    IFF(C_OK, c.REPORTING_SEGMENT, NULL) AS REPORTING_SEGMENT,
    IFF(C_OK, c.IS_ACTIVE, NULL)         AS CATEGORY_IS_ACTIVE
  FROM seg_f sf
  LEFT JOIN cat c ON c.CATEGORY_CODE = sf.CATEGORY_CODE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY sf.SKU_CODE, sf.SEG_START ORDER BY C_OK DESC) = 1
),
hashed AS (
  SELECT
    sc.*,
    MD5(CONCAT_WS('|', SKU_CODE, COALESCE(VARIANT, ''), COALESCE(PRICE_TIER, ''),
                  COALESCE(SKU_GLOBAL_LAUNCH_DATE::VARCHAR, ''), COALESCE(SKU_IS_ACTIVE::VARCHAR, ''),
                  COALESCE(MODEL_CODE, ''), COALESCE(MODEL_NAME, ''), COALESCE(MODEL_LAUNCH_DATE::VARCHAR, ''),
                  COALESCE(MODEL_DISCONTINUE_DATE::VARCHAR, ''), COALESCE(MODEL_LIFECYCLE_STATUS, ''),
                  COALESCE(MODEL_IS_ACTIVE::VARCHAR, ''),
                  COALESCE(FAMILY_CODE, ''), COALESCE(FAMILY_NAME, ''), COALESCE(FAMILY_LAUNCH_YEAR::VARCHAR, ''),
                  COALESCE(FAMILY_LIFECYCLE_STATUS, ''), COALESCE(FAMILY_IS_ACTIVE::VARCHAR, ''),
                  COALESCE(CATEGORY_CODE, ''), COALESCE(CATEGORY_NAME, ''), COALESCE(REPORTING_SEGMENT, ''),
                  COALESCE(CATEGORY_IS_ACTIVE::VARCHAR, ''),
                  COALESCE(SKU_DQ_STATUS, '')))  AS RECORD_HASH
  FROM seg_c sc
),
merged AS (   -- merge consecutive segments whose attributes did not change
  SELECT * FROM hashed
  QUALIFY LAG(RECORD_HASH) OVER (PARTITION BY SKU_CODE ORDER BY SEG_START) IS DISTINCT FROM RECORD_HASH
),
final AS (
  SELECT
    mg.*,
    COALESCE(DATEADD(DAY, -1, LEAD(SEG_START) OVER (PARTITION BY SKU_CODE ORDER BY SEG_START)),
             '9999-12-31'::DATE) AS VERSION_END,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(SKU_DQ_STATUS <> 'PASS',                      'SILVER_SKU_DQ_WARN', NULL),
      IFF(MODEL_CODE    IS NOT NULL AND NOT M_OK,        'MODEL_NOT_FOUND_FOR_PERIOD', NULL),
      IFF(FAMILY_CODE   IS NULL OR NOT F_OK,             'FAMILY_NOT_FOUND_FOR_PERIOD', NULL),
      IFF(CATEGORY_CODE IS NULL OR NOT C_OK,             'CATEGORY_NOT_FOUND_FOR_PERIOD', NULL)
    )) AS ISSUES
  FROM merged mg
)
SELECT
  MD5(CONCAT_WS('|', SKU_CODE, SEG_START::VARCHAR))  AS PRODUCT_SK,
  SKU_CODE, VARIANT, PRICE_TIER, SKU_GLOBAL_LAUNCH_DATE, SKU_IS_ACTIVE,
  MODEL_CODE, MODEL_NAME, MODEL_LAUNCH_DATE, MODEL_DISCONTINUE_DATE, MODEL_LIFECYCLE_STATUS, MODEL_IS_ACTIVE,
  FAMILY_CODE, FAMILY_NAME, FAMILY_LAUNCH_YEAR, FAMILY_LIFECYCLE_STATUS, FAMILY_IS_ACTIVE,
  CATEGORY_CODE, CATEGORY_NAME, REPORTING_SEGMENT, CATEGORY_IS_ACTIVE,
  SEG_START                                          AS EFFECTIVE_START_DATE,
  VERSION_END                                        AS EFFECTIVE_END_DATE,
  VERSION_END = '9999-12-31'::DATE                   AS IS_CURRENT,
  RECORD_HASH,
  IFF(ARRAY_SIZE(ISSUES) = 0, 'PASS', 'WARN')        AS DQ_STATUS,
  ISSUES                                             AS DQ_ISSUES
FROM final;

-- Post-deploy check (must return 0 rows): one row per SK, one current version per SKU.
-- SELECT SKU_CODE, COUNT(*) AS VERSIONS, COUNT(DISTINCT PRODUCT_SK) AS SKS, COUNT_IF(IS_CURRENT) AS CURRENT_VERSIONS
-- FROM SALES_{{ env }}.GOLD.DIM_PRODUCT GROUP BY SKU_CODE
-- HAVING VERSIONS <> SKS OR CURRENT_VERSIONS <> 1;
