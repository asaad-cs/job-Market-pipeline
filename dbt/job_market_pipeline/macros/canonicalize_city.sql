{#
    DIMENSION-LAYER ONLY fix for dim_location duplicates. Does NOT touch
    int_jobs_cleaned.location_city or job_fingerprint, so job counts and
    deduplication (fct_jobs) are unaffected — safe to run without a full
    pipeline rebuild.

    Handles:
      1. Non-breaking spaces / tabs / newlines from scraped HTML. Snowflake's
         trim() only strips regular spaces (U+0020), so e.g. "Riyadh " (NBSP)
         survives as a byte-different twin of "Riyadh" and used to hash to a
         different location_id.
      2. A small set of spelling/transliteration variants not covered by the
         _CITY_ALIASES case in int_jobs_cleaned.sql (Jubail / Al Jubail /
         Al Jubayl, Khobar / Al Khobar, Makkah Al Mukarramah / Mecca, plus a
         second round found after the 2026-09-28 fresh Careerjet pull grew
         the dataset to 1,484 records: Al Damam / Dammam, Al Hasa / Al Ahsa,
         Ta'If / Taif, Eastern / Eastern Province, Al Qasim / Qassim).
      3. 'Kingdom Of Jordan' — a country name sitting in the city field on one
         source record — is nulled out here so it doesn't display as a fake
         "city"; canonicalize_country() gives that record's country as Jordan
         (matched on the raw city text, since by the time country-resolution
         runs this macro has already nulled the city).

    Deliberately NOT merged (left as separate, legitimate localities):
      Yanbu Al Sinaiyah / Yanbu' Al Bahr — these name two distinct named
      areas of Yanbu (industrial city vs. sea port), analogous to Al Khobar
      vs. Al Khabra being two different real places despite similar English
      spelling. Merging them would risk conflating two different locations.

    Called by BOTH generate_location_key() and dim_location.sql, so the
    dimension's displayed city and its surrogate key always agree, and
    fct_jobs_star's FK (built from the same key macro) can never drift.
#}
{% macro canonicalize_city(city) -%}
    case
        when {{ city }} is null then null
        else
            case lower(trim(regexp_replace(replace({{ city }}, chr(160), ' '), '\\s+', ' ')))
                when 'al jubail'            then 'Jubail'
                when 'al jubayl'            then 'Jubail'
                when 'jubail'               then 'Jubail'
                when 'khobar'               then 'Al Khobar'
                when 'al khobar'            then 'Al Khobar'
                when 'makkah al mukarramah' then 'Mecca'
                when 'mecca'                then 'Mecca'
                when 'al damam'             then 'Dammam'
                when 'al hasa'              then 'Al Ahsa'
                when 'ta''if'               then 'Taif'
                when 'eastern'              then 'Eastern Province'
                when 'al qasim'             then 'Qassim'
                when 'kingdom of jordan'    then null
                else initcap(trim(regexp_replace(replace({{ city }}, chr(160), ' '), '\\s+', ' ')), ' ''')
            end
    end
{%- endmacro %}
