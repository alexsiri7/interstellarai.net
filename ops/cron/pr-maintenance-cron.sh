#!/usr/bin/env bash
# pr-maintenance-cron.sh — Run from cron every 15 minutes.
# Zero AI cost when nothing to do. Processes one PR per project per run.
#
# Usage:
#   ./scripts/pr-maintenance-cron.sh                    # all projects
#   ./scripts/pr-maintenance-cron.sh cosmic-match reli  # specific projects
#
# Crontab entry:
#   */15 * * * * <repo>/ops/cron/pr-maintenance-cron.sh >> ~/.local/state/archon-cron/logs/pr-maintenance.log 2>&1

set -euo pipefail

# Cron runs with a minimal PATH (/usr/bin:/bin). archon, gh, bun, git
# often live in user-local bins; prepend them so the script works from
# both cron and an interactive shell.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-as.sh
source "$SCRIPT_DIR/lib/run-as.sh"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
load_archon_projects DEFAULT_PROJECTS
# shellcheck source=lib/throttle.sh
source "$SCRIPT_DIR/lib/throttle.sh"
should_tick "pr-maintenance" || exit 0
runas_may_launch "pr-maintenance" || exit 0
# shellcheck source=lib/ci-skip.sh
source "$SCRIPT_DIR/lib/ci-skip.sh"
# shellcheck source=lib/archon-active-runs.sh
source "$SCRIPT_DIR/lib/archon-active-runs.sh"
archon_runs_snapshot
# shellcheck source=lib/trust.sh
source "$SCRIPT_DIR/lib/trust.sh"
BASE_DIR="${BASE_DIR:-/mnt/ext-fast}"
LOG_PREFIX="[pr-maintenance]"
# Same directory the crontab sends this script's own log to; survives a reboot
# (/tmp does not). `gh pr ready` stderr is appended here across ticks.
LOG_DIR="${ARCHON_CRON_LOG_DIR:-$HOME/.local/state/archon-cron/logs}"
mkdir -p "$LOG_DIR"
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
# row's hold column is "true", i.e. the PR carries $HOLD_LABEL or the trust
# gate's $TRUST_HELD_LABEL (needs-owner-review: the scope check below failed).
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

# list_prs full|merge <jq select expression> — open PRs of the current repo
# whose author the trust gate admits at that level (lib/trust.sh: `full` =
# archon may work it, `merge` = may also be a merge-only bot's PR), one
# "<number>\t<headRefName>\t<hold>\t<body>" row each. Untrusted PRs are
# dropped here, before any phase sees them, and the owner is told once.
list_prs() {
  local level="$1" select="$2" json
  json=$(gh pr list --state open --json number,mergeStateStatus,isDraft,headRefName,labels,body,author,isCrossRepository,title,createdAt 2>/dev/null || echo "[]")
  trust_filter_prs "$PROJECT" "$level" <<<"$json" \
    | jq -r --arg held "$TRUST_HELD_LABEL" ".[] | select($select)"' | [.number, .headRefName, ((.labels // []) | map(.name) | (index("hold") or index($held))), ((.body // "") | gsub("[\\t\\r\\n]"; " "))] | @tsv' 2>/dev/null || true
}

# UNSAFE_CHANGE_CHECK: the repo-side check (pull_request_target, policy read
# from the base branch) that fails a PR doing anything on the repo's denylist
# (.github/unsafe-change.yml: CI/deploy/infra paths, secrets/auth paths, new
# dependencies, process/env/socket code, migrations beyond the app schema).
# Required before merging a PR that closes an issue only automated screening
# vetted (lib/screen.sh: archon:auto-approved).
UNSAFE_CHANGE_CHECK="${UNSAFE_CHANGE_CHECK:-unsafe-change}"
UNSAFE_CHANGE_POLICY="${UNSAFE_CHANGE_POLICY:-.github/unsafe-change.yml}"

