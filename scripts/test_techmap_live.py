# -*- coding: utf-8 -*-
"""
Single live Techmap (RapidAPI daily-international-job-postings) probe.

Makes ONE live request (two only if the first auth style 401s) to confirm:
  - which auth header the API actually accepts (x-rapidapi-key vs Authorization: Bearer)
  - the response shape (result array / totalCount / jsonLD per job)
  - how much monthly quota remains (from response headers)

Does NOT touch pipeline/collectors/techmap.py. Saves the raw response to a
SEPARATE file (data/raw/techmap_live_probe.json) so the existing replay file
data/raw/techmap_live_raw.json is never overwritten.

Usage: python scripts/test_techmap_live.py
"""

import json
import os
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv

sys.stdout.reconfigure(encoding="utf-8")
load_dotenv()

API_KEY = os.getenv("TECHMAP_API_KEY")
if not API_KEY:
    print("ERROR: TECHMAP_API_KEY not set in .env")
    sys.exit(1)
print(f"Key loaded: {API_KEY[:6]}...{API_KEY[-4:]}")

HOST = "daily-international-job-postings.p.rapidapi.com"
URL = f"https://{HOST}/api/v2/jobs/search"
PARAMS = {
    "countryCode": "sa",
    "page": "1",
    "dateCreated": "2026-09",   # explicit month so we don't rely on the today-minus-2-days default
}

_requests_used = 0


def _dump_quota(resp):
    keys = [k for k in resp.headers
            if any(t in k.lower() for t in ("rate", "limit", "quota", "remaining"))]
    print("  Quota/rate-limit headers:")
    if keys:
        for k in keys:
            print(f"    {k}: {resp.headers[k]}")
    else:
        print("    (none exposed by this plan)")


def _try(headers, label):
    global _requests_used
    print(f"\n=== Attempt: {label} ===")
    print(f"GET {URL}  params={PARAMS}")
    _requests_used += 1
    r = requests.get(URL, headers=headers, params=PARAMS, timeout=30)
    print(f"HTTP {r.status_code}")
    _dump_quota(r)
    return r


# Attempt 1: RapidAPI marketplace headers (the pattern used by scripts/test_jsearch.py)
r = _try({"x-rapidapi-key": API_KEY, "x-rapidapi-host": HOST}, "x-rapidapi-key / x-rapidapi-host")

# Attempt 2 (only if the first 401/403s): provider-doc style Authorization: Bearer
if r.status_code in (401, 403):
    print("  -> auth rejected; trying Authorization: Bearer fallback")
    r = _try({"Authorization": f"Bearer {API_KEY}", "x-rapidapi-host": HOST}, "Authorization: Bearer")

print(f"\n>>> REQUESTS USED THIS SCRIPT: {_requests_used}")

if r.status_code != 200:
    print(f"FAILED — non-200 status. Body (first 500 chars):\n{r.text[:500]}")
    sys.exit(1)

data = r.json()
print(f"\nTop-level keys: {list(data.keys()) if isinstance(data, dict) else type(data).__name__}")

# Report the fields the docs claim (verify against live)
for k in ("totalCount", "totalDocuments", "count", "page", "pageSize"):
    if isinstance(data, dict) and k in data:
        print(f"  {k}: {data[k]}")

# Locate the results array (verify actual key name)
results = None
if isinstance(data, dict):
    for key in ("result", "results", "data", "jobs", "docs"):
        if isinstance(data.get(key), list):
            results = data[key]
            print(f"  results array key: '{key}'  length: {len(results)}")
            break
if results is None:
    print("  WARNING: could not locate a results array — inspect saved raw file.")
    results = []

# Show the shape of the first job so we can map to the 13-column canonical form
if results:
    j0 = results[0]
    print(f"\nFirst job top-level keys: {list(j0.keys())}")
    ld = j0.get("jsonLD") or j0.get("jsonld") or {}
    if ld:
        print(f"jsonLD keys: {list(ld.keys())}")
        for f in ("identifier", "url", "title", "hiringOrganization", "jobLocation", "datePosted", "dateCreated"):
            print(f"  jsonLD.{f}: {str(ld.get(f))[:100]}")

# Save raw response to a NON-conflicting file (never the replay file)
out = Path(__file__).resolve().parents[1] / "data" / "raw" / "techmap_live_probe.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"\nRaw response saved: {out}")
