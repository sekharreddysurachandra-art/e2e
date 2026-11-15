-- =============================================================================
-- V3.7.2 : Gold FACT_SALES_MONTHLY - monthly sales aggregate (dynamic table)
-- Source  : GOLD.FACT_SALES_DAILY (rolled up, not re-read from the line fact),
--           joined to GOLD.DIM_DATE for the month of each day (lineage link).
-- Month   : calendar month. MONTH_START_DATE_SK (YYYYMMDD of the 1st) joins
--           DIM_DATE; YEAR_MONTH (YYYY-MM) labels it. Calendar quarters and
--           years roll up from here. Apple fiscal quarters do not (they end on
--           a Saturday, not a month end) - use DIM_DATE.FISCAL_* on the daily
--           aggregate for fiscal reporting.
-- Grain   : month x country x store x product x channel x currency.
-- Measures: sums of the daily measures, in CURRENCY_CODE (no FX - never sum
--           across currencies). TRANSACTION_COUNT is a sum of daily counts.
-- Key     : SALES_MONTHLY_SK = MD5 of the grain columns.
-- Refresh : INCREMENTAL, TARGET_LAG = 24 hours (var: monthly_lag); created
--           populated, then SUSPENDED - resume with ALTER ... RESUME.
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}
{% set lag = monthly_lag | default('24 hours') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.FACT_SALES_MONTHLY (  -- create only if missing
  SALES_MONTHLY_SK     VARCHAR(32) NOT NULL COMMENT 'Surrogate key: MD5 of the grain columns (logical PK)',
  MONTH_START_DATE_SK  NUMBER(8,0) NOT NULL COMMENT 'FK to GOLD.DIM_DATE: first day of the month (YYYYMMDD)',
  YEAR_MONTH                                COMMENT 'Calendar year and month (YYYY-MM)',
  CALENDAR_YEAR                             COMMENT 'Calendar year',
  MONTH_NUMBER                              COMMENT 'Calendar month (1-12)',
  MONTH_START_DATE                          COMMENT 'First day of the calendar month',
  COUNTRY_SK                                COMMENT 'FK to GOLD.DIM_COUNTRY',
  STORE_SK                                  COMMENT 'FK to GOLD.DIM_STORE (NULL for ONLINE)',
  PRODUCT_SK                                COMMENT 'FK to GOLD.DIM_PRODUCT',
  COUNTRY_CODE                              COMMENT 'ISO 2-letter country code',
  STORE_CODE                                COMMENT 'Store code (NULL for ONLINE)',
  SKU_CODE                                  COMMENT 'SKU code',
  CHANNEL_ID                                COMMENT 'Sales channel (POS, ONLINE)',
  CURRENCY_CODE                             COMMENT 'Currency of all amounts on this row',
  SALES_DAYS                                COMMENT 'Number of days in the month with sales for this row',
  LINE_COUNT                                COMMENT 'Number of sales lines',
  TRANSACTION_COUNT                         COMMENT 'Number of transactions (sum of daily counts)',
  QUANTITY                                  COMMENT 'Units sold',
  GROSS_AMOUNT                              COMMENT 'Gross amount (quantity * unit price)',
  DISCOUNT_AMOUNT                           COMMENT 'Discount amount',
  NET_AMOUNT_EX_TAX                         COMMENT 'Revenue before tax (gross - discount)',
  TAX_AMOUNT                                COMMENT 'Tax amount',
  NET_AMOUNT                                COMMENT 'Net amount incl. tax (gross - discount + tax)',
  WARN_LINE_COUNT                           COMMENT 'Lines with DQ_STATUS = WARN in FACT_SALES_LINE'
)
  TARGET_LAG   = '{{ lag }}'                -- daily refresh (var: monthly_lag)
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- re-aggregate only changed months
  INITIALIZE   = ON_CREATE                 -- populate immediately, then suspend below
  COMMENT      = 'Monthly (calendar month) sales aggregate by country, store, product, channel and currency'
AS
SELECT
  MD5(CONCAT_WS('|', TO_CHAR(d.MONTH_START_DATE, 'YYYYMMDD'), COALESCE(f.COUNTRY_SK, ''), COALESCE(f.STORE_SK, ''),
                COALESCE(f.PRODUCT_SK, ''), COALESCE(f.CHANNEL_ID, ''), COALESCE(f.CURRENCY_CODE, '')))  AS SALES_MONTHLY_SK,
  TO_NUMBER(TO_CHAR(d.MONTH_START_DATE, 'YYYYMMDD'))  AS MONTH_START_DATE_SK,
  d.YEAR_MONTH, d.CALENDAR_YEAR, d.MONTH_NUMBER, d.MONTH_START_DATE,
  f.COUNTRY_SK, f.STORE_SK, f.PRODUCT_SK,
  f.COUNTRY_CODE, f.STORE_CODE, f.SKU_CODE, f.CHANNEL_ID, f.CURRENCY_CODE,
  COUNT(*)                     AS SALES_DAYS,
  SUM(f.LINE_COUNT)            AS LINE_COUNT,
  SUM(f.TRANSACTION_COUNT)     AS TRANSACTION_COUNT,
  SUM(f.QUANTITY)              AS QUANTITY,
  SUM(f.GROSS_AMOUNT)          AS GROSS_AMOUNT,
  SUM(f.DISCOUNT_AMOUNT)       AS DISCOUNT_AMOUNT,
  SUM(f.NET_AMOUNT_EX_TAX)     AS NET_AMOUNT_EX_TAX,
  SUM(f.TAX_AMOUNT)            AS TAX_AMOUNT,
  SUM(f.NET_AMOUNT)            AS NET_AMOUNT,
  SUM(f.WARN_LINE_COUNT)       AS WARN_LINE_COUNT
FROM SALES_{{ env }}.GOLD.FACT_SALES_DAILY f
JOIN SALES_{{ env }}.GOLD.DIM_DATE d ON d.DATE_SK = f.DATE_SK
GROUP BY d.MONTH_START_DATE, d.YEAR_MONTH, d.CALENDAR_YEAR, d.MONTH_NUMBER,
         f.COUNTRY_SK, f.STORE_SK, f.PRODUCT_SK, f.COUNTRY_CODE, f.STORE_CODE, f.SKU_CODE, f.CHANNEL_ID, f.CURRENCY_CODE;

ALTER DYNAMIC TABLE SALES_{{ env }}.GOLD.FACT_SALES_MONTHLY SUSPEND;   -- start suspended

-- Post-deploy check (both sums must be equal):
-- SELECT (SELECT SUM(NET_AMOUNT) FROM SALES_{{ env }}.GOLD.FACT_SALES_DAILY  WHERE DATE_SK <> -1),
--        (SELECT SUM(NET_AMOUNT) FROM SALES_{{ env }}.GOLD.FACT_SALES_MONTHLY);
