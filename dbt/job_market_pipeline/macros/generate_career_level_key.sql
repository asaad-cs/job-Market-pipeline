{#
    Canonical surrogate-key expression for dim_career_level.
    Null/blank career levels collapse into a single stable "Unknown" member.
    Called by BOTH dim_career_level and fct_jobs_star so PK and FK cannot drift.
#}
{% macro generate_career_level_key(career_level) -%}
    md5(coalesce(lower(trim({{ career_level }})), '__UNKNOWN__'))
{%- endmacro %}
