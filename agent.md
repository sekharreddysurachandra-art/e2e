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

  - `V2.9.0` grants SYSADMIN SELECT on all (and future) Bronze tables – Silver DTs run as SYSADMIN and failed without it.
  - `V2.9.1`–`V2.9.11` (`CREATE OR ALTER`) make the 11 master tables keep change history instead of latest-only: drop only consecutive rows with the same `ATTR_HASH`; dated masters compare within key + `EFFECTIVE_START_DATE` (latest copy kept, conflicts flagged `SAME_START_DIFFERENT_ATTRIBUTES`); undated masters version by file arrival (`VERSION_START_TS`; customer uses `UPDATED_AT`). New columns `ATTR_HASH`, `VERSION_START_TS`, `IS_LATEST`, `SILVER_SK`. Sales header/item still latest-wins. 2019 data: one version per key, so row counts are unchanged.
  - `CREATE OR ALTER` with a query change reinitialises on the next refresh; with `TARGET_LAG = DOWNSTREAM` nothing triggers it, so run `ALTER DYNAMIC TABLE ... REFRESH` after deploying.
  Original pattern (V2.4–V2.8): dedup on business key (latest file/row wins), trim/upper codes, text dates cast with TRY_TO_DATE, `RECORD_HASH`, `DQ_STATUS`/`DQ_ISSUES`, 3 Bronze metadata columns; no `__SILVER_LOADED_AT`. Extras: `IS_CURRENT` (SCD2 tables), `IS_OPEN` (store), `EMAIL_DOMAIN` (customer), `TAX_RATE_PCT`, `TRANSACTION_DATE`, `GROSS_LINE_AMOUNT`. Renamed: customer `REGION` -> `REGION_CODE`, header `CURRENCY` -> `CURRENCY_CODE`. Warehouse via schemachange var `warehouse` (default `COMPUTE_WH`; SYSADMIN granted USAGE).
- Data facts: e-mail is not unique in CUSTOMER_MASTER (1,244 shared by different people - do not dedup on it); ONLINE orders have NULL STORE_ID; 24 headers in the 2019 file are dated 2020-01-01 in UTC (31 Dec 2019 local, US/CA/MX); header NET_TOTAL = sum of item LINE_TOTAL; 1 item line per transaction in 2019.
- New objects are created as ACCOUNTADMIN by the SQL tool (USE ROLE does not persist) - transfer ownership to SYSADMIN afterwards.
- `snow sql` with `PD77583`/`PD77583_SNOW` fails (OAuth client_id / MFA); deploy via the active SQL connection.
- Silver DMFs proposed (see README "Planned: Snowflake data metric functions"), not attached: `DUPLICATE_COUNT`, `REFERENTIAL_INTEGRITY_COUNT`, `SOURCE_TARGET_LAG` (not `FRESHNESS` – no TIMESTAMP_NTZ support), `ROW_COUNT_DIFFERENCE`, `ROW_COUNT` + anomaly detection, `ACCEPTED_VALUES` on `DQ_STATUS`, `SCHEMA_CHANGE_COUNT`. Get approval before attaching; planned script `silver/V2.10.0__attach_silver_dmfs.sql` (`DUPLICATE_COUNT` on `SILVER_SK` for master tables).
- Gold `SALES_DEV.GOLD.DIM_COUNTRY` (`datamigrations/02_sales_db/gold/V3.0.0__create_gold_dim_country.sql`): SCD2 dim combining Silver COUNTRY + REGION + CURRENCY + TAX masters; owner SYSADMIN, INCREMENTAL, `TARGET_LAG = DOWNSTREAM`; 71 versions / 35 countries / 35 current.
  - `V3.0.1` reads the versioned Silver masters: latest arrival per code + `EFFECTIVE_START_DATE`. Output unchanged (71 rows).
  - Key `COUNTRY_SK = MD5(COUNTRY_CODE|EFFECTIVE_START_DATE)`; new version whenever country, region, currency or tax version changes (inclusive end dates).
  - Dynamic tables reject PRIMARY KEY/UNIQUE constraints and need typed columns for NOT NULL; uniqueness is checked by the query at the end of the script.
  - Incremental DTs reject outer joins with range predicates: lookups join on code and pick the valid version with QUALIFY.
  - Silver TAX_MASTER starts 2020-01-01, so every country's 2019-and-earlier versions have no tax (DQ `TAX_NOT_FOUND_FOR_PERIOD`, 36 WARN rows); 2019 sales will join a tax-less version - confirm with the user whether tax dates are correct.
  - Silver country DTs failed refresh because Bronze tables are owned by ACCOUNTADMIN; granted SELECT on the 4 Bronze country tables to SYSADMIN (now covered for all Bronze tables by `V2.9.0`).
- Gold dims `V3.1.0` `DIM_PRODUCT` (650), `V3.1.1` `DIM_PRODUCT_COUNTRY` (22,750), `V3.2.0` `DIM_STORE` (121), `V3.3.0` `DIM_CUSTOMER` (31,350): SCD2, hash SK, INCREMENTAL, DOWNSTREAM, owner SYSADMIN; first version back-dated to 1900-01-01 (source dates are 2026, after the 2019 sales); full Type 2 on all attributes (customer hybrid Type 1/2 not applied - ask before changing). All 2019 sales lines match each dim on TRANSACTION_DATE. See README "Gold dimensions".
  - With every table at `TARGET_LAG = DOWNSTREAM`, nothing refreshes on its own: the Gold facts / aggregate need a real lag (e.g. '1 hour') – not decided yet.
- `DIM_DATE` (`V3.4.0`, 2015-2044 + `-1`, `DATE_SK` YYYYMMDD, calendar + Apple fiscal year/quarter/week) and `DIM_TIME` (`V3.4.1`, minute grain + `-1`, `TIME_SK` HHMM, day parts) are regular transient tables with CHANGE_TRACKING and PK constraints, owner SYSADMIN. Fiscal year-ends verified against Apple (FY2019 2019-09-28 .. FY2023 2023-09-30, 53 weeks).
- Sales timestamps are UTC (inferred from hour-of-day per country, source has no timezone - user did not confirm the source). `V2.9.12` (CREATE OR ALTER) adds `TIMEZONE`, `TRANSACTION_TIMESTAMP_LOCAL`, `TRANSACTION_DATE_LOCAL` to Silver `SALES_HEADER` using the latest country timezone; local years: 2018 = 1, 2019 = 77,143, 2020 = 11. Facts must join DIM_DATE/DIM_TIME on the local date/time.
- Gold facts: `V3.5.0` `FACT_SALES_LINE` (line grain, 77,155, DOWNSTREAM, point-in-time SKs to all dims, local DATE_SK/TIME_SK, amounts in transaction currency - no FX) and `V3.5.1` `FACT_SALES_DAILY` (aggregate, 68,181, TARGET_LAG var `fact_lag` default '1 hour' - the only time lag, drives the whole chain). Both INCREMENTAL, owner SYSADMIN; reconciled with Silver (net 50,186,627.97, qty 92,025).
- Not started: semantic view, incremental load task, masking policies, data quality checks.
