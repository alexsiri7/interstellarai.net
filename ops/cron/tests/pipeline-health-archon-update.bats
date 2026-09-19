#!/usr/bin/env bats
# Unit tests for check_archon_update in ops/cron/pipeline-health-cron.sh:
# alert once when the weekly archon-update.sh failed or has not had a
# successful (no-op or updating) run in 8 days.
#
# Run: bunx bats ops/cron/tests/pipeline-health-archon-update.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/archon-update-state-$$"
    mkdir -p "$STATE_DIR"
    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"

    log() { echo "$*"; }
    export -f log
    notify() { echo "$1 | $2" > "$NTFY_SENTINEL"; }
    export -f notify

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_archon_update\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

teardown() {
    rm -rf "$STATE_DIR"
}

write_status() {  # last_run_age_seconds status failed_step last_ok_age_seconds [outcome]
    local now; now=$(date +%s)
    printf 'last_run=%s\nlast_run_status=%s\nlast_run_failed=%s\nlast_ok=%s\noutcome=%s\ncurrent=v0.10.1\nlatest=v0.11.0\nworktree=\n' \
        "$(( now - $1 ))" "$2" "$3" "$(( now - $4 ))" "${5:-noop}" > "$STATE_DIR/archon-update-status"
}

@test "fresh successful run: no alert, no marker" {
    write_status 86400 ok "" 86400
    run check_archon_update
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_SENTINEL" ]
    [ ! -f "$STATE_DIR/archon-update-alerted" ]
}

@test "last run failed alerts once and names the failed step and the tag" {
    write_status 3600 failed "type-check" 86400 failed
    run check_archon_update
    [ -f "$NTFY_SENTINEL" ]
    grep -q 'failed (type-check) bringing in v0.11.0' "$NTFY_SENTINEL"
    grep -q 'archon-update.sh by hand' "$NTFY_SENTINEL"
    [ -f "$STATE_DIR/archon-update-alerted" ]
    rm -f "$NTFY_SENTINEL"
    run check_archon_update
    [[ "$output" == *"archon-update:"* ]]
    [ ! -f "$NTFY_SENTINEL" ]           # marker suppresses the repeat
}

@test "no successful run for longer than 8 days alerts (a week of deferrals leaves last_ok behind)" {
    write_status 3600 ok "" $((9 * 86400)) deferred
    run check_archon_update
    [ -f "$NTFY_SENTINEL" ]
    [[ "$output" == *"9d ago (limit 8d)"* ]]
}

@test "a successful run 7 days ago is within the limit" {
    write_status $((7 * 86400)) ok "" $((7 * 86400))
    run check_archon_update
    [ ! -f "$NTFY_SENTINEL" ]
}

@test "missing status file (never run) alerts" {
    run check_archon_update
    [ -f "$NTFY_SENTINEL" ]
    [[ "$output" == *"no successful archon-update run recorded"* ]]
}

@test "recovery clears the marker" {
    touch "$STATE_DIR/archon-update-alerted"
    write_status 60 ok "" 60
    run check_archon_update
    [[ "$output" == *"recovered"* ]]
    [ ! -f "$STATE_DIR/archon-update-alerted" ]
}
