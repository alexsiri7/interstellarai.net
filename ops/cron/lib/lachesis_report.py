#!/usr/bin/env python3
"""Report the factory's fuel and run usage to Lachesis (interstellarai.net #146, #147).

Run by lachesis-report.sh every 15 minutes, as asiri:

1. Fuel. The plan-usage Claude Code plugin writes each account's latest rate-limit
   windows to <config dir>/plan-usage.json after every turn. For every account in
   LACHESIS_FUEL_SOURCES, the newest such file whose weekly window has not reset is
   reported with report_fuel, if it was recorded within LACHESIS_FUEL_MAX_AGE_HOURS.
   No file, or only stale ones: nothing is reported, so Lachesis keeps the last
   real reading and its time instead of a days-old figure stamped as new (until
   2026-10-08 a file last written on Oct 6 was re-reported every 15 minutes, and
   the main account read 27% used while it was at 38%).
   The plugin never writes in headless sessions (#165), so when factory, or main
   while the owner has ARCHON_MAIN_ACCOUNT=on (lib/main-account.sh), has no
   reading newer than LACHESIS_FUEL_REFRESH_MINUTES, one
   `archon-as-archon [--account main] fuel-probe` refreshes it first from the
   API's rate-limit headers. An account still without a current reading after
   that raises one ntfy escalation per stale episode (re-armed once a current
   reading is reported again).

2. Usage. Every archon workflow run that finished since the last report is read
   from archon.db: its repository, the issue or pull request its message names,
   its kind of work (from the workflow), its tokens and its main model. Each is
   reported with report_usage, on the account the archon shim recorded for its
   launch in the run ledger (lib/quota-pause.sh quota_record_launch), or
   LACHESIS_RUN_ACCOUNT when the ledger names none. A run whose
   previous run on the same issue and workflow failed is also reported as a retry
   with report_run_outcome. Runs naming no number, or in a repository Lachesis
   does not track, are skipped.

Lachesis is called over MCP (streamable HTTP) with a factory token
(LACHESIS_FACTORY_TOKEN). Stdlib only. The only Claude spend is that fuel probe,
one 1-token haiku request.

Env:
  LACHESIS_URL            default https://lachesis.interstellarai.net/mcp
  LACHESIS_FACTORY_TOKEN  required (secrets.env)
  LACHESIS_FUEL_SOURCES   account=path[:path...][;account=...]
  LACHESIS_RUN_ACCOUNT    default factory: the account of a run the ledger does not name
  LACHESIS_RUN_LEDGER     default ~/.local/state/archon-cron/run-accounts.tsv
  LACHESIS_FUEL_MAX_AGE_HOURS  default 2: older plan-usage.json records are not reported
  LACHESIS_FUEL_REFRESH_MINUTES  default 25: older readings are refreshed by a fuel probe
  ARCHON_MAIN_ACCOUNT     on: main may be probed (lachesis-report.sh sets it from the owner's flag)
  NTFY_TOPIC              ntfy.sh topic for the stale-fuel escalation (secrets.env)
  ARCHON_AS_WRAPPER       default /usr/local/bin/archon-as-archon
  ARCHON_DB               default /mnt/ext-fast/archon-home/.archon/archon.db
  LACHESIS_REPORT_STATE   default ~/.local/state/archon-cron/lachesis-report.json
  --dry-run               print what would be reported; call nothing, save nothing
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

DEFAULT_URL = "https://lachesis.interstellarai.net/mcp"
DEFAULT_DB = "/mnt/ext-fast/archon-home/.archon/archon.db"
# The factory account is the archon user's; asiri's own login is the author's main
# account. The fuel probe keeps the factory current through the factory door (archon's
# ~/.claude), and main (~/.claude-main) once the owner turns main on; Claude Code used
# in asiri's own sessions may write main's too.
DEFAULT_FUEL = (
    "factory=/mnt/ext-fast/archon-home/.claude/plan-usage.json;"
    f"main={Path.home()}/.claude/plan-usage.json:/mnt/ext-fast/archon-home/.claude-main/plan-usage.json"
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

# The accounts the factory door can probe, and the wrapper flags that select them.
PROBED: dict[str, list[str]] = {"factory": [], "main": ["--account", "main"]}

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
            # Cloudflare refuses the default Python-urllib agent (error 1010).
            "User-Agent": "lachesis-report/1",
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


def _recorded_at(record: dict[str, Any]) -> datetime | None:
    try:
        return datetime.fromisoformat(str(record.get("recordedAt", "")).replace("Z", "+00:00"))
    except ValueError:
        return None


def latest_fuel(
    paths: list[str], now: datetime, max_age: timedelta = timedelta(hours=2)
) -> dict[str, Any] | None:
    """The report_fuel arguments from the newest readable record whose week is current
    and that was recorded within *max_age* of *now*."""
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
        recorded = _recorded_at(record)
        if recorded is None or now - recorded > max_age:
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


def probeable_accounts(env: Mapping[str, str]) -> set[str]:
    """The accounts this tick may probe: the factory, and main only while the owner
    has turned main on, since every probe is a request on that account."""
    return {"factory", "main"} if env.get("ARCHON_MAIN_ACCOUNT") == "on" else {"factory"}


def probe_fuel(account: str) -> tuple[bool, str]:
    """Refresh *account*'s plan-usage.json with one fuel-probe; (ok, why not)."""
    wrapper = os.environ.get("ARCHON_AS_WRAPPER", "/usr/local/bin/archon-as-archon")
    try:
        done = subprocess.run(
            ["sudo", "-n", "-u", "archon", wrapper, *PROBED[account], "fuel-probe"],
            cwd="/",
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, str(exc)
    if done.returncode == 0:
        return True, ""
    if done.returncode == 64:
        return False, (
            "the installed archon-as-archon has no fuel-probe yet: "
            "sudo -n /usr/local/sbin/archon-ops-promote, then sudo -n /usr/local/sbin/archon-user-install"
        )
    if done.returncode == 69:
        return False, (
            "no main-account credential in the factory: "
            "sudo -n /usr/local/sbin/archon-user-install --set-claude-token --account main"
        )
    last = (done.stderr.strip().splitlines() or [""])[-1]
    return False, f"exit {done.returncode}: {last[:200]}"


def notify(title: str, message: str) -> bool:
    """Send one ntfy alert; True when it was delivered."""
    topic = os.environ.get("NTFY_TOPIC", "")
    if not topic:
        log("cannot escalate: NTFY_TOPIC not set")
        return False
    request = urllib.request.Request(
        f"https://ntfy.sh/{topic}",
        data=message.encode(),
        headers={
            "Title": title,
            "Priority": "high",
            "Tags": "fuelpump,warning",
            "User-Agent": "lachesis-report/1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, OSError) as exc:
        log(f"cannot escalate: {exc}")
        return False


def report_fuel_sources(
    sources: dict[str, list[str]],
    now: datetime,
    max_age: timedelta,
    refresh: timedelta,
    call: Callable[[str, dict[str, Any]], bool],
    escalated: list[str],
    dry_run: bool,
    may_probe: set[str],
    probe: Callable[[str], tuple[bool, str]] = probe_fuel,
    alert: Callable[[str, str], bool] = notify,
) -> list[str]:
    """Report each account's current fuel, probing one in *may_probe* first when older
    than *refresh*; return the accounts whose stale episode has been escalated."""
    still: list[str] = []
    for account, paths in sources.items():
        why = ""
        if account in PROBED and latest_fuel(paths, now, refresh) is None:
            if account not in may_probe:
                why = "not probed while ARCHON_MAIN_ACCOUNT is off (lib/main-account.sh)"
            elif dry_run:
                print(f"would probe {account}")
            else:
                ok, why = probe(account)
                log(f"fuel: probed {account}" if ok else f"fuel: probe of {account} failed: {why}")
        fuel = latest_fuel(paths, now, max_age)
        if fuel is not None:
            if call("report_fuel", {"account": account, **fuel}):
                log(f"fuel: {account} {fuel['weekly_used_percent']}% of the week")
            continue
        hours = max_age.total_seconds() / 3600
        log(f"fuel: no plan-usage.json for {account} recorded in the last {hours:g}h")
        if account in escalated:
            still.append(account)
            continue
        message = (
            f"No fuel reading for {account} in the last {hours:g}h: "
            "Lachesis is budgeting on its last real one."
        ) + (f" Probe: {why}" if why else "")
        if dry_run:
            print(f"would escalate {account}: {message}")
        elif alert(f"Lachesis fuel stale: {account}", message):
            still.append(account)
    return still


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
                   r.started_at, c.name AS repo
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


def read_ledger(path: str) -> list[tuple[int, str, str, str]]:
    """The run ledger the archon shim appends to: (epoch, account, workflow, message)."""
    entries = []
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return []
    for line in lines:
        parts = line.split("\t")
        if len(parts) == 4 and parts[0].isdigit():
            entries.append((int(parts[0]), parts[1], parts[2], parts[3]))
    return entries


def _flat(text: str | None) -> str:
    return re.sub(r"[\t\n\r]", " ", text or "")


def run_account(run: dict[str, Any], ledger: list[tuple[int, str, str, str]], default: str) -> str:
    """The account *run* used: the newest ledger launch of its workflow and message from
    15 minutes before it started to 2 minutes after (as lib/quota-pause.sh matches it)."""
    try:
        started = datetime.strptime(str(run.get("started_at")), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return default
    start = int(started.replace(tzinfo=UTC).timestamp())
    message = _flat(run.get("user_message"))
    account = default
    for epoch, name, workflow, text in ledger:
        if workflow == run.get("workflow_name") and text == message and start - 900 <= epoch <= start + 120:
            account = name
    return account


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
        state = {"since": now.strftime("%Y-%m-%d %H:%M:%S"), "failed": {}, "escalated": []}

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
    escalated = report_fuel_sources(
        sources,
        now,
        max_age=timedelta(hours=float(os.environ.get("LACHESIS_FUEL_MAX_AGE_HOURS") or 2)),
        refresh=timedelta(minutes=float(os.environ.get("LACHESIS_FUEL_REFRESH_MINUTES") or 25)),
        call=call,
        escalated=state.get("escalated", []),
        dry_run=dry_run,
        may_probe=probeable_accounts(os.environ),
    )

    default_account = os.environ.get("LACHESIS_RUN_ACCOUNT", "factory")
    ledger = read_ledger(
        os.environ.get("LACHESIS_RUN_LEDGER")
        or str(Path.home() / ".local/state/archon-cron/run-accounts.tsv")
    )
    failed: dict[str, bool] = state.get("failed", {})
    since = state["since"]
    reported = 0
    for run in finished_runs(os.environ.get("ARCHON_DB", DEFAULT_DB), since):
        since = max(since, run["completed_at"])
        report = usage_report(run, run_account(run, ledger, default_account))
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
        state_path.write_text(json.dumps({"since": since, "failed": failed, "escalated": escalated}) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (urllib.error.URLError, RuntimeError, sqlite3.Error) as exc:
        log(f"failed: {exc}")
        sys.exit(1)
