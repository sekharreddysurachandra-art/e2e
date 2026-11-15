-- =============================================================================
-- V2.6.0 : Silver CUSTOMER_MASTER dynamic table (Bronze -> Silver)
-- Grain   : one row per CUSTOMER_ID.
-- Dedup   : COPY does not reject duplicates, so the latest copy of a key wins
--           (newest file, then highest row number in that file).
-- Quality : codes trimmed/upper-cased, text trimmed, rows without a key are
--           dropped; record-level checks are exposed in DQ_STATUS / DQ_ISSUES.
-- Notes   : Dedup prefers the latest UPDATED_AT, then newest file / row.
--           EMAIL is not a unique key: different customers share e-mail addresses
--           in the source, so customers are NOT de-duplicated on e-mail.
--           Contains PII (name, e-mail, phone, address, birth date) - masking
--           policies from GOVERNANCE.POLICIES should be applied before sharing.
-- Keeps the 3 Bronze load metadata columns for lineage back to the file.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold consumers).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.CUSTOMER_MASTER (  -- create only if missing
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
  __FILE_LAST_MODIFIED_NTZ COMMENT 'Last modified time of the source file'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Bronze rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Cleaned, de-duplicated customer master'
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
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY CUSTOMER_ID
  ORDER BY UPDATED_AT DESC NULLS LAST, __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
