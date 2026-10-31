#!/usr/bin/env bats
# Tests for lib/releases.sh: which projects daily-release-cron.sh leaves alone
# (the opt-out, a release workflow that runs on push to main) and the 48h
# unreleased flag pipeline-health raises and pipeline-status shows.
#
# The library is sourced directly with gh, log and notify_checked stubbed as
# shell functions. gh answers from files under $T/gh/<project>/; the tree
# query runs the lib's own --jq filter over every path in tree. RELEASE_NOW
# drives the clock.
#
# Run: npx bats@1.13.0 ops/cron/tests/releases.bats

bats_require_minimum_version 1.5.0

setup() {
    T="$BATS_TMPDIR/releases-$$"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    mkdir -p "$T/gh"
    export RELEASE_LAG_STATE_DIR="$T/unreleased" DEADLINE_STATE_DIR="$T/deadlines"
    unset _ARCHON_RELEASES_SH _ARCHON_DEADLINES_SH RELEASE_NOW DAILY_RELEASE_OPT_OUT
    : > "$T/log"; : > "$T/notified"

    log() { echo "$*" >> "$T/log"; }
    notify_checked() { printf '%s|%s\n' "$1" "$2" >> "$T/notified"; return "${NOTIFY_RC:-0}"; }
    # A missing fixture file is a failed read.
    gh() {
        local url="" filter="" a p prev=""
        for a in "$@"; do
            case "$a" in repos/*) url="$a" ;; esac
            [ "$prev" = --jq ] && filter="$a"
            prev="$a"
        done
        p="${url#repos/alexsiri7/}"; p="${p%%/*}"
        case "$url" in
            */git/trees/main*) [ -z "${TREE_FAIL:-}" ] && [ -f "$T/gh/$p/tree" ] || return 1
                               jq -R '{type: "blob", path: .}' "$T/gh/$p/tree" | jq -s '{tree: .}' \
                                 | jq -r "$filter" ;;
            */contents/*) [ -z "${CONTENT_FAIL:-}" ] || return 1
                          a="${url#*/contents/}"; a="${a%%\?*}"
                          base64 "$T/gh/$p/files/$a" 2>/dev/null ;;
            */matching-refs/*) cat "$T/gh/$p/tags" 2>/dev/null ;;
            */compare/*) cat "$T/gh/$p/compare" 2>/dev/null ;;
            */commits*) cat "$T/gh/$p/old-commits" 2>/dev/null ;;
            *) return 1 ;;
        esac
    }
    # shellcheck source=../lib/releases.sh
    source "$CRON_DIR/lib/releases.sh"
    T0=1800000000
    export RELEASE_NOW=$T0
}

teardown() {
    rm -rf "$T"
}

# workflow <project> <path> — the workflow body on stdin, listed in the tree.
workflow() {
    mkdir -p "$T/gh/$1/files/$(dirname "$2")"
    cat > "$T/gh/$1/files/$2"
    echo "$2" >> "$T/gh/$1/tree"
}
no_workflows() { mkdir -p "$T/gh/$1"; : > "$T/gh/$1/tree"; }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
# lagging <project> <ahead> <oldest epoch> — newest tag release-2026-01-01.
lagging() {
    mkdir -p "$T/gh/$1"
    echo refs/tags/release-2025-12-31 > "$T/gh/$1/tags"
    echo refs/tags/release-2026-01-01 >> "$T/gh/$1/tags"
    echo "$2 $(iso "$3")" > "$T/gh/$1/compare"
}
marker() { echo "$RELEASE_LAG_STATE_DIR/$1"; }
ntfys() { grep -c '' "$T/notified" || true; }

# ── release_push_workflow ────────────────────────────────────────────────────

@test "an un-reminder-shaped release.yml (push to main + tags) releases on push" {
    workflow proj .github/workflows/release.yml <<'YML'
name: Release
on:
  push:
    branches: [main]
    tags: ['v*']
jobs: {}
YML
    run release_push_workflow proj
    [ "$status" -eq 0 ]
    [ "$output" = .github/workflows/release.yml ]
}

@test "a catscape-watchface-shaped release.yml (dispatch + push.tags) does not" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
    inputs:
      track:
        default: internal
  push:
    tags:
      - 'v*'
YML
    run release_push_workflow proj
    [ "$status" -eq 1 ]
}

@test "a push-to-main ci.yml is not a release workflow" {
    workflow proj .github/workflows/ci.yml <<'YML'
on:
  push:
    branches: [main]
YML
    run release_push_workflow proj
    [ "$status" -eq 1 ]
}

@test "bare on: push in release.yaml releases on push" {
    workflow proj .github/workflows/release.yaml <<'YML'
on: push
YML
    run release_push_workflow proj
    [ "$status" -eq 0 ]
    [ "$output" = .github/workflows/release.yaml ]
}

@test "a push limited to develop does not" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches:
      - develop
YML
    run release_push_workflow proj
    [ "$status" -eq 1 ]
}

@test "a push with branches-ignore that leaves main in releases on push" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches-ignore: [docs]
YML
    run release_push_workflow proj
    [ "$status" -eq 0 ]
}

@test "a push with branches-ignore listing main does not" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches-ignore:
      - main
YML
    run release_push_workflow proj
    [ "$status" -eq 1 ]
}

@test "a failed tree read is 2" {
    workflow proj .github/workflows/release.yml <<< 'on: push'
    TREE_FAIL=1 run release_push_workflow proj
    [ "$status" -eq 2 ]
}

