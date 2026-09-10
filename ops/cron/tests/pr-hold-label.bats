#!/usr/bin/env bats
# Tests for the `hold` label convention in pr-maintenance-cron.sh and
# pr-review-cron.sh: a PR labeled `hold` is never flipped to ready, merged,
# handed to archon-pr-maintenance, or reviewed.
#
# Runs the real scripts end to end against a temp project tree with `gh` and
# `archon` stubbed. The stubs live in $HOME/.local/bin under a temp HOME: the
# scripts prepend $HOME/.local/bin ahead of /usr/local/bin, where a real
# archon may be installed, so this is the one place a stub reliably wins. The
# gh stub answers `pr list` with $GH_PR_LIST (applying the script's own --jq
# filter) and records every invocation.
#
# Run: npx bats@1.11.0 ops/cron/tests/pr-hold-label.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/hold-label-$$"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    # Fresh HOME: throttle state and pr-review state start empty.
    export HOME="$T/home"
    STUB_BIN="$HOME/.local/bin"
    mkdir -p "$STUB_BIN" "$T/base/proj/.git"
    export BASE_DIR="$T/base"
    export ARCHON_RUNS_SNAPSHOT="$T/snapshot"
    export ARCHON_PROJECTS_FILE="$T/projects.txt"
    echo "proj" > "$ARCHON_PROJECTS_FILE"

    export STUB_GH_ARGV="$T/gh-argv"
    export STUB_ARCHON_ARGV="$T/archon-argv"
    : > "$STUB_GH_ARGV"; : > "$STUB_ARCHON_ARGV"

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
if [ "$1 $2" = "pr list" ]; then
  jqf="" prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
  if [ -n "$jqf" ]; then printf '%s' "$GH_PR_LIST" | jq -r "$jqf"; else printf '%s' "$GH_PR_LIST"; fi
fi
exit 0
STUB
    cat > "$STUB_BIN/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARCHON_ARGV"
[ "$1 $2" = "workflow runs" ] && printf '{"runs": []}'
exit 0
STUB
    chmod +x "$STUB_BIN/gh" "$STUB_BIN/archon"
    export PATH="$STUB_BIN:$PATH"
}

teardown() {
    rm -rf "$T"
}

pr() { # pr <number> <draft> <mergeState> <labels-json>
    printf '{"number": %s, "isDraft": %s, "mergeStateStatus": "%s", "headRefName": "feat/x-%s", "headRefOid": "abc%s", "updatedAt": "2026-09-10T00:00:00Z", "body": "asset upload", "labels": %s}' \
        "$1" "$2" "$3" "$1" "$1" "$4"
}

gh_called() { grep -qE "$1" "$STUB_GH_ARGV"; }

# ── pr-maintenance-cron.sh ───────────────────────────────────────────────────

@test "maintenance: CLEAN non-draft PR with hold label is not merged" {
    export GH_PR_LIST="[$(pr 299 false CLEAN '[{"name":"hold"}]')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj: PR #299 is on hold — skipping"* ]]
    ! gh_called '^pr merge'
    ! gh_called '^pr ready'
}

@test "maintenance: CLEAN draft PR with hold label is not flipped to ready" {
    export GH_PR_LIST="[$(pr 299 true CLEAN '[{"name":"hold"}]')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj: PR #299 is on hold — skipping"* ]]
    ! gh_called '^pr ready'
    ! gh_called '^pr merge'
}

@test "maintenance: CLEAN PRs without hold are still merged (harness control)" {
    export GH_PR_LIST="[$(pr 299 false CLEAN '[{"name":"hold"}]'), $(pr 300 false CLEAN '[{"name":"enhancement"}]'), $(pr 301 true CLEAN '[]')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    gh_called '^pr ready 301'
    gh_called '^pr merge 300 '
    ! gh_called '^pr merge 299'
    [[ "$output" == *"PR #300 is CLEAN — merging directly"* ]]
}

@test "maintenance: DIRTY PR with hold label is not handed to archon-pr-maintenance" {
    export GH_PR_LIST="[$(pr 299 false DIRTY '[{"name":"hold"}]')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj: PR #299 is on hold — skipping"* ]]
    [[ "$output" == *"proj: no PRs need AI maintenance"* ]]
    # The stub was reached (snapshot listings) but never asked to maintain.
    grep -q '^workflow runs' "$STUB_ARCHON_ARGV"
    ! grep -q 'workflow run archon-pr-maintenance' "$STUB_ARCHON_ARGV"
}

@test "maintenance: held DIRTY PR is passed over in favour of the next candidate" {
    export GH_PR_LIST="[$(pr 299 false DIRTY '[{"name":"hold"}]'), $(pr 300 false BEHIND '[]')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj: PR #299 is on hold — skipping"* ]]
    [[ "$output" == *"proj: PR #300 needs maintenance — launching archon"* ]]
    grep -q 'workflow run archon-pr-maintenance .*PR #300$' "$STUB_ARCHON_ARGV"
    ! grep -q 'PR #299' "$STUB_ARCHON_ARGV"
}

@test "maintenance: creates the hold label on each project every tick" {
    export GH_PR_LIST="[]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    gh_called '^label create hold --repo alexsiri7/proj --color 5319E7 --description Do not auto-merge, auto-review or auto-maintain$'
}

# ── pr-review-cron.sh ────────────────────────────────────────────────────────

@test "review: non-draft PR with hold label is not reviewed" {
    export GH_PR_LIST="[$(pr 299 false CLEAN '[{"name":"hold"}]'), $(pr 300 false CLEAN '[]')]"
    run "$CRON_DIR/pr-review-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj: PR #299 is on hold — skipping"* ]]
    [[ "$output" == *"fired archon-review"* ]]
    [[ "$output" == *"1 on-hold, 1 fired"* ]]
    grep -q 'review PR #300' "$STUB_ARCHON_ARGV"
    ! grep -q 'review PR #299' "$STUB_ARCHON_ARGV"
    [ ! -f "$HOME/.archon/state/pr-review/proj-299.pid" ]
}
