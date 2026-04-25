#!/usr/bin/env bash
# issue-pickup-cron.sh — run every 15 minutes from cron.
# Autonomous pipeline: auto-labels new issues, then picks up one per repo
# per tick and fires archon-fix-github-issue on the oldest queued one.
#
# Crontab:
#   */15 * * * * <repo>/ops/cron/issue-pickup-cron.sh >> /tmp/issue-pickup.log 2>&1

set -uo pipefail

# Cron has a minimal PATH; prepend where archon / gh / bun live.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
load_archon_projects DEFAULT_PROJECTS

# Age (seconds) after which an issue labeled archon:in-progress with no
# corresponding live archon process and no open PR is considered stuck and
# re-queued. Archon workflows usually finish in under an hour; 2h gives
# plenty of margin for slow CI and rate-limit backoff.
STUCK_AGE_SECONDS=7200
BASE_DIR="/mnt/ext-fast"
LOG_PREFIX="[issue-pickup]"

# Labels that make an issue a candidate for autonomous processing.
INGEST_LABELS=("enhancement" "bug")

# Labels archon already manages — presence of any of these means "don't re-queue".
ARCHON_LABELS=("archon:queued" "archon:in-progress" "archon:triage-in-progress" "archon:done" "archon:failed" "archon:skipped" "archon:blocked")

# Labels that signal human-only intent — triage must not reclassify these.
HUMAN_LABELS=("manual-review" "factory-gap" "human-needed" "wontfix" "duplicate" "question")

PROJECTS=("${DEFAULT_PROJECTS[@]}")
[ $# -gt 0 ] && PROJECTS=("$@")

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

# Per-tick, per-project summary state. Reset at the start of each project
# iteration, populated by the three phases, emitted after pick_and_fire.
SUMMARY_IN_PROGRESS=0
SUMMARY_STALE=0
SUMMARY_QUEUED=0
SUMMARY_BLOCKED=0
SUMMARY_PROMOTED=0
SUMMARY_ACTION="none"
SUMMARY_NOTE=""

ensure_labels() {
  local repo="$1"
  for label in archon:queued archon:in-progress archon:triage-in-progress archon:done archon:failed archon:skipped archon:blocked; do
    gh label create "$label" --repo "alexsiri7/$repo" \
      --color "c2e0c6" --description "Archon pipeline state" 2>/dev/null || true
  done
}

# Returns 0 (blocked) if the issue has at least one open "blocker" — defined
# as either an explicit `blocked_by` dependency OR an open sub-issue (child).
# Returns 1 (clear) otherwise.
#
# The child rule lets PRD/epic issues naturally park themselves while their
# phase children are in flight — no archon:skipped hygiene needed. When the
# last child closes, the PRD unblocks and gets picked up, which triggers a
# finalization archon run over the completed work.
#
# On API error, defaults to "clear" — we'd rather let a candidate run than
# freeze the pipeline on a transient failure; worst case is a phase runs
# slightly out of order.
has_open_blockers() {
  local project="$1" issue_num="$2"
  local blockers children
  blockers=$(gh api "repos/alexsiri7/$project/issues/$issue_num/dependencies/blocked_by" \
    --jq '[.[] | select(.state == "open")] | length' 2>/dev/null || echo 0)
  if [ "${blockers:-0}" -gt 0 ]; then
    return 0
  fi
  children=$(gh api "repos/alexsiri7/$project/issues/$issue_num/sub_issues" \
    --jq '[.[] | select(.state == "open")] | length' 2>/dev/null || echo 0)
  [ "${children:-0}" -gt 0 ]
}

has_archon_label() {
  local labels="$1"
  for al in "${ARCHON_LABELS[@]}"; do
    echo "$labels" | grep -q "\"$al\"" && return 0
  done
  return 1
}

has_human_label() {
  local labels="$1"
  for hl in "${HUMAN_LABELS[@]}"; do
    echo "$labels" | grep -q "\"$hl\"" && return 0
  done
  return 1
}

# --- Phase 0.5: auto-triage one issue that has no ingest label ---
# Picks the oldest untriaged issue (no archon:* and no bug/enhancement label,
# no human-intent label) and fires archon-triage-issue as a background workflow.
# One issue per tick, matching the pick_and_fire pattern for fixes.
# Only called when no fix workflow is already running for this repo (gated in
# the main loop by checking SUMMARY_ACTION after pick_and_fire).
auto_triage() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"

  if [ ! -d "$repo_dir/.git" ]; then
    return
  fi

  # Don't stack — skip if any archon workflow is already running for this repo.
  if pgrep -fa "archon workflow run.*--cwd.*$repo_dir" >/dev/null 2>&1; then
    return
  fi
  if pgrep -fa "archon workflow run" 2>/dev/null \
      | grep -qE "(^|[[:space:]=/])$project([[:space:]/]|\$)"; then
    return
  fi

  local issues
  issues=$(gh issue list --repo "alexsiri7/$project" --state open --limit 100 \
    --json number,labels,createdAt 2>/dev/null || echo "[]")

  local now_sec; now_sec=$(date +%s)
  local triage_issue=""

  while IFS= read -r row; do
    local num labels_json created created_sec age
    num=$(echo "$row" | jq -r '.number')
    labels_json=$(echo "$row" | jq -c '[.labels[].name]')
    created=$(echo "$row" | jq -r '.createdAt')
    created_sec=$(date -d "$created" +%s 2>/dev/null || echo 0)
    age=$((now_sec - created_sec))

    [ "$age" -lt 300 ] && continue
    has_archon_label "$labels_json" && continue
    echo "$labels_json" | grep -q '"archon:triage-in-progress"' && continue

    local has_ingest=0
    for il in "${INGEST_LABELS[@]}"; do
      echo "$labels_json" | grep -q "\"$il\"" && has_ingest=1 && break
    done
    [ "$has_ingest" = "1" ] && continue

    has_human_label "$labels_json" && continue

    triage_issue="$num"
    break
  done < <(echo "$issues" | jq -c '.[]' 2>/dev/null)

  [ -z "$triage_issue" ] && return

  gh issue edit "$triage_issue" --repo "alexsiri7/$project" \
    --add-label "archon:triage-in-progress" 2>/dev/null || true

  cd "$repo_dir"
  mkdir -p .archon-logs
  local logf=".archon-logs/cron-triage-$triage_issue-$(date +%Y%m%d-%H%M%S).log"
  CLAUDECODE=0 nohup archon workflow run archon-triage-issue \
    "triage #$triage_issue" --no-worktree >"$logf" 2>&1 &
  disown
  log "$project: triage launched for #$triage_issue (pid=$!, log=$logf)"
  SUMMARY_ACTION="triage #$triage_issue"
}

