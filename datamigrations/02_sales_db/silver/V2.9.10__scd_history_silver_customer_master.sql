-- =============================================================================
-- V2.9.10 : Silver CUSTOMER_MASTER keeps change history (replaces dedup of V2.6.0)
-- Why     : the previous version kept only the latest row per business key, so a
--           changed record was treated as a duplicate and the old version was
--           lost. Gold SCD2 dimensions need every version.
-- Dedup   : only exact re-sends are dropped - a row is removed when its ATTR_HASH
--           (business attributes, no effective dates or load metadata) equals the
--           previous row for the same CUSTOMER_ID (the first copy is kept, so VERSION_START_TS is when the version first arrived).
--           Changes back to an earlier value (A -> B -> A) are kept.
-- Version : VERSION_START_TS = UPDATED_AT (file arrival when missing).
-- Grain   : one row per CUSTOMER_ID version; SILVER_SK = MD5 of key + version + source row.
--           IS_LATEST flags the newest version of each CUSTOMER_ID.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           existing dynamic table in place (one reinitialisation).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.CUSTOMER_MASTER (  -- create or evolve in place
  CUSTOMER_ID              COMMENT 'Customer UUID (business key)',
  CUSTOMER_NUMBER          COMMENT 'Customer number',
  FIRST_NAME               COMMENT 'First name (PII)',
  LAST_NAME                COMMENT 'Last name (PII)',
  FULL_NAME                COMMENT 'Full name (PII)',
  GENDER                   COMMENT 'Gender',
  DATE_OF_BIRTH            COMMENT 'Date of birth (PII)',
  EMAIL                    COMMENT 'E-mail address, lower-case (PII)',
  PHONE_NUMBER             COMMENT 'Phone number (PII)',
  STREET_ADDRESS           COMMENT 'Street address (PII)',
  CITY                     COMMENT 'City',
  STATE_PROVINCE           COMMENT 'State or province',
  POSTAL_CODE              COMMENT 'Postal code (text, keeps leading zeros)',
  COUNTRY_CODE             COMMENT 'ISO 2-letter country code (FK to SILVER.COUNTRY_MASTER)',
  COUNTRY_NAME             COMMENT 'Country name',
  REGION_CODE              COMMENT 'Sales region code (Bronze REGION; FK to SILVER.REGION_MASTER)',
  PREFERRED_LANGUAGE       COMMENT 'Preferred language',
  CUSTOMER_SEGMENT         COMMENT 'Segment (Consumer, Business, Education)',
  LOYALTY_TIER             COMMENT 'Loyalty tier (None, Silver, Gold, Platinum)',
  REGISTRATION_DATE        COMMENT 'Date the customer registered',
  ACQUISITION_YEAR         COMMENT 'Year the customer was acquired',
  CUSTOMER_TYPE            COMMENT 'Customer type (e.g. NEW)',
  IS_ACTIVE                COMMENT 'Customer is active',
  SOURCE_SYSTEM            COMMENT 'Source system of the record',
  CREATED_AT               COMMENT 'Created date in source',
  UPDATED_AT               COMMENT 'Last updated timestamp in source',
  EMAIL_DOMAIN             COMMENT 'Domain part of the e-mail address',
  RECORD_HASH              COMMENT 'MD5 of business attributes for change detection',
  DQ_STATUS                COMMENT 'PASS or WARN from record-level quality checks',
  DQ_ISSUES                COMMENT 'List of failed quality checks (empty when PASS)',
  __FILE_NAME              COMMENT 'Stage file the row was loaded from',
  __ROW_NUMBER             COMMENT 'Row number within the source file',
  __FILE_LAST_MODIFIED_NTZ COMMENT 'Last modified time of the source file',
  ATTR_HASH                COMMENT 'MD5 of business attributes (no effective dates/metadata) - change detection',
  VERSION_START_TS         COMMENT 'Version valid from: source UPDATED_AT, file arrival when missing',
  IS_LATEST                COMMENT 'TRUE for the newest version of the business key',
  SILVER_SK                COMMENT 'MD5 of business key + version + source file/row (unique row id)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Bronze rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Cleaned, versioned (change history) customer master'
AS
WITH cleaned AS (
  SELECT
    LOWER(NULLIF(TRIM(CUSTOMER_ID), ''))     AS CUSTOMER_ID,
    UPPER(NULLIF(TRIM(CUSTOMER_NUMBER), '')) AS CUSTOMER_NUMBER,
    NULLIF(TRIM(FIRST_NAME), '')             AS FIRST_NAME,
    NULLIF(TRIM(LAST_NAME), '')              AS LAST_NAME,
    NULLIF(TRIM(FULL_NAME), '')              AS FULL_NAME,
    NULLIF(TRIM(GENDER), '')                 AS GENDER,
    DATE_OF_BIRTH,
    LOWER(NULLIF(TRIM(EMAIL), ''))           AS EMAIL,
    NULLIF(TRIM(PHONE_NUMBER), '')           AS PHONE_NUMBER,
    NULLIF(TRIM(STREET_ADDRESS), '')         AS STREET_ADDRESS,
    NULLIF(TRIM(CITY), '')                   AS CITY,
    NULLIF(TRIM(STATE_PROVINCE), '')         AS STATE_PROVINCE,
    UPPER(NULLIF(TRIM(POSTAL_CODE), ''))     AS POSTAL_CODE,
    UPPER(NULLIF(TRIM(COUNTRY_CODE), ''))    AS COUNTRY_CODE,
    NULLIF(TRIM(COUNTRY_NAME), '')           AS COUNTRY_NAME,
    UPPER(NULLIF(TRIM(REGION), ''))          AS REGION_CODE,
    NULLIF(TRIM(PREFERRED_LANGUAGE), '')     AS PREFERRED_LANGUAGE,
    NULLIF(TRIM(CUSTOMER_SEGMENT), '')       AS CUSTOMER_SEGMENT,
    NULLIF(TRIM(LOYALTY_TIER), '')           AS LOYALTY_TIER,
    REGISTRATION_DATE,
    ACQUISITION_YEAR,
    UPPER(NULLIF(TRIM(CUSTOMER_TYPE), ''))   AS CUSTOMER_TYPE,
    IS_ACTIVE,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))   AS SOURCE_SYSTEM,
    CREATED_AT,
    UPDATED_AT,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.CUSTOMER_MASTER
  WHERE NULLIF(TRIM(CUSTOMER_ID), '') IS NOT NULL   -- no business key, no row
),
src AS (   -- cleaned rows with record-level DQ (unchanged logic)
SELECT
  CUSTOMER_ID,
  CUSTOMER_NUMBER,
  FIRST_NAME,
  LAST_NAME,
  FULL_NAME,
  GENDER,
  DATE_OF_BIRTH,
  EMAIL,
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
  CREATED_AT,
  UPDATED_AT,
  SPLIT_PART(EMAIL, '@', 2)                   AS EMAIL_DOMAIN,
  MD5(CONCAT_WS('|', CUSTOMER_ID,
                COALESCE(CUSTOMER_NUMBER::VARCHAR, ''),
                COALESCE(FIRST_NAME::VARCHAR, ''),
                COALESCE(LAST_NAME::VARCHAR, ''),
                COALESCE(FULL_NAME::VARCHAR, ''),
                COALESCE(GENDER::VARCHAR, ''),
                COALESCE(DATE_OF_BIRTH::VARCHAR, ''),
                COALESCE(EMAIL::VARCHAR, ''),
                COALESCE(PHONE_NUMBER::VARCHAR, ''),
                COALESCE(STREET_ADDRESS::VARCHAR, ''),
                COALESCE(CITY::VARCHAR, ''),
                COALESCE(STATE_PROVINCE::VARCHAR, ''),
                COALESCE(POSTAL_CODE::VARCHAR, ''),
                COALESCE(COUNTRY_CODE::VARCHAR, ''),
                COALESCE(COUNTRY_NAME::VARCHAR, ''),
                COALESCE(REGION_CODE::VARCHAR, ''),
                COALESCE(PREFERRED_LANGUAGE::VARCHAR, ''),
                COALESCE(CUSTOMER_SEGMENT::VARCHAR, ''),
                COALESCE(LOYALTY_TIER::VARCHAR, ''),
                COALESCE(REGISTRATION_DATE::VARCHAR, ''),
                COALESCE(ACQUISITION_YEAR::VARCHAR, ''),
                COALESCE(CUSTOMER_TYPE::VARCHAR, ''),
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
      IFF(CUSTOMER_NUMBER IS NULL,                                           'CUSTOMER_NUMBER_MISSING', NULL),
      IFF(FULL_NAME IS NULL,                                                 'FULL_NAME_MISSING', NULL),
      IFF(EMAIL IS NULL OR NOT REGEXP_LIKE(EMAIL, '[^@ ]+@[^@ ]+\\.[^@ ]+'), 'EMAIL_INVALID', NULL),
      IFF(GENDER IS NOT NULL AND GENDER NOT IN ('Female', 'Male'),           'GENDER_UNEXPECTED', NULL),
      IFF(DATE_OF_BIRTH IS NULL OR DATE_OF_BIRTH < '1900-01-01'::DATE,       'DATE_OF_BIRTH_INVALID', NULL),
      IFF(DATE_OF_BIRTH > REGISTRATION_DATE,                                 'BORN_AFTER_REGISTRATION', NULL),
      IFF(COUNTRY_CODE IS NULL OR NOT REGEXP_LIKE(COUNTRY_CODE, '[A-Z]{2}'), 'COUNTRY_CODE_NOT_ISO2', NULL),
      IFF(REGION_CODE IS NULL,                                               'REGION_CODE_MISSING', NULL),
      IFF(REGISTRATION_DATE IS NULL,                                         'REGISTRATION_DATE_MISSING', NULL),
      IFF(ACQUISITION_YEAR <> YEAR(REGISTRATION_DATE),                       'ACQUISITION_YEAR_MISMATCH', NULL),
      IFF(IS_ACTIVE IS NULL,                                                 'IS_ACTIVE_MISSING', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                                             'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
),
hashed AS (
  SELECT
    src.*,
    MD5(CONCAT_WS('|', CUSTOMER_ID,
          COALESCE(CUSTOMER_NUMBER::VARCHAR, ''),
          COALESCE(FIRST_NAME::VARCHAR, ''),
          COALESCE(LAST_NAME::VARCHAR, ''),
          COALESCE(FULL_NAME::VARCHAR, ''),
          COALESCE(GENDER::VARCHAR, ''),
          COALESCE(DATE_OF_BIRTH::VARCHAR, ''),
          COALESCE(EMAIL::VARCHAR, ''),
          COALESCE(PHONE_NUMBER::VARCHAR, ''),
          COALESCE(STREET_ADDRESS::VARCHAR, ''),
          COALESCE(CITY::VARCHAR, ''),
          COALESCE(STATE_PROVINCE::VARCHAR, ''),
          COALESCE(POSTAL_CODE::VARCHAR, ''),
          COALESCE(COUNTRY_CODE::VARCHAR, ''),
          COALESCE(COUNTRY_NAME::VARCHAR, ''),
          COALESCE(REGION_CODE::VARCHAR, ''),
          COALESCE(PREFERRED_LANGUAGE::VARCHAR, ''),
          COALESCE(CUSTOMER_SEGMENT::VARCHAR, ''),
          COALESCE(LOYALTY_TIER::VARCHAR, ''),
          COALESCE(REGISTRATION_DATE::VARCHAR, ''),
          COALESCE(ACQUISITION_YEAR::VARCHAR, ''),
          COALESCE(CUSTOMER_TYPE::VARCHAR, ''),
          COALESCE(IS_ACTIVE::VARCHAR, '')))  AS ATTR_HASH,
    COALESCE(UPDATED_AT, __FILE_LAST_MODIFIED_NTZ)  AS VERSION_START_TS
  FROM src
),
kept AS (   -- exact re-sends removed, every real change kept
  SELECT * FROM hashed
  -- drop a row when the previous copy of the same key has the same attributes
  QUALIFY LAG(ATTR_HASH) OVER (PARTITION BY CUSTOMER_ID ORDER BY VERSION_START_TS, __FILE_NAME, __ROW_NUMBER) IS DISTINCT FROM ATTR_HASH
),
versioned AS (
  SELECT
    k.*,
    ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY VERSION_START_TS DESC, __FILE_NAME DESC, __ROW_NUMBER DESC) = 1  AS IS_LATEST
  FROM kept k
)
SELECT
  CUSTOMER_ID,
  CUSTOMER_NUMBER,
  FIRST_NAME,
  LAST_NAME,
  FULL_NAME,
  GENDER,
  DATE_OF_BIRTH,
  EMAIL,
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
  CREATED_AT,
  UPDATED_AT,
  EMAIL_DOMAIN,
  RECORD_HASH,
  DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ,
  ATTR_HASH,
  VERSION_START_TS,
  IS_LATEST,
  MD5(CONCAT_WS('|', CUSTOMER_ID, VERSION_START_TS::VARCHAR, __FILE_NAME, __ROW_NUMBER::VARCHAR))  AS SILVER_SK
FROM versioned;
