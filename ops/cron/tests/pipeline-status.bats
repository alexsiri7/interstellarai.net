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

    # Read by the extracted functions.
    # shellcheck disable=SC2034
    {
        STATE_DIR="$TEST_TMP"
        SWEEP_STATUS_FILE="$TEST_TMP/last-sweep"
        sweep_name="security"
        repo_name="cosmic-match"
        GREEN="" RED="" DIM="" RESET=""
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
