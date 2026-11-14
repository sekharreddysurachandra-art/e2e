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
- Not started: internal stage, Bronze tables and loads, Silver/Gold dynamic tables, semantic view, load task, masking policies.
