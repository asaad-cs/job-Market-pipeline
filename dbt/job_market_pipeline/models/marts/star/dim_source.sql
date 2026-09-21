{{ config(materialized='table') }}

-- Source dimension. One row per distinct data source. source_name is NOT NULL
-- upstream, so no Unknown member is required.

with src as (
    select distinct source_name
    from {{ ref('fct_jobs') }}
)

select
    {{ generate_source_key('source_name') }} as source_id,
    source_name
from src
