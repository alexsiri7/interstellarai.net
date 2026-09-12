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
# That deference is only safe while something does eventually resume a paused
# run, so the snapshot also records WHY each one is paused (see the pause class
# below) and archon_parked_runs names the ones nothing will resume on its own.
#
# Usage:
#   source "$SCRIPT_DIR/lib/archon-active-runs.sh"
#   archon_runs_snapshot                # once per tick, after PATH includes archon
#   if archon_run_active "$repo_dir" "$project" '^archon-ship$' "#42\\b"; then ...
#   msg=$(archon_run_active_msg "$repo_dir" "$project" '^archon-ship$') # first match's user_message
#   archon_runs_known || ...            # false when this tick's snapshot failed
#   archon_parked_runs 1800             # rows for paused runs nothing will resume
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
#   $1 workflow_name  $2 status  $3 origin_path  $4 user_message
#   $5 run_id         $6 pause class            $7 deadline    $8 waiting_since
# Fields 5-8 are appended so every $1..$4 matcher keeps working unchanged.
#
# The pause class is "" for a running run; for a paused one it mirrors
# `runAttention` in archon's packages/workflows/src/schemas/workflow-run.ts
# (isApprovalContext / isGateResolved), so the two can be diffed when the engine
# moves:
#   wait       no approval gate and a durable `wait:` with a readable resumeAt.
#              The server's continuation scan owns the resume.
#   resolved   a gate that was already approved or rejected — also the machine's
#              to resume, not anyone's to answer.
#   gate       a readable, unresolved approval gate. Something outside the run
#              owes it a response.
#   unreadable any other paused shape: no gate and no usable wait, or a gate
#              whose nodeId/message fail the field check. Nothing resumes it.
# runAttention's `child_workflow` and `writeback` variants collapse into `gate`:
# the sdlc pack composes with `include:` (inlined, no sub-runs) and nothing here
# is containerized, and either way the cron response is the same — tell a human,
# touch nothing.
#
# $7 is the latest moment the engine said it would be back, as a unix epoch, and
# is 0 for every class but `wait`: max(wait.resumeAt, continuation_retry_at),
# the two fields listDueWorkflowContinuations selects on
# (archon packages/core/src/db/workflows.ts). continuation_retry_at is top-level
# in metadata and rolls forward 60s per failed resume, while resumeAt is never
# rewritten, so taking the max keeps a scheduler that is actively retrying from
# ever looking stale. $8 is wait.waitingSince as an epoch, 0 otherwise.
#
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
from datetime import datetime

def epoch(value):
    if not isinstance(value, str):
        return 0
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0

def classify(meta):
    """(class, deadline, waiting_since) for a paused run — see the header."""
    wait = meta.get("wait")
    wait = wait if isinstance(wait, dict) else {}
    resume_at = epoch(wait.get("resumeAt"))
    approval = meta.get("approval")
    if approval is None:
        if not resume_at:
            return ("unreadable", 0, 0)
        deadline = max(resume_at, epoch(meta.get("continuation_retry_at")))
        return ("wait", deadline, epoch(wait.get("waitingSince")))
    if not isinstance(approval, dict) or not isinstance(approval.get("nodeId"), str) \
            or not isinstance(approval.get("message"), str) or approval["nodeId"] == "":
        return ("unreadable", 0, 0)
    if approval.get("resolved") in ("approved", "rejected"):
        return ("resolved", 0, 0)
    return ("gate", 0, 0)

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
    run_id = r.get("id") or ""
    pause, deadline, since = classify(meta) if status == "paused" else ("", 0, 0)
    print(f"{name}\t{status}\t{origin}\t{msg}\t{run_id}\t{pause}\t{deadline}\t{since}")
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

# archon_parked_runs <stale_seconds> [hard_max_seconds]
# Print one TSV row per paused run that nothing will resume on its own:
#   run_id <TAB> class <TAB> workflow_name <TAB> origin <TAB> user_message <TAB> deadline_epoch
# Call after archon_runs_snapshot, and only when archon_runs_known — an
# unreadable snapshot has no paused rows and would look like a quiet pipeline.
#
# A `gate` or `unreadable` run is owed something from outside and is reported
# immediately. A `wait` run is reported only once the engine has missed its own
# deadline by <stale_seconds> — which a live continuation scan cannot do, since
# a scheduler deferring after failed resumes keeps continuation_retry_at within
# 60s of now — or once it has sat at one wait for <hard_max_seconds>, the only
# way to see a scheduler that is alive but failing every retry. hard_max
# defaults to 4x stale; runs with no readable waitingSince skip that backstop
# rather than trip it every tick.
archon_parked_runs() {
  local stale="$1" hard_max="${2:-$(( $1 * 4 ))}"
  [ -s "$ARCHON_RUNS_SNAPSHOT" ] || return 0
  awk -F'\t' -v now="$(date +%s)" -v stale="$stale" -v hard="$hard_max" '
    function report() { print $5 "\t" $6 "\t" $1 "\t" $3 "\t" $4 "\t" $7 }
    $6 == "gate" || $6 == "unreadable" { report(); next }
    $6 == "wait" && (now - $7 > stale || ($8 > 0 && now - $8 > hard)) { report() }
  ' "$ARCHON_RUNS_SNAPSHOT"
}
