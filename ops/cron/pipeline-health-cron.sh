#!/usr/bin/env bash
# pipeline-health-cron.sh — runs every 30 minutes from cron.
# Detects and responds to pipeline-bottleneck states:
#   1. Main CI red (newest push-triggered run of each workflow at main HEAD)
#      → file issue tagged archon:in-progress + fire archon immediately
#      (dedup by SHA, by a tracked open "Main CI red" issue it filed, and by a 2h per-project cooldown)
#  1b. Main HEAD produced zero push workflow runs → ntfy; if its commit message
#      carries a CI-skip token, also auto-open an empty-commit re-trigger PR
#      (dedup per SHA, plus a 2h per-project cooldown on opening a PR)
#  1c. Scheduled workflows red on main → ntfy the operator only, no issue and no
#      archon: a missing secret is not something a commit can fix
#      (dedup per project+workflow in scheduled-health/ subdir)
#   2. Prod deploy failed or lagging main HEAD → file issue + fire archon (dedup by SHA)
#   3. Zombie archon DB runs (status=running, age >4h) → abandon
#   4. Disk >85% on / or /mnt/ext-fast → autoclean, then ntfy only if still
#      >=85%. For `/` that is the conservative full set (go/bun/npm/uv/pip
#      caches, user journal, idle Gradle version caches, APK builds >30d,
#      stale archon worktrees, stale /tmp dirs); for /mnt/ext-fast, where the
#      worktrees live, only the stale-worktree step; every failing step is logged
#   5. No pipeline progress in last tick (no commits, no archon completions)
#      while work is pending (queued/in-progress issues or actionable PRs):
#        - If token-limit markers in recent logs → wait, retry next tick
#        - Else → fire archon-assist diagnostic (dedup: 2h cooldown)
#  5b. Open archon PRs (non-draft, not CLEAN or BLOCKED) idle >2h → fire
#      archon-pr-maintenance, trusted authors/comments only; after 3 attempts
#      on one head SHA, ntfy + file a "factory stuck" issue (dedup by PR + SHA)
#   6. Open archon PRs with failed CI → fire archon-assist to diagnose + fix
#      (dedup by PR number, reset when PR merges/closes)
#  6b. Staging deploy HTTP health → ntfy operator if staging URL returns non-2xx/3xx
#      (informational only, no issue filed; dedup per-project in staging-health/ subdir)
#   7. Prod deploy HTTP health → file bug issue if deploy URL returns non-2xx/3xx
#      (dedup per-project, cleared on recovery)
#   8. Shipped-PR ntfy → emit "Shipped: repo #issue" for PRs that closed issues
#      in the last 24h, when the deploy URL is currently healthy
#      (dedup per-PR)
#  9e. Claude accounts: once a day, a real request against every config dir in
#      CLAUDE_ACCOUNTS (lib/claude-auth.sh) → ntfy once per day per failing
#      account + one `human-needed` tracking issue, closed on recovery
#
# Crontab (logs live under ~/.local/state/archon-cron/logs, which survives a
# reboot; /tmp does not):
#   */30 * * * * <repo>/ops/cron/pipeline-health-cron.sh >> ~/.local/state/archon-cron/logs/pipeline-health.log 2>&1
#   0 5 * * 0    <repo>/ops/cron/pipeline-health-cron.sh --trim >> ~/.local/state/archon-cron/logs/pipeline-health.log 2>&1
#
# `--trim` runs only the always-safe subset of the disk autoclean (uv/pip
# cache prune, idle Gradle version caches, old APK builds, stale archon
# worktrees, stale /tmp entries), logs the MB freed and exits. It never runs
# the >=85%-only steps that wipe hot caches (go clean -cache, bun pm cache rm,
# npm cache clean), skips the throttle gate and does none of the health checks.
#
# `--list-stale-worktrees` is the dry run of the stale-worktree step: it logs
# every worktree the autoclean would remove, with its size and a total, and
# removes nothing. Same gates skipped as `--trim`.

set -uo pipefail

MODE=tick
case "${1:-}" in
  --trim) MODE=trim; shift ;;
  --list-stale-worktrees) MODE=list-worktrees; shift ;;
  "") ;;
  *) echo "usage: $0 [--trim|--list-stale-worktrees]" >&2; exit 2 ;;
esac

# /snap/bin: uv (and go) are snaps, and cron does not put it on PATH.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/snap/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-as.sh
source "$SCRIPT_DIR/lib/run-as.sh"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
load_archon_projects REPOS
# shellcheck source=lib/throttle.sh
source "$SCRIPT_DIR/lib/throttle.sh"
if [ "$MODE" = tick ]; then
  should_tick "pipeline-health" || exit 0
  runas_may_launch "pipeline-health" || exit 0
fi
# shellcheck source=lib/archon-active-runs.sh
source "$SCRIPT_DIR/lib/archon-active-runs.sh"
# --trim touches no run, so it needs no snapshot (and no archon CLI call).
[ "$MODE" = tick ] && archon_runs_snapshot
# shellcheck source=lib/ci-skip.sh
source "$SCRIPT_DIR/lib/ci-skip.sh"
# shellcheck source=lib/claude-auth.sh
source "$SCRIPT_DIR/lib/claude-auth.sh"
# The PR checks that start archon (check_pr_ci_retry, check_stuck_prs) only see
# PRs lib/trust.sh rates `full`; a fork can name its branch `archon/…` too.
# shellcheck source=lib/trust.sh
source "$SCRIPT_DIR/lib/trust.sh"
BASE_DIR="${BASE_DIR:-/mnt/ext-fast}"
STATE_DIR="$HOME/.archon/pipeline-health-state"
# Where the crontab sends every script's stdout/stderr (see ops/cron/crontab).
# Only used here to name log files in messages and to park the archon-assist
# diagnostic output next to them.
LOG_DIR="${ARCHON_CRON_LOG_DIR:-$HOME/.local/state/archon-cron/logs}"

# NTFY_TOPIC loaded from secrets.env. Fail loud if unset.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set — populate $SECRETS_FILE}"
LOG_PREFIX="[pipeline-health]"

# Public prod-deploy URLs, keyed by project slug. Only projects listed here
# are subject to HTTP health checks + shipped-PR ntfys. Keep in sync with
# deploy workflows / ntfy steps in each repo's .github/workflows/.
declare -A DEPLOY_URLS=(
  ["filmduel"]="https://filmduel.interstellarai.net"
  ["word-coach-annie"]="https://annie.interstellarai.net/api/health"
  ["reli"]="https://reli.interstellarai.net/healthz"
  ["interstellarai.net"]="https://www.interstellarai.net/healthz"
  ["lachesis"]="https://lachesis.interstellarai.net/healthz"
  ["kindred"]="https://kindred.up.railway.app/healthz"
)

# Staging deploy URLs — subset of projects that have verified staging environments.
# Health checks here detect staging regressions before they block prod gates.
declare -A STAGING_DEPLOY_URLS=(
  ["filmduel"]="https://filmduel-staging.up.railway.app"
  ["reli"]="https://reli-staging.up.railway.app/healthz"
  ["word-coach-annie"]="https://word-coach-annie-staging.up.railway.app/api/health"
)

declare -A GITHUB_PROJECTS=(
  ["word-coach-annie"]="PVT_kwHOAANDVc4BV190"
  ["reli"]="PVT_kwHOAANDVc4BV191"
)

# Add an issue to the GitHub Project for its repo, if one is mapped.
# Args: $1=repo (owner/name or just name), $2=issue_num
add_to_project() {
  local repo="$1" issue_num="$2"
  local slug="${repo##*/}"  # strip "owner/" prefix if present
  local project_id="${GITHUB_PROJECTS[$slug]:-}"
  [ -z "$project_id" ] && return 0
  local node_id
  node_id=$(gh api "repos/alexsiri7/$slug/issues/$issue_num" \
    --jq '.node_id' 2>/dev/null || echo "")
  [ -z "$node_id" ] && return 0
  gh api graphql -f query="
  mutation {
    addProjectV2ItemById(input: {
      projectId: \"$project_id\"
      contentId: \"$node_id\"
    }) { item { id } }
  }" >/dev/null 2>&1 || true
}

mkdir -p "$STATE_DIR" "$LOG_DIR"
mkdir -p "$STATE_DIR/prciretry" "$STATE_DIR/escalated" \
         "$STATE_DIR/main-ci" "$STATE_DIR/escalated-main" \
         "$STATE_DIR/staging-health" "$STATE_DIR/scheduled-health" \
         "$STATE_DIR/parked" "$STATE_DIR/main-ci-missing"

# Max archon-remediation attempts against a single head SHA before we stop
# re-firing and ntfy the operator that the factory is stuck.
MAX_ATTEMPTS=3

# How far past its own recorded resume deadline a paused run may drift before
# check_parked_runs nudges it. 6x the longest `wait:` the sdlc pack declares
# (ci-pause, duration_ms 300000).
PARKED_WAIT_MAX_SECONDS="${PARKED_WAIT_MAX_SECONDS:-1800}"

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

# Returns curl's exit status, --fail so an ntfy.sh 5xx counts as undelivered.
# Only for the two checks whose ntfy is the operator's sole record (no issue, no
# archon run): they must not mark an alert delivered that never went out.
notify_checked() {
  local title="$1" msg="$2" priority="${3:-default}" tags="${4:-robot}"
  curl -s --fail -o /dev/null \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
    -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null
}

notify() { notify_checked "$@" || true; }

