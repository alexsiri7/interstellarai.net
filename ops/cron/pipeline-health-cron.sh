#!/usr/bin/env bash
# pipeline-health-cron.sh — runs every 30 minutes from cron.
# Detects and responds to pipeline-bottleneck states:
#   1. Main CI red → file issue tagged archon:in-progress + fire archon immediately (dedup by SHA)
#   2. Prod deploy failed or lagging main HEAD → file issue + fire archon (dedup by SHA)
#   3. Zombie archon DB runs (status=running, age >4h) → abandon
#   4. Disk >85% on / or /mnt/ext-fast → ntfy
#   5. No pipeline progress in last tick (no commits, no archon completions):
#        - If token-limit markers in recent logs → wait, retry next tick
#        - Else → fire archon-assist diagnostic (dedup: 2h cooldown)
#
# Crontab:
#   */30 * * * * <repo>/ops/cron/pipeline-health-cron.sh >> /tmp/pipeline-health.log 2>&1

set -uo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
load_archon_projects REPOS
BASE_DIR="/mnt/ext-fast"
STATE_DIR="$HOME/.archon/pipeline-health-state"

# NTFY_TOPIC loaded from secrets.env. Fail loud if unset.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set — populate $SECRETS_FILE}"
LOG_PREFIX="[pipeline-health]"

mkdir -p "$STATE_DIR"

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

