{{ config(materialized='table') }}

-- Dimensional fact table. Same grain and same primary key as GOLD.fct_jobs
-- (one row per curated job; job_id = md5(job_fingerprint)), so the two join 1:1.
-- Descriptive text is replaced by foreign keys into the star dimensions.
--
-- Each FK is computed with the SAME macro the corresponding dimension uses for
-- its primary key, so a fact FK can never drift out of sync with its dimension
-- (no orphaned FKs by construction).

with src as (
    select * from {{ ref('fct_jobs') }}
)

select
    -- Keys / degenerate dimensions
    job_id,
    job_fingerprint,
    source_job_id,
    source_url,
    title,

    -- Foreign keys (same macros as the dimension PKs -> cannot drift)
    {{ generate_company_key('company_name') }}                      as company_id,
    {{ generate_location_key('location_city', 'location_country') }} as location_id,
    {{ generate_date_key('posting_date') }}                        as date_id,
    {{ generate_source_key('source_name') }}                       as source_id,
    {{ generate_career_level_key('career_level') }}                as career_level_id,

    -- Measures
    salary_min,
    salary_max,
    salary_currency,
    salary_period,

    -- Boolean facts
    saudi_national_only,
    out_of_region,

    -- Timestamps
    collected_at,
    processed_at
from src
