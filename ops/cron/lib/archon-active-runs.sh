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
#   ids=$(archon_run_active_ids "$repo_dir" "$project" '^archon-review$' "#42\\b") # every match's run_id
#   if archon_worktree_active "$wt" "$(readlink -f "$wt")"; then ...   # a run owns this worktree
#   archon_worktrees_known || ...       # false when some active run's worktree is unknown
#   archon_runs_known || ...            # false when this tick's snapshot failed
#   archon_parked_runs 1800             # rows for paused runs nothing will resume
#   run_id=$(archon_branch_ci_attention_run "$head") # paused at the CI attention step on this branch
#   run_id=$(archon_branch_running_run "$head") # a running run is working in this branch's worktree
#   run_id=$(archon_branch_active_run "$head")  # a running or paused run holds this branch's worktree
#   archon_failed_runs_snapshot         # once per tick: failed runs nothing adopted
#   run_id=$(archon_branch_failed_run "$head") # such a run left this branch
#   class=$(archon_failed_run_class "$run_id") # review | other — why it failed
#   wt=$(archon_failed_run_path "$run_id")     # its worktree
#   archon_failed_runs_known || ...     # false when that listing failed
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

# The deliver tail's CI attention pause (archon-deliver.yaml
# ci-attention.attention-ci-pause): late red the branch did not introduce.
# pr-maintenance resumes it once the PR is green; archon_parked_runs reports it
# only after ARCHON_CI_ATTENTION_MAX_SECONDS.
ARCHON_CI_ATTENTION_STEP_RE='(^|[._])attention-ci-pause$'
ARCHON_CI_ATTENTION_MAX_SECONDS="${ARCHON_CI_ATTENTION_MAX_SECONDS:-86400}"
# pipeline-health's parked-run markers. pr-maintenance leaves
# ci-resume-failed-<run_id> there while its resume of a green CI attention run
# fails, so check_parked_runs alerts with that instead of the pause message.
# shellcheck disable=SC2034  # consumed by pr-maintenance and pipeline-health
ARCHON_PARKED_MARKER_DIR="$HOME/.archon/pipeline-health-state/parked"

# Snapshot all running + paused runs to $ARCHON_RUNS_SNAPSHOT as TSV:
#   $1 workflow_name  $2 status  $3 origin_path  $4 user_message
#   $5 run_id         $6 pause class            $7 deadline    $8 waiting_since
#   $9 working_path (the run's worktree)  $10 pause step  $11 pause message
# Fields 5-11 are appended so every $1..$4 matcher keeps working unchanged.
#
# The pause class is "" for a running run; for a paused one it mirrors
# `runAttention` in archon's packages/workflows/src/schemas/workflow-run.ts
# (isApprovalContext / isGateResolved), so the two can be diffed when the engine
# moves:
#   attention  a durable `wait:` with kind "attention" — runAttention's
#              `action_required`, checked before any gate. Something outside the
#              run is owed an action (re-run a check, fix a secret), then
#              `archon workflow resume`. No deadline; $8 is its waitingSince.
#              Before this class existed such runs read as `unreadable`.
#   wait       no approval gate and a durable `wait:` with a readable resumeAt.
#              The server's continuation scan owns the resume.
#   resolved   a gate that was already approved or rejected — the machine's to
#              resume, not anyone's to answer. It still gets reported, because
#              the auto-resume is a single synchronous attempt the approver
#              makes (`--json` approve skips it entirely) and the continuation
#              scan selects on metadata.wait, never metadata.approval — so a
#              resolved gate that survives one tick has nothing left to resume
#              it.
#   gate       a readable, unresolved approval gate. Something outside the run
#              owes it a response. runAttention's `writeback` variant lands
#              here too: it is an awaiting_response gate there as well.
#   blocked_on_child  a `workflow:` sub-run node whose child is still going.
#              Normal progress, not a stall: the parent is resumed by the
#              child's own termination hook rather than by the continuation
#              scan, so nothing here is owed. Not reachable in the current sdlc
#              pack (no `container:`, no sub-run node), and the approval context
#              carries no timestamp to age it by, so it is excluded outright
#              rather than given a staleness backstop.
#   unreadable any other paused shape: no gate and no usable wait, a gate whose
#              nodeId/message fail the field check, or a child_workflow pause
#              with no child to follow. Nothing resumes it.
#
# $7 is the latest moment the engine said it would be back, as a unix epoch, and
# is 0 for every class but `wait`: max(wait.resumeAt, continuation_retry_at),
# the two fields listDueWorkflowContinuations selects on
# (archon packages/core/src/db/workflows.ts). continuation_retry_at is top-level
# in metadata and rolls forward 60s per failed resume, while resumeAt is never
# rewritten, so taking the max keeps a scheduler that is actively retrying from
# ever looking stale. $8 is wait.waitingSince as an epoch, 0 otherwise.
#
# $10 and $11 name what an `attention` or `gate` pause is waiting on, and are
# empty for every other class. For `attention` they are archon's step name
# (workflowWaitStepName: "<nodeId>.<bodyWaitId>" for a loop-owned wait) and
# wait.message; for `gate`, approval.nodeId and approval.message.
#
# A listing failure, or a page holding fewer runs than its `total` (the listing
# is capped at 100), leaves the snapshot short and sets ARCHON_RUNS_SNAPSHOT_OK=0
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

