{#
    Canonical surrogate-key expression for dim_date.
    Uses a Kimball smart integer key (YYYYMMDD). Null posting_date maps to the
    reserved 0 member ("Unknown / no date") — this absorbs the ~23% of records
    (all Careerjet) that have no per-listing posting date. Called by BOTH
    dim_date and fct_jobs_star so the dimension PK and the fact FK cannot drift.
#}
{% macro generate_date_key(posting_date) -%}
    coalesce(to_number(to_char({{ posting_date }}, 'YYYYMMDD')), 0)
{%- endmacro %}
