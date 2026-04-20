#!/usr/bin/env bash
# sweep-audits.sh — nightly codebase sweep, rotating through audit workflows.
#
# Runs one archon audit workflow per night on one project, cycling through:
#   4 repos × 3 sweep types = 12-day rotation (keyed off day-of-year).
#
# Night 1:  filmduel         — architect
# Night 2:  word-coach-annie — architect
# Night 3:  reli             — architect
# Night 4:  cosmic-match     — architect
# Night 5:  filmduel         — security
# Night 6:  word-coach-annie — security
# Night 7:  reli             — security
# Night 8:  cosmic-match     — security
# Night 9:  filmduel         — test-audit
# Night 10: word-coach-annie — test-audit
# Night 11: reli             — test-audit
# Night 12: cosmic-match     — test-audit
# (cycle repeats)
#
# Ported from archon/scripts/poll-sweep.sh. Matches the style of the other
# ops/cron scripts (log/notify helpers, SECRETS_FILE, SCRIPT_DIR, STATE_DIR).
#
# Crontab:
#   0 2 * * * <repo>/ops/cron/sweep-audits.sh >> /tmp/sweep-audits.log 2>&1

set -uo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="/mnt/ext-fast"
STATE_DIR="$HOME/.archon/sweep-state"
LOG_DIR="$HOME/.archon/logs/sweep"
CLAUDE_ACCOUNTS="${CLAUDE_ACCOUNTS:-$HOME/.claude:$HOME/.claude-secondary}"

# NTFY_TOPIC loaded from secrets.env. Fail loud if unset.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set — populate $SECRETS_FILE}"
LOG_PREFIX="[sweep-audits]"

export ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1

mkdir -p "$STATE_DIR" "$LOG_DIR"

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

notify() {
  local title="$1" msg="$2" priority="${3:-default}" tags="${4:-robot}"
  curl -s -o /dev/null \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
    -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
}

# Rotation config. Deliberately hardcoded (not loaded from archon-projects.txt):
# the 12-slot rotation depends on exactly 4 repos × 3 sweep types. Projects
# without substantial codebases to audit (un-reminder, interstellarai.net
# landing page) are intentionally excluded.
REPOS=(
  "alexsiri7/filmduel"
  "alexsiri7/word-coach-annie"
  "alexsiri7/reli"
  "alexsiri7/cosmic-match"
)

SWEEPS=(
  "archon-architect|Analyze the codebase architecture — identify complexity hotspots, unnecessary abstractions, and opportunities for simplification"
  "archon-security-audit|Perform a deep security and privacy audit of the entire codebase — check OWASP top 10, auth, data privacy, dependencies, and business logic"
  "archon-test-audit|Audit test coverage and stability — fix flaky tests, add tests for critical uncovered code paths, improve test quality"
)

# 4 repos × 3 sweeps = 12-day cycle, keyed off day-of-year.
day_of_year=$(date +%j)
slot=$(( (10#$day_of_year - 1) % 12 ))

sweep_idx=$(( slot / 4 ))
repo_idx=$(( slot % 4 ))

repo="${REPOS[$repo_idx]}"
repo_name=$(basename "$repo")
sweep_entry="${SWEEPS[$sweep_idx]}"
workflow="${sweep_entry%%|*}"
prompt="${sweep_entry#*|}"
sweep_name="${workflow#archon-}"

log "=== nightly sweep: $sweep_name on $repo_name (slot $slot of 12) ==="

# Skip if a sweep is already running for this repo (lock TTL: 2h)
lock_file="$STATE_DIR/${repo_name}.lock"
if [ -f "$lock_file" ]; then
  lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_file") ))
  if [ "$lock_age" -lt 7200 ]; then
    log "$repo_name: sweep still running (${lock_age}s), skipping"
    exit 0
  else
    log "$repo_name: stale lock (${lock_age}s), removing"
    rm -f "$lock_file"
  fi
fi

# Find local clone
local_path=""
for candidate in \
  "$HOME/.archon/workspaces/${repo}/source" \
  "$BASE_DIR/$repo_name" \
  "$HOME/$repo_name"; do
  if [ -d "$candidate/.git" ]; then
    local_path="$candidate"
    break
  fi
done

if [ -z "$local_path" ]; then
  log "ERROR: no local clone found for $repo"
  notify "Sweep: $repo_name" "No local clone found" high warning
  exit 1
fi

# Alternate Claude accounts per slot
IFS=':' read -ra accounts <<< "$CLAUDE_ACCOUNTS"
account_dir="${accounts[$((slot % ${#accounts[@]}))]}"
export CLAUDE_CONFIG_DIR="$account_dir"

log "repo: $local_path"
log "workflow: $workflow"
log "account: $(basename "$account_dir")"
touch "$lock_file"

logfile="$LOG_DIR/${repo_name}-${sweep_name}-$(date +%Y%m%d).log"

cd "$local_path"
if CLAUDECODE=0 archon workflow run "$workflow" "$prompt" > "$logfile" 2>&1; then
  log "$repo_name: $sweep_name sweep complete"
  notify "Sweep done: $repo_name" "$sweep_name complete — check for PR" default mag
else
  log "$repo_name: $sweep_name sweep failed (see $logfile)"
  notify "Sweep failed: $repo_name" "$sweep_name failed — check $logfile" high x
fi

rm -f "$lock_file"
log "=== nightly sweep complete ==="
