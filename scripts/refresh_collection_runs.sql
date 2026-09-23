-- refresh_collection_runs.sql
-- Populate BRONZE.collection_runs from the authoritative raw data already in
-- BRONZE.raw_jobs, closing the audit-trail gap left by the ADLS -> COPY INTO
-- path (README Known Limitation #11). The ADLS path lands raw_jobs only; this
-- script derives one collection_runs row per (run_id) so the run audit trail
-- stays populated without the frozen legacy loader (land_raw_to_snowflake.py).
--
-- Run this AFTER scripts/copy_adls_to_bronze.sql (once raw_jobs is current).
--
-- Derivation: GROUP BY run_id, source_name over raw_jobs —
--   records_fetched = COUNT(*)
--   started_at      = MIN(collected_at)
--   completed_at    = MAX(collected_at)
--
-- NOTES: preserved via a static CASE lookup keyed on the four baseline run_ids
-- (their original hand-written provenance text), falling back to a generic
-- 'Derived from raw_jobs (ADLS load path)' for any future/unknown run_id.
--
-- Idempotency: INSERT-ONLY MERGE + orphan cleanup. The MERGE inserts runs not
-- already recorded (e.g. a new ADLS run, or the techmap run whose raw_jobs were
-- re-landed under a new run_id by the ADLS path) and NEVER overwrites existing
-- rows. Existing rows keep their curated timestamps and notes — deliberately,
-- because some baseline collected_at values are per-listing dates (Jooble spans
-- 2025-12..2026-09) that would misreport a MIN()-derived started_at.
--
-- The final DELETE removes orphaned audit rows whose run_id no longer exists in
-- raw_jobs (e.g. a stale legacy techmap run superseded by an ADLS reload), so
-- collection_runs exactly mirrors the runs actually present in raw_jobs. This is
-- safe here because raw_jobs is append-only (never trimmed); if a raw-data
-- retention policy is ever introduced, revisit this DELETE so it does not prune
-- audit rows for legitimately-aged-out runs. Safe to re-run: full script is a
-- no-op once collection_runs matches raw_jobs.

-- USE DATABASE <your_database>;   -- e.g. the SNOWFLAKE_DATABASE from .env
-- USE SCHEMA BRONZE;

MERGE INTO BRONZE.collection_runs AS tgt
USING (
    SELECT
        run_id,
        source_name,
        COUNT(*)          AS records_fetched,
        MIN(collected_at) AS started_at,
        MAX(collected_at) AS completed_at
    FROM BRONZE.raw_jobs
    GROUP BY run_id, source_name
) AS src
ON tgt.run_id = src.run_id
WHEN NOT MATCHED THEN INSERT
    (run_id, started_at, completed_at, source_name, records_fetched, notes)
    VALUES (
        src.run_id,
        src.started_at,
        src.completed_at,
        src.source_name,
        src.records_fetched,
        CASE src.run_id
            WHEN 'dfa8e653-0a58-4352-8349-e71a91cdef88'
                THEN 'Repeatability test — 1 page'
            WHEN 'ef572245-583e-4f9a-b512-9d67871ef64a'
                THEN 'Initial scrape via scripts/scrape_tanqeeb.py (2026-09-09)'
            WHEN '24d3e9af-c29d-4bfe-a50d-c3b06945e94d'
                THEN 'Combined from 9 API calls (Sep-09 5-call pull + Sep-12 step-B 4-call pull); '
                     || '500-call lifetime quota; 1 duplicate removed'
            WHEN 'fd0f8a96-b34a-4bea-9ab4-5c6779055210'
                THEN '100-record live pull via RapidAPI Techmap endpoint (2026-09-13); '
                     || 'pages 1-10; Saudi Arabia; native IDs (jsonLD.identifier); '
                     || 'provenance: 60% DEjobs, 32% GulfTalent, 8% ATS/Reed. ToS not fully verified.'
            ELSE 'Derived from raw_jobs (ADLS load path)'
        END
    );

-- Remove orphaned audit rows: any collection_runs entry whose run_id is no
-- longer present in raw_jobs (e.g. a stale legacy run superseded by an ADLS
-- reload under a new run_id). See the retention caveat in the header.
DELETE FROM BRONZE.collection_runs
WHERE run_id NOT IN (SELECT DISTINCT run_id FROM BRONZE.raw_jobs);

-- Verification (run manually after this script):
-- SELECT source_name, run_id, records_fetched, started_at, completed_at, notes
--   FROM BRONZE.collection_runs ORDER BY source_name;
-- Expect 4 rows: careerjet(99), jooble(109), tanqeeb(117), techmap(100).
