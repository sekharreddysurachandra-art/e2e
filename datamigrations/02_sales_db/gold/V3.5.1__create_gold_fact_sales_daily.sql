-- =============================================================================
-- V3.5.1 : Gold FACT_SALES_DAILY - aggregated sales fact (dynamic table)
-- Source  : GOLD.FACT_SALES_LINE (V3.5.0).
-- Grain   : one row per local business date x country x store x product x channel
--           x currency (STORE_SK is NULL for ONLINE sales).
-- Measures: additive sums of the line fact, in CURRENCY_CODE (no FX conversion -
--           never sum across currencies); LINE_COUNT and TRANSACTION_COUNT.
--           Distinct customers are not stored: they do not add up across rows,
--           query FACT_SALES_LINE for them.
-- Key     : SALES_DAILY_SK = MD5 of the grain columns (NULL store = '').
-- Refresh : INCREMENTAL. This is the top of the pipeline, so it carries the one
--           real TARGET_LAG (var: fact_lag, default '1 hour'); every upstream
--           table is DOWNSTREAM and refreshes when this one needs it.
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}
{% set lag = fact_lag | default('1 hour') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.FACT_SALES_DAILY (  -- create only if missing
  SALES_DAILY_SK       VARCHAR(32) NOT NULL COMMENT 'Surrogate key: MD5 of the grain columns (logical PK)',
  DATE_SK              NUMBER(8,0) NOT NULL COMMENT 'FK to GOLD.DIM_DATE (local business date)',
  COUNTRY_SK                                COMMENT 'FK to GOLD.DIM_COUNTRY',
  STORE_SK                                  COMMENT 'FK to GOLD.DIM_STORE (NULL for ONLINE)',
  PRODUCT_SK                                COMMENT 'FK to GOLD.DIM_PRODUCT',
  COUNTRY_CODE                              COMMENT 'ISO 2-letter country code',
  STORE_CODE                                COMMENT 'Store code (NULL for ONLINE)',
  SKU_CODE                                  COMMENT 'SKU code',
  CHANNEL_ID                                COMMENT 'Sales channel (POS, ONLINE)',
  CURRENCY_CODE                             COMMENT 'Currency of all amounts on this row',
  LINE_COUNT                                COMMENT 'Number of sales lines',
  TRANSACTION_COUNT                         COMMENT 'Number of distinct transactions',
  QUANTITY                                  COMMENT 'Units sold',
  GROSS_AMOUNT                              COMMENT 'Gross amount (quantity * unit price)',
  DISCOUNT_AMOUNT                           COMMENT 'Discount amount',
  NET_AMOUNT_EX_TAX                         COMMENT 'Revenue before tax (gross - discount)',
  TAX_AMOUNT                                COMMENT 'Tax amount',
  NET_AMOUNT                                COMMENT 'Net amount incl. tax (gross - discount + tax)',
  WARN_LINE_COUNT                           COMMENT 'Lines with DQ_STATUS = WARN in FACT_SALES_LINE'
)
  TARGET_LAG   = '{{ lag }}'                -- top of the pipeline: drives all DOWNSTREAM tables
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- re-aggregate only changed groups
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Daily sales aggregate by country, store, product, channel and currency'
AS
SELECT
  MD5(CONCAT_WS('|', DATE_SK::VARCHAR, COALESCE(COUNTRY_SK, ''), COALESCE(STORE_SK, ''),
                COALESCE(PRODUCT_SK, ''), COALESCE(CHANNEL_ID, ''), COALESCE(CURRENCY_CODE, '')))  AS SALES_DAILY_SK,
  DATE_SK, COUNTRY_SK, STORE_SK, PRODUCT_SK,
  COUNTRY_CODE, STORE_CODE, SKU_CODE, CHANNEL_ID, CURRENCY_CODE,
  COUNT(*)                         AS LINE_COUNT,
  COUNT(DISTINCT TRANSACTION_SK)   AS TRANSACTION_COUNT,
  SUM(QUANTITY)                    AS QUANTITY,
  SUM(GROSS_AMOUNT)                AS GROSS_AMOUNT,
  SUM(DISCOUNT_AMOUNT)             AS DISCOUNT_AMOUNT,
  SUM(NET_AMOUNT_EX_TAX)           AS NET_AMOUNT_EX_TAX,
  SUM(TAX_AMOUNT)                  AS TAX_AMOUNT,
  SUM(NET_AMOUNT)                  AS NET_AMOUNT,
  COUNT_IF(DQ_STATUS = 'WARN')     AS WARN_LINE_COUNT
FROM SALES_{{ env }}.GOLD.FACT_SALES_LINE
GROUP BY DATE_SK, COUNTRY_SK, STORE_SK, PRODUCT_SK, COUNTRY_CODE, STORE_CODE, SKU_CODE, CHANNEL_ID, CURRENCY_CODE;

-- Post-deploy check (must return one row with equal values):
-- SELECT (SELECT SUM(NET_AMOUNT) FROM SALES_{{ env }}.GOLD.FACT_SALES_LINE),
--        (SELECT SUM(NET_AMOUNT) FROM SALES_{{ env }}.GOLD.FACT_SALES_DAILY);
