-- =============================================================================
-- V3.2.0 : Gold DIM_STORE dynamic table (Silver -> Gold), SCD Type 2
-- Source  : SILVER.STORE_MASTER (versioned: one row per real change, V2.9.x).
-- Grain   : one row per STORE_CODE + EFFECTIVE_START_DATE.
-- Versions: source EFFECTIVE_START_DATE / EFFECTIVE_END_DATE.
--           The first version of each key starts 1900-01-01 so facts dated before
--           the first load (e.g. 2019 sales) still find a dimension row.
-- Key     : STORE_SK = MD5(STORE_CODE | EFFECTIVE_START_DATE) - deterministic
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

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.DIM_STORE (  -- create only if missing
  STORE_SK                   VARCHAR(32) NOT NULL COMMENT 'Surrogate key: MD5(STORE_CODE|EFFECTIVE_START_DATE) (logical PK)',
  STORE_CODE                 VARCHAR     NOT NULL COMMENT 'Store code (business key)',
  STORE_NAME                                      COMMENT 'Store name',
  COUNTRY_CODE                                    COMMENT 'ISO 2-letter country code (joins GOLD.DIM_COUNTRY)',
  REGION_CODE                                     COMMENT 'Sales region code',
  TAX_JURISDICTION_CODE                           COMMENT 'Tax jurisdiction code',
  FORMAT_CODE                                     COMMENT 'Store format (FLG = flagship, MALL, MINI)',
  CITY                                            COMMENT 'City',
  STATE_CODE                                      COMMENT 'State code',
  POSTAL_CODE                                     COMMENT 'Postal code',
  ADDRESS_LINE1                                   COMMENT 'Street address',
  LATITUDE                                        COMMENT 'Latitude (decimal degrees)',
  LONGITUDE                                       COMMENT 'Longitude (decimal degrees)',
  STORE_OPEN_DATE                                 COMMENT 'Store opening date',
  STORE_CLOSE_DATE                                COMMENT 'Store closing date (NULL = open)',
  IS_OPEN                                         COMMENT 'TRUE when the store has no close date',
  LIFECYCLE_STATUS                                COMMENT 'Lifecycle status (e.g. ACTIVE)',
  FLOOR_AREA_SQFT                                 COMMENT 'Floor area in square feet',
  ANNUAL_RENT_USD                                 COMMENT 'Annual rent in USD',
  IS_ACTIVE                                       COMMENT 'Record is active in source',
  SOURCE_SYSTEM                                   COMMENT 'Source system of the record',
  EFFECTIVE_START_DATE       DATE        NOT NULL COMMENT 'SCD2 version valid from (inclusive; first version = 1900-01-01)',
  EFFECTIVE_END_DATE         DATE        NOT NULL COMMENT 'SCD2 version valid to (inclusive, 9999-12-31 = open)',
  IS_CURRENT                 BOOLEAN     NOT NULL COMMENT 'TRUE for the open (current) version',
  SOURCE_EFFECTIVE_START_DATE                     COMMENT 'Start date sent by the source (before back-dating the first version)',
  RECORD_HASH                VARCHAR(32) NOT NULL COMMENT 'MD5 of Type-2 attributes for change detection',
  DQ_STATUS                  VARCHAR(4)  NOT NULL COMMENT 'PASS or WARN, carried from the Silver record checks',
  DQ_ISSUES                                       COMMENT 'Failed Silver quality checks (empty when PASS)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Silver rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Store dimension (SCD2), hash surrogate key STORE_SK'
AS
WITH dedup AS (   -- one row per source version: latest arrival per key + start date
  SELECT * FROM SALES_{{ env }}.SILVER.STORE_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY STORE_CODE, EFFECTIVE_START_DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
versions AS (   -- first version back-dated so early facts find a match
  SELECT
    d.*,
    IFF(ROW_NUMBER() OVER (PARTITION BY STORE_CODE ORDER BY EFFECTIVE_START_DATE) = 1,
        '1900-01-01'::DATE, EFFECTIVE_START_DATE)                 AS EFF_START,
    EFFECTIVE_END_DATE                                            AS EFF_END
  FROM dedup d
)
SELECT
  MD5(CONCAT_WS('|', STORE_CODE, EFF_START::VARCHAR))  AS STORE_SK,
  STORE_CODE,
  STORE_NAME,
  COUNTRY_CODE,
  REGION_CODE,
  TAX_JURISDICTION_CODE,
  FORMAT_CODE,
  CITY,
  STATE_CODE,
  POSTAL_CODE,
  ADDRESS_LINE1,
  LATITUDE,
  LONGITUDE,
  STORE_OPEN_DATE,
  STORE_CLOSE_DATE,
  IS_OPEN,
  LIFECYCLE_STATUS,
  FLOOR_AREA_SQFT,
  ANNUAL_RENT_USD,
  IS_ACTIVE,
  SOURCE_SYSTEM,
  EFF_START                                      AS EFFECTIVE_START_DATE,
  EFF_END                                        AS EFFECTIVE_END_DATE,
  EFF_END = '9999-12-31'::DATE                   AS IS_CURRENT,
  EFFECTIVE_START_DATE  AS SOURCE_EFFECTIVE_START_DATE,
  ATTR_HASH                                      AS RECORD_HASH,
  DQ_STATUS,
  DQ_ISSUES
FROM versions;

-- Post-deploy check (must return 0 rows): one row per SK, one current version per key.
-- SELECT STORE_CODE, COUNT(*) AS VERSIONS, COUNT(DISTINCT STORE_SK) AS SKS, COUNT_IF(IS_CURRENT) AS CURRENT_VERSIONS
-- FROM SALES_{{ env }}.GOLD.DIM_STORE GROUP BY STORE_CODE
-- HAVING VERSIONS <> SKS OR CURRENT_VERSIONS <> 1;
