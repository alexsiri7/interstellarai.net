#!/usr/bin/env bats
# Unit tests for lib/build-drift.sh (pipeline-health-cron.sh Check 1d): once a
# day, re-run main's stale CI/validation workflows so a tool release that breaks
# the build files an issue even though nothing was pushed.
#
# gh is a stub that serves fixture files and applies `--jq` with real jq, so the
# filters in the lib are exercised. Every argv lands in $GH_LOG.
#
# Run: bats ops/cron/tests/pipeline-health-build-drift.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/build-drift-$$"
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR"
    FIX="$STATE_DIR/fix"
    mkdir -p "$FIX/files" "$FIX/runs"
    GH_LOG="$STATE_DIR/gh-argv"
    : > "$GH_LOG"
    BASE_DIR="$STATE_DIR/repos"
    mkdir -p "$BASE_DIR/proj/.git"

    HEAD_SHA="headsha000000000000"
    ISSUE_LIST_FIXTURE='[]'
    RERUN_FAILS=""
    DISPATCH_FAILS=""
    ISSUE_CREATE_FAILS=""

    log() { echo "$*" >> "$STATE_DIR/log"; }
    add_to_project() { :; }
    fire_ship_and_settle() { echo "$*" >> "$STATE_DIR/fired"; }

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^TRACKED_(HUMAN|ACTIVE)_LABELS=/{print}' "$SCRIPT_FILE")
    # shellcheck disable=SC1090
    source <(awk '/^find_tracked_issue\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
    # shellcheck source=../lib/build-drift.sh
    source "$(dirname "$SCRIPT_FILE")/lib/build-drift.sh"

    gh() {
        printf '%s\n' "$*" >> "$GH_LOG"
        local jqexpr="" a out
        local -a args=("$@")
        for ((i = 0; i < ${#args[@]}; i++)); do
            [ "${args[$i]}" = "--jq" ] && jqexpr="${args[$((i + 1))]}"
        done
        case "$1 $2" in
            "run rerun")
                if [ -n "$RERUN_FAILS" ]; then echo "$RERUN_FAILS" >&2; return 1; fi
                return 0 ;;
            "workflow run")
                if [ -n "$DISPATCH_FAILS" ]; then echo "$DISPATCH_FAILS" >&2; return 1; fi
                return 0 ;;
            "run view") echo "build"; return 0 ;;
            "issue list") out="$ISSUE_LIST_FIXTURE" ;;
            "issue create")
                [ -n "$ISSUE_CREATE_FAILS" ] && return 1
                for ((i = 0; i < ${#args[@]}; i++)); do
                    [ "${args[$i]}" = "--body" ] && printf '%s\n' "${args[$((i + 1))]}" > "$STATE_DIR/issue-body"
                    [ "${args[$i]}" = "--title" ] && printf '%s\n' "${args[$((i + 1))]}" > "$STATE_DIR/issue-title"
                done
                echo "https://github.com/alexsiri7/proj/issues/42"; return 0 ;;
            "issue close") echo "$3" >> "$STATE_DIR/closed"; return 0 ;;
            "api "*)
                a="$2"
                case "$a" in
                    */commits/main) out="{\"sha\":\"$HEAD_SHA\"}" ;;
                    */actions/workflows\?per_page=100) out=$(cat "$FIX/workflows.json") ;;
                    */contents/*)
                        local f="${a#*/contents/.github/workflows/}"; f="${f%%\?*}"
                        [ -f "$FIX/files/$f" ] || return 1
                        out=$(jq -n --arg c "$(base64 -w0 < "$FIX/files/$f")" '{content: $c}') ;;
                    */actions/workflows/*/runs\?*)
                        local id="${a#*/actions/workflows/}"; id="${id%%/*}" ev=all
                        case "$a" in *event=push*) ev=push ;; *event=workflow_dispatch*) ev=dispatch ;; esac
                        [ -f "$FIX/runs/$id-$ev.json" ] && out=$(cat "$FIX/runs/$id-$ev.json") \
                            || out='{"workflow_runs":[]}' ;;
                    */actions/runs/*)
                        local rid="${a##*/}"
                        [ -f "$FIX/runs/run-$rid.json" ] || return 1
                        out=$(cat "$FIX/runs/run-$rid.json") ;;
                    *) return 1 ;;
                esac ;;
            *) return 0 ;;
        esac
        if [ -n "$jqexpr" ]; then echo "$out" | jq -r "$jqexpr"; else echo "$out"; fi
    }
}

