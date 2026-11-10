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
    # shellcheck disable=SC1090
    source <(awk '/^ci_status\(\)/{p=1} p{print} p && /^}$/{p=0}' "$cron_dir/../bin/pipeline-status")
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
        OWNER="alexsiri7"
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

@test "a release tag containing a printf conversion is rendered verbatim, not consumed as a format directive (#248 R4)" {
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
    # git permits "%" in a tag name, and this tag is read verbatim from
    # GitHub, not generated by this cron — a printf format-string bug would
    # drop the "%s" and truncate the rest of the line instead of printing the
    # tag name as written (#248 R4).
    printf 'since=1700000000\ntag=v2026.1%%s25\nahead=3\noldest=2026-01-01T00:00:00Z\nnotified=1700000000\n' \
        > "$RELEASE_LAG_STATE_DIR/test-project"

    run "$pipeline_status" test-project
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNRELEASED: 3 commit(s) since v2026.1%s25, oldest 2026-01-01T00:00:00Z"* ]]
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

@test "ops PRs awaiting review: 0 with no marks, the count and the oldest with some" {
    run ops_review_status
    [ "$output" = 0 ]
    DEADLINE_NOW=$((1000000 - 30 * 3600)) deadline_mark ops-merge interstellarai.net 244 abc archon/x "needs a human merge"
    DEADLINE_NOW=$((1000000 - 2 * 3600)) deadline_mark ops-merge interstellarai.net 245 def archon/y "needs a human merge"
    for f in "$DEADLINE_STATE_DIR"/*; do _deadline_set "$f" last_seen 1000000; done
    run ops_review_status
    [ "$output" = "2 (oldest 30h)" ]
}

# ci_status reads `gh api .../check-runs --jq <filter>`; this stand-in applies
# the filter to $CHECK_RUNS_JSON the way gh would.
gh() {
    local filter=""
    while [ $# -gt 0 ]; do
        [ "$1" = --jq ] && { filter="$2"; break; }
        shift
    done
    jq -r "$filter" <<<"$CHECK_RUNS_JSON"
}

@test "ci_status ignores a cancelled run superseded by a successful rerun of the same check" {
    CHECK_RUNS_JSON='{"check_runs":[
        {"id":1,"name":"unsafe-change-recheck","status":"completed","conclusion":"cancelled"},
        {"id":2,"name":"unsafe-change-recheck","status":"completed","conclusion":"success"},
        {"id":3,"name":"test","status":"completed","conclusion":"success"}]}'
    run ci_status catscape-watchface
    [ "$output" = pass ]
}

@test "ci_status reads fail when the newest run of a check failed" {
    CHECK_RUNS_JSON='{"check_runs":[
        {"id":1,"name":"test","status":"completed","conclusion":"success"},
        {"id":2,"name":"test","status":"completed","conclusion":"failure"},
        {"id":3,"name":"lint","status":"completed","conclusion":"success"}]}'
    run ci_status catscape-watchface
    [ "$output" = fail ]
}

@test "ci_status reads fail when a check's only run is cancelled with no rerun" {
    CHECK_RUNS_JSON='{"check_runs":[
        {"id":1,"name":"unsafe-change-recheck","status":"completed","conclusion":"cancelled"},
        {"id":2,"name":"test","status":"completed","conclusion":"success"}]}'
    run ci_status catscape-watchface
    [ "$output" = fail ]
}
