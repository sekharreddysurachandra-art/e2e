-- =============================================================================
-- V2.8.0 : Silver SALES_HEADER dynamic table (Bronze -> Silver)
-- Grain   : one row per TRANSACTION_SK (TRANSACTION_ID is also unique).
-- Dedup   : COPY does not reject duplicates, so the latest copy of a key wins
--           (newest file, then highest row number in that file).
-- Quality : codes trimmed/upper-cased, text trimmed, rows without a key are
--           dropped; record-level checks are exposed in DQ_STATUS / DQ_ISSUES.
-- Notes   : ONLINE orders have no STORE_ID by design; POS orders must have one.
--           NET_TOTAL = GROSS_AMOUNT - TOTAL_DISCOUNT + TOTAL_TAX.
--           The 2019 file contains a few 2020-01-01 transactions (period cut-off);
--           they are kept, the business date comes from TRANSACTION_TIMESTAMP.
-- Keeps the 3 Bronze load metadata columns for lineage back to the file.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold consumers).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.SALES_HEADER (  -- create only if missing
  TRANSACTION_SK           COMMENT 'Transaction surrogate key (business key)',
  TRANSACTION_ID           COMMENT 'Transaction id from the source system',
  TRANSACTION_TIMESTAMP    COMMENT 'Transaction timestamp (local)',
  CUSTOMER_ID              COMMENT 'Customer UUID (FK to SILVER.CUSTOMER_MASTER)',
  STORE_ID                 COMMENT 'Store code (FK to SILVER.STORE_MASTER; NULL for ONLINE)',
  CHANNEL_ID               COMMENT 'Sales channel (POS, ONLINE)',
  COUNTRY_CODE             COMMENT 'ISO 2-letter country code (FK to SILVER.COUNTRY_MASTER)',
  PAYMENT_METHOD           COMMENT 'Payment method',
  CURRENCY_CODE            COMMENT 'Transaction currency (Bronze CURRENCY; FK to SILVER.CURRENCY_MASTER)',
  GROSS_AMOUNT             COMMENT 'Gross amount before discount and tax',
  TOTAL_DISCOUNT           COMMENT 'Total discount',
  TOTAL_TAX                COMMENT 'Total tax',
  NET_TOTAL                COMMENT 'Net total (gross - discount + tax)',
  CREATED_AT               COMMENT 'Created timestamp in source',
  SOURCE_SYSTEM            COMMENT 'Source system of the record',
  TRANSACTION_DATE         COMMENT 'Business date of the transaction',
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
  COMMENT      = 'Cleaned, de-duplicated sales transaction header'
AS
WITH cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(TRANSACTION_SK), '')) AS TRANSACTION_SK,
    UPPER(NULLIF(TRIM(TRANSACTION_ID), '')) AS TRANSACTION_ID,
    TRANSACTION_TIMESTAMP,
    LOWER(NULLIF(TRIM(CUSTOMER_ID), ''))    AS CUSTOMER_ID,
    UPPER(NULLIF(TRIM(STORE_ID), ''))       AS STORE_ID,
    UPPER(NULLIF(TRIM(CHANNEL_ID), ''))     AS CHANNEL_ID,
    UPPER(NULLIF(TRIM(COUNTRY_CODE), ''))   AS COUNTRY_CODE,
    NULLIF(TRIM(PAYMENT_METHOD), '')        AS PAYMENT_METHOD,
    UPPER(NULLIF(TRIM(CURRENCY), ''))       AS CURRENCY_CODE,
    GROSS_AMOUNT,
    TOTAL_DISCOUNT,
    TOTAL_TAX,
    NET_TOTAL,
    CREATED_AT,
    UPPER(NULLIF(TRIM(SOURCE_SYSTEM), ''))  AS SOURCE_SYSTEM,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.SALES_HEADER
  WHERE NULLIF(TRIM(TRANSACTION_SK), '') IS NOT NULL   -- no business key, no row
)
SELECT
  TRANSACTION_SK,
  TRANSACTION_ID,
  TRANSACTION_TIMESTAMP,
  CUSTOMER_ID,
  STORE_ID,
  CHANNEL_ID,
  COUNTRY_CODE,
  PAYMENT_METHOD,
  CURRENCY_CODE,
  GROSS_AMOUNT,
  TOTAL_DISCOUNT,
  TOTAL_TAX,
  NET_TOTAL,
  CREATED_AT,
  SOURCE_SYSTEM,
  TRANSACTION_TIMESTAMP::DATE                 AS TRANSACTION_DATE,
  MD5(CONCAT_WS('|', TRANSACTION_SK,
                COALESCE(TRANSACTION_ID::VARCHAR, ''),
                COALESCE(TRANSACTION_TIMESTAMP::VARCHAR, ''),
                COALESCE(CUSTOMER_ID::VARCHAR, ''),
                COALESCE(STORE_ID::VARCHAR, ''),
                COALESCE(CHANNEL_ID::VARCHAR, ''),
                COALESCE(COUNTRY_CODE::VARCHAR, ''),
                COALESCE(PAYMENT_METHOD::VARCHAR, ''),
                COALESCE(CURRENCY_CODE::VARCHAR, ''),
                COALESCE(GROSS_AMOUNT::VARCHAR, ''),
                COALESCE(TOTAL_DISCOUNT::VARCHAR, ''),
                COALESCE(TOTAL_TAX::VARCHAR, ''),
                COALESCE(NET_TOTAL::VARCHAR, '')))  AS RECORD_HASH,
  IFF(ARRAY_SIZE(DQ_ISSUES) = 0, 'PASS', 'WARN')     AS DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ
FROM (
  SELECT
    c.*,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(TRANSACTION_ID IS NULL,                                                   'TRANSACTION_ID_MISSING', NULL),
      IFF(TRANSACTION_TIMESTAMP IS NULL,                                            'TRANSACTION_TIMESTAMP_MISSING', NULL),
      IFF(CUSTOMER_ID IS NULL,                                                      'CUSTOMER_ID_MISSING', NULL),
      IFF(CHANNEL_ID IS NULL OR CHANNEL_ID NOT IN ('POS', 'ONLINE'),                'CHANNEL_INVALID', NULL),
      IFF(CHANNEL_ID = 'POS' AND STORE_ID IS NULL,                                  'POS_WITHOUT_STORE', NULL),
      IFF(CHANNEL_ID = 'ONLINE' AND STORE_ID IS NOT NULL,                           'ONLINE_WITH_STORE', NULL),
      IFF(COUNTRY_CODE IS NULL OR NOT REGEXP_LIKE(COUNTRY_CODE, '[A-Z]{2}'),        'COUNTRY_CODE_NOT_ISO2', NULL),
      IFF(CURRENCY_CODE IS NULL OR NOT REGEXP_LIKE(CURRENCY_CODE, '[A-Z]{3}'),      'CURRENCY_CODE_INVALID', NULL),
      IFF(PAYMENT_METHOD IS NULL,                                                   'PAYMENT_METHOD_MISSING', NULL),
      IFF(GROSS_AMOUNT < 0 OR TOTAL_DISCOUNT < 0 OR TOTAL_TAX < 0 OR NET_TOTAL < 0, 'NEGATIVE_AMOUNT', NULL),
      IFF(TOTAL_DISCOUNT > GROSS_AMOUNT,                                            'DISCOUNT_EXCEEDS_GROSS', NULL),
      IFF(ABS(GROSS_AMOUNT - TOTAL_DISCOUNT + TOTAL_TAX - NET_TOTAL) > 0.01,        'NET_TOTAL_MISMATCH', NULL),
      IFF(SOURCE_SYSTEM IS NULL,                                                    'SOURCE_SYSTEM_MISSING', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY TRANSACTION_SK
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