teardown() {
    rm -rf "$STATE_DIR"
}

ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# run_json <id> <sha> <status> <conclusion> <created secs ago> <updated secs ago> [attempt] [event]
run_json() {
    jq -nc --argjson id "$1" --arg sha "$2" --arg st "$3" --arg c "$4" \
        --arg cr "$(ago "$5")" --arg up "$(ago "$6")" --argjson at "${7:-1}" --arg ev "${8:-push}" \
        '{id: $id, head_sha: $sha, status: $st, conclusion: (if $c == "" then null else $c end),
          created_at: $cr, updated_at: $up, run_attempt: $at, event: $ev,
          html_url: "https://github.com/alexsiri7/proj/actions/runs/\($id)"}'
}

# push_runs <wfid> <run json...>: the workflow's push-run listing.
push_runs() { local id="$1"; shift; jq -sc '{workflow_runs: .}' <<< "$*" > "$FIX/runs/$id-push.json"; }
dispatch_runs() { local id="$1"; shift; jq -sc '{workflow_runs: .}' <<< "$*" > "$FIX/runs/$id-dispatch.json"; }
all_runs() { local id="$1"; shift; jq -sc '{workflow_runs: .}' <<< "$*" > "$FIX/runs/$id-all.json"; }
single_run() { echo "$2" > "$FIX/runs/run-$1.json"; }

# workflow <id> <name> <file> <yaml>
workflow() {
    printf '%s\n' "$4" > "$FIX/files/$3"
    local cur='[]'
    [ -f "$FIX/workflows.json" ] && cur=$(jq -c '.workflows' "$FIX/workflows.json")
    jq -nc --argjson cur "$cur" --argjson id "$1" --arg n "$2" --arg p ".github/workflows/$3" \
        '{workflows: ($cur + [{id: $id, name: $n, path: $p, state: "active"}])}' > "$FIX/workflows.json"
}

PLAIN_CI=$'on:\n  push:\n    branches: [main]\n  pull_request:\npermissions:\n  contents: read\njobs:\n  test:\n    runs-on: ubuntu-latest'
DISPATCH_CI=$'on:\n  push:\n    branches: [main]\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  test:\n    runs-on: ubuntu-latest'

GUARDED_DEPLOY=$'on:\n  workflow_run:\n    workflows: ["CI"]\n    types: [completed]\njobs:\n  deploy:\n    if: >-\n      github.event.workflow_run.conclusion == \'success\' &&\n      github.event.workflow_run.event == \'push\''

today() { date +%Y%m%d; }
writes() { grep -cE '^(run rerun|workflow run|issue create|issue close)' "$GH_LOG" || true; }

# ── which workflows may be touched ───────────────────────────────────────────

@test "policy: release, deploy and side-effect workflows are denied" {
    while IFS='|' read -r name file; do
        out=$(build_drift_policy "$name" ".github/workflows/$file")
        [[ "$out" == deny* ]] || { echo "allowed: $name ($file)"; false; }
    done <<'EOF'
Release|release.yml
Deploy CF Worker|deploy-worker.yml
Deploy to Cloudflare Pages|deploy.yml
Migrate|migrate.yml
Staging → Production Pipeline|staging-pipeline.yml
Staging → Production Pipeline|deploy.yml
Fix kindred-mcp CNAME to DNS-only (one-shot)|fix-kindred-mcp-dns2.yml
Setup Store Listing|setup-store-listing.yml
Generate Store Screenshots|generate-screenshots.yml
Delivery|delivery.yml
Publish package|ci-publish.yml
unsafe-change|unsafe-change.yml
Stale issue triage|stale.yml
Uptime Monitor|uptime.yml
Pipeline Deploy Watchdog|pipeline-watchdog.yml
Nightly cleanup|cleanup.yml
EOF
    [[ "$(build_drift_policy pages-build-deployment dynamic/pages/pages-build-deployment)" == deny* ]]
    [[ "$(build_drift_policy "Dependency Graph" dynamic/dependabot/update-graph)" == deny* ]]
}

