#!/usr/bin/env bats
# End-to-end tests for pr-maintenance-cron.sh and pr-review-cron.sh: the
# `hold` label convention (a PR labeled `hold` is never flipped to ready,
# merged, handed to archon-pr-maintenance, or reviewed), the squash merge
# message, and the review/merge race.
#
# Runs the real scripts end to end against a temp project tree with `gh` and
# `archon` stubbed. The stubs live in $HOME/.local/bin under a temp HOME: the
# scripts prepend $HOME/.local/bin ahead of /usr/local/bin, where a real
# archon may be installed, so this is the one place a stub reliably wins. The
# gh stub answers `pr list` with $GH_PR_LIST (applying the script's own --jq
# filter), `pr view` with $GH_PR_VIEW, fails `pr merge --auto` when
# $GH_MERGE_AUTO_FAILS is set, and records every invocation. The archon stub
# lists $ARCHON_RUNNING_RUNS as the running runs, fails the paused listing when
# $ARCHON_PAUSED_FAILS is set, and records every invocation.
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

    # What `gh pr view --json title,body` answers with. Phase 1 refuses to
    # merge when this comes back empty, so every merge test needs it set.
    export GH_PR_VIEW='{"title":"stub title","body":"stub body"}'

    # Set to make `gh pr merge --auto` fail, so the non---auto fallback runs.
    export GH_MERGE_AUTO_FAILS=""

    # The `runs` array `archon workflow runs --status running` answers with.
    export ARCHON_RUNNING_RUNS="[]"

    # Set to make `archon workflow runs --status paused` fail, leaving the
    # tick's run snapshot incomplete.
    export ARCHON_PAUSED_FAILS=""

    # The real token predicate, so no test re-declares what lib/ci-skip.sh owns.
    unset _ARCHON_CI_SKIP_SH
    source "$CRON_DIR/lib/ci-skip.sh"

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
if [ -n "$GH_MERGE_AUTO_FAILS" ] && [ "$1 $2" = "pr merge" ]; then
  case "$*" in *--auto*) exit 1 ;; esac
fi
if [ "$1 $2" = "pr list" ]; then
  jqf="" prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
  if [ -n "$jqf" ]; then printf '%s' "$GH_PR_LIST" | jq -r "$jqf"; else printf '%s' "$GH_PR_LIST"; fi
fi
[ "$1 $2" = "pr view" ] && printf '%s' "$GH_PR_VIEW"
# Linked issues (pr-maintenance's scope gate): owner issues, no labels.
[ "$1 $2" = "issue view" ] && printf '{"labels":[]}'
exit 0
STUB
    cat > "$STUB_BIN/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARCHON_ARGV"
if [ "$1 $2" = "workflow runs" ]; then
  case "$*" in
    *"--status paused"*) [ -n "$ARCHON_PAUSED_FAILS" ] && { printf '{"ok": false, "error": "db locked"}'; exit 1; }
                         printf '{"runs": []}' ;;
    *"--status running"*) printf '{"runs": %s}' "$ARCHON_RUNNING_RUNS" ;;
    *) printf '{"runs": []}' ;;
  esac
fi
exit 0
STUB
    chmod +x "$STUB_BIN/gh" "$STUB_BIN/archon"
    export PATH="$STUB_BIN:$PATH"
}

teardown() {
    rm -rf "$T"
}

pr() { # pr <number> <draft> <mergeState> <labels-json> [head] — an owner, same-repo PR
    printf '{"number": %s, "isDraft": %s, "mergeStateStatus": "%s", "headRefName": "%s", "headRefOid": "abc%s", "updatedAt": "2026-09-10T00:00:00Z", "body": "asset upload", "labels": %s, "author": {"login": "alexsiri7"}, "isCrossRepository": false}' \
        "$1" "$2" "$3" "${5:-feat/x-$1}" "$1" "$4"
}

run_json() { # run_json <id> <workflow> <user_message> — a running run on proj
    printf '{"id": "%s", "workflow_name": "%s", "status": "running", "user_message": "%s", "metadata": {"workflow_source": {"origin": "%s"}}}' \
        "$1" "$2" "$3" "$BASE_DIR/proj"
}

gh_called() { grep -qE "$1" "$STUB_GH_ARGV"; }

merge_argv() { grep -E "^pr merge $1 " "$STUB_GH_ARGV"; }

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

# ── squash merge message sanitising (interstellarai.net#76) ──────────────────

@test "maintenance: every merge carries an explicit subject and body, token or not" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export GH_PR_VIEW='{"title":"feat: normal change","body":"nothing special"}'
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    # The poisoned token lives in an intermediate commit subject, which neither
    # the title nor the body shows — so the override can never be conditional.
    merge_argv 300 | grep -qF -e '--subject feat: normal change (#300)'
    merge_argv 300 | grep -qF -e '--body nothing special'
}

@test "maintenance: a skip-ci token in the PR title is stripped from the merge subject" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export GH_PR_VIEW='{"title":"chore: bump deps [skip ci]","body":"routine"}'
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    merge_argv 300 | grep -qF -- '--subject chore: bump deps (#300)'
    ! merge_argv 300 | grep -qiF -- 'skip ci'
}

@test "maintenance: a skip-ci token in the PR body is stripped from the merge body" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export GH_PR_VIEW='{"title":"feat: thing","body":"closes #12 [ci skip]"}'
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    merge_argv 300 | grep -qF -- '--body closes #12'
    ! merge_argv 300 | grep -qiF -- 'ci skip'
}

