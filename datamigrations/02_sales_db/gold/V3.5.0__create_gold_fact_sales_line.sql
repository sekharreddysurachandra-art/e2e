-- =============================================================================
-- V3.5.0 : Gold FACT_SALES_LINE dynamic table (Silver + Gold dims -> Gold)
-- Grain   : one row per sales transaction line (SILVER.SALES_ITEM), with the
--           header attributes of its transaction (SILVER.SALES_HEADER).
-- Dims    : every dimension is joined so the dynamic table graph / lineage shows
--           DIM_* -> FACT_SALES_LINE, and its surrogate key is stored:
--             DATE_SK / TIME_SK  <- DIM_DATE / DIM_TIME on the LOCAL date / time
--             PRODUCT_SK, PRODUCT_COUNTRY_SK, CUSTOMER_SK, STORE_SK, COUNTRY_SK
--               <- SCD2 dims, the version valid on the local transaction date
--                  (point-in-time: business key + date between start and end).
-- Joins   : equality joins on the business key + QUALIFY on "version valid at
--           the transaction date" (incremental refresh does not allow outer joins
--           with range predicates). Unmatched dates/times get -1; an unmatched
--           SCD2 dim leaves its SK NULL and is listed in DQ_ISSUES. ONLINE sales
--           have no store: STORE_SK is NULL by design (not a DQ issue).
-- Measures: in the transaction currency (CURRENCY_CODE) - there is no FX rate
--           source yet, so amounts of different currencies must not be summed.
-- Key     : SALES_LINE_SK = MD5(TRANSACTION_LINE_ID). Dynamic tables do not allow
--           PRIMARY KEY / FOREIGN KEY constraints; NOT NULL is enforced and key
--           uniqueness is asserted by the check below.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM - refreshed when the aggregated
--           fact FACT_SALES_DAILY (V3.5.1, real time lag) needs it.
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.FACT_SALES_LINE (  -- create only if missing
  SALES_LINE_SK               VARCHAR(32) NOT NULL COMMENT 'Surrogate key: MD5(TRANSACTION_LINE_ID) (logical PK)',
  TRANSACTION_LINE_ID         VARCHAR     NOT NULL COMMENT 'Transaction line id (business key, degenerate)',
  TRANSACTION_SK              VARCHAR     NOT NULL COMMENT 'Transaction key (degenerate dimension)',
  TRANSACTION_ID                                   COMMENT 'Transaction id from the source system (degenerate)',
  LINE_NUMBER                                      COMMENT 'Line number within the transaction',
  DATE_SK                     NUMBER(8,0) NOT NULL COMMENT 'FK to GOLD.DIM_DATE on the local transaction date (-1 = unknown)',
  TIME_SK                     NUMBER(4,0) NOT NULL COMMENT 'FK to GOLD.DIM_TIME on the local transaction minute (-1 = unknown)',
  PRODUCT_SK                                       COMMENT 'FK to GOLD.DIM_PRODUCT (version valid on the transaction date)',
  PRODUCT_COUNTRY_SK                               COMMENT 'FK to GOLD.DIM_PRODUCT_COUNTRY (version valid on the transaction date)',
  CUSTOMER_SK                                      COMMENT 'FK to GOLD.DIM_CUSTOMER (version valid on the transaction date)',
  STORE_SK                                         COMMENT 'FK to GOLD.DIM_STORE (version valid on the transaction date; NULL for ONLINE)',
  COUNTRY_SK                                       COMMENT 'FK to GOLD.DIM_COUNTRY (version valid on the transaction date)',
  SKU_CODE                                         COMMENT 'SKU code (business key of DIM_PRODUCT)',
  CUSTOMER_ID                                      COMMENT 'Customer UUID (business key of DIM_CUSTOMER)',
  STORE_CODE                                       COMMENT 'Store code (business key of DIM_STORE; NULL for ONLINE)',
  COUNTRY_CODE                                     COMMENT 'ISO 2-letter country code (business key of DIM_COUNTRY)',
  CHANNEL_ID                                       COMMENT 'Sales channel (POS, ONLINE)',
  PAYMENT_METHOD                                   COMMENT 'Payment method',
  CURRENCY_CODE                                    COMMENT 'Currency of all amounts on this row',
  TRANSACTION_TIMESTAMP_UTC                        COMMENT 'Transaction timestamp as sent by the source (UTC)',
  TRANSACTION_TIMESTAMP_LOCAL                      COMMENT 'Transaction timestamp in the country local timezone',
  TRANSACTION_DATE_LOCAL                           COMMENT 'Local business date of the transaction',
  QUANTITY                                         COMMENT 'Quantity sold',
  UNIT_PRICE                                       COMMENT 'Unit price before discount and tax',
  GROSS_AMOUNT                                     COMMENT 'Quantity * unit price (before discount and tax)',
  DISCOUNT_AMOUNT                                  COMMENT 'Line discount',
  NET_AMOUNT_EX_TAX                                COMMENT 'Gross amount - discount (revenue before tax)',
  TAX_AMOUNT                                       COMMENT 'Line tax',
  NET_AMOUNT                                       COMMENT 'Line total: gross - discount + tax',
  DQ_STATUS                   VARCHAR(4)  NOT NULL COMMENT 'PASS or WARN (Silver header/item checks + dimension lookups)',
  DQ_ISSUES                                        COMMENT 'List of failed checks (empty when PASS)'
)
  TARGET_LAG   = DOWNSTREAM                -- refreshed when FACT_SALES_DAILY needs it
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = INCREMENTAL               -- process only changed lines / dimension rows
  INITIALIZE   = ON_CREATE                 -- populate immediately
  COMMENT      = 'Sales fact at transaction-line grain with point-in-time keys to all Gold dimensions'
