#!/usr/bin/env bash
# pr-maintenance-cron.sh — Run from cron every 15 minutes.
# Zero AI cost when nothing to do. Processes one PR per project per run.
#
# Usage:
#   ./scripts/pr-maintenance-cron.sh                    # all projects
#   ./scripts/pr-maintenance-cron.sh cosmic-match reli  # specific projects
#
# Crontab entry:
#   */15 * * * * <repo>/ops/cron/pr-maintenance-cron.sh >> /tmp/pr-maintenance.log 2>&1

set -euo pipefail

# Cron runs with a minimal PATH (/usr/bin:/bin). archon, gh, bun, git
# often live in user-local bins; prepend them so the script works from
# both cron and an interactive shell.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
load_archon_projects DEFAULT_PROJECTS
# shellcheck source=lib/throttle.sh
source "$SCRIPT_DIR/lib/throttle.sh"
should_tick "pr-maintenance" || exit 0
# shellcheck source=lib/archon-active-runs.sh
source "$SCRIPT_DIR/lib/archon-active-runs.sh"
archon_runs_snapshot
BASE_DIR="${BASE_DIR:-/mnt/ext-fast}"
LOG_PREFIX="[pr-maintenance]"
# A PR carrying this label is left alone by every phase below (and by
# pr-review-cron.sh). It is how a human parks a PR that must stay open and
# unmerged — e.g. an asset-upload PR whose head another workflow fetches from.
HOLD_LABEL="hold"

# Use arguments if provided, otherwise all projects
if [ $# -gt 0 ]; then
  PROJECTS=("$@")
else
  PROJECTS=("${DEFAULT_PROJECTS[@]}")
fi

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

# ensure_hold_label <project> — create the hold label once per repo (same
# idempotent pattern as issue-pickup-cron's ensure_labels; exists => no-op).
ensure_hold_label() {
  gh label create "$HOLD_LABEL" --repo "alexsiri7/$1" \
    --color "5319E7" --description "Do not auto-merge, auto-review or auto-maintain" 2>/dev/null || true
}

# pr_on_hold <number> <hold-flag> — true (with a log line) when the PR list
# row's hold column is "true", i.e. the PR carries $HOLD_LABEL.
pr_on_hold() {
  [ "$2" = "true" ] || return 1
  log "$PROJECT: PR #$1 is on hold — skipping"
}

# pr_owned_by_live_run <number> <headRefName> <body>
# True when the PR's head is an archon task branch and a running or paused
# archon-ship / archon-fix-github-issue run for this project still owns it
# (matched on the run's "fix #N" message via the PR's closing keyword, or any
# such run for the project when the body has no closing keyword). Also true,
# with a log line, when this tick has no run snapshot: an archon branch whose
# run state is unknown is deferred rather than merged.
#
# Such a PR is still being worked: the run's review, corrections, CI wait and
# ready flip have not finished. Merging it here with --delete-branch deletes
# the local branch and its worktree from under the run (2026-09-08: lachesis
# PR #132 merged at 05:30 while its run was mid-review; the run died two
# minutes later with ENOENT on its cwd, reported as "'uv' executable not found",
# and its three Important review findings were never applied). Leave the flip
# and the merge until the run has exited.
pr_owned_by_live_run() {
  local pr="$1" head="$2" body="$3" wf issue
  case "$head" in
    archon/task-archon-ship-*) wf='^archon-ship$' ;;
    archon/task-archon-fix-github-issue-*) wf='^archon-fix-github-issue$' ;;
    *) return 1 ;;
  esac
  # Merging is the destructive branch (--delete-branch removes the run's
  # worktree), so an unreadable run DB fails closed for archon branches only;
  # human PRs are unaffected. The snapshot failure itself is already on stderr.
  if ! archon_runs_known; then
    log "$PROJECT: PR #$pr ($head) — no archon run snapshot this tick, treating as owned by a live run"
    return 0
  fi
  issue=$(printf '%s' "$body" \
    | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 \
    | grep -oE '[0-9]+$' || true)
  if [ -n "$issue" ]; then
    archon_run_active "$REPO_DIR" "$PROJECT" "$wf" "#${issue}([^0-9]|$)"
  else
    archon_run_active "$REPO_DIR" "$PROJECT" "$wf"
  fi
}