# pr_scope_decision <number> <view-json> — prints ok, wait or hold <why>.
# ok: the PR closes no screened-only issue, or its unsafe-change check passed.
# wait: the check is still running. hold: the check failed, or the repo has no
# unsafe-change policy, or anything here could not be read or parsed. Every
# step fails closed: this decision is what keeps a PR built from a screened
# public issue from merging something on the denylist. JSON goes to jq through
# printf pipes, never here-strings, which need a temp file on a full disk.
pr_scope_decision() {
  local pr="$1" view="$2" refs body issues n flag screened="" state
  if ! refs=$(printf '%s' "$view" | jq -er '[.closingIssuesReferences[]?.number] | map(tostring) | join(" ")' 2>/dev/null); then
    echo "hold could not parse PR #$pr"; return
  fi
  if ! body=$(printf '%s' "$view" | jq -er '.body // ""' 2>/dev/null); then
    echo "hold could not parse PR #$pr"; return
  fi
  issues=$(printf '%s\n%s\n' "$refs" \
             "$(printf '%s' "$body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | grep -oE '[0-9]+$' | tr '\n' ' ')" \
           | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un || true)
  for n in $issues; do
    if ! flag=$(gh issue view "$n" --json labels 2>/dev/null \
         | jq -r --arg s "$TRUST_SCREENED_LABEL" --arg o "$TRUST_APPROVED_LABEL" \
             '[.labels[].name] | (index($s) != null and index($o) == null)' 2>/dev/null); then
      echo "hold could not read linked issue #$n"; return
    fi
    case "$flag" in   # jq -e would fail on a literal false; validate here
      true) screened="$screened #$n" ;;
      false) ;;
      *) echo "hold could not read linked issue #$n"; return ;;
    esac
  done
  [ -n "$screened" ] || { echo ok; return; }
  # Every rollup entry of that name must pass: another workflow can publish a
  # job called unsafe-change too.
  if ! state=$(printf '%s' "$view" | jq -er --arg c "$UNSAFE_CHANGE_CHECK" '
        [.statusCheckRollup[]? | select((.name // .context) == $c) | ((.conclusion // .state // "") | ascii_upcase)]
        | if length == 0 then "MISSING"
          elif all(. == "SUCCESS") then "SUCCESS"
          elif any(IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","STALE","SKIPPED","NEUTRAL")) then "FAILURE"
          else "PENDING" end' 2>/dev/null); then
    echo "hold could not parse the checks of PR #$pr"; return
  fi
  case "$state" in
    SUCCESS) echo ok ;;
    FAILURE) echo "hold $UNSAFE_CHANGE_CHECK check failed (closes screened issue${screened})" ;;
    PENDING) echo wait ;;
    *)
      if gh api "repos/alexsiri7/$PROJECT/contents/$UNSAFE_CHANGE_POLICY" --jq .path >/dev/null 2>&1; then
        echo wait
      else
        echo "hold no $UNSAFE_CHANGE_POLICY in this repo (closes screened issue${screened})"
      fi ;;
  esac
}

