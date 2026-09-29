# Saudi Arabia Job Market Pipeline — 02_code

## Project Summary
A data engineering pipeline that collects Saudi Arabia job postings from four
sources (Careerjet, Tanqeeb, Jooble, Techmap), lands raw data in Azure Data
Lake Storage Gen2, loads it into Snowflake, and transforms it through a
Bronze/Silver/Gold medallion architecture (dbt) into a curated, deduplicated
dataset plus a Kimball star schema for analytics. No AI/ML components — this
is a rule-based ETL/ELT pipeline (SHA-256 fingerprint deduplication, rule-based
data quality validation).

## Requirements
- Python 3.11+
- A Snowflake account (warehouse, database, schema)
- An Azure Storage account with Data Lake Storage Gen2 enabled
- Careerjet Partner API key (required to re-collect Careerjet data)
- Jooble Saudi Arabia API key (optional — only for re-collecting Jooble data)
- Techmap RapidAPI key (optional — only for re-collecting Techmap data)
- dbt-core (for the transformation layer)

## Installation
```bash
git clone <repo-url>
cd job-market-pipeline
pip install -e ".[dev]"
cp .env.example .env   # then fill in your credentials
python db/init_db.py
```

## Run the Project
Recommended — full pipeline (idempotent, no live API calls by default):
```bash
python scripts/run_full_pipeline.py
```

Run a single source end-to-end:
```bash
python -m pipeline.runner --source techmap
```

Build and test the dbt models:
```bash
cd dbt/job_market_pipeline
dbt run
dbt test
```

Run the test suite:
```bash
pytest          # suite lives in archive/tests/ (configured via pyproject testpaths)
```

## API Keys & Environment Variables
See `.env.example` for the full list. Required: `DB_URL`, `CAREERJET_API_KEY`,
`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`,
`SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`,
`AZURE_STORAGE_CONNECTION_STRING`, `AZURE_STORAGE_FILE_SYSTEM`. Optional (only
for re-collection): `JOOBLE_SA_API_KEY`, `TECHMAP_API_KEY`.

Note: `AZURE_STORAGE_ACCOUNT_NAME` appears in `.env.example` for reference but is
not consumed by any Python file currently (the connection string already encodes
the account), so it is not required to run the pipeline.

## Known Issues
- Techmap's Terms of Service for automated collection are not fully verified;
  treated as provisional pending re-check before any production scaling.
- Cross-source deduplication logic is implemented (shared fingerprint schema)
  and empirically validated against the current 3,184-record dataset: 3
  fingerprints appeared under more than one source (2 Careerjet+Techmap, 1
  Careerjet+Tanqeeb; 8 pre-dedup records collapsed to 3 canonical rows), so the
  deduplicator is confirmed to catch cross-source overlap. Such overlap is rare
  at this scale (3 of 1,484 curated fingerprints).
- Careerjet provides no reliable per-listing posting date (its `date` field is
  the query timestamp, not the posting date) — `posting_date` is null for all
  Careerjet records by design.
- Salary data coverage is sparse (~4.6%) — an inherent limitation of the
  Careerjet source, not a parsing defect.
- The Jadarat Open Data source was evaluated but is not implemented
  (`pipeline/collectors/jadarat_csv.py` is a stub that raises
  `NotImplementedError`).
