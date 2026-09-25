#!/usr/bin/env bats
# Unit tests for pipeline-health-cron.sh
#
# Run: bats ops/cron/tests/pipeline-health-cron.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/state-$$"
    mkdir -p "$STATE_DIR"

    # Stub external dependencies so the function can be sourced standalone.
    log() { :; }
    export -f log

    gh() { :; }
    export -f gh

    sleep() { :; }
    export -f sleep

    # Declare global arrays expected by the functions under test.
    declare -gA DEPLOY_URLS=(
        ["test-project"]="https://test.example.com/healthz"
    )

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR/state-$$"
}

# ── Helper: load only the function under test ────────────────────────────────
# Extract check_deploy_http from the script without executing it.
load_check_deploy_http() {
    # shellcheck disable=SC1090
    source <(
        awk '/^check_deploy_http\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE"
    )
}

# Same extraction for any named function. Only the body is sourced, so each
# test must supply the globals that body reads.
load_fn() {
    # shellcheck disable=SC1090
    source <(awk -v fn="^$1\\(\\)" '$0 ~ fn {p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

# Load the real TRACKED_*_LABELS lists rather than restating them here, so a
# drift in the script is a test failure and not a silently-stale fixture.
load_tracked_labels() {
    # shellcheck disable=SC1090
    source <(awk '/^TRACKED_(HUMAN|ACTIVE)_LABELS=/{print}' "$SCRIPT_FILE")
}

# gh stub shared by the check_main_ci cases. Dispatch on the subcommand, not on
# "$*": the filed issue body quotes `gh run view`, which a whole-argument-list
# match would mistake for a run-view call.
stub_gh_for_main_ci() {
    gh() {
        case "$1 $2" in
            "run list")
                case "$*" in
                    *"--event push"*) echo "$RUNS_FIXTURE" ;;
                    # Unfiltered: the pre-#75 query, which read a red scheduled
                    # run as main CI red.
                    *) echo "$SCHEDULE_FIXTURE" ;;
                esac ;;
            "run view") echo "build" ;;
            "api repos/alexsiri7/test-project/commits/main") echo "$HEAD_SHA_FIXTURE" ;;
            "issue list") echo "${ISSUE_LIST_FIXTURE:-[]}" ;;
            "issue create") touch "$ISSUE_SENTINEL"; echo "https://github.com/alexsiri7/test-project/issues/42" ;;
            *) echo "" ;;
        esac
    }
}

# The launch runs as a background job nothing waits for, so poll for its record.
# `command sleep`: setup() stubs sleep out. $1 is the log name's prefix; the
# path is repo-relative so no argv carries the project's directory.
assert_settled_launch() {
    for _ in $(seq 1 100); do [ -s "$STATE_DIR/nohup-argv" ] && break; command sleep 0.05; done
    grep -qxF "$SCRIPT_DIR/lib/settle-ship-outcome.sh" "$STATE_DIR/nohup-argv"
    grep -qxF "test-project" "$STATE_DIR/nohup-argv"
    grep -qxF "bash" "$STATE_DIR/nohup-argv"
    grep -qxF "42" "$STATE_DIR/nohup-argv"
    grep -qE "^\.archon-logs/$1-issue-42-[0-9-]+\.log\$" "$STATE_DIR/nohup-argv"
}

