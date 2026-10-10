#!/usr/bin/env bats
# Tests for pr-maintenance-cron.sh's failed-run guard (interstellarai.net#74):
# a PR whose archon task branch was left by a failed run that nothing adopted is
# never flipped to ready or merged, however green its CI.
#
# Same harness as pr-hold-label.bats: the real script end to end, with `gh` and
# `archon` stubbed in $HOME/.local/bin under a temp HOME. The archon stub
# answers `workflow runs --open` with $ARCHON_OPEN_RUNS and every other listing
# with no runs.
#
# Run: npx bats@1.11.0 ops/cron/tests/pr-maintenance-failed-run.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/failed-run-$$"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    export HOME="$T/home"
    STUB_BIN="$HOME/.local/bin"
    mkdir -p "$STUB_BIN" "$T/base/proj/.git"
    export BASE_DIR="$T/base"
    export ARCHON_RUNS_SNAPSHOT="$T/snapshot"
    export ARCHON_PROJECTS_FILE="$T/projects.txt"
    echo "proj" > "$ARCHON_PROJECTS_FILE"

    export STUB_GH_ARGV="$T/gh-argv"
    : > "$STUB_GH_ARGV"
    export GH_PR_VIEW='{"title":"stub title","body":"stub body"}'
    export ARCHON_OPEN_RUNS='{"runs": [], "total": 0}'

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
if [ "$1 $2" = "workflow runs" ]; then
  case " $* " in
    *" --open "*) printf '%s' "$ARCHON_OPEN_RUNS" ;;
    *) printf '{"runs": [], "total": 0}' ;;
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

pr() { # pr <number> <draft> <headRefName> — a CLEAN owner, same-repo PR
    printf '{"number": %s, "isDraft": %s, "mergeStateStatus": "CLEAN", "headRefName": "%s", "body": "Fixes #74", "labels": [], "author": {"login": "alexsiri7"}, "isCrossRepository": false}' \
        "$1" "$2" "$3"
}

failed_run() { # failed_run <id> <branch> — an unadopted failed run whose worktree is <branch>
    printf '{"runs": [{"id": "%s", "workflow_name": "archon-ship", "status": "failed", "user_message": "fix #74", "working_path": "/w/proj/worktrees/%s"}], "total": 1}' \
        "$1" "$2"
}

gh_called() { grep -qE "$1" "$STUB_GH_ARGV"; }

@test "a CLEAN draft left by a failed run is not promoted" {
    export GH_PR_LIST="[$(pr 329 true archon/task-archon-ship-17)]"
    export ARCHON_OPEN_RUNS="$(failed_run run-329 archon/task-archon-ship-17)"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj: PR #329 (archon/task-archon-ship-17) was left by failed archon run run-329 — not promoting or merging it"* ]]
    ! gh_called '^pr ready'
    ! gh_called '^pr merge'
}

@test "a CLEAN non-draft PR left by a failed run is not merged" {
    export GH_PR_LIST="[$(pr 329 false archon/task-archon-ship-17)]"
    export ARCHON_OPEN_RUNS="$(failed_run run-329 archon/task-archon-ship-17)"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR #329 (archon/task-archon-ship-17) was left by failed archon run run-329"* ]]
    ! gh_called '^pr merge'
}

@test "a CLEAN draft whose run did not fail (or was adopted) is still promoted and merged" {
    # The failed run left another branch; this one's run completed, or was
    # adopted and so dropped out of the open-work inbox.
    export GH_PR_LIST="[$(pr 330 true archon/task-archon-ship-18), $(pr 331 false archon/task-archon-ship-19)]"
    export ARCHON_OPEN_RUNS="$(failed_run run-329 archon/task-archon-ship-17)"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    gh_called '^pr ready 330'
    gh_called '^pr merge 331 '
    [[ "$output" != *"failed archon run"* ]]
}

@test "an unreadable failed-run listing holds archon branches and nothing else" {
    export GH_PR_LIST="[$(pr 330 true archon/task-archon-ship-18), $(pr 332 false feat/human), $(pr 333 false archon/task-archon-ship-19)]"
    export ARCHON_OPEN_RUNS='{"ok": false, "error": "db down"}'
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not list failed runs"*"db down"* ]]
    [[ "$output" == *"PR #330 (archon/task-archon-ship-18) — no failed-run listing this tick, not promoting or merging it"* ]]
    [[ "$output" == *"PR #333 (archon/task-archon-ship-19) — no failed-run listing this tick, not promoting or merging it"* ]]
    ! gh_called '^pr ready 330'
    ! gh_called '^pr merge 333 '
    gh_called '^pr merge 332 '
}
