{#
    Canonical surrogate-key expression for dim_location.
    Grain is the (city, country) pair. Called by BOTH dim_location and
    fct_jobs_star so the dimension PK and the fact FK cannot drift.
    Null city and/or country collapse into a stable Unknown member.

    City and country are run through canonicalize_city()/canonicalize_country()
    before hashing (whitespace/NBSP cleanup + a small alias map) so that
    dimension-layer duplicates collapse to one member. This is independent of
    int_jobs_cleaned.location_city / job_fingerprint, so it does not affect
    deduplication or job counts.
#}
{% macro generate_location_key(city, country) -%}
    md5(
        coalesce(lower({{ canonicalize_city(city) }}), '__NA__')
        || '|' ||
        coalesce(lower({{ canonicalize_country(country, city) }}), '__NA__')
    )
{%- endmacro %}
