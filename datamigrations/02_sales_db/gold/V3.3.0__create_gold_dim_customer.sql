-- =============================================================================
-- V3.3.0 : Gold DIM_CUSTOMER dynamic table (Silver -> Gold), SCD Type 2
-- Source  : SILVER.CUSTOMER_MASTER (versioned: one row per real change, V2.9.x).
-- Grain   : one row per CUSTOMER_ID + EFFECTIVE_START_DATE.
-- Versions: UPDATED_AT (VERSION_START_TS).
--           The first version of each key starts 1900-01-01 so facts dated before
--           the first load (e.g. 2019 sales) still find a dimension row.
-- Key     : CUSTOMER_SK = MD5(CUSTOMER_ID | EFFECTIVE_START_DATE) - deterministic
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

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.DIM_CUSTOMER (  -- create only if missing
  CUSTOMER_SK                VARCHAR(32) NOT NULL COMMENT 'Surrogate key: MD5(CUSTOMER_ID|EFFECTIVE_START_DATE) (logical PK)',
  CUSTOMER_ID                VARCHAR     NOT NULL COMMENT 'Customer UUID (business key)',
  CUSTOMER_NUMBER                                 COMMENT 'Customer number',
  FIRST_NAME                                      COMMENT 'First name (PII)',
  LAST_NAME                                       COMMENT 'Last name (PII)',
  FULL_NAME                                       COMMENT 'Full name (PII)',
  GENDER                                          COMMENT 'Gender',
  DATE_OF_BIRTH                                   COMMENT 'Date of birth (PII)',
  EMAIL                                           COMMENT 'E-mail address, lower-case (PII)',
  EMAIL_DOMAIN                                    COMMENT 'Domain part of the e-mail address',
  PHONE_NUMBER                                    COMMENT 'Phone number (PII)',
  STREET_ADDRESS                                  COMMENT 'Street address (PII)',
  CITY                                            COMMENT 'City',
  STATE_PROVINCE                                  COMMENT 'State or province',
  POSTAL_CODE                                     COMMENT 'Postal code (text, keeps leading zeros)',
  COUNTRY_CODE                                    COMMENT 'ISO 2-letter country code (joins GOLD.DIM_COUNTRY)',
  COUNTRY_NAME                                    COMMENT 'Country name',
  REGION_CODE                                     COMMENT 'Sales region code',
  PREFERRED_LANGUAGE                              COMMENT 'Preferred language',
  CUSTOMER_SEGMENT                                COMMENT 'Segment (Consumer, Business, Education)',
  LOYALTY_TIER                                    COMMENT 'Loyalty tier (None, Silver, Gold, Platinum)',
  REGISTRATION_DATE                               COMMENT 'Date the customer registered',
  ACQUISITION_YEAR                                COMMENT 'Year the customer was acquired',
  CUSTOMER_TYPE                                   COMMENT 'Customer type (e.g. NEW)',
  IS_ACTIVE                                       COMMENT 'Record is active in source',
  SOURCE_SYSTEM                                   COMMENT 'Source system of the record',
  EFFECTIVE_START_DATE       DATE        NOT NULL COMMENT 'SCD2 version valid from (inclusive; first version = 1900-01-01)',
  EFFECTIVE_END_DATE         DATE        NOT NULL COMMENT 'SCD2 version valid to (inclusive, 9999-12-31 = open)',
  IS_CURRENT                 BOOLEAN     NOT NULL COMMENT 'TRUE for the open (current) version',
  SOURCE_VERSION_TS                               COMMENT 'Source time the version was first seen (UPDATED_AT)',
  RECORD_HASH                VARCHAR(32) NOT NULL COMMENT 'MD5 of Type-2 attributes for change detection',
  DQ_STATUS                  VARCHAR(4)  NOT NULL COMMENT 'PASS or WARN, carried from the Silver record checks',
  DQ_ISSUES                                       COMMENT 'Failed Silver quality checks (empty when PASS)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Silver rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Customer dimension (SCD2), hash surrogate key CUSTOMER_SK'
AS
WITH daily AS (   -- one version per key per day: latest arrival that day
  SELECT *, VERSION_START_TS::DATE AS VERSION_DATE
  FROM SALES_{{ env }}.SILVER.CUSTOMER_MASTER
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID, VERSION_START_TS::DATE
    ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1
),
changes AS (   -- drop a day whose attributes equal the previous version
  SELECT * FROM daily
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY CUSTOMER_ID ORDER BY VERSION_DATE) IS DISTINCT FROM ATTR_HASH
),
versions AS (   -- validity = version day until the day before the next one; first back-dated
  SELECT
    c.*,
    IFF(ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY VERSION_DATE) = 1,
        '1900-01-01'::DATE, VERSION_DATE)                         AS EFF_START,
    COALESCE(DATEADD(DAY, -1, LEAD(VERSION_DATE) OVER (PARTITION BY CUSTOMER_ID ORDER BY VERSION_DATE)),
             '9999-12-31'::DATE)                                  AS EFF_END
  FROM changes c
)
SELECT
  MD5(CONCAT_WS('|', CUSTOMER_ID, EFF_START::VARCHAR))  AS CUSTOMER_SK,
  CUSTOMER_ID,
  CUSTOMER_NUMBER,
  FIRST_NAME,
  LAST_NAME,
  FULL_NAME,
  GENDER,
  DATE_OF_BIRTH,
  EMAIL,
  EMAIL_DOMAIN,
  PHONE_NUMBER,
  STREET_ADDRESS,
  CITY,
  STATE_PROVINCE,
  POSTAL_CODE,
  COUNTRY_CODE,
  COUNTRY_NAME,
  REGION_CODE,
  PREFERRED_LANGUAGE,
  CUSTOMER_SEGMENT,
  LOYALTY_TIER,
  REGISTRATION_DATE,
  ACQUISITION_YEAR,
  CUSTOMER_TYPE,
  IS_ACTIVE,
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
-- SELECT CUSTOMER_ID, COUNT(*) AS VERSIONS, COUNT(DISTINCT CUSTOMER_SK) AS SKS, COUNT_IF(IS_CURRENT) AS CURRENT_VERSIONS
-- FROM SALES_{{ env }}.GOLD.DIM_CUSTOMER GROUP BY CUSTOMER_ID
-- HAVING VERSIONS <> SKS OR CURRENT_VERSIONS <> 1;
