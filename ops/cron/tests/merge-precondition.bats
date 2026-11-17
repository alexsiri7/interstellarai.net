#!/usr/bin/env bats
# Tests for lib/merge-precondition.sh (does a PR's or issue's text state a
# precondition to meet before it merges, #325).
#
# Run: npx bats@1.13.0 ops/cron/tests/merge-precondition.bats

bats_require_minimum_version 1.5.0

setup() {
    unset _ARCHON_MERGE_PRECONDITION_SH
    # shellcheck source=../lib/merge-precondition.sh
    source "$(dirname "$BATS_TEST_FILENAME")/../lib/merge-precondition.sh"
}

hits() { printf '%s\n' "$1" | merge_precondition_lines; }

@test "reli#1840's body is a hit, quoted line by line without markdown" {
    run hits $'Moves deploys to per-environment tokens.\r\n\r\n**Draft on purpose: do not merge until both environment secrets exist.**\r\n\r\n## Before merging\r\n1. Create a `RAILWAY_PROJECT_TOKEN` for staging and production.'
    [ "$status" -eq 0 ]
    [ "$output" = $'Draft on purpose: do not merge until both environment secrets exist.\nBefore merging' ]
}

@test "each stated form is a hit" {
    local text
    for text in \
        '## ⚠️ Required before merging' \
        '### Before Merge' \
        '## Prerequisite Setup (Operator)' \
        '# Pre-merge checklist' \
        '**Before merging:** set the Railway variable.' \
        '  **Precondition**: the DB backup has run.' \
        "Please don't merge this PR before the owner has rotated it." \
        "Do not merge without the owner's decision."; do
        hits "$text" >/dev/null || { echo "missed: $text"; return 1; }
    done
}

@test "text that only mentions a precondition, or says nothing about one, is no hit" {
    local text
    for text in \
        '## After merging' \
        'This has a precondition we checked in CI.' \
        'Do not merge from here: use the PR.' \
        'Merge before Friday.' \
        '    ## Before merging (indented code)' \
        ''; do
        run ! hits "$text"
        [ -z "$output" ] || { echo "hit: $text"; return 1; }
    done
}

@test "a heading inside a fenced code block is no hit" {
    run ! hits $'Example template:\n```md\n# Prerequisites\n```\n~~~\n## Before merging\n~~~'
}

@test "at most 3 lines, each cut to 200 characters" {
    local long
    long="## Before merging $(printf 'x%.0s' {1..300})"
    run hits "$(printf '%s\n' "$long" '## Prerequisites' '## Precondition' '## Pre-merge')"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${#lines[0]}" -eq 200 ]
    [ "${lines[2]}" = Precondition ]
}
