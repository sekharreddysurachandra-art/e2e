-- =============================================================================
-- V2.2.1 : Bronze sales transaction tables (header and line items)
-- Column lists derived with INFER_SCHEMA on the 2019 source files in DEV.
-- Each table carries 3 load metadata columns filled by COPY ... INCLUDE_METADATA.
-- Tables in DEV/QA are TRANSIENT; PROD tables are permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set meta %}
  __FILE_NAME              VARCHAR(500)  COMMENT 'Stage file the row was loaded from',
  __ROW_NUMBER             NUMBER(18,0)  COMMENT 'Row number within the source file',
  __FILE_LAST_MODIFIED_NTZ TIMESTAMP_NTZ COMMENT 'Last modified time of the source file'
{% endset %}

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.SALES_HEADER (  -- create only if missing
  TRANSACTION_SK        VARCHAR,
  TRANSACTION_ID        VARCHAR,
  TRANSACTION_TIMESTAMP TIMESTAMP_NTZ,
  CUSTOMER_ID           VARCHAR,
  STORE_ID              VARCHAR,
  CHANNEL_ID            VARCHAR,
  COUNTRY_CODE          VARCHAR,
  PAYMENT_METHOD        VARCHAR,
  CURRENCY              VARCHAR,
  GROSS_AMOUNT          NUMBER(6,2),
  TOTAL_DISCOUNT        NUMBER(5,2),
  TOTAL_TAX             NUMBER(6,2),
  NET_TOTAL             NUMBER(6,2),
  CREATED_AT            TIMESTAMP_NTZ,
  SOURCE_SYSTEM         VARCHAR,
{{ meta }}
) COMMENT = 'Raw sales transaction header from CSV';

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.BRONZE.SALES_ITEM (  -- create only if missing
  TRANSACTION_LINE_ID VARCHAR,
  TRANSACTION_SK      VARCHAR,
  LINE_NUMBER         NUMBER(1,0),
  SKU_CODE            VARCHAR,
  CATEGORY_CODE       VARCHAR,
  QUANTITY            NUMBER(1,0),
  UNIT_PRICE          NUMBER(6,2),
  DISCOUNT_AMOUNT     NUMBER(5,2),
  TAX_AMOUNT          NUMBER(6,2),
  LINE_TOTAL          NUMBER(6,2),
  CREATED_AT          TIMESTAMP_NTZ,
{{ meta }}
) COMMENT = 'Raw sales transaction line items from CSV';
