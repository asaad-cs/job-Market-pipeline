{#
    Canonical surrogate-key expression for dim_source.
    source_name is NOT NULL upstream, so no Unknown member is required.
    Called by BOTH dim_source and fct_jobs_star so PK and FK cannot drift.
#}
{% macro generate_source_key(source_name) -%}
    md5(lower(trim({{ source_name }})))
{%- endmacro %}
