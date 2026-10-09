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

    def test_a_record_older_than_the_max_age_is_not_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            later = NOW + timedelta(days=2)
            old = _record(Path(d), "a.json", "2026-10-04T20:04:27.860Z", 27, later)
            self.assertIsNone(lr.latest_fuel([old], NOW))
            self.assertEqual(lr.latest_fuel([old], NOW, timedelta(days=3))["weekly_used_percent"], 27)

    def test_a_fresh_record_beats_a_newer_week_figure_that_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            later = NOW + timedelta(days=2)
            fresh = _record(Path(d), "a.json", "2026-10-06T11:30:00Z", 38, later)
            stale = _record(Path(d), "b.json", "2026-10-06T07:00:00Z", 27, later)
            self.assertEqual(lr.latest_fuel([stale, fresh], NOW)["weekly_used_percent"], 38)

    def test_sources_parse(self) -> None:
        self.assertEqual(
            lr.parse_sources("factory=/a:/b; main=/c"), {"factory": ["/a", "/b"], "main": ["/c"]}
        )


class FuelRefreshTest(unittest.TestCase):
    """report_fuel_sources: probe a reading older than the refresh threshold, escalate
    an account still stale after that once per episode."""

    WEEK_END = NOW + timedelta(days=3)

    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.path = str(self.dir / "plan-usage.json")
        self.probed: list[str] = []
        self.alerts: list[tuple[str, str]] = []
        self.reported: list[dict] = []
        self.probe_writes = False
        self.alert_delivers = True

    def _write(self, age: timedelta) -> None:
        _record(self.dir, "plan-usage.json", (NOW - age).isoformat(), 40, self.WEEK_END)

    def probe(self, account: str) -> tuple[bool, str]:
        self.probed.append(account)
        if self.probe_writes:
            self._write(timedelta(0))
            return True, ""
        return False, "x"

    def alert(self, title: str, message: str) -> bool:
        self.alerts.append((title, message))
        return self.alert_delivers

    def call(self, tool: str, arguments: dict) -> bool:
        self.reported.append(arguments)
        return True

    def run_once(self, escalated: list[str], account: str = "factory", dry_run: bool = False) -> list[str]:
        return lr.report_fuel_sources(
            {account: [self.path]},
            NOW,
            max_age=timedelta(hours=2),
            refresh=timedelta(minutes=25),
            call=self.call,
            escalated=escalated,
            dry_run=dry_run,
            probe=self.probe,
            alert=self.alert,
        )

    def test_a_reading_past_the_refresh_threshold_is_probed_and_still_reported(self) -> None:
        self._write(timedelta(minutes=40))
        self.assertEqual(self.run_once([]), [])
        self.assertEqual(self.probed, ["factory"])
        self.assertEqual([r["account"] for r in self.reported], ["factory"])
        self.assertEqual(self.alerts, [])

    def test_a_fresh_reading_is_not_probed(self) -> None:
        self._write(timedelta(minutes=10))
        self.run_once([])
        self.assertEqual(self.probed, [])
        self.assertEqual(len(self.reported), 1)

    def test_an_account_the_door_cannot_probe_is_never_probed(self) -> None:
        self.run_once([], account="other")
        self.assertEqual(self.probed, [])

    def test_the_probes_fresh_reading_is_reported_and_nothing_escalated(self) -> None:
        self.probe_writes = True
        self.assertEqual(self.run_once([], account="main"), [])
        self.assertEqual(self.probed, ["main"])
        self.assertEqual(self.reported[0]["weekly_used_percent"], 40)
        self.assertEqual(self.alerts, [])

    def test_a_stale_episode_is_escalated_once_and_rearmed_by_a_current_reading(self) -> None:
        escalated = self.run_once([])
        self.assertEqual(escalated, ["factory"])
        self.assertEqual(len(self.alerts), 1)
        self.assertIn("factory", self.alerts[0][0])
        self.assertIn("Probe: x", self.alerts[0][1])

        escalated = self.run_once(escalated)
        self.assertEqual(escalated, ["factory"])
        self.assertEqual(len(self.alerts), 1)

        self._write(timedelta(minutes=5))
        escalated = self.run_once(escalated)
        self.assertEqual(escalated, [])

        Path(self.path).unlink()
        self.assertEqual(self.run_once(escalated), ["factory"])
        self.assertEqual(len(self.alerts), 2)

    def test_an_undelivered_escalation_is_retried_next_tick(self) -> None:
        self.alert_delivers = False
        self.assertEqual(self.run_once([]), [])
        self.assertEqual(self.run_once([]), [])
        self.assertEqual(len(self.alerts), 2)

    def test_an_account_no_longer_in_the_sources_is_dropped(self) -> None:
        self._write(timedelta(minutes=5))
        self.assertEqual(self.run_once(["gone"]), [])

    def test_dry_run_neither_probes_nor_alerts(self) -> None:
        self.assertEqual(self.run_once([], dry_run=True), [])
        self.assertEqual(self.probed, [])
        self.assertEqual(self.alerts, [])


class UsageTest(unittest.TestCase):
    def _db(self, d: str) -> str:
        path = f"{d}/archon.db"
        conn = sqlite3.connect(path)
        conn.executescript(
            """
            CREATE TABLE remote_agent_codebases (id TEXT, name TEXT);
            CREATE TABLE remote_agent_workflow_runs (id TEXT, codebase_id TEXT, workflow_name TEXT,
                user_message TEXT, status TEXT, completed_at TEXT, started_at TEXT);
            CREATE TABLE remote_agent_workflow_events (workflow_run_id TEXT, event_type TEXT,
                data TEXT);
            INSERT INTO remote_agent_codebases VALUES ('c1', 'alexsiri7/kith');
            INSERT INTO remote_agent_workflow_runs VALUES
                ('r1', 'c1', 'archon-ship', 'fix #6', 'completed', '2026-10-06 10:00:00',
                 '2026-10-06 09:00:00'),
                ('r0', 'c1', 'archon-ship', 'fix #5', 'completed', '2026-10-01 10:00:00',
                 '2026-10-01 09:00:00');
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


class LedgerTest(unittest.TestCase):
    START = int(datetime(2026, 10, 6, 9, tzinfo=UTC).timestamp())
    RUN = {"workflow_name": "archon-ship", "user_message": "fix #6", "started_at": "2026-10-06 09:00:00"}

    def test_the_launch_recorded_for_the_run_names_its_account(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            path = f"{d}/ledger.tsv"
            Path(path).write_text(
                f"{self.START - 7200}\tmain\tarchon-ship\tfix #6\n"  # an earlier run's launch
                f"{self.START - 3}\tmain\tarchon-ship\tfix #6\n"
                f"{self.START - 2}\tmain\tarchon-triage-issue\ttriage #6\n"
                "garbage line\n"
            )
            ledger = lr.read_ledger(path)
        self.assertEqual(lr.run_account(self.RUN, ledger, "factory"), "main")

    def test_a_run_the_ledger_does_not_name_is_on_the_default_account(self) -> None:
        ledger = [(self.START - 7200, "main", "archon-ship", "fix #6"),
                  (self.START, "main", "archon-ship", "fix #7")]
        self.assertEqual(lr.run_account(self.RUN, ledger, "factory"), "factory")
        self.assertEqual(lr.read_ledger("/nonexistent/ledger.tsv"), [])


if __name__ == "__main__":
    unittest.main()
