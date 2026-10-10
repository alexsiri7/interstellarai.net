#!/usr/bin/env bash
# Liveness watch for the work-loop crons: tells "ticked and found nothing"
# apart from "stopped ticking". The heartbeat is the throttle stamp
# (lib/throttle.sh), which should_tick rewrites at the start of every real
# tick; a forced tick (ARCHON_CRON_FORCE_TICK=1) does not count.
#
# Usage:
#   source "$SCRIPT_DIR/lib/heartbeat.sh"
#   heartbeat_watch <name> <cron period in minutes>
#
# pipeline-health-cron.sh watches issue-pickup and pr-maintenance;
# issue-pickup-cron.sh watches pipeline-health, so stopping any one of the
# three is noticed. Under a throttle of T minutes a cron firing every P
# minutes really ticks every E = max(P, ceil(T/P)*P) minutes; the watch alerts
# once the stamp is older than 2E+P (two missed ticks, plus one cron slot for
# a tick that slips when T is a multiple of P). One ntfy per stale episode,
# marker in $HEARTBEAT_STATE_DIR (default
# ~/.archon/pipeline-health-state/heartbeat), written only once the ntfy went
# out; removed, with a `recovered` log line, when the cron ticks again.
# NTFY_TOPIC comes from the caller (lib/trust.sh or secrets.env).

[ -n "${_ARCHON_HEARTBEAT_SH:-}" ] && return 0
_ARCHON_HEARTBEAT_SH=1

# shellcheck source=lib/throttle.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/throttle.sh"

HEARTBEAT_STAMP_DIR="${HEARTBEAT_STAMP_DIR:-$HOME/.config/archon-cron/state}"
HEARTBEAT_STATE_DIR="${HEARTBEAT_STATE_DIR:-$HOME/.archon/pipeline-health-state/heartbeat}"

_heartbeat_log() { echo "$(date -Is) [heartbeat] $*"; }

# heartbeat_expected_minutes <cron period> — minutes between real ticks.
heartbeat_expected_minutes() {
  local period="$1" interval
  interval=$(throttle_interval_minutes heartbeat)
  local expected=$(( (interval + period - 1) / period * period ))
  [ "$expected" -lt "$period" ] && expected="$period"
  echo "$expected"
}

# heartbeat_watch <name> <cron period> — always returns 0: a watch never fails
# the caller's tick.
heartbeat_watch() {
  local name="$1" period="$2"
  local stamp="$HEARTBEAT_STAMP_DIR/$name.last_run"
  local marker="$HEARTBEAT_STATE_DIR/$name-alerted"
  local expected limit_min last now age_min problem=""
  expected=$(heartbeat_expected_minutes "$period")
  limit_min=$(( 2 * expected + period ))
  now=$(date +%s)
  last=$(cat "$stamp" 2>/dev/null)

  if ! [[ "$last" =~ ^[0-9]+$ ]]; then
    problem="$name has never ticked (no $stamp)"
  else
    age_min=$(( (now - last) / 60 ))
    if [ $(( now - last )) -gt $(( limit_min * 60 )) ]; then
      problem="$name last ticked $age_min min ago; expected every $expected min, alert after $limit_min (two missed ticks)"
    fi
  fi

  if [ -z "$problem" ]; then
    if [ -f "$marker" ]; then
      rm -f "$marker"
      _heartbeat_log "$name recovered — ticked $age_min min ago"
    fi
    return 0
  fi

  _heartbeat_log "$problem"
  [ -f "$marker" ] && return 0   # alert once per stale episode
  mkdir -p "$HEARTBEAT_STATE_DIR" 2>/dev/null || true
  if [ -z "${NTFY_TOPIC:-}" ]; then
    _heartbeat_log "$name: NTFY_TOPIC not set — logged only"
    touch "$marker" 2>/dev/null || true
    return 0
  fi
  if curl -s --fail -o /dev/null -H "Title: Factory cron silent: $name" \
       -H "Priority: high" -H "Tags: skull" \
       -d "$problem. Check ~/.local/state/archon-cron/logs/$name.log and \`crontab -l\`." \
       "ntfy.sh/$NTFY_TOPIC" 2>/dev/null; then
    touch "$marker" 2>/dev/null || true
  else
    _heartbeat_log "$name: ntfy failed, retrying next tick"
  fi
  return 0
}
