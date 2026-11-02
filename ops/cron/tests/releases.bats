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
    # A nonexistent path: the real ~/.config/archon-cron/daily-release.env must
    # never leak into these tests.
    export DAILY_RELEASE_OPT_OUT_FILE="$T/no-opt-out.env"
    unset _ARCHON_RELEASES_SH _ARCHON_DEADLINES_SH RELEASE_NOW DAILY_RELEASE_OPT_OUT
    : > "$T/log"; : > "$T/notified"

    log() { echo "$*" >> "$T/log"; }
    notify_checked() { printf '%s|%s\n' "$1" "$2" >> "$T/notified"; return "${NOTIFY_RC:-0}"; }
    : > "$T/gh-calls"
    # A missing fixture file is a failed read. Fixtures are keyed by project
    # only (not owner), so the owner segment is parsed out but otherwise
    # ignored here — RELEASE_OWNER's own test asserts it from the raw call
    # log instead (#248 R3).
    gh() {
        local url="" filter="" a p prev="" reqprefix t
        printf '%s\n' "$*" >> "$T/gh-calls"
        for a in "$@"; do
            case "$a" in repos/*) url="$a" ;; esac
            [ "$prev" = --jq ] && filter="$a"
            prev="$a"
        done
        p="${url#repos/*/}"; p="${p%%/*}"
        case "$url" in
            */git/trees/main*) [ -z "${TREE_FAIL:-}" ] && [ -f "$T/gh/$p/tree" ] || return 1
                               jq -R '{type: "blob", path: .}' "$T/gh/$p/tree" | jq -s '{tree: .}' \
                                 | jq -r "$filter" ;;
            */contents/*) [ -z "${CONTENT_FAIL:-}" ] || return 1
                          a="${url#*/contents/}"; a="${a%%\?*}"
                          base64 "$T/gh/$p/files/$a" 2>/dev/null ;;
            */matching-refs/tags/*)
                # Mirrors GitHub's own matching-refs semantics: only refs
                # whose name literally starts with the requested prefix come
                # back, so a caller that asks with an unstripped glob
                # metacharacter in the prefix (#248 / seam R3) gets nothing.
                reqprefix="${url#*/git/matching-refs/tags/}"
                [ -f "$T/gh/$p/tags" ] || return 1
                while IFS= read -r t; do
                    case "$t" in "refs/tags/$reqprefix"*) printf '%s\n' "$t" ;; esac
                done < "$T/gh/$p/tags"
                ;;
            # compare and runs carry raw API JSON; the real --jq filter runs
            # against it here, same as the tree filter above (#248 / seam R5).
            */compare/*) [ -f "$T/gh/$p/compare" ] || return 1
                         jq -r "$filter" "$T/gh/$p/compare" ;;
            */commits*since=*) cat "$T/gh/$p/since-commits" 2>/dev/null ;;
            */commits*) cat "$T/gh/$p/old-commits" 2>/dev/null ;;
            */actions/workflows/*/runs*) [ -f "$T/gh/$p/runs" ] || return 1
                                         jq -r "$filter" "$T/gh/$p/runs" ;;
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
# compare_fixture <ahead_by> <oldest-iso-or-empty> — raw /compare/... JSON,
# the real --jq filter's input (#248 / seam R5).
compare_fixture() {
    if [ "$1" -eq 0 ] || [ -z "$2" ]; then
        jq -n --argjson a "$1" '{ahead_by: $a, commits: []}'
    else
        jq -n --argjson a "$1" --arg d "$2" \
          '{ahead_by: $a, commits: [range($a) | {commit: {committer: {date: $d}}}]}'
    fi
}
# lagging <project> <ahead> <oldest epoch> — newest tag release-2026-01-01.
lagging() {
    mkdir -p "$T/gh/$1"
    echo refs/tags/release-2025-12-31 > "$T/gh/$1/tags"
    echo refs/tags/release-2026-01-01 >> "$T/gh/$1/tags"
    compare_fixture "$2" "$(iso "$3")" > "$T/gh/$1/compare"
}
marker() { echo "$RELEASE_LAG_STATE_DIR/$1"; }
ntfys() { grep -c '' "$T/notified" || true; }
# last_run <project> <iso-or-empty> — the newest successful dispatch run, raw
# /actions/workflows/.../runs JSON (#248 / seam R5).
last_run() {
    mkdir -p "$T/gh/$1"
    if [ -z "$2" ]; then
        echo '{"workflow_runs": []}' > "$T/gh/$1/runs"
    else
        jq -n --arg d "$2" \
          '{workflow_runs: [{status: "completed", conclusion: "success", created_at: $d}]}' \
          > "$T/gh/$1/runs"
    fi
}
# since_commits <project> <count> <oldest-iso-or-empty> — commits on main
# since a dispatch run, as the production code's own --paginate --slurp
# produces (an array of pages, each page an array of commits) — release_lag_check
# pipes this through the real jq filter directly, no gh --jq (#248 / seam R1).
since_commits() {
    mkdir -p "$T/gh/$1"
    if [ "$2" -eq 0 ]; then
        echo '[[]]' > "$T/gh/$1/since-commits"
    else
        jq -n --argjson n "$2" --arg d "$3" \
          '[[range($n) | {commit: {committer: {date: $d}}}]]' > "$T/gh/$1/since-commits"
    fi
}

# ── release_classify: push detection ─────────────────────────────────────────

@test "a push trigger combining branches: [main] with a tags pattern classifies as push, not tag (#248 R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
name: Release
on:
  push:
    branches: [main]
    tags: ['v*']
jobs: {}
YML
    run release_classify proj
    # The block already hits main on every push, at whatever track that
    # workflow itself picks — a tags pattern in the same block must not
    # upgrade it to an unattended tag-triggered rollout (#248 R1).
    [ "$status" -eq 0 ]
    [ "$output" = "push .github/workflows/release.yml" ]
}

@test "a bare push-to-main release.yml with no tags pattern still releases on push" {
    workflow proj .github/workflows/release.yml <<'YML'
name: Release
on:
  push:
    branches: [main]
jobs: {}
YML
    run release_classify proj
    [ "$status" -eq 0 ]
    [ "$output" = "push .github/workflows/release.yml" ]
}

@test "a catscape-watchface-shaped release.yml (dispatch + push.tags) does not run on push" {
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
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "a push-to-main ci.yml is not a release workflow" {
    workflow proj .github/workflows/ci.yml <<'YML'
on:
  push:
    branches: [main]
YML
    run release_classify proj
    [ "$status" -eq 3 ]
}

@test "bare on: push in release.yaml releases on push" {
    workflow proj .github/workflows/release.yaml <<'YML'
on: push
YML
    run release_classify proj
    [ "$status" -eq 0 ]
    [ "$output" = "push .github/workflows/release.yaml" ]
}

@test "a quoted \"on\": key classifies the same as the bare key (#248 / seam R3)" {
    workflow proj .github/workflows/release.yml <<'YML'
"on":
  push:
    tags: ['v*']
jobs: {}
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "a push limited to develop does not run on push" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches:
      - develop
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "none .github/workflows/release.yml" ]
}

@test "a push with branches-ignore that leaves main in releases on push" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches-ignore: [docs]
YML
    run release_classify proj
    [ "$status" -eq 0 ]
}

@test "a push with branches-ignore listing main does not run on push" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches-ignore:
      - main
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "none .github/workflows/release.yml" ]
}

@test "a push with only a tags-ignore filter never hits main, so it does not run on push (#248 R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    tags-ignore: ['nightly-*']
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "none .github/workflows/release.yml" ]
}

@test "a flow-mapping push with only a tags-ignore filter never hits main either (#248 R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push: {tags-ignore: ['nightly-*']}
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "none .github/workflows/release.yml" ]
}

@test "branches-ignore: ['**'] excludes every branch, so a tags push trigger does not run on push to main (#248 R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches-ignore: ['**']
    tags: ['v*']
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "a branches glob that matches main without being the literal main, * or ** still releases on push (#248 R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches: ['ma*']
YML
    run release_classify proj
    [ "$status" -eq 0 ]
}

@test "a failed tree read is 2" {
    workflow proj .github/workflows/release.yml <<< 'on: push'
    TREE_FAIL=1 run release_classify proj
    [ "$status" -eq 2 ]
}

@test "a failed content read is 2" {
    workflow proj .github/workflows/release.yml <<< 'on: push'
    CONTENT_FAIL=1 run release_classify proj
    [ "$status" -eq 2 ]
}

@test "a tag match already found stops the scan, so a later unreadable file does not abort the classification (#248 R3)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    # No file written for this path — its content read would fail — but it
    # is listed after the tag-pattern file above, and tag is already the top
    # rank, so release_classify must never try to read it.
    echo '.github/workflows/release-extra.yml' >> "$T/gh/proj/tree"
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "a push match already found does not stop the scan, so a later unreadable file still aborts the classification (#248 R5)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches: [main]
YML
    # No file written for this path — its content read would fail — but it
    # is listed after the push-to-main file above. Unlike a tag match (#248
    # R3), a push match does not short-circuit the scan: a later file could
    # still turn out to be the higher-ranked tag-pattern workflow, so
    # guessing wrong here would misroute a real release.
    echo '.github/workflows/release-extra.yml' >> "$T/gh/proj/tree"
    run release_classify proj
    [ "$status" -eq 2 ]
}

@test "a dispatch match already found does not stop the scan, so a later unreadable file still aborts the classification (#248 R5)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    # Same as the push case above: a dispatch match does not short-circuit
    # the scan either, so a later unreadable file still aborts rather than
    # settling for the dispatch match already found (#248 R5).
    echo '.github/workflows/release-extra.yml' >> "$T/gh/proj/tree"
    run release_classify proj
    [ "$status" -eq 2 ]
}

@test "no release*.yml at all is 3, distinct from one that just doesn't run on push" {
    no_workflows proj
    run release_classify proj
    [ "$status" -eq 3 ]
}

@test "release_classify scans every release*.yml file, not just the first" {
    workflow proj .github/workflows/release-notes.yml <<'YML'
on:
  pull_request:
YML
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches: [main]
YML
    run release_classify proj
    [ "$status" -eq 0 ]
    [ "$output" = "push .github/workflows/release.yml" ]
}

@test "RELEASE_OWNER overrides the hardcoded alexsiri7 owner in gh calls (#248 R3)" {
    no_workflows proj
    RELEASE_OWNER=someorg run release_classify proj
    [ "$status" -eq 3 ]
    grep -q 'repos/someorg/proj/git/trees/main' "$T/gh-calls"
    ! grep -q 'repos/alexsiri7/proj' "$T/gh-calls" || false
}

# ── release_classify ─────────────────────────────────────────────────────────

@test "release_classify prefers a push:tags pattern over workflow_dispatch" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
  push:
    tags: ['v*']
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "release_classify reports workflow_dispatch when there is no tags pattern" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "dispatch .github/workflows/release.yml" ]
}

@test "release_classify reports none for a release*.yml with neither shape" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  pull_request:
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "none .github/workflows/release.yml" ]
}

@test "release_classify finds a push file over an earlier dispatch-only one" {
    workflow proj .github/workflows/release-notes.yml <<'YML'
on:
  workflow_dispatch:
YML
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    branches: [main]
YML
    run release_classify proj
    [ "$status" -eq 0 ]
    [ "$output" = "push .github/workflows/release.yml" ]
}

@test "release_classify prefers a tag-pattern file over an earlier, separate push-to-main-only file (#248 R1)" {
    workflow proj .github/workflows/release-notes.yml <<'YML'
on:
  push:
    branches: [main]
YML
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "release_classify prefers a tag-pattern file over an earlier, separate dispatch-only file" {
    workflow proj .github/workflows/release-notes.yml <<'YML'
on:
  workflow_dispatch:
YML
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "release_classify reports workflow_dispatch for the short scalar form, not just the block form (#248 / seam R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on: workflow_dispatch
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "dispatch .github/workflows/release.yml" ]
}

@test "release_classify reports workflow_dispatch for the flow-list form too (#248 / seam R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on: [workflow_dispatch]
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "dispatch .github/workflows/release.yml" ]
}

@test "release_classify reports push for a flow-mapping on: (#248 / seam R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on: {push: {branches: [main]}}
YML
    run release_classify proj
    [ "$status" -eq 0 ]
    [ "$output" = "push .github/workflows/release.yml" ]
}

@test "release_classify reports tag for a flow-mapping on: with a tags pattern (#248 / seam R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on: {push: {tags: [v*]}}
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "release_classify reports dispatch for a flow-mapping on: with only workflow_dispatch (#248 / seam R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on: {workflow_dispatch: {}}
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "dispatch .github/workflows/release.yml" ]
}

@test "release_classify reports tag for a top-level flow-mapping on: spanning multiple lines (#248 R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on: {
  push: { tags: ["v*"] },
  workflow_dispatch: {}
}
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "release_classify reports tag for a block on: with a flow-mapping push: spanning multiple lines (#248 R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push: {
    tags: ["v*"]
  }
  workflow_dispatch:
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "release_classify reports tag for a flow-mapping on: with a bare-scalar tags value (#248 R3)" {
    workflow proj .github/workflows/release.yml <<'YML'
on: {push: {tags: v*}}
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "release_classify reports tag for a block on: with a flow-mapping push: using a bare-scalar tags value (#248 R3)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push: {tags: v*}
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "tag .github/workflows/release.yml v*" ]
}

@test "release_classify reports push for a block-sequence on: (#248 / seam R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  - push
  - workflow_dispatch
YML
    run release_classify proj
    [ "$status" -eq 0 ]
    [ "$output" = "push .github/workflows/release.yml" ]
}

@test "release_classify reports dispatch for a block-sequence on: with only workflow_dispatch (#248 / seam R1)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  - workflow_dispatch
YML
    run release_classify proj
    [ "$status" -eq 1 ]
    [ "$output" = "dispatch .github/workflows/release.yml" ]
}

# ── release_opted_out ────────────────────────────────────────────────────────

@test "release_opted_out matches a listed slug only" {
    DAILY_RELEASE_OPT_OUT="reli kith" release_opted_out kith
    DAILY_RELEASE_OPT_OUT="reli kith" run ! release_opted_out ki
    DAILY_RELEASE_OPT_OUT="reli kith" run ! release_opted_out zoomies
    DAILY_RELEASE_OPT_OUT="" run ! release_opted_out kith
}

@test "DAILY_RELEASE_OPT_OUT_FILE is sourced when present, so the opt-out reaches the scheduled cron's bare environment (#248 / seam R7)" {
    echo 'DAILY_RELEASE_OPT_OUT=kith' > "$T/opt-out.env"
    unset _ARCHON_RELEASES_SH DAILY_RELEASE_OPT_OUT
    export DAILY_RELEASE_OPT_OUT_FILE="$T/opt-out.env"
    source "$CRON_DIR/lib/releases.sh"
    release_opted_out kith
    run ! release_opted_out zoomies
}

@test "DAILY_RELEASE_OPT_OUT_FILE overrides an already-exported DAILY_RELEASE_OPT_OUT, not the other way round (#248 R2)" {
    echo 'DAILY_RELEASE_OPT_OUT=kith' > "$T/opt-out.env"
    unset _ARCHON_RELEASES_SH
    export DAILY_RELEASE_OPT_OUT=zoomies
    export DAILY_RELEASE_OPT_OUT_FILE="$T/opt-out.env"
    source "$CRON_DIR/lib/releases.sh"
    release_opted_out kith
    run ! release_opted_out zoomies
}

# ── release_latest_tag_by_name ───────────────────────────────────────────────

@test "release_latest_tag_by_name picks the double-digit day over the single-digit one" {
    result=$(printf 'v2026.11.1\nv2026.11.2\nv2026.11.9\nv2026.11.10\n' | release_latest_tag_by_name)
    [ "$result" = "v2026.11.10" ]
}

@test "release_latest_tag_by_name picks the later month across a month/day digit-width change" {
    result=$(printf 'v2026.9.30\nv2026.10.1\n' | release_latest_tag_by_name)
    [ "$result" = "v2026.10.1" ]
}

# ── release_tag_for_pattern ──────────────────────────────────────────────────

@test "release_tag_for_pattern splices today's date around the wildcard, no leading zeros" {
    [ "$(release_tag_for_pattern 'v*')" = "v$(date -u +%Y.%-m.%-d)" ]
    [ "$(release_tag_for_pattern 'rel-*-stable')" = "rel-$(date -u +%Y.%-m.%-d)-stable" ]
}

@test "release_tag_for_pattern distributes today's date across a multi-wildcard pattern (#248 / seam R3)" {
    local y m d
    IFS=. read -r y m d <<< "$(date -u +%Y.%-m.%-d)"
    [ "$(release_tag_for_pattern 'v*.*.*')" = "v$y.$m.$d" ]
}

@test "release_tag_for_pattern folds the day into the last of exactly two wildcards, so the tag stays unique per day (#248 R1)" {
    local y m d
    IFS=. read -r y m d <<< "$(date -u +%Y.%-m.%-d)"
    [ "$(release_tag_for_pattern 'v*.*')" = "v$y.$m.$d" ]
    [ "$(release_tag_for_pattern 'v*-*')" = "v$y-$m.$d" ]
}

@test "release_tag_for_pattern separates adjacent wildcards so a year boundary still sorts correctly under sort -V (#248 R2)" {
    date() { if [ "$*" = "-u +%Y.%-m.%-d" ]; then printf '%s\n' "$FAKE_DATE"; else command date "$@"; fi; }
    FAKE_DATE=2026.12.31
    dec31=$(release_tag_for_pattern 'v1.**')
    FAKE_DATE=2027.1.1
    jan1=$(release_tag_for_pattern 'v1.**')
    [ "$dec31" = "v1.2026.12.31" ]
    [ "$jan1" = "v1.2027.1.1" ]
    [ "$(printf '%s\n%s\n' "$dec31" "$jan1" | sort -V | tail -n1)" = "$jan1" ]
}

@test "release_tag_for_pattern returns a literal, wildcard-free pattern unchanged (#248 R3)" {
    [ "$(release_tag_for_pattern 'stable')" = "stable" ]
}

@test "release_tag_for_pattern falls back to the literal prefix plus today's date when a satisfiable bracket-class splice is rejected by git (#248 / seam R2)" {
    [ "$(release_tag_for_pattern 'v[0-9]*')" = "v$(date -u +%Y.%-m.%-d)" ]
}

@test "release_tag_for_pattern fails, printing nothing, when neither candidate satisfies the pattern (#248 / seam R3)" {
    run release_tag_for_pattern 'v?.0'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
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
    compare_fixture 0 "" > "$T/gh/proj/compare"
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

@test "a project with a push-to-main release workflow is tracked by the cron's own fallback tag, same as mode none, and still flags (#248 R1)" {
    lagging proj 3 $((T0 - 50 * 3600))
    workflow proj .github/workflows/release.yml <<< 'on: [push, workflow_dispatch]'
    release_lag_check proj
    [ -f "$(marker proj)" ]
    grep -q 'since release-2026-01-01' "$T/notified"

    compare_fixture 0 "" > "$T/gh/proj/compare"
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    grep -q 'proj — released again' "$T/log"
}

@test "a release.yml with neither a tag nor a dispatch trigger (mode none) is tracked by the cron's own fallback tag, same as a project with no release.yml, and clears once released" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  pull_request:
YML
    lagging proj 3 $((T0 - 50 * 3600))
    release_lag_check proj
    [ -f "$(marker proj)" ]
    grep -q 'since release-2026-01-01' "$T/notified"

    compare_fixture 0 "" > "$T/gh/proj/compare"
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    grep -q 'proj — released again' "$T/log"
}

@test "a project with its own non-push release workflow stays flagged after the cron's own fallback tag clears ahead_by" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
  push:
    tags: ['v*']
YML
    # The cron's own daily fallback tag, sitting right at head: ahead_by 0
    # against it, which must NOT be read as "released" for this project.
    echo refs/tags/release-2026-01-01 > "$T/gh/proj/tags"
    compare_fixture 0 "$(iso $((T0 - 50 * 3600)))" > "$T/gh/proj/compare"
    echo 1 > "$T/gh/proj/old-commits"
    # No matching v* tag exists and no successful run on main either (#248
    # R2's fallback finds no evidence here, same as before that fallback
    # existed).
    last_run proj ""
    release_lag_check proj
    [ -f "$(marker proj)" ]
    grep -q 'not released since the repo started' "$T/notified"
}

@test "a tag-pattern release workflow clears against its own matching tag, not the cron's fallback" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    printf 'refs/tags/release-2026-01-01\nrefs/tags/v2026-10-31\n' > "$T/gh/proj/tags"
    compare_fixture 0 "" > "$T/gh/proj/compare"
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "a tag-pattern release workflow flags using its own matching tag's lag" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    printf 'refs/tags/release-2026-01-01\nrefs/tags/v2026-09-01\n' > "$T/gh/proj/tags"
    compare_fixture 4 "$(iso $((T0 - 50 * 3600)))" > "$T/gh/proj/compare"
    release_lag_check proj
    [ -f "$(marker proj)" ]
    grep -q 'since v2026-09-01' "$T/notified"
}

@test "a tag pattern using '?' matches via bash's own glob, agreeing with git's (#248 / seam R4)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v?.0']
YML
    printf 'refs/tags/release-2026-01-01\nrefs/tags/v1.0\n' > "$T/gh/proj/tags"
    # If the match against v1.0 failed, tag would resolve empty and fall
    # through to the no-tag branch, which would read this as an old commit
    # and flag — exactly the permanent false positive #248 R4 describes.
    echo 1 > "$T/gh/proj/old-commits"
    compare_fixture 0 "" > "$T/gh/proj/compare"
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "a tag pattern using a bracket class also matches via bash's own glob (#248 / seam R4)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v[0-9].0']
YML
    printf 'refs/tags/release-2026-01-01\nrefs/tags/v3.0\n' > "$T/gh/proj/tags"
    echo 1 > "$T/gh/proj/old-commits"
    compare_fixture 0 "" > "$T/gh/proj/compare"
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "a tag-mode release workflow with no matching tag but a fresh successful run on main does not flag (#248 R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
  push:
    tags: ['v*']
YML
    : > "$T/gh/proj/tags"
    last_run proj "$(iso $((T0 - 1 * 3600)))"
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "a tag-mode release workflow with no matching tag falls back to commits since its newest run (#248 R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
  push:
    tags: ['v*']
YML
    : > "$T/gh/proj/tags"
    last_run proj "$(iso $((T0 - 100 * 3600)))"
    since_commits proj 2 "$(iso $((T0 - 50 * 3600)))"
    release_lag_check proj
    [ -f "$(marker proj)" ]
    grep -q "since $(iso $((T0 - 100 * 3600)))" "$T/notified"
}

@test "a tag-mode release workflow's runs read failing, with no matching tag, leaves no marker (#248 R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
  push:
    tags: ['v*']
YML
    : > "$T/gh/proj/tags"
    # last_run is never called, so $T/gh/proj/runs is absent and the gh stub
    # fails this read the same way it fails any other missing fixture.
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "a dispatch-only release workflow clears when its newest successful run is fresh" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    last_run proj "$(iso $((T0 - 1 * 3600)))"
    since_commits proj 0 ""
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "a dispatch-only release workflow's lag clears once a run supersedes the fallback commit-age flag" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    last_run proj ""
    echo 1 > "$T/gh/proj/old-commits"
    release_lag_check proj
    [ -f "$(marker proj)" ]
    grep -q 'not released since the repo started' "$T/notified"

    last_run proj "$(iso $((T0 - 1 * 3600)))"
    since_commits proj 0 ""
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
}

@test "a dispatch-only release workflow flags using commits since its newest run" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    last_run proj "$(iso $((T0 - 100 * 3600)))"
    since_commits proj 2 "$(iso $((T0 - 50 * 3600)))"
    release_lag_check proj
    [ -f "$(marker proj)" ]
    grep -q "since $(iso $((T0 - 100 * 3600)))" "$T/notified"
}

@test "a dispatch-only release workflow's runs read failing leaves no marker (#248 / seam R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    # last_run is never called, so $T/gh/proj/runs is absent and the gh stub
    # fails this read the same way it fails any other missing fixture.
    release_lag_check proj
    [ ! -e "$(marker proj)" ]
    [ "$(ntfys)" = 0 ]
}

@test "a dispatch-only release workflow's since-commits read failing leaves an existing marker untouched (#248 R3)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    last_run proj "$(iso $((T0 - 100 * 3600)))"
    since_commits proj 2 "$(iso $((T0 - 50 * 3600)))"
    release_lag_check proj
    before=$(cat "$(marker proj)")
    # The run lookup still succeeds (last_run's fixture is untouched); only
    # the second read — commits since that run — fails this time.
    rm "$T/gh/proj/since-commits"
    export RELEASE_NOW=$((T0 + 1800))
    release_lag_check proj
    [ "$(cat "$(marker proj)")" = "$before" ]
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

# ── release_lag_check: unreadable release workflows (#248 R1) ────────────────

@test "a read failure under 48h old does not ntfy, but one over 48h does, once per episode" {
    TREE_FAIL=1 release_lag_check proj
    [ "$(ntfys)" = 0 ]
    [ "$(deadline_get "$(marker proj).unreadable" since)" = "$T0" ]

    export RELEASE_NOW=$((T0 + 47 * 3600))
    TREE_FAIL=1 release_lag_check proj
    [ "$(ntfys)" = 0 ]

    export RELEASE_NOW=$((T0 + 50 * 3600))
    TREE_FAIL=1 release_lag_check proj
    [ "$(ntfys)" = 1 ]
    grep -q '^Release workflow unreadable: proj|proj: could not read its release workflow' "$T/notified"
    [ "$(deadline_get "$(marker proj).unreadable" notified)" = "$((T0 + 50 * 3600))" ]

    # Still unreadable next tick: no second ntfy for the same episode.
    export RELEASE_NOW=$((T0 + 51 * 3600))
    TREE_FAIL=1 release_lag_check proj
    [ "$(ntfys)" = 1 ]
}

@test "an opted-out project with an unreadable release workflow never ntfys, even past 48h (#248 R2)" {
    DAILY_RELEASE_OPT_OUT=proj TREE_FAIL=1 release_lag_check proj
    [ "$(ntfys)" = 0 ]
    [ ! -e "$(marker proj).unreadable" ]

    export RELEASE_NOW=$((T0 + 50 * 3600))
    DAILY_RELEASE_OPT_OUT=proj TREE_FAIL=1 release_lag_check proj
    [ "$(ntfys)" = 0 ]
    [ ! -e "$(marker proj).unreadable" ]
}

@test "a project that recovers after a long read-error episode clears the unreadable marker" {
    TREE_FAIL=1 release_lag_check proj
    export RELEASE_NOW=$((T0 + 50 * 3600))
    TREE_FAIL=1 release_lag_check proj
    [ "$(ntfys)" = 1 ]
    [ -f "$(marker proj).unreadable" ]

    no_workflows proj; : > "$T/gh/proj/tags"; echo 0 > "$T/gh/proj/old-commits"
    release_lag_check proj
    [ ! -e "$(marker proj).unreadable" ]
    grep -q 'proj — release workflow read recovered' "$T/log"
}

@test "a transient read failure right after a real lag leaves the real marker alone and does not itself ntfy early" {
    lagging proj 3 $((T0 - 50 * 3600)); no_workflows proj
    release_lag_check proj
    [ "$(ntfys)" = 1 ]
    before=$(cat "$(marker proj)")

    export RELEASE_NOW=$((T0 + 1800))
    TREE_FAIL=1 release_lag_check proj
    [ "$(cat "$(marker proj)")" = "$before" ]
    [ "$(ntfys)" = 1 ]
}

# ── release_lag_check: unreadable lag evidence (#248 R2) ─────────────────────
# Distinct from the unreadable-release-workflow marker above: release_mode
# classifies the workflow fine (rc 0/1), but a later gh read release_lag_check
# itself makes — the runs lookup here — keeps failing.

@test "a persistent lag-evidence read failure under 48h does not ntfy, but one over 48h does, once per episode (#248 R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    # last_run is never called, so $T/gh/proj/runs is absent and every tick's
    # runs read fails the same way the dispatch-only "no marker" test does.
    release_lag_check proj
    [ "$(ntfys)" = 0 ]
    [ "$(deadline_get "$(marker proj).evidence-unreadable" since)" = "$T0" ]

    export RELEASE_NOW=$((T0 + 47 * 3600))
    release_lag_check proj
    [ "$(ntfys)" = 0 ]

    export RELEASE_NOW=$((T0 + 50 * 3600))
    release_lag_check proj
    [ "$(ntfys)" = 1 ]
    grep -q '^Release lag evidence unreadable: proj|proj: could not read the GitHub evidence' "$T/notified"
    [ "$(deadline_get "$(marker proj).evidence-unreadable" notified)" = "$((T0 + 50 * 3600))" ]

    # Still unreadable next tick: no second ntfy for the same episode.
    export RELEASE_NOW=$((T0 + 51 * 3600))
    release_lag_check proj
    [ "$(ntfys)" = 1 ]
}

@test "an opted-out project with persistently unreadable lag evidence never ntfys, even past 48h (#248 R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    DAILY_RELEASE_OPT_OUT=proj release_lag_check proj
    [ "$(ntfys)" = 0 ]
    [ ! -e "$(marker proj).evidence-unreadable" ]

    export RELEASE_NOW=$((T0 + 50 * 3600))
    DAILY_RELEASE_OPT_OUT=proj release_lag_check proj
    [ "$(ntfys)" = 0 ]
    [ ! -e "$(marker proj).evidence-unreadable" ]
}

@test "a project that recovers after a long lag-evidence read-error episode clears the evidence-unreadable marker (#248 R2)" {
    workflow proj .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    release_lag_check proj
    export RELEASE_NOW=$((T0 + 50 * 3600))
    release_lag_check proj
    [ "$(ntfys)" = 1 ]
    [ -f "$(marker proj).evidence-unreadable" ]

    last_run proj "$(iso $((T0 + 50 * 3600)))"
    since_commits proj 0 ""
    release_lag_check proj
    [ ! -e "$(marker proj).evidence-unreadable" ]
    grep -q 'proj — lag evidence read recovered' "$T/log"
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
