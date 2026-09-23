"""
Full-pipeline orchestration wrapper — single entrypoint that chains the
verified 4-source ADLS pipeline.

Phases (each independently selectable; see failure semantics below):

  --collect    For each source, run `python -m pipeline.runner --source X`,
               which collects and uploads raw records to the ADLS landing zone.
               LIVE for Careerjet (Partner API) and Tanqeeb (scraper); Jooble
               and Techmap replay saved data/raw/*.json (no API calls — quota
               safe). This phase MUTATES the dataset: new run_ids each time grow
               BRONZE, which changes downstream GOLD counts. It is therefore
               NEVER run by default — you must pass --collect explicitly. The
               flag itself is the confirmation.

  --load       Run scripts/copy_adls_to_bronze.sql (idempotent COPY INTO) then
               scripts/refresh_collection_runs.sql (idempotent MERGE) against
               Snowflake. Idempotent — safe to re-run.

  --transform  Run `dbt run` then `dbt test`. Idempotent (CREATE OR REPLACE).

DEFAULT (no phase flags): --load --transform only. Both are idempotent and
leave GOLD.fct_jobs unchanged (416 stays 416). Live collection is opt-in.

Failure semantics:
  * Collection  — continue-on-error per source (one bad source does not block
                  the others); if EVERY requested source fails, abort before
                  load (nothing new to ingest).
  * Load / Transform — fail-fast: any error stops the run with a non-zero exit.

dbt executable resolution (portable — no hardcoded path): --dbt-path arg, else
$DBT_EXECUTABLE, else `dbt` on PATH.

Examples:
  python scripts/run_full_pipeline.py                     # load + transform (safe, 416 preserved)
  python scripts/run_full_pipeline.py --dry-run           # print the default plan, run nothing
  python scripts/run_full_pipeline.py --collect --load --transform   # full refresh (changes dataset)
  python scripts/run_full_pipeline.py --collect --sources techmap,jooble  # offline replay only
"""

import argparse
import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("run_full_pipeline")

REPO_ROOT     = Path(__file__).resolve().parents[1]
# Allow `python scripts/run_full_pipeline.py` from anywhere to import the
# `pipeline` package (sys.path[0] would otherwise be scripts/, not the repo root).
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

ALL_SOURCES   = ["careerjet", "tanqeeb", "techmap", "jooble"]
COPY_SQL      = REPO_ROOT / "scripts" / "copy_adls_to_bronze.sql"
REFRESH_SQL   = REPO_ROOT / "scripts" / "refresh_collection_runs.sql"
DBT_PROJECT   = REPO_ROOT / "dbt" / "job_market_pipeline"
DBT_PROFILES  = REPO_ROOT / "dbt"


# ── Phase 1: collection ─────────────────────────────────────────────────────────

def phase_collect(sources: list[str], dry_run: bool) -> dict[str, str]:
    """Run the runner for each source. Continue-on-error; returns {source: status}."""
    log.info("PHASE collect: sources: %s", ", ".join(sources))
    results: dict[str, str] = {}
    for src in sources:
        cmd = [sys.executable, "-m", "pipeline.runner", "--source", src]
        if dry_run:
            log.info("  [dry-run] would run: %s", " ".join(cmd))
            results[src] = "DRY-RUN"
            continue
        try:
            subprocess.run(cmd, cwd=str(REPO_ROOT), check=True)
            results[src] = "OK"
        except subprocess.CalledProcessError as exc:
            # continue-on-error: one failing source must not block the rest
            log.error("  source %s FAILED (exit %s) - continuing", src, exc.returncode)
            results[src] = "FAILED"
    return results


# ── Phase 2: load (SQL) ─────────────────────────────────────────────────────────

def _run_sql_file(conn, sql_path: Path) -> None:
    """Execute every statement in a .sql file (quote-/comment-aware). Fail-fast."""
    sql = sql_path.read_text(encoding="utf-8")
    # execute_string handles ';' inside string literals and skips comment-only tails
    for cur in conn.execute_string(sql, remove_comments=True):
        pass  # iterating forces execution; any error raises here


