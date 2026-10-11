#!/usr/bin/env bash
# lib/build-drift.sh — sourced by pipeline-health-cron.sh (Check 1d).
#
# Build drift: main can go red without a push. An unpinned tool (`npx
# @fission-ai/openspec@latest`), a dependency release or a runner image update
# breaks a workflow that has not run since, so main looks green while every PR
# is red (FilmDuel and Annie's OpenSpec, 2026-10). The owner's policy is to never
# pin tools to keep CI green, so this check re-runs main's CI/validation
# workflows once a day and files an issue when one breaks, so the factory fixes
# the real cause.
#
# Once a day per project, for each active workflow under .github/workflows/
# whose newest push run on main last ran more than BUILD_DRIFT_STALE_SECONDS ago:
#   - push run at main HEAD  → `gh run rerun` it (event stays push, SHA stays
#     HEAD), so check_main_ci judges the result and files "Main CI red" as usual.
#   - push run at an OLDER SHA (a path-filtered workflow the latest commits did
#     not trigger) → `gh workflow run --ref main` when the workflow declares
#     workflow_dispatch, else rerun that older push run. check_main_ci never sees
#     either (it reads push runs at HEAD only), so build_drift_judge follows the
#     run and files "Main CI drift: <workflow>" when it fails.
# A HEAD run whose rerun is barred (side effects, see below) is dispatched
# instead when it can be, and judged the same way.
#
# Which workflows may be touched (build_drift_policy), fail-closed:
#   1. deny on name/path: BUILD_DRIFT_DENY_RE (release, deploy, migrate, ...);
#   2. allow on name/path: BUILD_DRIFT_ALLOW_RE (CI, tests, OpenSpec, ...);
#      anything matching neither is skipped;
#   3. a rerun keeps event=push, which is what every deploy gate keys on, so a
#      rerun additionally needs no side-effect signal in the repo: no other
#      workflow names it under workflow_run (reli/filmduel/kindred deploy off a
#      green CI — rerunning an older CI run would roll prod back), and its file
#      grants no write permission (checks: write excepted), runs no
#      `gh workflow run` and uses no `environment:`.
#      A dispatch is event=workflow_dispatch, which those gates all reject; it
#      needs only that no workflow_run consumer lacks the push-only guard and
#      that no other workflow names its file (a watchdog that redeploys on any
#      green ci.yml run, as Annie's does).
#
# State in $STATE_DIR/build-drift/:
#   <project>-<YYYYMMDD>            the project's daily pass completed
#   <project>-<wfid>-<YYYYMMDD>     that workflow decided today (acted or skipped)
#   pending/<project>-<wfid>        a drift run to judge on later ticks
#   rerun-<run id>                  a HEAD rerun, so check_main_ci can say "drift"
# A marker is written only once its gh call succeeded, so a failure retries on
# the next tick. Costs GitHub Actions minutes, never Claude tokens, except when a
# real failure is filed and archon is fired on it.
#
# Needs from the sourcing script: STATE_DIR, BASE_DIR, log, find_tracked_issue,
# fire_ship_and_settle, add_to_project.

# Re-run when the newest run finished longer ago than this. Below 24h on purpose:
# the daily pass lands at about the same time each day, and yesterday's drift run
# must count as stale today or a workflow would only be re-run every other day.
BUILD_DRIFT_STALE_SECONDS="${BUILD_DRIFT_STALE_SECONDS:-72000}"
# GitHub refuses to re-run a run created more than 30 days ago; a day of slack.
BUILD_DRIFT_RERUN_MAX_AGE_SECONDS="${BUILD_DRIFT_RERUN_MAX_AGE_SECONDS:-2505600}"
# A pending drift run nobody can find (dispatch never registered, rerun never
# started) is dropped after this; the next daily pass tries again.
BUILD_DRIFT_PENDING_MAX_SECONDS="${BUILD_DRIFT_PENDING_MAX_SECONDS:-21600}"

