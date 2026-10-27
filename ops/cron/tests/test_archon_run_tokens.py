"""Unit tests for lib/archon_run_tokens.py: python3 -m unittest ops/cron/tests/test_archon_run_tokens.py"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import archon_run_tokens  # noqa: E402

SINCE = "2026-10-27 02:00:00"


def _db(d: str) -> str:
    path = f"{d}/archon.db"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE remote_agent_codebases (id TEXT, name TEXT);
        CREATE TABLE remote_agent_workflow_runs (id TEXT, codebase_id TEXT, workflow_name TEXT,
            user_message TEXT, status TEXT, completed_at TEXT, started_at TEXT);
        CREATE TABLE remote_agent_workflow_events (workflow_run_id TEXT, event_type TEXT,
            data TEXT);
        INSERT INTO remote_agent_codebases VALUES ('c1', 'alexsiri7/reli');
        INSERT INTO remote_agent_workflow_runs VALUES
            ('early', 'c1', 'archon-security-audit', 'audit', 'completed',
             '2026-10-27 02:30:00', '2026-10-27 01:59:00'),
            ('audit', 'c1', 'archon-security-audit', 'audit', 'completed',
             '2026-10-27 03:00:00', '2026-10-27 02:00:06'),
            ('ship', 'c1', 'archon-ship', 'fix #6', 'completed',
             '2026-10-27 02:40:00', '2026-10-27 02:10:00');
        """
    )
    events = [
        ("early", {"tokens": {"input": 7000, "output": 700}}),
        ("audit", {"tokens": {"input": 100, "output": 10}}),
        ("audit", {"tokens": {"input": 5, "output": 1}}),
        ("ship", {"tokens": {"input": 9000, "output": 900}}),
    ]
    conn.executemany(
        "INSERT INTO remote_agent_workflow_events VALUES (?, 'node_completed', ?)",
        [(run, json.dumps(e)) for run, e in events],
    )
    conn.commit()
    conn.close()
    return path


def _run(db: str, *argv: str) -> tuple[int, dict]:
    out = io.StringIO()
    with mock.patch.dict(os.environ, {"ARCHON_DB": db}), contextlib.redirect_stdout(out), \
            contextlib.redirect_stderr(io.StringIO()):
        rc = archon_run_tokens.main(list(argv))
    return rc, json.loads(out.getvalue())


class ArchonRunTokensTest(unittest.TestCase):
    def test_only_the_audit_run_launched_since_is_summed(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            rc, tokens = _run(_db(d), "archon-security-audit", "Alexsiri7/Reli", SINCE)
        self.assertEqual(rc, 0)
        self.assertEqual(tokens, {"tokens_in": 105, "tokens_out": 11})

    def test_a_run_started_before_since_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            rc, tokens = _run(_db(d), "archon-security-audit", "alexsiri7/reli", "2026-10-27 02:05:00")
        self.assertEqual(rc, 1)
        self.assertEqual(tokens, {"tokens_in": 0, "tokens_out": 0})

    def test_a_missing_db_prints_zeros(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            rc, tokens = _run(f"{d}/none.db", "archon-security-audit", "alexsiri7/reli", SINCE)
        self.assertEqual(rc, 1)
        self.assertEqual(tokens, {"tokens_in": 0, "tokens_out": 0})


if __name__ == "__main__":
    unittest.main()
