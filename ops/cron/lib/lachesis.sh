#!/usr/bin/env bash
# Lachesis, the planner, from the cron scripts: its switches and one MCP call.
#
#   source "$SCRIPT_DIR/lib/lachesis.sh"
#   lachesis_pickup_enabled && json=$(lachesis_call next_issue '{}')
#
# Switches, off unless the owner turns them on, outside this repo so archon
# cannot (same shape as lib/main-account.sh's ARCHON_MAIN_ACCOUNT):
#   $LACHESIS_PICKUP_FLAG (default ~/.config/archon-cron/lachesis-pickup), one line
#   LACHESIS_PICKUP=on
# With it on, issue-pickup takes its work from Lachesis next_issue instead of
# the archon:queued label scan, and every wait for the author is a Lachesis
# question (interstellarai.net #157). Off, or under bats without
# LACHESIS_FLAG_TEST, nothing here changes what the factory does.
#
# A second switch routes every archon launch to the Claude account Lachesis
# route_run names (interstellarai.net #156; lib/quota-pause.sh):
#   $LACHESIS_ROUTE_FLAG (default ~/.config/archon-cron/lachesis-route), one line
#   LACHESIS_ROUTE=on
#
# lachesis_call runs lib/lachesis_call.py with the factory token
# (LACHESIS_FACTORY_TOKEN, read from Doppler on its own through lib/secrets.sh:
# the rest of the store never reaches the environment of the archon runs these
# scripts start). LACHESIS_CALL_CMD replaces it in tests.

[ -n "${_LACHESIS_SH:-}" ] && return 0
_LACHESIS_SH=1

# shellcheck source=secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

LACHESIS_PICKUP_FLAG="${LACHESIS_PICKUP_FLAG:-$HOME/.config/archon-cron/lachesis-pickup}"
LACHESIS_ROUTE_FLAG="${LACHESIS_ROUTE_FLAG:-$HOME/.config/archon-cron/lachesis-route}"
LACHESIS_STATE_DIR="${LACHESIS_STATE_DIR:-$HOME/.local/state/archon-cron/lachesis}"

# lachesis_flag_on <file> <VAR> — true when <file>'s last VAR= line says on.
# Under bats the host's files are ignored unless the test sets LACHESIS_FLAG_TEST.
lachesis_flag_on() {
  [ -n "${BATS_TEST_FILENAME:-}" ] && [ -z "${LACHESIS_FLAG_TEST:-}" ] && return 1
  [ -r "$1" ] || return 1
  [ "$(sed -nE "s/^[[:space:]]*$2=[\"']?([a-z]+)[\"']?[[:space:]]*(#.*)?\$/\\1/p" "$1" | tail -n 1)" = on ]
}

lachesis_pickup_enabled() { lachesis_flag_on "$LACHESIS_PICKUP_FLAG" LACHESIS_PICKUP; }
lachesis_route_enabled() { lachesis_flag_on "$LACHESIS_ROUTE_FLAG" LACHESIS_ROUTE; }

# lachesis_kind_for <workflow> — Lachesis's kind of work for an archon
# workflow, as route_run and report_usage take it (lachesis_report.py KINDS).
lachesis_kind_for() {
  case "$1" in
    archon-triage-issue) echo triage ;;
    archon-review|archon-smart-pr-review|archon-*-audit) echo audit ;;
    archon-architect) echo "spec work" ;;
    *) echo implementation ;;
  esac
}

# lachesis_token — LACHESIS_FACTORY_TOKEN from the environment, else the store.
lachesis_token() {
  if [ -n "${LACHESIS_FACTORY_TOKEN:-}" ]; then
    printf '%s' "$LACHESIS_FACTORY_TOKEN"
    return 0
  fi
  secret_get LACHESIS_FACTORY_TOKEN
}

# lachesis_call <tool> [json-arguments] — the tool's JSON on stdout. Exit 0 when
# it answered, 1 when it refused, 2 when Lachesis could not be reached (the
# reason on stderr either way).
lachesis_call() {
  if [ -n "${LACHESIS_CALL_CMD:-}" ]; then
    $LACHESIS_CALL_CMD "$@"
    return
  fi
  LACHESIS_FACTORY_TOKEN="$(lachesis_token)" \
    python3 -B "$(dirname "${BASH_SOURCE[0]}")/lachesis_call.py" "$@"
}

