#!/usr/bin/env bats
# Unit tests for check_db_backup in ops/cron/pipeline-health-cron.sh:
# alert once when backup-dbs.sh has not recorded a successful run recently.
#
# Run: bunx bats ops/cron/tests/pipeline-health-db-backup.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/db-backup-state-$$"
    mkdir -p "$STATE_DIR"
    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"

    log() { echo "$*"; }
    export -f log
    notify() { echo "$1 | $2" > "$NTFY_SENTINEL"; }
    export -f notify

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_db_backup\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

teardown() {
    rm -rf "$STATE_DIR"
}

write_status() {  # last_ok_age_seconds status failed_csv
    local now; now=$(date +%s)
    printf 'last_run=%s\nlast_run_status=%s\nlast_run_failed=%s\nlast_ok=%s\n' \
        "$now" "$2" "$3" "$(( now - $1 ))" > "$STATE_DIR/db-backup-status"
}

@test "fresh successful backup: no alert, no marker" {
    write_status 3600 ok ""
    run check_db_backup
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_SENTINEL" ]
    [ ! -f "$STATE_DIR/db-backup-alerted" ]
}

@test "no successful backup for longer than the limit alerts once and names the failed projects" {
    write_status $((8 * 3600)) failed "reli,annie"
    run check_db_backup
    [ -f "$NTFY_SENTINEL" ]
    grep -q 'reli,annie' "$NTFY_SENTINEL"
    [ -f "$STATE_DIR/db-backup-alerted" ]
    rm -f "$NTFY_SENTINEL"
    run check_db_backup
    [[ "$output" == *"db-backup:"* ]]
    [ ! -f "$NTFY_SENTINEL" ]           # marker suppresses the repeat
}

@test "missing status file (backup never verified) alerts" {
    run check_db_backup
    [ -f "$NTFY_SENTINEL" ]
    [[ "$output" == *"no successful DB backup recorded"* ]]
}

@test "a recent failure with a fresh last_ok does not alert (backup-dbs.sh ntfys that itself)" {
    write_status 3600 failed "reli"
    run check_db_backup
    [ ! -f "$NTFY_SENTINEL" ]
}

@test "recovery clears the marker" {
    touch "$STATE_DIR/db-backup-alerted"
    write_status 60 ok ""
    run check_db_backup
    [[ "$output" == *"recovered"* ]]
    [ ! -f "$STATE_DIR/db-backup-alerted" ]
}
