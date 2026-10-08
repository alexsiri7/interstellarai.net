#!/usr/bin/env bash
# The owner's main Claude account as the factory's fallback while the factory
# account is rate limited, never past a pace the owner sets.
#
#   source "$SCRIPT_DIR/lib/main-account.sh"
#   main_account_may_launch "<script>" && <launch with --account main>
#
# Off unless the owner turns it on, outside this repo so archon cannot:
#   $MAIN_ACCOUNT_FLAG (default ~/.config/archon-cron/main-account), one line
#   ARCHON_MAIN_ACCOUNT=on
#
# The caps are the main config dir's own budget guard (the plan-usage plugin's
# budget-guard.json, written by install.sh --set-claude-token --account main),
# so the gate here and the guard inside every main-account session agree:
#   { "enabled": true, "weeklyCapPercent": 65, "fiveHourCapPercent": 60, "pace": true }
# With pace on, the weekly cap in force is weeklyCapPercent times the share of
# the 7-day window elapsed (65% with 10% of the week gone: 6.5%), so the owner's
# allowance is lent a little each day and never spent on the first one.
#
# The usage read is the plugin's plan-usage.json in that dir. The owner's own
# use of main (other machines, claude.ai) never reaches it, so a reading older
# than MAIN_ACCOUNT_MAX_AGE seconds is refreshed first with one haiku request
# through the factory door (claude-probe), which writes a current one. A
# reading that is still missing or stale after that holds the launch: an
# unknown figure is never taken as room.

[ -n "${_MAIN_ACCOUNT_SH:-}" ] && return 0
_MAIN_ACCOUNT_SH=1

MAIN_ACCOUNT_FLAG="${MAIN_ACCOUNT_FLAG:-$HOME/.config/archon-cron/main-account}"
MAIN_ACCOUNT_DIR="${MAIN_ACCOUNT_DIR:-/mnt/ext-fast/archon-home/.claude-main}"
MAIN_ACCOUNT_MAX_AGE="${MAIN_ACCOUNT_MAX_AGE:-600}"

# main_account_enabled — true when the owner's flag says ARCHON_MAIN_ACCOUNT=on.
# Under bats the host's flag is ignored unless the test names its own file.
main_account_enabled() {
  [ -n "${BATS_TEST_FILENAME:-}" ] && [ -z "${MAIN_ACCOUNT_FLAG_TEST:-}" ] && return 1
  [ -r "$MAIN_ACCOUNT_FLAG" ] || return 1
  [ "$(sed -nE 's/^[[:space:]]*ARCHON_MAIN_ACCOUNT=["'\'']?([a-z]+)["'\'']?[[:space:]]*(#.*)?$/\1/p' "$MAIN_ACCOUNT_FLAG" | tail -n 1)" = on ]
}

# main_account_probe — one haiku request on main, to refresh plan-usage.json.
main_account_probe() {
  if [ -n "${MAIN_ACCOUNT_PROBE_CMD:-}" ]; then
    $MAIN_ACCOUNT_PROBE_CMD >/dev/null 2>&1
  else
    ( cd / && sudo -n -u "${ARCHON_AS_USER:-archon}" "${ARCHON_AS_WRAPPER:-/usr/local/bin/archon-as-archon}" \
        --account main claude-probe 60 ) >/dev/null 2>&1
  fi
}

# main_account_verdict [now-epoch] — "ok <why>", "hold <why>" or "stale", from
# the guard file and plan-usage.json in MAIN_ACCOUNT_DIR.
main_account_verdict() {
  python3 - "$MAIN_ACCOUNT_DIR" "$MAIN_ACCOUNT_MAX_AGE" "${1:-$(date +%s)}" <<'PY'
import json, sys
from datetime import datetime
d, max_age, now = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
def ts(s): return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
try:
    guard = json.load(open(f"{d}/budget-guard.json"))
except (OSError, ValueError):
    print("hold no budget-guard.json in the main config dir"); sys.exit()
if guard.get("enabled") is not True:
    print("hold the main config dir's budget guard is off"); sys.exit()
try:
    rec = json.load(open(f"{d}/plan-usage.json"))
    if now - ts(rec["recordedAt"]) > max_age:
        print("stale"); sys.exit()
except (OSError, ValueError, KeyError, TypeError):
    print("stale"); sys.exit()
wins = {w.get("kind"): w for w in rec.get("rateLimits", [])}
week, five = wins.get("seven_day"), wins.get("five_hour")
if not week or not week.get("resetsAt"):
    print("hold no 7-day reading"); sys.exit()
cap = float(guard.get("weeklyCapPercent", 100))
if guard.get("pace") is True:
    left = ts(week["resetsAt"]) - now
    elapsed = min(1.0, max(0.0, 1 - left / (7 * 86400)))
    cap = round(cap * elapsed, 1)
used = float(week["percentUsed"])
if used >= cap:
    print(f"hold 7d {used:g}% at or past its cap {cap:g}%"); sys.exit()
five_cap = float(guard.get("fiveHourCapPercent", 100))
if five and float(five["percentUsed"]) >= five_cap:
    print(f"hold 5h {float(five['percentUsed']):g}% at or past its cap {five_cap:g}%"); sys.exit()
five_txt = f", 5h {float(five['percentUsed']):g}%/{five_cap:g}%" if five else ""
print(f"ok 7d {used:g}% of a {cap:g}% cap{five_txt}")
PY
}

# main_account_may_launch <script-name> — true when the factory may launch on
# main now; one log line either way when the flag is on.
main_account_may_launch() {
  main_account_enabled || return 1
  local v
  v=$(main_account_verdict)
  if [ "$v" = stale ]; then
    main_account_probe
    v=$(main_account_verdict)
    [ "$v" = stale ] && v="hold no current plan-usage.json after a probe"
  fi
  case "$v" in
    ok\ *)
      echo "$(date -Is) [main-account] $1: factory rate limited — launching on main (${v#ok })"
      return 0 ;;
    *)
      echo "$(date -Is) [main-account] $1: not on main — ${v#hold }"
      return 1 ;;
  esac
}
