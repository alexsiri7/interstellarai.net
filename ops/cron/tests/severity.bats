#!/usr/bin/env bats
# Tests for lib/severity.sh (the severity tier of a no-PR ship outcome, #237).
#
# Run: bunx bats ops/cron/tests/severity.bats

bats_require_minimum_version 1.5.0

setup() {
    unset _SEVERITY_SH
    # shellcheck source=../lib/severity.sh
    source "$(dirname "$BATS_TEST_FILENAME")/../lib/severity.sh"
}

@test "an outcome with no tier, or one that is not 1-3, is tier 2" {
    [ "$(severity_tier '' 'No delivery needed: a false positive.')" = 2 ]
    [ "$(severity_tier 4 'No delivery needed: a false positive.')" = 2 ]
    [ "$(severity_tier act 'No delivery needed: a false positive.')" = 2 ]
}

@test "a declared tier stands for ordinary text" {
    [ "$(severity_tier 1 'No delivery needed: a false positive.')" = 1 ]
    [ "$(severity_tier 3 'No delivery needed: a false positive.')" = 3 ]
}

@test "each tier-3 category raises tier 1 and tier 2 to 3" {
    local text
    for text in \
        'the fix deletes production data' \
        'rewrite the git history to drop the file' \
        'make the repo public' \
        'needs a GDPR answer' \
        'Stripe billing is involved' \
        'rotate the API keys first' \
        'publish to the Play Store'; do
        [ "$(severity_tier 1 "$text")" = 3 ] || { echo "not raised: $text"; return 1; }
        [ "$(severity_tier '' "$text")" = 3 ] || { echo "not raised: $text"; return 1; }
    done
}

@test "the floor never lowers a tier" {
    [ "$(severity_tier 3 'GDPR')" = 3 ]
}

@test "ordinary words near the categories stay below 3" {
    local text
    for text in 'truncate the log line' 'add a schema migration' 'fix the button visibility' \
            'the Claude account ran out' 'illegal state exception' 'rotate the logs'; do
        [ "$(severity_tier 1 "$text")" = 1 ] || { echo "raised: $text"; return 1; }
    done
}

@test "matching ignores case" {
    [ "$(severity_tier 1 'Force-Pushed to main')" = 3 ]
}

@test "severity.sh passes shellcheck" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    cd "$(dirname "$BATS_TEST_FILENAME")/.."
    run shellcheck -x lib/severity.sh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