@test "policy: CI and validation workflows are allowed" {
    while IFS='|' read -r name file; do
        [ "$(build_drift_policy "$name" ".github/workflows/$file")" = allow ] \
            || { echo "denied: $name ($file)"; false; }
    done <<'EOF'
CI|ci.yml
OpenSpec|openspec.yml
OpenSpec|openspec-validate.yml
Integration|integration.yml
Ops tests|ops-tests.yml
Dependency Vulnerability Scan|dependency-scan.yml
Lint|lint.yml
EOF
}

@test "rerun blocker: a workflow another one runs on via workflow_run" {
    d="$STATE_DIR/c"; mkdir -p "$d"
    printf '%s\n' "$PLAIN_CI" > "$d/1.yml"
    printf 'on:\n  workflow_run:\n    workflows: ["CI"]\n    types: [completed]\n' > "$d/2.yml"
    [[ "$(build_drift_rerun_blocker CI "$d" "$d/1.yml")" == *"2.yml"*workflow_run* ]]

    printf 'on:\n  workflow_run:\n    workflows:\n      - "Lint"\n      - CI\n' > "$d/2.yml"
    [ -n "$(build_drift_rerun_blocker CI "$d" "$d/1.yml")" ]

    printf 'on:\n  workflow_run:\n    workflows: [CI Nightly]\n' > "$d/2.yml"
    [ -z "$(build_drift_rerun_blocker CI "$d" "$d/1.yml")" ]
}

@test "rerun blocker: write permissions, dispatching workflows or an environment" {
    d="$STATE_DIR/c"; mkdir -p "$d"
    for body in "permissions:\n  packages: write" "    permissions:\n      actions: write" \
                "permissions: write-all" "      - run: gh workflow run deploy.yml" \
                "    environment: production" "  contents:   write"; do
        printf "on: push\n$body\n" > "$d/1.yml"
        [ -n "$(build_drift_rerun_blocker CI "$d" "$d/1.yml")" ] || { echo "not blocked: $body"; false; }
    done
    for body in "permissions:\n  checks: write\n  contents: read" "# contents: write is not needed"; do
        printf "on: push\n$body\n" > "$d/1.yml"
        [ -z "$(build_drift_rerun_blocker CI "$d" "$d/1.yml")" ] || { echo "blocked: $body"; false; }
    done
}

@test "dispatchable: workflow_dispatch in any form, not in a comment" {
    printf 'on:\n  workflow_dispatch:\n' | build_drift_dispatchable
    printf 'on: [push, workflow_dispatch]\n' | build_drift_dispatchable
    ! printf 'on:\n  push:\n# add workflow_dispatch later\n' | build_drift_dispatchable
}

# ── the daily pass ───────────────────────────────────────────────────────────

@test "a CI run at HEAD that finished over 20h ago is re-run and left to check_main_ci" {
    workflow 10 CI ci.yml "$PLAIN_CI"
    push_runs 10 "$(run_json 500 "$HEAD_SHA" completed success 90000 90000)"

    check_build_drift proj

    grep -qx "run rerun 500 --repo alexsiri7/proj" "$GH_LOG"
    [ -f "$STATE_DIR/build-drift/rerun-500" ]
    [ -z "$(ls "$STATE_DIR/build-drift/pending")" ]
    [ -f "$STATE_DIR/build-drift/proj-10-$(today)" ]
    [ -f "$STATE_DIR/build-drift/proj-$(today)" ]
}

