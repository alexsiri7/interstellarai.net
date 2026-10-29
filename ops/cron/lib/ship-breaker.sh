#!/usr/bin/env bash
# Circuit breaker for archon-ship relaunches, read from archon's run DB.
#
#   source "$SCRIPT_DIR/lib/ship-breaker.sh"   # after lib/run-as.sh
#   ship_breaker_check <project> <issue>       # 0 launch, 1 parked, 2 unknown
#
# 2026-10-02/03: one weekly Claude quota went in a day on the same seven issues
# relaunched every 15-30 minutes (lachesis #174: 52 runs, annie #1157: 23), each
# run failing the same way: the factory token could not push .github/workflows/**
# (it had no Workflows permission then), so the PR node returned no PR and the
# rest of the tail spent the tokens anyway. Nothing upstream of the launch
# remembered that the last runs had failed. Since 2026-10-04 the token has
# "Workflows: Read and write" (ops/host/archon-user/README.md "Decisions"), so
# the workflow-scope verdict below should stay dormant; it is kept because a
# token regenerated without that permission brings the loop straight back.
#
# Before every archon-ship launch on an issue this looks at that issue's runs:
#   - the newest counted run hit GitHub's workflow-permission push refusal:
#     trip at once — another run cannot push it either;
#   - the last SHIP_BREAKER_THRESHOLD (3) counted runs all failed: trip.
# A run the DB records as completed but whose no-PR verdict is a placeholder
# (lib/ship-verdict.sh, #209) counts as failed: its triage degenerated, and
# settle leaves the issue to be relaunched, so it must not reset the count.
# Runs that failed on a Claude rate limit are not counted (a quota wave must not
# park every issue it touched; lib/quota-pause.sh holds launches instead), and
# only runs started after the breaker's last park comment on the issue count,
# so a human who re-queues a parked issue gets fresh attempts.
#
# A failed:<n> trip first allows one diagnose-and-retry run (#237): a comment
# carrying SHIP_BREAKER_RETRY_MARKER lists why the last runs failed, where the
# next run's triage reads it, and the launch goes ahead. Only a counted failure
# after that comment parks, and only when every counted run since the comment
# failed: a retry run that did not fail resets the count, so the next trip is a
# fresh streak and gets its own retry. A workflow-scope trip parks at once:
# another run cannot push it either. A human who re-queues a parked issue gets
# a retry again on its next trip.
#
# A park labels the issue manual-review + archon:skipped, posts one comment
# carrying SHIP_BREAKER_MARKER and logs it. A DB that cannot be read returns 2:
# the caller does not launch (fail closed — an unbounded relaunch is the
# expensive failure here) and logs it.

[ -n "${_SHIP_BREAKER_SH:-}" ] && return 0
_SHIP_BREAKER_SH=1

SHIP_BREAKER_THRESHOLD="${SHIP_BREAKER_THRESHOLD:-3}"
SHIP_BREAKER_MARKER="<!-- archon:ship-breaker -->"
SHIP_BREAKER_RETRY_MARKER="<!-- archon:ship-breaker-retry -->"

# shellcheck source=lib/ship-verdict.sh
source "$(dirname "${BASH_SOURCE[0]}")/ship-verdict.sh"

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

# A run that failed on a Claude rate limit, as a condition on its events e.
SHIP_BREAKER_RATE_LIMITED="e.event_type IN ('node_failed', 'workflow_failed')
  AND (e.data LIKE '%rate_limit%' OR e.data LIKE '%hit your%limit%')"

# ship_breaker_runs_sql <project> <issue> <since> — the FROM and WHERE that
# select the issue's archon-ship runs (r) started after <since>, the runs the
# breaker counts. 2 when an argument would not be safe to interpolate.
ship_breaker_runs_sql() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$2" =~ ^[0-9]+$ \
     && "$3" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 2
  printf '%s' "FROM remote_agent_workflow_runs r
    JOIN remote_agent_codebases c ON c.id = r.codebase_id
    WHERE r.workflow_name IN ('archon-ship', 'archon-ship-block')
      AND r.user_message = 'fix #$2'
      AND c.name = 'alexsiri7/$1'
      AND r.started_at > '$3'"
}

