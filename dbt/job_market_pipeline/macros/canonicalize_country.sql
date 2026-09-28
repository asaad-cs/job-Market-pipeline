{#
    DIMENSION-LAYER ONLY country cleanup. Confirmed root cause of the exact
    "duplicate" city pairs (Riyadh, Jeddah, Dammam, Medina all appeared
    twice): the SAME city text with two different country values — populated
    ('Saudi Arabia') for some records, NULL for others (when the raw location
    string had no comma to split city from country) — hashes to two different
    location_ids via generate_location_key(city, country).

    IMPORTANT CORRECTION: an earlier version of this macro defaulted EVERY
    NULL country to 'Saudi Arabia'. That incorrectly relabeled genuinely
    foreign cities that also happen to have a NULL country value (e.g. Cairo,
    Egypt) as being in Saudi Arabia. This version only applies that default to
    a fixed allow-list of known Saudi cities/towns actually observed in this
    dataset — anything else with a NULL country (Cairo, or an unrecognized
    city) is left NULL and shows as 'Unknown' in dim_location, rather than
    being guessed.

    SECOND CORRECTION (after the 2026-09-28 fresh pull grew the dataset to
    1,484 records): the fresh data surfaced records where the source itself
    populated country as 'Saudi Arabia' for a genuinely foreign city (same
    class of issue as the original Cairo finding, confirmed against raw
    payloads): Cairo (Egypt), Dubai (UAE), and one record with a country name
    ("Kingdom Of Jordan") sitting in the city field instead of a real city.
    Since these have a NON-NULL country in the source, the "country is not
    null -> passthrough" branch alone would keep the wrong value, so this
    version overrides those specific known cases before that branch runs.
    This is still dimension-layer only: it changes what's DISPLAYED in
    dim_location, not int_jobs_cleaned.location_city/job_fingerprint, so job
    counts and deduplication are unaffected.

    Takes the RAW city (not the canonicalized one) so the override match
    happens on the original text — by the time canonicalize_city() has run,
    'Kingdom Of Jordan' has already been nulled out (see that macro), so
    matching against its OUTPUT would miss this case. The Saudi-city
    allow-list check further down still calls canonicalize_city(city)
    internally to compare against normalized spelling.

    Does not touch int_jobs_cleaned.sql or job_fingerprint — job counts and
    deduplication are unaffected.
#}
{% macro canonicalize_country(country, city) -%}
    case
        -- Known source-data country errors for specific foreign cities/entries
        when lower(trim({{ city }})) = 'cairo'              then 'Egypt'
        when lower(trim({{ city }})) = 'dubai'              then 'United Arab Emirates'
        when lower(trim({{ city }})) = 'kingdom of jordan'  then 'Jordan'
        -- Saudi region name that leaked into the country field: 'Al Hudud ash
        -- Shamaliyah' is the Northern Borders Province of Saudi Arabia (the
        -- Turaif record), not a foreign country. Resolve it to Saudi Arabia so
        -- it displays correctly and is not bucketed as "Outside Saudi Arabia".
        when lower(trim(regexp_replace(replace({{ country }}, chr(160), ' '), '\\s+', ' ')))
             = 'al hudud ash shamaliyah'                     then 'Saudi Arabia'
        when {{ country }} is not null
            then trim(regexp_replace(replace({{ country }}, chr(160), ' '), '\\s+', ' '))
        when lower({{ canonicalize_city(city) }}) in (
            'riyadh', 'jeddah', 'dammam', 'medina', 'mecca', 'al khobar',
            'jubail', 'dhahran', 'abha', 'al ahsa', 'al khabra', 'an nafal',
            'duba', 'hanak', 'khamis mushait', 'qatif', 'rabigh', 'tabuk',
            'taif', 'eastern province', 'qassim'
        ) then 'Saudi Arabia'
        else null
    end
{%- endmacro %}