# lachesis_ask <project> <issue> <question> [context] [default] [wait_days]
#   [option...] — record a question for the author blocking
# alexsiri7/<project>#<issue> (ask_question, kind clarification): Lachesis
# posts it, with the context, as a comment on the issue and labels it
# needs-author, so next_issue passes over the issue until the author answers.
# A default (#237) is taken after wait_days (Lachesis's own default when
# empty) unless the author answers first; options are the answers offered.
# Each is sent only when given. True when the question was recorded.
lachesis_ask() {
  local project="$1" issue="$2" question="$3" context="${4:-}" default="${5:-}" wait_days="${6:-}" args
  shift $(( $# < 6 ? $# : 6 ))
  args=$(jq -nc --arg repo "alexsiri7/$project" --argjson n "$issue" \
    --arg q "$question" --arg c "$context" --arg d "$default" --arg w "$wait_days" \
    '{repo: $repo, question: $q, kind: "clarification", asker: "factory",
      blocks: [$n], issue: $n, context: $c}
     + (if $d != "" then {default: $d} else {} end)
     + (if $w != "" then {wait_days: ($w | tonumber)} else {} end)
     + (if $ARGS.positional != [] then {options: $ARGS.positional} else {} end)' \
    --args "$@") || return 1
  lachesis_call ask_question "$args" >/dev/null
}

# lachesis_note <project> <issue> <text> — record a decision the factory took
# on alexsiri7/<project>#<issue> without asking (add_note). True when recorded.
lachesis_note() {
  local args
  args=$(jq -nc --arg repo "alexsiri7/$1" --argjson n "$2" --arg t "$3" \
    '{repo: $repo, role: "factory", type: "decision", text: $t, issue: $n}') || return 1
  lachesis_call add_note "$args" >/dev/null
}

# lachesis_depend <project> <issue> <blocker> — record #<blocker> as blocking
# #<issue> (add_dependency, a native GitHub blocked_by link), so next_issue
# passes over #<issue> until #<blocker> closes. True when recorded.
lachesis_depend() {
  local args
  args=$(jq -nc --arg repo "alexsiri7/$1" --argjson n "$2" --argjson b "$3" \
    '{repo: $repo, issue_number: $n, blocked_by_issue_number: $b}') || return 1
  lachesis_call add_dependency "$args" >/dev/null
}

# lachesis_ask_once <project> <issue> <key> <question> [context] — lachesis_ask,
# once per (project, issue, key): a marker in LACHESIS_STATE_DIR keeps a
# question whose cause outlives its answer (a stranger's comment left in
# place) from being asked again every tick. True when it is (or already was)
# recorded.
lachesis_ask_once() {
  local marker="$LACHESIS_STATE_DIR/asked-$1-$2-$3"
  [ -e "$marker" ] && return 0
  lachesis_ask "$1" "$2" "$4" "${5:-}" || return 1
  mkdir -p "$LACHESIS_STATE_DIR" 2>/dev/null && : > "$marker"
  return 0
}

# The factory's reads of next_issue, one per issue-pickup tick that asks
# (lachesis_next_record), so that a run of failures is a visible fault: from
# 2026-10-17 every tick's next_issue timed out and no issue was picked up for a
# day while pipeline-health and pipeline-status called the factory healthy.
#   $LACHESIS_NEXT_STATUS (default $LACHESIS_STATE_DIR/next-issue-status)
#   failures=<ticks in a row that could not read it>
#   last_ok=<epoch of the last read>   last_failed=<epoch of the last failure>
# A streak of LACHESIS_NEXT_FAIL_MAX (default 3) or more is a failure.
LACHESIS_NEXT_STATUS="${LACHESIS_NEXT_STATUS:-$LACHESIS_STATE_DIR/next-issue-status}"
LACHESIS_NEXT_FAIL_MAX="${LACHESIS_NEXT_FAIL_MAX:-3}"

# lachesis_next_status_get <key> — a field of the status file, empty if none.
lachesis_next_status_get() {
  sed -n "s/^$1=\([0-9]*\)\$/\1/p" "$LACHESIS_NEXT_STATUS" 2>/dev/null | tail -n 1
}

# lachesis_next_record ok|failed — this tick's read of next_issue. Best effort:
# a status file that cannot be written must never cost the tick its pickup.
lachesis_next_record() {
  local now failures last_ok last_failed
  now=$(date +%s)
  failures=$(lachesis_next_status_get failures)
  last_ok=$(lachesis_next_status_get last_ok)
  last_failed=$(lachesis_next_status_get last_failed)
  if [ "$1" = ok ]; then
    failures=0 last_ok=$now
  else
    failures=$(( ${failures:-0} + 1 )) last_failed=$now
  fi
  {
    mkdir -p "$(dirname "$LACHESIS_NEXT_STATUS")" &&
      printf 'failures=%s\nlast_ok=%s\nlast_failed=%s\n' \
        "$failures" "${last_ok:-0}" "${last_failed:-0}" > "$LACHESIS_NEXT_STATUS.tmp" &&
      mv "$LACHESIS_NEXT_STATUS.tmp" "$LACHESIS_NEXT_STATUS"
  } 2>/dev/null || true
}

# shellcheck disable=SC2034  # LACHESIS_NEXT_PROBLEM is read by its callers
# lachesis_next_failing — true when the last LACHESIS_NEXT_FAIL_MAX or more
# ticks in a row could not read next_issue. Sets LACHESIS_NEXT_PROBLEM to say
# so, with when it last answered.
lachesis_next_failing() {
  local failures last_ok since
  failures=$(lachesis_next_status_get failures)
  LACHESIS_NEXT_PROBLEM=""
  [ "${failures:-0}" -ge "$LACHESIS_NEXT_FAIL_MAX" ] || return 1
  last_ok=$(lachesis_next_status_get last_ok)
  since="never recorded"
  [ "${last_ok:-0}" -gt 0 ] && since=$(date -d "@$last_ok" '+%F %H:%M' 2>/dev/null || echo "?")
  LACHESIS_NEXT_PROBLEM="Lachesis next_issue could not be read on $failures issue-pickup ticks in a row (last read: $since)"
  return 0
}