# Globals and stubs check_main_ci reads that live outside its own body.
setup_main_ci_env() {
    mkdir -p "$STATE_DIR/main-ci" "$STATE_DIR/escalated-main"
    BASE_DIR="$STATE_DIR/repos"
    mkdir -p "$BASE_DIR/test-project/.git"
    MAX_ATTEMPTS=3
    # What `gh api .../commits/main --jq .sha` answers; every RUNS_FIXTURE
    # below is at "aaa" unless the case is about HEAD drifting from the listing.
    HEAD_SHA_FIXTURE="aaa"
    SCHEDULE_FIXTURE='[{"databaseId":9,"conclusion":"failure","headSha":"bbb","workflowName":"Scheduled Run Health Check"}]'
    ISSUE_SENTINEL="$STATE_DIR/issue-created"
    NOTIFY_SENTINEL="$STATE_DIR/notified"
    notify() { touch "$NOTIFY_SENTINEL"; }
    # Set NOTIFY_FAILS=1 to play a failed ntfy delivery.
    notify_checked() { touch "$NOTIFY_SENTINEL"; return "${NOTIFY_FAILS:-0}"; }
    add_to_project() { :; }
    file_stuck_issue() { :; }
    archon() { :; }
    SCRIPT_DIR="$STATE_DIR/scriptdir"
    # Records the settle wrapper's environment and argv; see assert_settled_launch.
    nohup() { printf '%s\n' "$SETTLE_SCRIPT" "$SETTLE_PROJECT" "$@" > "$STATE_DIR/nohup-argv"; }
    disown() { :; }
    load_tracked_labels
    load_fn find_tracked_issue
    load_fn sha_attempt_decide
    load_fn check_main_ci
}

# ── curl "000" regression tests ──────────────────────────────────────────────

@test "check_deploy_http treats curl 000 (connection failure) as deploy-down" {
    # Stub curl to return exactly "000" — what curl -w %{http_code} emits on failure.
    curl() { printf "000"; return 6; }
    export -f curl

    load_check_deploy_http

    # check_deploy_http files only on the second consecutive down tick, so the
    # suspect marker stands in for the first one.
    touch "$STATE_DIR/deploy-suspect-test-project"

    run check_deploy_http "test-project"

    # Marker file must be created (deploy-down path taken).
    [ -f "$STATE_DIR/deploy-down-test-project" ]
}

@test "check_deploy_http does NOT file issue when first probe fails but second succeeds" {
    # Stub curl to fail once then succeed on the second call.
    # Use STATE_DIR so teardown cleans it up even if an assertion fails.
    stub_file="$STATE_DIR/curl-calls"
    printf '0' > "$stub_file"
    curl() {
        local n; n=$(cat "$stub_file")
        n=$((n + 1)); printf '%s' "$n" > "$stub_file"
        if [ "$n" -eq 1 ]; then
            printf '000'; return 6
        fi
        printf '200'; return 0
    }
    export -f curl
    export stub_file

    load_check_deploy_http

    run check_deploy_http "test-project"

    [ ! -f "$STATE_DIR/deploy-down-test-project" ]
    # stub_file cleaned by teardown — no explicit rm needed
}

@test "check_deploy_http files issue only after all 3 probes fail" {
    # Counter stub to verify curl is called exactly 3 times (all probes attempted).
    # Use STATE_DIR so teardown cleans it up even if an assertion fails.
    stub_file="$STATE_DIR/curl-calls3"
    printf '0' > "$stub_file"
    curl() {
        local n; n=$(cat "$stub_file")
        n=$((n + 1)); printf '%s' "$n" > "$stub_file"
        printf '000'; return 6
    }
    export -f curl
    export stub_file

    load_check_deploy_http

    # Second consecutive down tick — the first only arms the suspect marker.
    touch "$STATE_DIR/deploy-suspect-test-project"

    run check_deploy_http "test-project"

    [ -f "$STATE_DIR/deploy-down-test-project" ]
    # Verify curl was called exactly 3 times (all probes attempted).
    [ "$(cat "$stub_file")" -eq 3 ]
    # stub_file cleaned by teardown — no explicit rm needed
}

@test "check_deploy_http does NOT create marker when curl returns 200" {
    curl() { printf "200"; return 0; }
    export -f curl

    load_check_deploy_http

    run check_deploy_http "test-project"

    [ ! -f "$STATE_DIR/deploy-down-test-project" ]
}

@test "check_deploy_http skips re-filing when marker already exists" {
    curl() { printf "000"; return 6; }
    export -f curl

    load_check_deploy_http

    # Pre-create marker — simulates a previously-filed issue.
    touch "$STATE_DIR/deploy-down-test-project"

    # Sentinel file: if gh is called inside run's subshell, it creates this file.
    local gh_sentinel="$BATS_TMPDIR/gh-called-$$"
    gh() { touch "$gh_sentinel"; }
    export -f gh

    run check_deploy_http "test-project"

    # Marker still present, gh issue create NOT called.
    [ -f "$STATE_DIR/deploy-down-test-project" ]
    [ ! -f "$gh_sentinel" ]
}

