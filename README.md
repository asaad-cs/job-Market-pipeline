# Saudi Arabia Job Market Data Pipeline

**WeCloudData / SDA Data Engineering Capstone — Ahmed Saad Al-Faidi**

A repeatable data engineering pipeline that collects Saudi Arabia job postings from four sources (Careerjet, Tanqeeb, Jooble, and Techmap), stores them raw, cleans and standardizes the data, deduplicates across collection runs, validates quality, and loads the curated records into a Snowflake analytical table.

The deliverable is the **pipeline and curated dataset**, not a downstream application.

---

## Architecture

```
Careerjet API ── Tanqeeb ── Jooble (JSON) ── Techmap (RapidAPI)
     │               │            │                 │
     └───────────────┴────────────┴─────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────┐
│              COLLECTION STAGE                   │
│  pipeline/collectors/careerjet.py (live API)    │
│  pipeline/collectors/tanqeeb.py   (scraper)     │
│  pipeline/collectors/techmap.py   (RapidAPI)    │
│  Jooble: data/raw/jooble_combined*.json         │
└──────────────────┬──────────────────────────────┘
                   │ Careerjet: writes to SQLite
                   ▼
┌─────────────────────────────────────────────────┐
│           OLTP TIER  (SQLite dev / PG prod)     │
│  raw_jobs            — append-only raw storage  │
│  collection_runs     — run tracking             │
│  processed_fingerprints — cross-run dedup state │
│  quality_log         — all flags and rejections │
└──────────────────┬──────────────────────────────┘
                   │ read by (Careerjet Python path only)
                   ▼
┌─────────────────────────────────────────────────┐
│           PROCESSING STAGES  (Python)           │
│  cleaner.py       — normalize fields, generate  │
│                     job_fingerprint             │
│  standardizer.py  — career level, salary parse  │
│  deduplicator.py  — 2-stage dedup (fingerprint  │
│                     then URL); marks is_duplicate│
│  validator.py     — 15 quality rules; writes to │
│                     quality_log                 │
└──────────────────┬──────────────────────────────┘
                   │ all 4 sources uploaded to ADLS by pipeline/adls.py,
                   │ then loaded via scripts/copy_adls_to_bronze.sql
                   │ (+ scripts/refresh_collection_runs.sql for the audit trail)
                   ▼
┌─────────────────────────────────────────────────┐
│           BRONZE TIER  (Snowflake)              │
│  BRONZE.raw_jobs — 425 raw records              │
│  99 Careerjet + 117 Tanqeeb + 109 Jooble        │
│                 + 100 Techmap                   │
└──────────────────┬──────────────────────────────┘
                   │ transformed by dbt
                   ▼
┌─────────────────────────────────────────────────┐
│           OLAP TIER  (Snowflake GOLD)           │
│  GOLD.fct_jobs — 416 curated records            │
│  (4 sources; last rebuilt 2026-09-13)           │
└─────────────────────────────────────────────────┘
```

---

## dbt Transformation Layer (Medallion Architecture)

The pipeline includes a dbt project (`dbt/job_market_pipeline/`) that replicates and supersedes the Python processing stages (cleaner/standardizer/deduplicator/validator) as SQL transformations in Snowflake.

### Snowflake schema layout

| Layer | Schema | dbt models | Contents |
|---|---|---|---|
| **Bronze** | `BRONZE` | *(source, not a dbt model)* | Raw VARIANT payloads from all four sources — `raw_jobs` loaded via the ADLS path (`pipeline/adls.py` → `scripts/copy_adls_to_bronze.sql`) and `collection_runs` populated by `scripts/refresh_collection_runs.sql` |
| **Silver** | `SILVER` | `stg_careerjet__raw_jobs`, `stg_tanqeeb__raw_jobs`, `stg_jooble__raw_jobs`, `stg_techmap__raw_jobs`, `int_jobs_cleaned`, `int_jobs_standardized`, `int_jobs_deduplicated`, `int_jobs_quality_flags` | Field extraction, cleaning, standardization, dedup, quality flagging — all as views |
| **Gold** | `GOLD` | `fct_jobs` | Non-duplicate, non-rejected curated records — materialized as a table |

### Model chain

