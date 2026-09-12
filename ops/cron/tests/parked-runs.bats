#!/usr/bin/env bats
# Tests for check_parked_runs in ops/cron/pipeline-health-cron.sh — the
# watchdog over paused archon runs the continuation scheduler has stopped
# answering for (issue #77).
#
# Run: bunx bats ops/cron/tests/parked-runs.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/parked-$$"
    export PARKED_DIR="$STATE_DIR/parked"
    mkdir -p "$PARKED_DIR"
    export ARCHON_ARGV="$STATE_DIR/argv"
    export NOTIFIED="$STATE_DIR/notified"
    export PARKED_ROWS="$STATE_DIR/rows"
    : > "$PARKED_ROWS"

    export PARKED_WAIT_MAX_SECONDS=1800
    export ARCHON_RUNS_CWD=/mnt/ext-fast/interstellarai.net

    log() { :; }
    # One line per call — the real body is multi-line and the tests count calls.
    notify() { printf '%s\n' "${*//$'\n'/ }" >> "$NOTIFIED"; }
    archon() { printf '%s ' "$@" >> "$ARCHON_ARGV"; printf '\n' >> "$ARCHON_ARGV"; echo '{"ok": true}'; }
    archon_runs_known() { [ "${RUNS_KNOWN:-1}" = 1 ]; }
    archon_parked_runs() { cat "$PARKED_ROWS"; }

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(
        awk '/^check_parked_runs\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE"
    )
}

teardown() {
    rm -rf "$BATS_TMPDIR/parked-$$"
}

# run_id, class, workflow, origin, user_message, deadline_epoch
parked_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "$2" archon-ship /mnt/ext-fast/un-reminder "fix #361" "$(( $(date +%s) - 7200 ))" \
      >> "$PARKED_ROWS"
}

@test "a stale wait is resumed once, without an alert" {
    parked_row 500946af-bbbb wait
    check_parked_runs

    grep -q 'workflow resume 500946af-bbbb --detach' "$ARCHON_ARGV"
    [ -e "$PARKED_DIR/resumed-500946af-bbbb" ]
    [ ! -e "$NOTIFIED" ]
}

@test "a wait still stale after the nudge alerts exactly once" {
    parked_row 500946af-bbbb wait
    check_parked_runs          # resumes
    : > "$ARCHON_ARGV"
    check_parked_runs          # nudge did not take
    [ ! -s "$ARCHON_ARGV" ]
    [ -e "$PARKED_DIR/alerted-500946af-bbbb" ]
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]

    check_parked_runs          # third tick stays quiet
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
}

@test "a gate is reported to a human and never answered by cron" {
    parked_row 500946af-dddd gate
    check_parked_runs

    grep -q 'gate' "$NOTIFIED"
    grep -q '500946af-dddd' "$NOTIFIED"
    [ ! -e "$ARCHON_ARGV" ]
}

@test "an unreadable pause is reported, and no resume is attempted" {
    parked_row 500946af-ffff unreadable
    check_parked_runs

    grep -q 'unreadable' "$NOTIFIED"
    [ ! -e "$ARCHON_ARGV" ]
}

@test "a blind tick neither resumes, alerts, nor drops markers" {
    touch "$PARKED_DIR/resumed-500946af-bbbb"
    parked_row 500946af-bbbb wait
    RUNS_KNOWN=0 check_parked_runs

    [ ! -e "$ARCHON_ARGV" ]
    [ ! -e "$NOTIFIED" ]
    [ -e "$PARKED_DIR/resumed-500946af-bbbb" ]
}

@test "markers for runs no longer parked are dropped, so a re-park starts over" {
    touch "$PARKED_DIR/resumed-500946af-bbbb" "$PARKED_DIR/alerted-500946af-bbbb"
    parked_row 500946af-dddd gate
    check_parked_runs

    [ ! -e "$PARKED_DIR/resumed-500946af-bbbb" ]
    [ ! -e "$PARKED_DIR/alerted-500946af-bbbb" ]
    [ -e "$PARKED_DIR/alerted-500946af-dddd" ]
}

@test "a user message with spaces survives into the notification intact" {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' 500946af-dddd gate archon-ship \
      /mnt/ext-fast/un-reminder "fix #361 — ship the thing" 0 >> "$PARKED_ROWS"
    check_parked_runs

    grep -q 'fix #361 — ship the thing' "$NOTIFIED"
    grep -q 'un-reminder' "$NOTIFIED"
}

@test "the real archon_parked_runs row feeds check_parked_runs unchanged" {
    # The only test that crosses the seam: both sides assert the six-column
    # contract independently, so a reordered column would otherwise pass twice.
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/archon-active-runs.sh"
    ARCHON_RUNS_SNAPSHOT="$STATE_DIR/snapshot"
    ARCHON_RUNS_SNAPSHOT_OK=1
    printf 'archon-ship\tpaused\t/mnt/ext-fast/un-reminder\tfix #361\t500946af-bbbb\twait\t%s\t%s\n' \
      "$(( $(date +%s) - 7200 ))" "$(( $(date +%s) - 7500 ))" > "$ARCHON_RUNS_SNAPSHOT"

    check_parked_runs

    grep -q 'workflow resume 500946af-bbbb --detach' "$ARCHON_ARGV"
    [ -e "$PARKED_DIR/resumed-500946af-bbbb" ]
    [ ! -e "$NOTIFIED" ]
}
