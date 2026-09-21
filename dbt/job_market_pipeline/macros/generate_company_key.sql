{#
    Canonical surrogate-key expression for dim_company.
    Called by BOTH dim_company and fct_jobs_star so the dimension PK and the
    fact FK are generated from the identical expression and can never drift.
    Null/blank company names collapse into a single stable "Unknown" member.
#}
{% macro generate_company_key(company_name) -%}
    md5(coalesce(lower(trim({{ company_name }})), '__UNKNOWN__'))
{%- endmacro %}