notify() {
  local title="$1" msg="$2" priority="${3:-default}" tags="${4:-robot}"
  curl -s -o /dev/null \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
    -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Check 1: Main CI red — file issue + fire archon immediately, dedup by SHA.
# ----------------------------------------------------------------------------
check_main_ci() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  [ -d "$repo_dir/.git" ] || return

  local latest
  latest=$(gh run list --repo "alexsiri7/$project" --branch main --limit 1 \
    --json databaseId,conclusion,headSha --jq '.[0] // empty' 2>/dev/null || echo "")
  [ -n "$latest" ] || return

  local conclusion sha run_id
  conclusion=$(echo "$latest" | jq -r '.conclusion // "pending"')
  sha=$(echo "$latest" | jq -r '.headSha')
  run_id=$(echo "$latest" | jq -r '.databaseId')

  if [ "$conclusion" = "success" ]; then
    # Green again — clear stale markers for this repo
    find "$STATE_DIR" -maxdepth 1 -name "main-ci-fired-$project-*" -delete 2>/dev/null || true
    return
  fi
  # Still running, cancelled, or pending — not actionable yet
  [ "$conclusion" = "failure" ] || return

  local marker="$STATE_DIR/main-ci-fired-$project-$sha"
  if [ -f "$marker" ]; then
    log "$project: main CI still red at $sha — archon already fired, skipping"
    return
  fi

  # Also skip if a human (or earlier tick) already filed an open "Main CI" issue
  # that is queued or in-progress. Avoids duplicating triage on SHA changes.
  local existing
  existing=$(gh issue list --repo "alexsiri7/$project" --state open \
    --search "Main CI in:title" --json number,labels \
    --jq '[.[] | select((.labels | map(.name)) as $l | ($l | index("archon:queued")) or ($l | index("archon:in-progress")))] | .[0].number // empty' \
    2>/dev/null || echo "")
  if [ -n "$existing" ]; then
    log "$project: main CI red, but open CI issue #$existing already queued/in-progress — marker set, skipping"
    touch "$marker"
    return
  fi

  local failed_jobs
  failed_jobs=$(gh run view "$run_id" --repo "alexsiri7/$project" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")' 2>/dev/null || echo "unknown")

  log "$project: main CI red ($failed_jobs) at $sha — filing issue + firing archon"

  local issue_body
  issue_body=$(cat <<EOF
## Main CI red

**Repo**: alexsiri7/$project
**SHA**: \`$sha\`
**Run**: https://github.com/alexsiri7/$project/actions/runs/$run_id
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

  touch "$marker"

  mkdir -p "$repo_dir/.archon-logs"
  local logf="$repo_dir/.archon-logs/health-ci-fix-${sha:0:8}-$(date +%Y%m%d-%H%M%S).log"
  (
    cd "$repo_dir"
    CLAUDECODE=0 nohup archon workflow run archon-fix-github-issue "fix #$issue_num" \
      > "$logf" 2>&1 &
    disown
  )
  log "$project: archon fired for issue #$issue_num (log $logf)"
}

# ----------------------------------------------------------------------------
# Check 2: Prod deploy health — failed or lagging main HEAD.
#   Signal sources (try in order, use whichever exists):
#     (a) GH Actions workflow matching "Production" (Reli, WCA use "Staging → Production Pipeline")
#     (b) GitHub deployments API, environment matches "production" (Railway native integration, FilmDuel)
#   If deploy FAILED → file issue + fire archon (dedup by deploy SHA).
#   If last successful deploy SHA != main HEAD AND main HEAD older than 15 min → file lag issue.
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

  # --- Source (a): GH Actions deploy workflow ---
  local deploy_sha="" deploy_ts="" deploy_state="" deploy_url=""
  local wf_run
  wf_run=$(gh run list --repo "alexsiri7/$project" --branch main --limit 10 \
    --json name,headSha,updatedAt,conclusion,url \
    --jq '[.[] | select(.name | test("Production"; "i"))] | .[0] // empty' \
    2>/dev/null || echo "")
  if [ -n "$wf_run" ]; then
    deploy_sha=$(echo "$wf_run" | jq -r '.headSha')
    deploy_ts=$(echo "$wf_run" | jq -r '.updatedAt')
    deploy_state=$(echo "$wf_run" | jq -r '.conclusion // "pending"')
    deploy_url=$(echo "$wf_run" | jq -r '.url')
  fi

  # --- Source (b): GitHub deployments API (Railway native) ---
  if [ -z "$deploy_sha" ]; then
    local dep
    dep=$(gh api "repos/alexsiri7/$project/deployments?per_page=10" \
      --jq '[.[] | select(.environment | test("production"; "i"))] | .[0] // empty' \
      2>/dev/null || echo "")
    if [ -n "$dep" ]; then
      deploy_sha=$(echo "$dep" | jq -r '.sha')
      deploy_ts=$(echo "$dep" | jq -r '.created_at')
      local dep_id
      dep_id=$(echo "$dep" | jq -r '.id')
      deploy_state=$(gh api "repos/alexsiri7/$project/deployments/$dep_id/statuses?per_page=1" \
        --jq '.[0].state // "pending"' 2>/dev/null || echo "pending")
      deploy_url="https://github.com/alexsiri7/$project/deployments"
    fi
  fi

  [ -n "$deploy_sha" ] || return  # No deploy signal — skip silently

  # --- Case 1: deploy FAILED ---
  if [ "$deploy_state" = "failure" ] || [ "$deploy_state" = "error" ]; then
    local marker="$STATE_DIR/prod-deploy-failed-$project-${deploy_sha:0:12}"
    if [ -f "$marker" ]; then
      log "$project: prod deploy still failed at ${deploy_sha:0:10} — already filed, skipping"
      return
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
    # No ntfy — archon has been fired and will auto-fix. If it can't,
    # the issue stays open and pipeline-health re-tries on the next tick.

    mkdir -p "$repo_dir/.archon-logs"
    local logf="$repo_dir/.archon-logs/health-prod-deploy-${deploy_sha:0:8}-$(date +%Y%m%d-%H%M%S).log"
    (
      cd "$repo_dir"
      CLAUDECODE=0 nohup archon workflow run archon-fix-github-issue "fix #$issue_num" \
        > "$logf" 2>&1 &
      disown
    )
    log "$project: archon fired for issue #$issue_num (log $logf)"
    return
  fi

  # --- Case 2: deploy succeeded but lagging main HEAD ---
  if [ "$deploy_state" = "success" ] && [ "$deploy_sha" != "$head_sha" ]; then
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
**Latest prod deploy**: \`$deploy_sha\` at $deploy_ts
**Deploy source**: $deploy_url

Auto-filed by \`pipeline-health-cron.sh\`. main has been ahead of prod for >15 minutes, which suggests the deploy mechanism (Railway webhook, GH Actions workflow) did not fire or silently failed.

### Steps
1. Check $deploy_url — is there a run for $head_sha?
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
      return
    fi
  fi

  # Deploy up to date — clear stale markers
  find "$STATE_DIR" -maxdepth 1 \( -name "prod-deploy-failed-$project-*" -o -name "prod-deploy-stale-$project-*" \) -delete 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Check 3: Abandon archon DB runs marked "running" for >4h — likely orphaned.
# ----------------------------------------------------------------------------
reconcile_zombies() {
  local status_out
  status_out=$(cd "$BASE_DIR/archon" && \
    CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 archon workflow status 2>/dev/null || true)
  [ -n "$status_out" ] || return

  echo "$status_out" | awk '
    /^ *ID: / { id = $2 }
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
      if (age_hours >= 4) print id
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
# Check 3: Disk warning — ntfy if / or /mnt/ext-fast above 85%.
# ----------------------------------------------------------------------------
check_disk() {
  for mount in / /mnt/ext-fast; do
    local used
    used=$(df -P "$mount" 2>/dev/null | awk 'NR==2 { gsub("%",""); print $5 }')
    [ -n "$used" ] || continue
    if [ "$used" -ge 85 ]; then
      log "disk $mount at ${used}% — ntfying"
      notify "Disk warning: $mount ${used}%" \
        "Pipeline will stall if this fills. Investigate and clean." \
        high warning
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

  local logf="/tmp/pipeline-health-diagnostic-$(date +%Y%m%d-%H%M%S).log"
  (
    cd "$BASE_DIR/archon"
    CLAUDECODE=0 nohup archon workflow run archon-assist \
      "Pipeline-health-cron detected no progress across repos ${REPOS[*]} in the last 30 minutes. No commits landed on origin/main, no archon workflows completed, and no token-limit markers were found in recent .archon-logs. Investigate: check 'gh run list' per repo, 'archon workflow status', recent logs in /tmp/pr-maintenance.log and /tmp/issue-pickup.log, and take action to unblock whatever is stuck." \
      > "$logf" 2>&1 &
    disown
  )
  # No ntfy — archon-assist has been fired and will diagnose; if nothing
  # improves on the next tick, we'll fire it again (2h cooldown).
}

# ----------------------------------------------------------------------------
log "=== pipeline health check ==="
for project in "${REPOS[@]}"; do
  check_main_ci "$project"
  check_prod_deploy "$project"
done
reconcile_zombies
check_disk
check_progress
log "=== done ==="
