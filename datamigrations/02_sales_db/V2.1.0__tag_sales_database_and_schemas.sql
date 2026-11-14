-- =============================================================================
-- V2.1.0 : Tag sales database and schemas with ENVIRONMENT
-- Database level for every environment (schemas and tables inherit it).
-- DEV also tags each schema explicitly, matching the current DEV setup.
-- =============================================================================

ALTER DATABASE SALES_{{ env }}                             -- target environment database
  SET TAG {{ governance_db }}.TAGS.ENVIRONMENT = '{{ env }}';  -- environment value: DEV | QA | PROD

{% if env == 'DEV' %}
ALTER SCHEMA SALES_{{ env }}.BRONZE SET TAG {{ governance_db }}.TAGS.ENVIRONMENT = '{{ env }}';  -- bronze schema
ALTER SCHEMA SALES_{{ env }}.SILVER SET TAG {{ governance_db }}.TAGS.ENVIRONMENT = '{{ env }}';  -- silver schema
ALTER SCHEMA SALES_{{ env }}.GOLD   SET TAG {{ governance_db }}.TAGS.ENVIRONMENT = '{{ env }}';  -- gold schema
ALTER SCHEMA SALES_{{ env }}.COMMON SET TAG {{ governance_db }}.TAGS.ENVIRONMENT = '{{ env }}';  -- common schema
{% endif %}
