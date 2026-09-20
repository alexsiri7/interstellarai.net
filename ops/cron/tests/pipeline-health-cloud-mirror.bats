#!/usr/bin/env bats
# Unit tests for check_cloud_mirror in ops/cron/pipeline-health-cron.sh:
# alert once per episode when cloud-mirror.sh has not recorded a successful
# run within 48h, and at most once a day when the newest Google Takeout
# archive in the mirror is older than 45 days (export stopped / needs
# re-arming at takeout.google.com).
#
# Run: bunx bats ops/cron/tests/pipeline-health-cloud-mirror.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/cloud-mirror-state-$$"
    mkdir -p "$STATE_DIR"
    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"
    export LOG_DIR="/logs"

    log() { echo "$*"; }
    export -f log
    notify() { echo "$1 | $2" >> "$NTFY_SENTINEL"; }
    export -f notify

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_cloud_mirror\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

teardown() {
    rm -rf "$STATE_DIR"
}

write_status() {  # last_ok_age_seconds status failed_csv newest_takeout_age_seconds|zero|omit
    local now; now=$(date +%s)
    {
        printf 'last_run=%s\nlast_run_status=%s\nlast_run_failed=%s\nlast_ok=%s\n' \
            "$now" "$2" "$3" "$(( now - $1 ))"
        case "$4" in
            omit) ;;
            zero) echo "newest_takeout_epoch=0" ;;
            *) echo "newest_takeout_epoch=$(( now - $4 ))" ;;
        esac
    } > "$STATE_DIR/cloud-mirror-status"
}

alerts() { wc -l < "$NTFY_SENTINEL" 2>/dev/null || echo 0; }

@test "fresh mirror and fresh Takeout: no alert, no markers" {
    write_status 3600 ok "" $((10 * 86400))
    run check_cloud_mirror
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_SENTINEL" ]
    [ ! -f "$STATE_DIR/cloud-mirror-alerted" ]
    [ ! -f "$STATE_DIR/cloud-mirror-takeout-alerted" ]
}

@test "no successful mirror for longer than 48h alerts once and names the last failure" {
    write_status $((49 * 3600)) failed "rclone-sync" $((10 * 86400))
    run check_cloud_mirror
    [ -f "$NTFY_SENTINEL" ]
    grep -q '^Cloud mirror stale | last successful cloud mirror 49h ago (limit 48h); last run: failed (rclone-sync)' "$NTFY_SENTINEL"
    grep -q 'cloud-mirror.log' "$NTFY_SENTINEL"
    [ -f "$STATE_DIR/cloud-mirror-alerted" ]
    rm -f "$NTFY_SENTINEL"
    run check_cloud_mirror
    [[ "$output" == *"cloud-mirror:"* ]]
    [ ! -f "$NTFY_SENTINEL" ]           # marker suppresses the repeat
}

@test "missing status file (mirror never ran) alerts for the mirror only — Takeout age is unknown" {
    run check_cloud_mirror
    [ "$(alerts)" -eq 1 ]
    [[ "$output" == *"no successful cloud mirror recorded"* ]]
    grep -q '^Cloud mirror stale' "$NTFY_SENTINEL"
    [ ! -f "$STATE_DIR/cloud-mirror-takeout-alerted" ]
}

@test "a recent failure with a fresh last_ok does not alert (cloud-mirror.sh ntfys that itself)" {
    write_status 3600 failed "corrupt:takeout-x.tgz" $((10 * 86400))
    run check_cloud_mirror
    [ ! -f "$NTFY_SENTINEL" ]
}

@test "recovery clears the mirror marker" {
    touch "$STATE_DIR/cloud-mirror-alerted"
    write_status 60 ok "" $((10 * 86400))
    run check_cloud_mirror
    [[ "$output" == *"recovered"* ]]
    [ ! -f "$STATE_DIR/cloud-mirror-alerted" ]
}

@test "Takeout archive older than 45 days alerts with the re-arm instruction, once a day" {
    write_status 3600 ok "" $((46 * 86400))
    run check_cloud_mirror
    [ "$(alerts)" -eq 1 ]
    grep -q '^Google Takeout export may have stopped | newest Google Takeout archive in the mirror is 46d old (limit 45d)' "$NTFY_SENTINEL"
    grep -q 'takeout.google.com' "$NTFY_SENTINEL"
    grep -q '12-month' "$NTFY_SENTINEL"
    [ -f "$STATE_DIR/cloud-mirror-takeout-alerted" ]
    [ ! -f "$STATE_DIR/cloud-mirror-alerted" ]     # the mirror itself is fine
    run check_cloud_mirror
    [ "$(alerts)" -eq 1 ]                           # same day: suppressed
    [[ "$output" == *"cloud-mirror: newest Google Takeout archive"* ]]
    touch -d '25 hours ago' "$STATE_DIR/cloud-mirror-takeout-alerted"
    run check_cloud_mirror
    [ "$(alerts)" -eq 2 ]                           # next day: alerts again
    [ "$(( $(date +%s) - $(stat -c %Y "$STATE_DIR/cloud-mirror-takeout-alerted") ))" -lt 60 ]
}

@test "no Takeout archive at all in a mirror that has synced alerts too" {
    write_status 3600 ok "" zero
    run check_cloud_mirror
    [ "$(alerts)" -eq 1 ]
    grep -q '^Google Takeout export may have stopped | no Google Takeout archive anywhere in the Drive mirror' "$NTFY_SENTINEL"
}

@test "a fresh Takeout archive clears the Takeout marker" {
    touch "$STATE_DIR/cloud-mirror-takeout-alerted"
    write_status 3600 ok "" $((3 * 86400))
    run check_cloud_mirror
    [[ "$output" == *"Takeout recovered"* ]]
    [ ! -f "$STATE_DIR/cloud-mirror-takeout-alerted" ]
    [ ! -f "$NTFY_SENTINEL" ]
}

@test "stale mirror and stale Takeout are two separate alerts" {
    write_status $((72 * 3600)) ok "" $((60 * 86400))
    run check_cloud_mirror
    [ "$(alerts)" -eq 2 ]
    grep -q '^Cloud mirror stale' "$NTFY_SENTINEL"
    grep -q '^Google Takeout export may have stopped' "$NTFY_SENTINEL"
}

@test "limits are overridable (CLOUD_MIRROR_MAX_AGE_H, CLOUD_MIRROR_TAKEOUT_MAX_AGE_D)" {
    export CLOUD_MIRROR_MAX_AGE_H=1 CLOUD_MIRROR_TAKEOUT_MAX_AGE_D=1
    write_status 7200 ok "" $((2 * 86400))
    run check_cloud_mirror
    [ "$(alerts)" -eq 2 ]
    grep -q '(limit 1h)' "$NTFY_SENTINEL"
    grep -q '(limit 1d)' "$NTFY_SENTINEL"
}