# --- Phase 0: un-stick stale archon:in-progress issues ---
# If an issue has been archon:in-progress for a long time and there's no
# running archon process for it and no open PR that references it, treat it
# as stuck (e.g. previous run died from rate-limit or crash) and re-queue.
# Uses the timeline API to find when the in-progress label was last added.
unstick_stale() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  local issues
  issues=$(gh issue list --repo "alexsiri7/$project" --state open \
    --label "archon:in-progress" --limit 50 --json number 2>/dev/null || echo "[]")

  local nums
  nums=$(echo "$issues" | jq -r '.[].number' 2>/dev/null)
  SUMMARY_IN_PROGRESS=$(echo "$issues" | jq 'length' 2>/dev/null || echo 0)
  [ -z "$nums" ] && return

  local now_sec; now_sec=$(date +%s)

  local num
  for num in $nums; do
    # Skip if a live archon process is working on this issue's repo and
    # references this issue number. Best-effort — we match on the archon
    # command line which includes the issue number in "fix #N".
    # Anchor project match to $repo_dir so e.g. `reli` does not substring-match
    # a worktree path containing `reliability`.
    if pgrep -fa "archon workflow run archon-fix-github-issue.*#$num\\b" >/dev/null 2>&1 \
        && pgrep -fa "archon workflow run archon-fix-github-issue" | grep -qE "(^|[[:space:]=/])$project([[:space:]/]|\$)"; then
      continue
    fi

    # Skip if any open PR body/title references this issue (GH auto-links
    # "Fixes #N" / "Closes #N", and archon's PRs include "Closes #N").
    local linked_prs
    linked_prs=$(gh pr list --repo "alexsiri7/$project" --state open --search "#$num in:body,title" --json number --jq 'length' 2>/dev/null || echo 0)
    if [ "${linked_prs:-0}" -gt 0 ]; then
      continue
    fi

    # Find when archon:in-progress was last added via timeline events.
    local labeled_at
    labeled_at=$(gh api "repos/alexsiri7/$project/issues/$num/timeline" \
      --jq '[.[] | select(.event=="labeled" and .label.name=="archon:in-progress") | .created_at] | last' 2>/dev/null || echo "")
    [ -z "$labeled_at" ] || [ "$labeled_at" = "null" ] && continue

    local labeled_sec; labeled_sec=$(date -d "$labeled_at" +%s 2>/dev/null || echo 0)
    local age=$((now_sec - labeled_sec))
    if [ "$age" -lt "$STUCK_AGE_SECONDS" ]; then
      continue
    fi

    # Don't re-queue issues that a human has explicitly parked (manual-review etc.)
    local issue_labels
    issue_labels=$(gh issue view "$num" --repo "alexsiri7/$project" --json labels \
      --jq '.labels | map(.name) | @json' 2>/dev/null || echo "[]")
    if has_human_label "$issue_labels"; then
      log "$project: #$num — skipping re-queue (has human-intent label)"
      continue
    fi

    log "$project: #$num is stuck (in-progress for ${age}s, no process, no PR) — re-queuing"
    gh issue edit "$num" --repo "alexsiri7/$project" \
      --remove-label "archon:in-progress" --add-label "archon:queued" 2>/dev/null || {
        log "$project: #$num — could not swap labels"
        continue
      }
    SUMMARY_STALE=$((SUMMARY_STALE + 1))
    gh issue comment "$num" --repo "alexsiri7/$project" \
      --body "archon was labeled in-progress ${age}s ago but no live run and no linked PR were found. Re-queued for another attempt." 2>/dev/null || true
  done
}

