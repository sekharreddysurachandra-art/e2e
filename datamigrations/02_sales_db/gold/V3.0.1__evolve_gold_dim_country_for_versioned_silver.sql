-- =============================================================================
-- V3.0.1 : Gold DIM_COUNTRY reads the versioned Silver masters (follows V2.9.x)
-- Why     : Silver now keeps every changed version, so one COUNTRY/REGION/
--           CURRENCY/TAX code + EFFECTIVE_START_DATE can have several rows when
--           the source re-sent a version with different attributes. The dimension
--           takes the latest arrival (VERSION_START_TS, file, row) per code +
--           start date. A country overwrite flagged in Silver
--           (SAME_START_DIFFERENT_ATTRIBUTES) shows as SILVER_COUNTRY_DQ_WARN.
-- Grain, key, SCD2 rules and refresh settings are unchanged from V3.0.0:
--           one row per COUNTRY_CODE + EFFECTIVE_START_DATE,
--           COUNTRY_SK = MD5(COUNTRY_CODE|EFFECTIVE_START_DATE), INCREMENTAL,
--           TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the table in place.
-- Keys    : dynamic tables do not allow PRIMARY KEY / UNIQUE constraints; NOT NULL
--           is enforced and uniqueness is asserted by the check at the end.
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.GOLD.DIM_COUNTRY (  -- create or evolve in place
  COUNTRY_SK             VARCHAR(32)  NOT NULL COMMENT 'Surrogate key: MD5(COUNTRY_CODE|EFFECTIVE_START_DATE) (logical PK)',
  COUNTRY_CODE           VARCHAR      NOT NULL COMMENT 'ISO 2-letter country code (business key)',
  COUNTRY_NAME           VARCHAR               COMMENT 'Country name',
  ISO_ALPHA3             VARCHAR               COMMENT 'ISO 3-letter country code',
  APPLE_FISCAL_SEGMENT   VARCHAR               COMMENT 'Fiscal reporting segment',
  PRIMARY_LANGUAGE       VARCHAR               COMMENT 'Primary language',
  TIMEZONE               VARCHAR               COMMENT 'Primary timezone',
  ECOMMERCE_SUPPORTED    BOOLEAN               COMMENT 'Online store available',
  RETAIL_STORE_SUPPORTED BOOLEAN               COMMENT 'Retail stores available',
  MARKET_TIER            VARCHAR               COMMENT 'Market priority tier',
  POPULATION_MILLIONS    NUMBER(10,2)          COMMENT 'Population in millions',
  GDP_USD_BILLIONS       NUMBER(12,2)          COMMENT 'GDP in USD billions',
  GDPR_APPLICABLE        BOOLEAN               COMMENT 'GDPR applies',
  COUNTRY_IS_ACTIVE      BOOLEAN               COMMENT 'Country is active in source',
  REGION_CODE            VARCHAR               COMMENT 'Sales region code',
  REGION_NAME            VARCHAR               COMMENT 'Sales region name',
  REGION_IS_ACTIVE       BOOLEAN               COMMENT 'Region is active in source',
  CURRENCY_CODE          VARCHAR               COMMENT 'Local ISO currency code',
  CURRENCY_NAME          VARCHAR               COMMENT 'Currency name',
  CURRENCY_SYMBOL        VARCHAR               COMMENT 'Currency symbol',
  CURRENCY_MINOR_UNIT    NUMBER(2,0)           COMMENT 'Number of decimal places of the currency',
  CURRENCY_IS_ACTIVE     BOOLEAN               COMMENT 'Currency is active in source',
  TAX_CODE               VARCHAR               COMMENT 'Applicable tax code',
  TAX_TYPE               VARCHAR               COMMENT 'Tax type (e.g. VAT, GST, sales tax)',
  TAX_RATE               NUMBER(6,4)           COMMENT 'Tax rate as a fraction (0.20 = 20%)',
  TAX_RATE_PCT           NUMBER(9,4)           COMMENT 'Tax rate as a percentage',
  TAX_INCLUSIVE_FLAG     BOOLEAN               COMMENT 'Prices include tax',
  TAX_IS_ACTIVE          BOOLEAN               COMMENT 'Tax record is active in source',
  EFFECTIVE_START_DATE   DATE         NOT NULL COMMENT 'SCD2 version valid from (inclusive)',
  EFFECTIVE_END_DATE     DATE         NOT NULL COMMENT 'SCD2 version valid to (inclusive, 9999-12-31 = open)',
  IS_CURRENT             BOOLEAN      NOT NULL COMMENT 'TRUE for the open (current) version of the country',
  RECORD_HASH            VARCHAR(32)  NOT NULL COMMENT 'MD5 of Type-2 attributes for change detection',
  DQ_STATUS              VARCHAR(4)   NOT NULL COMMENT 'PASS or WARN from dimension-level quality checks',
  DQ_ISSUES              ARRAY                 COMMENT 'List of failed quality checks (empty when PASS)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Silver rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Country dimension (SCD2): country + region + currency + tax, hash surrogate key COUNTRY_SK'
AS
-- One row per code + EFFECTIVE_START_DATE from each versioned Silver master
-- (latest arrival wins when the source re-sent a version with new attributes).
WITH c AS (   -- country versions (driver)
  SELECT * FROM SALES_{{ env }}.SILVER.COUNTRY_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY COUNTRY_CODE, EFFECTIVE_START_DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
rm AS (
  SELECT * FROM SALES_{{ env }}.SILVER.REGION_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY REGION_CODE, EFFECTIVE_START_DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
cm AS (
  SELECT * FROM SALES_{{ env }}.SILVER.CURRENCY_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CURRENCY_CODE, EFFECTIVE_START_DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
tm AS (
  SELECT * FROM SALES_{{ env }}.SILVER.TAX_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TAX_CODE, EFFECTIVE_START_DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
-- Change points per country: its own start plus every start / end+1 of a linked
-- region, currency or tax version that falls inside the country version window.
points AS (
  SELECT COUNTRY_CODE, EFFECTIVE_START_DATE AS PT, EFFECTIVE_START_DATE AS C_START, EFFECTIVE_END_DATE AS C_END
  FROM c
  UNION
  SELECT c.COUNTRY_CODE, p.PT, c.EFFECTIVE_START_DATE, c.EFFECTIVE_END_DATE
  FROM c
  JOIN (
    SELECT 'R' AS SRC, REGION_CODE AS CODE, EFFECTIVE_START_DATE AS PT FROM rm
    UNION ALL SELECT 'R', REGION_CODE, DATEADD(DAY, 1, EFFECTIVE_END_DATE) FROM rm WHERE EFFECTIVE_END_DATE < '9999-12-31'
    UNION ALL SELECT 'C', CURRENCY_CODE, EFFECTIVE_START_DATE FROM cm
    UNION ALL SELECT 'C', CURRENCY_CODE, DATEADD(DAY, 1, EFFECTIVE_END_DATE) FROM cm WHERE EFFECTIVE_END_DATE < '9999-12-31'
    UNION ALL SELECT 'T', TAX_CODE, EFFECTIVE_START_DATE FROM tm
    UNION ALL SELECT 'T', TAX_CODE, DATEADD(DAY, 1, EFFECTIVE_END_DATE) FROM tm WHERE EFFECTIVE_END_DATE < '9999-12-31'
  ) p
    ON p.CODE = CASE p.SRC WHEN 'R' THEN c.REGION_CODE WHEN 'C' THEN c.CURRENCY_CODE ELSE c.TAX_CODE END
   AND p.PT >  c.EFFECTIVE_START_DATE
   AND p.PT <= c.EFFECTIVE_END_DATE
),
segments AS (   -- [start, next point - 1] clipped to the country version window
  SELECT
    COUNTRY_CODE,
    PT AS EFFECTIVE_START_DATE,
    COALESCE(DATEADD(DAY, -1, LEAD(PT) OVER (PARTITION BY COUNTRY_CODE, C_START ORDER BY PT)), C_END) AS EFFECTIVE_END_DATE,
    C_START
  FROM points
),
-- Lookups use equality joins only (incremental refresh does not allow outer
-- joins with range predicates); the version valid at the segment start is
-- picked with QUALIFY. Versions of one code never overlap, so the top row
-- holds the matching region, currency and tax version at the same time.
joined AS (
  SELECT
    s.COUNTRY_CODE, s.EFFECTIVE_START_DATE, s.EFFECTIVE_END_DATE,
    COALESCE(s.EFFECTIVE_START_DATE BETWEEN r.EFFECTIVE_START_DATE  AND r.EFFECTIVE_END_DATE,  FALSE) AS R_OK,
    COALESCE(s.EFFECTIVE_START_DATE BETWEEN cu.EFFECTIVE_START_DATE AND cu.EFFECTIVE_END_DATE, FALSE) AS CU_OK,
    COALESCE(s.EFFECTIVE_START_DATE BETWEEN t.EFFECTIVE_START_DATE  AND t.EFFECTIVE_END_DATE,  FALSE) AS T_OK,
    c.COUNTRY_NAME, c.ISO_ALPHA3, c.APPLE_FISCAL_SEGMENT, c.PRIMARY_LANGUAGE, c.TIMEZONE,
    c.ECOMMERCE_SUPPORTED, c.RETAIL_STORE_SUPPORTED, c.MARKET_TIER, c.POPULATION_MILLIONS,
    c.GDP_USD_BILLIONS, c.GDPR_APPLICABLE, c.IS_ACTIVE AS COUNTRY_IS_ACTIVE,
    c.REGION_CODE,
    IFF(R_OK,  r.REGION_NAME,      NULL)  AS REGION_NAME,
    IFF(R_OK,  r.IS_ACTIVE,        NULL)  AS REGION_IS_ACTIVE,
    c.CURRENCY_CODE,
    IFF(CU_OK, cu.CURRENCY_NAME,   NULL)  AS CURRENCY_NAME,
    IFF(CU_OK, cu.CURRENCY_SYMBOL, NULL)  AS CURRENCY_SYMBOL,
    IFF(CU_OK, cu.MINOR_UNIT,      NULL)  AS CURRENCY_MINOR_UNIT,
    IFF(CU_OK, cu.IS_ACTIVE,       NULL)  AS CURRENCY_IS_ACTIVE,
    c.TAX_CODE,
    IFF(T_OK,  t.TAX_TYPE,           NULL) AS TAX_TYPE,
    IFF(T_OK,  t.TAX_RATE,           NULL) AS TAX_RATE,
    IFF(T_OK,  t.TAX_RATE_PCT,       NULL) AS TAX_RATE_PCT,
    IFF(T_OK,  t.TAX_INCLUSIVE_FLAG, NULL) AS TAX_INCLUSIVE_FLAG,
    IFF(T_OK,  t.IS_ACTIVE,          NULL) AS TAX_IS_ACTIVE,
    c.DQ_STATUS AS COUNTRY_DQ_STATUS
  FROM segments s
  JOIN c
    ON c.COUNTRY_CODE = s.COUNTRY_CODE AND c.EFFECTIVE_START_DATE = s.C_START
  LEFT JOIN rm r  ON r.REGION_CODE    = c.REGION_CODE
  LEFT JOIN cm cu ON cu.CURRENCY_CODE = c.CURRENCY_CODE
  LEFT JOIN tm t  ON t.TAX_CODE       = c.TAX_CODE
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY s.COUNTRY_CODE, s.EFFECTIVE_START_DATE
    ORDER BY R_OK DESC, CU_OK DESC, T_OK DESC
  ) = 1
)
SELECT
  MD5(CONCAT_WS('|', COUNTRY_CODE, EFFECTIVE_START_DATE::VARCHAR))     AS COUNTRY_SK,
  COUNTRY_CODE, COUNTRY_NAME, ISO_ALPHA3, APPLE_FISCAL_SEGMENT, PRIMARY_LANGUAGE, TIMEZONE,
  ECOMMERCE_SUPPORTED, RETAIL_STORE_SUPPORTED, MARKET_TIER, POPULATION_MILLIONS,
  GDP_USD_BILLIONS, GDPR_APPLICABLE, COUNTRY_IS_ACTIVE,
  REGION_CODE, REGION_NAME, REGION_IS_ACTIVE,
  CURRENCY_CODE, CURRENCY_NAME, CURRENCY_SYMBOL, CURRENCY_MINOR_UNIT, CURRENCY_IS_ACTIVE,
  TAX_CODE, TAX_TYPE, TAX_RATE, TAX_RATE_PCT, TAX_INCLUSIVE_FLAG, TAX_IS_ACTIVE,
  EFFECTIVE_START_DATE,
  EFFECTIVE_END_DATE,
  EFFECTIVE_END_DATE = '9999-12-31'::DATE                              AS IS_CURRENT,
  MD5(CONCAT_WS('|', COUNTRY_CODE, COALESCE(COUNTRY_NAME, ''), COALESCE(ISO_ALPHA3, ''),
                COALESCE(APPLE_FISCAL_SEGMENT, ''), COALESCE(PRIMARY_LANGUAGE, ''),
                COALESCE(TIMEZONE, ''), COALESCE(ECOMMERCE_SUPPORTED::VARCHAR, ''),
                COALESCE(RETAIL_STORE_SUPPORTED::VARCHAR, ''), COALESCE(MARKET_TIER, ''),
                COALESCE(POPULATION_MILLIONS::VARCHAR, ''), COALESCE(GDP_USD_BILLIONS::VARCHAR, ''),
                COALESCE(GDPR_APPLICABLE::VARCHAR, ''), COALESCE(COUNTRY_IS_ACTIVE::VARCHAR, ''),
                COALESCE(REGION_CODE, ''), COALESCE(REGION_NAME, ''), COALESCE(REGION_IS_ACTIVE::VARCHAR, ''),
                COALESCE(CURRENCY_CODE, ''), COALESCE(CURRENCY_NAME, ''), COALESCE(CURRENCY_SYMBOL, ''),
                COALESCE(CURRENCY_MINOR_UNIT::VARCHAR, ''), COALESCE(CURRENCY_IS_ACTIVE::VARCHAR, ''),
                COALESCE(TAX_CODE, ''), COALESCE(TAX_TYPE, ''), COALESCE(TAX_RATE::VARCHAR, ''),
                COALESCE(TAX_INCLUSIVE_FLAG::VARCHAR, ''), COALESCE(TAX_IS_ACTIVE::VARCHAR, '')))  AS RECORD_HASH,
  IFF(ARRAY_SIZE(DQ_ISSUES) = 0, 'PASS', 'WARN')                       AS DQ_STATUS,
  DQ_ISSUES
FROM (
  SELECT
    j.*,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(COUNTRY_DQ_STATUS <> 'PASS',                   'SILVER_COUNTRY_DQ_WARN', NULL),
      IFF(REGION_CODE   IS NOT NULL AND NOT R_OK,   'REGION_NOT_FOUND_FOR_PERIOD', NULL),
      IFF(CURRENCY_CODE IS NOT NULL AND NOT CU_OK, 'CURRENCY_NOT_FOUND_FOR_PERIOD', NULL),
      IFF(TAX_CODE      IS NOT NULL AND NOT T_OK,      'TAX_NOT_FOUND_FOR_PERIOD', NULL)
    )) AS DQ_ISSUES
  FROM joined j
);

-- Post-deploy check (must return 0 rows): hash key and version key are unique,
-- and each country has exactly one current version.
-- SELECT COUNTRY_CODE, COUNT(*) AS VERSIONS, COUNT(DISTINCT COUNTRY_SK) AS SKS,
--        COUNT_IF(IS_CURRENT) AS CURRENT_VERSIONS
-- FROM SALES_{{ env }}.GOLD.DIM_COUNTRY GROUP BY COUNTRY_CODE
-- HAVING VERSIONS <> SKS OR CURRENT_VERSIONS <> 1;
