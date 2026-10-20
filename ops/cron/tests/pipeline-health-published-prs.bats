#!/usr/bin/env bats
# Tests for check_published_prs in pipeline-health-cron.sh (#211): alert once
# when a PR a factory ship run published stops resolving.
#
# Run: bats ops/cron/tests/pipeline-health-published-prs.bats

setup() {
    T="$BATS_TMPDIR/published-prs-$$"
    export BASE_DIR="$T/base" STATE_DIR="$T/state"
    LOGDIR="$BASE_DIR/proj.x/.archon-logs"
    mkdir -p "$LOGDIR" "$STATE_DIR" "$T/gh"
    PUBLISHED_PR_WINDOW_DAYS=14 PUBLISHED_PR_MAX=40
    : > "$T/log"; : > "$T/notified"; : > "$T/gh-calls"

    log() { echo "$*" >> "$T/log"; }
    notify_checked() { printf '%s|%s\n' "$1" "$2" >> "$T/notified"; return "${NOTIFY_RC:-0}"; }
    # gh api repos/<repo>/pulls/<n>: $T/gh/<n> holds "404", "500", or nothing
    # (the PR resolves).
    gh() {
        local n="${2##*/}"
        echo "$n" >> "$T/gh-calls"
        case "$(cat "$T/gh/$n" 2>/dev/null)" in
            404) echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; return 1 ;;
            500) echo 'gh: Server Error (HTTP 500)' >&2; return 1 ;;
            *) echo "$n" ;;
        esac
    }

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_published_prs\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

teardown() {
    rm -rf "$T"
}

published() {  # <log name> <pr url> [delivered]
    {
        echo '[outcome] Completed'
        printf '{"delivered":%s,"reason":"delivered","pr_url":"%s","summary":"PR opened"}\n' "${3:-true}" "$2"
    } >> "$LOGDIR/$1"
}

@test "a published PR that answers 404 is alerted once, naming its issue" {
    published cron-issue-174-20261013-101010.log https://github.com/alexsiri7/proj.x/pull/186
    echo 404 > "$T/gh/186"

    check_published_prs proj.x

    [ "$(wc -l < "$T/notified")" -eq 1 ]
    grep -q '^Published PR gone: proj.x|#186 (issue #174) opened by factory ship runs now answer 404' "$T/notified"
    [ -f "$STATE_DIR/published-prs-gone/proj.x-186" ]

    check_published_prs proj.x

    [ "$(wc -l < "$T/notified")" -eq 1 ]
}

@test "a gone PR that resolves again clears its marker" {
    published health-ci-fix-abcd1234-issue-5-20261013-101010.log https://github.com/alexsiri7/proj.x/pull/9
    mkdir -p "$STATE_DIR/published-prs-gone"; touch "$STATE_DIR/published-prs-gone/proj.x-9"

    check_published_prs proj.x

    [ ! -e "$STATE_DIR/published-prs-gone/proj.x-9" ]
    grep -q 'proj.x #9 resolves again' "$T/log"
    [ ! -s "$T/notified" ]
}

@test "a lookup failure other than 404 proves nothing" {
    published cron-issue-1-20261013-101010.log https://github.com/alexsiri7/proj.x/pull/9
    echo 500 > "$T/gh/9"

    check_published_prs proj.x

    [ ! -s "$T/notified" ]
    [ ! -e "$STATE_DIR/published-prs-gone/proj.x-9" ]
    grep -q 'proj.x #9 lookup failed, proves nothing' "$T/log"
}

@test "an ntfy that did not go out writes no marker, so the next tick retries" {
    published cron-issue-1-20261013-101010.log https://github.com/alexsiri7/proj.x/pull/9
    echo 404 > "$T/gh/9"
    NOTIFY_RC=1

    check_published_prs proj.x

    [ ! -e "$STATE_DIR/published-prs-gone/proj.x-9" ]
    grep -q 'ntfy not delivered' "$T/log"
}

@test "undelivered outcomes, other repos' PRs, other logs and old logs are not read" {
    published cron-issue-1-20261013-101010.log https://github.com/alexsiri7/proj.x/pull/1 false
    published cron-issue-2-20261013-101010.log https://github.com/alexsiri7/projyx/pull/2
    published cron-issue-3-20261013-101010.log https://github.com/alexsiri7/other/pull/3
    published pr-maint-4-20261013-101010.log https://github.com/alexsiri7/proj.x/pull/4
    published cron-issue-5-20261001-101010.log https://github.com/alexsiri7/proj.x/pull/5
    touch -d '20 days ago' "$LOGDIR/cron-issue-5-20261001-101010.log"

    check_published_prs proj.x

    [ ! -s "$T/gh-calls" ]
}

@test "the cap checks the newest PRs and logs how many it dropped" {
    published cron-issue-1-20261013-101010.log https://github.com/alexsiri7/proj.x/pull/20
    published cron-issue-2-20261013-101010.log https://github.com/alexsiri7/proj.x/pull/30
    published cron-issue-3-20261014-101010.log https://github.com/alexsiri7/proj.x/pull/30
    PUBLISHED_PR_MAX=1

    check_published_prs proj.x

    [ "$(cat "$T/gh-calls")" = 30 ]
    grep -q 'proj.x: 1 more published PRs not checked this tick' "$T/log"
}

@test "a project with no ship logs is skipped" {
    rm -rf "$LOGDIR"

    run check_published_prs proj.x

    [ "$status" -eq 0 ]
    [ ! -s "$T/gh-calls" ]
}
