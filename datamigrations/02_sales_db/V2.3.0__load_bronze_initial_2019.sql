-- =============================================================================
-- V2.3.0 : Initial 2019 load of Bronze tables from SALES_CSV_STAGE
-- Files must be uploaded to initial_load/ first (see README).
-- PATTERN is used so an empty stage loads 0 files instead of failing.
-- COPY skips files it has already loaded (load metadata), so re-runs are safe.
-- =============================================================================
{% set stage = '@SALES_' ~ env ~ '.BRONZE.SALES_CSV_STAGE/initial_load/' %}
{% set loads = [
  ('REGION_MASTER',                'country-master/',         'region_master'),
  ('CURRENCY_MASTER',              'country-master/',         'currency_master'),
  ('TAX_MASTER',                   'country-master/',         'tax_master'),
  ('COUNTRY_MASTER',               'country-master/',         'country_master'),
  ('PRODUCT_CATEGORY_MASTER',      'product-master/',         'product_category_master'),
  ('PRODUCT_FAMILY_MASTER',        'product-master/',         'product_family_master'),
  ('PRODUCT_MODEL_MASTER',         'product-master/',         'product_model_master'),
  ('PRODUCT_SKU_MASTER',           'product-master/',         'product_sku_master'),
  ('PRODUCT_COUNTRY_AVAILABILITY', 'product-master/',         'product_country_availability'),
  ('STORE_MASTER',                 'store-master/',           'store_master'),
  ('CUSTOMER_MASTER',              'customer-master/2019/',   'customer_master_2019_[A-Z]{2}'),
  ('SALES_HEADER',                 'sales-transaction/2019/', 'sales_header_2019'),
  ('SALES_ITEM',                   'sales-transaction/2019/', 'sales_item_2019')
] %}

{% for table, folder, file in loads %}
COPY INTO SALES_{{ env }}.BRONZE.{{ table }}                 -- target bronze table
FROM {{ stage }}{{ folder }}                                 -- stage folder
PATTERN = '.*{{ file }}[.]csv([.]gz)?'                       -- 2019 source file(s)
FILE_FORMAT = (FORMAT_NAME = 'SALES_{{ env }}.COMMON.CSV_FF')  -- shared CSV format
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE                      -- map by header name
INCLUDE_METADATA = (                                         -- load metadata columns
  __FILE_NAME              = METADATA$FILENAME,
  __ROW_NUMBER             = METADATA$FILE_ROW_NUMBER,
  __FILE_LAST_MODIFIED_NTZ = METADATA$FILE_LAST_MODIFIED)
ON_ERROR = ABORT_STATEMENT;                                  -- fail on any bad row
{% endfor %}
