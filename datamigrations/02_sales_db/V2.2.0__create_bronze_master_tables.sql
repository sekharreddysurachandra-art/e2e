-- =============================================================================
-- V2.2.0 : Bronze master data tables (country, product, store, customer)
-- Column lists were derived with INFER_SCHEMA on the 2019 source files in DEV
-- and are fixed here so every environment gets the same structure, even before
-- files are on its stage. CUSTOMER_MASTER was inferred over all country files
-- (single-file inference typed POSTAL_CODE as a number).
-- Each table carries 3 load metadata columns filled by COPY ... INCLUDE_METADATA.
-- Tables in DEV/QA are TRANSIENT; PROD tables are permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set meta %}
  __FILE_NAME              VARCHAR(500)  COMMENT 'Stage file the row was loaded from',
  __ROW_NUMBER             NUMBER(18,0)  COMMENT 'Row number within the source file',
  __FILE_LAST_MODIFIED_NTZ TIMESTAMP_NTZ COMMENT 'Last modified time of the source file'
{% endset %}

-- ---------------------------------------------------------------- country-master
CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.REGION_MASTER (  -- create only if missing
  REGION_CODE          VARCHAR(30)     COMMENT 'Sales region code (e.g. AMER, EMEA)',
  REGION_NAME          VARCHAR(100)    COMMENT 'Sales region name',
  IS_ACTIVE            BOOLEAN         COMMENT 'Region is active',
  EFFECTIVE_START_DATE DATE            COMMENT 'Record valid from',
  EFFECTIVE_END_DATE   DATE            COMMENT 'Record valid to (9999-12-31 = current)',
  CREATED_AT           TIMESTAMP_NTZ(6) COMMENT 'Created timestamp in source',
  SOURCE_SYSTEM        VARCHAR(50)     COMMENT 'Source system of the record',
{{ meta }}
) COMMENT = 'Raw region master from CSV';

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.CURRENCY_MASTER (  -- create only if missing
  CURRENCY_CODE        VARCHAR(3)      COMMENT 'ISO 4217 currency code',
  CURRENCY_NAME        VARCHAR(100)    COMMENT 'Currency name',
  CURRENCY_SYMBOL      VARCHAR(10)     COMMENT 'Currency symbol',
  MINOR_UNIT           NUMBER(2,0)     COMMENT 'Number of decimal places',
  IS_ACTIVE            BOOLEAN         COMMENT 'Currency is active',
  EFFECTIVE_START_DATE DATE            COMMENT 'Record valid from',
  EFFECTIVE_END_DATE   DATE            COMMENT 'Record valid to (9999-12-31 = current)',
  CREATED_AT           TIMESTAMP_NTZ(6) COMMENT 'Created timestamp in source',
  SOURCE_SYSTEM        VARCHAR(50)     COMMENT 'Source system of the record',
{{ meta }}
) COMMENT = 'Raw currency master from CSV';

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.TAX_MASTER (  -- create only if missing
  TAX_CODE             VARCHAR(30)     COMMENT 'Tax code',
  TAX_TYPE             VARCHAR(50)     COMMENT 'Tax type (e.g. VAT, GST, sales tax)',
  TAX_RATE             NUMBER(6,4)     COMMENT 'Tax rate as decimal fraction',
  TAX_INCLUSIVE_FLAG   BOOLEAN         COMMENT 'Prices include tax',
  EFFECTIVE_START_DATE DATE            COMMENT 'Record valid from',
  EFFECTIVE_END_DATE   DATE            COMMENT 'Record valid to (9999-12-31 = current)',
  IS_ACTIVE            BOOLEAN         COMMENT 'Tax code is active',
  CREATED_AT           TIMESTAMP_NTZ(6) COMMENT 'Created timestamp in source',
  SOURCE_SYSTEM        VARCHAR(50)     COMMENT 'Source system of the record',
{{ meta }}
) COMMENT = 'Raw tax master from CSV';

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.COUNTRY_MASTER (  -- create only if missing
  COUNTRY_CODE           VARCHAR(10)   COMMENT 'ISO 2-letter country code',
  COUNTRY_NAME           VARCHAR(100)  COMMENT 'Country name',
  ISO_ALPHA3             VARCHAR(3)    COMMENT 'ISO 3-letter country code',
  REGION_CODE            VARCHAR(30)   COMMENT 'Sales region code (FK to region master)',
  APPLE_FISCAL_SEGMENT   VARCHAR(50)   COMMENT 'Fiscal reporting segment',
  CURRENCY_CODE          VARCHAR(3)    COMMENT 'Local currency code (FK to currency master)',
  TAX_CODE               VARCHAR(30)   COMMENT 'Applicable tax code (FK to tax master)',
  PRIMARY_LANGUAGE       VARCHAR(50)   COMMENT 'Primary language',
  TIMEZONE               VARCHAR(50)   COMMENT 'Primary timezone',
  ECOMMERCE_SUPPORTED    BOOLEAN       COMMENT 'Online store available',
  RETAIL_STORE_SUPPORTED BOOLEAN       COMMENT 'Retail stores available',
  MARKET_TIER            VARCHAR(20)   COMMENT 'Market priority tier',
  POPULATION_MILLIONS    NUMBER(10,2)  COMMENT 'Population in millions',
  GDP_USD_BILLIONS       NUMBER(12,2)  COMMENT 'GDP in USD billions',
  GDPR_APPLICABLE        BOOLEAN       COMMENT 'GDPR applies',
  IS_ACTIVE              BOOLEAN       COMMENT 'Country is active',
  EFFECTIVE_START_DATE   DATE          COMMENT 'Record valid from',
  EFFECTIVE_END_DATE     DATE          COMMENT 'Record valid to (9999-12-31 = current)',
  CREATED_AT             TIMESTAMP_NTZ(6) COMMENT 'Created timestamp in source',
  SOURCE_SYSTEM          VARCHAR(50)   COMMENT 'Source system of the record',
{{ meta }}
) COMMENT = 'Raw country master from CSV';