# ship_breaker_rows <project> <issue> [since 'YYYY-MM-DD HH:MM:SS' UTC]
# Newest first, at most 10: status<TAB>rate_limited(0|1)<TAB>workflow_scope(0|1).
# A completed run whose outcome node printed a placeholder verdict reads failed.
# The workflow-scope match reads only node and workflow results, where a
# refused push lands. The agent's own stream (provider_event, tool_called,
# tool_completed) is skipped: a run that reads or edits this file sees these
# very LIKE patterns, and on 2026-10-22 that parked interstellarai.net#209 as
# workflow-scope although nothing was pushed (its real failure was review__route).
# Both json_valid guards matter: one malformed node_output would otherwise fail
# the whole query, and the breaker would refuse every launch.
ship_breaker_rows() {
  local project="$1" issue="$2" since="${3:-1970-01-01 00:00:00}" db runs out
  local status rate scope verdict
  runs=$(ship_breaker_runs_sql "$project" "$issue" "$since") || return 2
  db=$(ship_breaker_db)
  [ -r "$db" ] || return 2
  out=$(sqlite3 -readonly -separator $'\t' "file:$db?mode=ro" "
    SELECT r.status,
      EXISTS (SELECT 1 FROM remote_agent_workflow_events e
              WHERE e.workflow_run_id = r.id AND $SHIP_BREAKER_RATE_LIMITED),
      EXISTS (SELECT 1 FROM remote_agent_workflow_events e
              WHERE e.workflow_run_id = r.id
                AND e.event_type IN ('node_failed', 'node_completed', 'workflow_failed')
                AND (e.data LIKE '%create or update workflow%'
                     OR e.data LIKE '%without \`workflow\` scope%'
                     OR e.data LIKE '%lacks \`workflow\` scope%')),
      (SELECT replace(CASE WHEN instr(s, char(10)) > 0
                           THEN substr(s, 1, instr(s, char(10)) - 1) ELSE s END, char(9), ' ')
       FROM (SELECT CASE WHEN json_valid(o) THEN json_extract(o, '\$.summary') END AS s
             FROM (SELECT json_extract(e.data, '\$.node_output') AS o
                   FROM remote_agent_workflow_events e
                   WHERE e.workflow_run_id = r.id AND e.event_type = 'node_completed'
                     AND e.step_name = 'outcome' AND json_valid(e.data)
                   ORDER BY e.rowid DESC LIMIT 1)))
    $runs
    ORDER BY r.started_at DESC
    LIMIT 10;" 2>/dev/null) || return 2
  while IFS=$'\t' read -r status rate scope verdict; do
    [ -n "$status" ] || continue
    [ "$status" = completed ] && verdict_is_placeholder "$verdict" && status=failed
    printf '%s\t%s\t%s\n' "$status" "$rate" "$scope"
  done <<<"$out"
}

# ship_breaker_diagnosis <project> <issue> [since] — why the newest counted
# runs failed, one "- <started_at>: <error>" line each for at most three. The
# newest runs that are not rate-limited are the ones a trip counted: anything
# else would have reset the count. The lines go into a public issue comment, so
# they pass through ship_breaker_redact first.
ship_breaker_diagnosis() {
  local project="$1" issue="$2" since="${3:-1970-01-01 00:00:00}" db runs out started error
  db=$(ship_breaker_db)
  if runs=$(ship_breaker_runs_sql "$project" "$issue" "$since") && [ -r "$db" ] \
     && out=$(sqlite3 -readonly -separator $'\t' "file:$db?mode=ro" "
    SELECT r.started_at,
      (SELECT substr(replace(replace(json_extract(e.data, '\$.error'), char(10), ' '), char(9), ' '), 1, 300)
       FROM remote_agent_workflow_events e
       WHERE e.workflow_run_id = r.id AND e.event_type IN ('node_failed', 'workflow_failed')
         AND json_valid(e.data) AND json_extract(e.data, '\$.error') IS NOT NULL
       ORDER BY e.rowid DESC LIMIT 1)
    $runs
      AND NOT EXISTS (SELECT 1 FROM remote_agent_workflow_events e
                      WHERE e.workflow_run_id = r.id AND $SHIP_BREAKER_RATE_LIMITED)
    ORDER BY r.started_at DESC
    LIMIT 3;" 2>/dev/null); then
    while IFS=$'\t' read -r started error; do
      [ -n "$started" ] || continue
      printf -- '- %s: %s\n' "$started" "${error:-no error recorded (a placeholder verdict, or a crash before any node reported)}"
    done <<<"$out" | ship_breaker_redact
  else
    echo "- the run history could not be read"
  fi
}

# ship_breaker_redact — stdin to stdout with secret-shaped text replaced by
# [redacted] (ops/cron/README.md: no secret value in an issue). A node error
# can quote a token, an authenticated URL or an environment dump.
ship_breaker_redact() {
  sed -E \
    -e 's/\b(gh[opsur]_|github_pat_)[A-Za-z0-9_]{16,}/[redacted]/g' \
    -e 's/\b(sk-|xox[abeprs]-|dp\.(st|ct|pt|sa|scrt)\.)[A-Za-z0-9_.-]{16,}/[redacted]/g' \
    -e 's/\bAKIA[0-9A-Z]{16}/[redacted]/g' \
    -e 's/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+/[redacted]/g' \
    -e 's#://[^/@[:space:]]+@#://[redacted]@#g' \
    -e 's/\b(bearer|basic|token) +[A-Za-z0-9._~+/=-]{16,}/\1 [redacted]/Ig' \
    -e "s/([A-Za-z0-9_]*(token|secret|passw(or)?d|api[_-]?key|private[_-]?key)[A-Za-z0-9_]*[\"']?[:=] *[\"']?)[^[:space:]\"',]+/\1[redacted]/Ig" \
    -e 's/\b([A-Z][A-Z0-9_]{2,})=[^[:space:]]+/\1=[redacted]/g'
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

# ship_breaker_since_retry — reads the ship_breaker_rows since a retry comment
# on stdin; prints "pending" (no counted run yet), "reset" (a counted run did
# not fail, so the streak now tripping is a fresh one) or "failed" (every
# counted run since, the retry run among them, failed).
ship_breaker_since_retry() {
  awk -F'\t' '
    NF == 0 { next }                            # no rows: a here-string of ""
    $1 == "failed" && $2 == 1 { next }
    $1 != "failed" { r = "reset"; exit }
    { r = "failed" }
    END { print (r ? r : "pending") }'
}

# ship_breaker_retry <project> <issue> <verdict> [since] — the
# diagnose-and-retry comment. 0 when posted (launch), 1 when not.
ship_breaker_retry() {
  local project="$1" issue="$2" verdict="$3" since="${4:-}"
  echo "$(date -Is) [ship-breaker] $project: #$issue — circuit would open ($verdict); one diagnose-and-retry run first"
  gh issue comment "$issue" --repo "alexsiri7/$project" --body "The archon-ship circuit breaker would park #$issue: its last ${verdict#failed:} runs all failed (rate-limit failures not counted). Before parking, one more run. The next run should read why they failed and not repeat it:
$(ship_breaker_diagnosis "$project" "$issue" "$since")

If this run fails too, the breaker parks the issue.

${SHIP_BREAKER_RETRY_MARKER}
<!-- lachesis:automated -->" >/dev/null 2>&1 && return 0
  echo "$(date -Is) [ship-breaker] $project: #$issue — could not post the retry comment; not launching, will retry next tick"
  return 1
}

# ship_breaker_check <project> <issue> — see the header.
ship_breaker_check() {
  local project="$1" issue="$2" rows verdict marks since retry_at retried=""
  rows=$(ship_breaker_rows "$project" "$issue") || return 2
  verdict=$(ship_breaker_verdict <<<"$rows")
  [ "$verdict" = ok ] && return 0

  # The breaker's own comments, oldest first: "park|retry<TAB>created_at".
  marks=$(gh api --paginate "repos/alexsiri7/$project/issues/$issue/comments" \
    --jq ".[] | if (.body | contains(\"$SHIP_BREAKER_RETRY_MARKER\")) then \"retry\t\(.created_at)\"
                elif (.body | contains(\"$SHIP_BREAKER_MARKER\")) then \"park\t\(.created_at)\"
                else empty end" 2>/dev/null) || return 2
  since=$(awk -F'\t' '$1 == "park" { t = $2 } END { print t }' <<<"$marks")
  retry_at=$(awk -F'\t' '$1 == "retry" { t = $2 } END { print t }' <<<"$marks")
  # ISO-8601 Z timestamps order as strings; a retry before the last park is spent.
  [[ -n "$since" && ! "$retry_at" > "$since" ]] && retry_at=""

  # Re-queued by a human after an earlier park: count only the runs since.
  if [ -n "$since" ]; then
    since=$(date -u -d "$since" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || return 2
    rows=$(ship_breaker_rows "$project" "$issue" "$since") || return 2
    verdict=$(ship_breaker_verdict <<<"$rows")
    [ "$verdict" = ok ] && return 0
  fi

  if [[ "$verdict" == failed:* ]]; then
    [ -n "$retry_at" ] || { ship_breaker_retry "$project" "$issue" "$verdict" "$since"; return; }
    retry_at=$(date -u -d "$retry_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || return 2
    rows=$(ship_breaker_rows "$project" "$issue" "$retry_at") || return 2
    case "$(ship_breaker_since_retry <<<"$rows")" in
      pending) return 0 ;;
      reset) ship_breaker_retry "$project" "$issue" "$verdict" "$since"; return ;;
    esac
    retried="One diagnose-and-retry run after the breaker's comment failed too. "
  fi

  local why
  case "$verdict" in
    workflow-scope)
      why="its last archon-ship run could not push: the branch changes .github/workflows/**, and GitHub refused the factory token for lack of the Workflows permission. The token should have \"Workflows: Read and write\" (ops/host/archon-user/README.md, step (a)); check it was not regenerated without it. Until then another run cannot push it either: push the change by hand." ;;
    *)
      why="its last ${verdict#failed:} archon-ship runs all failed (rate-limit failures not counted). ${retried}Read the run logs under .archon-logs/cron-issue-$issue-* before re-queuing." ;;
  esac
  # With Lachesis pickup on (lib/lachesis.sh) labels gate nothing: the park is
  # a question for the author, which labels the issue needs-author so
  # next_issue passes over it until it is answered. The marker travels in the
  # question's comment, so the answered issue gets fresh attempts. A question
  # that could not be recorded is not a park: no launch, retried next tick.
  if [ -n "${SHIP_BREAKER_ASK:-}" ]; then
    if "$SHIP_BREAKER_ASK" "$project" "$issue" \
        "archon-ship keeps failing on #$issue. Look at why, then answer this question to let the factory try it again." \
        "Parked by the archon-ship circuit breaker: ${why}

Only runs after this comment will count.

${SHIP_BREAKER_MARKER}"; then
      echo "$(date -Is) [ship-breaker] $project: #$issue — circuit open ($verdict), asked the author in Lachesis"
    else
      echo "$(date -Is) [ship-breaker] $project: #$issue — circuit open ($verdict), could not record the question in Lachesis; not launching, will retry next tick"
    fi
    return 1
  fi
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

${SHIP_BREAKER_MARKER}
<!-- lachesis:automated -->" >/dev/null 2>&1 || true
  return 1
}
