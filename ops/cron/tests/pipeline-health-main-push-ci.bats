#!/usr/bin/env bats
# Unit tests for check_main_push_ci in ops/cron/pipeline-health-cron.sh:
# a main HEAD that produced no push workflow run is detected once, and the
# empty-commit re-trigger PR is opened only when the HEAD commit message
# explains the missing run with a CI-skip token.
#
# The real lib/ci-skip.sh is sourced rather than stubbed — the split between
# the diagnosed and ambiguous branches is the behaviour under test.
#
# Run: bunx bats ops/cron/tests/pipeline-health-main-push-ci.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/main-push-ci-$$"
    # The script creates this at top level; awk extraction never runs that, and
    # pipeline-health-cron.sh has no `set -e`, so a failing touch would be
    # silent and every dedup assertion meaningless.
    mkdir -p "$STATE_DIR/main-ci-missing"

    # check_main_push_ci returns early unless the project has a local clone.
    export BASE_DIR="$STATE_DIR/base"
    mkdir -p "$BASE_DIR/proj/.git"

    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"
    export GH_ARGV="$STATE_DIR/gh-argv"
    : > "$GH_ARGV"

    # Defaults: HEAD is old enough, the repo does run push CI, and the SHA has
    # a run. Each test overrides only what it is about.
    export HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    export HEAD_MSG="feat: a normal merge (#12)"
    export HEAD_TS="$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    export EVER_COUNT="94"
    export SHA_COUNT="1"
    export OPEN_RETRIGGER=""

    log() { echo "$*"; }
    export -f log
    notify() { echo "$1 | $2" >> "$NTFY_SENTINEL"; }
    export -f notify

    gh() {
        printf '%s\n' "$*" >> "$GH_ARGV"
        case "$*" in
            *"commits/main"*)
                printf '{"sha":"%s","ts":"%s","msg":"%s","tree":"treesha"}' \
                    "$HEAD_SHA" "$HEAD_TS" "$HEAD_MSG" ;;
            *"branch=main&event=push"*) printf '%s' "$EVER_COUNT" ;;
            *"head_sha="*)              printf '%s' "$SHA_COUNT" ;;
            *"pr list"*)                printf '%s' "$OPEN_RETRIGGER" ;;
            *"git/commits"*)            printf 'newcommitsha' ;;
            *"git/refs"*)               printf 'refs/heads/ci/retrigger-aaaaaaaa' ;;
            *"pr create"*)              printf 'https://github.com/alexsiri7/proj/pull/500' ;;
        esac
    }
    export -f gh

    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    unset _ARCHON_CI_SKIP_SH
    source "$SCRIPT_DIR/lib/ci-skip.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_main_push_ci\(\)/{p=1} p{print} p && /^}$/{p=0}' \
        "$SCRIPT_DIR/pipeline-health-cron.sh")
}

teardown() {
    rm -rf "$STATE_DIR"
}

gh_called() { grep -qF -e "$1" "$GH_ARGV"; }
marker_count() { find "$STATE_DIR/main-ci-missing" -maxdepth 1 -name 'proj-*' | wc -l; }

# ── nothing to do ────────────────────────────────────────────────────────────

@test "HEAD with a push run is not flagged" {
    run check_main_push_ci proj
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_SENTINEL" ]
    [ "$(marker_count)" -eq 0 ]
}

@test "a HEAD younger than the age gate is left alone" {
    export HEAD_TS="$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    export SHA_COUNT="0"
    run check_main_push_ci proj
    [ ! -f "$NTFY_SENTINEL" ]
    [ "$(marker_count)" -eq 0 ]
    ! gh_called 'head_sha='
}

@test "a repo that never runs push CI on main is skipped silently" {
    export EVER_COUNT="0"
    export SHA_COUNT="0"
    run check_main_push_ci proj
    [ ! -f "$NTFY_SENTINEL" ]
    [ "$(marker_count)" -eq 0 ]
    ! gh_called 'head_sha='
}

