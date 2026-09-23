# Legacy / archived scripts

Scripts here are **retired**. They are kept for historical reference, provenance,
and rollback value only — they are **not** part of the current pipeline and
should not be run in normal operation.

## `land_raw_to_snowflake.py`

**Status:** Retired 2026-09-23. Frozen since 2026-09-21 (`ALLOW_LEGACY_LOAD=1`
guard retained).

**What it did:** Truncated and reloaded `BRONZE.raw_jobs` and
`BRONZE.collection_runs` for all four sources (Careerjet from SQLite; Tanqeeb,
Jooble, Techmap from `data/raw/*.json`) in a single direct-load pass.

**Why it was retired:** every responsibility it held is now covered by the
verified Azure ADLS load path:

| Legacy responsibility | Replaced by |
|---|---|
| Land raw records into `BRONZE.raw_jobs` | `pipeline/adls.py` upload → `scripts/copy_adls_to_bronze.sql` (idempotent `COPY INTO`) |
| Populate `BRONZE.collection_runs` | `scripts/refresh_collection_runs.sql` (idempotent MERGE derived from `raw_jobs`) — closed README Known Limitation #11 |
| Per-source collection | All four collectors run via `python -m pipeline.runner --source <name>` (Jooble collector added in commit `d6ce67a`) |

The ADLS path has been verified end-to-end (upload → external stage → `COPY INTO`)
for all four sources, and `refresh_collection_runs.sql` reproduces the exact
4-row run audit trail.

**Do not run.** Unlike the append-only ADLS path, this script **`TRUNCATE`s**
`BRONZE.raw_jobs` and `BRONZE.collection_runs` before loading, which would
destroy data landed by the ADLS path. It refuses to execute unless
`ALLOW_LEGACY_LOAD=1` is set; that guard is intentionally kept as
defense-in-depth. It is retained only as a reference for the original baseline
load and the hand-written provenance notes now preserved in
`scripts/refresh_collection_runs.sql`.