# ----------------------------------------------------------------------------
# file_stuck_issue: file a durable `manual-review`-labeled issue on the
# affected repo when the factory exhausts MAX_ATTEMPTS for a given SHA.
#
# The `manual-review` label is intentionally NOT in issue-pickup-cron.sh's
# INGEST_LABELS ("enhancement", "bug"), so these issues will NOT be re-queued
# into archon — they exist purely as a durable work item for a human.
#
# Dedup: at most one open `manual-review` issue per (repo, kind, sha). We
# search existing open issues by title for "SHA <sha>" and skip if one exists.
#
# Args:
#   $1 repo             — "owner/repo" (e.g. "alexsiri7/word-coach-annie")
#   $2 kind             — "main-ci" or "pr-ci"
#   $3 sha              — head SHA that is stuck
#   $4 subject_summary  — short human-readable subject (e.g. "word-coach-annie main CI red")
#   $5 evidence_link    — URL to the relevant CI run or PR
#   $6 attempts         — attempt count (for body, typically $MAX_ATTEMPTS)
#   $7 log_file         — path to the relevant archon log (for body)
# ----------------------------------------------------------------------------
file_stuck_issue() {
  local repo="$1" kind="$2" sha="$3" subject_summary="$4" \
        evidence_link="$5" attempts="$6" log_file="$7"

  # Ensure the label exists (idempotent — --force updates color/desc if present)
  gh label create --repo "$repo" manual-review \
    --color B60205 \
    --description "Factory escalation — needs human attention" \
    --force >/dev/null 2>&1 || true

  # Dedup: skip if an open manual-review issue for this SHA already exists.
  local existing
  existing=$(gh issue list --repo "$repo" --state open --label manual-review \
    --search "SHA $sha in:title" --json number --jq '.[0].number // empty' \
    2>/dev/null || echo "")
  if [ -n "$existing" ]; then
    log "$repo: manual-review issue #$existing already open for SHA $sha ($kind) — skipping"
    return
  fi

  local title="factory stuck: $subject_summary after $attempts attempts (SHA $sha)"
  local body
  body=$(cat <<EOF
## Factory escalation — manual review required

**Kind**: $kind
**Repo**: $repo
**SHA**: \`$sha\`
**Evidence**: $evidence_link
**Attempts**: $attempts (at MAX_ATTEMPTS)
**Archon log**: \`$log_file\`

Auto-filed by \`pipeline-health-cron.sh\` after \`sha_attempt_decide\` exhausted the remediation budget for this SHA. The ntfy alert has also been sent.

This issue is labeled \`manual-review\` only — \`issue-pickup-cron.sh\` will NOT auto-queue it into archon (its \`INGEST_LABELS\` is \`enhancement\` / \`bug\`). A human should diagnose why automated remediation kept failing for this SHA and either fix it or close the issue.
EOF
)

  local issue_url
  issue_url=$(gh issue create --repo "$repo" \
    --title "$title" \
    --label "manual-review" \
    --body "$body" 2>/dev/null | tail -1)
  local issue_num
  issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
  if [ -n "$issue_num" ]; then
    log "$repo: filed manual-review issue #$issue_num for $kind at $sha ($issue_url)"
    add_to_project "$repo" "$issue_num"
  else
    log "$repo: failed to file manual-review issue for $kind at $sha"
  fi
}

# ----------------------------------------------------------------------------
# sha_attempt_decide: shared helper for SHA-scoped remediation attempts.
#
# Args:
#   $1 marker_file        — path holding "<sha>:<attempts>"
#   $2 escalate_dir       — dir where presence of "<key>-<sha>" = already ntfy'd
#   $3 escalate_key       — prefix used to form the escalated-ntfy marker file
#                           (e.g. "$project" for main, "$project-pr<N>" for PR)
#   $4 current_sha        — head SHA we are evaluating right now
#
# Echoes one of:
#   FIRE <attempts_after_increment>   — caller should fire remediation
#   SKIP                              — already at/over MAX_ATTEMPTS for this
#                                       SHA; caller should NOT fire. If the
#                                       escalated-ntfy marker does not exist,
#                                       it will be created and this function
#                                       returns SKIP_NTFY instead, meaning the
#                                       caller should send the "factory stuck"
#                                       ntfy.
#   SKIP_NTFY                         — same as SKIP but caller must ntfy now.
#
# The marker is always (re)written to "<current_sha>:<attempts>" so that a
# SHA change resets the counter to 1 on the next FIRE and newer state wins.
# ----------------------------------------------------------------------------
sha_attempt_decide() {
  local marker_file="$1" escalate_dir="$2" escalate_key="$3" current_sha="$4"
  local recorded_sha="" recorded_attempts=0
  if [ -f "$marker_file" ]; then
    local content
    content=$(cat "$marker_file" 2>/dev/null || echo "")
    recorded_sha="${content%%:*}"
    recorded_attempts="${content##*:}"
    case "$recorded_attempts" in ''|*[!0-9]*) recorded_attempts=0 ;; esac
  fi

  local attempts
  if [ "$recorded_sha" != "$current_sha" ]; then
    # New SHA — reset budget
    attempts=1
    echo "${current_sha}:${attempts}" > "$marker_file"
    echo "FIRE $attempts"
    return
  fi

  if [ "$recorded_attempts" -lt "$MAX_ATTEMPTS" ]; then
    attempts=$((recorded_attempts + 1))
    echo "${current_sha}:${attempts}" > "$marker_file"
    echo "FIRE $attempts"
    return
  fi

  # At/over MAX_ATTEMPTS for this SHA — do not fire. Ntfy once per (key, SHA).
  local escalated_marker="$escalate_dir/${escalate_key}-${current_sha}"
  if [ ! -f "$escalated_marker" ]; then
    touch "$escalated_marker"
    echo "SKIP_NTFY"
    return
  fi
  echo "SKIP"
}

# Labels that mean "this issue already has an owner" — any archon:* pipeline
# state, or a human-intent label. Keep TRACKED_HUMAN_LABELS in sync with
# HUMAN_LABELS in lib/human-labels.sh. Filing a second issue beside one of
# these is the #75 refile loop.
TRACKED_HUMAN_LABELS='["manual-review","factory-gap","human-needed","wontfix","duplicate","question"]'
# archon:* states that mean a run is actually moving. The other archon:* states
# (failed/done/skipped/blocked) track an issue nobody is working — still a
# reason not to refile, but a reason to tell the operator once.
TRACKED_ACTIVE_LABELS='["archon:queued","archon:in-progress","archon:triage-in-progress"]'

# ----------------------------------------------------------------------------
# find_tracked_issue: echo "<number> active|stalled" for the first open issue on
# $1 that this script filed — title starting with $2, body carrying the
# "Auto-filed by `pipeline-health-cron.sh`" line — and which carries a tracked
# label; nothing if none. Any other archon:* issue that merely mentions the
# title must not stop a real one being filed (#126). Callers split with
# ${v%% *} / ${v##* }, as check_main_ci already does for sha_attempt_decide.
# jq runs as a pipeline stage rather than via `gh --jq` so
# the predicate stays exercisable against a stubbed gh.
# ----------------------------------------------------------------------------
find_tracked_issue() {
  local repo="$1" title="$2"
  gh issue list --repo "$repo" --state open \
    --search "$title in:title" --json number,title,body,labels 2>/dev/null \
    | jq -r --arg title "$title" --argjson human "$TRACKED_HUMAN_LABELS" --argjson active "$TRACKED_ACTIVE_LABELS" \
        '[ .[] | select(.title | startswith($title))
               | select((.body // "") | contains("Auto-filed by `pipeline-health-cron.sh`"))
               | select([.labels[].name] | any(startswith("archon:") or IN($human[]))) ]
         | .[0] // empty
         | "\(.number) \(if ([.labels[].name] | any(IN($active[]) or IN($human[])))
                          then "active" else "stalled" end)"' \
        2>/dev/null || echo ""
}

# ----------------------------------------------------------------------------
# fire_ship_and_settle <project> <issue> <repo-dir> <log>: run archon-ship on
# the issue in the background; the wrapper settles a no-PR verdict on it as
# soon as the run exits (lib/settle-ship-outcome.sh parks health-filed issues,
# never closes them — #107). Same shape as issue-pickup's pick_and_fire: the
# wrapper's command line carries the literal "fix #$1" and a repo-relative log
# path, so the pgrep guards only see the archon child. unstick_stale finds the
# log by its "-issue-N-" part.
# ----------------------------------------------------------------------------
fire_ship_and_settle() {
  local project="$1" issue_num="$2" repo_dir="$3" logf="$4"
  (
    cd "$repo_dir"
    CLAUDECODE=0 SETTLE_SCRIPT="$SCRIPT_DIR/lib/settle-ship-outcome.sh" SETTLE_PROJECT="$project" \
      nohup bash -c '
        archon workflow run archon-ship "fix #$1" >"$2" 2>&1
        "$SETTLE_SCRIPT" "$SETTLE_PROJECT" "$1" "$2"' \
      ship-wrapper "$issue_num" "${logf#"$repo_dir"/}" 2>/dev/null &
    disown
  )
}

# ----------------------------------------------------------------------------
# Check 1: Main CI red — file issue + fire archon immediately, dedup by SHA.
# ----------------------------------------------------------------------------
check_main_ci() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  [ -d "$repo_dir/.git" ] || return

  # Only push-triggered workflows are "main CI": a failing schedule/workflow_run
  # run is not something a commit on main can fix (#75). Repos run more than one
  # push workflow (un-reminder CI+Release, kindred CI+Migrate, reli CI+scan), so
  # take the newest run of EACH workflow at the current head SHA rather than the
  # single newest run, which alternates between them.
  local runs
  runs=$(gh run list --repo "alexsiri7/$project" --branch main --event push --limit 20 \
    --json databaseId,conclusion,headSha,workflowName 2>/dev/null || echo "")
  [ -n "$runs" ] || return

  # Anchor on the branch's real HEAD, not on whichever run the listing puts
  # first: the runs endpoint once returned a three-month-old failure at the
  # top, and this filed cosmic-match#246 against a SHA 22 commits behind main.
  # A HEAD with no listed push run at all is Check 1b's case, not a red.
  local sha
  sha=$(gh api "repos/alexsiri7/$project/commits/main" --jq '.sha' 2>/dev/null || echo "")
  if [ -z "$sha" ] || [ "$sha" = "null" ]; then
    log "$project: commits/main API returned no SHA — transient failure, skipping"
    return
  fi

  local at_head
  at_head=$(echo "$runs" | jq --arg sha "$sha" \
    '[.[] | select(.headSha == $sha)] | group_by(.workflowName) | map(.[0])')
  [ "$(echo "$at_head" | jq 'length')" -gt 0 ] || return 0

  local marker="$STATE_DIR/main-ci/$project"
  local failed run_id wf_name
  failed=$(echo "$at_head" | jq -r '[.[] | select(.conclusion == "failure")] | .[0] // empty')
  if [ -z "$failed" ]; then
    # Clear markers only when every push workflow at this SHA went green. A run
    # still in flight, or cancelled, is neither red nor a recovery.
    if [ "$(echo "$at_head" | jq -r \
         'if (length > 0) and (all(.[]; .conclusion == "success")) then "yes" else "no" end')" = "yes" ]; then
      rm -f "$marker" "$STATE_DIR/main-ci-cooldown-$project" 2>/dev/null || true
      find "$STATE_DIR/escalated-main" -maxdepth 1 -name "$project-*" -delete 2>/dev/null || true
      find "$STATE_DIR" -maxdepth 1 -name "main-ci-fired-$project-*" -delete 2>/dev/null || true
    fi
    return
  fi
  run_id=$(echo "$failed" | jq -r '.databaseId')
  wf_name=$(echo "$failed" | jq -r '.workflowName')

  # Dedup: an open "Main CI red" issue this script filed, with an archon:*
  # state or a human-intent label, means someone already owns this. Relabelling an auto-filed issue
  # `human-needed` used to slip past this guard and refile every tick (#75).
  # A `stalled` match (terminal archon state, no human label) means nobody is
  # on it — still don't refile, but say so once, since this guard returns
  # before sha_attempt_decide and so before any "factory stuck" escalation.
  local tracked tracked_num tracked_state
  tracked=$(find_tracked_issue "alexsiri7/$project" "Main CI red")
  if [ -n "$tracked" ]; then
    tracked_num="${tracked%% *}"
    tracked_state="${tracked##* }"
    if [ "$tracked_state" = "stalled" ]; then
      # Lives in escalated-main/ so the green branch's existing $project-* sweep
      # re-arms the alert when main recovers.
      local stall_marker="$STATE_DIR/escalated-main/$project-stalled-$tracked_num"
      if [ ! -f "$stall_marker" ]; then
        # Mark it delivered only once it is: this ntfy is the only record, so a
        # marker written ahead of a failed push loses the alert for good.
        if notify_checked "main CI still red: $project" \
          "Open issue #$tracked_num tracks it but no archon run is active.
https://github.com/alexsiri7/$project/issues/$tracked_num" \
          high warning; then
          touch "$stall_marker"
        else
          log "$project: ntfy for stalled issue #$tracked_num failed — retrying next tick"
        fi
      fi
    fi
    log "$project: main CI red, but open CI issue #$tracked_num is already tracked ($tracked_state) — skipping"
    return
  fi

  # Per-project cooldown (2h), mirroring check_prod_deploy: archon can "fix" a
  # config-caused red by landing a trivial commit and closing the issue, which
  # produces a new SHA, a reset attempt budget and an immediate re-fire. Cleared
  # whenever main goes green, so a genuine first red is never delayed. Returning
  # here does not consume an attempt — the cooldown throttles fires, it does not
  # spend the budget.
  local cooldown_marker="$STATE_DIR/main-ci-cooldown-$project"
  local now_epoch; now_epoch=$(date +%s)
  if [ -f "$cooldown_marker" ]; then
    local last_filed elapsed
    last_filed=$(cat "$cooldown_marker" 2>/dev/null || echo 0)
    elapsed=$(( now_epoch - last_filed ))
    if [ "$elapsed" -lt 7200 ]; then
      log "$project: main CI red at ${sha:0:10} — cooldown active (${elapsed}s < 2h since last issue filed), skipping"
      return
    fi
  fi

  # SHA-scoped attempt tracking: new SHA resets counter, same SHA retries up
  # to MAX_ATTEMPTS, then ntfys "factory stuck" and backs off.
  local decision action attempts
  decision=$(sha_attempt_decide "$marker" "$STATE_DIR/escalated-main" "$project" "$sha")
  action="${decision%% *}"
  attempts="${decision##* }"

  case "$action" in
    SKIP)
      log "$project: main CI red at $sha — already at MAX_ATTEMPTS=$MAX_ATTEMPTS, backed off"
      return
      ;;
    SKIP_NTFY)
      log "$project: main CI red at $sha — MAX_ATTEMPTS=$MAX_ATTEMPTS reached, ntfying operator"
      notify "factory stuck: $project main CI red" \
        "main CI red at $sha after $MAX_ATTEMPTS attempts" \
        high warning
      file_stuck_issue "alexsiri7/$project" "main-ci" "$sha" \
        "$project main CI red" \
        "https://github.com/alexsiri7/$project/actions/runs/$run_id" \
        "$MAX_ATTEMPTS" \
        "$repo_dir/.archon-logs/"
      return
      ;;
  esac

  local failed_jobs failed_workflows
  failed_jobs=$(gh run view "$run_id" --repo "alexsiri7/$project" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")' 2>/dev/null || echo "unknown")
  # group_by sorts by workflow name, so $wf_name/$run_id are the alphabetically
  # first failing workflow. Title-based dedup means the others never get an
  # issue of their own, so name them all here.
  failed_workflows=$(echo "$at_head" | jq -r '[.[] | select(.conclusion == "failure") | .workflowName] | join(", ")')

  log "$project: main CI red ($failed_jobs) at $sha — filing issue + firing archon (attempt $attempts/$MAX_ATTEMPTS)"

  local issue_body
  # lib/settle-ship-outcome.sh keys on the "Auto-filed by `pipeline-health-cron.sh`"
  # line to never auto-close this issue, and find_tracked_issue to dedup on it;
  # keep it verbatim.
  issue_body=$(cat <<EOF
## Main CI red

**Repo**: alexsiri7/$project
**SHA**: \`$sha\`
**Run**: https://github.com/alexsiri7/$project/actions/runs/$run_id
**Workflow**: $wf_name
**Failing workflows at this SHA**: $failed_workflows
**Failed jobs**: $failed_jobs

Auto-filed by \`pipeline-health-cron.sh\`. Main CI is a pipeline bottleneck, so archon has been fired immediately on this issue rather than queued. This issue is tagged \`archon:in-progress\` so the regular pickup cron will not double-fire.

### Steps
1. \`gh run view $run_id --repo alexsiri7/$project --log-failed\`
2. Identify root cause (dep bump? toolchain? flaky test?)
3. Fix on a branch, open PR, ensure CI goes green
EOF
)
  local issue_url
  issue_url=$(gh issue create --repo "alexsiri7/$project" \
    --title "Main CI red: $failed_jobs" \
    --label "bug,archon:in-progress" \
    --body "$issue_body" 2>/dev/null | tail -1)

  local issue_num
  issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
  if [ -z "$issue_num" ]; then
    log "$project: could not create issue — skipping archon fire (will retry next tick)"
    return
  fi

  echo "$now_epoch" > "$cooldown_marker"
  add_to_project "$project" "$issue_num"

  mkdir -p "$repo_dir/.archon-logs"
  local logf="$repo_dir/.archon-logs/health-ci-fix-${sha:0:8}-issue-${issue_num}-$(date +%Y%m%d-%H%M%S).log"
  fire_ship_and_settle "$project" "$issue_num" "$repo_dir" "$logf"
  log "$project: archon fired for issue #$issue_num (log $logf)"
}

# ----------------------------------------------------------------------------
# Check 1b: a main HEAD that produced no push workflow run at all.
#   check_main_ci only judges runs at main HEAD, so a SHA that triggered
#   zero runs is invisible to it.
#   That is exactly what a CI-skip token in a merge commit message does
#   (interstellarai.net#76): CI, release and the prod deploy silently never
#   happen. When the HEAD message explains it, open an empty-commit PR whose
#   merge produces a clean push; when it does not, the cause is something else
#   (Actions outage, disabled workflows, a paths: filter) so only ntfy.
# ----------------------------------------------------------------------------
check_main_push_ci() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  [ -d "$repo_dir/.git" ] || return

  local head_json head_sha head_ts head_msg head_tree
  head_json=$(gh api "repos/alexsiri7/$project/commits/main" \
    --jq '{sha: .sha, ts: .commit.committer.date, msg: .commit.message, tree: .commit.tree.sha}' 2>/dev/null || echo "")
  [ -n "$head_json" ] || return
  head_sha=$(echo "$head_json" | jq -r '.sha')
  head_ts=$(echo "$head_json" | jq -r '.ts')
  head_msg=$(echo "$head_json" | jq -r '.msg // ""')
  head_tree=$(echo "$head_json" | jq -r '.tree')

  if [ "$head_sha" = "null" ] || [ -z "$head_sha" ] || \
     [ "$head_ts" = "null" ] || [ -z "$head_ts" ] || \
     [ "$head_tree" = "null" ] || [ -z "$head_tree" ]; then
    log "$project: commits/main API returned null fields — transient failure, skipping"
    return
  fi

  # GitHub registers a run within seconds of a push; 10 minutes is slack for
  # API lag, not a wait for the run to finish.
  local now_epoch head_epoch age
  now_epoch=$(date +%s)
  head_epoch=$(date -d "$head_ts" +%s 2>/dev/null || echo 0)
  age=$(( now_epoch - head_epoch ))
  [ "$age" -gt 600 ] || return

  # A repo whose workflows simply do not run on push to main is not stuck.
  local ever
  ever=$(gh api "repos/alexsiri7/$project/actions/runs?branch=main&event=push&per_page=1" \
    --jq '.total_count' 2>/dev/null || echo "")
  case "$ever" in ''|*[!0-9]*) return ;; esac
  [ "$ever" -gt 0 ] || return

  local runs
  runs=$(gh api "repos/alexsiri7/$project/actions/runs?head_sha=$head_sha&event=push&per_page=1" \
    --jq '.total_count' 2>/dev/null || echo "")
  # An API failure is not evidence that no run exists.
  case "$runs" in ''|*[!0-9]*) return ;; esac

  local marker_dir="$STATE_DIR/main-ci-missing"
  if [ "$runs" -gt 0 ]; then
    find "$marker_dir" -maxdepth 1 -name "$project-*" -delete 2>/dev/null || true
    return
  fi

  local marker="$marker_dir/$project-${head_sha:0:12}"
  if [ -f "$marker" ]; then
    log "$project: ${head_sha:0:10} still has no push CI run — already handled, skipping"
    return
  fi

  local age_m=$(( age / 60 ))
  if ! has_ci_skip_token "$head_msg"; then
    log "$project: main HEAD ${head_sha:0:10} (${age_m}m old) produced no push workflow run and carries no CI-skip token — ntfying, cause unknown"
    notify "no CI on $project main" \
      "${head_sha:0:10} landed ${age_m}m ago with zero push workflow runs and no CI-skip token in its message. Check for an Actions outage, disabled workflows, or a new paths: filter." \
      high warning
    touch "$marker"
    return
  fi

  # Chain breaker: if the re-trigger commit is itself skipped, the new SHA gets
  # a fresh marker but this stops a second PR, same as check_prod_deploy's.
  local cooldown_marker="$STATE_DIR/main-ci-missing-cooldown-$project"
  if [ -f "$cooldown_marker" ]; then
    local last_filed elapsed
    last_filed=$(cat "$cooldown_marker" 2>/dev/null || echo 0)
    case "$last_filed" in ''|*[!0-9]*) last_filed=0 ;; esac
    elapsed=$(( now_epoch - last_filed ))
    if [ "$elapsed" -lt 7200 ]; then
      log "$project: main HEAD ${head_sha:0:10} has no push CI run — cooldown active (${elapsed}s < 2h since the last re-trigger PR), ntfying instead"
      notify "factory stuck: $project main has no CI" \
        "${head_sha:0:10} produced no push workflow run and a re-trigger PR was already opened within the last 2h. Re-trigger CI by hand." \
        high warning
      touch "$marker"
      return
    fi
  fi

  local open_retrigger
  open_retrigger=$(gh pr list --repo "alexsiri7/$project" --state open \
    --json number,headRefName \
    --jq '[.[] | select(.headRefName | startswith("ci/retrigger-"))] | .[0].number // empty' \
    2>/dev/null || echo "")
  if [ -n "$open_retrigger" ]; then
    log "$project: main HEAD ${head_sha:0:10} has no push CI run — re-trigger PR #$open_retrigger already open, skipping"
    touch "$marker"
    return
  fi

  local short="${head_sha:0:8}"
  log "$project: main HEAD $short produced no push workflow run and its message carries a CI-skip token — opening a re-trigger PR"

  # Built entirely through the API: $repo_dir is the live clone archon runs
  # work in, and creating branches under it has killed a run before
  # (lachesis PR #132, 2026-09-08).
  #
  # None of the three write failures below sets $marker: a SHA counts as handled
  # only once it has been notified or remediated, so a failed write is attempted
  # again on the next tick.
  local new_commit
  new_commit=$(gh api "repos/alexsiri7/$project/git/commits" \
    -f message="chore: re-trigger CI for $short" \
    -f tree="$head_tree" -f "parents[]=$head_sha" \
    --jq '.sha' 2>/dev/null || echo "")
  if [ -z "$new_commit" ] || [ "$new_commit" = "null" ]; then
    log "$project: could not create the re-trigger commit for $short — skipping"
    return
  fi

  local branch="ci/retrigger-$short"
  local new_ref
  new_ref=$(gh api "repos/alexsiri7/$project/git/refs" \
    -f ref="refs/heads/$branch" -f sha="$new_commit" \
    --jq '.ref' 2>/dev/null || echo "")
  if [ -z "$new_ref" ] || [ "$new_ref" = "null" ]; then
    log "$project: could not create branch $branch — skipping"
    return
  fi

  local pr_body
  pr_body=$(cat <<EOF
## Re-trigger CI for \`$short\`

\`$head_sha\` landed on \`main\` ${age_m} minutes ago carrying an instruction that
tells GitHub not to run workflows, so it produced **zero** push workflow runs —
no CI, no release, no prod deploy.

This PR is an empty commit on top of that SHA. Merging it puts a clean commit
message on \`main\`, which is enough for the push workflows to run.

Auto-opened by \`pipeline-health-cron.sh\` (\`check_main_push_ci\`); see
alexsiri7/interstellarai.net#76.
EOF
)
  local pr_url
  pr_url=$(gh pr create --repo "alexsiri7/$project" --base main --head "$branch" \
    --title "chore: re-trigger CI for $short" --body "$pr_body" 2>/dev/null | tail -1)
  if [ -z "$pr_url" ]; then
    log "$project: could not open the re-trigger PR for $short — skipping"
    return
  fi

  touch "$marker"
  echo "$now_epoch" > "$cooldown_marker"
  log "$project: opened re-trigger PR $pr_url for $short"
  notify "no CI on $project main — re-trigger PR opened" \
    "$short landed on main with no push workflow run. Opened $pr_url to produce a clean push." \
    high warning
}

# ----------------------------------------------------------------------------
# Check 1c: Scheduled workflows red on main — operator ntfy only.
#   A schedule-triggered workflow (uptime/disk/health monitors) failing is
#   almost always environment or config — a missing secret — not something a
#   commit on main can fix. Firing archon at one burns runs against an
#   unfixable target (#75), so this check only tells the operator.
#   workflow_run deploy runs are NOT handled here: Check 2 owns those.
#   Dedup per (project, workflow) in scheduled-health/, cleared on recovery.
#   Reads only the Actions API, so unlike Check 1 it needs no local clone.
# ----------------------------------------------------------------------------
check_scheduled_workflows() {
  local project="$1"
  local runs latest
  runs=$(gh run list --repo "alexsiri7/$project" --branch main --event schedule --limit 30 \
    --json conclusion,status,workflowName,url 2>/dev/null || echo "")
  [ -n "$runs" ] || return
  latest=$(echo "$runs" | jq -c \
    '[.[] | select(.status == "completed")] | group_by(.workflowName) | map(.[0]) | .[]' 2>/dev/null)
  [ -n "$latest" ] || return

  local run name conclusion url safe marker
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    name=$(echo "$run" | jq -r '.workflowName')
    conclusion=$(echo "$run" | jq -r '.conclusion')
    url=$(echo "$run" | jq -r '.url')
    safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')
    marker="$STATE_DIR/scheduled-health/$project-$safe"
    if [ "$conclusion" = "failure" ]; then
      if [ -f "$marker" ]; then
        log "$project: scheduled workflow '$name' still red — already notified, skipping"
        continue
      fi
      log "$project: scheduled workflow '$name' red ($url) — notifying operator, no archon"
      if notify_checked "Scheduled workflow red: $project" \
        "$name failed on main — $url
No archon run fired: fix the workflow or its config." \
        default warning; then
        touch "$marker"
      else
        log "$project: ntfy for scheduled workflow '$name' failed — retrying next tick"
      fi
    else
      [ -f "$marker" ] && log "$project: scheduled workflow '$name' recovered"
      rm -f "$marker"
    fi
  done <<< "$latest"
}

# ----------------------------------------------------------------------------
# Check 2: Prod deploy health — failed or lagging main HEAD.
#   Signal sources (try in order, use whichever exists):
#     (a) GH Actions workflow matching "Production" (Reli, WCA use "Staging → Production Pipeline")
#     (b) GitHub deployments API, environment matches "production" (Railway native integration, FilmDuel)
#   The listings only prove a signal exists; state is judged on the run or
#   deployment at main HEAD, never on whichever entry a listing puts first.
#   If the deploy at HEAD FAILED → file issue + fire archon (dedup by SHA).
#   If nothing deployed HEAD AND HEAD older than 15 min → file lag issue.
#   Projects with no deploy signal are skipped silently.
# ----------------------------------------------------------------------------
check_prod_deploy() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  [ -d "$repo_dir/.git" ] || return

  local head_json head_sha head_ts
  head_json=$(gh api "repos/alexsiri7/$project/commits/main" \
    --jq '{sha: .sha, ts: .commit.committer.date}' 2>/dev/null || echo "")
  [ -n "$head_json" ] || return
  head_sha=$(echo "$head_json" | jq -r '.sha')
  head_ts=$(echo "$head_json" | jq -r '.ts')

  # Guard: jq returns the string "null" for missing fields on error responses.
  # If we got null for either field, the API call failed — skip silently.
  if [ "$head_sha" = "null" ] || [ -z "$head_sha" ] || \
     [ "$head_ts" = "null" ] || [ -z "$head_ts" ]; then
    log "$project: commits/main API returned null SHA/TS — transient failure, skipping"
    return
  fi

  # --- Signal presence: does this project publish a prod deploy at all? ---
  # The listings only answer that question and supply the latest deploy the
  # lag issue cites. They do not decide state: the runs endpoint once led
  # with an August run for reli while the September HEAD was already live,
  # and comparing HEAD against it filed reli#1512 and tripped the stall
  # diagnostic. State is judged below on the deploy at HEAD itself.
  local latest_sha="" latest_ts="" latest_url=""
  local wf_run
  wf_run=$(gh run list --repo "alexsiri7/$project" --branch main --limit 10 \
    --json name,headSha,updatedAt,url 2>/dev/null \
    | jq -c '[.[] | select(.name | test("Production"; "i"))] | .[0] // empty' 2>/dev/null || echo "")
  if [ -n "$wf_run" ]; then
    latest_sha=$(echo "$wf_run" | jq -r '.headSha')
    latest_ts=$(echo "$wf_run" | jq -r '.updatedAt')
    latest_url=$(echo "$wf_run" | jq -r '.url')
  fi
  if [ -z "$latest_sha" ]; then
    local dep
    dep=$(gh api "repos/alexsiri7/$project/deployments?per_page=10" 2>/dev/null \
      | jq -c '[.[] | select(.environment | test("production"; "i"))] | .[0] // empty' 2>/dev/null || echo "")
    if [ -n "$dep" ]; then
      latest_sha=$(echo "$dep" | jq -r '.sha')
      latest_ts=$(echo "$dep" | jq -r '.created_at')
      latest_url="https://github.com/alexsiri7/$project/deployments"
    fi
  fi
  [ -n "$latest_sha" ] || return  # No deploy signal — skip silently

  # --- Judge at HEAD: newest Production run at head_sha, else newest
  # production deployment at head_sha. Empty state means nothing deployed HEAD.
  local deploy_sha="$head_sha" deploy_ts="" deploy_state="" deploy_url=""
  local head_run
  head_run=$(gh run list --repo "alexsiri7/$project" --branch main --commit "$head_sha" --limit 10 \
    --json name,conclusion,createdAt,updatedAt,url 2>/dev/null \
    | jq -c '[.[] | select(.name | test("Production"; "i"))] | sort_by(.createdAt) | last // empty' 2>/dev/null || echo "")
  if [ -n "$head_run" ]; then
    deploy_state=$(echo "$head_run" | jq -r '.conclusion // "pending"')
    deploy_ts=$(echo "$head_run" | jq -r '.updatedAt')
    deploy_url=$(echo "$head_run" | jq -r '.url')
  else
    local head_dep
    head_dep=$(gh api "repos/alexsiri7/$project/deployments?sha=$head_sha&per_page=10" 2>/dev/null \
      | jq -c '[.[] | select(.environment | test("production"; "i"))] | .[0] // empty' 2>/dev/null || echo "")
    if [ -n "$head_dep" ]; then
      local dep_id
      dep_id=$(echo "$head_dep" | jq -r '.id')
      deploy_state=$(gh api "repos/alexsiri7/$project/deployments/$dep_id/statuses?per_page=1" \
        --jq '.[0].state // "pending"' 2>/dev/null || echo "pending")
      deploy_ts=$(echo "$head_dep" | jq -r '.created_at')
      deploy_url="https://github.com/alexsiri7/$project/deployments"
    fi
  fi

  # --- Case 1: deploy FAILED ---
  if [ "$deploy_state" = "failure" ] || [ "$deploy_state" = "error" ]; then
    local marker="$STATE_DIR/prod-deploy-failed-$project-${deploy_sha:0:12}"
    if [ -f "$marker" ]; then
      log "$project: prod deploy still failed at ${deploy_sha:0:10} — already filed, skipping"
      return
    fi

    # Per-project cooldown (2h): prevents re-firing when Archon closes the issue
    # by landing a trivial commit (new SHA = new marker = loop). Infrastructure
    # failures like expired tokens can't be fixed with code commits.
    local cooldown_marker="$STATE_DIR/prod-deploy-cooldown-$project"
    local now_epoch; now_epoch=$(date +%s)
    if [ -f "$cooldown_marker" ]; then
      local last_filed; last_filed=$(cat "$cooldown_marker" 2>/dev/null || echo 0)
      local elapsed=$(( now_epoch - last_filed ))
      if [ "$elapsed" -lt 7200 ]; then
        log "$project: prod deploy FAILED at ${deploy_sha:0:10} — cooldown active (${elapsed}s < 2h since last issue filed), skipping"
        touch "$marker"
        return
      fi
    fi

    local existing
    existing=$(gh issue list --repo "alexsiri7/$project" --state open \
      --search "Prod deploy in:title" --json number,labels \
      --jq '[.[] | select((.labels | map(.name)) as $l | ($l | index("archon:queued")) or ($l | index("archon:in-progress")))] | .[0].number // empty' \
      2>/dev/null || echo "")
    if [ -n "$existing" ]; then
      log "$project: prod deploy failed, but open issue #$existing already queued — marker set, skipping"
      touch "$marker"
      return
    fi

    log "$project: prod deploy FAILED at ${deploy_sha:0:10} — filing issue + firing archon"

    local body
    # Keep the "Auto-filed by" line verbatim; see check_main_ci's issue body.
    body=$(cat <<EOF
## Prod deploy failed

**Repo**: alexsiri7/$project
**SHA**: \`$deploy_sha\`
**Deploy run/status**: $deploy_url
**State**: $deploy_state
**Deployed at**: $deploy_ts

Auto-filed by \`pipeline-health-cron.sh\`. Prod deploy is a pipeline bottleneck — archon has been fired immediately. This issue is tagged \`archon:in-progress\` so the pickup cron will not double-fire.

### Steps
1. Inspect deploy logs at $deploy_url
2. Identify root cause (Railway config? env var? build error? migration?)
3. Fix on a branch, land, confirm next deploy goes green
EOF
)
    local issue_url
    issue_url=$(gh issue create --repo "alexsiri7/$project" \
      --title "Prod deploy failed on main" \
      --label "bug,archon:in-progress" \
      --body "$body" 2>/dev/null | tail -1)
    local issue_num
    issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
    if [ -z "$issue_num" ]; then
      log "$project: could not create prod-deploy issue — skipping archon fire"
      return
    fi

    touch "$marker"
    echo "$now_epoch" > "$cooldown_marker"
    # No ntfy — archon has been fired and will auto-fix. If it can't,
    # the issue is parked archon:skipped for a human when the run ends with
    # a no-PR verdict.

    mkdir -p "$repo_dir/.archon-logs"
    local logf="$repo_dir/.archon-logs/health-prod-deploy-${deploy_sha:0:8}-issue-${issue_num}-$(date +%Y%m%d-%H%M%S).log"
    fire_ship_and_settle "$project" "$issue_num" "$repo_dir" "$logf"
    log "$project: archon fired for issue #$issue_num (log $logf)"
    return
  fi

  # --- Case 2: nothing has deployed main HEAD ---
  if [ -z "$deploy_state" ]; then
    local head_epoch now_epoch
    head_epoch=$(date -d "$head_ts" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    local age=$((now_epoch - head_epoch))
    if [ "$age" -gt 900 ]; then
      local marker="$STATE_DIR/prod-deploy-stale-$project-${head_sha:0:12}"
      if [ -f "$marker" ]; then
        log "$project: prod still lagging main ${head_sha:0:10} (age ${age}s) — already filed, skipping"
        return
      fi

      log "$project: prod LAGGING — main=${head_sha:0:10} prod=${deploy_sha:0:10} (head age ${age}s)"

      local body
      body=$(cat <<EOF
## Prod deploy lagging main

**Repo**: alexsiri7/$project
**main HEAD**: \`$head_sha\` (committed $head_ts, age ${age}s)
**Latest prod deploy**: \`$latest_sha\` at $latest_ts
**Deploy source**: $latest_url

Auto-filed by \`pipeline-health-cron.sh\`. main has been ahead of prod for >15 minutes, which suggests the deploy mechanism (Railway webhook, GH Actions workflow) did not fire or silently failed.

### Steps
1. Check $latest_url — is there a run for $head_sha?
2. If Railway-native: inspect Railway dashboard for the service, check webhook delivery
3. If GH Actions: re-dispatch the deploy workflow on main
EOF
)
      gh issue create --repo "alexsiri7/$project" \
        --title "Prod deploy lagging main" \
        --label "bug,archon:queued" \
        --body "$body" >/dev/null 2>&1 || true

      touch "$marker"
      # No ntfy — archon will handle the issue automatically.
    fi
    # A HEAD younger than 15 minutes is still waiting for its pipeline.
    return
  fi

  # Anything but success (in_progress, queued, cancelled, skipped, ...) is a
  # deploy still settling or one that never ran to a verdict. Leave the
  # markers alone; the next tick judges it again.
  if [ "$deploy_state" != "success" ]; then
    log "$project: prod deploy at HEAD ${head_sha:0:10} is $deploy_state — waiting"
    return
  fi

  # Deploy up to date — clear stale markers
  find "$STATE_DIR" -maxdepth 1 \( -name "prod-deploy-failed-$project-*" -o -name "prod-deploy-stale-$project-*" \) -delete 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Check 3: Abandon archon DB runs marked "running" for >4h — likely orphaned.
# NOTE (archon 0.10 cutover): `archon workflow abandon` did not exist in 0.3.6 —
# this cleanup was a silent no-op there. It works as intended on archon >= 0.10.
# Status output format (`  ID:` / `  Age:` lines) verified unchanged in 0.10.1.
# ----------------------------------------------------------------------------
reconcile_zombies() {
  local status_out
  status_out=$(cd "$BASE_DIR/archon" && \
    CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 archon workflow status 2>/dev/null || true)
  [ -n "$status_out" ] || return

  echo "$status_out" | awk '
    /^ *ID: / { id = $2; runstatus = "" }
    /^ *Status: / { runstatus = $2 }
    /^ *Age: / {
      age_str = $2
      age_hours = 0
      if (age_str ~ /d$/) {
        age_hours = 24
      } else if (age_str ~ /h$/) {
        n = age_str
        gsub(/h$/, "", n)
        age_hours = n + 0
      }
      # Paused runs are parked at a durable wait — the server resumes them;
      # age alone does not make them zombies. Only reap stale RUNNING rows.
      if (age_hours >= 4 && runstatus == "running") print id
    }
  ' | while read -r stale_id; do
    [ -n "$stale_id" ] || continue
    log "abandoning stale archon run $stale_id (age >=4h)"
    (cd "$BASE_DIR/archon" && \
      CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 \
      archon workflow abandon "$stale_id" 2>&1 | tail -1)
  done
}

# ----------------------------------------------------------------------------
# Check 3: Disk warning — ntfy if / or /mnt/ext-fast above 85%, after an
# autoclean attempt: the conservative cache cleanup for `/`, the stale-worktree
# step alone for /mnt/ext-fast. Only ntfy if still over threshold after
# cleanup. Every step is non-fatal and every failure is logged with its
# exit code: a step that fails silently is one that never frees anything.
# ----------------------------------------------------------------------------
disk_used_pct() {
  df -P "$1" 2>/dev/null | awk 'NR==2 { gsub("%",""); print $5 }'
}

dir_size_mb() {
  if [ -z "$1" ] || [ ! -d "$1" ]; then echo 0; return; fi
  du -sm "$1" 2>/dev/null | cut -f1 || echo 0
}

# autoclean_step <label> <dir-or-empty> <cmd...>
# Runs one cleanup command, logging the outcome instead of swallowing it.
# When a target dir is given, reports how many MB it lost. Always returns 0
# so a failing step never aborts the ones after it.
autoclean_step() {
  local label="$1" dir="$2"; shift 2
  local before=0 out rc=0
  [ -n "$dir" ] && before=$(dir_size_mb "$dir")
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    local reason; reason=$(printf '%s\n' "$out" | grep -v '^$' | tail -n1)
    log "autoclean: $label failed (exit $rc)${reason:+: $reason}"
    return 0
  fi
  if [ -n "$dir" ]; then
    log "autoclean: $label ok — freed $((before - $(dir_size_mb "$dir")))MB"
  else
    log "autoclean: $label ok"
  fi
  return 0
}

# bun_pm_cache [args...] — `bun pm cache` and `bun pm cache rm` (bun 1.3.x)
# exit 1 with "No package.json was found" unless the cwd holds a manifest.
# Cron's cwd is $HOME, so the step failed on every tick and `|| true` hid it
# while the cache grew to 14 GB. Run bun from a throwaway dir with an empty
# manifest instead.
# shellcheck disable=SC2120  # called both bare (print dir) and with `rm`
bun_pm_cache() {
  local dir rc=0
  dir=$(mktemp -d) || return 1
  echo '{}' > "$dir/package.json"
  (cd "$dir" && bun pm cache "$@") || rc=$?
  rm -rf "$dir"
  return "$rc"
}

# The full autoclean, only ever run under disk pressure (check_disk, / >=85%).
# The first three steps wipe caches that are hot on a healthy box (a go/bun/npm
# build after them re-downloads everything), which is why they never run on the
# weekly --trim; everything else is the always-safe subset in autoclean_light.
autoclean_root() {
  if command -v go >/dev/null 2>&1; then
    autoclean_step "go clean -cache" "$(go env GOCACHE 2>/dev/null)" go clean -cache
  fi
  if command -v bun >/dev/null 2>&1; then
    # shellcheck disable=SC2119
    autoclean_step "bun pm cache rm" "$(bun_pm_cache 2>/dev/null)" bun_pm_cache rm
  fi
  if command -v npm >/dev/null 2>&1; then
    autoclean_step "npm cache clean --force" "$(npm config get cache 2>/dev/null)" npm cache clean --force
  fi
  if command -v journalctl >/dev/null 2>&1; then
    autoclean_step "journalctl --user --vacuum-time=7d" "" journalctl --user --vacuum-time=7d
  fi
  autoclean_idle_dir "$HOME/.cache/puccinialin" 30
  autoclean_light
}

# The cheap, always-safe steps: they only drop what is already unreferenced or
# idle (uv/pip prune their own unused entries; the rest are 30d-idle Gradle
# version caches, >30d APK builds nothing points at, worktrees with no open PR,
# stale /tmp entries). Weekly via `--trim`, and the tail of autoclean_root.
autoclean_light() {
  if command -v uv >/dev/null 2>&1; then
    autoclean_step "uv cache prune" "$(uv cache dir 2>/dev/null)" uv cache prune
  fi
  if command -v pip >/dev/null 2>&1; then
    # `pip cache purge` exits 1 when there is nothing to purge — only run it
    # against a populated cache so an empty one is not logged as a failure.
    local pip_cache; pip_cache=$(pip cache dir 2>/dev/null)
    if [ -n "$pip_cache" ] && find "$pip_cache" -type f -print -quit 2>/dev/null | grep -q .; then
      autoclean_step "pip cache purge" "$pip_cache" pip cache purge
    fi
  fi
  autoclean_gradle_caches
  autoclean_apks
  autoclean_stale_worktrees
  autoclean_tmp
}

# disk_used_kb <mount> — used KB on the filesystem, for before/after deltas.
disk_used_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 { print $3 }'
}

# run_trim — the weekly `--trim` entry point: autoclean_light plus a one-line
# summary of what it freed on /, measured at the filesystem so the steps that
# report no dir of their own (worktrees, /tmp) are counted too.
run_trim() {
  local before after freed
  before=$(disk_used_kb /); before="${before:-0}"
  log "=== weekly trim (light autoclean) === disk / at $(disk_used_pct /)%"
  autoclean_light
  after=$(disk_used_kb /); after="${after:-$before}"
  freed=$(( (before - after) / 1024 ))
  [ "$freed" -lt 0 ] && freed=0
  log "=== trim done — freed ${freed}MB on / (now $(disk_used_pct /)%) ==="
}

# autoclean_idle_dir <dir> <days> — remove a whole directory when nothing in
# it has been written for <days> days. Used for caches that are rebuilt on
# demand and have no prune command of their own.
autoclean_idle_dir() {
  local dir="$1" days="$2"
  [ -d "$dir" ] || return 0
  if find "$dir" -type f -mtime "-$days" -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  local size rc=0; size=$(dir_size_mb "$dir")
  rm -rf "$dir" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "autoclean: rm -rf $dir failed (exit $rc)"
  else
    log "autoclean: removed $dir (idle >${days}d) — freed ${size}MB"
  fi
  return 0
}

# Gradle keeps one cache tree per Gradle version under ~/.gradle/caches
# (8.14, 8.14.1, 9.0.0, ...). A version no wrapper has used for 30 days is
# dead weight — 9.0.0 + 9.4.1 sat at 2.7 GB with nothing written since
# August. Only version-named dirs are candidates: modules-2, jars-*, journal-1
# and the transforms inside a live version are never touched.
autoclean_gradle_caches() {
  local caches="${PIPELINE_HEALTH_GRADLE_CACHES:-$HOME/.gradle/caches}"
  [ -d "$caches" ] || return 0
  local dir name
  for dir in "$caches"/*/; do
    [ -d "$dir" ] || continue
    dir="${dir%/}"; name=$(basename "$dir")
    [[ "$name" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || continue
    autoclean_idle_dir "$dir" 30
  done
  return 0
}

# ~/apks holds <project>-<sha>.apk builds plus a <project>-latest.apk symlink
# (fetch-apks.sh, and the retired auto-apk-sync.sh before it, which never
# pruned: 150 builds / 7.1 GB by 2026-09). Drop builds older than 30 days
# unless a *-latest.* symlink in the same dir resolves to them. Symlinks
# themselves are never candidates (-type f).
autoclean_apks() {
  local apk_dir="${PIPELINE_HEALTH_APK_DIR:-$HOME/apks}"
  local dir total=0 removed=0
  for dir in "$apk_dir" "$apk_dir/aab"; do
    [ -d "$dir" ] || continue
    local keep="" link target
    for link in "$dir"/*-latest.*; do
      [ -L "$link" ] || continue
      target=$(readlink -f "$link" 2>/dev/null) || continue
      keep+="$target"$'\n'
    done
    local f resolved sz rc
    while IFS= read -r f; do
      resolved=$(readlink -f "$f" 2>/dev/null) || resolved="$f"
      if printf '%s' "$keep" | grep -qxF "$resolved"; then
        continue
      fi
      sz=$(du -sb "$f" 2>/dev/null | cut -f1); sz="${sz:-0}"
      rc=0; rm -f "$f" || rc=$?
      if [ "$rc" -ne 0 ]; then
        log "autoclean: rm $f failed (exit $rc)"
      else
        total=$((total + sz)); removed=$((removed + 1))
      fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f \( -name '*.apk' -o -name '*.aab' \) -mtime +30 2>/dev/null)
  done
  [ "$removed" -gt 0 ] && log "autoclean: removed $removed APK/AAB builds older than 30d under $apk_dir — freed $((total / 1048576))MB"
  return 0
}

# autoclean_stale_worktrees [--dry-run] — remove Archon task worktrees whose
# branch has no open PR and that nothing has touched for 4h. Covers the
# retry-loop accumulation pattern (hundreds of failed task dirs from a broken
# archon period). Two layouts hold them: the 0.10 one under
# ~/.archon/workspaces/{ext-fast,alexsiri7}/<project>/worktrees/archon and the
# pre-0.10 one under $BASE_DIR/.archon/worktrees/ext-fast/<project>/archon
# (~/.archon/worktrees is a symlink to it), which held 509 dirs / 148 GB by
# 2026-09-21 because only the first was scanned. Both register against the
# main checkout at $BASE_DIR/<project>, so one `worktree prune` there covers
# either. A project whose `gh pr list` fails is skipped: an empty answer
# would read as "no open PRs" and delete live work.
# --dry-run logs each candidate with its size and a total, removes nothing.
autoclean_stale_worktrees() {
  local dry_run=0
  [ "${1:-}" = "--dry-run" ] && dry_run=1
  local candidates=0 total_mb=0
  for repo_dir in "$BASE_DIR"/*/; do
    [ -d "$repo_dir/.git" ] || continue
    local project; project=$(basename "$repo_dir")

    # One API call per repo to get all open PR branches. gh's default page is
    # 30; a PR past that would read as "no open PR" and its worktree deleted.
    local open_branches
    if ! open_branches=$(gh pr list --repo "alexsiri7/$project" --state open --limit 200 \
        --json headRefName --jq '.[].headRefName' 2>/dev/null); then
      log "autoclean: gh pr list failed for $project — skipping its worktrees"
      continue
    fi

    local removed=0
    local wt_base
    for wt_base in \
      "$HOME/.archon/workspaces/ext-fast/$project/worktrees/archon" \
      "$HOME/.archon/workspaces/alexsiri7/$project/worktrees/archon" \
      "$BASE_DIR/.archon/worktrees/ext-fast/$project/archon"; do
      [ -d "$wt_base" ] || continue
      while IFS= read -r wt_path; do
        local wt_name; wt_name=$(basename "$wt_path")
        local branch="archon/$wt_name"
        # Keep if there is an open PR on this branch.
        if echo "$open_branches" | grep -qxF "$branch"; then
          continue
        fi
        # Keep if modified in the last 4h — task may be in-progress but pre-PR.
        if find "$wt_path" -maxdepth 0 -mmin -240 2>/dev/null | grep -q .; then
          continue
        fi
        if [ "$dry_run" -eq 1 ]; then
          local size; size=$(dir_size_mb "$wt_path")
          log "autoclean: would remove $wt_path (${size}MB)"
          candidates=$((candidates + 1)); total_mb=$((total_mb + size))
          continue
        fi
        local rc=0
        rm -rf "$wt_path" 2>/dev/null || rc=$?
        if [ "$rc" -ne 0 ]; then
          log "autoclean: rm -rf $wt_path failed (exit $rc)"
          continue
        fi
        removed=$((removed + 1))
      done < <(find "$wt_base" -maxdepth 1 -type d -name 'task-archon-*' 2>/dev/null)
    done

    if [ "$removed" -gt 0 ]; then
      git -C "$repo_dir" worktree prune --expire now 2>/dev/null \
        || log "autoclean: git worktree prune failed for $project (exit $?)"
      log "autoclean: pruned $removed stale worktrees for $project"
    fi
  done
  [ "$dry_run" -eq 1 ] && log "autoclean: dry run — $candidates stale worktrees, ${total_mb}MB total"
  # ARCHON_RUN_AS=archon: new worktrees are the factory user's (its home, its
  # clones), which asiri can neither delete nor should run git in. The same
  # rule runs there as archon (archon-as-archon worktree-trim); the loop above
  # still clears what asiri's own runs left behind.
  if runas_archon; then
    local out trim_args=()
    [ "$dry_run" -eq 1 ] && trim_args=(--dry-run)
    if out=$(runas_wrapper worktree-trim "${trim_args[@]}" 2>&1); then
      [ -n "$out" ] && printf '%s\n' "$out" | while IFS= read -r l; do log "[archon] $l"; done
    else
      log "autoclean: archon worktree-trim failed: $(tail -n 1 <<<"$out")"
    fi
  fi
  return 0
}

# Remove stale build/test artifacts from the tmp root ($PIPELINE_HEALTH_TMP_ROOT,
# default /tmp). Two rules:
#   1. Known artifact names (patterns below) older than 1 day, files or dirs.
#   2. Any top-level *directory* owned by this user that nothing has written to
#      for 3 days, except session/runtime dirs (claude-*, tmux-*, ssh-*,
#      pulse-*, dbus-*, systemd-*, snap-*) and dotfiles. Agent sessions leave
#      venvs, JDK extracts, node tarballs and review checkouts behind under
#      arbitrary names — 300 of them held 6.6 GB by 2026-09.
# Rule 2 never removes a regular file: the per-tick state files
# (/tmp/.archon-active-runs.*, /tmp/.pr-review-fire.*) live here, and so did
# the cron logs until they moved to ~/.local/state/archon-cron/logs.
autoclean_tmp() {
  local tmp_root="${PIPELINE_HEALTH_TMP_ROOT:-/tmp}"
  [ -n "$tmp_root" ] && [ -d "$tmp_root" ] || return 0
  local patterns=(
    "flutter-sdk"
    "flutter_tools.*"
    "*-bd-tests-*"
    "bd-testbin-*"
    "bd-init-test-*"
    "bd-embedded-init-test-*"
    "go-build*"
    "*-venv"
    "pip-unpack-*"
    "litertlm-*.aar"
    "litert-*.aar"
    "llama-cpp.tar.gz"
    "llama-cpp"
  )
  local total=0 removed=0 f sz rc
  for pat in "${patterns[@]}"; do
    while IFS= read -r f; do
      sz=$(du -sb "$f" 2>/dev/null | cut -f1); sz="${sz:-0}"
      rc=0; rm -rf "$f" 2>/dev/null || rc=$?
      if [ "$rc" -ne 0 ]; then
        log "autoclean: rm -rf $f failed (exit $rc)"
        continue
      fi
      total=$((total + sz)); removed=$((removed + 1))
    done < <(find "$tmp_root" -mindepth 1 -maxdepth 1 -name "$pat" -mtime +1 2>/dev/null)
  done

  local me; me=$(id -un)
  while IFS= read -r f; do
    case "$(basename "$f")" in
      .*|claude-*|tmux-*|ssh-*|pulse-*|dbus-*|systemd-*|snap-*) continue ;;
    esac
    sz=$(du -sb "$f" 2>/dev/null | cut -f1); sz="${sz:-0}"
    rc=0; rm -rf "$f" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      log "autoclean: rm -rf $f failed (exit $rc)"
      continue
    fi
    total=$((total + sz)); removed=$((removed + 1))
  done < <(find "$tmp_root" -mindepth 1 -maxdepth 1 -type d -user "$me" -mmin +4320 2>/dev/null)

  [ "$removed" -gt 0 ] && log "autoclean: removed $removed stale entries from $tmp_root — freed $((total / 1048576))MB"
  return 0
}

check_disk() {
  for mount in / /mnt/ext-fast; do
    local used
    used=$(disk_used_pct "$mount")
    [ -n "$used" ] || continue
    [ "$used" -ge 85 ] || continue

    # The caches autoclean_root clears live under $HOME on /; the only
    # autoclean target on /mnt/ext-fast is the worktrees.
    local clean_fn clean_verb clean_body
    if [ "$mount" = "/" ]; then
      clean_fn=autoclean_root
      clean_verb="running conservative autoclean"
      clean_body="Autoclean ran (go/bun/npm/uv/pip caches, journal vacuum, idle Gradle caches, old APKs, stale worktrees and /tmp dirs) but disk still >=85%. See $LOG_DIR/pipeline-health.log for per-step results."
    else
      clean_fn=autoclean_stale_worktrees
      clean_verb="removing stale worktrees"
      clean_body="Stale archon worktrees were removed but disk still >=85%. Pipeline will stall if this fills. See $LOG_DIR/pipeline-health.log."
    fi

    local before="$used"
    log "disk $mount at ${before}% — $clean_verb before ntfy"
    "$clean_fn"
    local after
    after=$(disk_used_pct "$mount")
    [ -n "$after" ] || after="$before"
    log "disk $mount ${before}% → ${after}% after cleanup"
    if [ "$after" -ge 85 ]; then
      log "disk $mount still at ${after}% after cleanup — ntfying"
      notify "Disk warning: $mount ${after}% (was ${before}%)" "$clean_body" high warning
    else
      log "disk $mount recovered (${before}% → ${after}%) — no ntfy"
    fi
  done
}

# ----------------------------------------------------------------------------
# Check 4: Progress detection.
#   Signal = commits to origin/main across repos + archon log completions since
#   the last health tick. If zero: look for token-limit markers first (expected,
#   transient). If none, fire archon-assist to diagnose (cooldown: 2h).
# ----------------------------------------------------------------------------
check_progress() {
  local progress_marker="$STATE_DIR/last-progress-ts"
  local now; now=$(date +%s)
  local last_ts=0
  [ -f "$progress_marker" ] && last_ts=$(cat "$progress_marker" 2>/dev/null || echo 0)
  echo "$now" > "$progress_marker"

  # First run after install — baseline only
  [ "$last_ts" -eq 0 ] && { log "progress baseline set, skipping first check"; return; }

  local since_iso
  since_iso=$(date -u -d "@$last_ts" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
  [ -n "$since_iso" ] || return

  local commits=0 completions=0
  for project in "${REPOS[@]}"; do
    local n
    n=$(gh api "repos/alexsiri7/$project/commits?sha=main&since=$since_iso" \
        --jq 'length' 2>/dev/null || echo 0)
    commits=$((commits + n))

    local logdir="$BASE_DIR/$project/.archon-logs"
    [ -d "$logdir" ] || continue
    local m
    m=$(find "$logdir" -name "*.log" -newermt "@$last_ts" \
          -exec grep -l 'dag_workflow_finished' {} \; 2>/dev/null | wc -l)
    completions=$((completions + m))
  done

  log "progress: $commits commits on main, $completions archon completions since last tick"
  [ $((commits + completions)) -gt 0 ] && return

  # No progress is only a stall if there was work to make progress on.
  # An empty backlog (no archon:queued/in-progress issues, no open PR that
  # pr-maintenance would act on) is idle, not stuck — firing the diagnostic
  # there burns an archon-assist run every 2h for nothing.
  # An item created after the last tick had no window to progress in, so it
  # is not evidence of a stall either. The prod-deploy check files
  # archon:queued issues earlier in this same tick; counting those fired the
  # diagnostic at a seconds-old issue (reli#1512, 2026-09-16).
  local pending=0
  for project in "${REPOS[@]}"; do
    local n
    # Trusted items only: the factory never works an untrusted one, so counting
    # it would read as a permanent stall and fire the diagnostic every 2h at it.
    n=$(gh issue list --repo "alexsiri7/$project" --state open --limit 100 \
          --json number,labels,createdAt,author,title,body 2>/dev/null \
        | TRUST_QUIET=1 trust_filter_issues "$project" \
        | jq --arg since "$since_iso" '[.[] | select(.createdAt < $since) | select(.labels | map(.name) | any(. == "archon:queued" or . == "archon:in-progress" or . == "archon:triage-in-progress"))] | length' \
          2>/dev/null || echo 0)
    pending=$((pending + ${n:-0}))
    n=$(gh pr list --repo "alexsiri7/$project" --state open --json number,isDraft,mergeStateStatus,createdAt,author,isCrossRepository 2>/dev/null \
        | trust_filter_prs "$project" full \
        | jq --arg since "$since_iso" '[.[] | select(.createdAt < $since) | select(.isDraft == false and (.mergeStateStatus == "CLEAN" or .mergeStateStatus == "BEHIND" or .mergeStateStatus == "DIRTY" or .mergeStateStatus == "UNSTABLE" or .mergeStateStatus == "UNKNOWN"))] | length' \
          2>/dev/null || echo 0)
    pending=$((pending + ${n:-0}))
  done
  if [ "$pending" -eq 0 ]; then
    log "no progress, but no queued issues or actionable PRs — idle, not stalled"
    return
  fi
  log "no progress with $pending pending item(s) — checking for token-limit markers"

  # No progress — check for token-limit markers
  local token_hint=0
  for project in "${REPOS[@]}"; do
    local logdir="$BASE_DIR/$project/.archon-logs"
    [ -d "$logdir" ] || continue
    if find "$logdir" -name "*.log" -newermt "@$last_ts" 2>/dev/null \
         -exec grep -liE 'rate.?limit|rate_limit| 429 |http.?429|quota.?exceed|overloaded|usage.?limit|credit.?exhaust' {} \; \
         2>/dev/null | head -1 | grep -q .; then
      token_hint=1; break
    fi
  done

  if [ "$token_hint" = "1" ]; then
    log "no progress but token-limit markers found — likely quota, retrying next tick"
    return
  fi

  # Cooldown: only fire diagnostic if we haven't in the last 2h
  local stall_marker="$STATE_DIR/last-stall-diagnostic-ts"
  local last_stall=0
  [ -f "$stall_marker" ] && last_stall=$(cat "$stall_marker" 2>/dev/null || echo 0)
  if [ $((now - last_stall)) -lt 7200 ]; then
    log "no progress, but diagnostic fired <2h ago — skipping"
    return
  fi

  log "no progress, no token hints — firing archon-assist diagnostic"
  echo "$now" > "$stall_marker"

  local logf="$LOG_DIR/pipeline-health-diagnostic-$(date +%Y%m%d-%H%M%S).log"
  # Under ARCHON_RUN_AS=archon the factory user may only run in a factory
  # project (the engine checkout is read-only to it): use the ops repo's clone.
  local diag_dir="$BASE_DIR/archon"
  runas_archon && diag_dir="$BASE_DIR/interstellarai.net"
  (
    cd "$diag_dir"
    CLAUDECODE=0 nohup archon workflow run archon-assist \
      "Pipeline-health-cron detected no progress across repos ${REPOS[*]} in the last 30 minutes. No commits landed on origin/main, no archon workflows completed, and no token-limit markers were found in recent .archon-logs. Investigate: check 'gh run list' per repo, 'archon workflow status', recent logs in $LOG_DIR/pr-maintenance.log and $LOG_DIR/issue-pickup.log, and take action to unblock whatever is stuck." \
      > "$logf" 2>&1 &
    disown
  )
  # No ntfy — archon-assist has been fired and will diagnose; if nothing
  # improves on the next tick, we'll fire it again (2h cooldown).
}

# ----------------------------------------------------------------------------
# Check 5: Retry CI on open archon PRs with failed checks.
#   Ported from archon/scripts/poll-health.sh (check 1). For each open PR on
#   an `archon/` branch whose statusCheckRollup contains a FAILURE, fire
#   archon-assist to diagnose + push a fix. Dedup by PR number; cleared when
#   the PR is no longer in the failed-CI list (merged, closed, or recovered).
# ----------------------------------------------------------------------------
check_pr_ci_retry() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  [ -d "$repo_dir/.git" ] || return

  # Collect current set of archon PRs with FAILURE in rollup.
  # Includes headRefOid so we can scope attempts to the PR's current head SHA.
  local failed_prs
  failed_prs=$(gh pr list --repo "alexsiri7/$project" --state open \
    --json number,title,headRefName,headRefOid,statusCheckRollup,author,isCrossRepository,labels 2>/dev/null \
    | trust_filter_prs "$project" full \
    | jq -r --arg held "$TRUST_HELD_LABEL" '.[] | select(.headRefName | startswith("archon/"))
        | select((.labels // []) | map(.name) | (index("hold") or index($held)) | not)
        | select(.statusCheckRollup | length > 0)
        | select(.statusCheckRollup | map(select((.name // .context) | IN("unsafe-change", "safe-change") | not) | .conclusion // "PENDING") | any(. == "FAILURE"))
        | [(.number|tostring), .headRefOid, .title] | @tsv' \
    2>/dev/null || echo "")

  # Clear markers for PRs no longer failing (merged, closed, or recovered).
  local current_nums=""
  if [ -n "$failed_prs" ]; then
    current_nums=$(echo "$failed_prs" | awk -F'\t' '{print $1}' | sort -u)
  fi
  local prefix="$project-pr"
  while IFS= read -r marker; do
    [ -z "$marker" ] && continue
    local mbase mnum
    mbase=$(basename "$marker")
    mnum="${mbase#$prefix}"
    if [ -z "$current_nums" ] || ! echo "$current_nums" | grep -qx "$mnum"; then
      rm -f "$marker"
    fi
  done < <(find "$STATE_DIR/prciretry" -maxdepth 1 -name "$project-pr*" 2>/dev/null)
  # Also clear any stale "escalated" ntfy-dedup markers for PRs that recovered.
  while IFS= read -r marker; do
    [ -z "$marker" ] && continue
    local mbase prnum
    mbase=$(basename "$marker")
    # <project>-pr<N>-<sha> → extract N
    prnum="${mbase#$project-pr}"
    prnum="${prnum%%-*}"
    if [ -z "$current_nums" ] || ! echo "$current_nums" | grep -qx "$prnum"; then
      rm -f "$marker"
    fi
  done < <(find "$STATE_DIR/escalated" -maxdepth 1 -name "$project-pr*" 2>/dev/null)
  # Legacy single-file markers from earlier versions of this script.
  find "$STATE_DIR" -maxdepth 1 -name "prciretry-$project-pr*" -delete 2>/dev/null || true

  [ -n "$failed_prs" ] || return

  while IFS=$'\t' read -r pr_num pr_sha pr_title; do
    [ -n "$pr_num" ] || continue
    [ -n "$pr_sha" ] || continue

    # Before sha_attempt_decide, so a PR held back here spends no attempt.
    if ! trust_comments_ok "$project" pr "$pr_num"; then
      log "$project: PR #$pr_num CI red but has untrusted comments or reviews — not firing archon-assist"
      continue
    fi
    local marker="$STATE_DIR/prciretry/$project-pr$pr_num"
    local decision action attempts
    decision=$(sha_attempt_decide "$marker" "$STATE_DIR/escalated" \
      "$project-pr$pr_num" "$pr_sha")
    action="${decision%% *}"
    attempts="${decision##* }"

    case "$action" in
      SKIP)
        log "$project: PR #$pr_num CI red at ${pr_sha:0:10} — already at MAX_ATTEMPTS=$MAX_ATTEMPTS, backed off"
        continue
        ;;
      SKIP_NTFY)
        log "$project: PR #$pr_num CI red at ${pr_sha:0:10} — MAX_ATTEMPTS=$MAX_ATTEMPTS reached, ntfying operator"
        notify "factory stuck: $project PR #$pr_num CI red" \
          "PR #$pr_num CI red at ${pr_sha:0:10} after $MAX_ATTEMPTS attempts" \
          high warning
        file_stuck_issue "alexsiri7/$project" "pr-ci" "$pr_sha" \
          "$project PR #$pr_num CI red" \
          "https://github.com/alexsiri7/$project/pull/$pr_num" \
          "$MAX_ATTEMPTS" \
          "$repo_dir/.archon-logs/"
        continue
        ;;
    esac

    log "$project: PR #$pr_num CI red at ${pr_sha:0:10} — firing archon-assist (attempt $attempts/$MAX_ATTEMPTS)"

    mkdir -p "$repo_dir/.archon-logs"
    local logf="$repo_dir/.archon-logs/health-pr-ci-fix-pr${pr_num}-$(date +%Y%m%d-%H%M%S).log"
    (
      cd "$repo_dir"
      CLAUDECODE=0 nohup archon workflow run archon-assist \
        "PR #$pr_num has failing CI checks. Check out the branch, look at the CI failure logs with 'gh pr checks $pr_num' and 'gh run view', diagnose the failure, fix it, commit, and push. The PR title is: $pr_title" \
        > "$logf" 2>&1 &
      disown
    )
  done <<< "$failed_prs"
}

# ----------------------------------------------------------------------------
# Check 5b: Stuck archon PRs — open, CI-clean (not caught by check_pr_ci_retry),
#   but not merged/updated for 2+ hours. Fires archon-pr-maintenance to unblock.
#   Covers cases where pr-maintenance-cron has a gap (e.g. draft+conflicting were
#   invisible until that script was fixed). Dedup by (project, PR#, head SHA).
# ----------------------------------------------------------------------------
check_stuck_prs() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  [ -d "$repo_dir/.git" ] || return

  local now_epoch; now_epoch=$(date +%s)
  local stale_secs=7200  # 2 hours

  # ISO cutoff: any PR last updated before this is considered stuck.
  local cutoff_iso
  cutoff_iso=$(date -u -d "@$((now_epoch - stale_secs))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
  [ -n "$cutoff_iso" ] || return

  # Open archon PRs that:
  #   - are not drafts (drafts handled by pr-maintenance-cron Phase 0)
  #   - are not CLEAN (would be merged by Phase 1)
  #   - are not BLOCKED (CI failing, caught by check_pr_ci_retry)
  #   - haven't been updated in >2h
  # gh's --jq takes no --arg, so the cutoff goes to a standalone jq. A failed
  # listing is logged, never read as "no stuck PRs": that would switch the
  # check off silently, tick after tick.
  local open_prs stuck_prs
  if ! open_prs=$(gh pr list --repo "alexsiri7/$project" --state open \
      --json number,title,headRefName,headRefOid,isDraft,updatedAt,mergeStateStatus 2>/dev/null) \
    || ! stuck_prs=$(jq -r --arg cutoff "$cutoff_iso" \
    '[.[] | select(.headRefName | startswith("archon/"))
          | select(.isDraft == false)
          | select(.mergeStateStatus != "CLEAN")
          | select(.mergeStateStatus != "BLOCKED")
          | select(.updatedAt < $cutoff)
          | [(.number|tostring), .headRefOid, .mergeStateStatus, .title]
          | @tsv] | .[]' <<< "$open_prs" 2>/dev/null); then
    log "$project: stuck-PR listing failed — skipping"
    return
  fi

  [ -n "$stuck_prs" ] || return

  mkdir -p "$STATE_DIR/stuck-pr"

  while IFS=$'\t' read -r pr_num pr_sha merge_state pr_title; do
    [ -n "$pr_num" ] || continue
    [ -n "$pr_sha" ] || continue

    # Before sha_attempt_decide, so a PR held back here spends no attempt.
    local pr_who
    pr_who=$(gh pr view "$pr_num" --repo "alexsiri7/$project" --json number,author,isCrossRepository 2>/dev/null \
      | jq -c '[.]' 2>/dev/null | trust_filter_prs "$project" full | jq 'length' 2>/dev/null || echo 0)
    if [ "${pr_who:-0}" != "1" ]; then
      log "$project: PR #$pr_num stuck but its author is not trusted for archon — skipping"
      continue
    fi
    if ! trust_comments_ok "$project" pr "$pr_num"; then
      log "$project: PR #$pr_num stuck but has untrusted comments or reviews — not firing archon-pr-maintenance"
      continue
    fi
    local marker="$STATE_DIR/stuck-pr/$project-pr$pr_num"
    local decision action attempts
    decision=$(sha_attempt_decide "$marker" "$STATE_DIR/escalated" \
      "stuck-$project-pr$pr_num" "$pr_sha")
    action="${decision%% *}"
    attempts="${decision##* }"

    case "$action" in
      SKIP)
        log "$project: PR #$pr_num stuck ($merge_state) at ${pr_sha:0:10} — MAX_ATTEMPTS reached, backed off"
        continue
        ;;
      SKIP_NTFY)
        log "$project: PR #$pr_num stuck ($merge_state) at ${pr_sha:0:10} — MAX_ATTEMPTS=$MAX_ATTEMPTS exhausted, ntfying"
        notify "factory stuck: $project PR #$pr_num ($merge_state)" \
          "PR #$pr_num open >2h, mergeState=$merge_state, pr-maintenance not making progress" \
          high warning
        file_stuck_issue "alexsiri7/$project" "stuck-pr" "$pr_sha" \
          "$project PR #$pr_num stuck ($merge_state)" \
          "https://github.com/alexsiri7/$project/pull/$pr_num" \
          "$MAX_ATTEMPTS" \
          "$repo_dir/.archon-logs/"
        continue
        ;;
    esac

    log "$project: PR #$pr_num stuck ($merge_state) at ${pr_sha:0:10} — firing archon-pr-maintenance (attempt $attempts/$MAX_ATTEMPTS)"

    mkdir -p "$repo_dir/.archon-logs"
    local logf="$repo_dir/.archon-logs/health-stuck-pr${pr_num}-$(date +%Y%m%d-%H%M%S).log"
    (
      cd "$repo_dir"
      CLAUDECODE=0 nohup archon workflow run archon-pr-maintenance \
        "PR #$pr_num" \
        > "$logf" 2>&1 &
      disown
    )
    log "$project: archon-pr-maintenance fired for PR #$pr_num (log $logf)"
  done <<< "$stuck_prs"
}

# ----------------------------------------------------------------------------
# Check 6: Prod deploy HTTP health.
#   Ported from archon/scripts/poll-health.sh (check 3). For each project with
#   a DEPLOY_URLS entry, GET the URL (body discarded); if HTTP status is <200
#   or >=400, file a `bug` issue (queued for the normal pickup cron). Dedup per
#   project; marker is cleared once the deploy recovers.
# ----------------------------------------------------------------------------
check_deploy_http() {
  local project="$1"
  local deploy_url="${DEPLOY_URLS[$project]:-}"
  [ -n "$deploy_url" ] || return 0  # No public URL configured — skip

  # Probe up to 3 times (30s apart) before declaring the deploy down.
  # This avoids filing spurious issues for transient connection failures.
  local http_code attempt
  for attempt in 1 2 3; do
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$deploy_url" 2>/dev/null)
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
      break
    fi
    [ "$attempt" -lt 3 ] && sleep 30
  done

  local marker="$STATE_DIR/deploy-down-$project"
  local suspect="$STATE_DIR/deploy-suspect-$project"
  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 400 ]; then
    if [ -f "$marker" ]; then
      log "$project: deploy still down (HTTP $http_code at $deploy_url) — issue already filed, skipping"
      return
    fi

    # File only on the second consecutive down tick. The 3x30s probe above
    # covers ~90s, but a Railway container restart can refuse connections for
    # ~4 minutes; reli's nightly restart at 03:01 UTC produced 26 identical
    # "HTTP 000" issues (reli #1153 … #1402), each costing an archon-ship run
    # that found the site up. One tick of confirmation (30 min) is the
    # cheapest window that outlasts a restart without blocking this cron.
    if [ ! -f "$suspect" ]; then
      touch "$suspect"
      log "$project: deploy down (HTTP $http_code at $deploy_url) — first sighting, confirming next tick before filing"
      return
    fi
    rm -f "$suspect"

    log "$project: deploy down (HTTP $http_code at $deploy_url) — down two consecutive ticks, filing issue"
    touch "$marker"

    local body
    body=$(cat <<EOF
## Deploy health check failure

**URL**: $deploy_url
**HTTP status**: $http_code
**Detected**: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

The production deployment is not responding correctly. Check the hosting
dashboard (Railway / Cloudflare Pages / etc.) and recent deployments for errors.
EOF
)
    gh issue create --repo "alexsiri7/$project" \
      --title "Deploy down: $deploy_url returning HTTP $http_code" \
      --label "bug" \
      --body "$body" >/dev/null 2>&1 \
      || log "$project: WARNING: gh issue create failed (rate limit / auth / network?)"
    return
  fi

  # Healthy — clear markers
  rm -f "$marker" "$suspect"
  log "$project: deploy OK (HTTP $http_code at $deploy_url)"
}

# ----------------------------------------------------------------------------
# Check 6b: Staging deploy HTTP health.
#   Same as check_deploy_http but for STAGING_DEPLOY_URLS. Failures are logged
#   and ntfy'd but do NOT file issues — staging outages are informational, not
#   pipeline-blocking. Dedup per project in staging-health/ subdirectory.
# ----------------------------------------------------------------------------
check_staging_deploy_http() {
  local project="$1"
  local staging_url="${STAGING_DEPLOY_URLS[$project]:-}"
  [ -n "$staging_url" ] || return  # No staging URL configured — skip

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$staging_url" 2>/dev/null)

  local marker="$STATE_DIR/staging-health/deploy-down-$project"
  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 400 ]; then
    if [ -f "$marker" ]; then
      log "$project: staging deploy still down (HTTP $http_code at $staging_url) — already notified, skipping"
      return
    fi

    log "$project: staging deploy down (HTTP $http_code at $staging_url) — notifying"
    touch "$marker"

    notify "Staging down: $project" \
      "Staging deploy at $staging_url returning HTTP $http_code" \
      default warning
    return
  fi

  # Healthy — clear marker
  rm -f "$marker"
  log "$project: staging deploy OK (HTTP $http_code at $staging_url)"
}

# ----------------------------------------------------------------------------
# Check 7: Shipped-PR ntfy — announce PRs merged in the last 24h.
#   Ported from archon/scripts/poll-health.sh (check 4). Only fires when the
#   deploy URL is configured AND currently healthy (we assume merged code is
#   live). For each merged PR, pulls linked issue numbers from the body and
#   emits "Shipped: <repo> #<issue>" for each. Dedup per-PR.
#   Projects without a DEPLOY_URLS entry are skipped (no live signal).
# ----------------------------------------------------------------------------
check_shipped_prs() {
  local project="$1"
  local deploy_url="${DEPLOY_URLS[$project]:-}"
  [ -n "$deploy_url" ] || return

  # Only announce if deploy is currently healthy — avoid claiming "shipped"
  # when prod is actually down. check_deploy_http already logged status.
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$deploy_url" 2>/dev/null)
  [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ] || return

  local merged
  merged=$(gh pr list --repo "alexsiri7/$project" --state merged \
    --json number,title,mergedAt,body \
    --jq "[.[] | select((.mergedAt | fromdateiso8601) > (now - 86400))]" \
    2>/dev/null || echo "[]")

  echo "$merged" | jq -c '.[]' 2>/dev/null | while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    local pr_num pr_title pr_body
    pr_num=$(echo "$pr" | jq -r '.number')
    pr_title=$(echo "$pr" | jq -r '.title')
    pr_body=$(echo "$pr" | jq -r '.body // ""')

    local marker="$STATE_DIR/shipped-$project-pr$pr_num"
    [ -f "$marker" ] && continue

    # Extract "Fixes/Closes/Resolves #N" issue references from the PR body
    local issue_nums
    issue_nums=$(echo "$pr_body" \
      | grep -oiE '(fix(es)?|close[sd]?|resolve[sd]?) #[0-9]+' \
      | grep -oE '[0-9]+' || true)

    if [ -n "$issue_nums" ]; then
      for issue_num in $issue_nums; do
        local issue_title
        issue_title=$(gh issue view "$issue_num" --repo "alexsiri7/$project" \
          --json title -q '.title' 2>/dev/null || echo "")
        notify "Shipped: $project #$issue_num" \
          "$issue_title — deployed to prod via PR #$pr_num" \
          default rocket
        log "$project: shipped-ntfy for issue #$issue_num via PR #$pr_num"
      done
    else
      notify "Shipped: $project PR #$pr_num" \
        "$pr_title — deployed to prod" \
        default rocket
      log "$project: shipped-ntfy for PR #$pr_num (no linked issue)"
    fi

    touch "$marker"
  done
}

# ----------------------------------------------------------------------------
# Check 8: Sweep stale `archon:in-progress` labels off closed issues.
#   archon's fix workflow closes issues via "Fixes #N" on a merged PR, but
#   GitHub doesn't auto-update the label, and the workflow doesn't always
#   bother either — leaving closed issues stuck with `archon:in-progress`.
#   Low-frequency, cheap, idempotent — safe to run every tick.
# ----------------------------------------------------------------------------
sweep_stale_labels() {
  local project="$1"
  local stale_nums
  stale_nums=$(gh issue list --repo "alexsiri7/$project" --state closed \
    --label "archon:in-progress" --limit 100 \
    --json number --jq '.[].number' 2>/dev/null || echo "")
  [ -n "$stale_nums" ] || return

  local count=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if gh issue edit "$n" --repo "alexsiri7/$project" \
         --remove-label "archon:in-progress" \
         --add-label "archon:done" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done <<< "$stale_nums"

  if [ "$count" -gt 0 ]; then
    log "$project: swept $count stale archon:in-progress label(s) → archon:done on closed issues"
  fi
}

# ----------------------------------------------------------------------------
# Check 9: DB backup freshness. backup-dbs.sh (cron, every 3h) writes
#   $STATE_DIR/db-backup-status with last_ok=<epoch of the last run in which
#   every configured project produced a verified archive>. A failed run ntfys
#   on its own; this check catches the quieter failures — the script not
#   running at all, crashing before it logs, or failing repeatedly — by
#   alerting once when no verified backup landed within DB_BACKUP_MAX_AGE_H
#   hours (default 7: two missed 3-hourly runs).
# ----------------------------------------------------------------------------
check_db_backup() {
  local status_file="$STATE_DIR/db-backup-status"
  local marker="$STATE_DIR/db-backup-alerted"
  local max_age_h="${DB_BACKUP_MAX_AGE_H:-7}"
  local max_age=$(( max_age_h * 3600 ))
  local now last_ok=0 last_status="" last_failed="" problem=""
  now=$(date +%s)

  if [ -f "$status_file" ]; then
    last_ok=$(grep -s '^last_ok=' "$status_file" | cut -d= -f2)
    last_status=$(grep -s '^last_run_status=' "$status_file" | cut -d= -f2)
    last_failed=$(grep -s '^last_run_failed=' "$status_file" | cut -d= -f2)
    [[ "$last_ok" =~ ^[0-9]+$ ]] || last_ok=0
  fi

  if [ "$last_ok" -eq 0 ]; then
    problem="no successful DB backup recorded ($status_file missing or never ok)"
  elif [ $(( now - last_ok )) -gt "$max_age" ]; then
    problem="last verified DB backup $(( (now - last_ok) / 3600 ))h ago (limit ${max_age_h}h)"
    [ -n "$last_status" ] && problem="$problem; last run: $last_status${last_failed:+ ($last_failed)}"
  fi

  if [ -z "$problem" ]; then
    if [ -f "$marker" ]; then
      rm -f "$marker"
      log "db-backup: recovered — verified backup landed"
    fi
    return 0
  fi

  log "db-backup: $problem"
  [ -f "$marker" ] && return 0   # alert once per stale episode
  notify "DB backups stale" \
    "$problem. Check $LOG_DIR/db-backup.log and run ops/cron/backup-dbs.sh by hand." \
    high floppy_disk
  touch "$marker"
}

# ----------------------------------------------------------------------------
# Check 9b: weekly system maintenance. system-maintenance.sh (cron, Sundays
#   04:00) writes $STATE_DIR/system-maintenance-status in the db-backup-status
#   shape. It ntfys its own failures; this catches the run that never happened
#   (crontab not installed, script crashing before it logs) and the failure
#   whose ntfy did not get through: alert once when the last run reports
#   `failed`, or when no successful run landed within
#   SYSTEM_MAINTENANCE_MAX_AGE_D days (default 8: one missed weekly run).
# ----------------------------------------------------------------------------
check_system_maintenance() {
  local status_file="$STATE_DIR/system-maintenance-status"
  local marker="$STATE_DIR/system-maintenance-alerted"
  local max_age_d="${SYSTEM_MAINTENANCE_MAX_AGE_D:-8}"
  local max_age=$(( max_age_d * 86400 ))
  local now last_ok=0 last_run=0 last_status="" last_failed="" problem=""
  now=$(date +%s)

  if [ -f "$status_file" ]; then
    last_ok=$(grep -s '^last_ok=' "$status_file" | cut -d= -f2)
    last_run=$(grep -s '^last_run=' "$status_file" | cut -d= -f2)
    last_status=$(grep -s '^last_run_status=' "$status_file" | cut -d= -f2)
    last_failed=$(grep -s '^last_run_failed=' "$status_file" | cut -d= -f2)
    [[ "$last_ok" =~ ^[0-9]+$ ]] || last_ok=0
    [[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
  fi

  if [ "$last_status" = "failed" ]; then
    problem="last system-maintenance run failed${last_failed:+ ($last_failed)}, $(( (now - last_run) / 3600 ))h ago"
  elif [ "$last_ok" -eq 0 ]; then
    problem="no successful system-maintenance run recorded ($status_file missing or never ok)"
  elif [ $(( now - last_ok )) -gt "$max_age" ]; then
    problem="last successful system-maintenance run $(( (now - last_ok) / 86400 ))d ago (limit ${max_age_d}d)"
  fi

  if [ -z "$problem" ]; then
    if [ -f "$marker" ]; then
      rm -f "$marker"
      log "system-maintenance: recovered — successful run landed"
    fi
    return 0
  fi

  log "system-maintenance: $problem"
  [ -f "$marker" ] && return 0   # alert once per episode
  notify "System maintenance stale" \
    "$problem. Check $LOG_DIR/system-maintenance.log; run ops/cron/system-maintenance.sh by hand, or sudo ops/host/install.sh if sudo -n is refused." \
    high wrench
  touch "$marker"
}

# ----------------------------------------------------------------------------
# Check 9d: weekly Archon engine update. archon-update.sh (cron, Sundays
#   03:00) writes $STATE_DIR/archon-update-status in the system-maintenance
#   shape plus outcome=noop|deferred|updated|failed. It ntfys its own failures
#   and successful updates; this catches the run that never happened and the
#   update that keeps being deferred behind live runs (a deferred run leaves
#   last_ok alone): alert once when the last run reports `failed`, or when no
#   ok run (a no-op counts) landed within ARCHON_UPDATE_MAX_AGE_D days
#   (default 8: one missed weekly run).
# ----------------------------------------------------------------------------
check_archon_update() {
  local status_file="$STATE_DIR/archon-update-status"
  local marker="$STATE_DIR/archon-update-alerted"
  local max_age_d="${ARCHON_UPDATE_MAX_AGE_D:-8}"
  local max_age=$(( max_age_d * 86400 ))
  local now last_ok=0 last_run=0 last_status="" last_failed="" latest="" problem=""
  now=$(date +%s)

  if [ -f "$status_file" ]; then
    last_ok=$(grep -s '^last_ok=' "$status_file" | cut -d= -f2)
    last_run=$(grep -s '^last_run=' "$status_file" | cut -d= -f2)
    last_status=$(grep -s '^last_run_status=' "$status_file" | cut -d= -f2)
    last_failed=$(grep -s '^last_run_failed=' "$status_file" | cut -d= -f2)
    latest=$(grep -s '^latest=' "$status_file" | cut -d= -f2)
    [[ "$last_ok" =~ ^[0-9]+$ ]] || last_ok=0
    [[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
  fi

  if [ "$last_status" = "failed" ]; then
    problem="last archon-update run failed${last_failed:+ ($last_failed)}${latest:+ bringing in $latest}, $(( (now - last_run) / 3600 ))h ago"
  elif [ "$last_ok" -eq 0 ]; then
    problem="no successful archon-update run recorded ($status_file missing or never ok)"
  elif [ $(( now - last_ok )) -gt "$max_age" ]; then
    problem="last successful archon-update run $(( (now - last_ok) / 86400 ))d ago (limit ${max_age_d}d)"
  fi

  if [ -z "$problem" ]; then
    if [ -f "$marker" ]; then
      rm -f "$marker"
      log "archon-update: recovered — successful run landed"
    fi
    return 0
  fi

  log "archon-update: $problem"
  [ -f "$marker" ] && return 0   # alert once per episode
  notify "Archon update stale or failed" \
    "$problem. Check $LOG_DIR/archon-update.log; run ops/cron/archon-update.sh by hand (runbook: ops/cron/README.md, 'Archon auto-update')." \
    high wrench
  touch "$marker"
}

# ----------------------------------------------------------------------------
# Check 9c: DB restore test. restore-test.sh (cron, Sunday 04:30) restores the
#   newest archive of every project into a throwaway cluster and writes
#   $STATE_DIR/restore-test-status (last_ok=<epoch of the last run in which
#   every configured project restored with the recorded row count>,
#   last_run_status=ok|failed). The script ntfys its own failures; this check
#   alerts once when the last run failed (a failed status stays failed for a
#   week, so the marker keeps it to one alert) or when no successful test
#   landed within RESTORE_TEST_MAX_AGE_D days (default 8: one missed week).
# ----------------------------------------------------------------------------
check_restore_test() {
  local status_file="$STATE_DIR/restore-test-status"
  local marker="$STATE_DIR/restore-test-alerted"
  local max_age_d="${RESTORE_TEST_MAX_AGE_D:-8}"
  local max_age=$(( max_age_d * 86400 ))
  local now last_ok=0 last_status="" last_failed="" problem=""
  now=$(date +%s)

  if [ -f "$status_file" ]; then
    last_ok=$(grep -s '^last_ok=' "$status_file" | cut -d= -f2)
    last_status=$(grep -s '^last_run_status=' "$status_file" | cut -d= -f2)
    last_failed=$(grep -s '^last_run_failed=' "$status_file" | cut -d= -f2)
    [[ "$last_ok" =~ ^[0-9]+$ ]] || last_ok=0
  fi

  if [ "$last_ok" -eq 0 ]; then
    problem="no successful DB restore test recorded ($status_file missing or never ok)"
    [ "$last_status" = "failed" ] && problem="$problem; last run failed${last_failed:+ ($last_failed)}"
  elif [ "$last_status" = "failed" ]; then
    problem="last DB restore test failed${last_failed:+ ($last_failed)}; last success $(( (now - last_ok) / 86400 ))d ago"
  elif [ $(( now - last_ok )) -gt "$max_age" ]; then
    problem="last successful DB restore test $(( (now - last_ok) / 86400 ))d ago (limit ${max_age_d}d)"
  fi

  if [ -z "$problem" ]; then
    if [ -f "$marker" ]; then
      rm -f "$marker"
      log "restore-test: recovered — newest backups restore cleanly"
    fi
    return 0
  fi

  log "restore-test: $problem"
  [ -f "$marker" ] && return 0   # alert once per episode
  notify "DB restore test stale or failed" \
    "$problem. Check $LOG_DIR/restore-test.log and run ops/cron/restore-test.sh by hand." \
    high floppy_disk
  touch "$marker"
}

# ----------------------------------------------------------------------------
# Check 9e: Claude account auth. The nightly sweep probes only the accounts it
#   reaches, so an expired token on the other one would sit unnoticed until its
#   slot; probe every CLAUDE_ACCOUNTS dir once a day (the first tick after
#   midnight) so it surfaces within a day. Alerting, the tracking issue and
#   recovery are lib/claude-auth.sh's.
# ----------------------------------------------------------------------------
check_claude_auth() {
  local stamp="$CLAUDE_AUTH_STATE_DIR/last-probe" today dir
  today=$(date +%F)
  [ "$(cat "$stamp" 2>/dev/null)" = "$today" ] && return 0
  mkdir -p "$CLAUDE_AUTH_STATE_DIR"
  local -a accounts
  IFS=':' read -ra accounts <<< "$(runas_claude_accounts)"
  for dir in "${accounts[@]}"; do
    claude_auth_check "$dir" && log "claude-auth: $dir ok"
  done
  echo "$today" > "$stamp"
}

# ----------------------------------------------------------------------------
# Check 10: Paused archon runs nothing will resume. reconcile_zombies reaps
# stale `running` rows and deliberately leaves `paused` ones to the server's
# continuation scheduler; this is the other half — the runs that scheduler has
# stopped answering for. A paused run still owns its worktree and freezes its
# PR and issue (pr_owned_by_live_run, unstick_stale), so when it drifts past
# the resume deadline it recorded for itself, one `workflow resume` is the
# cheapest way to find out whether the engine is still there. If that does not
# take, or the run is parked on something only a person can answer, ntfy once
# and leave it alone: approving a gate, or declaring the run dead so
# pr-maintenance merges under it, is a guess this cron does not get to make.
# ----------------------------------------------------------------------------
check_parked_runs() {
  local marker_dir="$STATE_DIR/parked"
  local run_id class wf origin msg deadline seen="" ack marker id overdue
  # A failed listing has no paused rows and would read as a quiet pipeline —
  # never let that delete markers or look like a recovery.
  if ! archon_runs_known; then
    log "parked-runs: no archon run snapshot this tick — skipping"
    return 0
  fi
  while IFS=$'\t' read -r run_id class wf origin msg deadline; do
    [ -n "$run_id" ] || continue
    seen="$seen $run_id"
    # `wait` and `resolved` are both the engine's own to resume, so a nudge is
    # the recovery; a `gate` is owed an answer cron must never give.
    if { [ "$class" = wait ] || [ "$class" = resolved ]; } && [ ! -e "$marker_dir/resumed-$run_id" ]; then
      overdue="no resume deadline recorded"
      [ "${deadline:-0}" -gt 0 ] && overdue="$(( $(date +%s) - deadline ))s past its recorded resume deadline"
      log "parked-runs: $wf $run_id parked ($class), $overdue — resuming"
      ack=$(CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 \
        archon workflow resume "$run_id" --detach --json --cwd "$ARCHON_RUNS_CWD" 2>&1 | tail -1)
      log "parked-runs: resume $run_id — $ack"
      touch "$marker_dir/resumed-$run_id"
      continue
    fi
    [ -e "$marker_dir/alerted-$run_id" ] && continue
    log "parked-runs: $wf $run_id parked ($class) with no automated recovery left — alerting"
    notify "Archon run parked: ${origin##*/}" \
      "$wf ($class) — ${msg:-no user message}
run $run_id
archon workflow get $run_id --json" \
      high hourglass
    touch "$marker_dir/alerted-$run_id"
  done < <(archon_parked_runs "$PARKED_WAIT_MAX_SECONDS")
  # A nudged run that healthily re-parks leaves this tick's parked set with a
  # fresh deadline; drop its markers so the next stall starts from a resume.
  for marker in "$marker_dir"/resumed-* "$marker_dir"/alerted-*; do
    [ -e "$marker" ] || continue
    id="${marker##*/}"
    id="${id#resumed-}"
    id="${id#alerted-}"
    case " $seen " in *" $id "*) continue ;; esac
    rm -f "$marker"
  done
}

# ----------------------------------------------------------------------------
if [ "$MODE" = trim ]; then
  run_trim
  exit 0
fi
if [ "$MODE" = list-worktrees ]; then
  autoclean_stale_worktrees --dry-run
  exit 0
fi

log "=== pipeline health check ==="
for project in "${REPOS[@]}"; do
  check_main_ci "$project"
  check_main_push_ci "$project"
  check_scheduled_workflows "$project"
  check_prod_deploy "$project"
  check_pr_ci_retry "$project"
  check_stuck_prs "$project"
  check_deploy_http "$project"
  check_staging_deploy_http "$project"
  check_shipped_prs "$project"
  sweep_stale_labels "$project"
done
reconcile_zombies
check_parked_runs
check_disk
check_db_backup
check_system_maintenance
check_archon_update
check_restore_test
check_claude_auth
check_progress
log "=== done ==="
