"""
Techmap Saudi Arabia job collector — pipeline collector interface.

Reads from data/raw/techmap_live_raw.json — 100 records collected via
the RapidAPI Techmap endpoint (daily-international-job-postings) on
2026-09-13. Saudi Arabia, September 2026, pages 1-10.

API details: Basic (free) tier; 100 req/month quota; 10 jobs/request (fixed).
source_job_id : jsonLD.identifier — native 24-char MongoDB ObjectID hex string.
source_url    : jsonLD.url — direct third-party job board link (DEjobs, GulfTalent, etc.)

ToS note: not fully verified; see README Known Limitations §8.
"""

import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger(__name__)

LIVE_FILE = Path(__file__).resolve().parents[2] / "data" / "raw" / "techmap_live_raw.json"

_COUNTRY_CODES = {"sa": "Saudi Arabia"}


def collect(run_id: str) -> list[dict]:
    """
    Load Techmap records from the live pull JSON and return standard raw_jobs records.
    Reads from the saved live pull file — no network calls are made.

    Returns a list of dicts with keys:
        raw_id, run_id, source_name, source_job_id, source_url,
        raw_payload (JSON string), collected_at (ISO-8601 UTC)
    """
    if not LIVE_FILE.exists():
        raise FileNotFoundError(
            f"Techmap live file not found: {LIVE_FILE}\n"
            "Re-run _techmap_phase2.py to regenerate it."
        )

    with open(LIVE_FILE, encoding="utf-8") as f:
        records = json.load(f)

    if not isinstance(records, list):
        raise ValueError(
            f"Techmap live file must contain a list of records: {LIVE_FILE}"
        )

    log.info("Techmap collect: reading %d records from live pull (run_id=%s)",
             len(records), run_id)

    collected_at = datetime.now(timezone.utc).isoformat()
    raw_records = []

    for rec in records:
        country_raw = rec.get("country") or ""
        country = _COUNTRY_CODES.get(country_raw.lower(), None) or country_raw or "Saudi Arabia"

        payload = {
            "title":        rec.get("title"),
            "company":      rec.get("company"),
            "city":         rec.get("city"),
            "country":      country,
            "date_created": rec.get("date_created"),
            "date_posted":  rec.get("date_posted"),
            "description":  rec.get("description"),
            "occupation":   rec.get("occupation"),
            "industry":     rec.get("industry"),
            "work_place":   rec.get("work_place"),
            "work_type":    rec.get("work_type"),
            "career_level": rec.get("career_level"),
            "portal":       rec.get("portal"),
            "source":       rec.get("source"),
            "has_salary":   rec.get("has_salary"),
            "is_duplicate": rec.get("is_duplicate"),
        }

        raw_records.append({
            "raw_id":        str(uuid.uuid4()),
            "run_id":        run_id,
            "source_name":   "techmap",
            "source_job_id": rec.get("native_id") or "",
            "source_url":    rec.get("source_url") or "",
            "raw_payload":   json.dumps(payload, ensure_ascii=False),
            "collected_at":  collected_at,
        })

    log.info("Techmap collect done: %d records loaded", len(raw_records))
    return raw_records
