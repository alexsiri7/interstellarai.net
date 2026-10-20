#!/usr/bin/env bash
# The no-PR verdict line an archon-ship run ends with, shared by
# lib/settle-ship-outcome.sh (which records it on the issue) and
# lib/ship-breaker.sh (which counts the run).
#
#   source "$SCRIPT_DIR/lib/ship-verdict.sh"
#   [[ "$line" =~ $VERDICT_RE ]]       # a no-PR verdict
#   verdict_is_placeholder "$line"     # 0 when its reason is placeholder junk
#
# 2026-10-18/20 (filmduel #814, musenmingle #348): triage__triage returned "test"
# in every structured-output field, so the run printed "Not done: blocked on
# test. test". Settle took it as a real verdict, parked the issue and filed a
# Lachesis question an author had to answer by hand, and the run DB recorded the
# run as completed, which reset the breaker. A placeholder verdict is treated as
# a crashed run instead (#209): settle leaves it alone, the breaker counts it.

[ -n "${_SHIP_VERDICT_SH:-}" ] && return 0
_SHIP_VERDICT_SH=1

# Archon v0.12 (ship tail scripts/outcome.ts) reworded the stops. "No delivery
# needed: " (triage NO_ACTION) is unchanged; "No delivery started: " is gone and
# its cases now read "Not done: " (triage BLOCKED or needing contract work, an
# inconclusive investigation, planning stopped on a person's call) or "No work
# owed in this repository: " (the investigation refuted the report). Those park
# as "No delivery started" did (only "No delivery needed" can close) instead of
# matching nothing and being re-queued by unstick_stale.
VERDICT_RE='^(No delivery (needed|started)|Not done|No work owed in this repository): '

SHIP_VERDICT_STOCK_WORDS='test|tests|testing|todo|tbd|fixme|placeholder|dummy|lorem|ipsum|xxx|foo|bar|baz|null|none|undefined|n|a|na'

# verdict_is_placeholder <verdict line> — 0 when the line is a verdict whose
# reason names no #ref and carries at most one distinct word outside
# SHIP_VERDICT_STOCK_WORDS: empty, stock words, or one value repeated in every
# field. The stripped phrases are the fixed wording of stopped() in the pack's
# ship/scripts/outcome.ts; if the pack rewords them they stay in the reason,
# which only makes this check stricter.
verdict_is_placeholder() {
  local reason words
  [[ "$1" =~ $VERDICT_RE ]] || return 1
  reason=${1#"${BASH_REMATCH[0]}"}
  reason=${reason#blocked on }
  reason=${reason#the work item needs contract work before a run can start.}
  reason=${reason#the investigation was inconclusive.}
  reason=${reason#planning stopped on calls only a person can make.}
  [[ "$reason" =~ \#[0-9] ]] && return 1
  words=$(tr '[:upper:]' '[:lower:]' <<<"$reason" | tr -cs 'a-z0-9' '\n' \
    | grep -vxE "$SHIP_VERDICT_STOCK_WORDS" | sort -u | grep -c .)
  [ "$words" -le 1 ]
}