@test "a failed content read is 2" {
    workflow proj .github/workflows/release.yml <<< 'on: push'
    CONTENT_FAIL=1 run release_push_workflow proj
    [ "$status" -eq 2 ]
}

# ── release_opted_out ────────────────────────────────────────────────────────

@test "release_opted_out matches a listed slug only" {
    DAILY_RELEASE_OPT_OUT="reli kith" release_opted_out kith
    DAILY_RELEASE_OPT_OUT="reli kith" run ! release_opted_out ki
    DAILY_RELEASE_OPT_OUT="reli kith" run ! release_opted_out zoomies
    DAILY_RELEASE_OPT_OUT="" run ! release_opted_out kith
}

# ── release_lag_check ────────────────────────────────────────────────────────

@test "a lag over 48h writes the marker and sends one ntfy, once per episode" {
    lagging proj 3 $((T0 - 50 * 3600)); no_workflows proj
    release_lag_check proj
    [ -f "$(marker proj)" ]
    [ "$(ntfys)" = 1 ]
    grep -q '^Unreleased: proj|proj: 3 commit(s) on main not released since release-2026-01-01' "$T/notified"
    [ "$(deadline_get "$(marker proj)" notified)" = "$T0" ]

    export RELEASE_NOW=$((T0 + 1800))
    release_lag_check proj
    [ "$(ntfys)" = 1 ]
    [ "$(deadline_get "$(marker proj)" since)" = "$T0" ]
}

@test "ahead_by 0 on a later tick clears the marker" {
    lagging proj 3 $((T0 - 50 * 3600)); no_workflows proj
    release_lag_check proj
    echo "0 " > "$T/gh/proj/compare"
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    grep -q 'proj — released again' "$T/log"
}

@test "the newest release-* tag by name is the last release, whatever order gh lists them in" {
    lagging proj 3 $((T0 - 50 * 3600)); no_workflows proj
    printf 'refs/tags/release-2026-02-01\nrefs/tags/release-2026-01-01\n' > "$T/gh/proj/tags"
    release_lag_check proj
    grep -q 'since release-2026-02-01' "$T/notified"
}

@test "a lag under 48h does not flag" {
    lagging proj 3 $((T0 - 47 * 3600)); no_workflows proj
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "no release tag and a commit older than 48h flags" {
    no_workflows proj; : > "$T/gh/proj/tags"; echo 1 > "$T/gh/proj/old-commits"
    release_lag_check proj
    [ -f "$(marker proj)" ]
    grep -q 'not released since the repo started' "$T/notified"
    [ "$(release_lag_note proj)" = "UNRELEASED: all commit(s) since start, oldest before $(iso $((T0 - 172800)))" ]
}

@test "no release tag and no commit older than 48h does not flag" {
    no_workflows proj; : > "$T/gh/proj/tags"; echo 0 > "$T/gh/proj/old-commits"
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
}

@test "an opted-out project does not flag, and its marker clears" {
    lagging proj 3 $((T0 - 50 * 3600)); no_workflows proj
    release_lag_check proj
    DAILY_RELEASE_OPT_OUT=proj release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 1 ]
}

@test "a project with a push-to-main release workflow does not flag" {
    lagging proj 3 $((T0 - 50 * 3600))
    workflow proj .github/workflows/release.yml <<< 'on: [push, workflow_dispatch]'
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "a failed read leaves an existing marker untouched" {
    lagging proj 3 $((T0 - 50 * 3600)); no_workflows proj
    release_lag_check proj
    before=$(cat "$(marker proj)")
    rm "$T/gh/proj/compare"
    export RELEASE_NOW=$((T0 + 1800))
    release_lag_check proj
    [ "$(cat "$(marker proj)")" = "$before" ]
    rm "$T/gh/proj/tags"
    release_lag_check proj
    [ "$(cat "$(marker proj)")" = "$before" ]
    lagging proj 3 $((T0 - 50 * 3600)); TREE_FAIL=1 release_lag_check proj
    [ "$(cat "$(marker proj)")" = "$before" ]
}

@test "a failed ntfy keeps notified=0, so the next tick retries" {
    lagging proj 3 $((T0 - 50 * 3600)); no_workflows proj
    NOTIFY_RC=1 release_lag_check proj
    [ "$(deadline_get "$(marker proj)" notified)" = 0 ]
    export RELEASE_NOW=$((T0 + 1800))
    release_lag_check proj
    [ "$(ntfys)" = 2 ]
    [ "$(deadline_get "$(marker proj)" notified)" = $((T0 + 1800)) ]
}

# ── release_lag_note ─────────────────────────────────────────────────────────

@test "release_lag_note prints the marker's line, and nothing without one" {
    [ -z "$(release_lag_note proj)" ]
    lagging proj 3 $((T0 - 50 * 3600)); no_workflows proj
    release_lag_check proj
    [ "$(release_lag_note proj)" = "UNRELEASED: 3 commit(s) since release-2026-01-01, oldest $(iso $((T0 - 50 * 3600)))" ]
}

@test "pipeline-status shows an unreleased repo in red" {
    grep -q 'source "$SCRIPT_DIR/../cron/lib/releases.sh"' "$CRON_DIR/../bin/pipeline-status"
    grep -q 'unreleased=$(release_lag_note "$REPO")' "$CRON_DIR/../bin/pipeline-status"
}
