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
│   ├── V1.1.0__create_governance_tags.sql
│   ├── V1.2.0__create_pii_reader_role.sql
│   ├── V1.2.1__create_pii_type_tag.sql
│   └── V1.2.2__create_pii_masking_policies.sql
└── 02_sales_db/
    ├── V2.0.0__create_sales_database.sql
    ├── V2.0.1__create_sales_schemas.sql
    ├── V2.0.2__create_common_file_formats.sql
    ├── V2.1.0__tag_sales_database_and_schemas.sql
    ├── V2.2.0__create_bronze_master_tables.sql
    ├── V2.2.1__create_bronze_sales_tables.sql
    ├── V2.3.0__load_bronze_initial_2019.sql
    ├── V3.6.0__tag_customer_pii_columns.sql      # PII tags on Bronze/Silver/Gold customer tables
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
        ├── V2.9.1 … V2.9.11__scd_history_silver_<table>.sql   # masters keep change history
        └── V2.9.12__add_local_date_silver_sales_header.sql
    └── gold/                                     # Silver -> Gold dynamic tables
        ├── V3.0.0__create_gold_dim_country.sql
        ├── V3.0.1__evolve_gold_dim_country_for_versioned_silver.sql
        ├── V3.1.0__create_gold_dim_product.sql
        ├── V3.1.1__create_gold_dim_product_country.sql
        ├── V3.2.0__create_gold_dim_store.sql
        ├── V3.3.0__create_gold_dim_customer.sql
        ├── V3.4.0__create_gold_dim_date.sql
        ├── V3.4.1__create_gold_dim_time.sql
        ├── V3.5.0__create_gold_fact_sales_line.sql
        ├── V3.5.1__create_gold_fact_sales_daily.sql
        ├── V3.7.0__set_fact_sales_daily_lag_24h.sql
        ├── V3.7.1__create_gold_fact_sales_weekly.sql
        ├── V3.7.2__create_gold_fact_sales_monthly.sql
        └── V3.7.3__suspend_fact_sales_daily.sql
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

## Gold dimensions (`SALES_DEV.GOLD`)

Transient dynamic tables, `REFRESH_MODE = INCREMENTAL`, `TARGET_LAG = DOWNSTREAM`, owner `SYSADMIN`. All SCD Type 2: hash surrogate key `MD5(business key|EFFECTIVE_START_DATE)`, inclusive end dates (9999-12-31 = open), `IS_CURRENT`, `RECORD_HASH`, `DQ_STATUS`/`DQ_ISSUES`. Dynamic tables reject PRIMARY KEY/UNIQUE, so key and SCD columns are NOT NULL and each script ends with a uniqueness check query.

| Script | Table | Grain | Sources | Rows |
|---|---|---|---|---|
| `V3.0.0`/`V3.0.1` | `DIM_COUNTRY` | country version | country + region + currency + tax | 71 |
| `V3.1.0` | `DIM_PRODUCT` | SKU version | SKU + model + family + category (hierarchy flattened) | 650 |
| `V3.1.1` | `DIM_PRODUCT_COUNTRY` | SKU x country version | product country availability | 22,750 |
| `V3.2.0` | `DIM_STORE` | store version | store master | 121 |
| `V3.3.0` | `DIM_CUSTOMER` | customer version | customer master (PII - masking still to do) | 31,350 |
| `V3.4.0` | `DIM_DATE` | calendar day 2015-01-01 .. 2044-12-31 + unknown (-1) | generated (regular table) | 10,959 |
| `V3.4.1` | `DIM_TIME` | minute of day + unknown (-1) | generated (regular table) | 1,441 |

