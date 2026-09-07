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
#
# Requires: archon >= 0.10 (workflow runs --json), python3, awk.

ARCHON_RUNS_SNAPSHOT="/tmp/.archon-active-runs.$(basename "${0:-tick}" .sh)"

# Snapshot all running + paused runs to $ARCHON_RUNS_SNAPSHOT as TSV:
#   workflow_name <TAB> status <TAB> origin_path <TAB> user_message
# Failures leave an empty snapshot — matchers then return "no active run",
# which mirrors the old pgrep-only behavior (fail-open, never fail-stuck).
archon_runs_snapshot() {
  : > "$ARCHON_RUNS_SNAPSHOT"
  local st
  for st in running paused; do
    CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 \
      archon workflow runs --all --status "$st" --limit 100 --json 2>/dev/null \
      | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("runs", []):
    name = r.get("workflow_name") or ""
    msg = (r.get("user_message") or "").replace("\t", " ").replace("\n", " ")
    meta = r.get("metadata") or {}
    origin = ((meta.get("workflow_source") or {}).get("origin")) or ""
    status = r.get("status") or ""
    print(f"{name}\t{status}\t{origin}\t{msg}")
' >> "$ARCHON_RUNS_SNAPSHOT" || true
  done
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
