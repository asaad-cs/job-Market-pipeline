{{ config(materialized='table') }}

-- Company dimension. One row per distinct company (normalized on lower/trim).
-- Records with a null/blank company_name (~10% of the curated set) collapse
-- into a single "Unknown" member via generate_company_key().

with src as (
    select
        {{ generate_company_key('company_name') }} as company_id,
        company_name
    from {{ ref('fct_jobs') }}
)

select
    company_id,
    -- max() ignores nulls, so the Unknown group yields null -> 'Unknown';
    -- for casing variants that share a key it picks one deterministic label.
    coalesce(max(company_name), 'Unknown') as company_name
from src
group by company_id