BUILD_DRIFT_DENY_RE='release|deploy|publish|pages|migrat|production|staging|deliver|promot|rollout|rollback|store|listing|screenshot|dns|cname|one-shot|watchdog|monitor|uptime|backup|sync|stale|dependabot|dependency graph|update-graph|unsafe-change|label|triage'
BUILD_DRIFT_ALLOW_RE='(^|[^a-z])(ci|tests?|lint|checks?|validate|validation|openspec|integration|scan|verify|build)([^a-z]|$)'
BUILD_DRIFT_WRITE_RE='(contents|packages|deployments|actions|id-token|pages|issues|pull-requests|statuses|attestations|security-events|repository-projects|discussions)[ \t]*:[ \t]*write|write-all|gh workflow run|^[ \t]*environment[ \t]*:'

# build_drift_policy <name> <path>: "allow", or "deny <reason>". Name/path rules
# only (1-2 above); rerun side effects are build_drift_rerun_blocker's.
build_drift_policy() {
  local name path hay
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  path=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  case "$path" in
    .github/workflows/*) ;;
    *) echo "deny not a repo workflow file"; return ;;
  esac
  hay="$name ${path##*/}"
  if printf '%s' "$hay" | grep -qE "$BUILD_DRIFT_DENY_RE"; then
    echo "deny name/path matches the release/deploy/side-effect deny list"
  elif printf '%s' "$hay" | grep -qE "$BUILD_DRIFT_ALLOW_RE"; then
    echo "allow"
  else
    echo "deny name/path is not on the CI/validation allow list"
  fi
}

# Workflow YAML on stdin, comment lines dropped.
build_drift_uncommented() {
  grep -v '^[[:space:]]*#' || true
}

# build_drift_workflow_run_targets: workflow YAML on stdin; prints each workflow
# name it lists under `workflow_run: workflows:` (inline or block list).
build_drift_workflow_run_targets() {
  build_drift_uncommented | awk '
    inlist && /^[ \t]*-/ { s = $0; sub(/^[ \t]*-[ \t]*/, "", s); print s; next }
    inlist { inlist = 0 }
    /^[ \t]*workflows[ \t]*:/ {
      s = $0; sub(/^[ \t]*workflows[ \t]*:[ \t]*/, "", s)
      if (s == "") { inlist = 1; next }
      gsub(/\[|\]/, "", s)
      n = split(s, a, ",")
      for (i = 1; i <= n; i++) print a[i]
    }' | sed -e "s/^[[:space:]\"']*//" -e "s/[[:space:]\"']*\$//" | grep -v '^$' || true
}

# build_drift_dispatchable: workflow YAML on stdin; true if it declares
# workflow_dispatch.
build_drift_dispatchable() {
  build_drift_uncommented | grep -qE '(^|[^a-z_])workflow_dispatch([^a-z_]|$)'
}

# build_drift_rerun_blocker <name> <content-dir> <file>: prints why a rerun (which
# keeps event=push) could have side effects; nothing when it could not. Every
# workflow file of the repo is in <content-dir> (as <wfid>.yml).
build_drift_rerun_blocker() {
  local name="$1" dir="$2" file="$3" other target
  if build_drift_uncommented < "$file" | grep -qE "$BUILD_DRIFT_WRITE_RE"; then
    echo "its file grants write permissions, dispatches workflows or uses an environment"
    return
  fi
  for other in "$dir"/*.yml; do
    [ -e "$other" ] && [ "$other" != "$file" ] || continue
    grep -q 'workflow_run' "$other" || continue
    while IFS= read -r target; do
      if [ "$target" = "$name" ]; then
        echo "another workflow (${other##*/}) runs on its completion (workflow_run)"
        return
      fi
    done < <(build_drift_workflow_run_targets < "$other")
  done
}

