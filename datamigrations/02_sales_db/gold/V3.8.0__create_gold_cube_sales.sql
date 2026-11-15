-- =============================================================================
-- V3.8.0 : Gold CUBE_SALES - pre-computed sales cube (dynamic table)
-- Source  : GOLD.FACT_SALES_LINE joined to DIM_DATE, DIM_COUNTRY, DIM_PRODUCT
--           and DIM_CUSTOMER (attributes as at the sale date - the SCD2 version
--           stored on the fact), so lineage shows fact + dims -> cube.
-- Hierarchies (every combination of levels is pre-computed):
--   Time     : ALL | CALENDAR_YEAR > CALENDAR_QUARTER > CALENDAR_MONTH
--                  | FISCAL_YEAR > FISCAL_QUARTER (Apple fiscal calendar)
--              calendar and fiscal levels are alternatives, never mixed in a row
--   Geography: ALL > REGION > COUNTRY
--   Channel  : ALL > CHANNEL (POS, ONLINE)
--   Product  : ALL > CATEGORY > FAMILY
--   Customer : ALL > CUSTOMER_SEGMENT
--   Currency : always grouped - amounts are in local currency, no FX yet
--   = 6 x 3 x 2 x 3 x 2 = 216 groupings per currency (~359k rows for 2019).
-- How to query: filter every *_LEVEL column, e.g. TIME_LEVEL = 'CALENDAR_MONTH'
--   AND GEO_LEVEL = 'COUNTRY' AND CHANNEL_LEVEL = 'ALL' AND PRODUCT_LEVEL =
--   'CATEGORY' AND CUSTOMER_LEVEL = 'ALL'. A NULL member means "all" only when
--   its level says so (NULL store / ONLINE never appears - no store level).
-- Measures: sums plus exact distinct counts per cell (transactions, customers)
--   and ratios computed per cell - do NOT add counts or ratios across cells.
-- Build   : Snowflake allows at most 128 grouping sets per GROUP BY, so the cube
--   is one UNION ALL branch per time level (36 groupings each) over one base.
-- Refresh : GROUPING SETS / ROLLUP cannot refresh incrementally, so this is
--   REFRESH_MODE = FULL, TARGET_LAG = 24 hours (var: cube_lag); created
--   populated, then SUSPENDED like the aggregates - resume with ALTER ... RESUME.
-- Key     : CUBE_SK = MD5 of the level and member columns (logical PK).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}
{% set lag = cube_lag | default('24 hours') %}
{% set time_cols = [('CALENDAR_YEAR', 'NUMBER'), ('YEAR_QUARTER', 'VARCHAR'), ('YEAR_MONTH', 'VARCHAR'),
                    ('FISCAL_YEAR', 'NUMBER'), ('FISCAL_YEAR_QUARTER', 'VARCHAR')] %}
{% set time_levels = [('ALL', []),
                      ('CALENDAR_YEAR', ['CALENDAR_YEAR']),
                      ('CALENDAR_QUARTER', ['CALENDAR_YEAR', 'YEAR_QUARTER']),
                      ('CALENDAR_MONTH', ['CALENDAR_YEAR', 'YEAR_QUARTER', 'YEAR_MONTH']),
                      ('FISCAL_YEAR', ['FISCAL_YEAR']),
                      ('FISCAL_QUARTER', ['FISCAL_YEAR', 'FISCAL_YEAR_QUARTER'])] %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.CUBE_SALES (  -- create only if missing
  CUBE_SK              VARCHAR(32) NOT NULL COMMENT 'Surrogate key: MD5 of level and member columns (logical PK)',
  TIME_LEVEL           VARCHAR     NOT NULL COMMENT 'ALL, CALENDAR_YEAR, CALENDAR_QUARTER, CALENDAR_MONTH, FISCAL_YEAR or FISCAL_QUARTER',
  GEO_LEVEL            VARCHAR     NOT NULL COMMENT 'ALL, REGION or COUNTRY',
  CHANNEL_LEVEL        VARCHAR     NOT NULL COMMENT 'ALL or CHANNEL',
  PRODUCT_LEVEL        VARCHAR     NOT NULL COMMENT 'ALL, CATEGORY or FAMILY',
  CUSTOMER_LEVEL       VARCHAR     NOT NULL COMMENT 'ALL or SEGMENT',
  CURRENCY_CODE        VARCHAR     NOT NULL COMMENT 'Currency of all amounts on this row (always grouped)',
  CALENDAR_YEAR                             COMMENT 'Calendar year (NULL above calendar levels)',
  YEAR_QUARTER                              COMMENT 'Calendar quarter YYYY-Qn (NULL above quarter level)',
  YEAR_MONTH                                COMMENT 'Calendar month YYYY-MM (NULL above month level)',
  FISCAL_YEAR                               COMMENT 'Apple fiscal year (NULL unless a fiscal time level)',
  FISCAL_YEAR_QUARTER                       COMMENT 'Apple fiscal quarter FYyyyy-Qn (NULL above fiscal quarter level)',
  REGION_CODE                               COMMENT 'Sales region code (NULL when GEO_LEVEL = ALL)',
  COUNTRY_CODE                              COMMENT 'ISO 2-letter country code (NULL above country level)',
  CHANNEL_ID                                COMMENT 'Sales channel POS / ONLINE (NULL when CHANNEL_LEVEL = ALL)',
  CATEGORY_NAME                             COMMENT 'Product category (NULL when PRODUCT_LEVEL = ALL)',
  FAMILY_NAME                               COMMENT 'Product family (NULL above family level)',
  CUSTOMER_SEGMENT                          COMMENT 'Customer segment (NULL when CUSTOMER_LEVEL = ALL)',
  LINE_COUNT                                COMMENT 'Number of sales lines',
  TRANSACTION_COUNT                         COMMENT 'Distinct transactions in the cell (exact, not additive across cells)',
  CUSTOMER_COUNT                            COMMENT 'Distinct customers in the cell (exact, not additive across cells)',
  QUANTITY                                  COMMENT 'Units sold',
  GROSS_AMOUNT                              COMMENT 'Gross amount (quantity * unit price)',
  DISCOUNT_AMOUNT                           COMMENT 'Discount amount',
  NET_AMOUNT_EX_TAX                         COMMENT 'Revenue before tax (gross - discount)',
  TAX_AMOUNT                                COMMENT 'Tax amount',
  NET_AMOUNT                                COMMENT 'Net amount incl. tax (gross - discount + tax)',
  AVG_ORDER_VALUE                           COMMENT 'NET_AMOUNT / TRANSACTION_COUNT for the cell',
  DISCOUNT_PCT                              COMMENT 'DISCOUNT_AMOUNT / GROSS_AMOUNT * 100 for the cell',
  UNITS_PER_TRANSACTION                     COMMENT 'QUANTITY / TRANSACTION_COUNT for the cell'
)
  TARGET_LAG   = '{{ lag }}'                -- daily refresh (var: cube_lag)
  WAREHOUSE    = {{ wh }}                -- refresh compute (var: warehouse)
  REFRESH_MODE = FULL                      -- GROUPING SETS / ROLLUP are not incremental
  INITIALIZE   = ON_CREATE                 -- populate immediately, then suspend below
  COMMENT      = 'Sales cube: time x geography x channel x product x customer segment, all hierarchy levels pre-computed per currency'
AS
WITH base AS (
  SELECT
    f.CURRENCY_CODE,
    d.CALENDAR_YEAR, d.YEAR_QUARTER, d.YEAR_MONTH, d.FISCAL_YEAR, d.FISCAL_YEAR_QUARTER,
    c.REGION_CODE, f.COUNTRY_CODE, f.CHANNEL_ID,
    p.CATEGORY_NAME, p.FAMILY_NAME,
    cu.CUSTOMER_SEGMENT,
    f.TRANSACTION_SK, f.CUSTOMER_ID,
    f.QUANTITY, f.GROSS_AMOUNT, f.DISCOUNT_AMOUNT, f.NET_AMOUNT_EX_TAX, f.TAX_AMOUNT, f.NET_AMOUNT
  FROM SALES_{{ env }}.GOLD.FACT_SALES_LINE f
  JOIN SALES_{{ env }}.GOLD.DIM_DATE d          ON d.DATE_SK = f.DATE_SK
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_COUNTRY c  ON c.COUNTRY_SK = f.COUNTRY_SK
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_PRODUCT p  ON p.PRODUCT_SK = f.PRODUCT_SK
  LEFT JOIN SALES_{{ env }}.GOLD.DIM_CUSTOMER cu ON cu.CUSTOMER_SK = f.CUSTOMER_SK
),
cells AS (
{% for level, cols in time_levels %}
  {{ 'UNION ALL' if not loop.first }}
  SELECT
    '{{ level }}'                                                     AS TIME_LEVEL,
    CASE GROUPING(REGION_CODE, COUNTRY_CODE) WHEN 0 THEN 'COUNTRY' WHEN 1 THEN 'REGION' ELSE 'ALL' END AS GEO_LEVEL,
    IFF(GROUPING(CHANNEL_ID) = 0, 'CHANNEL', 'ALL')                     AS CHANNEL_LEVEL,
    CASE GROUPING(CATEGORY_NAME, FAMILY_NAME) WHEN 0 THEN 'FAMILY' WHEN 1 THEN 'CATEGORY' ELSE 'ALL' END AS PRODUCT_LEVEL,
    IFF(GROUPING(CUSTOMER_SEGMENT) = 0, 'SEGMENT', 'ALL')               AS CUSTOMER_LEVEL,
    CURRENCY_CODE,
{% for col, typ in time_cols %}
    {{ col if col in cols else 'NULL::' ~ typ }} AS {{ col }},
{% endfor %}
    REGION_CODE, COUNTRY_CODE, CHANNEL_ID, CATEGORY_NAME, FAMILY_NAME, CUSTOMER_SEGMENT,
    COUNT(*)                        AS LINE_COUNT,
    COUNT(DISTINCT TRANSACTION_SK)  AS TRANSACTION_COUNT,
    COUNT(DISTINCT CUSTOMER_ID)     AS CUSTOMER_COUNT,
    SUM(QUANTITY)                   AS QUANTITY,
    SUM(GROSS_AMOUNT)               AS GROSS_AMOUNT,
    SUM(DISCOUNT_AMOUNT)            AS DISCOUNT_AMOUNT,
    SUM(NET_AMOUNT_EX_TAX)          AS NET_AMOUNT_EX_TAX,
    SUM(TAX_AMOUNT)                 AS TAX_AMOUNT,
    SUM(NET_AMOUNT)                 AS NET_AMOUNT
  FROM base
  GROUP BY CURRENCY_CODE{% for col in cols %}, {{ col }}{% endfor %},
    ROLLUP(REGION_CODE, COUNTRY_CODE), ROLLUP(CHANNEL_ID), ROLLUP(CATEGORY_NAME, FAMILY_NAME), ROLLUP(CUSTOMER_SEGMENT)
{% endfor %}
)
SELECT
  MD5(CONCAT_WS('|', TIME_LEVEL, GEO_LEVEL, CHANNEL_LEVEL, PRODUCT_LEVEL, CUSTOMER_LEVEL, CURRENCY_CODE,
                COALESCE(CALENDAR_YEAR::VARCHAR, ''), COALESCE(YEAR_QUARTER, ''), COALESCE(YEAR_MONTH, ''),
                COALESCE(FISCAL_YEAR::VARCHAR, ''), COALESCE(FISCAL_YEAR_QUARTER, ''),
                COALESCE(REGION_CODE, ''), COALESCE(COUNTRY_CODE, ''), COALESCE(CHANNEL_ID, ''),
                COALESCE(CATEGORY_NAME, ''), COALESCE(FAMILY_NAME, ''), COALESCE(CUSTOMER_SEGMENT, '')))  AS CUBE_SK,
  TIME_LEVEL, GEO_LEVEL, CHANNEL_LEVEL, PRODUCT_LEVEL, CUSTOMER_LEVEL, CURRENCY_CODE,
  CALENDAR_YEAR, YEAR_QUARTER, YEAR_MONTH, FISCAL_YEAR, FISCAL_YEAR_QUARTER,
  REGION_CODE, COUNTRY_CODE, CHANNEL_ID, CATEGORY_NAME, FAMILY_NAME, CUSTOMER_SEGMENT,
  LINE_COUNT, TRANSACTION_COUNT, CUSTOMER_COUNT, QUANTITY,
  GROSS_AMOUNT, DISCOUNT_AMOUNT, NET_AMOUNT_EX_TAX, TAX_AMOUNT, NET_AMOUNT,
  ROUND(NET_AMOUNT / NULLIF(TRANSACTION_COUNT, 0), 2)          AS AVG_ORDER_VALUE,
  ROUND(DISCOUNT_AMOUNT / NULLIF(GROSS_AMOUNT, 0) * 100, 2)    AS DISCOUNT_PCT,
  ROUND(QUANTITY / NULLIF(TRANSACTION_COUNT, 0), 2)            AS UNITS_PER_TRANSACTION
FROM cells;

ALTER DYNAMIC TABLE SALES_{{ env }}.GOLD.CUBE_SALES SUSPEND;   -- start suspended like the aggregates

-- Post-deploy checks:
-- 1. keys unique:    SELECT CUBE_SK FROM SALES_{{ env }}.GOLD.CUBE_SALES GROUP BY 1 HAVING COUNT(*) > 1;   -- 0 rows
-- 2. grand total per currency equals the line fact:
--    SELECT c.CURRENCY_CODE, c.NET_AMOUNT, f.NET_AMOUNT
--    FROM SALES_{{ env }}.GOLD.CUBE_SALES c
--    JOIN (SELECT CURRENCY_CODE, SUM(NET_AMOUNT) NET_AMOUNT FROM SALES_{{ env }}.GOLD.FACT_SALES_LINE GROUP BY 1) f
--      ON f.CURRENCY_CODE = c.CURRENCY_CODE
--    WHERE c.TIME_LEVEL = 'ALL' AND c.GEO_LEVEL = 'ALL' AND c.CHANNEL_LEVEL = 'ALL'
--      AND c.PRODUCT_LEVEL = 'ALL' AND c.CUSTOMER_LEVEL = 'ALL' AND c.NET_AMOUNT <> f.NET_AMOUNT;          -- 0 rows
