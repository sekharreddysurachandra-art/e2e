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
