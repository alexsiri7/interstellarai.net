"""Unit tests for ops/host/archon-user/fuel_probe.py: python3 -m unittest ops/cron/tests/test_fuel_probe.py"""

from __future__ import annotations

import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "ops/host/archon-user"))
sys.path.insert(0, str(ROOT / "ops/cron/lib"))
import fuel_probe as fp
import lachesis_report as lr

NOW = datetime(2026, 10, 9, 15, 30, tzinfo=UTC)

# The headers a 1-token request on the factory account answered with (#165).
HEADERS = {
    "Anthropic-Ratelimit-Unified-5h-Utilization": "0.27",
    "Anthropic-Ratelimit-Unified-5h-Reset": "1791574800",
    "Anthropic-Ratelimit-Unified-7d-Utilization": "0.03",
    "Anthropic-Ratelimit-Unified-7d-Reset": "1792159200",
    "Anthropic-Ratelimit-Unified-7d-Status": "allowed",
}


class RecordTest(unittest.TestCase):
    def test_the_rate_limit_headers_become_the_plugins_record(self) -> None:
        record = fp.record_from_headers(HEADERS, NOW)
        assert record is not None
        self.assertEqual(record["recordedAt"], "2026-10-09T15:30:00.000Z")
        self.assertEqual(
            record["rateLimits"],
            [
                {"kind": "five_hour", "percentUsed": 27.0, "resetsAt": "2026-10-09T19:40:00.000Z"},
                {"kind": "seven_day", "percentUsed": 3.0, "resetsAt": "2026-10-16T14:00:00.000Z"},
            ],
        )

    def test_no_7_day_window_writes_nothing(self) -> None:
        five_only = {k: v for k, v in HEADERS.items() if "-7d-" not in k}
        self.assertIsNone(fp.record_from_headers(five_only, NOW))
        self.assertIsNone(fp.record_from_headers({}, NOW))
        garbled = {**HEADERS, "Anthropic-Ratelimit-Unified-7d-Utilization": "n/a"}
        self.assertIsNone(fp.record_from_headers(garbled, NOW))

    def test_the_written_file_is_what_lachesis_report_reads(self) -> None:
        record = fp.record_from_headers(HEADERS, NOW)
        assert record is not None
        path = fp.write_record(Path(tempfile.mkdtemp()), record)
        self.assertEqual(
            lr.latest_fuel([str(path)], NOW),
            {
                "weekly_used_percent": 3.0,
                "weekly_resets_at": "2026-10-16T14:00:00.000Z",
                "five_hour_used_percent": 27.0,
            },
        )

    def test_config_dir_follows_claude_config_dir_else_home(self) -> None:
        self.assertEqual(fp.config_dir({"CLAUDE_CONFIG_DIR": "/h/.claude-main", "HOME": "/h"}), Path("/h/.claude-main"))
        self.assertEqual(fp.config_dir({"HOME": "/h"}), Path("/h/.claude"))


if __name__ == "__main__":
    unittest.main()