def nonempty(value):
    return isinstance(value, str) and value != ""

def classify(meta):
    """(class, deadline, waiting_since, step, need) for a paused run — see the header."""
    wait = meta.get("wait")
    wait = wait if isinstance(wait, dict) else {}
    if wait.get("kind") == "attention" and nonempty(wait.get("nodeId")) \
            and isinstance(wait.get("message"), str):
        step = wait["nodeId"]
        if wait.get("owner") == "loop_group" and nonempty(wait.get("bodyWaitId")):
            step = step + "." + wait["bodyWaitId"]
        return ("attention", 0, epoch(wait.get("waitingSince")), step, wait["message"])
    resume_at = epoch(wait.get("resumeAt"))
    approval = meta.get("approval")
    if approval is None:
        if not resume_at:
            return ("unreadable", 0, 0, "", "")
        deadline = max(resume_at, epoch(meta.get("continuation_retry_at")))
        return ("wait", deadline, epoch(wait.get("waitingSince")), "", "")
    if not isinstance(approval, dict) or not nonempty(approval.get("nodeId")) \
            or not isinstance(approval.get("message"), str):
        return ("unreadable", 0, 0, "", "")
    if approval.get("resolved") in ("approved", "rejected"):
        return ("resolved", 0, 0, "", "")
    if approval.get("type") == "child_workflow":
        child = approval.get("childRunId")
        if not nonempty(child):
            return ("unreadable", 0, 0, "", "")
        return ("blocked_on_child", 0, 0, "", "")
    return ("gate", 0, 0, approval["nodeId"], approval["message"])

def field(value):
    return (value or "").replace("\t", " ").replace("\n", " ")

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
total = d.get("total")
if isinstance(total, int) and total > len(runs):
    sys.stderr.write(f"listing truncated: {len(runs)} of {total} runs returned")
    sys.exit(3)
for r in runs:
    name = r.get("workflow_name") or ""
    msg = field(r.get("user_message"))
    meta = r.get("metadata") or {}
    origin = ((meta.get("workflow_source") or {}).get("origin")) or ""
    status = r.get("status") or ""
    run_id = r.get("id") or ""
    wpath = field(r.get("working_path"))
    pause, deadline, since, step, need = classify(meta) if status == "paused" else ("", 0, 0, "", "")
    print(f"{name}\t{status}\t{origin}\t{msg}\t{run_id}\t{pause}\t{deadline}\t{since}\t{wpath}"
          f"\t{field(step)}\t{field(need)}")
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

