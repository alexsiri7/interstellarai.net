#!/usr/bin/env bats
# Tests for check_stalled_tool_calls in ops/cron/pipeline-health-cron.sh — the
# watchdog over running archon runs whose tool call stopped making progress
# (issues #243, #293).
#
# Run: bunx bats ops/cron/tests/stalled-tool-calls.bats

bats_require_minimum_version 1.5.0

setup() {
    export STATE_DIR="$BATS_TMPDIR/stalled-$$"
    export MARKER_DIR="$STATE_DIR/stalled-tool-calls"
    mkdir -p "$MARKER_DIR"
    export ARCHON_ARGV="$STATE_DIR/argv"
    export GH_ARGV="$STATE_DIR/gh"
    export NOTIFIED="$STATE_DIR/notified"
    export STALLED_ROWS="$STATE_DIR/rows"
    : > "$STALLED_ROWS"

    export TOOL_CALL_STALL_MAX_SECONDS=7200
    export TOOL_CALL_ABANDON_SECONDS=14400
    export ARCHON_RUNS_CWD=/x

    log() { :; }
    # One line per call — the real body is multi-line and the tests count calls.
    notify() { printf '%s\n' "${*//$'\n'/ }" >> "$NOTIFIED"; }
    archon() { printf '%s\n' "$*" >> "$ARCHON_ARGV"; [ "$3" != "${ABANDON_FAILS:-}" ]; }
    gh() { printf '%s\n' "$*" >> "$GH_ARGV"; [ -z "${GH_FAILS:-}" ]; }
    archon_runs_known() { [ "${RUNS_KNOWN:-1}" = 1 ]; }
    archon_stalled_tool_calls() { cat "$STALLED_ROWS"; }

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(
        awk '/^(check_stalled_tool_calls|abandon_stalled_run)\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE"
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

# run_id, user_message — a row silent for 5h, past the abandon limit
old_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" archon-ship-block /mnt/ext-fast/interstellarai.net "$2" "$(( $(date +%s) - 18000 ))" \
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

@test "a row with no user_message or origin keeps every later field in place" {
    printf '%s\t%s\t\t\t%s\t%s\n' 197afe4f-aaaa archon-ship-block "$(( $(date +%s) - 10800 ))" \
      "deliver__update-pr-body: wait for bats" > "$STALLED_ROWS"
    set -u
    check_stalled_tool_calls
    set +u

    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'archon-ship-block — no user message deliver__update-pr-body: wait for bats: no progress for 3h0m run 197afe4f-aaaa' "$NOTIFIED"
}

@test "a stalled call with no readable progress time alerts once without a duration" {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' 197afe4f-aaaa archon-ship-block /mnt/ext-fast/interstellarai.net "fix #242" -1 \
      "deliver__update-pr-body: wait for bats" > "$STALLED_ROWS"
    check_stalled_tool_calls
    check_stalled_tool_calls

    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'wait for bats: listed as stalled, with no readable lastProgressAt run 197afe4f-aaaa' "$NOTIFIED"
}

@test "two runs stalled in one tick keep their markers apart" {
    stalled_row 197afe4f-aaaa
    stalled_row 197afe4f-bbbb
    check_stalled_tool_calls
    [ "$(wc -l < "$NOTIFIED")" -eq 2 ]

    : > "$STALLED_ROWS"
    stalled_row 197afe4f-bbbb
    check_stalled_tool_calls

    [ ! -e "$MARKER_DIR/alerted-197afe4f-aaaa" ]
    [ -e "$MARKER_DIR/alerted-197afe4f-bbbb" ]
    [ "$(wc -l < "$NOTIFIED")" -eq 2 ]
}

@test "a call silent past the abandon limit ends the run and says so on the issue" {
    old_row 197afe4f-aaaa "fix #242"
    check_stalled_tool_calls

    [ "$(cat "$ARCHON_ARGV")" = "workflow abandon 197afe4f-aaaa --cwd /x" ]
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'Archon run ended: interstellarai.net' "$NOTIFIED"
    grep -q '^api -X POST repos/alexsiri7/interstellarai.net/issues/242/comments -f body=Ended archon run `197afe4f-aaaa`' "$GH_ARGV"
    grep -q 'no progress for 5h0m; pipeline-health ends a run after 4h without progress' "$GH_ARGV"
    grep -q 'lachesis:automated' "$GH_ARGV"
    ! grep -q 'wait for bats' "$GH_ARGV"
    grep -q 'run 197afe4f-aaaa abandoned; commented on #242' "$NOTIFIED"
}

@test "an already-alerted call is still ended once it passes the abandon limit" {
    stalled_row 197afe4f-aaaa
    check_stalled_tool_calls
    [ -e "$MARKER_DIR/alerted-197afe4f-aaaa" ]

    : > "$STALLED_ROWS"
    old_row 197afe4f-aaaa "fix #242"
    check_stalled_tool_calls

    [ "$(cat "$ARCHON_ARGV")" = "workflow abandon 197afe4f-aaaa --cwd /x" ]
    grep -q 'Archon run ended: interstellarai.net' "$NOTIFIED"
    grep -q 'issues/242/comments' "$GH_ARGV"
}

@test "a comment that fails is named in the run-ended alert" {
    old_row 197afe4f-aaaa "fix #242"
    GH_FAILS=1 check_stalled_tool_calls

    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'run 197afe4f-aaaa abandoned; could not comment on #242 — say so there by hand' "$NOTIFIED"
}

@test "an assist correction names its PR, and the comment goes to that PR" {
    old_row 197afe4f-aaaa "PR #282 on alexsiri7/interstellarai.net is green, fix review #12"
    check_stalled_tool_calls

    grep -q '^api -X POST repos/alexsiri7/interstellarai.net/issues/282/comments ' "$GH_ARGV"
}

@test "a message with no #N is ended without a comment" {
    old_row 197afe4f-aaaa "tidy the docs"
    check_stalled_tool_calls

    grep -q 'workflow abandon 197afe4f-aaaa' "$ARCHON_ARGV"
    grep -q 'Archon run ended' "$NOTIFIED"
    [ ! -e "$GH_ARGV" ]
}

@test "a failed abandon is retried every tick but alerted once" {
    old_row 197afe4f-aaaa "fix #242"
    ABANDON_FAILS=197afe4f-aaaa check_stalled_tool_calls
    ABANDON_FAILS=197afe4f-aaaa check_stalled_tool_calls

    [ "$(grep -c 'workflow abandon 197afe4f-aaaa' "$ARCHON_ARGV")" -eq 2 ]
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'Archon run could not be ended: interstellarai.net' "$NOTIFIED"
    [ ! -e "$GH_ARGV" ]

    : > "$STALLED_ROWS"
    check_stalled_tool_calls
    [ ! -e "$MARKER_DIR/abandon-failed-197afe4f-aaaa" ]
}

@test "an unreadable progress time is alerted, never abandoned" {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' 197afe4f-aaaa archon-ship-block /mnt/ext-fast/interstellarai.net "fix #242" -1 \
      "deliver__update-pr-body: wait for bats" > "$STALLED_ROWS"
    check_stalled_tool_calls

    [ ! -e "$ARCHON_ARGV" ]
    grep -q 'Archon tool call stalled' "$NOTIFIED"
}
