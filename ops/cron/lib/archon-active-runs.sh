#!/usr/bin/env bash
# Parked-run-aware activity detection for archon >= 0.10 (sdlc durable waits).
#
# An sdlc run suspended at a `wait:` node (e.g. archon-ship's CI pause in the
# deliver tail) has status=paused in the run DB and NO live process — pgrep
# guards see nothing and would double-fire the same issue/PR, and the
# stuck-issue detector would re-queue work that is merely parked awaiting the
# server's continuation scheduler. These helpers snapshot the run DB once per
# tick and let guards treat running|paused runs as active, alongside (never
# instead of) the existing pgrep checks.
#
# Usage:
#   source "$SCRIPT_DIR/lib/archon-active-runs.sh"
#   archon_runs_snapshot                # once per tick, after PATH includes archon
#   if archon_run_active "$repo_dir" "$project" '^archon-ship$' "#42\\b"; then ...
#   msg=$(archon_run_active_msg "$repo_dir" "$project" '^archon-ship$') # first match's user_message
#   archon_runs_known || ...            # false when this tick's snapshot failed
#
# Requires: archon >= 0.10 (workflow runs --json), python3, awk.

ARCHON_RUNS_SNAPSHOT="${ARCHON_RUNS_SNAPSHOT:-/tmp/.archon-active-runs.$(basename "${0:-tick}" .sh)}"

# The CLI refuses to start outside a git checkout, even for `workflow runs
# --all`, which does not scope by project. Cron starts every script in $HOME,
# which is not one, so without --cwd every snapshot is empty (2026-09-10: every
# guard had been a no-op since the Stage 2 cutover; pr-maintenance merged
# filmduel #555 under its live ship run, which was entering corrections for a
# Critical review finding). Any checkout satisfies the CLI; this library's own
# repo is always present.
ARCHON_RUNS_CWD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1 when the last archon_runs_snapshot listed both statuses, 0 otherwise.
ARCHON_RUNS_SNAPSHOT_OK=0

# Snapshot all running + paused runs to $ARCHON_RUNS_SNAPSHOT as TSV:
#   workflow_name <TAB> status <TAB> origin_path <TAB> user_message
# A listing failure leaves the snapshot short and sets ARCHON_RUNS_SNAPSHOT_OK=0
# with one stderr line per failed status (cron captures stderr into the tick
# log). Matchers then report "no active run" — the pgrep guards still stand —
# so a tick never stalls on the snapshot; guards whose action is destructive
# consult archon_runs_known and defer instead. Always returns 0.
archon_runs_snapshot() {
  : > "$ARCHON_RUNS_SNAPSHOT"
  ARCHON_RUNS_SNAPSHOT_OK=1
  local st raw problem
  for st in running paused; do
    raw=$(CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 \
      archon workflow runs --all --status "$st" --limit 100 --json --cwd "$ARCHON_RUNS_CWD" 2>/dev/null) || true
    # python stdout (TSV rows) goes to the snapshot; its stderr carries the
    # CLI's own error when the payload is not a run list (the CLI answers
    # {"ok": false, "error": ...} with exit 1 rather than a bare failure).
    if problem=$(printf '%s' "$raw" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:
    sys.stderr.write(raw.strip()[:200] or "no output from archon")
    sys.exit(3)
runs = d.get("runs") if isinstance(d, dict) else None
if not isinstance(runs, list):
    err = d.get("error") if isinstance(d, dict) else None
    sys.stderr.write(str(err or raw.strip()[:200]).replace("\n", " "))
    sys.exit(3)
for r in runs:
    name = r.get("workflow_name") or ""
    msg = (r.get("user_message") or "").replace("\t", " ").replace("\n", " ")
    meta = r.get("metadata") or {}
    origin = ((meta.get("workflow_source") or {}).get("origin")) or ""
    status = r.get("status") or ""
    print(f"{name}\t{status}\t{origin}\t{msg}")
' 2>&1 >> "$ARCHON_RUNS_SNAPSHOT"); then
      continue
    fi
    ARCHON_RUNS_SNAPSHOT_OK=0
    echo "$(date -Is) [archon-active-runs] could not list $st runs — guards cannot see live archon runs this tick: ${problem}" >&2
  done
  return 0
}

# archon_runs_known — exit 0 when this tick's snapshot is trustworthy.
archon_runs_known() {
  [ "$ARCHON_RUNS_SNAPSHOT_OK" = 1 ]
}

# archon_run_active_msg <repo_dir> <project> <name_regex> [msg_regex]
# Matches an active run whose origin is the repo dir (or any path ending in
# /<project>, covering worktree-origin variants) and whose workflow name and
# user_message match the given EREs. Prints the first match's user_message.
# Exit 0 on match, 1 otherwise.
archon_run_active_msg() {
  local repo_dir="$1" project="$2" name_re="$3" msg_re="${4:-}"
  [ -s "$ARCHON_RUNS_SNAPSHOT" ] || return 1
  awk -F'\t' -v repo="$repo_dir" -v proj="/$project" -v nre="$name_re" -v mre="$msg_re" '
    $1 ~ nre && ($3 == repo || substr($3, length($3) - length(proj) + 1) == proj) \
      && (mre == "" || $4 ~ mre) { print $4; found = 1; exit }
    END { exit found ? 0 : 1 }' "$ARCHON_RUNS_SNAPSHOT"
}

# archon_run_active — same match, no output.
archon_run_active() {
  archon_run_active_msg "$@" >/dev/null
}
