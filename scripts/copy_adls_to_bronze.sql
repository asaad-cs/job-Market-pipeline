-- copy_adls_to_bronze.sql
-- Repeatable load of raw JSON files from the ADLS "raw" landing zone
-- (external stage bronze.azure_raw_stage, see setup_azure_integration.sql)
-- into BRONZE.raw_jobs.
--
-- Each file in the stage is a single JSON array of raw records produced by
-- pipeline/adls.py (json.dumps(list_of_records)). The stage's file format uses
-- STRIP_OUTER_ARRAY = TRUE, so each array element is exposed to COPY as one
-- VARIANT row ($1).
--
-- COLUMN MAPPING — matches the live BRONZE.raw_jobs DDL:
--   RAW_ID        VARCHAR(36)  NOT NULL   <- $1:raw_id
--   RUN_ID        VARCHAR(36)  NOT NULL   <- $1:run_id
--   SOURCE_NAME   VARCHAR(100) NOT NULL   <- $1:source_name
--   SOURCE_JOB_ID VARCHAR(500)            <- $1:source_job_id  (nullable)
--   SOURCE_URL    VARCHAR      NOT NULL   <- $1:source_url
--   RAW_PAYLOAD   VARIANT      NOT NULL   <- PARSE_JSON($1:raw_payload)
--   COLLECTED_AT  VARCHAR(50)  NOT NULL   <- $1:collected_at
--
-- Why PARSE_JSON on raw_payload: the collectors store raw_payload as a JSON
-- *string* (json.dumps(payload)), but dbt staging navigates it as a VARIANT
-- object (e.g. raw_payload:title::string). PARSE_JSON converts the string into
-- a parsed object so the RAW_PAYLOAD VARIANT column holds structured JSON, not
-- a quoted string.
--
-- Idempotency: COPY INTO tracks already-loaded files in load history (default
-- ~64 days), so re-running this does NOT reload files it has already ingested.
-- PURGE is left at the default (FALSE) so the landing zone retains the raw
-- files. ON_ERROR = ABORT_STATEMENT so a malformed file fails loudly rather
-- than loading partial data.

-- USE DATABASE <your_database>;   -- e.g. the SNOWFLAKE_DATABASE from .env
-- USE SCHEMA BRONZE;

COPY INTO bronze.raw_jobs
    (raw_id, run_id, source_name, source_job_id, source_url, raw_payload, collected_at)
FROM (
    SELECT
        $1:raw_id::VARCHAR,
        $1:run_id::VARCHAR,
        $1:source_name::VARCHAR,
        $1:source_job_id::VARCHAR,
        $1:source_url::VARCHAR,
        PARSE_JSON($1:raw_payload::VARCHAR),
        $1:collected_at::VARCHAR
    FROM @bronze.azure_raw_stage
)
FILE_FORMAT = (TYPE = JSON STRIP_OUTER_ARRAY = TRUE)
ON_ERROR = 'ABORT_STATEMENT';

-- Verification (run manually after COPY):
-- SELECT source_name, COUNT(*) FROM bronze.raw_jobs GROUP BY source_name;
-- SELECT raw_id, source_name, raw_payload:title::string AS title
--   FROM bronze.raw_jobs LIMIT 5;
