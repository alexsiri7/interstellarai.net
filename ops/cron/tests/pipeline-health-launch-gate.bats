#!/usr/bin/env bats
# pipeline-health-cron.sh: remediation attempts are spent only on launches that
# can run, an escalation gets one late retry, and a red PR asks build drift to
# re-check main.
#
# Annie PR 1483, 2026-11-13: the audit gate went red on new hono advisories;
# check_pr_ci_retry fired archon-assist three times inside a quota pause, archon
# refused all three, the attempts were spent anyway, the PR was escalated and
# never retried, and main (last green before the advisories) was not re-run.
#
# Run: bats ops/cron/tests/pipeline-health-launch-gate.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/launch-gate-$$"
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR/prciretry" "$STATE_DIR/escalated"
    BASE_DIR="$STATE_DIR/repos"; mkdir -p "$BASE_DIR/proj/.git"
    MAX_ATTEMPTS=3
    ESCALATION_RETRY_SECONDS=86400
    TRUST_HELD_LABEL=needs-owner-review
    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    for fn in sha_attempt_decide health_launch_gate check_pr_ci_retry; do
        # shellcheck disable=SC1090
        source <(awk -v fn="^$fn\\(\\)" '$0 ~ fn {p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
    done
    # shellcheck disable=SC1090
    source <(awk '/^HEALTH_LAUNCH_(HELD|CHECKED)=/{print}' "$SCRIPT_FILE")

    log() { echo "$*" >> "$STATE_DIR/log"; }
    notify() { :; }
    file_stuck_issue() { :; }
    trust_filter_prs() { cat; }
    trust_comments_ok() { :; }
    archon_runs_known() { :; }
    archon_branch_running_run() { return 1; }
    ASSIST="$STATE_DIR/assist"; : > "$ASSIST"
    nohup() { printf '%s\n' "$*" >> "$ASSIST"; }
    disown() { :; }
    REQUESTS="$STATE_DIR/requests"; : > "$REQUESTS"
    build_drift_request() { printf '%s|%s|%s\n' "$@" >> "$REQUESTS"; }
    QUOTA_CALLS="$STATE_DIR/quota-calls"; : > "$QUOTA_CALLS"
    QUOTA_HELD=0; GH_FACTORY_HELD=0
    quota_may_launch() { echo x >> "$QUOTA_CALLS"; [ "$QUOTA_HELD" = 0 ]; }
    gh_factory_may_launch() { [ "$GH_FACTORY_HELD" = 0 ]; }

    FAILED_AT="2026-11-13T01:43:51Z"
    PR_LIST='[{"number":1483,"title":"Attach images","headRefName":"archon/task-x","headRefOid":"sha1",
      "author":{"login":"alexsiri7"},"isCrossRepository":false,"labels":[],
      "statusCheckRollup":[
        {"name":"Lint & Typecheck","workflowName":"CI","conclusion":"FAILURE","completedAt":"'"$FAILED_AT"'"},
        {"name":"Test","workflowName":"CI","conclusion":"SUCCESS","completedAt":"'"$FAILED_AT"'"},
        {"name":"unsafe-change","workflowName":"Unsafe change","conclusion":"FAILURE","completedAt":"'"$FAILED_AT"'"},
        {"context":"Cloudflare Pages","state":"FAILURE","conclusion":"FAILURE"}]}]'
    gh() { case "$1 $2" in "pr list") echo "$PR_LIST" ;; *) echo "" ;; esac; }
}

teardown() { rm -rf "$STATE_DIR"; }

@test "a quota pause holds the launch and spends no attempt; the next tick fires attempt 1" {
    QUOTA_HELD=1
    check_pr_ci_retry proj

    [ ! -s "$ASSIST" ]
    [ ! -f "$STATE_DIR/prciretry/proj-pr1483" ]
    grep -q "held: Claude rate limit in effect, no attempt spent" "$STATE_DIR/log"

    # Next tick, quota back.
    QUOTA_HELD=0; HEALTH_LAUNCH_CHECKED=0
    check_pr_ci_retry proj
    [ "$(cat "$STATE_DIR/prciretry/proj-pr1483")" = "sha1:1" ]
    grep -q "PR #1483 has failing CI" "$ASSIST"
}

@test "a blocked factory identity holds the launch too" {
    GH_FACTORY_HELD=1
    check_pr_ci_retry proj
    [ ! -s "$ASSIST" ]
    [ ! -f "$STATE_DIR/prciretry/proj-pr1483" ]
    grep -q "held: factory GitHub identity blocked" "$STATE_DIR/log"
}

@test "the gate is decided once per tick" {
    QUOTA_HELD=1
    health_launch_gate || true
    health_launch_gate || true
    health_launch_gate || true
    [ "$(wc -l < "$QUOTA_CALLS")" -eq 1 ]
}

@test "three pauses in a row no longer escalate the PR" {
    QUOTA_HELD=1
    for _ in 1 2 3 4; do HEALTH_LAUNCH_CHECKED=0; check_pr_ci_retry proj; done
    [ ! -s "$ASSIST" ]
    [ -z "$(ls "$STATE_DIR/escalated")" ]
}

@test "a red PR requests a recheck of each failing workflow, not unsafe-change or status contexts" {
    QUOTA_HELD=1   # requested even while launches are held
    check_pr_ci_retry proj
    [ "$(cat "$REQUESTS")" = "proj|CI|$(date -d "$FAILED_AT" +%s)" ]
}

@test "an escalated SHA gets exactly one more attempt 24h later" {
    local m="$STATE_DIR/prciretry/proj-pr1483"
    echo "sha1:3" > "$m"
    touch -d "25 hours ago" "$STATE_DIR/escalated/proj-pr1483-sha1"

    [ "$(sha_attempt_decide "$m" "$STATE_DIR/escalated" proj-pr1483 sha1)" = "FIRE 4" ]
    [ "$(cat "$m")" = "sha1:4" ]
    [ -f "$STATE_DIR/escalated/proj-pr1483-sha1.retried" ]
    [ "$(sha_attempt_decide "$m" "$STATE_DIR/escalated" proj-pr1483 sha1)" = "SKIP" ]
}

@test "a recent escalation stays backed off" {
    local m="$STATE_DIR/prciretry/proj-pr1483"
    echo "sha1:3" > "$m"
    touch -d "2 hours ago" "$STATE_DIR/escalated/proj-pr1483-sha1"
    [ "$(sha_attempt_decide "$m" "$STATE_DIR/escalated" proj-pr1483 sha1)" = "SKIP" ]
    [ ! -f "$STATE_DIR/escalated/proj-pr1483-sha1.retried" ]
}

@test "the first time the budget runs out still escalates" {
    local m="$STATE_DIR/prciretry/proj-pr1483"
    echo "sha1:3" > "$m"
    [ "$(sha_attempt_decide "$m" "$STATE_DIR/escalated" proj-pr1483 sha1)" = "SKIP_NTFY" ]
}