- Product data is two dimensions, not one or five: category -> family -> model -> SKU is a strict hierarchy, so it is flattened onto the SKU; availability has a different grain (SKU x country) and is its own dimension.
- A combined dimension (`DIM_COUNTRY`, `DIM_PRODUCT`) starts a new version when any of its sources changes, using equality joins + `QUALIFY` so incremental refresh is kept; unchanged neighbouring segments are merged.
- Version dates: source effective dates where they exist (country, region, currency, tax, category, store); otherwise the day the version arrived (`VERSION_START_TS`; customer `UPDATED_AT`), one version per key per day.
- The first version of each key in the new dims starts `1900-01-01`, because the sources' first dates (2026) are later than the 2019 sales. Store keeps the source date in `SOURCE_EFFECTIVE_START_DATE`, undated dims in `SOURCE_VERSION_TS`. `DIM_COUNTRY` is not back-dated (its data starts in 1997).
- Store and customer keep `COUNTRY_CODE`/`REGION_CODE` as codes and join `DIM_COUNTRY` instead of copying its attributes, so a tax or currency change does not create store/customer versions.
- 2019 coverage check: every sales line finds one valid row in each dimension on its transaction date.

### Date and time dimensions
- `DIM_DATE` and `DIM_TIME` are regular (DEV/QA transient) tables loaded once: a generated calendar cannot be a dynamic table (`SEQ4`/`GENERATOR` are not change-trackable). Both have `CHANGE_TRACKING = TRUE` and declared PRIMARY KEY constraints (allowed on regular tables, not enforced by Snowflake).
- Fixed range instead of sales min/max: every day exists (also days without sales), fiscal years are complete, late/back-dated sales already have a row, and DEV/QA/PROD are identical. Extend the range with a new script.
- Keys: `DATE_SK` = YYYYMMDD, `TIME_SK` = HHMM; `-1` = unknown member so facts never drop rows.
- Apple fiscal calendar: the year ends on the last Saturday of September (52/53 weeks), 13-week quarters, Q1 = 14 weeks in 53-week years. Checked: FY2019 ends 2019-09-28, FY2020 2020-09-26, FY2022 2022-09-24, FY2023 2023-09-30 (53 weeks, Q1 ends 2022-12-31).
- Sales timestamps are UTC (inferred from the hour-of-day pattern per country; the source has no timezone). `V2.9.12` adds `TIMEZONE`, `TRANSACTION_TIMESTAMP_LOCAL` and `TRANSACTION_DATE_LOCAL` to Silver `SALES_HEADER`; facts join `DIM_DATE` / `DIM_TIME` on the local date and time. `TRANSACTION_DATE` stays the UTC date.
- Lineage: fact dynamic tables join `DIM_DATE`/`DIM_TIME` and store `DATE_SK`/`TIME_SK`, so the dates appear upstream of the facts in the dynamic table graph and `GET_LINEAGE`.

## Gold facts

| Script | Table | Grain | Lag | Rows |
|---|---|---|---|---|
| `V3.5.0` | `FACT_SALES_LINE` | sales line | `DOWNSTREAM` | 77,155 |
| `V3.5.1`/`V3.7.0` | `FACT_SALES_DAILY` | local date x country x store x product x channel x currency | `'24 hours'` (var `daily_lag`), suspended | 68,181 |
| `V3.7.1` | `FACT_SALES_WEEKLY` | ISO week (Mon-Sun) x same members | `'24 hours'` (var `weekly_lag`), suspended | 49,196 |
| `V3.7.2` | `FACT_SALES_MONTHLY` | calendar month x same members | `'24 hours'` (var `monthly_lag`), suspended | 33,310 |

