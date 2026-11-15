-- =============================================================================
-- V3.6.0 : Tag customer PII columns in Bronze, Silver and Gold
-- Sets GOVERNANCE.TAGS.PII_TYPE on the personal-data columns of
--   BRONZE.CUSTOMER_MASTER (table), SILVER.CUSTOMER_MASTER and
--   GOLD.DIM_CUSTOMER (dynamic tables).
-- The tag carries the masking policies (governance V1.2.2), so tagging is all
-- that is needed: non-PII_READER roles see obfuscated values.
-- Not tagged (kept clear for analytics): CUSTOMER_ID / CUSTOMER_NUMBER
-- (pseudonymous keys), GENDER, CITY, STATE_PROVINCE, COUNTRY, EMAIL_DOMAIN.
-- Note: changing masking on a base table reinitialises downstream dynamic
-- tables once (Silver CUSTOMER_MASTER, Gold DIM_CUSTOMER, FACT_SALES_LINE).
-- =============================================================================

ALTER TABLE SALES_{{ env }}.BRONZE.CUSTOMER_MASTER MODIFY
  COLUMN FIRST_NAME     SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN LAST_NAME      SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN FULL_NAME      SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN EMAIL          SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'EMAIL',
  COLUMN PHONE_NUMBER   SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'PHONE',
  COLUMN STREET_ADDRESS SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'ADDRESS',
  COLUMN POSTAL_CODE    SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'POSTAL_CODE',
  COLUMN DATE_OF_BIRTH  SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'DATE_OF_BIRTH';

ALTER DYNAMIC TABLE SALES_{{ env }}.SILVER.CUSTOMER_MASTER MODIFY
  COLUMN FIRST_NAME     SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN LAST_NAME      SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN FULL_NAME      SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN EMAIL          SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'EMAIL',
  COLUMN PHONE_NUMBER   SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'PHONE',
  COLUMN STREET_ADDRESS SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'ADDRESS',
  COLUMN POSTAL_CODE    SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'POSTAL_CODE',
  COLUMN DATE_OF_BIRTH  SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'DATE_OF_BIRTH';

ALTER DYNAMIC TABLE SALES_{{ env }}.GOLD.DIM_CUSTOMER MODIFY
  COLUMN FIRST_NAME     SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN LAST_NAME      SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN FULL_NAME      SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'NAME',
  COLUMN EMAIL          SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'EMAIL',
  COLUMN PHONE_NUMBER   SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'PHONE',
  COLUMN STREET_ADDRESS SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'ADDRESS',
  COLUMN POSTAL_CODE    SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'POSTAL_CODE',
  COLUMN DATE_OF_BIRTH  SET TAG {{ governance_db }}.TAGS.PII_TYPE = 'DATE_OF_BIRTH';
