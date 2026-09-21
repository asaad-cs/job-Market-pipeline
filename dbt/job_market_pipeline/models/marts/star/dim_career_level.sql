{{ config(materialized='table') }}

-- Career-level dimension. One row per distinct standardized career level
-- (Junior/Mid/Senior/...). Null/blank levels collapse into a stable Unknown
-- member via generate_career_level_key().

with src as (
    select
        {{ generate_career_level_key('career_level') }} as career_level_id,
        career_level
    from {{ ref('fct_jobs') }}
)

select
    career_level_id,
    coalesce(max(career_level), 'Unknown') as career_level
from src
group by career_level_id
