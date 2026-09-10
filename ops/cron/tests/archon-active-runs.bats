#!/usr/bin/env bats
# Tests for lib/archon-active-runs.sh and pr-maintenance's live-run guard.
#
# Run: bunx bats ops/cron/tests/archon-active-runs.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/active-runs-$$"
    mkdir -p "$T/bin"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    # Stub archon: prints $STUB_PAYLOAD, exits $STUB_RC, records its argv.
    cat > "$T/bin/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$STUB_ARGV"
printf '%s' "$STUB_PAYLOAD"
exit "${STUB_RC:-0}"
STUB
    chmod +x "$T/bin/archon"
    export PATH="$T/bin:$PATH"
    export STUB_ARGV="$T/argv"
    export STUB_RC=0

    # shellcheck disable=SC1091
    source "$CRON_DIR/lib/archon-active-runs.sh"
    ARCHON_RUNS_SNAPSHOT="$T/snapshot"
}

teardown() {
    rm -rf "$T"
}

# What the CLI answers when its cwd is not a git checkout (cron's $HOME).
NOT_A_REPO='{"ok": false, "error": "Error: Not in a git repository.\nThe Archon CLI must be run from within a git repository."}'

ONE_SHIP_RUN='{"runs": [{"workflow_name": "archon-ship", "status": "running", "user_message": "fix #528",
  "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/filmduel"}}}], "total": 1}'

load_pr_owned_by_live_run() {
    # shellcheck disable=SC1090
    source <(
        awk '/^pr_owned_by_live_run\(\)/{p=1} p{print} p && /^}$/{p=0}' "$CRON_DIR/pr-maintenance-cron.sh"
    )
}

@test "snapshot passes --cwd pointing at a git checkout on every listing" {
    export STUB_PAYLOAD='{"runs": []}'
    archon_runs_snapshot
    [ "$(grep -o -- '--cwd' "$STUB_ARGV" | wc -l)" -eq 2 ]
    cwd=$(tr ' ' '\n' < "$STUB_ARGV" | grep -A1 -- '--cwd' | sed -n 2p)
    git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null
}

@test "snapshot records a listed run and matches it by project, name and message" {
    export STUB_PAYLOAD="$ONE_SHIP_RUN"
    archon_runs_snapshot
    archon_runs_known
    archon_run_active /mnt/ext-fast/filmduel filmduel '^archon-ship$' '#528([^0-9]|$)'
    ! archon_run_active /mnt/ext-fast/filmduel filmduel '^archon-ship$' '#52([^0-9]|$)'
    ! archon_run_active /mnt/ext-fast/reli reli '^archon-ship$'
    [ "$(archon_run_active_msg /mnt/ext-fast/filmduel filmduel '^archon-ship$')" = "fix #528" ]
}

@test "CLI error payload marks the snapshot unknown and says so on stderr" {
    export STUB_PAYLOAD="$NOT_A_REPO" STUB_RC=1
    run --separate-stderr archon_runs_snapshot
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"could not list running runs"* ]]
    [[ "$stderr" == *"could not list paused runs"* ]]
    [[ "$stderr" == *"Not in a git repository"* ]]
    archon_runs_snapshot
    ! archon_runs_known
    [ ! -s "$ARCHON_RUNS_SNAPSHOT" ]
    ! archon_run_active /mnt/ext-fast/filmduel filmduel '^archon-ship$'
}

@test "empty CLI output marks the snapshot unknown" {
    export STUB_PAYLOAD="" STUB_RC=1
    run --separate-stderr archon_runs_snapshot
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"no output from archon"* ]]
}

@test "pr_owned_by_live_run defers archon branches when the snapshot is unknown" {
    export STUB_PAYLOAD="$NOT_A_REPO" STUB_RC=1
    archon_runs_snapshot 2>/dev/null
    PROJECT=filmduel; REPO_DIR=/mnt/ext-fast/filmduel
    LOGGED="$T/logged"; log() { echo "$*" >> "$LOGGED"; }
    load_pr_owned_by_live_run

    pr_owned_by_live_run 555 archon/task-archon-ship-1789045232455 "Closes #528"
    grep -q 'PR #555 (archon/task-archon-ship-1789045232455) — no archon run snapshot' "$LOGGED"
    ! pr_owned_by_live_run 556 dependabot/npm_and_yarn/frontend/vitest-5.0.0 "bump vitest"
}

@test "pr_owned_by_live_run matches the run on the PR's closing keyword" {
    export STUB_PAYLOAD="$ONE_SHIP_RUN"
    archon_runs_snapshot
    PROJECT=filmduel; REPO_DIR=/mnt/ext-fast/filmduel
    log() { :; }
    load_pr_owned_by_live_run

    pr_owned_by_live_run 555 archon/task-archon-ship-1789045232455 "## Problem  ...  Closes #528"
    ! pr_owned_by_live_run 556 archon/task-archon-ship-1789045232999 "Closes #530"
    # No closing keyword: any live ship run for the project owns it.
    pr_owned_by_live_run 557 archon/task-archon-ship-1789045232999 "no keyword here"
}
