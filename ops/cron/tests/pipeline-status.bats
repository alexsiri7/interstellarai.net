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

@test "the real script shows and clears the unreleased row and footer (#248 R6)" {
    local cron_dir="$BATS_TEST_DIRNAME/.."
    local pipeline_status="$cron_dir/../bin/pipeline-status"

    export HOME="$TEST_TMP/home"
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api rate_limit"*) echo '{"resources":{"graphql":{"limit":5000,"remaining":4000,"reset":0},"core":{"limit":5000}}}' ;;
  *) exit 1 ;;
esac
EOF
    chmod +x "$HOME/.local/bin/gh"

    export RELEASE_LAG_STATE_DIR="$TEST_TMP/unreleased" DEADLINE_STATE_DIR="$TEST_TMP/deadlines"
    export STALL_STATE_DIR="$TEST_TMP/stalled" LACHESIS_STATE_DIR="$TEST_TMP/lachesis"
    export SWEEP_STATUS_FILE="$TEST_TMP/no-sweep"

    mkdir -p "$RELEASE_LAG_STATE_DIR"
    printf 'since=1700000000\ntag=release-2026-01-01\nahead=3\noldest=2026-01-01T00:00:00Z\nnotified=1700000000\n' \
        > "$RELEASE_LAG_STATE_DIR/test-project"

    run "$pipeline_status" test-project
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNRELEASED: 3 commit(s) since release-2026-01-01"* ]]
    [[ "$output" == *"At least one repo has main commits unreleased for 48h"* ]]

    rm -f "$RELEASE_LAG_STATE_DIR/test-project"
    run "$pipeline_status" test-project
    [ "$status" -eq 0 ]
    [[ "$output" != *"UNRELEASED:"* ]]
    [[ "$output" != *"unreleased for 48h"* ]]
}

@test "with no argv, a duplicated project slug in archon-projects.txt is deduped, not shown twice (#248 R2)" {
    local cron_dir="$BATS_TEST_DIRNAME/.."
    local pipeline_status="$cron_dir/../bin/pipeline-status"

    export HOME="$TEST_TMP/home"
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api rate_limit"*) echo '{"resources":{"graphql":{"limit":5000,"remaining":4000,"reset":0},"core":{"limit":5000}}}' ;;
  *) exit 1 ;;
esac
EOF
    chmod +x "$HOME/.local/bin/gh"

    export RELEASE_LAG_STATE_DIR="$TEST_TMP/unreleased" DEADLINE_STATE_DIR="$TEST_TMP/deadlines"
    export STALL_STATE_DIR="$TEST_TMP/stalled" LACHESIS_STATE_DIR="$TEST_TMP/lachesis"
    export SWEEP_STATUS_FILE="$TEST_TMP/no-sweep"
    export ARCHON_PROJECTS_FILE="$TEST_TMP/projects.txt"
    printf 'test-project\ntest-project\n' > "$ARCHON_PROJECTS_FILE"

    run "$pipeline_status"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c '^test-project ')" -eq 1 ]
}

@test "with no argv, a missing archon-projects.txt exits loudly instead of rendering an empty dashboard (#248 R2)" {
    local cron_dir="$BATS_TEST_DIRNAME/.."
    local pipeline_status="$cron_dir/../bin/pipeline-status"

    export HOME="$TEST_TMP/home"
    mkdir -p "$HOME/.local/bin"
    export RELEASE_LAG_STATE_DIR="$TEST_TMP/unreleased" DEADLINE_STATE_DIR="$TEST_TMP/deadlines"
    export STALL_STATE_DIR="$TEST_TMP/stalled" LACHESIS_STATE_DIR="$TEST_TMP/lachesis"
    export SWEEP_STATUS_FILE="$TEST_TMP/no-sweep"
    export ARCHON_PROJECTS_FILE="$TEST_TMP/no-such-projects.txt"

    run "$pipeline_status"
    [ "$status" -eq 1 ]
    [[ "$output" == *"archon-projects: file not found"* ]]
}
