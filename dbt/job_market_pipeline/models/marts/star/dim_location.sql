{{ config(materialized='table') }}

-- Location dimension. Grain is the distinct (city, country) pair, normalized on
-- lower/trim. Null city and/or country collapse into a stable Unknown member
-- via generate_location_key().
--
-- City/country are also passed through canonicalize_city()/canonicalize_country()
-- (whitespace/NBSP cleanup + a small alias map) for both the key and the
-- displayed value, so e.g. "Riyadh" + "Riyadh " and "Al Jubail" / "Jubail"
-- collapse into one dimension member instead of showing as look-alike
-- duplicates. This is dimension-layer only: int_jobs_cleaned.location_city and
-- job_fingerprint are untouched, so fct_jobs' row count is unaffected.
--
-- DISPLAY-ONLY foreign-city bucketing: this project's scope is the Saudi Arabia
-- job market. A few source records are genuine, correctly-resolved non-Saudi
-- cities (e.g. Omar/Philippines, Caesarea/Israel, Al Shamal/Qatar). These are
-- accurate data, not bugs — but raw foreign city names in a Saudi-market City
-- filter read as a data-quality issue in the dashboard. The final SELECT
-- relabels the CITY of any row whose resolved country is a real value other
-- than 'Saudi Arabia' (and not 'Unknown') to 'Outside Saudi Arabia', while
-- leaving the country field fully granular and unchanged. This is purely a
-- display relabel in the final projection: location_id / generate_location_key
-- still hash on the original canonicalized city+country, so fct_jobs_star's FK
-- relationship, dim_location row count, fct_jobs count, and job_fingerprint are
-- all completely unaffected.

with src as (
    select
        {{ generate_location_key('location_city', 'location_country') }} as location_id,
        {{ canonicalize_city('location_city') }}       as canonical_city,
        {{ canonicalize_country('location_country', 'location_city') }} as canonical_country
    from {{ ref('fct_jobs') }}
),

resolved as (
    select
        location_id,
        coalesce(max(canonical_city), 'Unknown')    as city,
        coalesce(max(canonical_country), 'Unknown') as country
    from src
    group by location_id
)

select
    location_id,
    case
        when country not in ('Saudi Arabia', 'Unknown') then 'Outside Saudi Arabia'
        else city
    end as city,
    country
from resolved