@test "check_deploy_http clears marker when deploy recovers (200)" {
    curl() { printf "200"; return 0; }
    export -f curl

    load_check_deploy_http

    # Pre-create marker — simulates a previously-down deploy now recovered.
    touch "$STATE_DIR/deploy-down-test-project"

    run check_deploy_http "test-project"

    # Marker must be removed on recovery.
    [ ! -f "$STATE_DIR/deploy-down-test-project" ]
}

@test "check_deploy_http returns early for unconfigured project" {
    curl() { printf "200"; return 0; }
    export -f curl

    load_check_deploy_http

    run check_deploy_http "no-such-project"

    # No marker created, exit 0.
    [ "$status" -eq 0 ]
    [ ! -f "$STATE_DIR/deploy-down-no-such-project" ]
}

# ── URL map regression tests ─────────────────────────────────────────────────
# Reli's backend (v4) serves nothing at "/" (404); health lives at /healthz.
# Probing the root would file a false "Deploy down" issue every tick.

@test "DEPLOY_URLS probes reli at /healthz, not the site root" {
    # shellcheck disable=SC1090
    source <(awk '/^declare -A DEPLOY_URLS=\(/{p=1} p{print} p && /^\)$/{p=0}' "$SCRIPT_FILE")
    [ "${DEPLOY_URLS[reli]}" = "https://reli.interstellarai.net/healthz" ]
}

@test "STAGING_DEPLOY_URLS probes reli staging at /healthz, not the site root" {
    # shellcheck disable=SC1090
    source <(awk '/^declare -A STAGING_DEPLOY_URLS=\(/{p=1} p{print} p && /^\)$/{p=0}' "$SCRIPT_FILE")
    [ "${STAGING_DEPLOY_URLS[reli]}" = "https://reli-staging.up.railway.app/healthz" ]
}


# ── find_tracked_issue: the #75 dedup predicate ──────────────────────────────
# Relabelling an auto-filed "Main CI" issue `human-needed` used to slip past the
# old two-label guard, refiling a fresh issue every tick (reli #1472–#1474).

stub_gh_issues() {
    gh() { echo "$ISSUE_LIST_FIXTURE"; }
}

@test "find_tracked_issue: a human-needed issue is tracked and active (the #75 refile)" {
    load_tracked_labels
    load_fn find_tracked_issue
    ISSUE_LIST_FIXTURE='[{"number":11,"labels":[{"name":"bug"},{"name":"human-needed"}]}]'
    stub_gh_issues

    run find_tracked_issue "alexsiri7/test-project" "Main CI"

    [ "$output" = "11 active" ]
}

@test "find_tracked_issue: archon:skipped is tracked but stalled" {
    load_tracked_labels
    load_fn find_tracked_issue
    ISSUE_LIST_FIXTURE='[{"number":14,"labels":[{"name":"archon:skipped"}]}]'
    stub_gh_issues

    run find_tracked_issue "alexsiri7/test-project" "Main CI"

    [ "$output" = "14 stalled" ]
}

@test "find_tracked_issue: archon:failed is tracked but stalled" {
    load_tracked_labels
    load_fn find_tracked_issue
    ISSUE_LIST_FIXTURE='[{"number":10,"labels":[{"name":"bug"},{"name":"archon:failed"}]}]'
    stub_gh_issues

    run find_tracked_issue "alexsiri7/test-project" "Main CI"

    [ "$output" = "10 stalled" ]
}

@test "find_tracked_issue: in-progress plus human-needed is active, not stalled" {
    load_tracked_labels
    load_fn find_tracked_issue
    # The operator's own 2026-09-11 workaround shape (reli #1474) — no nag.
    ISSUE_LIST_FIXTURE='[{"number":13,"labels":[{"name":"archon:in-progress"},{"name":"human-needed"}]}]'
    stub_gh_issues

    run find_tracked_issue "alexsiri7/test-project" "Main CI"

    [ "$output" = "13 active" ]
}