@test "maintenance: a title that is only a skip-ci token falls back to a generic subject" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export GH_PR_VIEW='{"title":"[skip ci]","body":"nothing to see"}'
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    merge_argv 300 | grep -qF -- '--subject Merge pull request #300'
}

@test "maintenance: the fallback merge carries the same sanitized subject and body" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export GH_PR_VIEW='{"title":"chore: bump deps [skip ci]","body":"routine [ci skip]"}'
    export GH_MERGE_AUTO_FAILS=1
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    # --auto is what GitHub honours when checks are still pending; when it is
    # refused the immediate merge is what lands on main, so it needs the same
    # message. Nothing else distinguishes the two lines in the argv log.
    fallback="$(merge_argv 300 | grep -v -- '--auto')"
    [ -n "$fallback" ]
    grep -qF -- '--subject chore: bump deps (#300)' <<<"$fallback"
    grep -qF -- '--body routine' <<<"$fallback"
    ! has_ci_skip_token "$fallback"
}

@test "maintenance: an unreadable title/body defers the merge to the next tick" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export GH_PR_VIEW=""
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR #300 — could not read title/body for the merge message, retrying next tick"* ]]
    ! gh_called '^pr merge 300'
}

# ── pr-review-cron.sh ────────────────────────────────────────────────────────

@test "review: non-draft PR with hold label is not reviewed" {
    export GH_PR_LIST="[$(pr 299 false CLEAN '[{"name":"hold"}]'), $(pr 300 false CLEAN '[]')]"
    run "$CRON_DIR/pr-review-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj: PR #299 is on hold — skipping"* ]]
    [[ "$output" == *"fired archon-review"* ]]
    [[ "$output" == *"1 on-hold, 0 ship-merging, 1 fired"* ]]
    grep -q 'review PR #300' "$STUB_ARCHON_ARGV"
    ! grep -q 'review PR #299' "$STUB_ARCHON_ARGV"
    [ ! -f "$HOME/.archon/state/pr-review/proj-299.pid" ]
}

# ── review/merge race (interstellarai.net#71) ────────────────────────────────

@test "review: a CLEAN non-draft archon-ship PR does not get a review fired" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]' archon/task-archon-ship-1791575208056)]"
    run "$CRON_DIR/pr-review-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj: PR #300 is a CLEAN archon-ship PR, reviewed by its run and about to merge — skipping"* ]]
    [[ "$output" == *"1 ship-merging, 0 fired"* ]]
    ! grep -q 'workflow run archon-review' "$STUB_ARCHON_ARGV"
    [ ! -f "$HOME/.archon/state/pr-review/proj-300.pid" ]
}

@test "review: archon-ship PRs not yet CLEAN, and CLEAN PRs on other heads, are still reviewed" {
    export GH_PR_LIST="[$(pr 300 false BLOCKED '[]' archon/task-archon-ship-1), $(pr 301 false CLEAN '[]')]"
    run "$CRON_DIR/pr-review-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 ship-merging, 2 fired"* ]]
    grep -q 'review PR #300' "$STUB_ARCHON_ARGV"
    grep -q 'review PR #301' "$STUB_ARCHON_ARGV"
}

@test "maintenance: merging a PR with an active review abandons the review" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export ARCHON_RUNNING_RUNS="[$(run_json rev-300 archon-review 'review PR #300'), $(run_json smart-300 archon-smart-pr-review 'PR #300'), $(run_json rev-3000 archon-review 'review PR #3000'), $(run_json ship-300 archon-ship 'fix #300')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    gh_called '^pr merge 300 '
    [[ "$output" == *"proj: PR #300 — abandoned review run rev-300 on the merged PR"* ]]
    grep -qx 'workflow abandon rev-300' "$STUB_ARCHON_ARGV"
    grep -qx 'workflow abandon smart-300' "$STUB_ARCHON_ARGV"
    ! grep -q 'workflow abandon rev-3000' "$STUB_ARCHON_ARGV"
    ! grep -q 'workflow abandon ship-300' "$STUB_ARCHON_ARGV"
}

@test "maintenance: merging via the non-auto fallback also abandons the review" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export GH_MERGE_AUTO_FAILS=1
    export ARCHON_RUNNING_RUNS="[$(run_json rev-300 archon-review 'review PR #300')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    merge_argv 300 | grep -v -- '--auto' | grep -q .
    [[ "$output" == *"proj: PR #300 — abandoned review run rev-300 on the merged PR"* ]]
    grep -qx 'workflow abandon rev-300' "$STUB_ARCHON_ARGV"
}

@test "maintenance: a merge on an incomplete run snapshot abandons what it sees and says so" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[]')]"
    export ARCHON_PAUSED_FAILS=1
    export ARCHON_RUNNING_RUNS="[$(run_json rev-300 archon-review 'review PR #300')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    gh_called '^pr merge 300 '
    [[ "$output" == *"proj: PR #300 — no complete archon run snapshot this tick, a review run on the merged PR may be left running"* ]]
    grep -qx 'workflow abandon rev-300' "$STUB_ARCHON_ARGV"
}

@test "maintenance: a PR that is not merged keeps its review" {
    export GH_PR_LIST="[$(pr 300 false CLEAN '[{"name":"hold"}]')]"
    export ARCHON_RUNNING_RUNS="[$(run_json rev-300 archon-review 'review PR #300')]"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    ! gh_called '^pr merge 300'
    ! grep -q 'workflow abandon' "$STUB_ARCHON_ARGV"
}