# --- Phase 1: auto-queue discovered issues ---
# Find issues labeled with any INGEST_LABEL that have NO archon:* label yet,
# add archon:queued to them. Only for issues older than 5 minutes to let
# humans explicitly skip via archon:skipped if they want to.
auto_queue() {
  local project="$1"
  local issues
  issues=$(gh issue list --repo "alexsiri7/$project" --state open --limit 100 \
    --json number,labels,createdAt 2>/dev/null || echo "[]")

  local now_sec; now_sec=$(date +%s)
  echo "$issues" | jq -c '.[]' 2>/dev/null | while read -r row; do
    local num created has_ingest
    num=$(echo "$row" | jq -r '.number')
    created=$(echo "$row" | jq -r '.createdAt')
    local labels_json
    labels_json=$(echo "$row" | jq -c '[.labels[].name]')

    if has_archon_label "$labels_json"; then
      continue
    fi

    # Must have at least one ingest label
    has_ingest=0
    for il in "${INGEST_LABELS[@]}"; do
      echo "$labels_json" | grep -q "\"$il\"" && has_ingest=1 && break
    done
    [ "$has_ingest" = "1" ] || continue

    # Age check: must be > 5 min old
    local created_sec; created_sec=$(date -d "$created" +%s 2>/dev/null || echo 0)
    local age=$((now_sec - created_sec))
    [ "$age" -lt 300 ] && continue

    # Dep-aware: if the issue has open blockers, park it in archon:blocked
    # instead of archon:queued. promote_unblocked will flip it later.
    local initial_label="archon:queued"
    if has_open_blockers "$project" "$num"; then
      initial_label="archon:blocked"
      log "$project: auto-labeling #$num archon:blocked (open blockers)"
    else
      log "$project: auto-queuing #$num (age ${age}s)"
    fi
    gh issue edit "$num" --repo "alexsiri7/$project" --add-label "$initial_label" 2>/dev/null || \
      log "$project: #$num — could not add $initial_label label"
  done
}

# --- Phase 1.5: promote archon:blocked issues whose blockers are all closed ---
# Runs after auto_queue so newly-filed sub-issues that happen to be unblocked
# get picked up on the same tick.
promote_unblocked() {
  local project="$1"
  local blocked_json
  blocked_json=$(gh issue list --repo "alexsiri7/$project" --state open \
    --label "archon:blocked" --limit 100 --json number 2>/dev/null || echo "[]")
  SUMMARY_BLOCKED=$(echo "$blocked_json" | jq 'length' 2>/dev/null || echo 0)

  local nums
  nums=$(echo "$blocked_json" | jq -r '.[].number' 2>/dev/null)
  [ -z "$nums" ] && return

  local num
  for num in $nums; do
    if has_open_blockers "$project" "$num"; then
      continue
    fi
    log "$project: #$num unblocked — promoting archon:blocked → archon:queued"
    if gh issue edit "$num" --repo "alexsiri7/$project" \
        --remove-label "archon:blocked" --add-label "archon:queued" 2>/dev/null; then
      SUMMARY_PROMOTED=$((SUMMARY_PROMOTED + 1))
      SUMMARY_BLOCKED=$((SUMMARY_BLOCKED - 1))
    else
      log "$project: #$num — could not swap blocked→queued"
    fi
  done
}