AS
WITH lines AS (
  SELECT
    i.TRANSACTION_LINE_ID, i.TRANSACTION_SK, h.TRANSACTION_ID, i.LINE_NUMBER,
    i.SKU_CODE, h.CUSTOMER_ID, h.STORE_ID AS STORE_CODE, h.COUNTRY_CODE,
    h.CHANNEL_ID, h.PAYMENT_METHOD, h.CURRENCY_CODE,
    h.TRANSACTION_TIMESTAMP AS TRANSACTION_TIMESTAMP_UTC,
    h.TRANSACTION_TIMESTAMP_LOCAL, h.TRANSACTION_DATE_LOCAL,
    i.QUANTITY, i.UNIT_PRICE, i.GROSS_LINE_AMOUNT AS GROSS_AMOUNT, i.DISCOUNT_AMOUNT,
    i.GROSS_LINE_AMOUNT - i.DISCOUNT_AMOUNT AS NET_AMOUNT_EX_TAX,
    i.TAX_AMOUNT, i.LINE_TOTAL AS NET_AMOUNT,
    ARRAY_CAT(h.DQ_ISSUES, i.DQ_ISSUES) AS SILVER_ISSUES
  FROM SALES_{{ env }}.SILVER.SALES_ITEM i
  JOIN SALES_{{ env }}.SILVER.SALES_HEADER h ON h.TRANSACTION_SK = i.TRANSACTION_SK
),
-- Point-in-time lookups, one dimension per step: equality join on the business
-- key, then keep the version valid on the local transaction date.
p AS (
  SELECT l.*,
    COALESCE(l.TRANSACTION_DATE_LOCAL BETWEEN d.EFFECTIVE_START_DATE AND d.EFFECTIVE_END_DATE, FALSE) AS P_OK,
    IFF(P_OK, d.PRODUCT_SK, NULL) AS PRODUCT_SK
  FROM lines l
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_PRODUCT d ON d.SKU_CODE = l.SKU_CODE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.TRANSACTION_LINE_ID ORDER BY P_OK DESC) = 1
),
pc AS (
  SELECT p.*,
    COALESCE(p.TRANSACTION_DATE_LOCAL BETWEEN d.EFFECTIVE_START_DATE AND d.EFFECTIVE_END_DATE, FALSE) AS PC_OK,
    IFF(PC_OK, d.PRODUCT_COUNTRY_SK, NULL) AS PRODUCT_COUNTRY_SK
  FROM p
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_PRODUCT_COUNTRY d
    ON d.SKU_CODE = p.SKU_CODE AND d.COUNTRY_CODE = p.COUNTRY_CODE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY p.TRANSACTION_LINE_ID ORDER BY PC_OK DESC) = 1
),
cu AS (
  SELECT pc.*,
    COALESCE(pc.TRANSACTION_DATE_LOCAL BETWEEN d.EFFECTIVE_START_DATE AND d.EFFECTIVE_END_DATE, FALSE) AS CU_OK,
    IFF(CU_OK, d.CUSTOMER_SK, NULL) AS CUSTOMER_SK
  FROM pc
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_CUSTOMER d ON d.CUSTOMER_ID = pc.CUSTOMER_ID
  QUALIFY ROW_NUMBER() OVER (PARTITION BY pc.TRANSACTION_LINE_ID ORDER BY CU_OK DESC) = 1
),
st AS (
  SELECT cu.*,
    COALESCE(cu.TRANSACTION_DATE_LOCAL BETWEEN d.EFFECTIVE_START_DATE AND d.EFFECTIVE_END_DATE, FALSE) AS ST_OK,
    IFF(ST_OK, d.STORE_SK, NULL) AS STORE_SK
  FROM cu
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_STORE d ON d.STORE_CODE = cu.STORE_CODE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cu.TRANSACTION_LINE_ID ORDER BY ST_OK DESC) = 1
),
co AS (
  SELECT st.*,
    COALESCE(st.TRANSACTION_DATE_LOCAL BETWEEN d.EFFECTIVE_START_DATE AND d.EFFECTIVE_END_DATE, FALSE) AS CO_OK,
    IFF(CO_OK, d.COUNTRY_SK, NULL) AS COUNTRY_SK
  FROM st
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_COUNTRY d ON d.COUNTRY_CODE = st.COUNTRY_CODE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY st.TRANSACTION_LINE_ID ORDER BY CO_OK DESC) = 1
),
dt AS (   -- calendar and time-of-day: plain equality joins
  SELECT co.*,
    dd.DATE_SK AS D_SK,
    tt.TIME_SK AS T_SK
  FROM co
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_DATE dd ON dd.CALENDAR_DATE = co.TRANSACTION_DATE_LOCAL
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_TIME tt
    ON tt.TIME_SK = HOUR(co.TRANSACTION_TIMESTAMP_LOCAL) * 100 + MINUTE(co.TRANSACTION_TIMESTAMP_LOCAL)
)
SELECT
  MD5(TRANSACTION_LINE_ID)                         AS SALES_LINE_SK,
  TRANSACTION_LINE_ID, TRANSACTION_SK, TRANSACTION_ID, LINE_NUMBER,
  COALESCE(D_SK, -1)                               AS DATE_SK,
  COALESCE(T_SK, -1)                               AS TIME_SK,
  PRODUCT_SK, PRODUCT_COUNTRY_SK, CUSTOMER_SK, STORE_SK, COUNTRY_SK,
  SKU_CODE, CUSTOMER_ID, STORE_CODE, COUNTRY_CODE,
  CHANNEL_ID, PAYMENT_METHOD, CURRENCY_CODE,
  TRANSACTION_TIMESTAMP_UTC, TRANSACTION_TIMESTAMP_LOCAL, TRANSACTION_DATE_LOCAL,
  QUANTITY, UNIT_PRICE, GROSS_AMOUNT, DISCOUNT_AMOUNT, NET_AMOUNT_EX_TAX, TAX_AMOUNT, NET_AMOUNT,
  IFF(ARRAY_SIZE(ISSUES) = 0, 'PASS', 'WARN')      AS DQ_STATUS,
  ISSUES                                           AS DQ_ISSUES