for PROJECT in "${PROJECTS[@]}"; do
  REPO_DIR="$BASE_DIR/$PROJECT"

  if [ ! -d "$REPO_DIR/.git" ]; then
    log "$PROJECT: not a git repo, skipping"
    continue
  fi

  cd "$REPO_DIR"
  ensure_hold_label "$PROJECT"

  # --- Phase 0: Promote CLEAN draft PRs to ready-for-review ---
  # Archon workflows create PRs as drafts by default. When CI is green the
  # draft has nothing left to gate on, but the Phase 1 merge filter skips
  # drafts — so left alone a green draft sits forever. Flip it to ready so
  # Phase 1 can merge it on this same tick.
  GREEN_DRAFTS=$(gh pr list --state open --json number,mergeStateStatus,isDraft,headRefName,labels,body \
    --jq '.[] | select(.isDraft == true and .mergeStateStatus == "CLEAN") | [.number, .headRefName, (((.labels // []) | map(.name) | index("hold")) != null), ((.body // "") | gsub("[\\t\\r\\n]"; " "))] | @tsv' 2>/dev/null || true)

  while IFS=$'\t' read -r PR HEAD HOLD BODY; do
    [ -n "$PR" ] || continue
    pr_on_hold "$PR" "$HOLD" && continue
    if pr_owned_by_live_run "$PR" "$HEAD" "$BODY"; then
      log "$PROJECT: draft PR #$PR ($HEAD) is owned by a live archon run — leaving the ready flip to it"
      continue
    fi
    log "$PROJECT: promoting draft PR #$PR to ready (CI CLEAN)"
    if ! gh pr ready "$PR" 2>>"/tmp/pr-maintenance-errors.log"; then
      log "$PROJECT: PR #$PR — could not mark ready (see /tmp/pr-maintenance-errors.log)"
    fi
  done <<< "$GREEN_DRAFTS"

  # --- Phase 1: Merge CLEAN PRs directly (bash only, zero AI cost) ---
  CLEAN_PRS=$(gh pr list --state open --json number,mergeStateStatus,isDraft,headRefName,labels,body \
    --jq '.[] | select(.isDraft == false and .mergeStateStatus == "CLEAN") | [.number, .headRefName, (((.labels // []) | map(.name) | index("hold")) != null), ((.body // "") | gsub("[\\t\\r\\n]"; " "))] | @tsv' 2>/dev/null || true)

  while IFS=$'\t' read -r PR HEAD HOLD BODY; do
    [ -n "$PR" ] || continue
    pr_on_hold "$PR" "$HOLD" && continue
    if pr_owned_by_live_run "$PR" "$HEAD" "$BODY"; then
      log "$PROJECT: PR #$PR ($HEAD) is owned by a live archon run — merging after it exits"
      continue
    fi
    log "$PROJECT: PR #$PR is CLEAN — merging directly"
    # Surface stderr to the cron log so actual failures (permissions, branch
    # protection, etc.) are diagnosable on the next tick instead of vanishing.
    if ! gh pr merge "$PR" --squash --auto --delete-branch 2>&1; then
      if ! gh pr merge "$PR" --squash --delete-branch 2>&1; then
        log "$PROJECT: PR #$PR — could not merge, skipping"
      fi
    fi
  done <<< "$CLEAN_PRS"

  # --- Phase 2: Check for one PR needing AI attention ---
  # Drafts count only when DIRTY. GitHub runs no pull_request workflow on a
  # conflicting PR, so a draft that goes DIRTY has no CI for the health cron's
  # PR-CI retry to see, never becomes CLEAN for Phase 0, and its issue stays
  # archon:in-progress behind a linked PR nobody touches (2026-09-09:
  # word-coach-annie #1121 sat conflicted for 2.5h after #1122 merged the same
  # file). Other draft states are still the opening run's to finish.
  CANDIDATES=$(gh pr list --state open --json number,mergeStateStatus,isDraft,headRefName,labels,body \
    --jq '.[] | select((.isDraft == false and (.mergeStateStatus == "BEHIND" or .mergeStateStatus == "DIRTY" or .mergeStateStatus == "UNSTABLE" or .mergeStateStatus == "UNKNOWN")) or (.isDraft == true and .mergeStateStatus == "DIRTY")) | [.number, .headRefName, (((.labels // []) | map(.name) | index("hold")) != null), ((.body // "") | gsub("[\\t\\r\\n]"; " "))] | @tsv' 2>/dev/null || true)

  ACTIONABLE=""
  while IFS=$'\t' read -r PR HEAD HOLD BODY; do
    [ -n "$PR" ] || continue
    pr_on_hold "$PR" "$HOLD" && continue
    if pr_owned_by_live_run "$PR" "$HEAD" "$BODY"; then
      log "$PROJECT: PR #$PR ($HEAD) needs maintenance but is owned by a live archon run — leaving it to the run"
      continue
    fi
    ACTIONABLE="$PR"
    break
  done <<< "$CANDIDATES"

  if [ -z "$ACTIONABLE" ]; then
    log "$PROJECT: no PRs need AI maintenance"
    continue
  fi

  log "$PROJECT: PR #$ACTIONABLE needs maintenance — launching archon"
  archon workflow run archon-pr-maintenance --cwd "$REPO_DIR" "PR #$ACTIONABLE" &

done

# Wait for any background archon runs to complete
wait
log "Done"