# build_drift_dispatch_blocker <name> <content-dir> <file> <path>: prints why a
# workflow_dispatch run could set something else off; nothing when it could not.
# Deploy gates in the fleet require workflow_run.event == 'push', so a consumer
# carrying that guard is fine; one without it, or any workflow that names this
# file (Annie's pipeline watchdog redeploys on any green ci.yml run), is not.
build_drift_dispatch_blocker() {
  local name="$1" dir="$2" file="$3" base re other target
  base="${4##*/}"
  re=$(printf '%s' "$base" | sed 's/[.]/[.]/g')
  for other in "$dir"/*.yml; do
    [ -e "$other" ] && [ "$other" != "$file" ] || continue
    if build_drift_uncommented < "$other" | grep -qE "(^|[^A-Za-z0-9_.-])$re([^A-Za-z0-9_.-]|\$)"; then
      echo "another workflow (${other##*/}) references $base"
      return
    fi
    grep -q 'workflow_run' "$other" || continue
    grep -qE "workflow_run\.event[[:space:]]*==[[:space:]]*['\"]push" "$other" && continue
    while IFS= read -r target; do
      if [ "$target" = "$name" ]; then
        echo "another workflow (${other##*/}) runs on its completion without a push-only guard"
        return
      fi
    done < <(build_drift_workflow_run_targets < "$other")
  done
}

build_drift_epoch() {
  date -d "$1" +%s 2>/dev/null || echo 0
}

# A gh write that will fail the same way tomorrow: a run past the 30-day rerun
# window, a dispatch missing a required input, a token without the permission.
build_drift_permanent_error() {
  printf '%s' "$1" | grep -qiE 'HTTP 4(03|22)|over a month|cannot be re-?run|older than'
}

# build_drift_record_pending <project> <wfid> <mode> <workflow> <run_id> <attempt> <sha>
build_drift_record_pending() {
  local f="$STATE_DIR/build-drift/pending/$1-$2"
  mkdir -p "${f%/*}"
  printf 'mode=%s\nworkflow=%s\nrun_id=%s\nattempt=%s\nsha=%s\nsince=%s\n' \
    "$3" "$4" "$5" "$6" "$7" "$(date +%s)" > "$f"
}

build_drift_field() {
  sed -n "s/^$1=//p" "$2" | head -1
}

# build_drift_rerun <project> <run id>: 0 done, 2 permanently refused, 1 retry.
build_drift_rerun() {
  local out
  if out=$(gh run rerun "$2" --repo "alexsiri7/$1" 2>&1); then
    return 0
  fi
  log "$1: gh run rerun $2 failed: $(printf '%s' "$out" | tail -1)"
  build_drift_permanent_error "$out" && return 2
  return 1
}

# build_drift_dispatch <project> <wfid>: 0 done, 2 permanently refused, 1 retry.
build_drift_dispatch() {
  local out
  if out=$(gh workflow run "$2" --repo "alexsiri7/$1" --ref main 2>&1); then
    return 0
  fi
  log "$1: gh workflow run $2 --ref main failed: $(printf '%s' "$out" | tail -1)"
  build_drift_permanent_error "$out" && return 2
  return 1
}

