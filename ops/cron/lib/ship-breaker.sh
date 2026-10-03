#!/usr/bin/env bash
# Circuit breaker for archon-ship relaunches, read from archon's run DB.
#
#   source "$SCRIPT_DIR/lib/ship-breaker.sh"   # after lib/run-as.sh
#   ship_breaker_check <project> <issue>       # 0 launch, 1 parked, 2 unknown
#
# 2026-10-02/03: one weekly Claude quota went in a day on the same seven issues
# relaunched every 15-30 minutes (lachesis #174: 52 runs, annie #1157: 23), each
# run failing the same way: the factory token cannot push .github/workflows/**
# (no Workflows permission, ops/host/archon-user/README.md "Decisions"), so the
# PR node returned no PR and the rest of the tail spent the tokens anyway.
# Nothing upstream of the launch remembered that the last runs had failed.
#
# Before every archon-ship launch on an issue this looks at that issue's runs:
#   - the newest counted run hit GitHub's workflow-permission push refusal:
#     trip at once — another run cannot push it either;
#   - the last SHIP_BREAKER_THRESHOLD (3) counted runs all failed: trip.
# Runs that failed on a Claude rate limit are not counted (a quota wave must not
# park every issue it touched; lib/quota-pause.sh holds launches instead), and
# only runs started after the breaker's last park comment on the issue count,
# so a human who re-queues a parked issue gets fresh attempts.
#
# A trip parks the issue (manual-review + archon:skipped, one comment carrying
# SHIP_BREAKER_MARKER) and logs it. A DB that cannot be read returns 2: the
# caller does not launch (fail closed — an unbounded relaunch is the expensive
# failure here) and logs it.

[ -n "${_SHIP_BREAKER_SH:-}" ] && return 0
_SHIP_BREAKER_SH=1

SHIP_BREAKER_THRESHOLD="${SHIP_BREAKER_THRESHOLD:-3}"
SHIP_BREAKER_MARKER="<!-- archon:ship-breaker -->"

# The run DB of whichever user runs the factory (lib/run-as.sh). Under bats
# only an explicit ARCHON_DB counts: tests must never read the host's live DB.
ship_breaker_db() {
  if [ -n "${ARCHON_DB:-}" ]; then
    echo "$ARCHON_DB"
  elif [ -n "${BATS_TEST_FILENAME:-}" ]; then
    echo "/nonexistent/archon.db"
  elif [ "${ARCHON_RUN_AS:-asiri}" = archon ]; then
    echo "${ARCHON_HOME_DIR:-/mnt/ext-fast/archon-home}/.archon/archon.db"
  else
    echo "$HOME/.archon/archon.db"
  fi
}

# ship_breaker_rows <project> <issue> [since 'YYYY-MM-DD HH:MM:SS' UTC]
# Newest first, at most 10: status<TAB>rate_limited(0|1)<TAB>workflow_scope(0|1).
ship_breaker_rows() {
  local project="$1" issue="$2" since="${3:-1970-01-01 00:00:00}" db
  [[ "$project" =~ ^[A-Za-z0-9._-]+$ && "$issue" =~ ^[0-9]+$ \
     && "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 2
  db=$(ship_breaker_db)
  [ -r "$db" ] || return 2
  sqlite3 -readonly -separator $'\t' "file:$db?mode=ro" "
    SELECT r.status,
      EXISTS (SELECT 1 FROM remote_agent_workflow_events e
              WHERE e.workflow_run_id = r.id
                AND e.event_type IN ('node_failed', 'workflow_failed')
                AND (e.data LIKE '%rate_limit%' OR e.data LIKE '%hit your%limit%')),
      EXISTS (SELECT 1 FROM remote_agent_workflow_events e
              WHERE e.workflow_run_id = r.id
                AND (e.data LIKE '%create or update workflow%'
                     OR e.data LIKE '%without \`workflow\` scope%'
                     OR e.data LIKE '%lacks \`workflow\` scope%'))
    FROM remote_agent_workflow_runs r
    JOIN remote_agent_codebases c ON c.id = r.codebase_id
    WHERE r.workflow_name = 'archon-ship'
      AND r.user_message = 'fix #$issue'
      AND c.name = 'alexsiri7/$project'
      AND r.started_at > '$since'
    ORDER BY r.started_at DESC
    LIMIT 10;" 2>/dev/null || return 2
}

# ship_breaker_verdict — reads ship_breaker_rows on stdin; prints
# "ok", "workflow-scope" or "failed:<n>".
ship_breaker_verdict() {
  awk -F'\t' -v max="$SHIP_BREAKER_THRESHOLD" '
    $1 == "failed" && $2 == 1 { next }          # rate limit: not counted
    $1 != "failed" { exit }                     # a success/live run resets
    n == 0 && $3 == 1 { scope = 1; exit }       # newest counted run: no push
    { n++ }
    END {
      if (scope) print "workflow-scope"
      else if (n >= max) print "failed:" n
      else print "ok"
    }'
}

# ship_breaker_check <project> <issue> — see the header.
ship_breaker_check() {
  local project="$1" issue="$2" rows verdict since
  rows=$(ship_breaker_rows "$project" "$issue") || return 2
  verdict=$(ship_breaker_verdict <<<"$rows")
  [ "$verdict" = ok ] && return 0

  # Re-queued by a human after an earlier park: count only the runs since.
  since=$(gh api --paginate "repos/alexsiri7/$project/issues/$issue/comments" \
    --jq ".[] | select(.body | contains(\"$SHIP_BREAKER_MARKER\")) | .created_at" 2>/dev/null \
    | tail -n 1) || return 2
  if [ -n "$since" ]; then
    since=$(date -u -d "$since" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || return 2
    rows=$(ship_breaker_rows "$project" "$issue" "$since") || return 2
    verdict=$(ship_breaker_verdict <<<"$rows")
    [ "$verdict" = ok ] && return 0
  fi

  local why
  case "$verdict" in
    workflow-scope)
      why="its last archon-ship run could not push: the branch changes .github/workflows/**, and the factory token has no Workflows permission (ops/host/archon-user/README.md). Another run cannot push it either. Push the change by hand, or grant the token Workflows: Read and write." ;;
    *)
      why="its last ${verdict#failed:} archon-ship runs all failed (rate-limit failures not counted). Read the run logs under .archon-logs/cron-issue-$issue-* before re-queuing." ;;
  esac
  echo "$(date -Is) [ship-breaker] $project: #$issue — circuit open ($verdict), parking as manual-review + archon:skipped"
  # The marker comment resets the count, so it is only posted once the park
  # holds: posted after a failed relabel, the next tick would count no runs
  # and launch again. Not launching either way.
  if ! gh issue edit "$issue" --repo "alexsiri7/$project" \
      --remove-label "archon:queued" --remove-label "archon:in-progress" \
      --add-label "manual-review" --add-label "archon:skipped" >/dev/null 2>&1; then
    echo "$(date -Is) [ship-breaker] $project: #$issue — could not relabel; not launching, will retry next tick"
    return 1
  fi
  gh issue comment "$issue" --repo "alexsiri7/$project" --body "Parked by the archon-ship circuit breaker: ${why}

Remove \`manual-review\` and \`archon:skipped\` and add \`archon:queued\` to run it again; only runs after this comment will count.

${SHIP_BREAKER_MARKER}" >/dev/null 2>&1 || true
  return 1
}
