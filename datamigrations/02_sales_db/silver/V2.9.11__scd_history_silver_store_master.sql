-- =============================================================================
-- V2.9.11 : Silver STORE_MASTER keeps change history (replaces dedup of V2.7.0)
-- Why     : the previous version kept only the latest row per business key, so a
--           changed record was treated as a duplicate and the old version was
--           lost. Gold SCD2 dimensions need every version.
-- Dedup   : only exact re-sends are dropped - a row is removed when its ATTR_HASH
--           (business attributes, no effective dates or load metadata) equals the
--           next row for the same STORE_CODE + EFFECTIVE_START_DATE (the latest copy is kept, so a version closed by a new EFFECTIVE_END_DATE keeps the new end date).
--           Changes back to an earlier value (A -> B -> A) are kept.
-- Version : EFFECTIVE_START_DATE from source; VERSION_START_TS (file arrival) orders versions sharing a start date, flagged SAME_START_DIFFERENT_ATTRIBUTES.
-- Grain   : one row per STORE_CODE version; SILVER_SK = MD5 of key + version + source row.
--           IS_LATEST flags the newest version of each STORE_CODE.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           existing dynamic table in place (one reinitialisation).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.STORE_MASTER (  -- create or evolve in place
  STORE_CODE               COMMENT 'Store code (business key, upper-case)',
  STORE_NAME               COMMENT 'Store name',
  COUNTRY_CODE             COMMENT 'ISO 2-letter country code (FK to SILVER.COUNTRY_MASTER)',
  REGION_CODE              COMMENT 'Sales region code (FK to SILVER.REGION_MASTER)',
  TAX_JURISDICTION_CODE    COMMENT 'Tax jurisdiction code',
  FORMAT_CODE              COMMENT 'Store format (FLG = flagship, MALL, MINI)',
  CITY                     COMMENT 'City',
  STATE_CODE               COMMENT 'State code',
  POSTAL_CODE              COMMENT 'Postal code',
  ADDRESS_LINE1            COMMENT 'Street address',
  LATITUDE                 COMMENT 'Latitude (decimal degrees)',
  LONGITUDE                COMMENT 'Longitude (decimal degrees)',
  STORE_OPEN_DATE          COMMENT 'Store opening date',
  STORE_CLOSE_DATE         COMMENT 'Store closing date (NULL = open)',
  LIFECYCLE_STATUS         COMMENT 'Lifecycle status (e.g. ACTIVE)',
  FLOOR_AREA_SQFT          COMMENT 'Floor area in square feet',
  ANNUAL_RENT_USD          COMMENT 'Annual rent in USD',
  IS_ACTIVE                COMMENT 'Store is active',
  EFFECTIVE_START_DATE     COMMENT 'Record valid from',
  EFFECTIVE_END_DATE       COMMENT 'Record valid to (9999-12-31 = current)',
  CREATED_AT               COMMENT 'Created timestamp in source',
  SOURCE_SYSTEM            COMMENT 'Source system of the record',
  IS_CURRENT               COMMENT 'TRUE when EFFECTIVE_END_DATE = 9999-12-31',
  IS_OPEN                  COMMENT 'TRUE when the store has no close date',
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
  COMMENT      = 'Cleaned, versioned (change history) store master'
AS
WITH cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(STORE_CODE), ''))             AS STORE_CODE,
    NULLIF(TRIM(STORE_NAME), '')                    AS STORE_NAME,
    UPPER(NULLIF(TRIM(COUNTRY_CODE), ''))           AS COUNTRY_CODE,
    UPPER(NULLIF(TRIM(REGION_CODE), ''))            AS REGION_CODE,
    UPPER(NULLIF(TRIM(TAX_JURISDICTION_CODE), ''))  AS TAX_JURISDICTION_CODE,
    UPPER(NULLIF(TRIM(FORMAT_CODE), ''))            AS FORMAT_CODE,
    NULLIF(TRIM(CITY), '')                          AS CITY,
    UPPER(NULLIF(TRIM(STATE_CODE), ''))             AS STATE_CODE,
    UPPER(NULLIF(TRIM(POSTAL_CODE), ''))            AS POSTAL_CODE,
    NULLIF(TRIM(ADDRESS_LINE1), '')                 AS ADDRESS_LINE1,
    LATITUDE,
    LONGITUDE,
    STORE_OPEN_DATE,
    TRY_TO_DATE(NULLIF(TRIM(STORE_CLOSE_DATE), '')) AS STORE_CLOSE_DATE,
    UPPER(NULLIF(TRIM(LIFECYCLE_STATUS), ''))       AS LIFECYCLE_STATUS,
    FLOOR_AREA_SQFT,
    ANNUAL_RENT_USD,
    IS_ACTIVE,
    EFFECTIVE_START_DATE,
    EFFECTIVE_END_DATE,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))          AS SOURCE_SYSTEM,
    NULLIF(TRIM(STORE_CLOSE_DATE), '')              AS STORE_CLOSE_DATE_RAW,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.STORE_MASTER
  WHERE NULLIF(TRIM(STORE_CODE), '') IS NOT NULL
    AND EFFECTIVE_START_DATE IS NOT NULL   -- no business key, no row
),
src AS (   -- cleaned rows with record-level DQ (unchanged logic)
SELECT
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
  LIFECYCLE_STATUS,
  FLOOR_AREA_SQFT,
  ANNUAL_RENT_USD,
  IS_ACTIVE,
  EFFECTIVE_START_DATE,
  EFFECTIVE_END_DATE,
  CREATED_AT,
  SOURCE_SYSTEM,
  EFFECTIVE_END_DATE = '9999-12-31'::DATE     AS IS_CURRENT,
  STORE_CLOSE_DATE IS NULL                    AS IS_OPEN,
  MD5(CONCAT_WS('|', STORE_CODE,
                COALESCE(STORE_NAME::VARCHAR, ''),
                COALESCE(COUNTRY_CODE::VARCHAR, ''),
                COALESCE(REGION_CODE::VARCHAR, ''),
                COALESCE(TAX_JURISDICTION_CODE::VARCHAR, ''),
                COALESCE(FORMAT_CODE::VARCHAR, ''),
                COALESCE(CITY::VARCHAR, ''),
                COALESCE(STATE_CODE::VARCHAR, ''),
                COALESCE(POSTAL_CODE::VARCHAR, ''),
                COALESCE(ADDRESS_LINE1::VARCHAR, ''),
                COALESCE(LATITUDE::VARCHAR, ''),
                COALESCE(LONGITUDE::VARCHAR, ''),
                COALESCE(STORE_OPEN_DATE::VARCHAR, ''),
                COALESCE(STORE_CLOSE_DATE::VARCHAR, ''),
                COALESCE(LIFECYCLE_STATUS::VARCHAR, ''),
                COALESCE(FLOOR_AREA_SQFT::VARCHAR, ''),
                COALESCE(ANNUAL_RENT_USD::VARCHAR, ''),
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
      IFF(STORE_NAME IS NULL,                                                'STORE_NAME_MISSING', NULL),
      IFF(COUNTRY_CODE IS NULL OR NOT REGEXP_LIKE(COUNTRY_CODE, '[A-Z]{2}'), 'COUNTRY_CODE_NOT_ISO2', NULL),
      IFF(REGION_CODE IS NULL,                                               'REGION_CODE_MISSING', NULL),
      IFF(FORMAT_CODE IS NULL OR FORMAT_CODE NOT IN ('FLG', 'MALL', 'MINI'), 'FORMAT_CODE_INVALID', NULL),
      IFF(LATITUDE IS NULL OR LATITUDE NOT BETWEEN -90 AND 90,               'LATITUDE_INVALID', NULL),
      IFF(LONGITUDE IS NULL OR LONGITUDE NOT BETWEEN -180 AND 180,           'LONGITUDE_INVALID', NULL),
      IFF(STORE_OPEN_DATE IS NULL,                                           'OPEN_DATE_MISSING', NULL),
      IFF(STORE_CLOSE_DATE_RAW IS NOT NULL AND STORE_CLOSE_DATE IS NULL,     'CLOSE_DATE_UNPARSEABLE', NULL),
      IFF(STORE_CLOSE_DATE < STORE_OPEN_DATE,                                'CLOSE_BEFORE_OPEN', NULL),
      IFF(FLOOR_AREA_SQFT <= 0,                                              'FLOOR_AREA_NOT_POSITIVE', NULL),
      IFF(ANNUAL_RENT_USD < 0,                                               'RENT_NEGATIVE', NULL),
      IFF(EFFECTIVE_START_DATE IS NULL,                                      'START_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE IS NULL,                                        'END_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE < EFFECTIVE_START_DATE,                         'END_BEFORE_START', NULL),
      IFF(IS_ACTIVE IS NULL,                                                 'IS_ACTIVE_MISSING', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                                             'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
),
hashed AS (
  SELECT
    src.*,
    MD5(CONCAT_WS('|', STORE_CODE,
          COALESCE(STORE_NAME::VARCHAR, ''),
          COALESCE(COUNTRY_CODE::VARCHAR, ''),
          COALESCE(REGION_CODE::VARCHAR, ''),
          COALESCE(TAX_JURISDICTION_CODE::VARCHAR, ''),
          COALESCE(FORMAT_CODE::VARCHAR, ''),
          COALESCE(CITY::VARCHAR, ''),
          COALESCE(STATE_CODE::VARCHAR, ''),
          COALESCE(POSTAL_CODE::VARCHAR, ''),
          COALESCE(ADDRESS_LINE1::VARCHAR, ''),
          COALESCE(LATITUDE::VARCHAR, ''),
          COALESCE(LONGITUDE::VARCHAR, ''),
          COALESCE(STORE_OPEN_DATE::VARCHAR, ''),
          COALESCE(STORE_CLOSE_DATE::VARCHAR, ''),
          COALESCE(LIFECYCLE_STATUS::VARCHAR, ''),
          COALESCE(FLOOR_AREA_SQFT::VARCHAR, ''),
          COALESCE(ANNUAL_RENT_USD::VARCHAR, ''),
          COALESCE(IS_ACTIVE::VARCHAR, '')))  AS ATTR_HASH,
    __FILE_LAST_MODIFIED_NTZ  AS VERSION_START_TS
  FROM src
),
kept AS (   -- exact re-sends removed, every real change kept
  SELECT * FROM hashed
  -- drop a row when the next copy of the same version has the same attributes
  QUALIFY LEAD(ATTR_HASH) OVER (PARTITION BY STORE_CODE, EFFECTIVE_START_DATE ORDER BY VERSION_START_TS, __FILE_NAME, __ROW_NUMBER) IS DISTINCT FROM ATTR_HASH
),
versioned AS (
  SELECT
    k.*,
    COUNT(*) OVER (PARTITION BY STORE_CODE, EFFECTIVE_START_DATE) > 1  AS START_CONFLICT,
    ROW_NUMBER() OVER (PARTITION BY STORE_CODE ORDER BY EFFECTIVE_START_DATE DESC, VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1  AS IS_LATEST
  FROM kept k
)
SELECT
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
  LIFECYCLE_STATUS,
  FLOOR_AREA_SQFT,
  ANNUAL_RENT_USD,
  IS_ACTIVE,
  EFFECTIVE_START_DATE,
  EFFECTIVE_END_DATE,
  CREATED_AT,
  SOURCE_SYSTEM,
  IS_CURRENT,
  IS_OPEN,
  RECORD_HASH,
  IFF(START_CONFLICT OR DQ_STATUS = 'WARN', 'WARN', 'PASS')    AS DQ_STATUS,
  IFF(START_CONFLICT, ARRAY_APPEND(DQ_ISSUES, 'SAME_START_DIFFERENT_ATTRIBUTES'), DQ_ISSUES) AS DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ,
  ATTR_HASH,
  VERSION_START_TS,
  IS_LATEST,
  MD5(CONCAT_WS('|', STORE_CODE, EFFECTIVE_START_DATE::VARCHAR, VERSION_START_TS::VARCHAR, __FILE_NAME, __ROW_NUMBER::VARCHAR))  AS SILVER_SK
FROM versioned;