# --- Phase 2: pick up oldest queued issue per repo and fire archon ---
pick_and_fire() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"

  # Fetch queued list once, reuse for count + pick.
  # Order among queued siblings is NOT a contract — if issue A must run before
  # issue B, declare A as a `blocked_by` dep of B. Don't rely on filing order,
  # issue number, or gh's list sort.
  local queued_json
  queued_json=$(gh issue list --repo "alexsiri7/$project" --state open \
    --label "archon:queued" --limit 50 --json number 2>/dev/null || echo "[]")
  SUMMARY_QUEUED=$(echo "$queued_json" | jq 'length' 2>/dev/null || echo 0)

  if [ ! -d "$repo_dir/.git" ]; then
    log "$project: no repo at $repo_dir, skipping"
    SUMMARY_ACTION="skip"
    SUMMARY_NOTE="repo missing"
    return
  fi

  # Don't stack — if an archon run is already in flight for this repo, skip.
  # Capture the issue number from the cmdline ("fix #N") for the summary note.
  local running_for
  running_for=$(pgrep -fa "archon workflow run archon-fix-github-issue.*--cwd.*$repo_dir" 2>/dev/null \
    | grep -oE 'fix #[0-9]+' | head -1 | tr -d '#')
  if [ -n "$running_for" ]; then
    log "$project: archon already running, skipping"
    SUMMARY_ACTION="skip-running"
    SUMMARY_NOTE="archon already running for #$running_for"
    return
  fi
  # Fallback detector: look for runs started via direct cd (no --cwd).
  # Anchor project match so e.g. `reli` does not false-positive on
  # `reliability` or another slug containing the substring.
  running_for=$(pgrep -fa "archon workflow run archon-fix-github-issue" 2>/dev/null \
    | grep -E "(^|[[:space:]=/])$project([[:space:]/]|\$)" | grep -oE 'fix #[0-9]+' | head -1 | tr -d '#')
  if [ -n "$running_for" ]; then
    log "$project: archon already running (cwd match), skipping"
    SUMMARY_ACTION="skip-running"
    SUMMARY_NOTE="archon already running for #$running_for"
    return
  fi

  local issue
  issue=$(echo "$queued_json" | jq -r '.[0].number // empty' 2>/dev/null || echo "")

  if [ -z "$issue" ]; then
    return  # nothing queued; SUMMARY_ACTION stays "none"
  fi

  log "$project: picking up issue #$issue"
  gh issue edit "$issue" --repo "alexsiri7/$project" \
    --remove-label "archon:queued" --add-label "archon:in-progress" 2>/dev/null || true
  SUMMARY_ACTION="pickup #$issue"

  cd "$repo_dir"
  mkdir -p .archon-logs
  local logf=".archon-logs/cron-issue-$issue-$(date +%Y%m%d-%H%M%S).log"
  CLAUDECODE=0 nohup archon workflow run archon-fix-github-issue "fix #$issue" \
    >"$logf" 2>&1 &
  disown
  log "$project: archon launched for #$issue (pid=$!, log=$logf)"
}

for PROJECT in "${PROJECTS[@]}"; do
  SUMMARY_IN_PROGRESS=0
  SUMMARY_STALE=0
  SUMMARY_QUEUED=0
  SUMMARY_ACTION="none"
  SUMMARY_NOTE=""

  ensure_labels "$PROJECT"
  unstick_stale "$PROJECT"
  auto_queue "$PROJECT"
  promote_unblocked "$PROJECT"
  pick_and_fire "$PROJECT"
  # Triage only runs when the fix queue is idle — it fills otherwise-empty ticks.
  [ "$SUMMARY_ACTION" = "none" ] && auto_triage "$PROJECT"

  summary="$PROJECT: queued=$SUMMARY_QUEUED blocked=$SUMMARY_BLOCKED in-progress=$SUMMARY_IN_PROGRESS stale=$SUMMARY_STALE promoted=$SUMMARY_PROMOTED action=$SUMMARY_ACTION"
  [ -n "$SUMMARY_NOTE" ] && summary="$summary ($SUMMARY_NOTE)"
  log "$summary"
done

log "Done"
