#!/usr/bin/env bash
# Liveness watch for the crons: tells "ticked and found nothing" apart from
# "stopped ticking". For the work-loop crons the heartbeat is the throttle
# stamp (lib/throttle.sh), which should_tick rewrites at the start of every
# real tick; a forced tick (ARCHON_CRON_FORCE_TICK=1) does not count. For the
# other crons it is the mtime of a file the cron writes every time it fires
# (its log, which the crontab line appends to).
#
# Usage:
#   source "$SCRIPT_DIR/lib/heartbeat.sh"
#   heartbeat_watch <name> <cron period in minutes>
#   heartbeat_watch_mtime <name> <cron period in minutes> <file>
#
# pipeline-health-cron.sh watches issue-pickup, pr-maintenance and the other
# crons; issue-pickup-cron.sh watches pipeline-health, so stopping any one of
# them is noticed. Under a throttle of T minutes a cron firing every P minutes
# really ticks every E = max(P, ceil(T/P)*P) minutes; a file written every
# time the cron fires has E = P. The watch alerts once the heartbeat is older
# than 2E+P (two missed ticks, plus one cron slot for a tick that slips when T
# is a multiple of P). One ntfy per stale episode, marker in
# $HEARTBEAT_STATE_DIR (default ~/.archon/pipeline-health-state/heartbeat),
# written only once the ntfy went out; removed, with a `recovered` log line,
# when the cron ticks again.
# NTFY_TOPIC comes from the caller (lib/trust.sh or secrets_load).

[ -n "${_ARCHON_HEARTBEAT_SH:-}" ] && return 0
_ARCHON_HEARTBEAT_SH=1

# shellcheck source=lib/throttle.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/throttle.sh"

HEARTBEAT_STAMP_DIR="${HEARTBEAT_STAMP_DIR:-$(throttle_state_dir)}"
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
  _heartbeat_judge "$name" "$period" "$(heartbeat_expected_minutes "$period")" \
    "$stamp" "$(cat "$stamp" 2>/dev/null)"
}

# heartbeat_watch_mtime <name> <cron period> <file> — <file>'s mtime is the
# heartbeat, so the cron must write it every time it fires. Always returns 0.
heartbeat_watch_mtime() {
  local name="$1" period="$2" file="$3"
  _heartbeat_judge "$name" "$period" "$period" "$file" "$(stat -c %Y "$file" 2>/dev/null)"
}

# _heartbeat_judge <name> <cron period> <expected minutes> <source> <last tick epoch>
_heartbeat_judge() {
  local name="$1" period="$2" expected="$3" source="$4" last="$5"
  local marker="$HEARTBEAT_STATE_DIR/$name-alerted"
  local limit_min=$(( 2 * expected + period )) now age_min problem=""
  now=$(date +%s)

  if ! [[ "$last" =~ ^[0-9]+$ ]]; then
    problem="$name has never ticked (no $source)"
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
