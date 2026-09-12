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
    # $STUB_PAYLOAD_PAUSED, when set, answers the `--status paused` listing
    # instead — a paused run is only ever in that one, and a snapshot that
    # carries it twice hides duplicate rows from every assertion below.
    cat > "$T/bin/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$STUB_ARGV"
if [ -n "${STUB_PAYLOAD_PAUSED:-}" ] && [[ " $* " == *" --status paused "* ]]; then
  printf '%s' "$STUB_PAYLOAD_PAUSED"
else
  printf '%s' "$STUB_PAYLOAD"
fi
exit "${STUB_RC:-0}"
STUB
    chmod +x "$T/bin/archon"
    export PATH="$T/bin:$PATH"
    export STUB_ARGV="$T/argv"
    export STUB_RC=0
    export STUB_PAYLOAD_PAUSED=""

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

# ── Pause classification and archon_parked_runs ──────────────────────────────
#
# Fixtures mirror the metadata shapes archon writes: a `wait:` node records
# metadata.wait, an approval gate records metadata.approval, and a scheduler
# deferring after a failed resume stamps a top-level continuation_retry_at.

paused_run() {
    # $1 run id, $2 metadata JSON body (without workflow_source)
    printf '{"runs": [{"id": "%s", "workflow_name": "archon-ship", "status": "paused",
      "user_message": "fix #361", "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/un-reminder"}, %s}}]}' \
      "$1" "$2"
}

iso() { date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%S.000Z; }

ci_wait() {
    # $1 seconds until resumeAt, $2 seconds since waitingSince
    printf '"wait": {"owner": "loop_group", "nodeId": "deliver__await-checks", "bodyWaitId": "ci-pause",
      "kind": "time", "iteration": 1, "sessionId": null, "sessionProvider": null,
      "waitingSince": "%s", "resumeAt": "%s"}' "$(iso "-$2")" "$(iso "$1")"
}

snapshot_field() { awk -F'\t' -v n="$1" 'NR==1 { print $n }' "$ARCHON_RUNS_SNAPSHOT"; }

no_running() { export STUB_PAYLOAD='{"runs": []}'; }

@test "a fresh CI wait classifies as wait, is not parked, and still counts as active" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-aaaa "$(ci_wait 240 60)")"
    archon_runs_snapshot
    [ "$(snapshot_field 5)" = "500946af-aaaa" ]
    [ "$(snapshot_field 6)" = "wait" ]
    [ -z "$(archon_parked_runs 1800)" ]
    # The guard relaxation #77 asked for is exactly what must NOT happen here.
    archon_run_active /mnt/ext-fast/un-reminder un-reminder '^archon-ship$'
}

@test "a CI wait two hours past its resumeAt is parked, with that deadline in the row" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-bbbb "$(ci_wait -7200 7500)")"
    archon_runs_snapshot
    row=$(archon_parked_runs 1800)
    [ "$(printf '%s' "$row" | cut -f1)" = "500946af-bbbb" ]
    [ "$(printf '%s' "$row" | cut -f2)" = "wait" ]
    [ "$(printf '%s' "$row" | cut -f3)" = "archon-ship" ]
    [ "$(printf '%s' "$row" | cut -f5)" = "fix #361" ]
    deadline=$(printf '%s' "$row" | cut -f6)
    [ "$deadline" -gt 0 ]
    [ "$(( $(date +%s) - deadline ))" -gt 7000 ]
}

@test "a stale resumeAt with a fresh continuation_retry_at is the server still retrying" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-cccc \
      "$(ci_wait -7200 7500), \"continuation_retry_at\": \"$(iso -10)\"")"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "wait" ]
    # Deadline path clears, but three hours at one wait trips the backstop.
    [ -z "$(archon_parked_runs 1800 14400)" ]
    [ "$(archon_parked_runs 1800 7200 | cut -f1)" = "500946af-cccc" ]
}

@test "the default hard_max is 4x stale — what the one-argument call site gets" {
    # pipeline-health-cron.sh passes PARKED_WAIT_MAX_SECONDS alone, so the
    # backstop nobody can see in a call argument is 1800 * 4 = 2 hours. Both
    # fixtures keep continuation_retry_at fresh, so only the backstop decides.
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-1111 \
      "$(ci_wait -7200 7500), \"continuation_retry_at\": \"$(iso -10)\"")"
    archon_runs_snapshot
    [ "$(archon_parked_runs 1800 | cut -f1)" = "500946af-1111" ]

    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-2222 \
      "$(ci_wait -7200 7000), \"continuation_retry_at\": \"$(iso -10)\"")"
    archon_runs_snapshot
    [ -z "$(archon_parked_runs 1800)" ]
}

@test "an unresolved approval gate classifies as gate and is parked immediately" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-dddd \
      '"approval": {"nodeId": "review-gate", "message": "Ship it?", "type": "approval"}')"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "gate" ]
    [ "$(archon_parked_runs 1800 | cut -f2)" = "gate" ]
    # Reported to a human, yet still active: pr-maintenance must not merge or
    # abandon the PR a run pending an answer still owns.
    archon_run_active /mnt/ext-fast/un-reminder un-reminder '^archon-ship$'
}

@test "a resolved gate is reported: the machine owed the resume and did not make it" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-eeee \
      '"approval": {"nodeId": "review-gate", "message": "Ship it?", "resolved": "approved"}')"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "resolved" ]
    # No continuation scan ever looks at metadata.approval, so a resolved gate
    # still here on the next tick has nothing left that would resume it.
    [ "$(archon_parked_runs 1800 | cut -f2)" = "resolved" ]
    archon_run_active /mnt/ext-fast/un-reminder un-reminder '^archon-ship$'
}

@test "a parent blocked on a live child is progress, not a stall" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-7777 \
      '"approval": {"nodeId": "sub-run", "message": "child paused", "type": "child_workflow",
        "childRunId": "500946af-8888"}')"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "blocked_on_child" ]
    [ -z "$(archon_parked_runs 1800)" ]
    archon_run_active /mnt/ext-fast/un-reminder un-reminder '^archon-ship$'
}

@test "a child_workflow pause with no child to follow is unreadable" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-9999 \
      '"approval": {"nodeId": "sub-run", "message": "child paused", "type": "child_workflow"}')"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "unreadable" ]
    [ "$(archon_parked_runs 1800 | cut -f1)" = "500946af-9999" ]
}

@test "paused with neither a gate nor a usable wait is unreadable and parked" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-ffff '"note": "nothing describes this pause"')"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "unreadable" ]
    [ "$(archon_parked_runs 1800 | cut -f2)" = "unreadable" ]

    archon_run_active /mnt/ext-fast/un-reminder un-reminder '^archon-ship$'

    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-0000 '"approval": {"nodeId": "", "message": "x"}')"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "unreadable" ]
    archon_run_active /mnt/ext-fast/un-reminder un-reminder '^archon-ship$'
}

@test "a running run carries an empty class and is never parked" {
    export STUB_PAYLOAD="$ONE_SHIP_RUN"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "" ]
    [ -z "$(archon_parked_runs 1800)" ]
}