```
BRONZE.raw_jobs (source)
    ├─► SILVER.stg_careerjet__raw_jobs  ─┐
    ├─► SILVER.stg_tanqeeb__raw_jobs    ─┤ UNION ALL
    ├─► SILVER.stg_jooble__raw_jobs     ─┤ (canonical 13-column shape)
    └─► SILVER.stg_techmap__raw_jobs    ─┘
                └─► SILVER.int_jobs_cleaned          (title/company/location/fingerprint)
                        └─► SILVER.int_jobs_standardized   (career level, salary, out_of_region)
                                └─► SILVER.int_jobs_deduplicated  (is_duplicate, duplicate_of_raw_id)
                                        └─► SILVER.int_jobs_quality_flags (quality_flags, is_rejected)
                                                    └─► GOLD.fct_jobs  (416 curated records)
```

### Canonical dataset for submission

`GOLD.fct_jobs` (dbt path) is the **official curated dataset** for this project and the submission source of truth. All four sources are integrated; BRONZE was last reloaded and `dbt run` last executed on 2026-09-13.

| Table | Schema | Path | Rows | Status |
|---|---|---|---|---|
| `fct_jobs` | `GOLD` | dbt (BRONZE → Silver models → GOLD) | **416** | **Canonical — submission source of truth.** Last synced 2026-09-13. |
| `jobs` | `PUBLIC` | Python (runner.py → snowflake_loader.py) | varies | Parallel Careerjet-only output; not the submission source of truth. |

### Running the dbt models

```bash
cd dbt/job_market_pipeline
dbt run          # build all 15 models (9 medallion + 6 star-schema)
dbt test         # run schema tests (24 total)
```

Requires `dbt/profiles.yml` (gitignored — contains Snowflake credentials). See `.env.example` for the `SNOWFLAKE_*` variables used.

---

## Star Schema (Dimensional Model)

On top of the flat `GOLD.fct_jobs` table, the project provides a **dimensional
(star) model** for BI/analytics consumption (commit `aa965a7`). It is built
**additively** — `GOLD.fct_jobs` is unchanged and remains the submission source
of truth; the star schema is an additional set of dbt models under
`dbt/job_market_pipeline/models/marts/star/`.

### Structure

A central fact table surrounded by five conformed dimensions, all in the `GOLD`
schema:

```
              dim_date          dim_source
                  │                 │
    dim_company ──┼──► fct_jobs_star ◄──┼── dim_career_level
                  │                 │
              dim_location ─────────┘
```

| Model | Grain | Surrogate key |
|---|---|---|
| `fct_jobs_star` | one row per curated job (same grain & PK as `fct_jobs`) | `job_id = md5(job_fingerprint)` + FKs below |
| `dim_company` | distinct company | `company_id` — md5 of normalized company name |
| `dim_location` | distinct (city, country) | `location_id` — md5 of normalized city + country |
| `dim_date` | distinct posting date | `date_id` — YYYYMMDD smart integer (`0` = no date) |
| `dim_source` | distinct source | `source_id` — md5 of source name |
| `dim_career_level` | distinct career level | `career_level_id` — md5 of normalized career level |

`fct_jobs_star` carries the foreign keys (`company_id`, `location_id`, `date_id`,
`source_id`, `career_level_id`) plus true measures (`salary_min`, `salary_max`,
`salary_currency`, `salary_period`), boolean facts (`saudi_national_only`,
`out_of_region`), and degenerate dimensions (`title`, `source_url`,
`job_fingerprint`).

### Shared-macro key generation (PK/FK can never drift)

Every surrogate key is produced by a single shared macro in
`dbt/job_market_pipeline/macros/` — `generate_company_key`,
`generate_location_key`, `generate_date_key`, `generate_source_key`,
`generate_career_level_key`. Each dimension **and** the corresponding
`fct_jobs_star` foreign key call the **same** macro, so a dimension's primary
key and the fact's foreign key are generated from identical SQL and cannot drift
apart (no orphaned FKs by construction). Null natural values (e.g. Careerjet's
missing posting dates, ~23% of rows) collapse into a stable "Unknown" member in
each dimension, so every fact FK always resolves.

### Verification

- **Row-count parity:** `fct_jobs_star` = **416** rows = `GOLD.fct_jobs` (416).
- **Referential integrity:** zero orphaned FKs across all five dimensions; each
  fact FK resolves to exactly one dimension row.
