# agent.md – context for new sessions

Read this first, then the files in "Reference files". Keep this file current when the project state changes.

## Project
End-to-end sales data platform on Snowflake: CSV files → internal stage → Bronze → Silver → Gold (medallion), deployed to DEV, QA and PROD.

- Snowflake connection: `PD77583` (SQL). Use `PD77583_SNOW` for `snow stage copy` (OAuth `PD77583` fails uploads with S3 HTTP 400).
- Role: `SYSADMIN`.
- Git: work and push on `dev` only; `qa` and `main` are updated through PRs. Commit only when the user asks.

## Reference files

| File | What it contains |
|---|---|
| `README.md` | Branches, environments, datamigrations usage, stage upload summary |
| `SESSION.md` | Per-session log: what was created, open items |
| `__architectural_notes/architectural-important-notes.png` | Object creation rules (summarised below) |
| `__architectural_notes/architectural-data-flow-rules.png` | Data flow and transformation rules (summarised below) |
| `__architectural_notes/medallion-architecture-with-dev-qa-prod.png` | Medallion layout across DEV/QA/PROD |
| `__initial_load/` | Source CSVs (country, customer, product, store, sales) for 2019–2025 |
| `__financial_reports/` | Proxy statement PDFs (2019, 2022–2026) |
| `ddl/` | Scripts run manually in early sessions |
| `datamigrations/` | schemachange scripts (`01_governance` V1.x, `02_sales_db` V2.x; Silver in `02_sales_db/silver/`) |

`__*` folders and `*.csv` are git-ignored (local only).

## Rules to follow (from architectural notes)
Object creation:
1. DEV (`SALES_DEV`) and QA (`SALES_QA`) objects are transient (no fail-safe cost).
2. Common objects (file formats, sequences) go in the `COMMON` schema of each environment.
3. Tags, policies and masking policies go in the `GOVERNANCE` database.
4. Every object gets a short, meaningful comment.
5. Always `CREATE ... IF NOT EXISTS` – never drop or replace existing objects by mistake.
6. Data-storing objects (tables, stages) get a chargeback tag.

Data flow:
- CSVs uploaded to the internal stage with PUT / `snow stage copy`.
- Bronze tables: structure from `INFER_SCHEMA`, loaded with `COPY`, plus 3 metadata columns `__file_name`, `__row_number`, `__load_timestamp`.
- Bronze → Silver → Gold: dynamic tables, incremental refresh, `TARGET_LAG = DOWNSTREAM`.
- Facts and dimensions are dynamic tables in Gold; facts reference Gold dims, not Silver tables.
- Aggregated fact table and semantic view in Gold.
- A task runs `COPY` for newly arrived files; dynamic tables carry them to Gold.

## Current state (as of 2026-11-15)
- Databases: `GOVERNANCE` (`TAGS`, `POLICIES`), `SALES_DEV`/`SALES_QA` (transient), `SALES_PROD` – each sales DB has `BRONZE`, `SILVER`, `GOLD`, `COMMON`.
- `COMMON.CSV_FF` file format (header parsing, `COMPRESSION = AUTO`) in all sales DBs.
- Tag `GOVERNANCE.TAGS.ENVIRONMENT` applied to databases/schemas.
- Stage `SALES_DEV.BRONZE.SALES_CSV_STAGE` holds **2019 files only** (47 `.csv.gz` files under `initial_load/`). Scope is 2019 only – do not upload or load 2020–2025 unless the user asks.
- `SALES_DEV.BRONZE` tables, all loaded from 2019 files, all with 3 metadata columns populated:

| Table | Rows |
|---|---|
| `COUNTRY_MASTER` | 35 |
| `CURRENCY_MASTER` | 27 |
| `REGION_MASTER` | 5 |
| `TAX_MASTER` | 35 |
| `PRODUCT_CATEGORY_MASTER` | 10 |
| `PRODUCT_COUNTRY_AVAILABILITY` | 22,750 |
| `PRODUCT_FAMILY_MASTER` | 43 |
| `PRODUCT_MODEL_MASTER` | 111 |
| `PRODUCT_SKU_MASTER` | 650 |
| `STORE_MASTER` | 121 |
| `CUSTOMER_MASTER` | 31,350 (35 country files) |
| `SALES_HEADER` | 77,155 |
| `SALES_ITEM` | 77,155 |