@test "a run that finished under 20h ago is left alone" {
    workflow 10 CI ci.yml "$PLAIN_CI"
    push_runs 10 "$(run_json 500 "$HEAD_SHA" completed success 30000 30000)"

    check_build_drift proj

    [ "$(writes)" -eq 0 ]
    [ -f "$STATE_DIR/build-drift/proj-$(today)" ]
}

@test "a run still in flight, or already red at HEAD, is not re-run" {
    workflow 10 CI ci.yml "$PLAIN_CI"
    workflow 11 Lint lint.yml "$PLAIN_CI"
    push_runs 10 "$(run_json 500 "$HEAD_SHA" in_progress "" 90000 90000)"
    push_runs 11 "$(run_json 501 "$HEAD_SHA" completed failure 90000 90000)"

    check_build_drift proj

    [ "$(writes)" -eq 0 ]
    grep -q 'check_main_ci owns it' "$STATE_DIR/log"
}

@test "older SHA with workflow_dispatch: dispatched on main and judged later" {
    workflow 20 OpenSpec openspec.yml "$DISPATCH_CI"
    push_runs 20 "$(run_json 600 oldsha completed success 400000 400000)"

    check_build_drift proj

    grep -qx "workflow run 20 --repo alexsiri7/proj --ref main" "$GH_LOG"
    ! grep -q "run rerun" "$GH_LOG"
    f="$STATE_DIR/build-drift/pending/proj-20"
    [ "$(build_drift_field mode "$f")" = dispatch ]
    [ "$(build_drift_field workflow "$f")" = OpenSpec ]
}

@test "older SHA, yesterday's dispatch run counts as the last run" {
    workflow 20 OpenSpec openspec.yml "$DISPATCH_CI"
    push_runs 20 "$(run_json 600 oldsha completed success 400000 400000)"
    dispatch_runs 20 "$(run_json 650 "$HEAD_SHA" completed success 30000 30000 1 workflow_dispatch)"

    check_build_drift proj

    [ "$(writes)" -eq 0 ]
}

@test "older SHA without workflow_dispatch: its newest push run is re-run and judged later" {
    workflow 20 OpenSpec openspec.yml "$PLAIN_CI"
    push_runs 20 "$(run_json 600 oldsha completed success 400000 400000 2)"

    check_build_drift proj

    grep -qx "run rerun 600 --repo alexsiri7/proj" "$GH_LOG"
    f="$STATE_DIR/build-drift/pending/proj-20"
    [ "$(build_drift_field mode "$f")" = rerun ]
    [ "$(build_drift_field run_id "$f")" = 600 ]
    [ "$(build_drift_field attempt "$f")" = 2 ]
    [ ! -f "$STATE_DIR/build-drift/rerun-600" ]
}

@test "a run past the 30-day rerun window with no workflow_dispatch: no gh call, decided for the day" {
    workflow 20 OpenSpec openspec.yml "$PLAIN_CI"
    push_runs 20 "$(run_json 600 oldsha completed success 2700000 2700000)"

    check_build_drift proj

    [ "$(writes)" -eq 0 ]
    grep -q "30-day rerun window" "$STATE_DIR/log"
    [ -f "$STATE_DIR/build-drift/proj-20-$(today)" ]
}

@test "a CI that triggers a deploy is never re-run: skipped, or dispatched when it can be" {
    workflow 10 CI ci.yml "$PLAIN_CI"
    workflow 11 "Staging → Production Pipeline" staging-pipeline.yml \
        $'on:\n  workflow_run:\n    workflows: ["CI"]\n    types: [completed]'
    push_runs 10 "$(run_json 500 oldsha completed success 400000 400000)"
    push_runs 11 "$(run_json 501 oldsha completed success 400000 400000)"

    check_build_drift proj
    [ "$(writes)" -eq 0 ]

    # Same at HEAD, with workflow_dispatch and a deploy gated on push runs: a
    # dispatch, which that gate rejects.
    rm -f "$STATE_DIR/build-drift/proj-"* "$FIX/workflows.json"
    : > "$GH_LOG"
    workflow 10 CI ci.yml "$DISPATCH_CI"
    workflow 11 "Staging → Production Pipeline" staging-pipeline.yml "$GUARDED_DEPLOY"
    push_runs 10 "$(run_json 500 "$HEAD_SHA" completed success 90000 90000)"
    check_build_drift proj
    ! grep -q "run rerun" "$GH_LOG"
    grep -qx "workflow run 10 --repo alexsiri7/proj --ref main" "$GH_LOG"
}

