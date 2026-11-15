-- =============================================================================
-- V2.4.3 : Silver COUNTRY_MASTER dynamic table (Bronze -> Silver)
-- Grain   : one row per COUNTRY_CODE + EFFECTIVE_START_DATE (SCD2-style master).
-- Dedup   : COPY does not reject duplicates, so the latest copy of a key wins
--           (newest file, then highest row number in that file).
-- Quality : codes trimmed/upper-cased, text trimmed, rows without a key are
--           dropped; record-level checks are exposed in DQ_STATUS / DQ_ISSUES.
--           Region/currency/tax references are kept as codes; referential
--           integrity is checked when Gold dimensions join them.
-- Keeps the 3 Bronze load metadata columns for lineage back to the file.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold consumers).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.COUNTRY_MASTER (  -- create only if missing
  COUNTRY_CODE             COMMENT 'ISO 2-letter country code (business key)',
  COUNTRY_NAME             COMMENT 'Country name',
  ISO_ALPHA3               COMMENT 'ISO 3-letter country code',
  REGION_CODE              COMMENT 'Sales region code (FK to SILVER.REGION_MASTER)',
  APPLE_FISCAL_SEGMENT     COMMENT 'Fiscal reporting segment',
  CURRENCY_CODE            COMMENT 'Local currency code (FK to SILVER.CURRENCY_MASTER)',
  TAX_CODE                 COMMENT 'Applicable tax code (FK to SILVER.TAX_MASTER)',
  PRIMARY_LANGUAGE         COMMENT 'Primary language',
  TIMEZONE                 COMMENT 'Primary timezone',
  ECOMMERCE_SUPPORTED      COMMENT 'Online store available',
  RETAIL_STORE_SUPPORTED   COMMENT 'Retail stores available',
  MARKET_TIER              COMMENT 'Market priority tier',
  POPULATION_MILLIONS      COMMENT 'Population in millions',
  GDP_USD_BILLIONS         COMMENT 'GDP in USD billions',
  GDPR_APPLICABLE          COMMENT 'GDPR applies',
  IS_ACTIVE                COMMENT 'Country is active',
  EFFECTIVE_START_DATE     COMMENT 'Record valid from',
  EFFECTIVE_END_DATE       COMMENT 'Record valid to (9999-12-31 = current)',
  IS_CURRENT               COMMENT 'TRUE when EFFECTIVE_END_DATE = 9999-12-31',
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
  COMMENT      = 'Cleaned, de-duplicated country master'
AS
WITH cleaned AS (
  SELECT
    UPPER(TRIM(COUNTRY_CODE))                        AS COUNTRY_CODE,
    NULLIF(TRIM(COUNTRY_NAME), '')                   AS COUNTRY_NAME,
    UPPER(NULLIF(TRIM(ISO_ALPHA3), ''))              AS ISO_ALPHA3,
    UPPER(NULLIF(TRIM(REGION_CODE), ''))             AS REGION_CODE,
    NULLIF(TRIM(APPLE_FISCAL_SEGMENT), '')           AS APPLE_FISCAL_SEGMENT,
    UPPER(NULLIF(TRIM(CURRENCY_CODE), ''))           AS CURRENCY_CODE,
    UPPER(NULLIF(TRIM(TAX_CODE), ''))                AS TAX_CODE,
    NULLIF(TRIM(PRIMARY_LANGUAGE), '')               AS PRIMARY_LANGUAGE,
    NULLIF(TRIM(TIMEZONE), '')                       AS TIMEZONE,
    ECOMMERCE_SUPPORTED,
    RETAIL_STORE_SUPPORTED,
    NULLIF(TRIM(MARKET_TIER), '')                    AS MARKET_TIER,
    POPULATION_MILLIONS,
    GDP_USD_BILLIONS,
    GDPR_APPLICABLE,
    IS_ACTIVE,
    EFFECTIVE_START_DATE,
    EFFECTIVE_END_DATE,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))           AS SOURCE_SYSTEM,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.COUNTRY_MASTER
  WHERE NULLIF(TRIM(COUNTRY_CODE), '') IS NOT NULL  -- no business key, no row
)
SELECT
  COUNTRY_CODE,
  COUNTRY_NAME,
  ISO_ALPHA3,
  REGION_CODE,
  APPLE_FISCAL_SEGMENT,
  CURRENCY_CODE,
  TAX_CODE,
  PRIMARY_LANGUAGE,
  TIMEZONE,
  ECOMMERCE_SUPPORTED,
  RETAIL_STORE_SUPPORTED,
  MARKET_TIER,
  POPULATION_MILLIONS,
  GDP_USD_BILLIONS,
  GDPR_APPLICABLE,
  IS_ACTIVE,
  EFFECTIVE_START_DATE,
  EFFECTIVE_END_DATE,
  EFFECTIVE_END_DATE = '9999-12-31'::DATE            AS IS_CURRENT,
  CREATED_AT,
  SOURCE_SYSTEM,
  MD5(CONCAT_WS('|', COUNTRY_CODE, COALESCE(COUNTRY_NAME, ''), COALESCE(ISO_ALPHA3, ''),
                COALESCE(REGION_CODE, ''), COALESCE(APPLE_FISCAL_SEGMENT, ''),
                COALESCE(CURRENCY_CODE, ''), COALESCE(TAX_CODE, ''),
                COALESCE(PRIMARY_LANGUAGE, ''), COALESCE(TIMEZONE, ''),
                COALESCE(ECOMMERCE_SUPPORTED::VARCHAR, ''),
                COALESCE(RETAIL_STORE_SUPPORTED::VARCHAR, ''),
                COALESCE(MARKET_TIER, ''),
                COALESCE(POPULATION_MILLIONS::VARCHAR, ''),
                COALESCE(GDP_USD_BILLIONS::VARCHAR, ''),
                COALESCE(GDPR_APPLICABLE::VARCHAR, ''),
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
      IFF(NOT REGEXP_LIKE(COUNTRY_CODE, '[A-Z]{2}'), 'COUNTRY_CODE_NOT_ISO2', NULL),
      IFF(ISO_ALPHA3 IS NULL OR NOT REGEXP_LIKE(ISO_ALPHA3, '[A-Z]{3}'), 'ISO_ALPHA3_INVALID', NULL),
      IFF(COUNTRY_NAME IS NULL,                   'COUNTRY_NAME_MISSING', NULL),
      IFF(REGION_CODE IS NULL,                    'REGION_CODE_MISSING', NULL),
      IFF(CURRENCY_CODE IS NULL OR NOT REGEXP_LIKE(CURRENCY_CODE, '[A-Z]{3}'), 'CURRENCY_CODE_INVALID', NULL),
      IFF(TAX_CODE IS NULL,                       'TAX_CODE_MISSING', NULL),
      IFF(POPULATION_MILLIONS < 0,                'POPULATION_NEGATIVE', NULL),
      IFF(GDP_USD_BILLIONS < 0,                   'GDP_NEGATIVE', NULL),
      IFF(IS_ACTIVE IS NULL,                      'IS_ACTIVE_MISSING', NULL),
      IFF(EFFECTIVE_START_DATE IS NULL,           'START_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE IS NULL,             'END_DATE_MISSING', NULL),
      IFF(EFFECTIVE_END_DATE < EFFECTIVE_START_DATE, 'END_BEFORE_START', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                  'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY COUNTRY_CODE, EFFECTIVE_START_DATE
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