Load pattern used (repeat it for new tables):
```sql
COPY INTO SALES_DEV.BRONZE.<TABLE>
FROM @SALES_DEV.BRONZE.SALES_CSV_STAGE/initial_load/<folder>/
FILES = ('<file>.csv.gz')            -- or PATTERN for multi-file tables
FILE_FORMAT = (FORMAT_NAME = 'SALES_DEV.COMMON.CSV_FF')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (__FILE_NAME = METADATA$FILENAME, __ROW_NUMBER = METADATA$FILE_ROW_NUMBER,
                    __FILE_LAST_MODIFIED_NTZ = METADATA$FILE_LAST_MODIFIED)
ON_ERROR = ABORT_STATEMENT;
```
For multi-file tables run `INFER_SCHEMA` over the whole folder, not one file (single-file inference typed `CUSTOMER_MASTER.POSTAL_CODE` as a number and failed on BR postcodes).

## Known gaps / open items
- Metadata column is `__FILE_LAST_MODIFIED_NTZ`, but the rules require `__load_timestamp` – confirm with the user before changing.
- Only `COUNTRY_MASTER` (and other country tables) have column comments; the 9 tables created on 2026-11-15 do not.
- Bronze DDL and loads are in `datamigrations/02_sales_db/` (`V2.0.2` file format, `V2.2.0`/`V2.2.1` tables, `V2.3.0` 2019 COPY). Upload files to a stage before deploying `V2.3.0` there.
- No `schemachange-config.yml`.
- Chargeback tag not defined or applied.
- Silver dynamic tables in `SALES_DEV.SILVER`, scripts in `datamigrations/02_sales_db/silver/` (all owner SYSADMIN, INCREMENTAL, `TARGET_LAG = DOWNSTREAM`, Silver rows = Bronze rows, 0 DQ warnings):

| Script | Table | Key | Rows |
|---|---|---|---|
| `V2.4.0` | `REGION_MASTER` | REGION_CODE + EFFECTIVE_START_DATE | 5 |
| `V2.4.1` | `CURRENCY_MASTER` | CURRENCY_CODE + EFFECTIVE_START_DATE | 27 |
| `V2.4.2` | `TAX_MASTER` | TAX_CODE + EFFECTIVE_START_DATE | 35 |
| `V2.4.3` | `COUNTRY_MASTER` | COUNTRY_CODE + EFFECTIVE_START_DATE | 35 |
| `V2.5.0` | `PRODUCT_CATEGORY_MASTER` | CATEGORY_CODE + EFFECTIVE_START_DATE | 10 |
| `V2.5.1` | `PRODUCT_FAMILY_MASTER` | FAMILY_CODE | 43 |
| `V2.5.2` | `PRODUCT_MODEL_MASTER` | MODEL_CODE | 111 |
| `V2.5.3` | `PRODUCT_SKU_MASTER` | SKU_CODE | 650 |
| `V2.5.4` | `PRODUCT_COUNTRY_AVAILABILITY` | SKU_CODE + COUNTRY_CODE | 22,750 |
| `V2.6.0` | `CUSTOMER_MASTER` | CUSTOMER_ID (latest UPDATED_AT wins) | 31,350 |
| `V2.7.0` | `STORE_MASTER` | STORE_CODE + EFFECTIVE_START_DATE | 121 |
| `V2.8.0` | `SALES_HEADER` | TRANSACTION_SK | 77,155 |
| `V2.8.1` | `SALES_ITEM` | TRANSACTION_LINE_ID | 77,155 |

  Pattern: dedup on business key (latest file/row wins), trim/upper codes, text dates cast with TRY_TO_DATE, `RECORD_HASH`, `DQ_STATUS`/`DQ_ISSUES`, 3 Bronze metadata columns; no `__SILVER_LOADED_AT`. Extras: `IS_CURRENT` (SCD2 tables), `IS_OPEN` (store), `EMAIL_DOMAIN` (customer), `TAX_RATE_PCT`, `TRANSACTION_DATE`, `GROSS_LINE_AMOUNT`. Renamed: customer `REGION` -> `REGION_CODE`, header `CURRENCY` -> `CURRENCY_CODE`. Warehouse via schemachange var `warehouse` (default `COMPUTE_WH`; SYSADMIN granted USAGE).
- Data facts: e-mail is not unique in CUSTOMER_MASTER (1,244 shared by different people - do not dedup on it); ONLINE orders have NULL STORE_ID; 24 headers in the 2019 file are dated 2020-01-01; header NET_TOTAL = sum of item LINE_TOTAL; 1 item line per transaction in 2019.
- New objects are created as ACCOUNTADMIN by the SQL tool (USE ROLE does not persist) - transfer ownership to SYSADMIN afterwards.
- `snow sql` with `PD77583`/`PD77583_SNOW` fails (OAuth client_id / MFA); deploy via the active SQL connection.
- Not started: Gold dynamic tables, semantic view, incremental load task, masking policies, data quality checks.
