#!/usr/bin/env bats
# Unit tests for check_restore_test in ops/cron/pipeline-health-cron.sh:
# alert once when restore-test.sh last failed or has not recorded a
# successful run within RESTORE_TEST_MAX_AGE_D days.
#
# Run: bunx bats ops/cron/tests/pipeline-health-restore-test.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/restore-test-state-$$"
    mkdir -p "$STATE_DIR"
    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"

    log() { echo "$*"; }
    export -f log
    notify() { echo "$1 | $2" > "$NTFY_SENTINEL"; }
    export -f notify

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_restore_test\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

teardown() {
    rm -rf "$STATE_DIR"
}

write_status() {  # last_ok_age_seconds status failed_csv
    local now; now=$(date +%s)
    printf 'last_run=%s\nlast_run_status=%s\nlast_run_failed=%s\nlast_ok=%s\nreli=ok /b/reli.sql.gz rows=22\n' \
        "$now" "$2" "$3" "$(( now - $1 ))" > "$STATE_DIR/restore-test-status"
}

@test "fresh successful restore test: no alert, no marker" {
    write_status $((2 * 86400)) ok ""
    run check_restore_test
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_SENTINEL" ]
    [ ! -f "$STATE_DIR/restore-test-alerted" ]
}

@test "a failed last run alerts once, naming the projects, even with a recent last_ok" {
    write_status $((7 * 86400)) failed "kindred"
    run check_restore_test
    [ -f "$NTFY_SENTINEL" ]
    grep -q 'last DB restore test failed (kindred); last success 7d ago' "$NTFY_SENTINEL"
    [ -f "$STATE_DIR/restore-test-alerted" ]
    rm -f "$NTFY_SENTINEL"
    run check_restore_test
    [[ "$output" == *"restore-test:"* ]]
    [ ! -f "$NTFY_SENTINEL" ]           # marker suppresses the repeat
}

@test "no successful run for longer than 8 days alerts" {
    write_status $((9 * 86400)) ok ""
    run check_restore_test
    [ -f "$NTFY_SENTINEL" ]
    grep -q 'last successful DB restore test 9d ago (limit 8d)' "$NTFY_SENTINEL"
}

@test "RESTORE_TEST_MAX_AGE_D widens the limit" {
    write_status $((9 * 86400)) ok ""
    RESTORE_TEST_MAX_AGE_D=15 run check_restore_test
    [ ! -f "$NTFY_SENTINEL" ]
}

@test "missing status file (restore test never ran) alerts" {
    run check_restore_test
    [ -f "$NTFY_SENTINEL" ]
    [[ "$output" == *"no successful DB restore test recorded"* ]]
}

@test "recovery clears the marker" {
    touch "$STATE_DIR/restore-test-alerted"
    write_status 60 ok ""
    run check_restore_test
    [[ "$output" == *"recovered"* ]]
    [ ! -f "$STATE_DIR/restore-test-alerted" ]
}
