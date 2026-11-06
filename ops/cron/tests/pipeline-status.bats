#!/usr/bin/env bats
# The "last sweep" line in ops/bin/pipeline-status, rendered from a state file
# written by sweep-audits.sh's own record_sweep, so the two cannot drift apart
# unnoticed.
#
# Run: bunx bats ops/cron/tests/pipeline-status.bats

setup() {
    TEST_TMP="$(mktemp -d)"
    local cron_dir="$BATS_TEST_DIRNAME/.."
    # shellcheck disable=SC1090
    source <(awk '/^record_sweep\(\)/{p=1} p{print} p && /^}$/{p=0}' "$cron_dir/sweep-audits.sh")
    # shellcheck disable=SC1090
    source <(awk '/^sweep_status\(\)/{p=1} p{print} p && /^}$/{p=0}' "$cron_dir/../bin/pipeline-status")
    # shellcheck disable=SC1090
    source <(awk '/^issue_pickup_status\(\)/{p=1} p{print} p && /^}$/{p=0}' "$cron_dir/../bin/pipeline-status")
    # shellcheck disable=SC1090
    source <(awk '/^ops_review_status\(\)/{p=1} p{print} p && /^}$/{p=0}' "$cron_dir/../bin/pipeline-status")
    unset _ARCHON_DEADLINES_SH DEADLINE_FRESH_SECONDS
    export DEADLINE_STATE_DIR="$TEST_TMP/deadlines" DEADLINE_NOW=1000000
    # shellcheck source=../lib/deadlines.sh
    source "$cron_dir/lib/deadlines.sh"
    unset _LACHESIS_SH
    export LACHESIS_STATE_DIR="$TEST_TMP/lachesis"
    unset LACHESIS_NEXT_STATUS
    # shellcheck source=../lib/lachesis.sh
    source "$cron_dir/lib/lachesis.sh"

    # Read by the extracted functions.
    # shellcheck disable=SC2034
    {
        STATE_DIR="$TEST_TMP"
        SWEEP_STATUS_FILE="$TEST_TMP/last-sweep"
        sweep_name="security"
        repo_name="cosmic-match"
        GREEN="" RED="" DIM="" YELLOW="" RESET=""
    }
    log() { :; }
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "a successful sweep reads OK with its sweep, repo and account" {
    record_sweep ok "" "/home/u/.claude"
    run sweep_status
    [[ "$output" == "OK  security on cosmic-match, "*", account .claude" ]]
}

@test "an auth failure reads FAILED (auth) with no account" {
    record_sweep failed auth ""
    run sweep_status
    [[ "$output" == "FAILED (auth)  security on cosmic-match, "* ]]
    [[ "$output" != *account* ]]
}

@test "a workflow failure reads FAILED (workflow) with the account it ran on" {
    record_sweep failed workflow "/home/u/.claude-secondary"
    run sweep_status
    [[ "$output" == "FAILED (workflow)  security on cosmic-match, "*", account .claude-secondary" ]]
}

@test "the run time is rendered, not left unknown" {
    record_sweep ok "" "/home/u/.claude"
    run sweep_status
    [[ "$output" == *", $(date +%F) "* ]]
}

@test "no state file reads no sweep recorded" {
    run sweep_status
    [ "$output" = "no sweep recorded" ]
}

@test "issue pickup reads FAILING after three ticks in a row could not read next_issue" {
    lachesis_next_record ok
    lachesis_next_record failed
    lachesis_next_record failed
    lachesis_next_record failed
    run issue_pickup_status
    [[ "$output" == "FAILING  Lachesis next_issue could not be read on 3 issue-pickup ticks in a row (last read: $(date +%F) "*") — no issue is picked up" ]]
}

@test "issue pickup reads OK with the last read once next_issue answers" {
    lachesis_next_record failed
    lachesis_next_record ok
    run issue_pickup_status
    [[ "$output" == "OK  next_issue last read $(date +%F) "* ]]
}

@test "issue pickup flags a single failed tick without calling it failing" {
    lachesis_next_record ok
    lachesis_next_record failed
    run issue_pickup_status
    [[ "$output" == "last tick failed  Lachesis next_issue unread on 1 tick(s) in a row  next_issue last read "* ]]
}

@test "issue pickup with no record says so" {
    run issue_pickup_status
    [ "$output" = "no next_issue read recorded" ]
}

@test "ops PRs awaiting review: 0 with no marks, the count and the oldest with some" {
    run ops_review_status
    [ "$output" = 0 ]
    DEADLINE_NOW=$((1000000 - 30 * 3600)) deadline_mark ops-merge interstellarai.net 244 abc archon/x "needs a human merge"
    DEADLINE_NOW=$((1000000 - 2 * 3600)) deadline_mark ops-merge interstellarai.net 245 def archon/y "needs a human merge"
    for f in "$DEADLINE_STATE_DIR"/*; do _deadline_set "$f" last_seen 1000000; done
    run ops_review_status
    [ "$output" = "2 (oldest 30h)" ]
}
