#!/usr/bin/env bats
# Unit tests for check_system_maintenance in ops/cron/pipeline-health-cron.sh:
# alert once when the weekly system-maintenance.sh failed or has not run.
#
# Run: bunx bats ops/cron/tests/pipeline-health-system-maintenance.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/system-maintenance-state-$$"
    mkdir -p "$STATE_DIR"
    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"

    log() { echo "$*"; }
    export -f log
    notify() { echo "$1 | $2" > "$NTFY_SENTINEL"; }
    export -f notify

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_system_maintenance\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

teardown() {
    rm -rf "$STATE_DIR"
}

write_status() {  # last_run_age_seconds status failed_csv last_ok_age_seconds
    local now; now=$(date +%s)
    printf 'last_run=%s\nlast_run_status=%s\nlast_run_failed=%s\nlast_ok=%s\n' \
        "$(( now - $1 ))" "$2" "$3" "$(( now - $4 ))" > "$STATE_DIR/system-maintenance-status"
}

@test "fresh successful run: no alert, no marker" {
    write_status 86400 ok "" 86400
    run check_system_maintenance
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_SENTINEL" ]
    [ ! -f "$STATE_DIR/system-maintenance-alerted" ]
}

@test "last run failed alerts once and names the failed steps" {
    write_status 3600 failed "apt,smart:/dev/sdb" $((8 * 86400))
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
    grep -q 'apt,smart:/dev/sdb' "$NTFY_SENTINEL"
    grep -q 'install.sh' "$NTFY_SENTINEL"
    [ -f "$STATE_DIR/system-maintenance-alerted" ]
    rm -f "$NTFY_SENTINEL"
    run check_system_maintenance
    [[ "$output" == *"system-maintenance:"* ]]
    [ ! -f "$NTFY_SENTINEL" ]           # marker suppresses the repeat
}

@test "no successful run for longer than 8 days alerts" {
    write_status $((9 * 86400)) ok "" $((9 * 86400))
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
    [[ "$output" == *"9d ago (limit 8d)"* ]]
}

@test "a successful run 7 days ago is within the limit" {
    write_status $((7 * 86400)) ok "" $((7 * 86400))
    run check_system_maintenance
    [ ! -f "$NTFY_SENTINEL" ]
}

@test "missing status file (never run) alerts" {
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
    [[ "$output" == *"no successful system-maintenance run recorded"* ]]
}

@test "recovery clears the marker" {
    touch "$STATE_DIR/system-maintenance-alerted"
    write_status 60 ok "" 60
    run check_system_maintenance
    [[ "$output" == *"recovered"* ]]
    [ ! -f "$STATE_DIR/system-maintenance-alerted" ]
}