@test "find_tracked_issue: an untracked bug-only issue does not suppress detection" {
    load_tracked_labels
    load_fn find_tracked_issue
    ISSUE_LIST_FIXTURE='[{"number":15,"labels":[{"name":"bug"}]}]'
    stub_gh_issues

    run find_tracked_issue "alexsiri7/test-project" "Main CI"

    [ -z "$output" ]
}

@test "find_tracked_issue: no open issues yields nothing" {
    load_tracked_labels
    load_fn find_tracked_issue
    ISSUE_LIST_FIXTURE='[]'
    stub_gh_issues

    run find_tracked_issue "alexsiri7/test-project" "Main CI"

    [ -z "$output" ]
}

# ── check_main_ci run selection ──────────────────────────────────────────────

@test "check_main_ci ignores non-push workflows and clears markers when push CI is green" {
    setup_main_ci_env
    # The #75 regression: push CI is green, but a scheduled workflow is red. Drop
    # the --event push filter and the stub hands back that red schedule run and
    # an issue gets filed.
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"success","headSha":"aaa","workflowName":"CI"},
                   {"databaseId":2,"conclusion":"success","headSha":"aaa","workflowName":"Release"}]'
    stub_gh_for_main_ci
    touch "$STATE_DIR/main-ci/test-project" "$STATE_DIR/main-ci-cooldown-test-project"

    check_main_ci "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ ! -f "$STATE_DIR/main-ci/test-project" ]
    [ ! -f "$STATE_DIR/main-ci-cooldown-test-project" ]
}

# #107: a run that ends with no PR must not leave the issue archon:in-progress.
@test "check_main_ci launches archon-ship through the settle wrapper" {
    setup_main_ci_env
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    stub_gh_for_main_ci

    check_main_ci "test-project"

    [ -f "$ISSUE_SENTINEL" ]
    assert_settled_launch health-ci-fix-aaa
}

@test "check_main_ci sees a red CI masked by a later green Release at the same SHA" {
    setup_main_ci_env
    # Newest-run-wins (the old --limit 1) would read "success" here.
    RUNS_FIXTURE='[{"databaseId":2,"conclusion":"success","headSha":"aaa","workflowName":"Release"},
                   {"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    stub_gh_for_main_ci

    check_main_ci "test-project"

    [ -f "$ISSUE_SENTINEL" ]
}

@test "check_main_ci treats an in-flight run as neither red nor a recovery" {
    setup_main_ci_env
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"","headSha":"aaa","workflowName":"CI"}]'
    stub_gh_for_main_ci
    touch "$STATE_DIR/main-ci/test-project"

    check_main_ci "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ -f "$STATE_DIR/main-ci/test-project" ]
}

@test "check_main_ci judges runs at main HEAD, not the run the listing puts first" {
    setup_main_ci_env
    # cosmic-match#246: the runs endpoint led with a months-old failure. HEAD
    # is green, so this is a recovery, not a red.
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"old","workflowName":"Integration"},
                   {"databaseId":2,"conclusion":"success","headSha":"aaa","workflowName":"Integration"},
                   {"databaseId":3,"conclusion":"success","headSha":"aaa","workflowName":"CI"}]'
    stub_gh_for_main_ci
    touch "$STATE_DIR/main-ci/test-project"

    check_main_ci "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ ! -f "$STATE_DIR/main-ci/test-project" ]
}

@test "check_main_ci does nothing when main HEAD has no listed push run" {
    setup_main_ci_env
    # A HEAD with no run is Check 1b's case: neither red nor a recovery here.
    HEAD_SHA_FIXTURE="ccc"
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    stub_gh_for_main_ci
    touch "$STATE_DIR/main-ci/test-project"

    check_main_ci "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ -f "$STATE_DIR/main-ci/test-project" ]
}