# _archon_runs_match <field> <first_only> <repo_dir> <project> <name_regex> [msg_regex]
# Matches active runs whose origin is the repo dir (or any path ending in
# /<project>, covering worktree-origin variants) and whose workflow name and
# user_message match the given EREs. Prints snapshot column <field> of the
# first match, or of every match unless <first_only> is 1.
# Exit 0 on match, 1 otherwise.
_archon_runs_match() {
  local field="$1" first="$2" repo_dir="$3" project="$4" name_re="$5" msg_re="${6:-}"
  [ -s "$ARCHON_RUNS_SNAPSHOT" ] || return 1
  awk -F'\t' -v f="$field" -v first="$first" -v repo="$repo_dir" -v proj="/$project" -v nre="$name_re" -v mre="$msg_re" '
    $1 ~ nre && ($3 == repo || substr($3, length($3) - length(proj) + 1) == proj) \
      && (mre == "" || $4 ~ mre) { print $f; found = 1; if (first == 1) exit }
    END { exit found ? 0 : 1 }' "$ARCHON_RUNS_SNAPSHOT"
}

# archon_run_active_msg <repo_dir> <project> <name_regex> [msg_regex]
# Prints the first matching run's user_message (see _archon_runs_match).
archon_run_active_msg() {
  _archon_runs_match 4 1 "$@"
}

# archon_run_active_ids <repo_dir> <project> <name_regex> [msg_regex]
# Prints the run_id of every matching run, one per line.
archon_run_active_ids() {
  _archon_runs_match 5 0 "$@"
}

# archon_run_active — same match, no output.
archon_run_active() {
  archon_run_active_msg "$@" >/dev/null
}

# archon_worktree_active <path>... — exit 0 when a running or paused run's
# worktree is exactly one of the given paths. The origin that archon_run_active
# matches on is the same main clone for every worktree of a project, so it
# cannot say which worktree a run is using.
archon_worktree_active() {
  [ -s "$ARCHON_RUNS_SNAPSHOT" ] || return 1
  local path
  for path in "$@"; do
    [ -n "$path" ] || continue
    awk -F'\t' -v p="$path" '$9 == p { found = 1; exit } END { exit found ? 0 : 1 }' \
      "$ARCHON_RUNS_SNAPSHOT" && return 0
  done
  return 1
}

# archon_worktrees_known — exit 0 when the snapshot is trustworthy and records a
# worktree for every run in it. archon writes working_path once, and a run can
# be live without one; archon_worktree_active cannot see that run's worktree,
# so a guard that deletes on "no run owns this worktree" defers instead.
archon_worktrees_known() {
  archon_runs_known || return 1
  awk -F'\t' '$9 == "" { exit 1 }' "$ARCHON_RUNS_SNAPSHOT"
}

# archon_parked_runs <stale_seconds> [hard_max_seconds]
# Print one TSV row per paused run that nothing will resume on its own:
#   run_id <TAB> class <TAB> workflow_name <TAB> origin <TAB> user_message
#   <TAB> deadline_epoch <TAB> pause step <TAB> pause message
# Call after archon_runs_snapshot, and only when archon_runs_known — an
# unreadable snapshot has no paused rows and would look like a quiet pipeline.
#
# A `gate`, `resolved` or `unreadable` run is reported immediately: the first
# two have nothing left that would resume them on its own, and the last cannot
# say. A `blocked_on_child` run is never reported — its child's termination
# resumes it. A `wait` run is reported only once the engine has missed its own
# deadline by <stale_seconds> — which a live continuation scan cannot do, since
# a scheduler deferring after failed resumes keeps continuation_retry_at within
# 60s of now — or once it has sat at one wait for <hard_max_seconds>, the only
# way to see a scheduler that is alive but failing every retry. hard_max
# defaults to 4x stale; runs with no readable waitingSince skip that backstop
# rather than trip it every tick.
#
# An `attention` run is reported immediately, unless it is at the CI attention
# step: pr-maintenance resumes that one once its PR is green, so it is reported
# only after waiting ARCHON_CI_ATTENTION_MAX_SECONDS (or at once when it has no
# readable waitingSince to age it by).
archon_parked_runs() {
  local stale="$1" hard_max="${2:-$(( $1 * 4 ))}"
  [ -s "$ARCHON_RUNS_SNAPSHOT" ] || return 0
  awk -F'\t' -v now="$(date +%s)" -v stale="$stale" -v hard="$hard_max" \
      -v cire="$ARCHON_CI_ATTENTION_STEP_RE" -v cimax="$ARCHON_CI_ATTENTION_MAX_SECONDS" '
    function report() { print $5 "\t" $6 "\t" $1 "\t" $3 "\t" $4 "\t" $7 "\t" $10 "\t" $11 }
    $6 == "gate" || $6 == "resolved" || $6 == "unreadable" { report(); next }
    $6 == "attention" && ($10 !~ cire || $8 == 0 || now - $8 > cimax) { report(); next }
    $6 == "wait" && (now - $7 > stale || ($8 > 0 && now - $8 > hard)) { report() }
  ' "$ARCHON_RUNS_SNAPSHOT"
}

