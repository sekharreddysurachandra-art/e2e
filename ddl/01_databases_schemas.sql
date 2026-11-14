-- Apple sales analytics: databases, schemas and common objects
-- Rules: CREATE IF NOT EXISTS, meaningful comments, dev/qa transient
USE ROLE SYSADMIN;

-- Governance database (tags, masking and other policies)
CREATE DATABASE IF NOT EXISTS GOVERNANCE COMMENT = 'Governance objects: tags, masking and other policies';
CREATE SCHEMA IF NOT EXISTS GOVERNANCE.TAGS COMMENT = 'Tags for classification and chargeback';
CREATE SCHEMA IF NOT EXISTS GOVERNANCE.POLICIES COMMENT = 'Masking, row access and other policies';

-- DEV (transient: no fail-safe cost)
CREATE TRANSIENT DATABASE IF NOT EXISTS SALES_DEV COMMENT = 'Apple sales analytics - development';
CREATE TRANSIENT SCHEMA IF NOT EXISTS SALES_DEV.BRONZE COMMENT = 'Raw data landed from CSV files';
CREATE TRANSIENT SCHEMA IF NOT EXISTS SALES_DEV.SILVER COMMENT = 'Cleaned and curated data';
CREATE TRANSIENT SCHEMA IF NOT EXISTS SALES_DEV.GOLD COMMENT = 'Fact and dimension models';
CREATE TRANSIENT SCHEMA IF NOT EXISTS SALES_DEV.COMMON COMMENT = 'Shared file formats, sequences, UDFs, procedures';

-- QA (transient: no fail-safe cost)
CREATE TRANSIENT DATABASE IF NOT EXISTS SALES_QA COMMENT = 'Apple sales analytics - QA for business validation';
CREATE TRANSIENT SCHEMA IF NOT EXISTS SALES_QA.BRONZE COMMENT = 'Raw data landed from CSV files';
CREATE TRANSIENT SCHEMA IF NOT EXISTS SALES_QA.SILVER COMMENT = 'Cleaned and curated data';
CREATE TRANSIENT SCHEMA IF NOT EXISTS SALES_QA.GOLD COMMENT = 'Fact and dimension models';
CREATE TRANSIENT SCHEMA IF NOT EXISTS SALES_QA.COMMON COMMENT = 'Shared file formats, sequences, UDFs, procedures';

-- PROD (permanent)
CREATE DATABASE IF NOT EXISTS SALES_PROD COMMENT = 'Apple sales analytics - production';
CREATE SCHEMA IF NOT EXISTS SALES_PROD.BRONZE COMMENT = 'Raw data landed from CSV files';
CREATE SCHEMA IF NOT EXISTS SALES_PROD.SILVER COMMENT = 'Cleaned and curated data';
CREATE SCHEMA IF NOT EXISTS SALES_PROD.GOLD COMMENT = 'Fact and dimension models';
CREATE SCHEMA IF NOT EXISTS SALES_PROD.COMMON COMMENT = 'Shared file formats, sequences, UDFs, procedures';

-- CSV file format in each COMMON schema (PARSE_HEADER supports INFER_SCHEMA)
CREATE FILE FORMAT IF NOT EXISTS SALES_DEV.COMMON.CSV_FF
  TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE EMPTY_FIELD_AS_NULL = TRUE NULL_IF = ('', 'NULL', 'null')
  COMMENT = 'CSV with header for source file loads';
CREATE FILE FORMAT IF NOT EXISTS SALES_QA.COMMON.CSV_FF
  TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE EMPTY_FIELD_AS_NULL = TRUE NULL_IF = ('', 'NULL', 'null')
  COMMENT = 'CSV with header for source file loads';
CREATE FILE FORMAT IF NOT EXISTS SALES_PROD.COMMON.CSV_FF
  TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE EMPTY_FIELD_AS_NULL = TRUE NULL_IF = ('', 'NULL', 'null')
  COMMENT = 'CSV with header for source file loads';
-- CSV_FF has COMPRESSION = AUTO, so gzip (.csv.gz) files from the stage are read without changes.

-- Internal stage for the initial CSV load (DEV)
CREATE STAGE IF NOT EXISTS SALES_DEV.BRONZE.SALES_CSV_STAGE
  DIRECTORY = (ENABLE = TRUE) ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Internal stage for initial CSV loads';

-- -----------------------------------------------------------------------------
-- Initial load: upload local __initial_load/ files to the stage (snow CLI).
-- Run from the repo root. Stage path mirrors the local folders under initial_load/.
-- Files are uploaded one at a time; Zone.Identifier and .DS_Store files are skipped.
-- The OAuth connection PD77583 failed with S3 HTTP 400, so PD77583_SNOW was used.
-- -----------------------------------------------------------------------------
-- snow connection test -c PD77583_SNOW
-- STAGE=@SALES_DEV.BRONZE.SALES_CSV_STAGE/initial_load
-- OPTS="--parallel 10 --auto-compress -c PD77583_SNOW"
--
-- # country-master (4 files)
-- for f in region_master currency_master tax_master country_master; do
--   snow stage copy __initial_load/country-master/$f.csv $STAGE/country-master/ $OPTS
-- done
--
-- # product-master (5 files)
-- for f in product_category_master product_family_master product_model_master \
--          product_sku_master product_country_availability; do
--   snow stage copy __initial_load/product-master/$f.csv $STAGE/product-master/ $OPTS
-- done
--
-- # store-master (1 file)
-- snow stage copy __initial_load/store-master/store_master.csv $STAGE/store-master/ $OPTS
--
-- # customer-master: 2019 only, partitioned by year/country code (35 files)
-- for d in __initial_load/customer-master/2019/*/; do
--   cc=$(basename "$d")
--   snow stage copy "$d"customer_master_2019_$cc.csv $STAGE/customer-master/2019/$cc/ $OPTS
-- done
--
-- # sales-transaction: 2019 only, partitioned by year (2 files)
-- for f in sales_header_2019 sales_item_2019; do
--   snow stage copy __initial_load/sales-transaction/2019/$f.csv $STAGE/sales-transaction/2019/ $OPTS
-- done
--
-- snow stage list-files @SALES_DEV.BRONZE.SALES_CSV_STAGE/initial_load/ -c PD77583_SNOW

-- Validation: refresh the directory table, then check files per folder
ALTER STAGE SALES_DEV.BRONZE.SALES_CSV_STAGE REFRESH;
SELECT SPLIT_PART(RELATIVE_PATH, '/', 2) AS folder, COUNT(*) AS files
  FROM DIRECTORY(@SALES_DEV.BRONZE.SALES_CSV_STAGE) GROUP BY 1 ORDER BY 1;
-- Line counts for country-master (compare with: wc -l __initial_load/country-master/*.csv)
SELECT SPLIT_PART(METADATA$FILENAME, '/', -1) AS file, COUNT(*) AS line_count
  FROM @SALES_DEV.BRONZE.SALES_CSV_STAGE/initial_load/country-master/ GROUP BY 1 ORDER BY 1;