@test "dispatch blocker: a workflow_run consumer without a push-only guard" {
    d="$STATE_DIR/c"; mkdir -p "$d"
    printf '%s\n' "$DISPATCH_CI" > "$d/1.yml"
    printf 'on:\n  workflow_run:\n    workflows: [CI]\n' > "$d/2.yml"
    [[ "$(build_drift_dispatch_blocker CI "$d" "$d/1.yml" .github/workflows/ci.yml)" == *"push-only guard"* ]]

    printf '%s\n' "$GUARDED_DEPLOY" > "$d/2.yml"
    [ -z "$(build_drift_dispatch_blocker CI "$d" "$d/1.yml" .github/workflows/ci.yml)" ]
}

@test "dispatch blocker: another workflow naming the file (Annie's pipeline watchdog)" {
    d="$STATE_DIR/c"; mkdir -p "$d"
    printf '%s\n' "$DISPATCH_CI" > "$d/1.yml"
    printf 'on:\n  schedule:\n    - cron: "*/5 * * * *"\njobs:\n  w:\n    steps:\n      - run: gh run list --workflow=ci.yml --status success\n' > "$d/2.yml"
    [[ "$(build_drift_dispatch_blocker CI "$d" "$d/1.yml" .github/workflows/ci.yml)" == *"references ci.yml"* ]]

    # Another file name that merely contains it, or a comment, is not a reference.
    printf 'jobs:\n  w:\n    steps:\n      - run: echo openspec-ci.yml\n# ci.yml\n' > "$d/2.yml"
    [ -z "$(build_drift_dispatch_blocker CI "$d" "$d/1.yml" .github/workflows/ci.yml)" ]
}

@test "a dispatchable CI a watchdog redeploys from is neither re-run nor dispatched" {
    workflow 10 CI ci.yml $'on:\n  push:\n  workflow_dispatch:\npermissions:\n  actions: write'
    workflow 11 "Pipeline Deploy Watchdog" pipeline-watchdog.yml \
        $'on:\n  schedule:\n    - cron: "*/5 * * * *"\njobs:\n  w:\n    steps:\n      - run: gh run list --workflow=ci.yml'
    push_runs 10 "$(run_json 500 "$HEAD_SHA" completed success 90000 90000)"

    check_build_drift proj

    [ "$(writes)" -eq 0 ]
    grep -q 'cannot dispatch it (another workflow (11.yml) references ci.yml)' "$STATE_DIR/log"
}

@test "a stale Release workflow is never touched" {
    workflow 30 Release release.yml "$DISPATCH_CI"
    push_runs 30 "$(run_json 700 "$HEAD_SHA" completed success 90000 90000)"

    check_build_drift proj

    [ "$(writes)" -eq 0 ]
    [ ! -f "$FIX/runs/30-dispatch.json" ]
    ! grep -q "actions/workflows/30/runs" "$GH_LOG"
}

@test "a failed rerun writes no marker and is retried on the next tick" {
    workflow 10 CI ci.yml "$PLAIN_CI"
    push_runs 10 "$(run_json 500 "$HEAD_SHA" completed success 90000 90000)"
    RERUN_FAILS="HTTP 502: Bad Gateway"

    check_build_drift proj
    [ ! -f "$STATE_DIR/build-drift/proj-10-$(today)" ]
    [ ! -f "$STATE_DIR/build-drift/proj-$(today)" ]

    RERUN_FAILS=""
    : > "$GH_LOG"
    check_build_drift proj
    grep -qx "run rerun 500 --repo alexsiri7/proj" "$GH_LOG"
    [ -f "$STATE_DIR/build-drift/proj-$(today)" ]
}