def phase_load(dry_run: bool) -> None:
    """Run COPY INTO then the collection_runs refresh. Fail-fast."""
    log.info("PHASE load: %s then %s", COPY_SQL.name, REFRESH_SQL.name)
    if dry_run:
        log.info("  [dry-run] would execute (Snowflake): %s", COPY_SQL)
        log.info("  [dry-run] would execute (Snowflake): %s", REFRESH_SQL)
        return
    # Reuse the loader's credential-validated connection helper (no duplicated config)
    from pipeline.modeling.snowflake_loader import _get_snowflake_conn
    conn = _get_snowflake_conn()
    try:
        _run_sql_file(conn, COPY_SQL)
        log.info("  COPY INTO complete")
        _run_sql_file(conn, REFRESH_SQL)
        log.info("  collection_runs refresh complete")
    finally:
        conn.close()


# ── Phase 3: transform (dbt) ────────────────────────────────────────────────────

def _resolve_dbt(dbt_path_arg: str | None) -> str:
    cand = dbt_path_arg or os.getenv("DBT_EXECUTABLE") or shutil.which("dbt")
    if not cand:
        raise RuntimeError(
            "dbt executable not found. Pass --dbt-path, set $DBT_EXECUTABLE, "
            "or put dbt on PATH."
        )
    return cand


def phase_transform(dbt_path: str | None, dry_run: bool) -> None:
    """Run `dbt run` then `dbt test`. Fail-fast."""
    dbt = "dbt" if dry_run else _resolve_dbt(dbt_path)
    common = ["--profiles-dir", str(DBT_PROFILES), "--project-dir", str(DBT_PROJECT)]
    for sub in (["run"], ["test"]):
        cmd = [dbt, *sub, *common]
        if dry_run:
            log.info("  [dry-run] would run: %s", " ".join(cmd))
            continue
        log.info("PHASE transform: %s", " ".join(sub))
        subprocess.run(cmd, cwd=str(REPO_ROOT), check=True)  # fail-fast


# ── Orchestration ───────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Full pipeline orchestration wrapper")
    parser.add_argument("--collect", action="store_true",
                        help="Run collection (LIVE Careerjet/Tanqeeb; changes the dataset). Opt-in.")
    parser.add_argument("--load", action="store_true",
                        help="Run COPY INTO + collection_runs refresh (idempotent).")
    parser.add_argument("--transform", action="store_true",
                        help="Run dbt run + dbt test (idempotent).")
    parser.add_argument("--sources", default=",".join(ALL_SOURCES),
                        help="Comma-separated sources for --collect (default: all four).")
    parser.add_argument("--dbt-path", default=None,
                        help="Path to the dbt executable (else $DBT_EXECUTABLE or PATH).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print the plan and run nothing.")
    args = parser.parse_args()

    # Default (no phase flags): load + transform only — idempotent, 416-preserving.
    collect, load, transform = args.collect, args.load, args.transform
    if not (collect or load or transform):
        load = transform = True
        log.info("No phase flags - defaulting to --load --transform (idempotent; live "
                 "collection is opt-in via --collect).")

    sources = [s.strip() for s in args.sources.split(",") if s.strip()]
    unknown = [s for s in sources if s not in ALL_SOURCES]
    if unknown:
        parser.error(f"Unknown source(s): {unknown}. Choose from {ALL_SOURCES}.")

    plan = [p for p, on in (("collect", collect), ("load", load), ("transform", transform)) if on]
    log.info("Plan: %s%s", " -> ".join(plan), "  (DRY RUN)" if args.dry_run else "")

    collect_results: dict[str, str] = {}
    if collect:
        collect_results = phase_collect(sources, args.dry_run)
        # Guard: if collection ran for real and every source failed, abort before load.
        if not args.dry_run and collect_results and all(v == "FAILED" for v in collect_results.values()):
            log.error("All requested sources failed collection — aborting before load.")
            _summary(plan, collect_results)
            return 1

    if load:
        phase_load(args.dry_run)

    if transform:
        phase_transform(args.dbt_path, args.dry_run)

    _summary(plan, collect_results)
    log.info("Pipeline wrapper finished%s.", " (dry run)" if args.dry_run else "")
    return 0


def _summary(plan: list[str], collect_results: dict[str, str]) -> None:
    log.info("-- Summary --------------------------------")
    log.info("  phases: %s", " -> ".join(plan))
    if collect_results:
        for src, status in collect_results.items():
            log.info("  collect %-10s %s", src, status)


if __name__ == "__main__":
    sys.exit(main())
