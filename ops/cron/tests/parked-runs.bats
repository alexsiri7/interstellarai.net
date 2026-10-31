#!/usr/bin/env bats
# Tests for check_parked_runs in ops/cron/pipeline-health-cron.sh — the
# watchdog over paused archon runs the continuation scheduler has stopped
# answering for (issue #77).
#
# Run: bunx bats ops/cron/tests/parked-runs.bats

bats_require_minimum_version 1.5.0

setup() {
    export STATE_DIR="$BATS_TMPDIR/parked-$$"
    # The lib derives the marker directory from $HOME, never from $STATE_DIR.
    export HOME="$STATE_DIR/home"
    export PARKED_DIR="$HOME/.archon/pipeline-health-state/parked"
    export ARCHON_PARKED_MARKER_DIR="$PARKED_DIR"
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

    # The real workflow-name regex; GitHub and the abandon are stubbed. A PR
    # number in $MERGED_PR reads as merged; the run id in $ABANDON_FAILS cannot
    # be abandoned.
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/merged-reviews.sh"
    export ABANDONED="$STATE_DIR/abandoned"
    review_pr_merged() { [ -n "${MERGED_PR:-}" ] && [[ "$2" == *"#$MERGED_PR"* ]] && echo "$MERGED_PR"; }
    abandon_review() { printf '%s\n' "$*" >> "$ABANDONED"; [ "$3" != "${ABANDON_FAILS:-}" ]; }

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(
        awk '/^check_parked_runs\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE"
    )
}

teardown() {
    rm -rf "$BATS_TMPDIR/parked-$$"
}

# run_id, class, workflow, origin, user_message, deadline_epoch, step, need
parked_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "$2" archon-ship /mnt/ext-fast/un-reminder "fix #361" "$(( $(date +%s) - 7200 ))" \
      "${3:-}" "${4:-}" >> "$PARKED_ROWS"
}

review_row() { # review_row <run_id> <class> <user_message> — a parked archon-review run
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "$2" archon-review /mnt/ext-fast/reli "$3" 0 cycle.attend__ask "Review needs a decision" >> "$PARKED_ROWS"
}

@test "a parked review whose PR has merged is closed, never alerted or resumed" {
    MERGED_PR=1756
    review_row 2d79085e-aaaa attention "review PR #1756"
    review_row 2d79085e-bbbb wait "review PR #1756"
    check_parked_runs

    grep -qx 'reli 1756 2d79085e-aaaa' "$ABANDONED"
    grep -qx 'reli 1756 2d79085e-bbbb' "$ABANDONED"
    [ ! -e "$NOTIFIED" ]
    [ ! -e "$ARCHON_ARGV" ]
    [ ! -e "$PARKED_DIR/alerted-2d79085e-aaaa" ]
}

@test "a parked review of a merged PR that cannot be closed is alerted once" {
    MERGED_PR=1756 ABANDON_FAILS=2d79085e-aaaa
    review_row 2d79085e-aaaa attention "review PR #1756"
    check_parked_runs
    check_parked_runs

    [ "$(wc -l < "$ABANDONED")" -eq 2 ]
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'archon-review (attention at cycle.attend__ask) — review PR #1756' "$NOTIFIED"
}

@test "of two parked reviews of one merged PR, only the one that cannot be closed is alerted" {
    MERGED_PR=1756 ABANDON_FAILS=2d79085e-bbbb
    review_row 2d79085e-aaaa attention "review PR #1756"
    review_row 2d79085e-bbbb attention "review PR #1756"
    check_parked_runs

    [ ! -e "$PARKED_DIR/alerted-2d79085e-aaaa" ]
    [ -e "$PARKED_DIR/alerted-2d79085e-bbbb" ]
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'run 2d79085e-bbbb' "$NOTIFIED"
}

@test "a parked review of an open PR is alerted as before" {
    review_row 2d79085e-aaaa attention "review PR #300"
    check_parked_runs

    [ ! -e "$ABANDONED" ]
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'archon-review (attention at cycle.attend__ask) — review PR #300' "$NOTIFIED"
}

