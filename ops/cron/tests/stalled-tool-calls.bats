#!/usr/bin/env bats
# Tests for check_stalled_tool_calls in ops/cron/pipeline-health-cron.sh — the
# watchdog over running archon runs whose tool call stopped making progress
# (issue #243).
#
# Run: bunx bats ops/cron/tests/stalled-tool-calls.bats

bats_require_minimum_version 1.5.0

setup() {
    export STATE_DIR="$BATS_TMPDIR/stalled-$$"
    export MARKER_DIR="$STATE_DIR/stalled-tool-calls"
    mkdir -p "$MARKER_DIR"
    export ARCHON_ARGV="$STATE_DIR/argv"
    export NOTIFIED="$STATE_DIR/notified"
    export STALLED_ROWS="$STATE_DIR/rows"
    : > "$STALLED_ROWS"

    export TOOL_CALL_STALL_MAX_SECONDS=7200

    log() { :; }
    # One line per call — the real body is multi-line and the tests count calls.
    notify() { printf '%s\n' "${*//$'\n'/ }" >> "$NOTIFIED"; }
    archon() { printf '%s\n' "$*" >> "$ARCHON_ARGV"; }
    archon_runs_known() { [ "${RUNS_KNOWN:-1}" = 1 ]; }
    archon_stalled_tool_calls() { cat "$STALLED_ROWS"; }

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(
        awk '/^check_stalled_tool_calls\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE"
    )
}

teardown() {
    rm -rf "$BATS_TMPDIR/stalled-$$"
}

# run_id, workflow, origin, user_message, stalled_since_epoch, call label
stalled_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" archon-ship-block /mnt/ext-fast/interstellarai.net "fix #242" "$(( $(date +%s) - 10800 ))" \
      "deliver__update-pr-body: wait for bats" >> "$STALLED_ROWS"
}

@test "a stalled call alerts once, naming the run, and never touches archon" {
    stalled_row 197afe4f-aaaa
    check_stalled_tool_calls

    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'Archon tool call stalled: interstellarai.net archon-ship-block — fix #242' "$NOTIFIED"
    grep -q 'deliver__update-pr-body: wait for bats: no progress for 3h0m' "$NOTIFIED"
    grep -q 'run 197afe4f-aaaa' "$NOTIFIED"
    [ -e "$MARKER_DIR/alerted-197afe4f-aaaa" ]

    check_stalled_tool_calls   # second tick stays quiet
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    [ ! -e "$ARCHON_ARGV" ]
}

@test "a run that recovers drops its marker, and a later stall alerts again" {
    stalled_row 197afe4f-aaaa
    check_stalled_tool_calls

    : > "$STALLED_ROWS"
    check_stalled_tool_calls
    [ ! -e "$MARKER_DIR/alerted-197afe4f-aaaa" ]

    stalled_row 197afe4f-aaaa
    check_stalled_tool_calls
    [ "$(wc -l < "$NOTIFIED")" -eq 2 ]
}

@test "a tick without a run snapshot neither alerts nor drops a marker" {
    touch "$MARKER_DIR/alerted-197afe4f-aaaa"
    stalled_row 197afe4f-bbbb
    RUNS_KNOWN=0 check_stalled_tool_calls

    [ ! -e "$NOTIFIED" ]
    [ -e "$MARKER_DIR/alerted-197afe4f-aaaa" ]
}

@test "the real archon_stalled_tool_calls row feeds check_stalled_tool_calls unchanged" {
    # The only test that crosses the seam: both sides assert the column
    # contract independently, so a reordered column would otherwise pass twice.
    unset -f archon_stalled_tool_calls
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/archon-active-runs.sh"
    ARCHON_RUNS_SNAPSHOT="$STATE_DIR/snapshot"
    ARCHON_RUNS_SNAPSHOT_OK=1
    printf 'archon-ship-block\trunning\t/mnt/ext-fast/interstellarai.net\tfix #242\t197afe4f-aaaa\t\t0\t0\t%s\t\t\t%s\t%s\n' \
      /w/interstellarai.net/worktrees/archon/task-1 "$(( $(date +%s) - 10800 ))" \
      "deliver__update-pr-body: wait for bats" > "$ARCHON_RUNS_SNAPSHOT"

    check_stalled_tool_calls

    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'interstellarai.net archon-ship-block — fix #242 deliver__update-pr-body: wait for bats: no progress for 3h0m run 197afe4f-aaaa' "$NOTIFIED"
}
