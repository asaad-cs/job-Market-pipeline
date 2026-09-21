{#
    Canonical surrogate-key expression for dim_location.
    Grain is the (city, country) pair. Called by BOTH dim_location and
    fct_jobs_star so the dimension PK and the fact FK cannot drift.
    Null city and/or country collapse into a stable Unknown member.
#}
{% macro generate_location_key(city, country) -%}
    md5(
        coalesce(lower(trim({{ city }})), '__NA__')
        || '|' ||
        coalesce(lower(trim({{ country }})), '__NA__')
    )
{%- endmacro %}
