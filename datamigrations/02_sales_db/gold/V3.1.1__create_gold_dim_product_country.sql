-- =============================================================================
-- V3.1.1 : Gold DIM_PRODUCT_COUNTRY dynamic table (Silver -> Gold), SCD Type 2
-- Source  : SILVER.PRODUCT_COUNTRY_AVAILABILITY (versioned: one row per real change, V2.9.x).
-- Grain   : one row per SKU_CODE + COUNTRY_CODE + EFFECTIVE_START_DATE.
-- Versions: file arrival (VERSION_START_TS) - the source has no effective dates.
--           The first version of each key starts 1900-01-01 so facts dated before
--           the first load (e.g. 2019 sales) still find a dimension row.
-- Key     : PRODUCT_COUNTRY_SK = MD5(SKU_CODE | COUNTRY_CODE | EFFECTIVE_START_DATE) - deterministic
--           hash surrogate key, same in DEV/QA/PROD.
-- SCD2    : inclusive end dates (9999-12-31 = open), IS_CURRENT, RECORD_HASH =
--           Silver ATTR_HASH (all business attributes are Type 2).
-- Keys    : NOT NULL enforced on key/SCD columns; dynamic tables do not allow
--           PRIMARY KEY / UNIQUE, so uniqueness is asserted by the check below.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold facts).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.DIM_PRODUCT_COUNTRY (  -- create only if missing
  PRODUCT_COUNTRY_SK         VARCHAR(32) NOT NULL COMMENT 'Surrogate key: MD5(SKU_CODE|COUNTRY_CODE|EFFECTIVE_START_DATE) (logical PK)',
  SKU_CODE                   VARCHAR     NOT NULL COMMENT 'SKU code (joins GOLD.DIM_PRODUCT)',
  COUNTRY_CODE               VARCHAR     NOT NULL COMMENT 'ISO 2-letter country code (joins GOLD.DIM_COUNTRY)',
  LOCAL_PART_NUMBER                               COMMENT 'Country-specific part number',
  LOCAL_LAUNCH_DATE                               COMMENT 'Launch date in the country',
  LOCAL_DISCONTINUE_DATE                          COMMENT 'Discontinue date in the country (NULL = still sold)',
  IS_AVAILABLE                                    COMMENT 'SKU is available in the country',
  SOURCE_SYSTEM                                   COMMENT 'Source system of the record',
  EFFECTIVE_START_DATE       DATE        NOT NULL COMMENT 'SCD2 version valid from (inclusive; first version = 1900-01-01)',
  EFFECTIVE_END_DATE         DATE        NOT NULL COMMENT 'SCD2 version valid to (inclusive, 9999-12-31 = open)',
  IS_CURRENT                 BOOLEAN     NOT NULL COMMENT 'TRUE for the open (current) version',
  SOURCE_VERSION_TS                               COMMENT 'Source time the version was first seen (file arrival)',
  RECORD_HASH                VARCHAR(32) NOT NULL COMMENT 'MD5 of Type-2 attributes for change detection',
  DQ_STATUS                  VARCHAR(4)  NOT NULL COMMENT 'PASS or WARN, carried from the Silver record checks',
  DQ_ISSUES                                       COMMENT 'Failed Silver quality checks (empty when PASS)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Silver rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Product availability per country dimension (SCD2), hash surrogate key PRODUCT_COUNTRY_SK'
AS
WITH daily AS (   -- one version per key per day: latest arrival that day
  SELECT *, VERSION_START_TS::DATE AS VERSION_DATE
  FROM SALES_{{ env }}.SILVER.PRODUCT_COUNTRY_AVAILABILITY
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SKU_CODE, COUNTRY_CODE, VERSION_START_TS::DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
changes AS (   -- drop a day whose attributes equal the previous version
  SELECT * FROM daily
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY SKU_CODE, COUNTRY_CODE ORDER BY VERSION_DATE) IS DISTINCT FROM ATTR_HASH
),
versions AS (   -- validity = version day until the day before the next one; first back-dated
  SELECT
    c.*,
    IFF(ROW_NUMBER() OVER (PARTITION BY SKU_CODE, COUNTRY_CODE ORDER BY VERSION_DATE) = 1,
        '1900-01-01'::DATE, VERSION_DATE)                         AS EFF_START,
    COALESCE(DATEADD(DAY, -1, LEAD(VERSION_DATE) OVER (PARTITION BY SKU_CODE, COUNTRY_CODE ORDER BY VERSION_DATE)),
             '9999-12-31'::DATE)                                  AS EFF_END
  FROM changes c
)
SELECT
  MD5(CONCAT_WS('|', SKU_CODE, COUNTRY_CODE, EFF_START::VARCHAR))  AS PRODUCT_COUNTRY_SK,
  SKU_CODE, COUNTRY_CODE,
  LOCAL_PART_NUMBER,
  LOCAL_LAUNCH_DATE,
  LOCAL_DISCONTINUE_DATE,
  IS_AVAILABLE,
  SOURCE_SYSTEM,
  EFF_START                                      AS EFFECTIVE_START_DATE,
  EFF_END                                        AS EFFECTIVE_END_DATE,
  EFF_END = '9999-12-31'::DATE                   AS IS_CURRENT,
  VERSION_START_TS  AS SOURCE_VERSION_TS,
  ATTR_HASH                                      AS RECORD_HASH,
  DQ_STATUS,
  DQ_ISSUES
FROM versions;

-- Post-deploy check (must return 0 rows): one row per SK, one current version per key.
-- SELECT SKU_CODE, COUNTRY_CODE, COUNT(*) AS VERSIONS, COUNT(DISTINCT PRODUCT_COUNTRY_SK) AS SKS, COUNT_IF(IS_CURRENT) AS CURRENT_VERSIONS
-- FROM SALES_{{ env }}.GOLD.DIM_PRODUCT_COUNTRY GROUP BY SKU_CODE, COUNTRY_CODE
-- HAVING VERSIONS <> SKS OR CURRENT_VERSIONS <> 1;