- **Tests:** 18 new dbt tests (`not_null` + `unique` on every dimension key,
  plus 5 `relationships` tests from `fct_jobs_star` to each dimension) — all
  passing (24 dbt tests total).

---

## Repository Structure

```
job-market-pipeline/
├── pipeline/
│   ├── collectors/
│   │   ├── careerjet.py          Careerjet Partner API collector (live API)
│   │   ├── tanqeeb.py            Tanqeeb job board scraper
│   │   ├── techmap.py            Techmap RapidAPI collector (reads data/raw/)
│   │   └── jadarat_csv.py        Jadarat open-data CSV reader (evaluated, not active)
│   ├── processing/
│   │   ├── cleaner.py            Field normalization + fingerprint generation
│   │   ├── standardizer.py       Career level mapping, salary parsing
│   │   └── deduplicator.py       2-stage deduplication with cross-run persistence
│   ├── quality/
│   │   └── validator.py          15 quality rules; populates quality_flags
│   ├── modeling/
│   │   └── snowflake_loader.py   Loads curated records into Snowflake jobs table
│   └── runner.py                 Main orchestrator — runs all stages in sequence
├── dbt/
│   └── job_market_pipeline/
│       ├── models/
│       │   ├── staging/          stg_{careerjet,tanqeeb,jooble,techmap}__raw_jobs.sql
│       │   │                     sources.yml
│       │   ├── intermediate/     int_jobs_{cleaned,standardized,deduplicated,quality_flags}.sql
│       │   └── marts/            fct_jobs.sql  schema.yml
│       └── profiles.yml          (gitignored — Snowflake credentials)
├── db/
│   ├── schema.sql                SQLite/PostgreSQL table definitions
│   └── init_db.py                Creates tables from schema.sql
├── scripts/
│   ├── setup_azure_integration.sql  Creates the ADLS external stage (one-time)
│   ├── copy_adls_to_bronze.sql      BRONZE loader — idempotent COPY INTO from the ADLS stage
│   ├── refresh_collection_runs.sql  Populates BRONZE.collection_runs from raw_jobs (audit trail)
│   ├── scrape_tanqeeb.py            Tanqeeb multi-step scrape scripts (2026-09-09)
│   ├── backfill_warn005.sql         Retroactive WARN-005 backfill (run 2026-09-08)
│   └── legacy/
│       ├── land_raw_to_snowflake.py  RETIRED direct loader — superseded by the ADLS path (do not run)
│       └── README.md                 Why it is archived and what replaced it
├── tests/
│   ├── conftest.py               Shared fixtures; temp SQLite DB per test
│   ├── test_cleaner.py
│   ├── test_deduplicator.py
│   ├── test_standardizer.py
│   ├── test_validator.py
│   └── test_pipeline_integration.py
├── data/
│   ├── raw/                      Committed source files for static-load sources
│   │   ├── tanqeeb_jobs.json          117 records (scraped 2026-09-09)
│   │   ├── jooble_combined_2026-09-12.json  109 records (API pull, 9 calls)
│   │   └── techmap_live_raw.json      100 records (RapidAPI pull 2026-09-13)
│   └── samples/                  Small committed fixtures (review_sample.csv)
├── collect_full.py               5-page Careerjet collection runner (495 records)
├── phase5_run.py                 Validation runner; writes quality_log to DB
├── phase6_load.py                Snowflake load runner
├── snowflake_connection_test.py  Smoke test for Snowflake credentials
├── pyproject.toml
├── .env.example
└── docs/
    └── source_investigation.md   Source evaluation report (2026-08-27)
```

---

## Setup

### 1. Clone and install

```bash
git clone <repo-url>
cd job-market-pipeline
pip install -e ".[dev]"
```

Dependencies (from `pyproject.toml`): `requests`, `pandas`, `psycopg2-binary`,
`snowflake-connector-python`, `python-dotenv`. Dev extras: `pytest`, `rapidfuzz`.

### 2. Configure environment

```bash
cp .env.example .env
# then edit .env with your credentials
```

Required variables:

