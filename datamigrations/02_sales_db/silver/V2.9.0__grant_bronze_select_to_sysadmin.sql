-- =============================================================================
-- V2.9.0 : Let SYSADMIN read Bronze so Silver dynamic tables can refresh
-- Why     : Silver dynamic tables run as their owner SYSADMIN; Bronze tables
--           created by ACCOUNTADMIN were not readable, so refreshes failed with
--           "does not exist or not authorized".
-- Scope   : SELECT on all current and future Bronze tables (read-only).
-- =============================================================================

GRANT SELECT ON ALL TABLES IN SCHEMA SALES_{{ env }}.BRONZE TO ROLE SYSADMIN;     -- existing tables
GRANT SELECT ON FUTURE TABLES IN SCHEMA SALES_{{ env }}.BRONZE TO ROLE SYSADMIN;  -- tables added later