@test "a non-review run naming a merged PR is never closed" {
    MERGED_PR=361
    parked_row 500946af-dddd gate
    check_parked_runs

    [ ! -e "$ABANDONED" ]
    grep -q '500946af-dddd' "$NOTIFIED"
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

@test "a resolved gate the engine never resumed is nudged, then alerted once" {
    parked_row 500946af-eeee resolved
    check_parked_runs

    grep -q 'workflow resume 500946af-eeee --detach' "$ARCHON_ARGV"
    [ ! -e "$NOTIFIED" ]
    # Never an approve/reject/respond — the answer already exists, the resume
    # is what is missing.
    ! grep -qE 'workflow (approve|reject|respond)' "$ARCHON_ARGV"

    check_parked_runs
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q '(resolved)' "$NOTIFIED"
}

@test "a gate is reported to a human and never answered by cron" {
    parked_row 500946af-dddd gate
    check_parked_runs

    grep -q 'gate' "$NOTIFIED"
    grep -q '500946af-dddd' "$NOTIFIED"
    [ ! -e "$ARCHON_ARGV" ]
}

@test "a CI attention row is alerted once with what it needs, never resumed or answered" {
    parked_row 5deb98da-aaaa attention deliver__ci-attention.attention-ci-pause \
      "CI remains non-green for pull request #735: Re-run the failing check, then resume this run."
    check_parked_runs

    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q '(attention at deliver__ci-attention.attention-ci-pause)' "$NOTIFIED"
    grep -q 'Re-run the failing check, then resume this run.' "$NOTIFIED"
    [ ! -e "$ARCHON_ARGV" ]

    check_parked_runs
    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    [ ! -e "$ARCHON_ARGV" ]
}

@test "a CI attention run whose resume failed on a green PR is alerted with that failure" {
    parked_row 5deb98da-aaaa attention deliver__ci-attention.attention-ci-pause \
      "CI remains non-green for pull request #735: Re-run the failing check, then resume this run."
    echo 'PR #735 is green; archon workflow resume 5deb98da-aaaa failed: Error: run is locked' \
      > "$PARKED_DIR/ci-resume-failed-5deb98da-aaaa"
    check_parked_runs

    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'PR #735 is green; archon workflow resume 5deb98da-aaaa failed: Error: run is locked' "$NOTIFIED"
    run ! grep -q 'Re-run the failing check' "$NOTIFIED"
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
    touch "$PARKED_DIR/resumed-500946af-bbbb" "$PARKED_DIR/alerted-500946af-bbbb" \
          "$PARKED_DIR/ci-resume-failed-500946af-bbbb"
    parked_row 500946af-dddd gate
    check_parked_runs

    [ ! -e "$PARKED_DIR/resumed-500946af-bbbb" ]
    [ ! -e "$PARKED_DIR/alerted-500946af-bbbb" ]
    [ ! -e "$PARKED_DIR/ci-resume-failed-500946af-bbbb" ]
    [ -e "$PARKED_DIR/alerted-500946af-dddd" ]
}

@test "a user message with spaces survives into the notification intact" {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 500946af-dddd gate archon-ship \
      /mnt/ext-fast/un-reminder "fix #361 — ship the thing" 0 review-gate "Ship it now?" >> "$PARKED_ROWS"
    check_parked_runs

    grep -q 'fix #361 — ship the thing' "$NOTIFIED"
    grep -q 'un-reminder' "$NOTIFIED"
    grep -q '(gate at review-gate)' "$NOTIFIED"
    grep -q 'Ship it now?' "$NOTIFIED"
}

@test "the real archon_parked_runs row feeds check_parked_runs unchanged" {
    # The only test that crosses the seam: both sides assert the eight-column
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

@test "the real archon_parked_runs row of a day-old CI attention run is alerted, not resumed" {
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/archon-active-runs.sh"
    ARCHON_RUNS_SNAPSHOT="$STATE_DIR/snapshot"
    ARCHON_RUNS_SNAPSHOT_OK=1
    printf 'archon-ship\tpaused\t/mnt/ext-fast/filmduel\tfix #586\t5deb98da-aaaa\tattention\t0\t%s\t%s\t%s\t%s\n' \
      "$(( $(date +%s) - 90000 ))" /w/filmduel/worktrees/archon/task-archon-ship-1 \
      deliver__ci-attention.attention-ci-pause "CI remains non-green for pull request #735." \
      > "$ARCHON_RUNS_SNAPSHOT"

    check_parked_runs

    [ "$(wc -l < "$NOTIFIED")" -eq 1 ]
    grep -q 'archon-ship (attention at deliver__ci-attention.attention-ci-pause) — fix #586' "$NOTIFIED"
    grep -q 'CI remains non-green for pull request #735. run 5deb98da-aaaa' "$NOTIFIED"
    [ ! -e "$ARCHON_ARGV" ]
}