@test "a rerun GitHub refuses for good is decided for the day, not retried every tick" {
    workflow 20 OpenSpec openspec.yml "$PLAIN_CI"
    push_runs 20 "$(run_json 600 oldsha completed success 400000 400000)"
    RERUN_FAILS="HTTP 403: Unable to retry this workflow run because it was created over a month ago"

    check_build_drift proj

    [ -f "$STATE_DIR/build-drift/proj-20-$(today)" ]
    [ ! -f "$STATE_DIR/build-drift/pending/proj-20" ]
}

@test "an unreadable workflow file holds the whole pass back" {
    workflow 10 CI ci.yml "$PLAIN_CI"
    workflow 11 Deploy deploy.yml $'on:\n  workflow_run:\n    workflows: [CI]'
    rm "$FIX/files/deploy.yml"
    push_runs 10 "$(run_json 500 "$HEAD_SHA" completed success 90000 90000)"

    check_build_drift proj

    [ "$(writes)" -eq 0 ]
    [ ! -f "$STATE_DIR/build-drift/proj-$(today)" ]
}

@test "once the day's pass is done, later ticks make no gh call" {
    workflow 10 CI ci.yml "$PLAIN_CI"
    push_runs 10 "$(run_json 500 "$HEAD_SHA" completed success 90000 90000)"
    check_build_drift proj
    : > "$GH_LOG"

    check_build_drift proj

    [ ! -s "$GH_LOG" ]
}

@test "a project with no local clone is skipped" {
    workflow 10 CI ci.yml "$PLAIN_CI"
    check_build_drift other-proj
    [ ! -s "$GH_LOG" ]
}

# ── judging drift runs ───────────────────────────────────────────────────────

pending_rerun() {
    build_drift_record_pending proj 20 rerun OpenSpec 600 1 oldsha
}

@test "judge: a red drift rerun files a Main CI drift issue naming the workflow and fires archon" {
    pending_rerun
    single_run 600 "$(run_json 600 oldsha completed failure 400000 60 2)"

    build_drift_judge proj

    [ "$(cat "$STATE_DIR/issue-title")" = "Main CI drift: OpenSpec" ]
    grep -qF 'Auto-filed by `pipeline-health-cron.sh`' "$STATE_DIR/issue-body"
    grep -q 'build drift, not a commit' "$STATE_DIR/issue-body"
    grep -q '^\*\*Workflow\*\*: OpenSpec$' "$STATE_DIR/issue-body"
    grep -q "do not pin\|Do not pin" "$STATE_DIR/issue-body"
    grep -q -- "--label bug,archon:in-progress" "$GH_LOG"
    grep -q '^proj 42 ' "$STATE_DIR/fired"
    [ ! -f "$STATE_DIR/build-drift/pending/proj-20" ]
}

@test "judge: the filed drift issue is read as tracked, so it is not filed twice" {
    pending_rerun
    single_run 600 "$(run_json 600 oldsha completed failure 400000 60 2)"
    build_drift_judge proj
    ISSUE_LIST_FIXTURE=$(jq -nc --rawfile body "$STATE_DIR/issue-body" \
        '[{number: 42, title: "Main CI drift: OpenSpec", body: $body, labels: [{name: "archon:in-progress"}]}]')
    rm -f "$STATE_DIR/issue-title" "$STATE_DIR/fired"

    pending_rerun
    build_drift_judge proj

    [ ! -f "$STATE_DIR/issue-title" ]
    [ ! -f "$STATE_DIR/fired" ]
    [ ! -f "$STATE_DIR/build-drift/pending/proj-20" ]
}