# archon_branch_ci_attention_run <branch> — print the id of a run paused at
# the CI attention step whose worktree is <branch> (archon names each run's
# worktree after its branch, as archon_branch_failed_run relies on). Exit 0 on
# match, 1 otherwise.
archon_branch_ci_attention_run() {
  [ -n "$1" ] && [ -s "$ARCHON_RUNS_SNAPSHOT" ] || return 1
  awk -F'\t' -v tail="/$1" -v cire="$ARCHON_CI_ATTENTION_STEP_RE" '
    $6 == "attention" && $10 ~ cire && substr($9, length($9) - length(tail) + 1) == tail {
      print $5; found = 1; exit }
    END { exit found ? 0 : 1 }' "$ARCHON_RUNS_SNAPSHOT"
}

# archon_branch_running_run <branch> — print the id of a RUNNING run whose
# worktree is <branch> (archon names each run's worktree after its branch).
# Such a run is editing that checkout right now; anything else that commits
# there changes the tree under it. Exit 0 on match, 1 otherwise.
archon_branch_running_run() {
  [ -n "$1" ] && [ -s "$ARCHON_RUNS_SNAPSHOT" ] || return 1
  awk -F'\t' -v tail="/$1" '
    $2 == "running" && substr($9, length($9) - length(tail) + 1) == tail {
      print $5; found = 1; exit }
    END { exit found ? 0 : 1 }' "$ARCHON_RUNS_SNAPSHOT"
}

# archon_branch_active_run <branch> — print the id of a RUNNING or PAUSED run
# whose worktree is <branch>: anything in the snapshot, which holds only those
# two statuses. A paused run (a CI wait, a gate) still owns its PR; the
# review-not-ready deadline must not call such a PR abandoned. Exit 0 on
# match, 1 otherwise.
archon_branch_active_run() {
  [ -n "$1" ] && [ -s "$ARCHON_RUNS_SNAPSHOT" ] || return 1
  awk -F'\t' -v tail="/$1" '
    substr($9, length($9) - length(tail) + 1) == tail {
      print $5; found = 1; exit }
    END { exit found ? 0 : 1 }' "$ARCHON_RUNS_SNAPSHOT"
}

# Failed runs nothing has adopted, as "<run_id>\t<working_path>\t<class>"
# lines. The class reads the run's metadata.error, failing closed:
#   review  an archon-ship-block run whose ONLY failed top-level node is the
#           deliver__rounds loop group, and every failed node inside it is a
#           review__* node: the AI review stage broke (unparseable structured
#           output, a node that touched the checkout), not the change. The
#           error must read exactly
#             DAG workflow '<wf>' completed with failures: 'deliver__rounds':
#             Loop-group node 'deliver__rounds' failed at iteration <n>: <body>
#           and every "'<id>': " that opens <body> or follows "; " in it must
#           name a review__ node. A second top-level failure is joined the same
#           way ("; '<id>': ", archon dag-executor.ts), and no top-level node of
#           the sdlc pack is named review__*, so it makes the run `other`.
#   other   anything else, including an error that is missing or unreadable.
ARCHON_FAILED_RUNS_SNAPSHOT="${ARCHON_FAILED_RUNS_SNAPSHOT:-$ARCHON_RUNS_SNAPSHOT.failed}"
# The open-work inbox is never paged and only grows (346 rows on 2026-10-09),
# so ask for far more than it holds and treat a full page as unreadable.
ARCHON_FAILED_RUNS_LIMIT=10000
ARCHON_FAILED_RUNS_OK=0