# build_drift_workflow <project> <head sha> <content-dir> <wf json>: decide one
# workflow. 0 when decided for today (acted or deliberately skipped), 1 when a
# gh call failed and the next tick should try again.
build_drift_workflow() {
  local project="$1" head="$2" dir="$3" wf="$4"
  local id name path policy file now
  id=$(echo "$wf" | jq -r '.id')
  name=$(echo "$wf" | jq -r '.name')
  path=$(echo "$wf" | jq -r '.path')
  file="$dir/$id.yml"
  now=$(date +%s)

  policy=$(build_drift_policy "$name" "$path")
  if [ "$policy" != allow ]; then
    log "$project: drift: skip \"$name\" — ${policy#deny }"
    return 0
  fi

  local push_run
  if ! push_run=$(gh api "repos/alexsiri7/$project/actions/workflows/$id/runs?branch=main&event=push&per_page=1" \
       --jq '.workflow_runs[0] // empty' 2>/dev/null); then
    log "$project: drift: could not list push runs of \"$name\" — retrying next tick"
    return 1
  fi
  if [ -z "$push_run" ]; then
    log "$project: drift: skip \"$name\" — no push run on main"
    return 0
  fi

  local dispatchable=0 dispatch_run="" dispatch_blocker=""
  dispatch_blocker=$(build_drift_dispatch_blocker "$name" "$dir" "$file" "$path")
  if [ -z "$dispatch_blocker" ] && build_drift_dispatchable < "$file"; then
    dispatchable=1
    if ! dispatch_run=$(gh api "repos/alexsiri7/$project/actions/workflows/$id/runs?branch=main&event=workflow_dispatch&per_page=1" \
         --jq '.workflow_runs[0] // empty' 2>/dev/null); then
      log "$project: drift: could not list dispatch runs of \"$name\" — retrying next tick"
      return 1
    fi
  fi

  local run_id run_sha run_status run_conclusion run_created run_attempt last
  run_id=$(echo "$push_run" | jq -r '.id')
  run_sha=$(echo "$push_run" | jq -r '.head_sha')
  run_status=$(echo "$push_run" | jq -r '.status')
  run_conclusion=$(echo "$push_run" | jq -r '.conclusion // ""')
  run_created=$(build_drift_epoch "$(echo "$push_run" | jq -r '.created_at')")
  run_attempt=$(echo "$push_run" | jq -r '.run_attempt // 1')
  last=$(build_drift_epoch "$(echo "$push_run" | jq -r '.updated_at')")
  if [ -n "$dispatch_run" ]; then
    if [ "$(echo "$dispatch_run" | jq -r '.status')" != completed ]; then
      log "$project: drift: skip \"$name\" — a dispatch run is in flight"
      return 0
    fi
    local d_last
    d_last=$(build_drift_epoch "$(echo "$dispatch_run" | jq -r '.updated_at')")
    [ "$d_last" -gt "$last" ] && last="$d_last"
  fi
  if [ "$run_status" != completed ]; then
    log "$project: drift: skip \"$name\" — run $run_id is in flight"
    return 0
  fi
  if [ $(( now - last )) -lt "$BUILD_DRIFT_STALE_SECONDS" ]; then
    log "$project: drift: skip \"$name\" — ran $(( (now - last) / 3600 ))h ago"
    return 0
  fi

  local blocker rerunnable=1 why_not=""
  blocker=$(build_drift_rerun_blocker "$name" "$dir" "$file")
  if [ -n "$blocker" ]; then
    rerunnable=0; why_not="$blocker"
  elif [ $(( now - run_created )) -ge "$BUILD_DRIFT_RERUN_MAX_AGE_SECONDS" ]; then
    rerunnable=0; why_not="run $run_id is past GitHub's 30-day rerun window"
  fi

  local rc
  if [ "$run_sha" = "$head" ]; then
    if [ "$run_conclusion" = failure ]; then
      log "$project: drift: skip \"$name\" — already red at HEAD, check_main_ci owns it"
      return 0
    fi
    if [ "$rerunnable" = 1 ]; then
      build_drift_rerun "$project" "$run_id"; rc=$?
      if [ "$rc" = 0 ]; then
        touch "$STATE_DIR/build-drift/rerun-$run_id"
        log "$project: drift: re-ran \"$name\" run $run_id at HEAD ${head:0:10} — check_main_ci judges it"
        return 0
      fi
      [ "$rc" = 2 ] || return 1
      why_not="gh refused the rerun"
    fi
  fi

  # An older SHA (or a HEAD run that may not be re-run): dispatch on main first,
  # since that tests HEAD; rerun the older push run only when that is not possible.
  if [ "$dispatchable" = 1 ]; then
    build_drift_dispatch "$project" "$id"; rc=$?
    if [ "$rc" = 0 ]; then
      build_drift_record_pending "$project" "$id" dispatch "$name" "" "" "$head"
      log "$project: drift: dispatched \"$name\" on main (newest push run ${run_sha:0:10}, HEAD ${head:0:10})"
      return 0
    fi
    [ "$rc" = 2 ] || return 1
  fi
  if [ "$run_sha" != "$head" ] && [ "$rerunnable" = 1 ]; then
    build_drift_rerun "$project" "$run_id"; rc=$?
    if [ "$rc" = 0 ]; then
      build_drift_record_pending "$project" "$id" rerun "$name" "$run_id" "$run_attempt" "$run_sha"
      log "$project: drift: re-ran \"$name\" run $run_id at older SHA ${run_sha:0:10} (HEAD ${head:0:10}; no workflow_dispatch)"
      return 0
    fi
    [ "$rc" = 2 ] || return 1
    why_not="gh refused the rerun"
  fi
  log "$project: drift: skip \"$name\" — cannot re-run it safely (${why_not:-no workflow_dispatch}) and cannot dispatch it (${dispatch_blocker:-no workflow_dispatch})"
  return 0
}