| Variable | Required | Description |
|---|---|---|
| `DB_URL` | Yes | SQLite: `sqlite:///./data/pipeline.db` · PostgreSQL: `postgresql://user:pass@host:5432/db` |
| `CAREERJET_API_KEY` | Yes | Careerjet Partner API affiliation ID — register at careerjet.com/partners/api/ |
| `SNOWFLAKE_ACCOUNT` | Yes | Snowflake account identifier (e.g. `abc12345.us-east-1`) |
| `SNOWFLAKE_USER` | Yes | Snowflake username |
| `SNOWFLAKE_PASSWORD` | Yes | Snowflake password |
| `SNOWFLAKE_WAREHOUSE` | Yes | Compute warehouse name (e.g. `COMPUTE_WH`) |
| `SNOWFLAKE_DATABASE` | Yes | Target database (e.g. `JOB_PIPELINE_DB`) |
| `SNOWFLAKE_SCHEMA` | Yes | Target schema (e.g. `PUBLIC`) |
| `JOOBLE_SA_API_KEY` | For re-collection | Jooble Saudi Arabia search API key — register at `sa.jooble.org/api/about`; needed only to re-pull Jooble data; current integration loads from `data/raw/jooble_combined_2026-09-12.json` |
| `TECHMAP_API_KEY` | For re-collection | Techmap API key (RapidAPI `daily-international-job-postings`) — needed only to re-pull; current integration loads from `data/raw/techmap_live_raw.json` |

The Careerjet `Referer` header defaults to `https://www.careerjet.com.sa/` (hardcoded
in `pipeline/collectors/careerjet.py` as `DEFAULT_REFERRER`). Set `CAREERJET_REFERRER`
in `.env` only if you need to override this default.

### 3. Initialise the local database

```bash
python db/init_db.py
```

Creates the SQLite tables: `collection_runs`, `raw_jobs`, `quality_log`,
`processed_fingerprints`.

### 4. Verify Snowflake connection (optional but recommended)

```bash
python snowflake_connection_test.py
```

Creates the `jobs` table if it does not exist, inserts and queries one test row,
then deletes it. Reports PASS/FAIL with the exact error if any step fails.

---

## Running the Pipeline

### Option A — Unified runner (Careerjet / Tanqeeb / Techmap)

```bash
python -m pipeline.runner --source careerjet   # Careerjet Partner API (locale_code=en_SA)
python -m pipeline.runner --source tanqeeb     # Tanqeeb scraper
python -m pipeline.runner --source techmap     # Techmap RapidAPI (reads data/raw/techmap_live_raw.json)
```

Runs all stages in sequence for the specified source: collect → clean → standardize →
deduplicate → validate → load to Snowflake. Assigns a new `run_id` (UUID) per
execution. Duplicate records are detected via fingerprint and URL matching and are
marked `is_duplicate = True` but never deleted.

> **Note:** Jooble has a `runner.py` path (`python -m pipeline.runner --source jooble`),
> but its collector *replays* the saved `data/raw/jooble_combined_2026-09-12.json`
> (109 records) rather than calling the API live — this preserves Jooble's 500-call
> lifetime quota. Like the other sources, it uploads to ADLS and lands to BRONZE via
> Option B.

> **Note:** `runner.py` was not tested end-to-end during the initial build — the
> per-stage scripts below are the only workflow verified end-to-end for Careerjet.
> `runner.py` also does not write collected records to `raw_jobs`, so there is no
> raw-layer audit trail for runner.py runs.

### Option B — Load BRONZE from the ADLS landing zone and rebuild GOLD via dbt

This is the canonical path for the current 4-source Snowflake dataset. Each
source is collected and uploaded to the ADLS raw landing zone by the runner
(Option A); it is then loaded into Snowflake and transformed:

```bash
# 1. Load any new raw files from the ADLS external stage into BRONZE.raw_jobs
#    (idempotent COPY INTO — only ingests files not already in load history)
#    Run the statement in: scripts/copy_adls_to_bronze.sql

# 2. Refresh the run audit trail: derive BRONZE.collection_runs from raw_jobs
#    (idempotent MERGE + orphan cleanup; preserves provenance notes) — closes #11
#    Run the statement in: scripts/refresh_collection_runs.sql

# 3. Rebuild all Silver views and GOLD.fct_jobs
dbt run  --profiles-dir dbt --project-dir dbt/job_market_pipeline

# 4. Validate
dbt test --profiles-dir dbt --project-dir dbt/job_market_pipeline
```