@test "check_main_ci skips the tick when commits/main answers nothing" {
    setup_main_ci_env
    HEAD_SHA_FIXTURE=""
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    stub_gh_for_main_ci
    touch "$STATE_DIR/main-ci/test-project"

    check_main_ci "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ -f "$STATE_DIR/main-ci/test-project" ]
}

# ── check_main_ci 2h cooldown ────────────────────────────────────────────────

@test "check_main_ci holds off inside the 2h cooldown and files once it lapses" {
    setup_main_ci_env
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    stub_gh_for_main_ci

    date +%s > "$STATE_DIR/main-ci-cooldown-test-project"
    check_main_ci "test-project"
    [ ! -f "$ISSUE_SENTINEL" ]

    echo $(( $(date +%s) - 7300 )) > "$STATE_DIR/main-ci-cooldown-test-project"
    check_main_ci "test-project"
    [ -f "$ISSUE_SENTINEL" ]
}

@test "check_main_ci cooldown suppression never consumes the attempt budget" {
    setup_main_ci_env
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    stub_gh_for_main_ci

    # More suppressed ticks than MAX_ATTEMPTS: if the cooldown spent an attempt
    # each time, the budget would be exhausted before it lapses and this SHA
    # would go permanently silent.
    date +%s > "$STATE_DIR/main-ci-cooldown-test-project"
    for _ in 1 2 3 4 5; do
        check_main_ci "test-project"
    done
    [ ! -f "$ISSUE_SENTINEL" ]
    [ ! -f "$STATE_DIR/main-ci/test-project" ]

    echo $(( $(date +%s) - 7300 )) > "$STATE_DIR/main-ci-cooldown-test-project"
    check_main_ci "test-project"
    [ -f "$ISSUE_SENTINEL" ]
}

# ── check_main_ci dedup against a tracked issue ──────────────────────────────

@test "check_main_ci suppresses and alerts once when the open issue is stalled" {
    setup_main_ci_env
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    ISSUE_LIST_FIXTURE='[{"number":10,"labels":[{"name":"bug"},{"name":"archon:failed"}]}]'
    stub_gh_for_main_ci

    check_main_ci "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ -f "$NOTIFY_SENTINEL" ]
    [ -f "$STATE_DIR/escalated-main/test-project-stalled-10" ]

    rm -f "$NOTIFY_SENTINEL"
    check_main_ci "test-project"
    [ ! -f "$NOTIFY_SENTINEL" ]
}

@test "check_main_ci keeps the stalled alert armed when the ntfy fails to send" {
    setup_main_ci_env
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    ISSUE_LIST_FIXTURE='[{"number":10,"labels":[{"name":"bug"},{"name":"archon:failed"}]}]'
    stub_gh_for_main_ci

    NOTIFY_FAILS=1
    check_main_ci "test-project"
    [ ! -f "$STATE_DIR/escalated-main/test-project-stalled-10" ]

    NOTIFY_FAILS=0
    rm -f "$NOTIFY_SENTINEL"
    check_main_ci "test-project"
    [ -f "$NOTIFY_SENTINEL" ]
    [ -f "$STATE_DIR/escalated-main/test-project-stalled-10" ]
}

@test "check_main_ci suppresses silently when archon is working the open issue" {
    setup_main_ci_env
    RUNS_FIXTURE='[{"databaseId":1,"conclusion":"failure","headSha":"aaa","workflowName":"CI"}]'
    ISSUE_LIST_FIXTURE='[{"number":12,"labels":[{"name":"archon:in-progress"}]}]'
    stub_gh_for_main_ci

    check_main_ci "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ ! -f "$NOTIFY_SENTINEL" ]
}

# ── check_scheduled_workflows: operator ntfy only, never archon ──────────────

setup_scheduled_env() {
    mkdir -p "$STATE_DIR/scheduled-health"
    NOTIFY_SENTINEL="$STATE_DIR/notified"
    ISSUE_SENTINEL="$STATE_DIR/issue-created"
    notify() { touch "$NOTIFY_SENTINEL"; }
    notify_checked() { touch "$NOTIFY_SENTINEL"; return "${NOTIFY_FAILS:-0}"; }
    gh() {
        case "$1 $2" in
            "issue create") touch "$ISSUE_SENTINEL" ;;
            *) echo "$RUNS_FIXTURE" ;;
        esac
    }
    load_fn check_scheduled_workflows
}