# build_drift_file_issue <project> <wf> <run json> <mode>: file "Main CI drift:
# <wf>" and fire archon, unless one this script filed is already open. 0 when
# handled (filed or already tracked), 1 to retry next tick.
build_drift_file_issue() {
  local project="$1" wf="$2" run="$3" mode="$4"
  local repo="alexsiri7/$project" repo_dir="$BASE_DIR/$project"
  local title="Main CI drift: $wf"
  local tracked
  tracked=$(find_tracked_issue "$repo" "$title")
  if [ -n "$tracked" ]; then
    log "$project: drift: \"$wf\" red, but issue #${tracked%% *} already tracks it (${tracked##* }) — skipping"
    return 0
  fi

  local run_id run_sha url head failed_jobs how
  run_id=$(echo "$run" | jq -r '.id')
  run_sha=$(echo "$run" | jq -r '.head_sha')
  url=$(echo "$run" | jq -r '.html_url')
  head=$(gh api "repos/$repo/commits/main" --jq '.sha' 2>/dev/null || echo "unknown")
  failed_jobs=$(gh run view "$run_id" --repo "$repo" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")' 2>/dev/null || echo "unknown")
  [ -n "$failed_jobs" ] || failed_jobs="unknown"
  if [ "$mode" = dispatch ]; then
    how="\`workflow_dispatch\` on \`main\`, because the newest push run of this workflow was for an older commit"
  else
    how="re-run of the newest \`push\` run of this workflow on \`main\` (for \`$run_sha\`; the commits since did not touch its paths)"
  fi

  local body
  # Keep the "Auto-filed by" line verbatim: find_tracked_issue dedups on it and
  # lib/settle-ship-outcome.sh parks rather than closes issues that carry it.
  body=$(cat <<EOF
## Main CI drift: $wf

**Repo**: $repo
**Workflow**: $wf
**Run**: $url
**Run SHA**: \`$run_sha\` (main HEAD: \`$head\`)
**How it ran**: $how
**Failed jobs**: $failed_jobs

This is **build drift, not a commit**: nothing landed on \`main\` to break it. The workflow last passed on the same code, and \`pipeline-health-cron.sh\` re-ran it because it had not run for a day. Something outside the repo changed: an unpinned tool or action (\`npx …@latest\`), a dependency release, a runner image update or an external service. Every PR that runs this workflow is red until it is fixed.

Fix the real cause. Do not pin the tool to an old version to make CI green (owner policy, 2026-10-11).

Auto-filed by \`pipeline-health-cron.sh\` (build drift check). Main CI is a pipeline bottleneck, so archon has been fired immediately on this issue rather than queued. This issue is tagged \`archon:in-progress\` so the regular pickup cron will not double-fire. It is closed automatically once this workflow passes on \`main\` again.

### Steps
1. \`gh run view $run_id --repo $repo --log-failed\`
2. Find what changed upstream (release notes of the tool or action named in the failure)
3. Fix the code or config to work with it, open a PR, ensure CI goes green
EOF
)
  local issue_url issue_num
  issue_url=$(gh issue create --repo "$repo" --title "$title" \
    --label "bug,archon:in-progress" --body "$body" 2>/dev/null | tail -1)
  issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
  if [ -z "$issue_num" ]; then
    log "$project: drift: could not file the \"$wf\" issue — retrying next tick"
    return 1
  fi
  add_to_project "$project" "$issue_num"
  log "$project: drift: \"$wf\" red at ${run_sha:0:10} with no new commit — filed #$issue_num"
  if [ -d "$repo_dir/.git" ]; then
    mkdir -p "$repo_dir/.archon-logs"
    local logf
    logf="$repo_dir/.archon-logs/health-ci-drift-${run_sha:0:8}-issue-${issue_num}-$(date +%Y%m%d-%H%M%S).log"
    fire_ship_and_settle "$project" "$issue_num" "$repo_dir" "$logf"
    log "$project: archon fired for issue #$issue_num (log $logf)"
  fi
  return 0
}

# build_drift_close <project> <wf> <why>: close every open "Main CI drift: <wf>"
# issue this script filed.
build_drift_close() {
  local project="$1" wf="$2" why="$3" repo="alexsiri7/$1" num
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    if gh issue close "$num" --repo "$repo" \
        --comment "Resolved: $why Closed by \`pipeline-health-cron.sh\`, which filed this build-drift issue." \
        >/dev/null 2>&1; then
      log "$project: closed drift issue #$num — $why"
    else
      log "$project: could not close drift issue #$num — retrying next tick"
    fi
  done < <(gh issue list --repo "$repo" --state open --limit 100 \
             --search "Main CI drift in:title" --json number,title,body 2>/dev/null \
           | jq -r --arg t "Main CI drift: $wf" \
               '.[] | select(.title == $t)
                    | select((.body // "") | contains("Auto-filed by `pipeline-health-cron.sh`"))
                    | .number' 2>/dev/null)
}

# build_drift_judge <project>: follow each pending drift run to its verdict.
# Red → file the drift issue; green → close any open one.
build_drift_judge() {
  local project="$1" f now
  now=$(date +%s)
  for f in "$STATE_DIR/build-drift/pending/$project"-*; do
    [ -f "$f" ] || continue
    local mode wf run_id attempt since wfid run
    mode=$(build_drift_field mode "$f")
    wf=$(build_drift_field workflow "$f")
    run_id=$(build_drift_field run_id "$f")
    attempt=$(build_drift_field attempt "$f")
    since=$(build_drift_field since "$f")
    case "$since" in ''|*[!0-9]*) since=0 ;; esac
    wfid="${f##*/"$project"-}"

    if [ -z "$run_id" ]; then
      # A dispatch: gh does not return the run id, so find the run it created.
      run_id=$(gh api "repos/alexsiri7/$project/actions/workflows/$wfid/runs?branch=main&event=workflow_dispatch&per_page=5" \
        --jq '.workflow_runs[] | "\(.id) \(.created_at)"' 2>/dev/null \
        | while read -r id created; do
            if [ "$(build_drift_epoch "$created")" -ge $(( since - 120 )) ]; then
              echo "$id"
              break
            fi
          done || true)
      if [ -z "$run_id" ]; then
        if [ $(( now - since )) -gt "$BUILD_DRIFT_PENDING_MAX_SECONDS" ]; then
          log "$project: drift: the \"$wf\" dispatch never produced a run — dropped, the next daily pass retries"
          rm -f "$f"
        fi
        continue
      fi
      sed -i "s/^run_id=.*/run_id=$run_id/" "$f"
    fi

    if ! run=$(gh api "repos/alexsiri7/$project/actions/runs/$run_id" \
         --jq '{id, head_sha, status, conclusion, run_attempt, html_url}' 2>/dev/null) || [ -z "$run" ]; then
      log "$project: drift: could not read run $run_id of \"$wf\" — retrying next tick"
      continue
    fi
    if [ "$mode" = rerun ] && [ "$(echo "$run" | jq -r '.run_attempt // 1')" -le "${attempt:-0}" ]; then
      # The rerun has not registered as a new attempt yet.
      if [ $(( now - since )) -gt "$BUILD_DRIFT_PENDING_MAX_SECONDS" ]; then
        log "$project: drift: the \"$wf\" rerun of $run_id never started — dropped"
        rm -f "$f"
      fi
      continue
    fi
    [ "$(echo "$run" | jq -r '.status')" = completed ] || continue

    case "$(echo "$run" | jq -r '.conclusion // ""')" in
      success)
        log "$project: drift: \"$wf\" still green on main (run $run_id)"
        build_drift_close "$project" "$wf" "\`$wf\` passed on \`main\` again (run $run_id)."
        rm -f "$f"
        ;;
      failure)
        build_drift_file_issue "$project" "$wf" "$run" "$mode" && rm -f "$f"
        ;;
      *)
        log "$project: drift: \"$wf\" run $run_id ended $(echo "$run" | jq -r '.conclusion') — no verdict, dropped"
        rm -f "$f"
        ;;
    esac
  done
  return 0
}

# build_drift_close_recovered <project> <workflows json>: an open
# drift issue whose workflow's newest completed main run (push or dispatch) is
# green — say the factory's fix PR touched its paths — is resolved.
build_drift_close_recovered() {
  local project="$1" workflows="$2" issues wf id latest
  issues=$(gh issue list --repo "alexsiri7/$project" --state open --limit 100 \
    --search "Main CI drift in:title" --json title,body 2>/dev/null \
    | jq -r '.[] | select(.title | startswith("Main CI drift: "))
                 | select((.body // "") | contains("Auto-filed by `pipeline-health-cron.sh`"))
                 | .title | ltrimstr("Main CI drift: ")' 2>/dev/null) || return 0
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    id=$(echo "$workflows" | jq -r --arg n "$wf" '[.[] | select(.name == $n)][0].id // empty')
    [ -n "$id" ] || continue
    latest=$(gh api "repos/alexsiri7/$project/actions/workflows/$id/runs?branch=main&per_page=10" \
      --jq '[.workflow_runs[] | select(.status == "completed" and (.event == "push" or .event == "workflow_dispatch"))]
            | sort_by(.updated_at) | last // empty | "\(.id) \(.conclusion)"' 2>/dev/null || echo "")
    if [ "${latest##* }" = success ]; then
      build_drift_close "$project" "$wf" "\`$wf\` passed on \`main\` again (run ${latest%% *})."
    fi
  done <<< "$issues"
  return 0
}

# check_build_drift <project>: judge pending drift runs every tick; once a day,
# re-run each stale CI/validation workflow on main.
check_build_drift() {
  local project="$1"
  local dir="$STATE_DIR/build-drift" today
  [ -d "$BASE_DIR/$project/.git" ] || return 0
  mkdir -p "$dir/pending"
  today=$(date +%Y%m%d)

  build_drift_judge "$project"

  [ -f "$dir/$project-$today" ] && return 0

  local head workflows
  head=$(gh api "repos/alexsiri7/$project/commits/main" --jq '.sha' 2>/dev/null || echo "")
  if [ -z "$head" ] || [ "$head" = null ]; then
    log "$project: drift: commits/main returned no SHA — retrying next tick"
    return 0
  fi
  if ! workflows=$(gh api "repos/alexsiri7/$project/actions/workflows?per_page=100" \
       --jq '[.workflows[] | select(.state == "active") | {id, name, path}]' 2>/dev/null) \
     || [ -z "$workflows" ]; then
    log "$project: drift: could not list workflows — retrying next tick"
    return 0
  fi

  # Every workflow file, so a rerun can be checked against every workflow_run
  # consumer in the repo. One unreadable file and the pass waits: deciding
  # without it could rerun a deploy trigger.
  local content_dir id path ok=1
  content_dir=$(mktemp -d)
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] || continue
    case "$path" in .github/workflows/*) ;; *) continue ;; esac
    if ! gh api "repos/alexsiri7/$project/contents/$path?ref=main" --jq '.content' 2>/dev/null \
         | base64 -d > "$content_dir/$id.yml" 2>/dev/null || [ ! -s "$content_dir/$id.yml" ]; then
      log "$project: drift: could not read $path — retrying next tick"
      ok=0
      break
    fi
  done < <(echo "$workflows" | jq -r '.[] | "\(.id)\t\(.path)"')

  if [ "$ok" = 1 ]; then
    local wf
    while IFS= read -r wf; do
      [ -n "$wf" ] || continue
      id=$(echo "$wf" | jq -r '.id')
      [ -f "$dir/$project-$id-$today" ] && continue
      if build_drift_workflow "$project" "$head" "$content_dir" "$wf"; then
        touch "$dir/$project-$id-$today"
      else
        ok=0
      fi
    done < <(echo "$workflows" | jq -c '.[]')
    build_drift_close_recovered "$project" "$workflows"
  fi
  rm -rf "$content_dir"

  if [ "$ok" = 1 ]; then
    touch "$dir/$project-$today"
    # Earlier days' markers and HEAD-rerun notes older than a week.
    find "$dir" -maxdepth 1 -type f -name "$project-*" ! -name "*-$today" -delete 2>/dev/null || true
    find "$dir" -maxdepth 1 -type f -name "rerun-*" -mtime +7 -delete 2>/dev/null || true
  fi
}