> The legacy direct loader is **retired** and archived at
> `scripts/legacy/land_raw_to_snowflake.py` (still guarded by `ALLOW_LEGACY_LOAD=1`;
> do not run — it `TRUNCATE`s BRONZE). It was the only writer of
> `BRONZE.collection_runs` until step 2 above closed that gap. See
> `scripts/legacy/README.md`.

### Option C — Stage-by-stage Careerjet (used during initial build)

```bash
# Stage 1: collect (5 pages × 99 records from Careerjet Saudi Arabia)
python collect_full.py

# Stage 2–5: clean, dedup, validate, write quality_log to SQLite
python phase5_run.py

# Stage 6: load non-duplicate, non-rejected records to Snowflake
python phase6_load.py
```

Use this form to inspect intermediate Careerjet results between stages or to
re-run a single stage after a bug fix.

---

## Data Model

### OLTP tables (SQLite / PostgreSQL)

| Table | Purpose |
|---|---|
| `collection_runs` | One row per pipeline execution; tracks run_id, timestamps, record counts |
| `raw_jobs` | Append-only raw storage; full API response in `raw_payload` JSON; never modified |
| `processed_fingerprints` | Persists fingerprints from processed runs; enables cross-run dedup without Snowflake |
| `quality_log` | Every quality rule violation and rejection; queryable audit trail |

### OLAP table (Snowflake)

`jobs` — curated analytical dataset. Non-duplicate, non-rejected records only.
Key fields: `job_id` (PK), `raw_id` (FK to OLTP), `title`, `company_name`,
`location_city`, `location_country`, `career_level`, `salary_min/max/currency`,
`job_fingerprint`, `quality_flags` (VARIANT array), `is_duplicate`,
`is_rejected`, `collected_at`, `processed_at`.

---

## Production Run Results

### Initial Careerjet-only run (2026-09-07)

| Metric | Count |
|---|---|
| Raw records collected | 495 |
| Duplicate records detected | 64 (12.9%) |
| Records rejected by validation | 0 |
| Records loaded to Snowflake (`PUBLIC.jobs`) | **431** |
| Records flagged WARN-005 (low-confidence fingerprint) | 36 (8.3% of loaded) |
| Tests passing | **97** |

### Current 4-source state (2026-09-13)

| Metric | Count |
|---|---|
| Sources integrated | 4 (Careerjet, Tanqeeb, Jooble, Techmap) |
| Raw records in BRONZE (`raw_jobs`) | **425** (99 + 117 + 109 + 100) |
| Curated records in GOLD (`fct_jobs`) | **416** |
| Records filtered by dedup + quality | 9 |
| dbt models | 9 (all passing) |
| dbt schema tests | 6 (all passing) |

---

## Testing

```bash
pytest tests/ -v
```

97 tests across 5 files covering: title/company/location cleaning, fingerprint
generation, salary parsing, career level mapping, all 15 validation rules
(including both firing and non-firing cases for each), deduplication stages
(within-run URL, within-run fingerprint, cross-run URL, cross-run fingerprint,
self-match prevention), and full pipeline integration.

---

## Known Limitations

### 1. Fingerprint false-merge rate (~2.6% of collision records)

Careerjet provides no native job ID and no reliable per-listing posting date
(the `date` API field is the query timestamp). Deduplication therefore uses a
3-component SHA-256 fingerprint: `SHA-256(title | company_name | location_city)`.

A manual audit of 10 sampled fingerprint collision pairs (from 64 total
collision records across 495 collected) found:

- 9/10 pairs are true duplicates — the same posting appearing twice with
  minor Careerjet formatting variations (`"Job Description:"` prefix
  present/absent, en-dash vs hyphen).
- 1/10 is a genuine false merge — a `"Mechanical Engineer"` record where
  both `company_name` and `location_city` are null, reducing the fingerprint
  to a title-only hash. Any two listings with the same generic title and no
  company/city data will collide.

Extrapolating from that 10-record audit sample: an estimated ~10% of the 64
collision records are genuine false merges — roughly 13 records out of 495
(~2.6% of the full dataset). This figure is an extrapolation from a small
sample and should be treated as a rough estimate, not a precise count. These
records are logged with rule `DEDUP-FINGERPRINT-AUDIT` in `quality_log`.

### 2. Low-confidence fingerprints (WARN-005 — 36 records)

