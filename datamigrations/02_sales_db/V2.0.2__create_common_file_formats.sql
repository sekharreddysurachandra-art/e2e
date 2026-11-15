-- =============================================================================
-- V2.0.2 : Shared file formats in the COMMON schema (architecture rule 2)
-- CSV_FF parses the header so COPY can match columns by name and INFER_SCHEMA
-- can read column names. COMPRESSION defaults to AUTO, so .csv.gz files load.
-- =============================================================================

CREATE FILE FORMAT IF NOT EXISTS SALES_{{ env }}.COMMON.CSV_FF  -- create only if missing
  TYPE                           = CSV               -- comma separated values
  PARSE_HEADER                   = TRUE              -- first row holds column names
  TRIM_SPACE                     = TRUE              -- strip leading/trailing spaces
  FIELD_OPTIONALLY_ENCLOSED_BY   = '"'               -- quoted fields allowed
  NULL_IF                        = ('', 'NULL', 'null')  -- treat these as NULL
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE             -- tolerate extra/missing columns
  COMMENT = 'CSV with header for source file loads';  -- object purpose
