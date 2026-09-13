{{ config(materialized='view') }}

-- Extracts Techmap-specific fields from BRONZE.raw_jobs VARIANT payload
-- and maps them to the canonical staging shape shared by all four sources.
--
-- Source: 100-record live pull via RapidAPI Techmap endpoint (2026-09-13),
--   Saudi Arabia, September 2026, pages 1-10. Native IDs and source URLs
--   are real platform values (jsonLD.identifier / jsonLD.url).
--
-- Provenance breakdown: 60% DEjobs, 32% GulfTalent, 8% ATS/Reed.
--   See README Known Limitations §8 for GulfTalent provenance discussion.
--
-- Known limitations:
--   salary_raw  : not present in this export (has_salary is a boolean flag only)
--   city        : some records may contain Arabic city names from GulfTalent records;
--                 handled by the city-alias CASE in int_jobs_cleaned.sql
--   title       : DEjobs portal records may include location suffixes appended by
--                 Techmap aggregator (e.g. " — Riyadh, Saudi Arabia"); not stripped here

with source as (
    select * from {{ source('raw', 'raw_jobs') }}
    where source_name = 'techmap'
)

select
    raw_id,
    run_id,
    source_name,
    source_job_id,
    source_url,
    collected_at,

    -- Title
    nullif(raw_payload:title::string, '')                                   as title_raw,

    -- Company
    nullif(raw_payload:company::string, '')                                 as company_raw,

    -- Location: city + country combined for shared location-parsing logic in
    -- int_jobs_cleaned.sql. country is always "Saudi Arabia" (normalized from "sa"
    -- in the collector). city is the raw Techmap city field.
    case
        when nullif(raw_payload:city::string, '') is not null
            then nullif(raw_payload:city::string, '')
                 || ', '
                 || coalesce(nullif(raw_payload:country::string, ''), 'Saudi Arabia')
        else nullif(raw_payload:country::string, '')
    end                                                                     as location_raw,

    -- Description from jsonLD (present for most records; NULL where not provided)
    nullif(raw_payload:description::string, '')                             as description,

    -- No salary value in this export (has_salary is a boolean flag only)
    cast(null as varchar)                                                   as salary_raw,

    -- api_date_raw: full ISO-8601 UTC timestamp from dateCreated field
    raw_payload:date_created::string                                        as api_date_raw,

    -- posting_date_raw: same as date_created — used as best proxy for posting date.
    -- Timestamp variation across records rules out a single-call collection artifact.
    -- Treated as likely real posting times; not empirically validated with
    -- a multi-day dataset. TRY_TO_DATE() in int_jobs_cleaned handles conversion.
    raw_payload:date_created::string                                        as posting_date_raw

from source
