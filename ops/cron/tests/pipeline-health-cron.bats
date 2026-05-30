#!/usr/bin/env bats
# Unit tests for check_deploy_http in ops/cron/pipeline-health-cron.sh
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

# ── curl "000" regression tests ──────────────────────────────────────────────

@test "check_deploy_http treats curl 000 (connection failure) as deploy-down" {
    # Stub curl to return exactly "000" — what curl -w %{http_code} emits on failure.
    curl() { printf "000"; return 6; }
    export -f curl

    load_check_deploy_http

    run check_deploy_http "test-project"

    # Marker file must be created (deploy-down path taken).
    [ -f "$STATE_DIR/deploy-down-test-project" ]
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
