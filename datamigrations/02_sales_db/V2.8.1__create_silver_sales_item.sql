-- =============================================================================
-- V2.8.1 : Silver SALES_ITEM dynamic table (Bronze -> Silver)
-- Grain   : one row per TRANSACTION_LINE_ID (TRANSACTION_SK + LINE_NUMBER).
-- Dedup   : COPY does not reject duplicates, so the latest copy of a key wins
--           (newest file, then highest row number in that file).
-- Quality : codes trimmed/upper-cased, text trimmed, rows without a key are
--           dropped; record-level checks are exposed in DQ_STATUS / DQ_ISSUES.
-- Notes   : LINE_TOTAL = QUANTITY * UNIT_PRICE - DISCOUNT_AMOUNT + TAX_AMOUNT.
--           Bronze has no SOURCE_SYSTEM column for items.
-- Keeps the 3 Bronze load metadata columns for lineage back to the file.
-- Refresh : INCREMENTAL, TARGET_LAG = DOWNSTREAM (driven by Gold consumers).
-- Dynamic tables in DEV/QA are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}
{% set wh = warehouse | default('COMPUTE_WH') %}

CREATE {{ transient }}DYNAMIC TABLE IF NOT EXISTS SALES_{{ env }}.SILVER.SALES_ITEM (  -- create only if missing
  TRANSACTION_LINE_ID      COMMENT 'Transaction line id (business key)',
  TRANSACTION_SK           COMMENT 'Transaction surrogate key (FK to SILVER.SALES_HEADER)',
  LINE_NUMBER              COMMENT 'Line number within the transaction',
  SKU_CODE                 COMMENT 'SKU code (FK to SILVER.PRODUCT_SKU_MASTER)',
  CATEGORY_CODE            COMMENT 'Product category code (FK to SILVER.PRODUCT_CATEGORY_MASTER)',
  QUANTITY                 COMMENT 'Quantity sold',
  UNIT_PRICE               COMMENT 'Unit price before discount and tax',
  DISCOUNT_AMOUNT          COMMENT 'Line discount',
  TAX_AMOUNT               COMMENT 'Line tax',
  LINE_TOTAL               COMMENT 'Line total (qty * price - discount + tax)',
  CREATED_AT               COMMENT 'Created timestamp in source',
  GROSS_LINE_AMOUNT        COMMENT 'Quantity * unit price (before discount and tax)',
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
  COMMENT      = 'Cleaned, de-duplicated sales transaction item'
AS
WITH cleaned AS (
  SELECT
    UPPER(NULLIF(TRIM(TRANSACTION_LINE_ID), '')) AS TRANSACTION_LINE_ID,
    UPPER(NULLIF(TRIM(TRANSACTION_SK), ''))      AS TRANSACTION_SK,
    LINE_NUMBER,
    UPPER(NULLIF(TRIM(SKU_CODE), ''))            AS SKU_CODE,
    UPPER(NULLIF(TRIM(CATEGORY_CODE), ''))       AS CATEGORY_CODE,
    QUANTITY,
    UNIT_PRICE,
    DISCOUNT_AMOUNT,
    TAX_AMOUNT,
    LINE_TOTAL,
    CREATED_AT,
    __FILE_NAME,
    __ROW_NUMBER,
    __FILE_LAST_MODIFIED_NTZ
  FROM SALES_{{ env }}.BRONZE.SALES_ITEM
  WHERE NULLIF(TRIM(TRANSACTION_LINE_ID), '') IS NOT NULL   -- no business key, no row
)
SELECT
  TRANSACTION_LINE_ID,
  TRANSACTION_SK,
  LINE_NUMBER,
  SKU_CODE,
  CATEGORY_CODE,
  QUANTITY,
  UNIT_PRICE,
  DISCOUNT_AMOUNT,
  TAX_AMOUNT,
  LINE_TOTAL,
  CREATED_AT,
  QUANTITY * UNIT_PRICE                       AS GROSS_LINE_AMOUNT,
  MD5(CONCAT_WS('|', TRANSACTION_LINE_ID,
                COALESCE(TRANSACTION_SK::VARCHAR, ''),
                COALESCE(LINE_NUMBER::VARCHAR, ''),
                COALESCE(SKU_CODE::VARCHAR, ''),
                COALESCE(CATEGORY_CODE::VARCHAR, ''),
                COALESCE(QUANTITY::VARCHAR, ''),
                COALESCE(UNIT_PRICE::VARCHAR, ''),
                COALESCE(DISCOUNT_AMOUNT::VARCHAR, ''),
                COALESCE(TAX_AMOUNT::VARCHAR, ''),
                COALESCE(LINE_TOTAL::VARCHAR, '')))  AS RECORD_HASH,
  IFF(ARRAY_SIZE(DQ_ISSUES) = 0, 'PASS', 'WARN')     AS DQ_STATUS,
  DQ_ISSUES,
  __FILE_NAME,
  __ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ
FROM (
  SELECT
    c.*,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(TRANSACTION_SK IS NULL,                                                        'TRANSACTION_SK_MISSING', NULL),
      IFF(LINE_NUMBER IS NULL OR LINE_NUMBER < 1,                                        'LINE_NUMBER_INVALID', NULL),
      IFF(SKU_CODE IS NULL,                                                              'SKU_CODE_MISSING', NULL),
      IFF(CATEGORY_CODE IS NULL,                                                         'CATEGORY_CODE_MISSING', NULL),
      IFF(QUANTITY IS NULL OR QUANTITY <= 0,                                             'QUANTITY_NOT_POSITIVE', NULL),
      IFF(UNIT_PRICE IS NULL OR UNIT_PRICE < 0,                                          'UNIT_PRICE_INVALID', NULL),
      IFF(DISCOUNT_AMOUNT < 0 OR TAX_AMOUNT < 0 OR LINE_TOTAL < 0,                       'NEGATIVE_AMOUNT', NULL),
      IFF(DISCOUNT_AMOUNT > QUANTITY * UNIT_PRICE,                                       'DISCOUNT_EXCEEDS_GROSS', NULL),
      IFF(ABS(QUANTITY * UNIT_PRICE - DISCOUNT_AMOUNT + TAX_AMOUNT - LINE_TOTAL) > 0.01, 'LINE_TOTAL_MISMATCH', NULL)
    )) AS DQ_ISSUES
  FROM cleaned c
)
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY TRANSACTION_LINE_ID
  ORDER BY __FILE_LAST_MODIFIED_NTZ DESC, __FILE_NAME DESC, __ROW_NUMBER DESC
) = 1;
