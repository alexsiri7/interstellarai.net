#!/usr/bin/env bats
# Tests for pr-maintenance-cron.sh's resume of a run parked on CI attention
# (interstellarai.net#174): once the run's PR is green the run is resumed so it
# flips its own draft ready, and the PR is never promoted or merged under it.
#
# Same harness as pr-maintenance-failed-run.bats: the real script end to end,
# with `gh` and `archon` stubbed in $HOME/.local/bin under a temp HOME. The
# archon stub answers `workflow runs --status paused` with $ARCHON_PAUSED_RUNS,
# every other listing with no runs, and records every call.
#
# Run: npx bats@1.13.0 ops/cron/tests/pr-maintenance-ci-attention.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/ci-attention-$$"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    export HOME="$T/home"
    STUB_BIN="$HOME/.local/bin"
    mkdir -p "$STUB_BIN" "$T/base/proj/.git"
    export BASE_DIR="$T/base"
    export ARCHON_RUNS_SNAPSHOT="$T/snapshot"
    export ARCHON_PROJECTS_FILE="$T/projects.txt"
    echo "proj" > "$ARCHON_PROJECTS_FILE"

    export STUB_GH_ARGV="$T/gh-argv" STUB_ARCHON_ARGV="$T/archon-argv"
    : > "$STUB_GH_ARGV"
    : > "$STUB_ARCHON_ARGV"
    export ARCHON_PAUSED_RUNS='{"runs": [], "total": 0}'
    checks SUCCESS SUCCESS

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
if [ "$1 $2" = "pr list" ]; then
  jqf="" prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
  if [ -n "$jqf" ]; then printf '%s' "$GH_PR_LIST" | jq -r "$jqf"; else printf '%s' "$GH_PR_LIST"; fi
fi
[ "$1 $2" = "pr view" ] && printf '%s' "$GH_PR_VIEW"
[ "$1 $2" = "issue view" ] && printf '{"labels":[]}'
exit 0
STUB
    cat > "$STUB_BIN/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARCHON_ARGV"
if [ "$1 $2" = "workflow runs" ]; then
  case " $* " in
    *" --status paused "*) printf '%s' "$ARCHON_PAUSED_RUNS" ;;
    *) printf '{"runs": [], "total": 0}' ;;
  esac
fi
[ "$1 $2" = "workflow resume" ] && printf '{"ok": true}'
exit 0
STUB
    chmod +x "$STUB_BIN/gh" "$STUB_BIN/archon"
    export PATH="$STUB_BIN:$PATH"
}

teardown() {
    rm -rf "$T"
}

checks() { # checks <conclusion>... — the PR's statusCheckRollup, one check run each
    local entries="" c
    for c in "$@"; do
        entries="$entries${entries:+, }{\"name\": \"check\", \"status\": \"COMPLETED\", \"conclusion\": \"$c\"}"
    done
    export GH_PR_VIEW="{\"title\": \"stub title\", \"body\": \"Fixes #74\", \"statusCheckRollup\": [$entries]}"
}

pr() { # pr [labels JSON] — draft #735, CLEAN, on the paused run's branch
    printf '[{"number": 735, "isDraft": true, "mergeStateStatus": "CLEAN", "headRefName": "archon/task-archon-ship-17", "body": "Fixes #74", "labels": %s, "author": {"login": "alexsiri7"}, "isCrossRepository": false}]' \
        "${1:-[]}"
}

paused_run() { # paused_run <metadata JSON> — run-735 paused on archon/task-archon-ship-17
    printf '{"runs": [{"id": "run-735", "workflow_name": "archon-ship", "status": "paused", "user_message": "fix #74",
      "working_path": "/w/proj/worktrees/archon/task-archon-ship-17",
      "metadata": {"workflow_source": {"origin": "%s"}, %s}}], "total": 1}' "$BASE_DIR/proj" "$1"
}

attention() { # attention [bodyWaitId]
    printf '"wait": {"owner": "loop_group", "nodeId": "deliver__ci-attention", "bodyWaitId": "%s",
      "kind": "attention", "waitingSince": "2026-10-09T18:11:41.622Z",
      "message": "CI remains non-green for pull request #735. Re-run the failing check, then resume this run."}' \
      "${1:-attention-ci-pause}"
}

resumed() { grep -q '^workflow resume run-735 --detach --json --cwd ' "$STUB_ARCHON_ARGV"; }
not_resumed() { ! grep -q '^workflow resume' "$STUB_ARCHON_ARGV"; }
gh_not_called() { ! grep -qE "$1" "$STUB_GH_ARGV"; }

@test "a CI attention run whose PR is green is resumed, and the PR is left to it this tick" {
    export GH_PR_LIST="$(pr)"
    export ARCHON_PAUSED_RUNS="$(paused_run "$(attention)")"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    resumed
    [[ "$output" == *"proj: PR #735 is green — resuming run run-735 parked on CI attention"* ]]
    [[ "$output" == *"leaving the ready flip to it"* ]]
    gh_not_called '^pr ready'
    gh_not_called '^pr merge'
}

@test "a red check keeps the run parked" {
    checks SUCCESS FAILURE
    export GH_PR_LIST="$(pr)"
    export ARCHON_PAUSED_RUNS="$(paused_run "$(attention)")"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    not_resumed
    [[ "$output" == *"PR #735 — run run-735 is parked on CI attention and the checks are not all green yet"* ]]
    gh_not_called '^pr ready'
}

@test "a running check keeps the run parked" {
    export GH_PR_VIEW='{"statusCheckRollup": [{"name": "a", "status": "COMPLETED", "conclusion": "SUCCESS"},
      {"name": "b", "status": "IN_PROGRESS", "conclusion": ""}]}'
    export GH_PR_LIST="$(pr)"
    export ARCHON_PAUSED_RUNS="$(paused_run "$(attention)")"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    not_resumed
}

@test "a PR with no checks at all keeps the run parked" {
    checks
    export GH_PR_LIST="$(pr)"
    export ARCHON_PAUSED_RUNS="$(paused_run "$(attention)")"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    not_resumed
}

@test "a gate or a non-CI attention pause on the branch is never resumed" {
    export GH_PR_LIST="$(pr)"
    export ARCHON_PAUSED_RUNS="$(paused_run "$(attention deploy-approval-pause)")"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    not_resumed

    export ARCHON_PAUSED_RUNS="$(paused_run \
      '"approval": {"nodeId": "attention-ci-pause", "message": "Ship it?", "type": "approval"}')"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    not_resumed
    gh_not_called '^pr ready'
}

@test "a held PR's run is not resumed" {
    export GH_PR_LIST="$(pr '[{"name": "hold"}]')"
    export ARCHON_PAUSED_RUNS="$(paused_run "$(attention)")"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    not_resumed
}
