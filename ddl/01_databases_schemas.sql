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
