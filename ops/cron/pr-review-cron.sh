#!/usr/bin/env bash
# pr-review-cron.sh — run every 5 minutes from cron.
# Fires archon-smart-pr-review against non-draft open PRs in managed repos,
# once per (repo, pr_number, head_sha). Uses the user's Claude.ai subscription
# auth (same as issue-pickup-cron.sh / pr-maintenance-cron.sh); no Anthropic
# API key required.
#
# Crontab:
#   */5 * * * * <repo>/ops/cron/pr-review-cron.sh >> /tmp/pr-review.log 2>&1
#
# State (per PR):
#   ~/.archon/state/pr-review/${project}-${pr}.pid          — PID:SHA, in-flight
#   ~/.archon/state/pr-review/${project}-${pr}-reviewed.sha — last reviewed SHA
#
# Flow:
#   Tick A: PR has no reviewed.sha (or SHA changed) AND no live pid file → fire
#           archon, write pid file with $!:headSha.
#   Tick B: pid file exists → if PID still alive skip; if dead read SHA from
#           pid file, write to reviewed.sha, remove pid file.

set -uo pipefail

# Cron has a minimal PATH; prepend where archon / gh / bun live.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

# Bail early with a clear log line if a required tool is missing.
for tool in gh jq archon; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$(date -Is) [pr-review] FATAL: '$tool' not in PATH ($PATH)" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
load_archon_projects DEFAULT_PROJECTS

BASE_DIR="/mnt/ext-fast"
STATE_DIR="$HOME/.archon/state/pr-review"
LOG_PREFIX="[pr-review]"
mkdir -p "$STATE_DIR"

PROJECTS=("${DEFAULT_PROJECTS[@]}")
[ $# -gt 0 ] && PROJECTS=("$@")

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

# reap_finished: for this project, sweep any stale pid-files whose PID has
# exited. When a PID is dead, record the SHA we were reviewing as the
# "reviewed" SHA so the same head doesn't get re-fired. Best-effort —
# archon's own logfile captures the actual review result.
reap_finished() {
  local project="$1"
  shopt -s nullglob
  local pidfile
  for pidfile in "$STATE_DIR/${project}"-*.pid; do
    local base pr_num pid sha
    base=$(basename "$pidfile" .pid)
    pr_num="${base#${project}-}"
    # Only accept numeric PR suffix — guards against stray files.
    [[ "$pr_num" =~ ^[0-9]+$ ]] || continue

    IFS=: read -r pid sha < "$pidfile" 2>/dev/null || continue
    [ -n "${pid:-}" ] || { rm -f "$pidfile"; continue; }

    if kill -0 "$pid" 2>/dev/null; then
      continue  # still running
    fi

    if [ -n "${sha:-}" ]; then
      echo "$sha" > "$STATE_DIR/${project}-${pr_num}-reviewed.sha"
      log "$project: PR #$pr_num — archon finished (pid $pid), recorded SHA ${sha:0:10}"
    else
      log "$project: PR #$pr_num — archon finished (pid $pid) with no SHA record"
    fi
    rm -f "$pidfile"
  done
  shopt -u nullglob
}

# process_project: list open PRs, filter to non-draft, and for each decide
# whether to skip (already-reviewed / in-flight / running-archon) or fire.
process_project() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"

  if [ ! -d "$repo_dir/.git" ]; then
    log "$project: no repo at $repo_dir, skipping"
    return
  fi

  local prs_json
  prs_json=$(gh pr list --repo "alexsiri7/$project" --state open \
    --json number,headRefOid,isDraft,updatedAt --limit 50 2>/dev/null || echo "[]")

  local n_open n_nondraft
  n_open=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)
  n_nondraft=$(echo "$prs_json" | jq '[.[] | select(.isDraft == false)] | length' 2>/dev/null || echo 0)

  local reviewed=0 skipped_running=0 fired=0 in_flight=0

  local rows
  rows=$(echo "$prs_json" | jq -r '.[] | select(.isDraft == false) | "\(.number) \(.headRefOid)"' 2>/dev/null || true)

  while IFS=' ' read -r pr_num sha; do
    [ -z "${pr_num:-}" ] && continue

    local pidfile="$STATE_DIR/${project}-${pr_num}.pid"
    local reviewed_file="$STATE_DIR/${project}-${pr_num}-reviewed.sha"

    # Still-running (reaped above or just fired) → skip
    if [ -f "$pidfile" ]; then
      in_flight=$((in_flight + 1))
      continue
    fi

    # Already reviewed at this SHA → skip.
    if [ -f "$reviewed_file" ] && [ "$(cat "$reviewed_file" 2>/dev/null)" = "$sha" ]; then
      reviewed=$((reviewed + 1))
      continue
    fi

    # Dedupe against a live archon process for THIS repo + PR. Anchor on the
    # project name inside the command line (cd "$repo_dir" puts the project
    # slug in the process's cwd/command) and on "#$pr_num" to be precise.
    if pgrep -fa "archon workflow run archon-smart-pr-review" 2>/dev/null \
         | grep -E "(^|[[:space:]=/])$project([[:space:]/]|\$)" \
         | grep -qE "#${pr_num}\\b"; then
      skipped_running=$((skipped_running + 1))
      continue
    fi

    # Fire archon.
    (
      cd "$repo_dir" || exit 1
      mkdir -p .archon-logs
      local logf=".archon-logs/pr-review-${pr_num}-$(date +%Y%m%d-%H%M%S).log"
      CLAUDECODE=0 nohup archon workflow run archon-smart-pr-review "#${pr_num}" \
        >"$logf" 2>&1 &
      disown
      echo "$!:$sha" > "$STATE_DIR/${project}-${pr_num}.pid"
      echo "LAUNCHED pid=$! log=$logf"
    ) > /tmp/.pr-review-fire.$$ 2>&1
    local fire_rc=$?
    local fire_out
    fire_out=$(cat /tmp/.pr-review-fire.$$ 2>/dev/null || true)
    rm -f /tmp/.pr-review-fire.$$
    if [ "$fire_rc" -eq 0 ] && echo "$fire_out" | grep -q '^LAUNCHED '; then
      fired=$((fired + 1))
      log "$project: PR #$pr_num — fired archon-smart-pr-review at SHA ${sha:0:10} (${fire_out#LAUNCHED })"
    else
      log "$project: PR #$pr_num — failed to launch archon: $fire_out"
    fi
  done <<< "$rows"

  log "$project: $n_open open, $n_nondraft non-draft, $reviewed reviewed-at-this-SHA, $in_flight in-flight, $skipped_running skipped-running, $fired fired"
}

for PROJECT in "${PROJECTS[@]}"; do
  reap_finished "$PROJECT"
  process_project "$PROJECT"
done

log "Done"
