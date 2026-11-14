-- =============================================================================
-- V2.0.1 : Medallion schemas (Bronze -> Silver -> Gold) plus Common
-- Schemas in DEV/QA are TRANSIENT; PROD schemas are permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}

-- Bronze: raw data landed from CSV files via COPY
CREATE {{ transient }}SCHEMA IF NOT EXISTS SALES_{{ env }}.BRONZE  -- create only if missing
  COMMENT = 'Raw data landed from CSV files';              -- object purpose

-- Silver: cleaned and curated data (dynamic tables)
CREATE {{ transient }}SCHEMA IF NOT EXISTS SALES_{{ env }}.SILVER  -- create only if missing
  COMMENT = 'Cleaned and curated data';                    -- object purpose

-- Gold: fact and dimension models, aggregates, semantic view
CREATE {{ transient }}SCHEMA IF NOT EXISTS SALES_{{ env }}.GOLD    -- create only if missing
  COMMENT = 'Fact and dimension models';                   -- object purpose

-- Common: shared file formats, sequences, UDFs and procedures
CREATE {{ transient }}SCHEMA IF NOT EXISTS SALES_{{ env }}.COMMON  -- create only if missing
  COMMENT = 'Shared file formats, sequences, UDFs, procedures';  -- object purpose

-- Bronze internal stage for CSV loads (files uploaded with snow stage copy)
CREATE STAGE IF NOT EXISTS SALES_{{ env }}.BRONZE.SALES_CSV_STAGE  -- create only if missing
  DIRECTORY  = (ENABLE = TRUE)                                    -- directory table for file listing
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')                           -- Snowflake-managed encryption
  COMMENT    = 'Internal stage for initial CSV loads';            -- object purpose