@test "check_scheduled_workflows notifies on a red scheduled run and files no issue" {
    setup_scheduled_env
    RUNS_FIXTURE='[{"conclusion":"failure","status":"completed","workflowName":"Uptime Monitor","url":"https://x/1"}]'

    check_scheduled_workflows "test-project"

    [ -f "$NOTIFY_SENTINEL" ]
    [ -f "$STATE_DIR/scheduled-health/test-project-Uptime-Monitor" ]
    [ ! -f "$ISSUE_SENTINEL" ]
}

@test "check_scheduled_workflows alerts once per failure episode" {
    setup_scheduled_env
    RUNS_FIXTURE='[{"conclusion":"failure","status":"completed","workflowName":"Uptime Monitor","url":"https://x/1"}]'
    touch "$STATE_DIR/scheduled-health/test-project-Uptime-Monitor"

    check_scheduled_workflows "test-project"

    [ ! -f "$NOTIFY_SENTINEL" ]
}

@test "check_scheduled_workflows clears the marker when the workflow recovers" {
    setup_scheduled_env
    RUNS_FIXTURE='[{"conclusion":"success","status":"completed","workflowName":"Uptime Monitor","url":"https://x/2"}]'
    touch "$STATE_DIR/scheduled-health/test-project-Uptime-Monitor"

    check_scheduled_workflows "test-project"

    [ ! -f "$STATE_DIR/scheduled-health/test-project-Uptime-Monitor" ]
    [ ! -f "$NOTIFY_SENTINEL" ]
}

@test "check_scheduled_workflows judges each workflow by its newest run only" {
    setup_scheduled_env
    # Uptime Monitor's newest run is green; only Disk Monitor is still red.
    RUNS_FIXTURE='[{"conclusion":"success","status":"completed","workflowName":"Uptime Monitor","url":"https://x/3"},
                   {"conclusion":"failure","status":"completed","workflowName":"Disk Monitor","url":"https://x/2"},
                   {"conclusion":"failure","status":"completed","workflowName":"Uptime Monitor","url":"https://x/1"}]'

    check_scheduled_workflows "test-project"

    [ -f "$STATE_DIR/scheduled-health/test-project-Disk-Monitor" ]
    [ ! -f "$STATE_DIR/scheduled-health/test-project-Uptime-Monitor" ]
}

@test "check_scheduled_workflows keeps the episode armed when the ntfy fails to send" {
    setup_scheduled_env
    RUNS_FIXTURE='[{"conclusion":"failure","status":"completed","workflowName":"Uptime Monitor","url":"https://x/1"}]'

    NOTIFY_FAILS=1
    check_scheduled_workflows "test-project"
    [ ! -f "$STATE_DIR/scheduled-health/test-project-Uptime-Monitor" ]

    NOTIFY_FAILS=0
    rm -f "$NOTIFY_SENTINEL"
    check_scheduled_workflows "test-project"
    [ -f "$NOTIFY_SENTINEL" ]
    [ -f "$STATE_DIR/scheduled-health/test-project-Uptime-Monitor" ]
}

# ── check_prod_deploy: judge the deploy at HEAD ─────────────────────────────

