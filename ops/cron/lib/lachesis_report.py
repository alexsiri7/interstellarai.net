#!/usr/bin/env python3
"""Report the factory's fuel and run usage to Lachesis (interstellarai.net #146, #147).

Run by lachesis-report.sh every 15 minutes, as asiri:

1. Fuel. The plan-usage Claude Code plugin writes each account's latest rate-limit
   windows to <config dir>/plan-usage.json after every turn. For every account in
   LACHESIS_FUEL_SOURCES, the newest such file whose weekly window has not reset is
   reported with report_fuel. No file, or only stale ones: nothing is reported.

2. Usage. Every archon workflow run that finished since the last report is read
   from archon.db: its repository, the issue or pull request its message names,
   its kind of work (from the workflow), its tokens and its main model. Each is
   reported with report_usage, on the account LACHESIS_RUN_ACCOUNT. A run whose
   previous run on the same issue and workflow failed is also reported as a retry
   with report_run_outcome. Runs naming no number, or in a repository Lachesis
   does not track, are skipped.

Lachesis is called over MCP (streamable HTTP) with a factory token
(LACHESIS_FACTORY_TOKEN). Stdlib only. Nothing here spends Claude tokens.

Env:
  LACHESIS_URL            default https://lachesis.interstellarai.net/mcp
  LACHESIS_FACTORY_TOKEN  required (secrets.env)
  LACHESIS_FUEL_SOURCES   account=path[:path...][;account=...]
  LACHESIS_RUN_ACCOUNT    default factory
  ARCHON_DB               default /mnt/ext-fast/archon-home/.archon/archon.db
  LACHESIS_REPORT_STATE   default ~/.local/state/archon-cron/lachesis-report.json
  --dry-run               print what would be reported; call nothing, save nothing
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

DEFAULT_URL = "https://lachesis.interstellarai.net/mcp"
DEFAULT_DB = "/mnt/ext-fast/archon-home/.archon/archon.db"
DEFAULT_FUEL = (
    "factory=/mnt/ext-fast/archon-home/.claude/plan-usage.json:"
    f"{Path.home()}/.claude/plan-usage.json"
)

# Workflow → Lachesis kind of work. Workflows not listed are not reported.
KINDS = {
    "archon-ship": "implementation",
    "archon-pr-maintenance": "implementation",
    "archon-triage-issue": "triage",
    "archon-review": "audit",
    "archon-smart-pr-review": "audit",
    "archon-security-audit": "audit",
    "archon-requirements-audit": "audit",
    "archon-architect": "spec work",
}

_NUMBER = re.compile(r"#(\d+)")


def log(message: str) -> None:
    print(f"[lachesis-report] {datetime.now(UTC):%Y-%m-%d %H:%M:%S} {message}", flush=True)


# ---------------------------------------------------------------------------
# Lachesis over MCP
# ---------------------------------------------------------------------------


class Lachesis:
    """A minimal MCP client: initialize once, then call tools."""

    def __init__(self, url: str, token: str) -> None:
        self.url = url
        self.token = token
        self.session: str | None = None
        self._id = 0

    def _post(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        request = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(), headers=headers, method="POST"
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            self.session = response.headers.get("Mcp-Session-Id") or self.session
            body = response.read().decode()
            if not body.strip():
                return None
            if "text/event-stream" in (response.headers.get("Content-Type") or ""):
                data = [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]
                body = data[-1] if data else "{}"
            return json.loads(body)

    def _request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self._id += 1
        reply = self._post({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        if not reply or "error" in reply:
            raise RuntimeError(f"{method} failed: {(reply or {}).get('error')}")
        return reply["result"]

    def connect(self) -> None:
        self._request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "lachesis-report", "version": "1"},
            },
        )
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def call(self, tool: str, arguments: dict[str, Any]) -> tuple[bool, str]:
        """Call *tool*; return (ok, text)."""
        result = self._request("tools/call", {"name": tool, "arguments": arguments})
        text = "".join(c.get("text", "") for c in result.get("content", []))
        return not result.get("isError", False), text


# ---------------------------------------------------------------------------
# Fuel
# ---------------------------------------------------------------------------


def parse_sources(spec: str) -> dict[str, list[str]]:
    sources: dict[str, list[str]] = {}
    for part in filter(None, (p.strip() for p in spec.split(";"))):
        account, _, paths = part.partition("=")
        sources[account.strip()] = [p for p in paths.split(":") if p]
    return sources


def _window(record: dict[str, Any], kind: str) -> dict[str, Any] | None:
    return next((w for w in record.get("rateLimits", []) if w.get("kind") == kind), None)


def latest_fuel(paths: list[str], now: datetime) -> dict[str, Any] | None:
    """The report_fuel arguments from the newest readable record whose week is current."""
    best: tuple[str, dict[str, Any]] | None = None
    for path in paths:
        try:
            record = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            continue
        week = _window(record, "seven_day")
        if not week or not week.get("resetsAt"):
            continue
        if datetime.fromisoformat(week["resetsAt"].replace("Z", "+00:00")) <= now:
            continue
        stamp = record.get("recordedAt", "")
        if best is None or stamp > best[0]:
            best = (stamp, record)
    if best is None:
        return None
    record = best[1]
    week = _window(record, "seven_day")
    assert week is not None
    arguments: dict[str, Any] = {
        "weekly_used_percent": week["percentUsed"],
        "weekly_resets_at": week["resetsAt"],
    }
    five = _window(record, "five_hour")
    if five is not None:
        arguments["five_hour_used_percent"] = five["percentUsed"]
    return arguments


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------


def finished_runs(db: str, since: str) -> list[dict[str, Any]]:
    """Runs that finished after *since* (archon's UTC 'YYYY-MM-DD HH:MM:SS'), oldest first,
    each with its token totals and the model that used the most tokens."""
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30)
    conn.row_factory = sqlite3.Row
    try:
        runs = conn.execute(
            """
            SELECT r.id, r.workflow_name, r.user_message, r.status, r.completed_at,
                   c.name AS repo
            FROM remote_agent_workflow_runs r
            LEFT JOIN remote_agent_codebases c ON c.id = r.codebase_id
            WHERE r.completed_at IS NOT NULL AND r.completed_at > ?
            ORDER BY r.completed_at, r.id
            """,
            (since,),
        ).fetchall()
        result = []
        for run in runs:
            tokens_in = tokens_out = 0
            by_model: dict[str, int] = {}
            for (data,) in conn.execute(
                """
                SELECT data FROM remote_agent_workflow_events
                WHERE workflow_run_id = ? AND event_type = 'node_completed'
                """,
                (run["id"],),
            ):
                event = json.loads(data or "{}")
                tokens = event.get("tokens") or {}
                used_in, used_out = int(tokens.get("input") or 0), int(tokens.get("output") or 0)
                tokens_in += used_in
                tokens_out += used_out
                model = (event.get("model_usage") or {}).get("resolved")
                if model:
                    by_model[model] = by_model.get(model, 0) + used_in + used_out
            result.append(
                {
                    **dict(run),
                    "tokens_in": tokens_in,
                    "tokens_out": tokens_out,
                    "model": max(by_model, key=by_model.__getitem__) if by_model else None,
                }
            )
        return result
    finally:
        conn.close()


def usage_report(run: dict[str, Any], account: str) -> dict[str, Any] | None:
    """The report_usage arguments for *run*, or None when it cannot be reported."""
    kind = KINDS.get(run["workflow_name"])
    number = _NUMBER.search(run["user_message"] or "")
    if kind is None or number is None or not run["repo"] or not run["model"]:
        return None
    if run["tokens_in"] + run["tokens_out"] == 0:
        return None
    return {
        "repo": run["repo"],
        "issue": int(number.group(1)),
        "model": run["model"],
        "kind": kind,
        "tokens_in": run["tokens_in"],
        "tokens_out": run["tokens_out"],
        "account": account,
    }


# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    now = datetime.now(UTC)
    state_path = Path(
        os.environ.get("LACHESIS_REPORT_STATE")
        or Path.home() / ".local/state/archon-cron/lachesis-report.json"
    )
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        # First run: start from now, so history is not replayed.
        state = {"since": now.strftime("%Y-%m-%d %H:%M:%S"), "failed": {}}

    token = os.environ.get("LACHESIS_FACTORY_TOKEN", "")
    if not token and not dry_run:
        log("LACHESIS_FACTORY_TOKEN is not set; nothing reported")
        return 1
    lachesis = Lachesis(os.environ.get("LACHESIS_URL", DEFAULT_URL), token)
    if not dry_run:
        lachesis.connect()

    def call(tool: str, arguments: dict[str, Any]) -> bool:
        if dry_run:
            print(f"would call {tool} {json.dumps(arguments)}")
            return True
        ok, text = lachesis.call(tool, arguments)
        if not ok:
            log(f"{tool} refused: {text[:200]}")
        return ok

    sources = parse_sources(os.environ.get("LACHESIS_FUEL_SOURCES", DEFAULT_FUEL))
    for account, paths in sources.items():
        fuel = latest_fuel(paths, now)
        if fuel is None:
            log(f"fuel: no current plan-usage.json for {account}")
        elif call("report_fuel", {"account": account, **fuel}):
            log(f"fuel: {account} {fuel['weekly_used_percent']}% of the week")

    account = os.environ.get("LACHESIS_RUN_ACCOUNT", "factory")
    failed: dict[str, bool] = state.get("failed", {})
    since = state["since"]
    reported = 0
    for run in finished_runs(os.environ.get("ARCHON_DB", DEFAULT_DB), since):
        since = max(since, run["completed_at"])
        report = usage_report(run, account)
        if report is None:
            continue
        key = f"{report['repo']}#{report['issue']}:{run['workflow_name']}"
        if failed.get(key):
            call(
                "report_run_outcome",
                {
                    "repo": report["repo"],
                    "issue": report["issue"],
                    "kind": report["kind"],
                    "outcome": "retry",
                },
            )
        if call("report_usage", report):
            reported += 1
        failed[key] = run["status"] == "failed"
    log(f"usage: {reported} run(s) reported")

    if not dry_run:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(json.dumps({"since": since, "failed": failed}) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (urllib.error.URLError, RuntimeError, sqlite3.Error) as exc:
        log(f"failed: {exc}")
        sys.exit(1)
