-- =============================================================================
-- V3.7.0 : FACT_SALES_DAILY - refresh every 24 hours
-- Why     : the daily aggregate (V3.5.1) was created with a 1-hour lag; daily
--           data only needs a daily refresh. Changing TARGET_LAG does not
--           reinitialise the table. It is suspended in V3.7.3, after the weekly
--           and monthly aggregates that read it have been created.
-- =============================================================================
{% set lag = daily_lag | default('24 hours') %}

ALTER DYNAMIC TABLE SALES_{{ env }}.GOLD.FACT_SALES_DAILY SET TARGET_LAG = '{{ lag }}';  -- daily refresh (var: daily_lag)
