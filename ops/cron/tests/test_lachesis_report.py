"""Unit tests for lib/lachesis_report.py: python3 -m unittest ops/cron/tests/test_lachesis_report.py"""

from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import lachesis_report as lr  # noqa: E402

NOW = datetime(2026, 10, 6, 12, tzinfo=UTC)


def _record(dir: Path, name: str, recorded: str, weekly: float, resets: datetime) -> str:
    path = dir / name
    path.write_text(
        json.dumps(
            {
                "recordedAt": recorded,
                "rateLimits": [
                    {"kind": "five_hour", "percentUsed": 30, "resetsAt": resets.isoformat()},
                    {"kind": "seven_day", "percentUsed": weekly, "resetsAt": resets.isoformat()},
                ],
            }
        )
    )
    return str(path)


class FuelTest(unittest.TestCase):
    def test_the_newest_current_record_wins(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            later = NOW + timedelta(days=2)
            old = _record(Path(d), "a.json", "2026-10-06T09:00:00Z", 40, later)
            new = _record(Path(d), "b.json", "2026-10-06T11:00:00Z", 42, later)
            fuel = lr.latest_fuel([old, new, f"{d}/missing.json"], NOW)
        self.assertEqual(fuel["weekly_used_percent"], 42)
        self.assertEqual(fuel["five_hour_used_percent"], 30)

    def test_a_week_that_has_reset_is_not_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            stale = _record(Path(d), "a.json", "2026-09-29T09:00:00Z", 90, NOW - timedelta(hours=1))
            self.assertIsNone(lr.latest_fuel([stale], NOW))

    def test_sources_parse(self) -> None:
        self.assertEqual(
            lr.parse_sources("factory=/a:/b; main=/c"), {"factory": ["/a", "/b"], "main": ["/c"]}
        )


class UsageTest(unittest.TestCase):
    def _db(self, d: str) -> str:
        path = f"{d}/archon.db"
        conn = sqlite3.connect(path)
        conn.executescript(
            """
            CREATE TABLE remote_agent_codebases (id TEXT, name TEXT);
            CREATE TABLE remote_agent_workflow_runs (id TEXT, codebase_id TEXT, workflow_name TEXT,
                user_message TEXT, status TEXT, completed_at TEXT);
            CREATE TABLE remote_agent_workflow_events (workflow_run_id TEXT, event_type TEXT,
                data TEXT);
            INSERT INTO remote_agent_codebases VALUES ('c1', 'alexsiri7/kith');
            INSERT INTO remote_agent_workflow_runs VALUES
                ('r1', 'c1', 'archon-ship', 'fix #6', 'completed', '2026-10-06 10:00:00'),
                ('r0', 'c1', 'archon-ship', 'fix #5', 'completed', '2026-10-01 10:00:00');
            """
        )
        events = [
            {"tokens": {"input": 100, "output": 10}, "model_usage": {"resolved": "claude-sonnet-5"}},
            {"tokens": {"input": 5, "output": 1}, "model_usage": {"resolved": "claude-haiku-4-5"}},
        ]
        conn.executemany(
            "INSERT INTO remote_agent_workflow_events VALUES ('r1', 'node_completed', ?)",
            [(json.dumps(e),) for e in events],
        )
        conn.commit()
        conn.close()
        return path

    def test_a_finished_run_is_summed_and_named(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            [run] = lr.finished_runs(self._db(d), "2026-10-05 00:00:00")
        report = lr.usage_report(run, "factory")
        self.assertEqual(
            report,
            {
                "repo": "alexsiri7/kith",
                "issue": 6,
                "model": "claude-sonnet-5",
                "kind": "implementation",
                "tokens_in": 105,
                "tokens_out": 11,
                "account": "factory",
            },
        )

    def test_a_run_naming_no_number_is_skipped(self) -> None:
        run = {"workflow_name": "archon-security-audit", "user_message": "audit everything",
               "repo": "alexsiri7/kith", "model": "m", "tokens_in": 1, "tokens_out": 1}
        self.assertIsNone(lr.usage_report(run, "factory"))


if __name__ == "__main__":
    unittest.main()