36 of the 431 Careerjet records loaded in the initial production run (8.3%) have
both `company_name` and `location_city` null, causing the fingerprint to degrade
toward a title-only hash. These records are flagged `WARN-005 LOW-CONFIDENCE-FINGERPRINT` in
`quality_flags` and are queryable:

```sql
SELECT j.job_id, j.title, j.quality_flags
FROM jobs j,
     LATERAL FLATTEN(input => j.quality_flags) f
WHERE f.value:rule::STRING = 'WARN-005';
```

Records are retained and not rejected — the flag indicates reduced dedup
reliability, not data invalidity.

### 3. Salary sparsity (4.6% coverage)

Only 23 of 495 records (4.6%) include salary data from the Careerjet API.
This is an inherent characteristic of the source, not a parsing failure.
Where present, salaries are parsed to `salary_min`, `salary_max`,
`salary_currency` (SAR default, USD from `$` prefix), and `salary_period`
(monthly/annual).

### 4. No per-listing posting date from Careerjet

Careerjet's `date` API field returns the query timestamp (identical across all
records in a single API call), not the original posting date of each listing.
The field is discarded rather than stored as misleading metadata.
Consequently, `posting_date` is null for all Careerjet records and the
`WARN-004` flag fires on every record — this is expected and documented.
The `STALE-001` and `ERR-001` rules are therefore also inactive for this source.

### 5. Description is an excerpt, not full text

The Careerjet API returns a text excerpt (~242 character mean) rather than the
full job description. This is sufficient for profiling but cannot support
skills extraction or detailed NLP without fetching the detail page.

### 6. Cross-source deduplication is designed but not empirically validated

Cross-source deduplication logic exists — jobs from all four sources are matched
via a shared SHA-256 fingerprint schema (`SHA-256(title | company_name | location_city)`)
in `SILVER.int_jobs_deduplicated`. A job posted on both Tanqeeb and Jooble, for example,
would receive the same fingerprint and be deduplicated correctly.

However, this has not yet been empirically validated. In the current 425-record dataset
(~100 per source across all four sources), zero jobs appeared simultaneously across
multiple sources, so no cross-source duplicate was actually caught and verified.
All deduplicated records were within-source collisions.

This is expected at this sample size — genuine cross-source overlap is rare in a
~100-record slice of each source's much larger corpus. The mechanism should be revisited
and validated with a larger, intentionally overlapping dataset if the project scales.

### 7. Techmap integrated via 100-record live API pull (2026-09-13)

Techmap is included as a fourth source using a live 100-record pull executed on
2026-09-13 via the RapidAPI Techmap endpoint (`daily-international-job-postings`),
Basic (free) tier, 100 req/month quota. The pull covers Saudi Arabia, September 2026,
pages 1–10 (10 jobs/request × 10 pages). Records are saved at
`data/raw/techmap_live_raw.json`; the Techmap collector replays them and the ADLS
path (`pipeline/adls.py` → `scripts/copy_adls_to_bronze.sql`) lands them into BRONZE.

**Source IDs and URLs:** `source_job_id` is the native 24-character MongoDB ObjectID
(`jsonLD.identifier`); `source_url` is the direct third-party job board link
(`jsonLD.url`). Both are real platform values, not synthetic fingerprints.

**Provenance breakdown:** 60% DEjobs, 32% GulfTalent, 8% ATS/Reed. For the
GulfTalent authorization-boundary discussion, see §8.

### 8. Techmap Terms of Service not fully verified; GulfTalent provenance note

Techmap's Terms of Service for automated/scheduled collection could not be fully
verified — `jobdatafeeds.com` defers actual API terms to a RapidAPI subscription
agreement that was not reviewed in depth for this project. This source should be
re-verified before any production scaling or scheduled collection is implemented.

**GulfTalent provenance:** A live pull of 100 records (Sept 2026, Saudi Arabia)
showed 32% of records sourced from GulfTalent and 60% from DEjobs via Techmap's
aggregation layer. GulfTalent was excluded from this project as a direct collection
target due to its own anti-scraping Terms of Service. Techmap's commercial API
relationship with GulfTalent (and other job boards) is the relevant authorization
boundary for this data — analogous to how Careerjet aggregates from company career
pages without each one being individually vetted. This licensing relationship was
not independently verified with Techmap directly.

