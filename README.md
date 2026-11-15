# e2e

End-to-end data project on Snowflake.

## Branches

| Branch | Purpose |
|---|---|
| `main` | Production-ready code |
| `qa` | Testing and validation before production |
| `dev` | Active development |

Changes flow `dev` → `qa` → `main`.

## Snowflake environments

| Database | Environment | Type |
|---|---|---|
| `GOVERNANCE` | Shared | Permanent – tags (`TAGS`) and policies (`POLICIES`) |
| `SALES_DEV` | DEV | Transient |
| `SALES_QA` | QA | Transient |
| `SALES_PROD` | PROD | Permanent |

Each sales database has `BRONZE`, `SILVER`, `GOLD` and `COMMON` schemas (medallion architecture).
All objects are owned by `SYSADMIN` and tagged with `GOVERNANCE.TAGS.ENVIRONMENT`.

## Database migrations (`datamigrations/`)

DDL is managed with [schemachange](https://github.com/Snowflake-Labs/schemachange). The same scripts deploy to every environment through the `env` variable.

```
datamigrations/
├── 01_governance/
│   ├── V1.0.0__create_governance_database.sql
│   ├── V1.0.1__create_governance_schemas.sql
│   └── V1.1.0__create_governance_tags.sql
└── 02_sales_db/
    ├── V2.0.0__create_sales_database.sql
    ├── V2.0.1__create_sales_schemas.sql
    ├── V2.0.2__create_common_file_formats.sql
    ├── V2.1.0__tag_sales_database_and_schemas.sql
    ├── V2.2.0__create_bronze_master_tables.sql
    ├── V2.2.1__create_bronze_sales_tables.sql
    ├── V2.3.0__load_bronze_initial_2019.sql
    └── silver/                                   # Bronze -> Silver dynamic tables
        ├── V2.4.0__create_silver_region_master.sql
        ├── V2.4.1__create_silver_currency_master.sql
        ├── V2.4.2__create_silver_tax_master.sql
        ├── V2.4.3__create_silver_country_master.sql
        ├── V2.5.0__create_silver_product_category_master.sql
        ├── V2.5.1__create_silver_product_family_master.sql
        ├── V2.5.2__create_silver_product_model_master.sql
        ├── V2.5.3__create_silver_product_sku_master.sql
        ├── V2.5.4__create_silver_product_country_availability.sql
        ├── V2.6.0__create_silver_customer_master.sql
        ├── V2.7.0__create_silver_store_master.sql
        ├── V2.8.0__create_silver_sales_header.sql
        ├── V2.8.1__create_silver_sales_item.sql
        ├── V2.9.0__grant_bronze_select_to_sysadmin.sql
        └── V2.9.1 … V2.9.11__scd_history_silver_<table>.sql   # masters keep change history
    └── gold/                                     # Silver -> Gold dynamic tables
        ├── V3.0.0__create_gold_dim_country.sql
        └── V3.0.1__evolve_gold_dim_country_for_versioned_silver.sql
```

- File names follow `V<version>__<description>.sql`; scripts run once, in version order.
- `V1.x` = governance, `V2.x` = sales database. Never edit a script after it has run – add a new version instead.
- `V2.0.x` database objects, `V2.1.x` tags, `V2.2.x` Bronze tables, `V2.3.x` Bronze loads, `V2.4.x`–`V2.9.x` Silver dynamic tables (`silver/` subfolder), `V3.x` Gold dynamic tables (`gold/` subfolder; schemachange scans subfolders and orders by version, not folder).
- Silver scripts accept an optional `warehouse` variable for the refresh warehouse (default `COMPUTE_WH`).
- `V2.3.0` runs `COPY INTO`, so upload the files to the environment's stage before deploying it (otherwise it loads 0 files).

Deploy (replace `QA` with `DEV` or `PROD`):

```bash
schemachange deploy -f datamigrations -c PD77583 \
  --vars '{"env":"QA","governance_db":"GOVERNANCE","warehouse":"COMPUTE_WH"}' \
  --change-history-table GOVERNANCE.SCHEMACHANGE.CHANGE_HISTORY_QA \
  --create-change-history-table
```

## Initial load – files on stage

Internal stage `SALES_DEV.BRONZE.SALES_CSV_STAGE` (directory table enabled, `SNOWFLAKE_SSE` encryption).
Defined in `ddl/01_databases_schemas.sql` and `datamigrations/02_sales_db/V2.0.1__create_sales_schemas.sql`.
The `snow stage copy` commands are kept as comments in `ddl/01_databases_schemas.sql`.

- Uploaded one file at a time with `--parallel 10 --auto-compress` (files are stored as `.csv.gz`).
- Connection `PD77583_SNOW` (the OAuth connection `PD77583` failed with an S3 HTTP 400).
- `Zone.Identifier` and `.DS_Store` files are not uploaded.
- `COMMON.CSV_FF` uses `COMPRESSION = AUTO`, so no change is needed to read `.csv.gz` files.

| Stage path (`initial_load/…`) | Files | Validation |
|---|---|---|
| `country-master/` | 4 | Line counts match local files (36, 28, 6, 36) |
| `product-master/` | 5 | Listed and registered in directory table |
| `store-master/` | 1 | Listed and registered in directory table |
| `customer-master/2019/<country_code>/` | 35 | 35 files listed; no other years on stage |
| `sales-transaction/2019/` | 2 | Listed and registered in directory table |

Total: 47 files (2019 only). Scope is 2019 – 2020–2025 files are not uploaded.

## Bronze layer (`SALES_DEV.BRONZE`)

13 transient tables, each with `__FILE_NAME`, `__ROW_NUMBER` and `__FILE_LAST_MODIFIED_NTZ` filled by `COPY ... INCLUDE_METADATA`.
Columns come from `INFER_SCHEMA` and are fixed in `V2.2.0`/`V2.2.1`; loads are in `V2.3.0`.

| Table | Rows (2019) | Table | Rows (2019) |
|---|---|---|---|
| `REGION_MASTER` | 5 | `PRODUCT_SKU_MASTER` | 650 |
| `CURRENCY_MASTER` | 27 | `PRODUCT_COUNTRY_AVAILABILITY` | 22,750 |
| `TAX_MASTER` | 35 | `STORE_MASTER` | 121 |
| `COUNTRY_MASTER` | 35 | `CUSTOMER_MASTER` | 31,350 |
| `PRODUCT_CATEGORY_MASTER` | 10 | `SALES_HEADER` | 77,155 |
| `PRODUCT_FAMILY_MASTER` | 43 | `SALES_ITEM` | 77,155 |
| `PRODUCT_MODEL_MASTER` | 111 | | |

## Silver layer (`SALES_DEV.SILVER`)

13 transient dynamic tables, one per Bronze table (`REFRESH_MODE = INCREMENTAL`, `TARGET_LAG = DOWNSTREAM`, owner `SYSADMIN`).
Scripts: `datamigrations/02_sales_db/silver/`.

Every Silver table:
- Sales header/item de-duplicate on their key – COPY does not reject duplicates, so the latest copy wins (newest file, then highest row number).
- The 11 master tables keep change history (`V2.9.1`–`V2.9.11`): only exact re-sends are dropped – a row goes when its `ATTR_HASH` (business attributes without effective dates or load metadata) equals the previous copy of the same key; every real change, including a change back to an old value, is kept. Effective-dated masters compare within key + `EFFECTIVE_START_DATE` and keep the latest copy (so a closed version gets its new end date); two different versions with the same start date are both kept and flagged `SAME_START_DIFFERENT_ATTRIBUTES`. Masters without effective dates use `VERSION_START_TS` = file arrival time (customer: `UPDATED_AT`). Added columns: `ATTR_HASH`, `VERSION_START_TS`, `IS_LATEST`, `SILVER_SK` (MD5 of key + version + source row). Gold builds SCD2 end dates from these versions.
- Trims text, upper-cases codes, turns empty strings into NULL, drops rows without a key, casts text dates with `TRY_TO_DATE`.
- Flags record-level quality checks in `DQ_STATUS` (`PASS`/`WARN`) and `DQ_ISSUES` (array of failed check codes) – rows are kept, not rejected.
- Adds `RECORD_HASH` (MD5 of business columns) and keeps the 3 Bronze metadata columns. There is no Silver load-timestamp column.

| Script | Table | Business key | Extra columns | Rows |
|---|---|---|---|---|
| `V2.4.0` | `REGION_MASTER` | `REGION_CODE` + `EFFECTIVE_START_DATE` | `IS_CURRENT` | 5 |
| `V2.4.1` | `CURRENCY_MASTER` | `CURRENCY_CODE` + `EFFECTIVE_START_DATE` | `IS_CURRENT` | 27 |
| `V2.4.2` | `TAX_MASTER` | `TAX_CODE` + `EFFECTIVE_START_DATE` | `IS_CURRENT`, `TAX_RATE_PCT` | 35 |
| `V2.4.3` | `COUNTRY_MASTER` | `COUNTRY_CODE` + `EFFECTIVE_START_DATE` | `IS_CURRENT` | 35 |
| `V2.5.0` | `PRODUCT_CATEGORY_MASTER` | `CATEGORY_CODE` + `EFFECTIVE_START_DATE` | `IS_CURRENT` | 10 |
| `V2.5.1` | `PRODUCT_FAMILY_MASTER` | `FAMILY_CODE` | – | 43 |
| `V2.5.2` | `PRODUCT_MODEL_MASTER` | `MODEL_CODE` | – | 111 |
| `V2.5.3` | `PRODUCT_SKU_MASTER` | `SKU_CODE` | – | 650 |
| `V2.5.4` | `PRODUCT_COUNTRY_AVAILABILITY` | `SKU_CODE` + `COUNTRY_CODE` | – | 22,750 |
| `V2.6.0` | `CUSTOMER_MASTER` | `CUSTOMER_ID` (latest `UPDATED_AT` wins) | `EMAIL_DOMAIN` | 31,350 |
| `V2.7.0` | `STORE_MASTER` | `STORE_CODE` + `EFFECTIVE_START_DATE` | `IS_CURRENT`, `IS_OPEN` | 121 |
| `V2.8.0` | `SALES_HEADER` | `TRANSACTION_SK` | `TRANSACTION_DATE` | 77,155 |
| `V2.8.1` | `SALES_ITEM` | `TRANSACTION_LINE_ID` | `GROSS_LINE_AMOUNT` | 77,155 |

Renamed for consistency: customer `REGION` → `REGION_CODE`, header `CURRENCY` → `CURRENCY_CODE`.
2019 result: Silver rows = Bronze rows (no duplicates found), 0 `WARN` rows.

### Planned: Snowflake data metric functions (DMFs) on Silver – not applied yet

The `DQ_STATUS` / `DQ_ISSUES` columns check one row at a time. DMFs add table-level checks with history, thresholds (expectations) and alerts:

| DMF | Applies to | Expectation | Catches |
|---|---|---|---|
| `DUPLICATE_COUNT` on business key | all 13 Silver tables | `VALUE = 0` | dedup not working |
| `REFERENTIAL_INTEGRITY_COUNT` | country, product hierarchy, availability, customer, store, header, item | `VALUE = 0` | orphan rows |
| `SOURCE_TARGET_LAG` on `__FILE_LAST_MODIFIED_NTZ` (Silver vs Bronze) | all 13 | e.g. `VALUE <= 3600` | Silver refresh behind Bronze |
| `ROW_COUNT_DIFFERENCE` vs Bronze | all 13 | `VALUE = 0` | rows lost between layers |
| `ROW_COUNT` + `ANOMALY_DETECTION = TRUE` | sales header/item, customer, availability | learned | unusual load volume |
| `ACCEPTED_VALUES` on `DQ_STATUS = 'PASS'` | all 13 | `VALUE = 0` | rows flagged `WARN` |
| `INVALID_EMAIL_COUNT`, `NULL_COUNT` | customer | `VALUE = 0` | PII field quality |
| `SCHEMA_CHANGE_COUNT` | Bronze tables | `VALUE = 0` | schema drift |

- Schedule `TRIGGER_ON_CHANGES` (run on refresh); DMFs use serverless compute.
- `FRESHNESS` is not used: it does not accept `TIMESTAMP_NTZ` columns. `SECONDS_SINCE_ROW_COUNT_CHANGE` is not available in this account.
- Needs `EXECUTE DATA METRIC FUNCTION` and `SNOWFLAKE.DATA_METRIC_USER` for the deploying role, plus a notification integration for alerts.
- Planned script: `datamigrations/02_sales_db/silver/V2.10.0__attach_silver_dmfs.sql` (after approval of statements and thresholds).

See `agent.md` for a summary of rules, current state and open items for new sessions.

## Local-only folders (not in Git)

These folders stay on your machine and are excluded by `.gitignore`:

- `__initial_load/` – source CSV files (country, customer, product, store, sales transactions)
- `__architectural_notes/` – architecture diagrams
- `__financial_reports/` – financial report PDFs

All `*.csv` files are also ignored in every folder.