-- ---------------------------------------------------------------- product-master
CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.PRODUCT_CATEGORY_MASTER (  -- create only if missing
  CATEGORY_CODE        VARCHAR,
  CATEGORY_NAME        VARCHAR,
  REPORTING_SEGMENT    VARCHAR,
  IS_ACTIVE            BOOLEAN,
  EFFECTIVE_START_DATE DATE,
  EFFECTIVE_END_DATE   DATE,
  CREATED_AT           TIMESTAMP_NTZ,
  SOURCE_SYSTEM        VARCHAR,
{{ meta }}
) COMMENT = 'Raw product category master from CSV';

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.PRODUCT_FAMILY_MASTER (  -- create only if missing
  FAMILY_CODE          VARCHAR,
  FAMILY_NAME          VARCHAR,
  CATEGORY_CODE        VARCHAR,
  LAUNCH_YEAR          NUMBER(4,0),
  IS_ACTIVE            BOOLEAN,
  LIFECYCLE_STATUS     VARCHAR,
  CREATED_AT           TIMESTAMP_NTZ,
  SOURCE_SYSTEM        VARCHAR,
{{ meta }}
) COMMENT = 'Raw product family master from CSV';

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.PRODUCT_MODEL_MASTER (  -- create only if missing
  MODEL_CODE           VARCHAR,
  MODEL_NAME           VARCHAR,
  FAMILY_CODE          VARCHAR,
  LAUNCH_DATE          DATE,
  DISCONTINUE_DATE     VARCHAR,
  LIFECYCLE_STATUS     VARCHAR,
  IS_ACTIVE            BOOLEAN,
  CREATED_AT           TIMESTAMP_NTZ,
  SOURCE_SYSTEM        VARCHAR,
{{ meta }}
) COMMENT = 'Raw product model master from CSV';

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.PRODUCT_SKU_MASTER (  -- create only if missing
  SKU_CODE             VARCHAR,
  MODEL_CODE           VARCHAR,
  VARIANT              VARCHAR,
  PRICE_TIER           VARCHAR,
  GLOBAL_LAUNCH_DATE   DATE,
  IS_ACTIVE            BOOLEAN,
  CREATED_AT           TIMESTAMP_NTZ,
  SOURCE_SYSTEM        VARCHAR,
{{ meta }}
) COMMENT = 'Raw product SKU master from CSV';

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.PRODUCT_COUNTRY_AVAILABILITY (  -- create only if missing
  SKU_CODE               VARCHAR,
  COUNTRY_CODE           VARCHAR,
  LOCAL_PART_NUMBER      VARCHAR,
  LOCAL_LAUNCH_DATE      DATE,
  LOCAL_DISCONTINUE_DATE VARCHAR,
  IS_AVAILABLE           BOOLEAN,
  CREATED_AT             TIMESTAMP_NTZ,
  SOURCE_SYSTEM          VARCHAR,
{{ meta }}
) COMMENT = 'Raw product availability by country from CSV';

