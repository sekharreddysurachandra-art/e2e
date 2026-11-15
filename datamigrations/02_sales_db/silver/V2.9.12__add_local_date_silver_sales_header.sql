-- =============================================================================
-- V2.9.12 : Silver SALES_HEADER adds local transaction time and date
-- Why     : the source TRANSACTION_TIMESTAMP has no timezone, but the hour-of-day
--           pattern per country shows it is UTC (e.g. Japan peaks at 02:00 =
--           11:00 Tokyo, Mexico at 00:00 = 18:00 local). The UTC date put 24
--           US/CA/MX sales of 31 Dec 2019 (local) on 2020-01-01, and 12 Asia/
--           Pacific sales on the wrong side of a year boundary.
-- Adds    : TRANSACTION_TIMESTAMP_LOCAL / TRANSACTION_DATE_LOCAL, converted with
--           the country's TIMEZONE from the latest SILVER.COUNTRY_MASTER version.
--           Gold facts use the local date for DIM_DATE. TRANSACTION_DATE stays
--           the UTC date (unchanged). Unknown timezone -> local = UTC, flagged
--           TIMEZONE_UNKNOWN.
-- Grain, dedup and other checks are unchanged from V2.8.0.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM. CREATE OR ALTER evolves the
--           table in place (one reinitialisation; run a manual refresh after).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE OR ALTER {{ transient }}DYNAMIC TABLE SALES_{{ env }}.SILVER.SALES_HEADER (  -- create or evolve in place
  TRANSACTION_SK           COMMENT 'Transaction surrogate key (business key)',
  TRANSACTION_ID           COMMENT 'Transaction id from the source system',
  TRANSACTION_TIMESTAMP    COMMENT 'Transaction timestamp as sent by the source (UTC, inferred)',
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
  TRANSACTION_DATE         COMMENT 'Date part of TRANSACTION_TIMESTAMP (UTC date)',
  RECORD_HASH              COMMENT 'MD5 of business attributes for change detection',
  DQ_STATUS                COMMENT 'PASS or WARN from record-level quality checks',
  DQ_ISSUES                COMMENT 'List of failed quality checks (empty when PASS)',
  __FILE_NAME              COMMENT 'Stage file the row was loaded from',
  __ROW_NUMBER             COMMENT 'Row number within the source file',
  __FILE_LAST_MODIFIED_NTZ COMMENT 'Last modified time of the source file',
  TIMEZONE                 COMMENT 'Country timezone used for the local conversion (SILVER.COUNTRY_MASTER)',
  TRANSACTION_TIMESTAMP_LOCAL COMMENT 'Transaction time in the country local timezone',
  TRANSACTION_DATE_LOCAL   COMMENT 'Local business date of the transaction (joins GOLD.DIM_DATE)'
)
  TARGET_LAG   = DOWNSTREAM                -- refresh only when downstream needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed Bronze rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Cleaned, de-duplicated sales transaction header with local business date'
AS
WITH tz AS (   -- current timezone per country
  SELECT COUNTRY_CODE, TIMEZONE
  FROM SALES_{{ env }}.SILVER.COUNTRY_MASTER
  WHERE IS_LATEST
),
cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(b.TRANSACTION_SK), '')) AS TRANSACTION_SK,
    UPPER(NULLIF(TRIM(b.TRANSACTION_ID), '')) AS TRANSACTION_ID,
    b.TRANSACTION_TIMESTAMP,
    LOWER(NULLIF(TRIM(b.CUSTOMER_ID), ''))    AS CUSTOMER_ID,
    UPPER(NULLIF(TRIM(b.STORE_ID), ''))       AS STORE_ID,
    UPPER(NULLIF(TRIM(b.CHANNEL_ID), ''))     AS CHANNEL_ID,
    UPPER(NULLIF(TRIM(b.COUNTRY_CODE), ''))   AS COUNTRY_CODE,
    NULLIF(TRIM(b.PAYMENT_METHOD), '')        AS PAYMENT_METHOD,
    UPPER(NULLIF(TRIM(b.CURRENCY), ''))       AS CURRENCY_CODE,
    b.GROSS_AMOUNT,
    b.TOTAL_DISCOUNT,
    b.TOTAL_TAX,
    b.NET_TOTAL,
    b.CREATED_AT,
    UPPER(NULLIF(TRIM(b.SOURCE_SYSTEM), ''))  AS SOURCE_SYSTEM,
    tz.TIMEZONE,
    IFF(tz.TIMEZONE IS NULL, b.TRANSACTION_TIMESTAMP,
        CONVERT_TIMEZONE('UTC', tz.TIMEZONE, b.TRANSACTION_TIMESTAMP)) AS TRANSACTION_TIMESTAMP_LOCAL,
    b.__FILE_NAME,
    b.__ROW_NUMBER,
    b.__FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.SALES_HEADER b
  LEFT JOIN tz ON tz.COUNTRY_CODE = UPPER(NULLIF(TRIM(b.COUNTRY_CODE), ''))
  WHERE NULLIF(TRIM(b.TRANSACTION_SK), '') IS NOT NULL   -- no business key, no row
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
  __FILE_LAST_MODIFIED_NTZ,
  TIMEZONE,
  TRANSACTION_TIMESTAMP_LOCAL,
  TRANSACTION_TIMESTAMP_LOCAL::DATE           AS TRANSACTION_DATE_LOCAL
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
      IFF(SOURCE_SYSTEM IS NULL,                                                    'SOURCE_SYSTEM_MISSING', NULL),
      IFF(TIMEZONE IS NULL,                                                         'TIMEZONE_UNKNOWN', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY TRANSACTION_SK
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
