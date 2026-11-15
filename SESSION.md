# Session log

## Session 1 – 2026-11-14

### Git setup
- `.gitignore` excludes `__initial_load/`, `__architectural_notes/`, `__financial_reports/` and all `*.csv` files.
- Branches `main`, `qa`, `dev` created and pushed to GitHub (`sekharreddysurachandra-art/e2e`).
- Rule: commit and push to `dev` only. `qa` and `main` are updated through PRs.

### Architecture (from `__architectural_notes`)
- Medallion layout per environment: `BRONZE` → `SILVER` → `GOLD`, plus `COMMON`.
- `SALES_DEV` → `SALES_QA` → `SALES_PROD`, promoted with GitHub PRs.
- `GOVERNANCE` database holds all tags and policies.
- DEV/QA objects are transient; every object gets a short comment; always `CREATE ... IF NOT EXISTS`; data-storing objects get a chargeback tag.
- Bronze loads use `INFER_SCHEMA` + `COPY` with `__file_name`, `__row_number`, `__load_timestamp`; Silver/Gold use incremental dynamic tables with `TARGET_LAG = DOWNSTREAM`; semantic view in Gold; a task loads new files.

### Created in Snowflake (role `SYSADMIN`, connection `PD77583`)

| Database | Type | Schemas |
|---|---|---|
| `GOVERNANCE` | Permanent | `TAGS`, `POLICIES` |
| `SALES_DEV` | Transient | `BRONZE`, `SILVER`, `GOLD`, `COMMON` |
| `SALES_QA` | Transient | `BRONZE`, `SILVER`, `GOLD`, `COMMON` |
| `SALES_PROD` | Permanent | `BRONZE`, `SILVER`, `GOLD`, `COMMON` |

- File format `COMMON.CSV_FF` in all three sales databases.
- Tag `GOVERNANCE.TAGS.ENVIRONMENT` (allowed `DEV`, `QA`, `PROD`):
  - `SALES_DEV` database and its 4 schemas = `DEV`
  - `SALES_QA` database = `QA`, `SALES_PROD` database = `PROD` (schemas inherit)

### Code in repo
- `ddl/` – scripts that were run manually in this session.
- `datamigrations/` – schemachange scripts (`01_governance`: V1.0.0–V1.1.0, `02_sales_db`: V2.0.0–V2.1.0) using `{{ env }}` and `{{ governance_db }}`.
- `README.md` – branches, environments, migration usage.

### Open items
- `CSV_FF` file format is not yet in `datamigrations/` (candidate `V2.0.2__create_common_file_formats.sql`).
- No `schemachange-config.yml`; pass `--vars` and `--change-history-table` per environment.
- Decide whether to remove `ddl/` now that `datamigrations/` replaces it.
- Chargeback tag name/values not decided.
- Not started: Bronze tables and loads, Silver/Gold dynamic tables, semantic view, load task, masking policies.

## Session 2 – 2026-11-14

### Internal stage and file uploads
- Created `SALES_DEV.BRONZE.SALES_CSV_STAGE` (internal, `DIRECTORY = (ENABLE = TRUE)`, `ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')`).
- Added the stage to `ddl/01_databases_schemas.sql` (with the `snow stage copy` commands as comments) and to `V2.0.1__create_sales_schemas.sql`.
- Uploaded from `__initial_load/` with `snow stage copy ... --parallel 10 --auto-compress -c PD77583_SNOW`, one file at a time:
  - `initial_load/country-master/` – 4 files (line counts match local)
  - `initial_load/product-master/` – 5 files
  - `initial_load/store-master/` – 1 file
  - `initial_load/customer-master/2019/<country_code>/` – 35 files
  - `initial_load/sales-transaction/2019/` – 2 files
- Directory table refreshed; all 49 files registered.
- `COMMON.CSV_FF` left unchanged (`COMPRESSION = AUTO` reads `.csv.gz`).

### Open items
- `V2.0.1` was edited after it ran in DEV; schemachange will not re-run it there. The stage already exists in DEV; QA/PROD get it on their first deploy.
- OAuth connection `PD77583` fails `snow stage copy` with S3 HTTP 400 – re-authenticate or keep using `PD77583_SNOW`.
- Upload customer-master and sales-transaction 2020–2025.
- Create Bronze tables (`INFER_SCHEMA`) and run `COPY INTO`.

## Session 3 – 2026-11-15

### Bronze tables and 2019 load
- Country tables (`COUNTRY_MASTER`, `CURRENCY_MASTER`, `REGION_MASTER`, `TAX_MASTER`) already existed and were loaded.
- Created 9 transient tables in `SALES_DEV.BRONZE` with `INFER_SCHEMA` and loaded them with `COPY INTO` (`MATCH_BY_COLUMN_NAME`, `INCLUDE_METADATA`, `ON_ERROR = ABORT_STATEMENT`):
  `PRODUCT_CATEGORY_MASTER` 10, `PRODUCT_COUNTRY_AVAILABILITY` 22,750, `PRODUCT_FAMILY_MASTER` 43, `PRODUCT_MODEL_MASTER` 111, `PRODUCT_SKU_MASTER` 650, `STORE_MASTER` 121, `CUSTOMER_MASTER` 31,350 (35 files), `SALES_HEADER` 77,155, `SALES_ITEM` 77,155.