### 9. Techmap posting_date reliability not empirically validated

`posting_date` for Techmap records is based on the source platform's `dateCreated`
field. Timestamp variation across a 4.5-hour window (02:20–06:48 UTC) and the
`dateActive = dateCreated + platform-standard-duration` formula observed in the
data both suggest these are genuine posting times from the originating platform
(LinkedIn or ATS), not a collection-time artifact like Careerjet's `date` field.
However, this interpretation has not been empirically validated with a multi-day
dataset (all 100 records are from a single pull on 2026-09-13 and cannot confirm
whether `dateCreated` updates on re-sync).

### 10. `load_to_snowflake()` returned a bare int on the "nothing to load" path — **FIXED (commit 98a0e25)**

When every collected record is a duplicate/rejected, `load_to_snowflake()` returned an `int` instead of the `(loaded_count, failed)` tuple the runner unpacks, raising `TypeError: cannot unpack non-iterable int object` at Stage 5 (observed on a techmap re-run where all 100 records were prior duplicates).

**FIXED (commit 98a0e25)** — `load_to_snowflake()` now returns `(0, [])` on the nothing-to-load path, matching its normal return shape. Covered by a 5-case regression suite in `tests/test_snowflake_loader.py`, and verified with a live all-duplicate techmap re-run through the runner (completes cleanly, no `TypeError`).

### 11. `BRONZE.collection_runs` was not populated by the ADLS → COPY INTO path — **FIXED (commit d6ce67a+1)**

The ADLS raw-load path (`pipeline/adls.py` upload → `scripts/copy_adls_to_bronze.sql` COPY INTO) lands `BRONZE.raw_jobs` only; it did **not** write `BRONZE.collection_runs`. That audit table was populated **exclusively** by the legacy loader (now retired to `scripts/legacy/land_raw_to_snowflake.py`), so the run audit trail went stale on the ADLS path.

**FIXED** — `scripts/refresh_collection_runs.sql` derives `BRONZE.collection_runs` directly from `BRONZE.raw_jobs` (`GROUP BY run_id, source_name` → `records_fetched`, `started_at`, `completed_at`) via an idempotent insert-only MERGE, with a static CASE lookup preserving the original provenance notes for the four baseline runs (generic note for any future run). A trailing DELETE removes orphaned audit rows whose `run_id` no longer exists in `raw_jobs` (this also cleaned up a stale legacy techmap run that predated the ADLS reload). Run it after `copy_adls_to_bronze.sql` (see Option B). Verified: exactly 4 rows (careerjet 99, jooble 109, tanqeeb 117, techmap 100), zero orphans, idempotent on re-run, and **zero impact on `GOLD.fct_jobs` / `fct_jobs_star` (both still 416)** — `collection_runs` is an audit table with no dbt model referencing it.

---

## Source Evaluation

A full evaluation of 10 candidate data sources against four criteria
(robots.txt, server barriers, Terms of Service, authentication requirements)
is documented in `docs/source_investigation.md`.

**Summary:** Careerjet Partner API was selected as the primary source
(official partner programme; no scraping required). Jadarat Open Data
(open.data.gov.sa) is a viable secondary source (Arabic-language,
government/public-sector coverage; quarterly CSV under Open Data License).
All other evaluated sources were excluded due to one or more criteria failures.

---

## Data Source Compliance

This pipeline uses the **Careerjet Partner API** under a registered partner
affiliation. The API key (`CAREERJET_API_KEY`) must be obtained through
Careerjet's official partner registration. Do not make API calls without a
valid key set in `.env`.

Batch/scheduled collection compliance: a direct question was submitted to
Careerjet support at the time of initial setup. Refer to any response received
before automating scheduled runs.

---

## Security Notes

- `.env` is gitignored and must never be committed.
- All credentials (`CAREERJET_API_KEY`, `SNOWFLAKE_*`) are read exclusively
  from environment variables. The Careerjet `Referer` header has a hardcoded
  default (`https://www.careerjet.com.sa/`) that can be overridden via
  `CAREERJET_REFERRER` in `.env`.
- `data/pipeline.db` (contains real collected data) is gitignored.
  Only `data/samples/review_sample.csv` (a 20-record anonymised fixture) is committed.
Contributors: Ibtisam