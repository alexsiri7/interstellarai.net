#!/usr/bin/env bats
# Tests for pr-maintenance-cron.sh Phase 2's launch dedup (interstellarai.net#73):
# a PR gets one archon-pr-maintenance launch per head SHA and merge state, so a
# conflict the run could not resolve is not relaunched every tick.
#
# Runs the real script end to end against a temp project tree, with `gh` and
# `archon` stubbed in $HOME/.local/bin under a temp HOME (the script prepends
# it to PATH). The gh stub answers `pr list` with $GH_PR_LIST; the archon stub
# records every invocation. Each tick is forced past the throttle.
#
# Run: npx bats@1.11.0 ops/cron/tests/pr-maintenance-dedup.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/maintenance-dedup-$$"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    export HOME="$T/home"
    STUB_BIN="$HOME/.local/bin"
    mkdir -p "$STUB_BIN" "$T/base/proj/.git"
    export BASE_DIR="$T/base"
    export ARCHON_RUNS_SNAPSHOT="$T/snapshot"
    export ARCHON_PROJECTS_FILE="$T/projects.txt"
    echo "proj" > "$ARCHON_PROJECTS_FILE"
    export ARCHON_CRON_FORCE_TICK=1

    export STUB_ARCHON_ARGV="$T/archon-argv"
    : > "$STUB_ARCHON_ARGV"

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "pr list" ] && printf '%s' "$GH_PR_LIST"
exit 0
STUB
    cat > "$STUB_BIN/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARCHON_ARGV"
[ "$1 $2" = "workflow runs" ] && printf '{"runs": []}'
exit 0
STUB
    chmod +x "$STUB_BIN/gh" "$STUB_BIN/archon"
}

teardown() {
    rm -rf "$T"
}

pr() { # pr <number> <mergeState> <headRefOid> — an owner's archon-branch PR with no live run
    printf '{"number": %s, "isDraft": false, "mergeStateStatus": "%s", "headRefName": "archon/task-archon-ship-%s", "headRefOid": "%s", "body": "Fixes #9", "labels": [], "author": {"login": "alexsiri7"}, "isCrossRepository": false}' \
        "$1" "$2" "$1" "$3"
}

launches() { grep -c "^workflow run " "$STUB_ARCHON_ARGV" || true; }

tick() { run "$CRON_DIR/pr-maintenance-cron.sh"; [ "$status" -eq 0 ]; }

@test "a CONFLICTING PR gets one archon-pr-maintenance launch per head SHA" {
    export GH_PR_LIST="[$(pr 500 DIRTY aaaaaaa1)]"
    tick
    tick
    tick
    [ "$(launches)" -eq 1 ]
    grep -q '^workflow run archon-pr-maintenance --cwd .* PR #500$' "$STUB_ARCHON_ARGV"
    [[ "$output" == *"proj: PR #500 already had maintenance launched at aaaaaaa (DIRTY) — waiting for a new head or merge state"* ]]
    [[ "$output" == *"proj: no PRs need AI maintenance"* ]]
}

@test "a new head SHA re-arms the launch" {
    export GH_PR_LIST="[$(pr 500 DIRTY aaaaaaa1)]"
    tick
    export GH_PR_LIST="[$(pr 500 DIRTY bbbbbbb2)]"
    tick
    tick
    [ "$(launches)" -eq 2 ]
}

@test "a new merge state at the same head re-arms the launch" {
    export GH_PR_LIST="[$(pr 500 BEHIND aaaaaaa1)]"
    tick
    export GH_PR_LIST="[$(pr 500 DIRTY aaaaaaa1)]"
    tick
    [ "$(launches)" -eq 2 ]
}

@test "an already-launched PR is passed over in favour of the next candidate" {
    export GH_PR_LIST="[$(pr 500 DIRTY aaaaaaa1), $(pr 501 BEHIND ccccccc3)]"
    tick
    tick
    [ "$(launches)" -eq 2 ]
    grep -q 'PR #500$' "$STUB_ARCHON_ARGV"
    grep -q 'PR #501$' "$STUB_ARCHON_ARGV"
}

@test "a tick held by the rate limit marks nothing, so the next tick still launches" {
    export ARCHON_DB="$T/archon.db"
    local spec
    spec=$(TZ=Europe/London date -d '+2 hours' '+%-I%P')
    sqlite3 "$ARCHON_DB" "
      CREATE TABLE remote_agent_workflow_runs (id TEXT PRIMARY KEY, codebase_id TEXT,
        workflow_name TEXT, user_message TEXT, status TEXT, started_at TEXT);
      CREATE TABLE remote_agent_workflow_events (id INTEGER PRIMARY KEY,
        workflow_run_id TEXT, event_type TEXT, data TEXT,
        created_at TEXT DEFAULT (datetime('now')));
      INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, data)
        VALUES ('r1', 'node_failed', '{\"error\":\"You have hit your weekly limit · resets $spec (Europe/London)\"}');"
    export GH_PR_LIST="[$(pr 500 DIRTY aaaaaaa1)]"
    tick
    [[ "$output" == *"proj: PR #500 needs maintenance — held, Claude rate limit in effect"* ]]
    [ "$(launches)" -eq 0 ]

    sqlite3 "$ARCHON_DB" "DELETE FROM remote_agent_workflow_events;"
    tick
    [ "$(launches)" -eq 1 ]
    grep -q 'PR #500$' "$STUB_ARCHON_ARGV"
}