@test "judge: waits while the rerun has not started a new attempt or is in flight" {
    pending_rerun
    single_run 600 "$(run_json 600 oldsha completed success 400000 400000 1)"
    build_drift_judge proj
    [ -f "$STATE_DIR/build-drift/pending/proj-20" ]

    single_run 600 "$(run_json 600 oldsha in_progress "" 400000 60 2)"
    build_drift_judge proj
    [ -f "$STATE_DIR/build-drift/pending/proj-20" ]
    [ "$(writes)" -eq 0 ]
}

@test "judge: a failed issue create keeps the run pending" {
    pending_rerun
    single_run 600 "$(run_json 600 oldsha completed failure 400000 60 2)"
    ISSUE_CREATE_FAILS=1

    build_drift_judge proj

    [ -f "$STATE_DIR/build-drift/pending/proj-20" ]
    [ ! -f "$STATE_DIR/fired" ]
}

@test "judge: a green dispatch run is found by time and closes the open drift issue" {
    build_drift_record_pending proj 20 dispatch OpenSpec "" "" "$HEAD_SHA"
    dispatch_runs 20 "$(run_json 650 "$HEAD_SHA" completed success 30 10 1 workflow_dispatch)" \
                     "$(run_json 640 "$HEAD_SHA" completed failure 90000 90000 1 workflow_dispatch)"
    single_run 650 "$(run_json 650 "$HEAD_SHA" completed success 30 10 1 workflow_dispatch)"
    ISSUE_LIST_FIXTURE='[{"number":7,"title":"Main CI drift: OpenSpec","body":"x\nAuto-filed by `pipeline-health-cron.sh` (build drift check).","labels":[]},
                         {"number":8,"title":"Main CI drift: Lint","body":"Auto-filed by `pipeline-health-cron.sh`","labels":[]}]'

    build_drift_judge proj

    [ "$(cat "$STATE_DIR/closed")" = 7 ]
    [ ! -f "$STATE_DIR/build-drift/pending/proj-20" ]
}

@test "judge: a dispatch that never shows up is dropped after 6h" {
    build_drift_record_pending proj 20 dispatch OpenSpec "" "" "$HEAD_SHA"
    dispatch_runs 20 "$(run_json 640 "$HEAD_SHA" completed failure 90000 90000 1 workflow_dispatch)"
    build_drift_judge proj
    [ -f "$STATE_DIR/build-drift/pending/proj-20" ]

    sed -i "s/^since=.*/since=$(( $(date +%s) - 30000 ))/" "$STATE_DIR/build-drift/pending/proj-20"
    build_drift_judge proj
    [ ! -f "$STATE_DIR/build-drift/pending/proj-20" ]
    [ "$(writes)" -eq 0 ]
}

@test "daily pass: an open drift issue closes once the workflow's newest main run is green" {
    workflow 20 OpenSpec openspec.yml "$PLAIN_CI"
    push_runs 20 "$(run_json 601 "$HEAD_SHA" completed success 3600 3600)"
    all_runs 20 "$(run_json 601 "$HEAD_SHA" completed success 3600 3600)" \
                "$(run_json 600 oldsha completed failure 400000 80000 2)"
    ISSUE_LIST_FIXTURE='[{"number":7,"title":"Main CI drift: OpenSpec","body":"Auto-filed by `pipeline-health-cron.sh` (build drift check).","labels":[]}]'

    check_build_drift proj

    [ "$(cat "$STATE_DIR/closed")" = 7 ]
}

@test "daily pass: an open drift issue stays open while the newest main run is red" {
    workflow 20 OpenSpec openspec.yml "$PLAIN_CI"
    push_runs 20 "$(run_json 600 oldsha completed failure 400000 3600 2)"
    all_runs 20 "$(run_json 601 "$HEAD_SHA" completed success 90000 90000)" \
                "$(run_json 600 oldsha completed failure 400000 3600 2)"
    ISSUE_LIST_FIXTURE='[{"number":7,"title":"Main CI drift: OpenSpec","body":"Auto-filed by `pipeline-health-cron.sh` (build drift check).","labels":[]}]'

    check_build_drift proj

    [ ! -f "$STATE_DIR/closed" ]
}