- `FACT_SALES_LINE` joins every dimension and stores its SK: `DATE_SK`/`TIME_SK` on the local date/minute (`-1` = unknown), SCD2 SKs (`PRODUCT_SK`, `PRODUCT_COUNTRY_SK`, `CUSTOMER_SK`, `STORE_SK`, `COUNTRY_SK`) for the version valid on the local transaction date. Point-in-time lookups use equality joins + `QUALIFY` to stay incremental. ONLINE sales have `STORE_SK` NULL by design.
- Measures are in the transaction currency (`CURRENCY_CODE`); there is no FX source, so never sum across currencies.
- The three aggregates are the top of the pipeline and the only tables with a time lag (24 hours) - every Silver/Gold table below them is `DOWNSTREAM` and refreshes when they need data. They are **suspended** (`V3.7.1`-`V3.7.3`), so nothing refreshes on its own until they are resumed (daily first): `ALTER DYNAMIC TABLE SALES_<ENV>.GOLD.FACT_SALES_DAILY RESUME;` then WEEKLY and MONTHLY.
- Weekly and monthly roll up from `FACT_SALES_DAILY` (not the line fact) and join `DIM_DATE` for `WEEK_START_DATE_SK` / `MONTH_START_DATE_SK` (YYYYMMDD of the Monday / 1st), so lineage is line -> daily -> weekly/monthly and DIM_DATE -> weekly/monthly. `TRANSACTION_COUNT` is summed from daily counts (exact per row; summing over products double counts multi-product transactions). Apple fiscal quarters do not align with calendar months - report fiscal periods from the daily aggregate + `DIM_DATE.FISCAL_*`. Distinct customers are not stored (not additive) - use the line fact.
- Lineage (`GET_LINEAGE` / Snowsight graph): `SILVER.SALES_HEADER`, `SILVER.SALES_ITEM`, `DIM_DATE`, `DIM_TIME` and the 5 SCD2 dims -> `FACT_SALES_LINE` -> `FACT_SALES_DAILY`.
- Checks (2019): every line found all dimensions (0 DQ warnings); net amount 50,186,627.97 and quantity 92,025 reconcile Silver = line fact = daily aggregate.

## PII protection (tag-based masking)

| Script | Object | Purpose |
|---|---|---|
| `V1.2.0` | role `PII_READER` (granted to `SYSADMIN`) | Only role that sees customer PII in clear text |
| `V1.2.1` | tag `GOVERNANCE.TAGS.PII_TYPE` | NAME, EMAIL, PHONE, ADDRESS, POSTAL_CODE, DATE_OF_BIRTH |
| `V1.2.2` | `GOVERNANCE.POLICIES.MASK_PII_STRING`, `MASK_PII_DATE` | Masking policies attached to the tag |
| `V3.6.0` | tags on `BRONZE.CUSTOMER_MASTER`, `SILVER.CUSTOMER_MASTER`, `GOLD.DIM_CUSTOMER` | FIRST/LAST/FULL_NAME, EMAIL, PHONE_NUMBER, STREET_ADDRESS, POSTAL_CODE, DATE_OF_BIRTH |

- Tag-based: the policies are attached once to the tag, so any column tagged `PII_TYPE` in any table, layer or environment is masked - new tables only need the tag.
- Roles without `PII_READER` see: name `J***`, e-mail `j***@domain`, phone `***-***-1234`, address `*** MASKED ***`, postal code `94***`, date of birth `YYYY-01-01`. Customer ids, e-mail domain, city, state and country stay clear for analytics.
- `PII_READER` is granted to `SYSADMIN` because the Silver/Gold dynamic tables refresh as their owner SYSADMIN; without it they would store masked values. Consequence: SYSADMIN/ACCOUNTADMIN users see PII. To separate pipeline and admins later, move dynamic table ownership to a dedicated pipeline role.
- Policies use `IS_ROLE_IN_SESSION('PII_READER')` (constant, respects role hierarchy) - all dynamic tables stay INCREMENTAL. Tagging base columns reinitialised Silver CUSTOMER_MASTER, DIM_CUSTOMER and FACT_SALES_LINE once.
- Verified in DEV with a temporary role without PII_READER (masked in all three layers) and SYSADMIN (clear); Silver stores clear values, 0 DQ warnings.
- `CREATE MASKING POLICY` cannot run inside a `BEGIN ... END` block - keep each statement separate.
