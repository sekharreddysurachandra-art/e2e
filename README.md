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
    └── V2.1.0__tag_sales_database_and_schemas.sql
```

- File names follow `V<version>__<description>.sql`; scripts run once, in version order.
- `V1.x` = governance, `V2.x` = sales database. Never edit a script after it has run – add a new version instead.

Deploy (replace `QA` with `DEV` or `PROD`):

```bash
schemachange deploy -f datamigrations -c PD77583 \
  --vars '{"env":"QA","governance_db":"GOVERNANCE"}' \
  --change-history-table GOVERNANCE.SCHEMACHANGE.CHANGE_HISTORY_QA \
  --create-change-history-table
```

## Local-only folders (not in Git)

These folders stay on your machine and are excluded by `.gitignore`:

- `__initial_load/` – source CSV files (country, customer, product, store, sales transactions)
- `__architectural_notes/` – architecture diagrams
- `__financial_reports/` – financial report PDFs

All `*.csv` files are also ignored in every folder.