# gh stub for check_prod_deploy. The function filters listings with a local
# jq, so run and deployment fixtures are raw gh/API JSON and the real filters
# are under test. commits/main and the deployment status keep an inline --jq,
# so those fixtures are the post-jq answer.
stub_gh_for_prod_deploy() {
    gh() {
        case "$1 $2" in
            "run list")
                case "$*" in
                    *"--commit"*) echo "$HEAD_RUNS_FIXTURE" ;;
                    *) echo "$RUNS_FIXTURE" ;;
                esac ;;
            "api repos/alexsiri7/test-project/commits/main") echo "$HEAD_FIXTURE" ;;
            "api repos/alexsiri7/test-project/deployments?sha="*) echo "$HEAD_DEPLOYMENTS_FIXTURE" ;;
            "api repos/alexsiri7/test-project/deployments?per_page=10") echo "$DEPLOYMENTS_FIXTURE" ;;
            "api repos/alexsiri7/test-project/deployments/"*) echo "$DEPLOY_STATUS_FIXTURE" ;;
            "issue list") echo "" ;;
            "issue create") echo "$*" > "$ISSUE_SENTINEL"; echo "https://github.com/alexsiri7/test-project/issues/42" ;;
            *) echo "" ;;
        esac
    }
}

setup_prod_deploy_env() {
    BASE_DIR="$STATE_DIR/repos"
    mkdir -p "$BASE_DIR/test-project/.git"
    ISSUE_SENTINEL="$STATE_DIR/issue-created"
    archon() { :; }
    SCRIPT_DIR="$STATE_DIR/scriptdir"
    # Records the settle wrapper's environment and argv; see assert_settled_launch.
    nohup() { printf '%s\n' "$SETTLE_SCRIPT" "$SETTLE_PROJECT" "$@" > "$STATE_DIR/nohup-argv"; }
    disown() { :; }
    # HEAD "aaa" is hours old unless a case is about a fresh push.
    HEAD_FIXTURE='{"sha":"aaa","ts":"2026-01-01T00:00:00Z"}'
    # The listing leads with a stale run, which is what filed reli#1512.
    RUNS_FIXTURE='[{"name":"Staging → Production Pipeline","headSha":"old","updatedAt":"2026-08-26T05:16:16Z","url":"https://example.com/runs/1"}]'
    HEAD_RUNS_FIXTURE='[]'
    DEPLOYMENTS_FIXTURE='[]'
    HEAD_DEPLOYMENTS_FIXTURE='[]'
    DEPLOY_STATUS_FIXTURE='success'
    load_fn check_prod_deploy
}

@test "check_prod_deploy judges the deploy at main HEAD, not the run the listing puts first" {
    setup_prod_deploy_env
    HEAD_RUNS_FIXTURE='[{"name":"CI","conclusion":"success","createdAt":"2026-09-16T01:45:16Z","updatedAt":"2026-09-16T01:46:06Z","url":"https://example.com/runs/2"},
                        {"name":"Staging → Production Pipeline","conclusion":"success","createdAt":"2026-09-16T01:46:08Z","updatedAt":"2026-09-16T01:49:29Z","url":"https://example.com/runs/3"}]'
    stub_gh_for_prod_deploy
    touch "$STATE_DIR/prod-deploy-stale-test-project-aaa"

    check_prod_deploy "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ ! -f "$STATE_DIR/prod-deploy-stale-test-project-aaa" ]
}

@test "check_prod_deploy files a queued lag issue when nothing has deployed an old HEAD" {
    setup_prod_deploy_env
    stub_gh_for_prod_deploy

    check_prod_deploy "test-project"

    [ -f "$ISSUE_SENTINEL" ]
    grep -q "Prod deploy lagging main" "$ISSUE_SENTINEL"
    grep -q "archon:queued" "$ISSUE_SENTINEL"
    [ -f "$STATE_DIR/prod-deploy-stale-test-project-aaa" ]
}

@test "check_prod_deploy trusts a production deployment at HEAD when no run lists it" {
    setup_prod_deploy_env
    HEAD_DEPLOYMENTS_FIXTURE='[{"id":7,"sha":"aaa","environment":"production","created_at":"2026-09-16T01:49:26Z"}]'
    stub_gh_for_prod_deploy
    touch "$STATE_DIR/prod-deploy-stale-test-project-aaa"

    check_prod_deploy "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ ! -f "$STATE_DIR/prod-deploy-stale-test-project-aaa" ]
}