-- ---------------------------------------------------------------- store-master
CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.STORE_MASTER (  -- create only if missing
  STORE_CODE            VARCHAR,
  STORE_NAME            VARCHAR,
  COUNTRY_CODE          VARCHAR,
  REGION_CODE           VARCHAR,
  TAX_JURISDICTION_CODE VARCHAR,
  FORMAT_CODE           VARCHAR,
  CITY                  VARCHAR,
  STATE_CODE            VARCHAR,
  POSTAL_CODE           VARCHAR,
  ADDRESS_LINE1         VARCHAR,
  LATITUDE              NUMBER(8,6),
  LONGITUDE             NUMBER(9,6),
  STORE_OPEN_DATE       DATE,
  STORE_CLOSE_DATE      VARCHAR,
  LIFECYCLE_STATUS      VARCHAR,
  FLOOR_AREA_SQFT       NUMBER(5,0),
  ANNUAL_RENT_USD       NUMBER(8,0),
  IS_ACTIVE             BOOLEAN,
  EFFECTIVE_START_DATE  DATE,
  EFFECTIVE_END_DATE    DATE,
  CREATED_AT            TIMESTAMP_NTZ,
  SOURCE_SYSTEM         VARCHAR,
{{ meta }}
) COMMENT = 'Raw store master from CSV';

-- ---------------------------------------------------------------- customer-master
CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.CUSTOMER_MASTER (  -- create only if missing
  CUSTOMER_ID        VARCHAR,
  CUSTOMER_NUMBER    VARCHAR,
  FIRST_NAME         VARCHAR,
  LAST_NAME          VARCHAR,
  FULL_NAME          VARCHAR,
  GENDER             VARCHAR,
  DATE_OF_BIRTH      DATE,
  EMAIL              VARCHAR,
  PHONE_NUMBER       VARCHAR,
  STREET_ADDRESS     VARCHAR,
  CITY               VARCHAR,
  STATE_PROVINCE     VARCHAR,
  POSTAL_CODE        VARCHAR,
  COUNTRY_CODE       VARCHAR,
  COUNTRY_NAME       VARCHAR,
  REGION             VARCHAR,
  PREFERRED_LANGUAGE VARCHAR,
  CUSTOMER_SEGMENT   VARCHAR,
  LOYALTY_TIER       VARCHAR,
  REGISTRATION_DATE  DATE,
  ACQUISITION_YEAR   NUMBER(4,0),
  CUSTOMER_TYPE      VARCHAR,
  IS_ACTIVE          BOOLEAN,
  SOURCE_SYSTEM      VARCHAR,
  CREATED_AT         DATE,
  UPDATED_AT         TIMESTAMP_NTZ,
{{ meta }}
) COMMENT = 'Raw customer master (per year/country files) from CSV';
