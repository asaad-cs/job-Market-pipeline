{{ config(materialized='table') }}

-- Location dimension. Grain is the distinct (city, country) pair, normalized on
-- lower/trim. Null city and/or country collapse into a stable Unknown member
-- via generate_location_key().

with src as (
    select
        {{ generate_location_key('location_city', 'location_country') }} as location_id,
        location_city,
        location_country
    from {{ ref('fct_jobs') }}
)

select
    location_id,
    coalesce(max(location_city), 'Unknown')    as city,
    coalesce(max(location_country), 'Unknown') as country
from src
group by location_id
