#!/usr/bin/env python3
"""The tokens of one archon workflow run, for sweep-audits.sh's report_audit_run.

    python3 -B archon_run_tokens.py <workflow> <repo> <since>

<since> is archon's UTC 'YYYY-MM-DD HH:MM:SS', taken just before the launch. The
last run of <workflow> in <repo> (owner/name) that started at or after it and has
finished is summed like lachesis_report.py sums every run. Prints
{"tokens_in": N, "tokens_out": M} and exits 0; when no such run is found or the
DB cannot be read, prints zeros, the reason on stderr, and exits 1.

Env: ARCHON_DB (default /mnt/ext-fast/archon-home/.archon/archon.db).
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lachesis_report import DEFAULT_DB, finished_runs  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: archon_run_tokens.py <workflow> <repo> <since>", file=sys.stderr)
        return 2
    workflow, repo, since = argv
    db = os.environ.get("ARCHON_DB", DEFAULT_DB)
    tokens = {"tokens_in": 0, "tokens_out": 0}
    try:
        runs = [
            run
            for run in finished_runs(db, since)
            if run["workflow_name"] == workflow
            and (run["repo"] or "").lower() == repo.lower()
            and (run["started_at"] or "") >= since
        ]
    except (sqlite3.Error, OSError) as exc:
        print(json.dumps(tokens))
        print(f"archon_run_tokens: {db}: {exc}", file=sys.stderr)
        return 1
    if not runs:
        print(json.dumps(tokens))
        print(f"archon_run_tokens: no finished {workflow} run in {repo} since {since}", file=sys.stderr)
        return 1
    run = runs[-1]
    print(json.dumps({"tokens_in": run["tokens_in"], "tokens_out": run["tokens_out"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
