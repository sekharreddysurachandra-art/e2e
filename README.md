# e2e

End-to-end data project on Snowflake.

## Branches

| Branch | Purpose |
|---|---|
| `main` | Production-ready code |
| `qa` | Testing and validation before production |
| `dev` | Active development |

Changes flow `dev` → `qa` → `main`.

## Local-only folders (not in Git)

These folders stay on your machine and are excluded by `.gitignore`:

- `__initial_load/` – source CSV files (country, customer, product, store, sales transactions)
- `__architectural_notes/` – architecture diagrams
- `__financial_reports/` – financial report PDFs

All `*.csv` files are also ignored in every folder.
