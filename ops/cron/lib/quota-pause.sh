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

# ── Which account each run used ──────────────────────────────────────────────
# The archon shim records every launch it lets through, with the account it ran
# on, in QUOTA_LEDGER (one line: epoch<TAB>account<TAB>workflow<TAB>message).
# The run DB does not know the account, so a run is matched back to its launch:
# the newest launch of the same workflow and message from 15 minutes before
# the run started to 2 minutes after. A run with no such launch ran on factory
# (before the ledger, every run did). lachesis_report.py reads the same file
# for report_usage's account.
QUOTA_LEDGER="${QUOTA_LEDGER:-$HOME/.local/state/archon-cron/run-accounts.tsv}"
QUOTA_LEDGER_MAX="${QUOTA_LEDGER_MAX:-20000}"

# quota_record_launch <account> <workflow> <message> — append to the ledger;
# never fails the launch.
quota_record_launch() {
  local msg="${3//[$'\t\n\r']/ }" lines
  {
    mkdir -p "$(dirname "$QUOTA_LEDGER")" \
      && printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$msg" >> "$QUOTA_LEDGER"
    lines=$(wc -l < "$QUOTA_LEDGER")
    if [ "${lines:-0}" -gt "$QUOTA_LEDGER_MAX" ]; then
      tail -n $((QUOTA_LEDGER_MAX / 2)) "$QUOTA_LEDGER" > "$QUOTA_LEDGER.tmp" \
        && mv "$QUOTA_LEDGER.tmp" "$QUOTA_LEDGER"
    fi
  } 2>/dev/null || true
}

# quota_account_of_run <started-epoch> <workflow> <message> — the account the
# ledger says that run used (factory when it says nothing).
quota_account_of_run() {
  [ -r "$QUOTA_LEDGER" ] || { echo factory; return 0; }
  Q_START="$1" Q_WF="$2" Q_MSG="${3//[$'\t\n\r']/ }" awk -F'\t' '
    $3 == ENVIRON["Q_WF"] && $4 == ENVIRON["Q_MSG"] \
      && $1 >= ENVIRON["Q_START"] - 900 && $1 <= ENVIRON["Q_START"] + 120 { a = $2 }
    END { print (a == "" ? "factory" : a) }' "$QUOTA_LEDGER"
}

# quota_pause_until_account <account> — epoch until which <account> is held by
# the newest rate-limit error of a run on it (0 when not held).
quota_pause_until_account() {
  local account="$1" db at msg start wf um until
  db=$(ship_breaker_db)
  [ -r "$db" ] || { echo 0; return 0; }
  while IFS=$'\x1f' read -r at msg start wf um; do
    [[ "$at" =~ ^[0-9]+$ ]] || continue
    [ "$(quota_account_of_run "${start:-0}" "$wf" "$um")" = "$account" ] || continue
    until=$(quota_reset_epoch "$at" "$msg")
    if [ "$until" -gt "$(date +%s)" ]; then echo "$until"; else echo 0; fi
    return 0
  done < <(sqlite3 -readonly -separator $'\x1f' "file:$db?mode=ro" "
    SELECT strftime('%s', e.created_at),
           replace(json_extract(e.data, '\$.error'), char(10), ' '),
           strftime('%s', r.started_at), r.workflow_name,
           replace(replace(r.user_message, char(10), ' '), char(9), ' ')
    FROM remote_agent_workflow_events e
    LEFT JOIN remote_agent_workflow_runs r ON r.id = e.workflow_run_id
    WHERE e.created_at > datetime('now', '-8 days')
      AND e.event_type IN ('node_failed', 'workflow_failed')
      AND e.data LIKE '%hit your%limit%'
    ORDER BY e.created_at DESC LIMIT 50;" 2>/dev/null)
  echo 0
}

# quota_route_account <script-name> — with LACHESIS_ROUTE on: the account
# Lachesis route_run names for a run of QUOTA_RUN_KIND (default
# implementation), in QUOTA_ACCOUNT. route_run already weighs every account's
# fuel, pause and pace (and main's share and five-hour pause); the local hold
# for that account is the safety net when fuel is stale. Returns 0 launch,
# 1 hold (one log line why), 2 route_run could not be read.
quota_route_account() {
  local kind="${QUOTA_RUN_KIND:-implementation}" json via account reason until
  if ! json=$(lachesis_call route_run "$(jq -nc --arg k "$kind" '{kind: $k}')" 2>/dev/null) \
      || ! jq -e 'has("via")' <<<"$json" >/dev/null 2>&1; then
    echo "$(date -Is) [lachesis-route] $1: route_run could not be read — using the local rate-limit hold"
    return 2
  fi
  via=$(jq -r '.via // ""' <<<"$json")
  account=$(jq -r '.account // ""' <<<"$json")
  reason=$(jq -r '.reason // ""' <<<"$json")
  if [ "$via" != allowance ] || [ -z "$account" ]; then
    echo "$(date -Is) [lachesis-route] $1: no Claude account for $kind — ${reason:-route_run named none}"
    return 1
  fi
  case "$account" in
    factory) ;;
    main)
      # shellcheck source=lib/main-account.sh
      source "$(dirname "${BASH_SOURCE[0]}")/main-account.sh"
      if ! main_account_enabled; then
        echo "$(date -Is) [lachesis-route] $1: Lachesis names main for $kind, but the owner's ARCHON_MAIN_ACCOUNT is off — no launch"
        return 1
      fi ;;
    *)
      echo "$(date -Is) [lachesis-route] $1: Lachesis names account '$account', which has no credential here — no launch"
      return 1 ;;
  esac
  until=$(quota_pause_until_account "$account")
  if [ "${until:-0}" -gt 0 ]; then
    echo "$(date -Is) [lachesis-route] $1: Lachesis names $account, but its last run hit the rate limit until $(date -d "@$until" -Is) — no launch"
    return 1
  fi
  QUOTA_ACCOUNT="$account"
  echo "$(date -Is) [lachesis-route] $1: $kind on $account (${reason})"
  return 0
}

# quota_launch_account <script-name> — the account a launch may use now, in
# QUOTA_ACCOUNT. With the owner's LACHESIS_ROUTE switch on, the one Lachesis
# route_run names (quota_route_account), falling back to the rules below only
# when route_run cannot be read. Otherwise: factory when it is not held; main
# while it is held and the owner's main account is on and within its paced cap
# (lib/main-account.sh). False, with one log line, when nothing may launch.
QUOTA_ACCOUNT=factory
quota_launch_account() {
  local until rc
  QUOTA_ACCOUNT=factory
  # shellcheck source=lib/lachesis.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lachesis.sh"
  if lachesis_route_enabled; then
    rc=0; quota_route_account "$1" || rc=$?
    [ "$rc" = 2 ] || return "$rc"
    QUOTA_ACCOUNT=factory
  fi
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