@test "an unparseable run count is not treated as evidence of a missing run" {
    export SHA_COUNT="API rate limit exceeded"
    run check_main_push_ci proj
    [ ! -f "$NTFY_SENTINEL" ]
    [ "$(marker_count)" -eq 0 ]
    ! gh_called 'pr create'
}

# ── ambiguous: zero runs, no token in the HEAD message ───────────────────────

@test "zero runs without a CI-skip token ntfys and opens nothing" {
    export SHA_COUNT="0"
    run check_main_push_ci proj
    [ -f "$NTFY_SENTINEL" ]
    grep -q 'no CI-skip token' "$NTFY_SENTINEL"
    [ "$(marker_count)" -eq 1 ]
    ! gh_called 'git/commits'
    ! gh_called 'git/refs'
    ! gh_called 'pr create'
    [ ! -f "$STATE_DIR/main-ci-missing-cooldown-proj" ]
}

# ── diagnosed: zero runs and a token in the HEAD message ─────────────────────

@test "zero runs with a CI-skip token opens the re-trigger PR" {
    export SHA_COUNT="0"
    export HEAD_MSG="chore: update snapshots [skip ci]"
    run check_main_push_ci proj
    [ "$status" -eq 0 ]
    gh_called 'git/commits'
    gh_called 'git/refs'
    gh_called 'ref=refs/heads/ci/retrigger-aaaaaaaa'
    gh_called 'pr create'
    gh_called '--head ci/retrigger-aaaaaaaa'
    [ -f "$STATE_DIR/main-ci-missing-cooldown-proj" ]
    [ -f "$NTFY_SENTINEL" ]
    grep -q 'pull/500' "$NTFY_SENTINEL"
}

@test "the re-trigger PR carries no CI-skip token of its own" {
    export SHA_COUNT="0"
    export HEAD_MSG="chore: update snapshots [skip ci]"
    run check_main_push_ci proj
    ! grep -qiE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|\*\*\*NO_CI\*\*\*' "$GH_ARGV"
}

# ── dedup and loop control ───────────────────────────────────────────────────

@test "a SHA already handled is not handled twice" {
    export SHA_COUNT="0"
    export HEAD_MSG="chore: update snapshots [skip ci]"
    check_main_push_ci proj
    rm -f "$NTFY_SENTINEL"; : > "$GH_ARGV"
    run check_main_push_ci proj
    [[ "$output" == *"already handled"* ]]
    [ ! -f "$NTFY_SENTINEL" ]
    ! gh_called 'pr create'
}

@test "a new stuck SHA within the cooldown ntfys instead of opening a second PR" {
    date +%s > "$STATE_DIR/main-ci-missing-cooldown-proj"
    export SHA_COUNT="0"
    export HEAD_MSG="chore: update snapshots [skip ci]"
    run check_main_push_ci proj
    [[ "$output" == *"cooldown active"* ]]
    [ -f "$NTFY_SENTINEL" ]
    ! gh_called 'pr create'
    [ "$(marker_count)" -eq 1 ]
}

@test "an open re-trigger PR blocks a second one" {
    export SHA_COUNT="0"
    export HEAD_MSG="chore: update snapshots [skip ci]"
    export OPEN_RETRIGGER="500"
    run check_main_push_ci proj
    [[ "$output" == *"re-trigger PR #500 already open"* ]]
    ! gh_called 'pr create'
    ! gh_called 'git/commits'
}

# ── recovery ─────────────────────────────────────────────────────────────────

@test "a HEAD that does have runs clears this project's stale markers" {
    touch "$STATE_DIR/main-ci-missing/proj-bbbbbbbbbbbb"
    touch "$STATE_DIR/main-ci-missing/other-cccccccccccc"
    run check_main_push_ci proj
    [ "$(marker_count)" -eq 0 ]
    [ -f "$STATE_DIR/main-ci-missing/other-cccccccccccc" ]
}