# archon_failed_runs_snapshot — once per tick: snapshot every failed run
# nothing has adopted (`workflow runs --open`, all projects) to
# $ARCHON_FAILED_RUNS_SNAPSHOT. A listing failure leaves the snapshot empty and
# ARCHON_FAILED_RUNS_OK=0 with one stderr line, as archon_runs_snapshot does.
# Always returns 0.
archon_failed_runs_snapshot() {
  : > "$ARCHON_FAILED_RUNS_SNAPSHOT"
  ARCHON_FAILED_RUNS_OK=0
  local raw problem
  raw=$(CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 \
    archon workflow runs --all --open --limit "$ARCHON_FAILED_RUNS_LIMIT" --json --cwd "$ARCHON_RUNS_CWD" 2>/dev/null) || true
  if problem=$(printf '%s' "$raw" | python3 -c '
import json, re, sys
limit = int(sys.argv[1])
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
if len(runs) >= limit:
    sys.stderr.write(f"listing may be truncated: {len(runs)} runs at --limit {limit}")
    sys.exit(3)
# \x27 is a single quote: this program sits inside a single-quoted shell word.
ROUNDS = re.compile(r"DAG workflow \x27[^\x27]*\x27 completed with failures: \x27deliver__rounds\x27: "
                    r"Loop-group node \x27deliver__rounds\x27 failed at iteration [0-9]+: ")
NODE = re.compile(r"(?:^|; )\x27([^\x27]*)\x27: ")

def failure_class(meta):
    err = meta.get("error") if isinstance(meta, dict) else None
    if not isinstance(err, str):
        return "other"
    m = ROUNDS.match(err)
    if not m:
        return "other"
    ids = NODE.findall(err[m.end():])
    if ids and all(i.startswith("review__") for i in ids):
        return "review"
    return "other"

for r in runs:
    run_id = r.get("id") or ""
    wpath = (r.get("working_path") or "").replace("\t", " ").replace("\n", " ")
    cls = failure_class(r.get("metadata"))
    print(f"{run_id}\t{wpath}\t{cls}")
' "$ARCHON_FAILED_RUNS_LIMIT" 2>&1 > "$ARCHON_FAILED_RUNS_SNAPSHOT"); then
    ARCHON_FAILED_RUNS_OK=1
    return 0
  fi
  : > "$ARCHON_FAILED_RUNS_SNAPSHOT"
  echo "$(date -Is) [archon-active-runs] could not list failed runs — guards cannot see failed archon runs this tick: ${problem}" >&2
  return 0
}

# archon_failed_runs_known — exit 0 when this tick's failed-run snapshot is trustworthy.
archon_failed_runs_known() {
  [ "$ARCHON_FAILED_RUNS_OK" = 1 ]
}

# archon_branch_failed_run <branch> — print the id of a failed, unadopted run
# whose worktree is <branch>: archon names each run's worktree after its branch
# (.../worktrees/archon/task-<workflow>-<ts>). Exit 0 on match, 1 otherwise.
archon_branch_failed_run() {
  [ -n "$1" ] && [ -s "$ARCHON_FAILED_RUNS_SNAPSHOT" ] || return 1
  awk -F'\t' -v tail="/$1" '
    substr($2, length($2) - length(tail) + 1) == tail { print $1; found = 1; exit }
    END { exit found ? 0 : 1 }' "$ARCHON_FAILED_RUNS_SNAPSHOT"
}

# archon_failed_run_class <run_id> — print the failure class this tick's
# failed-run snapshot recorded for the run (review | other; see above). A run
# the snapshot does not hold prints `other`. Always exits 0.
archon_failed_run_class() {
  local c=""
  [ -n "$1" ] && [ -s "$ARCHON_FAILED_RUNS_SNAPSHOT" ] \
    && c=$(awk -F'\t' -v id="$1" '$1 == id { print $3; exit }' "$ARCHON_FAILED_RUNS_SNAPSHOT")
  [ "$c" = review ] && echo review || echo other
}

# archon_failed_run_path <run_id> — print the failed run's worktree ("" when
# unknown).
archon_failed_run_path() {
  [ -n "$1" ] && [ -s "$ARCHON_FAILED_RUNS_SNAPSHOT" ] || return 0
  awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' "$ARCHON_FAILED_RUNS_SNAPSHOT"
}
