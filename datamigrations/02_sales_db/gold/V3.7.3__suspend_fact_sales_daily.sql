-- =============================================================================
-- V3.7.3 : Suspend FACT_SALES_DAILY (aggregates start suspended)
-- Runs after V3.7.1 / V3.7.2 so the weekly and monthly aggregates could take
-- their initial data from it. All three aggregates are now suspended; nothing in
-- the pipeline refreshes on its own (every upstream table is DOWNSTREAM).
-- Resume, daily first, when the incremental load is scheduled:
--   ALTER DYNAMIC TABLE SALES_<ENV>.GOLD.FACT_SALES_DAILY   RESUME;
--   ALTER DYNAMIC TABLE SALES_<ENV>.GOLD.FACT_SALES_WEEKLY  RESUME;
--   ALTER DYNAMIC TABLE SALES_<ENV>.GOLD.FACT_SALES_MONTHLY RESUME;
-- =============================================================================

ALTER DYNAMIC TABLE SALES_{{ env }}.GOLD.FACT_SALES_DAILY SUSPEND;   -- start suspended