@test "check_prod_deploy files an in-progress failure issue for a red run at HEAD" {
    setup_prod_deploy_env
    HEAD_RUNS_FIXTURE='[{"name":"Staging → Production Pipeline","conclusion":"failure","createdAt":"2026-09-16T01:46:08Z","updatedAt":"2026-09-16T01:49:29Z","url":"https://example.com/runs/3"}]'
    stub_gh_for_prod_deploy

    check_prod_deploy "test-project"

    [ -f "$ISSUE_SENTINEL" ]
    grep -q "Prod deploy failed on main" "$ISSUE_SENTINEL"
    grep -q "archon:in-progress" "$ISSUE_SENTINEL"
    [ -f "$STATE_DIR/prod-deploy-failed-test-project-aaa" ]
    assert_settled_launch health-prod-deploy-aaa
}

@test "check_prod_deploy waits on a fresh HEAD that no deploy has reached yet" {
    setup_prod_deploy_env
    HEAD_FIXTURE='{"sha":"aaa","ts":"'"$(date -u -d '-1 minute' '+%Y-%m-%dT%H:%M:%SZ')"'"}'
    stub_gh_for_prod_deploy
    touch "$STATE_DIR/prod-deploy-stale-test-project-zzz"

    check_prod_deploy "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ -f "$STATE_DIR/prod-deploy-stale-test-project-zzz" ]
}

@test "check_prod_deploy waits while the run at HEAD is in flight" {
    setup_prod_deploy_env
    HEAD_RUNS_FIXTURE='[{"name":"Staging → Production Pipeline","conclusion":null,"createdAt":"2026-09-16T01:46:08Z","updatedAt":"2026-09-16T01:46:08Z","url":"https://example.com/runs/3"}]'
    stub_gh_for_prod_deploy
    touch "$STATE_DIR/prod-deploy-stale-test-project-zzz"

    check_prod_deploy "test-project"

    [ ! -f "$ISSUE_SENTINEL" ]
    [ -f "$STATE_DIR/prod-deploy-stale-test-project-zzz" ]
}

# ── check_progress: only work that had a window counts as pending ───────────

stub_gh_for_progress() {
    gh() {
        case "$1 $2" in
            "api repos/alexsiri7/test-project/commits?sha=main&since="*) echo 0 ;;
            "issue list") echo "$ISSUE_LIST_FIXTURE" ;;
            "pr list") echo "${PR_LIST_FIXTURE:-[]}" ;;
            *) echo "" ;;
        esac
    }
}

setup_progress_env() {
    BASE_DIR="$STATE_DIR/repos"
    mkdir -p "$BASE_DIR/archon" "$BASE_DIR/test-project"
    LOG_DIR="$STATE_DIR/logs"                    # the diagnostic's nohup output lands here
    mkdir -p "$LOG_DIR"
    REPOS=("test-project")
    archon() { :; }
    nohup() { :; }
    disown() { :; }
    echo $(( $(date +%s) - 1800 )) > "$STATE_DIR/last-progress-ts"
    STALL_MARKER="$STATE_DIR/last-stall-diagnostic-ts"
    load_fn check_progress
}

@test "check_progress does not count an issue filed after the last tick as pending" {
    setup_progress_env
    # reli#1512: check_prod_deploy filed this seconds before check_progress ran.
    ISSUE_LIST_FIXTURE='[{"createdAt":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'","labels":[{"name":"archon:queued"}]}]'
    stub_gh_for_progress

    check_progress

    [ ! -f "$STALL_MARKER" ]
}

@test "check_progress fires the diagnostic for an issue queued before the last tick" {
    setup_progress_env
    ISSUE_LIST_FIXTURE='[{"createdAt":"2026-01-01T00:00:00Z","labels":[{"name":"archon:queued"}]}]'
    stub_gh_for_progress

    check_progress

    [ -f "$STALL_MARKER" ]
}

@test "check_progress does not count a PR opened after the last tick as pending" {
    setup_progress_env
    ISSUE_LIST_FIXTURE='[]'
    PR_LIST_FIXTURE='[{"createdAt":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'","isDraft":false,"mergeStateStatus":"CLEAN"}]'
    stub_gh_for_progress

    check_progress

    [ ! -f "$STALL_MARKER" ]
}
