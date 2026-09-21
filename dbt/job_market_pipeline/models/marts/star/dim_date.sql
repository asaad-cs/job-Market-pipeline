{{ config(materialized='table') }}

-- Date dimension keyed on a Kimball smart integer (YYYYMMDD). Built from the
-- distinct posting_date values actually present in the curated set. The null
-- posting_date (all Careerjet, ~23% of rows) maps to the reserved date_id = 0
-- "Unknown / no date" member, whose calendar attributes are null.

with src as (
    select distinct posting_date
    from {{ ref('fct_jobs') }}
)

select
    {{ generate_date_key('posting_date') }} as date_id,
    posting_date                            as actual_date,
    extract(year  from posting_date)        as year,
    extract(month from posting_date)        as month,
    extract(day   from posting_date)        as day
from src