- `CUSTOMER_MASTER` was first inferred from the US file only; `POSTAL_CODE` became numeric and the BR file failed. Recreated (empty) with `INFER_SCHEMA` over all country files – `POSTAL_CODE` is now `VARCHAR`.
- Verified all 13 bronze tables have the 3 metadata columns and no NULLs in them.
- Scope decided: **2019 only**. A 2020–2025 upload was attempted, failed for every file and was stopped; nothing reached the stage.

### Code in repo
- `agent.md` – context file for new sessions (rules, current state, open items).
- New schemachange scripts in `datamigrations/02_sales_db/`:
  - `V2.0.2__create_common_file_formats.sql` – `COMMON.CSV_FF` (closes Session 1 open item)
  - `V2.2.0__create_bronze_master_tables.sql` – 11 master tables (country, product, store, customer)
  - `V2.2.1__create_bronze_sales_tables.sql` – `SALES_HEADER`, `SALES_ITEM`
  - `V2.3.0__load_bronze_initial_2019.sql` – `COPY INTO` for all 13 tables from 2019 files
- Bronze DDL uses fixed column lists (from `INFER_SCHEMA` in DEV) so QA/PROD get the same structure before files exist on their stage.

### Open items
- DEV objects were created by hand; on the next DEV deploy schemachange will run V2.2.x/V2.3.0 as no-ops (`IF NOT EXISTS`, COPY skips loaded files). `V2.0.2` is lower than the applied `V2.1.0`, so schemachange skips it in DEV (object already exists); QA/PROD run it in order.
- Metadata column is `__FILE_LAST_MODIFIED_NTZ`; the architecture rule names `__load_timestamp` – confirm.
- New tables have no column comments (only the 4 country tables do).
- `SALES_HEADER` and `SALES_ITEM` have identical row counts – verify grain.
- QA/PROD stages are empty; upload files before deploying `V2.3.0` there.
- Next: Silver dynamic tables (incremental, `TARGET_LAG = DOWNSTREAM`).

## Session 4 – 2026-11-15

### Silver dynamic tables (Bronze -> Silver)
- Created 13 transient dynamic tables in `SALES_DEV.SILVER`, one per Bronze table: `REFRESH_MODE = INCREMENTAL` (confirmed, no full-refresh fallback), `TARGET_LAG = DOWNSTREAM`, `INITIALIZE = ON_CREATE`.
- Order: region → currency, tax, country → 5 product tables → customer → store → sales header and item.
- Common pattern: dedup on business key (latest file/row wins, customer by latest `UPDATED_AT`), trim/upper-case, empty → NULL, text dates cast with `TRY_TO_DATE`, `DQ_STATUS`/`DQ_ISSUES` record checks, `RECORD_HASH`, 3 Bronze metadata columns.
- `__SILVER_LOADED_AT` dropped on request – no Silver load-timestamp column.
- Extra columns: `IS_CURRENT` (SCD2 tables), `TAX_RATE_PCT`, `EMAIL_DOMAIN`, `IS_OPEN`, `TRANSACTION_DATE`, `GROSS_LINE_AMOUNT`.
- Ownership of all 13 tables transferred to `SYSADMIN`; granted `USAGE ON WAREHOUSE COMPUTE_WH TO ROLE SYSADMIN`.

### Profiling results (2019 data)
- No duplicate or NULL business keys in any Bronze table; Silver row counts = Bronze; 0 `WARN` rows.
- All foreign keys resolve (country → region/currency/tax, product hierarchy, availability → SKU/country, header → customer/store, item → header/SKU).
- `CUSTOMER_MASTER`: 1,244 e-mails shared by different people – e-mail is not a dedup key.
- `SALES_HEADER`: 15,351 ONLINE orders have NULL `STORE_ID` (expected; all POS orders have a store). 24 transactions dated 2020-01-01 sit in the 2019 file – kept.
- Amounts reconcile: `NET_TOTAL = GROSS_AMOUNT - TOTAL_DISCOUNT + TOTAL_TAX`, line total = qty × price − discount + tax, header net = sum of item lines. Grain is one item line per transaction in 2019 (closes the Session 3 grain item).
- `PRODUCT_MODEL_MASTER`: "Apple Watch Ultra 2" has two model codes (2023 and 2024) – valid, key is `MODEL_CODE`.

### Code in repo
- `datamigrations/02_sales_db/silver/` – `V2.4.0`–`V2.8.1`, one script per Silver table; refresh warehouse via optional `warehouse` var (default `COMPUTE_WH`).
- `README.md` – Silver layer section and updated folder tree; `agent.md` – Silver inventory and data facts.

### Open items
- `CUSTOMER_MASTER` holds PII (name, e-mail, phone, address, birth date) – add masking policies in `GOVERNANCE.POLICIES`.
- Cross-table referential integrity is not enforced in Silver – check it in Gold joins.
- `snow sql` fails with `PD77583` (OAuth client_id empty) and `PD77583_SNOW` (MFA); Silver was deployed through the active SQL connection.
- DEV Silver objects were created by hand; the next DEV schemachange run executes `V2.4.0`–`V2.8.1` as no-ops (`IF NOT EXISTS`).
- Next: Gold dimension and fact dynamic tables, aggregated fact, semantic view.
