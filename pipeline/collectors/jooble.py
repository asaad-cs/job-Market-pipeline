"""
Jooble Saudi Arabia job collector — pipeline collector interface.

Reads from data/raw/jooble_combined_2026-09-12.json — 109 records combined
from 9 Jooble API calls (Sep-09 5-call pull + Sep-12 step-B 4-call pull),
1 duplicate removed.

Quota note: Jooble enforces a 500-call LIFETIME quota (not monthly). To avoid
consuming that finite budget, this collector reads exclusively from the saved
JSON pull — NO live API calls are made. Re-collection requires JOOBLE_SA_API_KEY
and a separate manual pull (see jooble_test_pull.py).

source_job_id : native Jooble job id (rec["id"], e.g. "-1733564566947666663")
source_url    : rec["link"] — Jooble job detail page (sa.jooble.org/jdp/...)
"""

import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger(__name__)

LIVE_FILE = Path(__file__).resolve().parents[2] / "data" / "raw" / "jooble_combined_2026-09-12.json"


def collect(run_id: str) -> list[dict]:
    """
    Load Jooble records from the saved combined-pull JSON and return standard
    raw_jobs records. Reads from the saved file — no network calls are made
    (preserves the 500-call lifetime API quota).

    Returns a list of dicts with keys:
        raw_id, run_id, source_name, source_job_id, source_url,
        raw_payload (JSON string), collected_at (ISO-8601 UTC)
    """
    if not LIVE_FILE.exists():
        raise FileNotFoundError(
            f"Jooble combined-pull file not found: {LIVE_FILE}\n"
            "Re-run jooble_test_pull.py to regenerate it (consumes lifetime quota)."
        )

    with open(LIVE_FILE, encoding="utf-8") as f:
        records = json.load(f)

    if not isinstance(records, list):
        raise ValueError(
            f"Jooble combined-pull file must contain a list of records: {LIVE_FILE}"
        )

    log.info("Jooble collect: reading %d records from saved pull (run_id=%s)",
             len(records), run_id)

    collected_at = datetime.now(timezone.utc).isoformat()
    raw_records = []

    for rec in records:
        raw_records.append({
            "raw_id":        str(uuid.uuid4()),
            "run_id":        run_id,
            "source_name":   "jooble",
            "source_job_id": str(rec.get("id", "") or ""),
            "source_url":    rec.get("link", "") or "",
            "raw_payload":   json.dumps(rec, ensure_ascii=False),
            "collected_at":  collected_at,
        })

    log.info("Jooble collect done: %d records loaded", len(raw_records))
    return raw_records