for PROJECT in "${PROJECTS[@]}"; do
  REPO_DIR="$BASE_DIR/$PROJECT"

  if [ ! -d "$REPO_DIR/.git" ]; then
    log "$PROJECT: not a git repo, skipping"
    continue
  fi

  cd "$REPO_DIR"
  ensure_hold_label "$PROJECT"
  gh label create "$TRUST_HELD_LABEL" --repo "alexsiri7/$PROJECT" \
    --color "d93f0b" --description "Held by the factory for the owner" 2>/dev/null || true

  # --- Phase 0: Promote CLEAN draft PRs to ready-for-review ---
  # Archon workflows create PRs as drafts by default. When CI is green the
  # draft has nothing left to gate on, but the Phase 1 merge filter skips
  # drafts — so left alone a green draft sits forever. Flip it to ready so
  # Phase 1 can merge it on this same tick.
  GREEN_DRAFTS=$(list_prs merge '.isDraft == true and .mergeStateStatus == "CLEAN"')

  while IFS=$'\t' read -r PR HEAD HOLD BODY; do
    [ -n "$PR" ] || continue
    pr_on_hold "$PR" "$HOLD" && continue
    if pr_owned_by_live_run "$PR" "$HEAD" "$BODY"; then
      log "$PROJECT: draft PR #$PR ($HEAD) is owned by a live archon run — leaving the ready flip to it"
      continue
    fi
    log "$PROJECT: promoting draft PR #$PR to ready (CI CLEAN)"
    if ! gh pr ready "$PR" 2>>"$LOG_DIR/pr-maintenance-errors.log"; then
      log "$PROJECT: PR #$PR — could not mark ready (see $LOG_DIR/pr-maintenance-errors.log)"
    fi
  done <<< "$GREEN_DRAFTS"

  # --- Phase 1: Merge CLEAN PRs directly (bash only, zero AI cost) ---
  CLEAN_PRS=$(list_prs merge '.isDraft == false and .mergeStateStatus == "CLEAN"')

  while IFS=$'\t' read -r PR HEAD HOLD BODY; do
    [ -n "$PR" ] || continue
    pr_on_hold "$PR" "$HOLD" && continue
    if pr_owned_by_live_run "$PR" "$HEAD" "$BODY"; then
      log "$PROJECT: PR #$PR ($HEAD) is owned by a live archon run — merging after it exits"
      continue
    fi
    if MERGE_HOLD=$(runas_merge_blocked "$PROJECT" "$PR"); then
      log "$PROJECT: PR #$PR is CLEAN but not auto-merged: $MERGE_HOLD"
      continue
    fi
    log "$PROJECT: PR #$PR is CLEAN — merging directly"
    # Left to itself GitHub builds the squash message out of the branch's commit
    # subjects, so a CI-authored "update snapshots" commit carrying a skip-ci
    # token lands on main and GitHub then creates no workflow run at all for the
    # push — no CI, no release, no deploy, silently (2026-09-10 reli 553e3f0,
    # 2026-09-11 un-reminder 7379c28). Compose the message from the PR's own
    # title and body instead, with every such token removed. Reading them fails
    # closed: a bare merge would reintroduce exactly this bug, and the PR is
    # still CLEAN on the next tick 15 minutes later.
    MERGE_JSON=$(gh pr view "$PR" --json title,body,closingIssuesReferences,statusCheckRollup 2>/dev/null || echo "")
    if [ -z "$MERGE_JSON" ]; then
      log "$PROJECT: PR #$PR — could not read title/body for the merge message, retrying next tick"
      continue
    fi
    # A PR built from an issue only automated screening vetted merges only
    # once the repo's unsafe-change scope check passed.
    SCOPE=$(pr_scope_decision "$PR" "$MERGE_JSON")
    case "$SCOPE" in
      ok) ;;
      wait)
        log "$PROJECT: PR #$PR — waiting for the $UNSAFE_CHANGE_CHECK check before merging"
        continue ;;
      *)
        log "$PROJECT: PR #$PR — not merging: ${SCOPE#hold }"
        gh pr edit "$PR" --add-label "$TRUST_HELD_LABEL" >/dev/null 2>&1 || true
        trust_notify_once "$PROJECT" pr-scope "$PR" \
          "PR #$PR on $PROJECT not auto-merged: ${SCOPE#hold }. Review it: https://github.com/alexsiri7/$PROJECT/pull/$PR"
        continue ;;
    esac
    MERGE_TITLE=$(ci_skip_clean_line "$(jq -r '.title // ""' <<<"$MERGE_JSON" || echo "")")
    if [ -n "$MERGE_TITLE" ]; then
      MERGE_SUBJECT="$MERGE_TITLE (#$PR)"
    else
      MERGE_SUBJECT="Merge pull request #$PR"
    fi
    MERGE_BODY=$(strip_ci_skip_tokens "$(jq -r '.body // ""' <<<"$MERGE_JSON" || echo "")")
    # Surface stderr to the cron log so actual failures (permissions, branch
    # protection, etc.) are diagnosable on the next tick instead of vanishing.
    if ! gh pr merge "$PR" --squash --auto --delete-branch \
         --subject "$MERGE_SUBJECT" --body "$MERGE_BODY" 2>&1; then
      if ! gh pr merge "$PR" --squash --delete-branch \
           --subject "$MERGE_SUBJECT" --body "$MERGE_BODY" 2>&1; then
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
  # Only `full` trust: archon-pr-maintenance reads the PR, so a merge-only
  # bot's PR (dependabot: upstream release notes in the body) never gets here.
  CANDIDATES=$(list_prs full '(.isDraft == false and (.mergeStateStatus == "BEHIND" or .mergeStateStatus == "DIRTY" or .mergeStateStatus == "UNSTABLE" or .mergeStateStatus == "UNKNOWN")) or (.isDraft == true and .mergeStateStatus == "DIRTY")')

  ACTIONABLE=""
  while IFS=$'\t' read -r PR HEAD HOLD BODY; do
    [ -n "$PR" ] || continue
    pr_on_hold "$PR" "$HOLD" && continue
    if pr_owned_by_live_run "$PR" "$HEAD" "$BODY"; then
      log "$PROJECT: PR #$PR ($HEAD) needs maintenance but is owned by a live archon run — leaving it to the run"
      continue
    fi
    if ! trust_comments_ok "$PROJECT" pr "$PR"; then
      log "$PROJECT: PR #$PR has untrusted comments or reviews — not handing it to archon"
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
