#!/usr/bin/env bash
# Hold every archon launch while the Claude account is rate limited.
#
#   source "$SCRIPT_DIR/lib/quota-pause.sh"    # after lib/ship-breaker.sh
#   quota_may_launch "<script>" || <skip the launch>
#
# A run that hits the limit fails with a node error like
#   Claude API error (rate_limit): You've hit your weekly limit · resets 3pm (Europe/London)
# and until 2026-10-03 nothing read it: every cron kept launching into the
# limit (62 node failures in 36h) and the issues it touched were re-queued
# as if they had crashed. This reads the newest such error from the run DB
# (lib/ship-breaker.sh picks the DB) and holds launches until the reset it
# names. The reset is resolved in the zone the message gives, as the first
# such moment after the error ("3pm" the same day or the next one, "Oct 5, 3pm"
# as written). A message whose reset cannot be read holds QUOTA_PAUSE_FALLBACK
# seconds from the error instead. No state file: the DB is the record, so a
# successful run is never needed to lift the hold and nothing is left to clear.
#
# A DB that cannot be read lifts nothing and holds nothing (returns 0): the
# per-issue breaker is the gate that fails closed.
#
# While held, a launch may still go to the owner's main account when the owner
# has turned that on and main is within its paced cap (lib/main-account.sh);
# the shim then runs it with --account main. Known gap: a main-account run that
# itself hits the limit (the owner's own use took main to 100%) is the newest
# such error and holds the factory until main's reset.

[ -n "${_QUOTA_PAUSE_SH:-}" ] && return 0
_QUOTA_PAUSE_SH=1

QUOTA_PAUSE_FALLBACK="${QUOTA_PAUSE_FALLBACK:-7200}"

# quota_reset_epoch <error-epoch> <message> — the reset the message names, as
# a unix epoch; the fallback hold when it names none.
quota_reset_epoch() {
  local at="$1" msg="$2" spec tz day when
  local re='resets[[:space:]]+([^(]+)[(]([A-Za-z0-9_/+-]+)[)]'
  if [[ "$msg" =~ $re ]]; then
    spec="${BASH_REMATCH[1]}"; tz="${BASH_REMATCH[2]}"
    spec="${spec//,/}"; spec="${spec%"${spec##*[![:space:]]}"}"
    local dated='^[A-Za-z]{3}[a-z]*[[:space:]]+[0-9]'
    if [[ "$spec" =~ $dated ]]; then
      when=$(TZ="$tz" date -d "$spec" +%s 2>/dev/null) || when=""
      # "Jan 2" read in late December names next year.
      [ -n "$when" ] && [ "$when" -lt "$at" ] \
        && when=$(TZ="$tz" date -d "$spec next year" +%s 2>/dev/null)
    else
      day=$(TZ="$tz" date -d "@$at" +%F 2>/dev/null) \
        && when=$(TZ="$tz" date -d "$day $spec" +%s 2>/dev/null) || when=""
      [ -n "$when" ] && [ "$when" -le "$at" ] \
        && when=$(TZ="$tz" date -d "$day $spec tomorrow" +%s 2>/dev/null)
    fi
    [[ "$when" =~ ^[0-9]+$ ]] && [ "$when" -gt "$at" ] && { echo "$when"; return 0; }
  fi
  echo $((at + QUOTA_PAUSE_FALLBACK))
}

# quota_pause_until — epoch launches are held until (0 when not held).
quota_pause_until() {
  local db row at msg until
  db=$(ship_breaker_db)
  [ -r "$db" ] || { echo 0; return 0; }
  row=$(sqlite3 -readonly -separator $'\t' "file:$db?mode=ro" "
    SELECT strftime('%s', created_at), json_extract(data, '\$.error')
    FROM remote_agent_workflow_events
    WHERE created_at > datetime('now', '-8 days')
      AND event_type IN ('node_failed', 'workflow_failed')
      AND data LIKE '%hit your%limit%'
    ORDER BY created_at DESC LIMIT 1;" 2>/dev/null | head -n 1) || row=""
  at="${row%%$'\t'*}"; msg="${row#*$'\t'}"
  [[ "$at" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
  until=$(quota_reset_epoch "$at" "$msg")
  if [ "$until" -gt "$(date +%s)" ]; then echo "$until"; else echo 0; fi
}

# quota_launch_account <script-name> — the account a launch may use now, in
# QUOTA_ACCOUNT: factory when it is not held; main while it is held and the
# owner's main account is on and within its paced cap (lib/main-account.sh).
# False, with one log line, when neither may launch.
QUOTA_ACCOUNT=factory
quota_launch_account() {
  local until
  QUOTA_ACCOUNT=factory
  until=$(quota_pause_until)
  [ "${until:-0}" -gt 0 ] || return 0
  # shellcheck source=lib/main-account.sh
  source "$(dirname "${BASH_SOURCE[0]}")/main-account.sh"
  if main_account_may_launch "$1"; then
    QUOTA_ACCOUNT=main
    return 0
  fi
  echo "$(date -Is) [quota-pause] $1: Claude rate limit in effect until $(date -d "@$until" -Is) — no archon launches"
  return 1
}

# quota_may_launch <script-name> — false (and one log line) while held and
# main may not take the launch either.
quota_may_launch() {
  quota_launch_account "$1"
}