FROM (
  SELECT dt.*,
    ARRAY_CAT(SILVER_ISSUES, ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(D_SK IS NULL,                         'DATE_NOT_FOUND', NULL),
      IFF(T_SK IS NULL,                         'TIME_NOT_FOUND', NULL),
      IFF(NOT P_OK,                             'PRODUCT_NOT_FOUND', NULL),
      IFF(NOT PC_OK,                            'PRODUCT_COUNTRY_NOT_FOUND', NULL),
      IFF(NOT CU_OK,                            'CUSTOMER_NOT_FOUND', NULL),
      IFF(STORE_CODE IS NOT NULL AND NOT ST_OK, 'STORE_NOT_FOUND', NULL),
      IFF(NOT CO_OK,                            'COUNTRY_NOT_FOUND', NULL)
    ))) AS ISSUES
  FROM dt
);

-- Post-deploy checks (must return 0 rows):
-- 1. one row per line:   SELECT SALES_LINE_SK FROM SALES_{{ env }}.GOLD.FACT_SALES_LINE GROUP BY 1 HAVING COUNT(*) > 1;
-- 2. no line lost:       SELECT TRANSACTION_LINE_ID FROM SALES_{{ env }}.SILVER.SALES_ITEM
--                        MINUS SELECT TRANSACTION_LINE_ID FROM SALES_{{ env }}.GOLD.FACT_SALES_LINE;
