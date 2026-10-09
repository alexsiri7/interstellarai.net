"""Refresh one Claude account's plan-usage.json from the API's rate-limit headers (#165).

The plan-usage plugin writes <config dir>/plan-usage.json only in sessions where it
gets to measure a turn, which headless factory sessions (claude -p, archon runs)
never are, so lachesis-report and the main-account launch gate were left with no
current reading. This sends one 1-token haiku request with the account's own token
and writes the account-wide 5-hour and 7-day windows the response headers carry, in
the plugin's schema, so every reader of that file works unchanged. No 7-day figure
in the response: nothing is written and the exit is 1, never a made-up reading.

Run only by `archon-as-archon [--account main] fuel-probe`, which installs it
root-owned in /usr/local/lib/archon-user and runs it as archon with:
  CLAUDE_CODE_OAUTH_TOKEN  the account's token (never on a command line)
  CLAUDE_CONFIG_DIR        the account's config dir; default $HOME/.claude
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from collections.abc import Mapping
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

URL = "https://api.anthropic.com/v1/messages"
MODEL = "claude-haiku-4-5-20251001"
SYSTEM = "You are Claude Code, Anthropic's official CLI for Claude."
WINDOWS = [("5h", "five_hour"), ("7d", "seven_day")]


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def record_from_headers(headers: Mapping[str, str], now: datetime) -> dict[str, Any] | None:
    """The plan-usage.json record for *headers*, or None without a 7-day window."""
    lower = {k.lower(): v for k, v in headers.items()}
    windows = []
    for prefix, kind in WINDOWS:
        try:
            used = float(lower[f"anthropic-ratelimit-unified-{prefix}-utilization"])
            resets = int(lower[f"anthropic-ratelimit-unified-{prefix}-reset"])
        except (KeyError, ValueError):
            continue
        windows.append(
            {
                "kind": kind,
                "percentUsed": round(used * 100, 1),
                "resetsAt": _iso(datetime.fromtimestamp(resets, UTC)),
            }
        )
    if not any(w["kind"] == "seven_day" for w in windows):
        return None
    return {"recordedAt": _iso(now), "rateLimits": windows, "source": "fuel-probe"}


def config_dir(env: Mapping[str, str]) -> Path:
    if env.get("CLAUDE_CONFIG_DIR"):
        return Path(env["CLAUDE_CONFIG_DIR"])
    return Path(env.get("HOME", "")) / ".claude"


def write_record(directory: Path, record: dict[str, Any]) -> Path:
    path = directory / "plan-usage.json"
    tmp = directory / ".plan-usage.json.tmp"
    tmp.write_text(json.dumps(record) + "\n")
    os.replace(tmp, path)
    return path


def probe(token: str) -> tuple[int, Mapping[str, str]]:
    """(HTTP status, response headers) of one 1-token request."""
    body = {
        "model": MODEL,
        "max_tokens": 1,
        "system": SYSTEM,
        "messages": [{"role": "user", "content": "ok"}],
    }
    request = urllib.request.Request(
        URL,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "oauth-2025-04-20",
            "content-type": "application/json",
            "User-Agent": "archon-fuel-probe/1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return response.status, response.headers
    except urllib.error.HTTPError as err:
        # A rate-limited account still gets its windows, and 100% is exactly the
        # reading that must reach Lachesis.
        return err.code, err.headers


def main() -> int:
    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if not token:
        print("fuel-probe: no Claude credential", file=sys.stderr)
        return 1
    try:
        status, headers = probe(token)
        record = record_from_headers(headers, datetime.now(UTC))
        if record is None:
            print(f"fuel-probe: no rate-limit headers in the response (HTTP {status})", file=sys.stderr)
            return 1
        write_record(config_dir(os.environ), record)
    except (urllib.error.URLError, OSError) as exc:
        print(f"fuel-probe: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(record))
    return 0


if __name__ == "__main__":
    sys.exit(main())
