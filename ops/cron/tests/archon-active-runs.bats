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
    ARCHON_FAILED_RUNS_SNAPSHOT="$T/snapshot.failed"
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

ci_attention() {
    # $1 seconds since waitingSince, $2 the bodyWaitId (default the CI attention step)
    printf '"wait": {"owner": "loop_group", "nodeId": "deliver__ci-attention", "bodyWaitId": "%s",
      "iteration": 1, "sessionId": null, "sessionProvider": null, "kind": "attention",
      "waitingSince": "%s",
      "message": "CI remains non-green for pull request #735: validate-specs (failure) Re-run the failing check, then resume this run."}' \
      "${2:-attention-ci-pause}" "$(iso "-$1")"
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
    [ "$(snapshot_field 10)" = "review-gate" ]
    [ "$(snapshot_field 11)" = "Ship it?" ]
    [ "$(archon_parked_runs 1800 | cut -f2)" = "gate" ]
    # Reported to a human, yet still active: pr-maintenance must not merge or
    # abandon the PR a run pending an answer still owns.
    archon_run_active /mnt/ext-fast/un-reminder un-reminder '^archon-ship$'
}

@test "a CI attention pause classifies as attention with its step and message, and stays active" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 5deb98da-aaaa "$(ci_attention 3600)")"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "attention" ]
    [ "$(snapshot_field 10)" = "deliver__ci-attention.attention-ci-pause" ]
    [[ "$(snapshot_field 11)" == "CI remains non-green for pull request #735:"*"resume this run." ]]
    [ "$(snapshot_field 8)" -gt 0 ]
    # pr-maintenance resumes it once its PR is green; until then nobody else
    # hears about it, and it still owns its PR.
    [ -z "$(archon_parked_runs 1800)" ]
    archon_run_active /mnt/ext-fast/un-reminder un-reminder '^archon-ship$'
}

@test "a CI attention pause past the day's grace is parked, naming step and need" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 5deb98da-bbbb "$(ci_attention 90000)")"
    archon_runs_snapshot
    row=$(archon_parked_runs 1800)
    [ "$(printf '%s\n' "$row" | wc -l)" -eq 1 ]
    [ "$(printf '%s' "$row" | cut -f1)" = "5deb98da-bbbb" ]
    [ "$(printf '%s' "$row" | cut -f2)" = "attention" ]
    [ "$(printf '%s' "$row" | cut -f7)" = "deliver__ci-attention.attention-ci-pause" ]
    [[ "$(printf '%s' "$row" | cut -f8)" == "CI remains non-green"* ]]
}

@test "any other attention pause is parked immediately" {
    no_running
    # redeploy-attention-ci-pause only ends like the CI attention step.
    for step in deploy-approval-pause redeploy-attention-ci-pause; do
        export STUB_PAYLOAD_PAUSED="$(paused_run 5deb98da-cccc "$(ci_attention 60 "$step")")"
        archon_runs_snapshot
        [ "$(snapshot_field 6)" = "attention" ]
        [ "$(archon_parked_runs 1800 | cut -f7)" = "deliver__ci-attention.$step" ]
    done
}

@test "archon_branch_ci_attention_run names the CI attention run whose worktree is the branch" {
    no_running
    attention_on() { # $1 id, $2 metadata — paused on archon/task-archon-ship-17
        printf '{"id": "%s", "workflow_name": "archon-ship", "status": "paused", "user_message": "fix #74",
          "working_path": "/w/proj/worktrees/archon/task-archon-ship-17",
          "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/proj"}, %s}}' "$1" "$2"
    }
    export STUB_PAYLOAD_PAUSED="{\"runs\": [$(attention_on run-ci "$(ci_attention 60)")]}"
    archon_runs_snapshot
    [ "$(archon_branch_ci_attention_run archon/task-archon-ship-17)" = "run-ci" ]
    run ! archon_branch_ci_attention_run archon/task-archon-ship-7
    run ! archon_branch_ci_attention_run ""

    for meta in "$(ci_attention 60 deploy-approval-pause)" "$(ci_attention 60 redeploy-attention-ci-pause)" \
                "$(ci_wait 240 60)" \
                '"approval": {"nodeId": "attention-ci-pause", "message": "Ship it?", "type": "approval"}'; do
        export STUB_PAYLOAD_PAUSED="{\"runs\": [$(attention_on run-other "$meta")]}"
        archon_runs_snapshot
        run ! archon_branch_ci_attention_run archon/task-archon-ship-17
    done
}

@test "archon_branch_running_run names only a running run whose worktree is the branch" {
    export STUB_PAYLOAD='{"runs": [{"id": "run-live", "workflow_name": "archon-ship-block", "status": "running", "user_message": "fix #9",
      "working_path": "/w/proj/worktrees/archon/task-archon-ship-block-17",
      "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/proj"}}}]}'
    export STUB_PAYLOAD_PAUSED='{"runs": [{"id": "run-paused", "workflow_name": "archon-ship", "status": "paused", "user_message": "fix #8",
      "working_path": "/w/proj/worktrees/archon/task-archon-ship-18",
      "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/proj"}}}]}'
    archon_runs_snapshot
    [ "$(archon_branch_running_run archon/task-archon-ship-block-17)" = "run-live" ]
    run ! archon_branch_running_run archon/task-archon-ship-18
    run ! archon_branch_running_run archon/task-archon-ship-block-1
    run ! archon_branch_running_run ""
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

@test "snapshot records the run's worktree as field 9 and archon_worktree_active matches it exactly" {
    export STUB_PAYLOAD='{"runs": [{"workflow_name": "archon-ship", "status": "running", "user_message": "fix #9",
      "working_path": "/w/musenmingle/worktrees/archon/task-archon-ship-1",
      "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/musenmingle"}}}]}'
    export STUB_PAYLOAD_PAUSED='{"runs": []}'
    archon_runs_snapshot
    [ "$(snapshot_field 9)" = "/w/musenmingle/worktrees/archon/task-archon-ship-1" ]
    archon_worktree_active /w/musenmingle/worktrees/archon/task-archon-ship-1
    archon_worktree_active /elsewhere /w/musenmingle/worktrees/archon/task-archon-ship-1
    ! archon_worktree_active /w/musenmingle/worktrees/archon/task-archon-ship-10
    ! archon_worktree_active /mnt/ext-fast/musenmingle
    archon_run_active /mnt/ext-fast/musenmingle musenmingle '^archon-ship$' '#9'
}

@test "a listing that returns fewer runs than its total marks the snapshot unknown" {
    export STUB_PAYLOAD='{"runs": [], "total": 0}'
    export STUB_PAYLOAD_PAUSED='{"runs": [{"workflow_name": "archon-ship", "status": "paused",
      "working_path": "/w/musenmingle/worktrees/archon/task-archon-ship-1",
      "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/musenmingle"}}}], "total": 101}'
    run --separate-stderr archon_runs_snapshot
    [[ "$stderr" == *"could not list paused runs"*"listing truncated: 1 of 101 runs returned"* ]]
    archon_runs_snapshot 2>/dev/null
    ! archon_runs_known
    ! archon_worktrees_known
}

@test "archon_worktrees_known fails while an active run has no working_path" {
    export STUB_PAYLOAD='{"runs": [{"workflow_name": "archon-ship", "status": "running",
      "working_path": "/w/musenmingle/worktrees/archon/task-archon-ship-1",
      "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/musenmingle"}}}], "total": 1}'
    export STUB_PAYLOAD_PAUSED='{"runs": [], "total": 0}'
    archon_runs_snapshot
    archon_worktrees_known

    export STUB_PAYLOAD_PAUSED='{"runs": [{"workflow_name": "archon-ship", "status": "paused", "working_path": null,
      "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/musenmingle"}}}], "total": 1}'
    archon_runs_snapshot
    archon_runs_known
    ! archon_worktrees_known
}

# ── Stalled tool calls ───────────────────────────────────────────────────────
#
# metadata.tool_call_attention as archon writes it for a running run: one
# entry per tool call that has gone toolCallAttentionMs without progress.

stalled_entry() {
    # $1 nodeId, $2 title, $3 seconds since lastProgressAt
    printf '{"streamId": "s1", "nodeId": "%s", "provider": "claude", "toolCallId": "subtask:%s",
      "name": "Bash", "title": "%s", "startedAt": "%s", "lastProgressAt": "%s",
      "raisedAt": "%s", "thresholdMs": 1800000}' \
      "$1" "$1" "$2" "$(iso "-$3")" "$(iso "-$3")" "$(iso "-$(( $3 - 1800 ))")"
}

running_run() {
    # $1 run id, $2 metadata JSON body (without workflow_source)
    printf '{"id": "%s", "workflow_name": "archon-ship-block", "status": "running", "user_message": "fix #242",
      "working_path": "/w/proj/worktrees/archon/task-%s",
      "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/proj"}%s}}' "$1" "$1" "${2:+, $2}"
}

@test "a running run's oldest stalled tool call past the threshold is reported once" {
    local three_h
    export STUB_PAYLOAD="{\"runs\": [$(running_run 197afe4f-aaaa "\"tool_call_attention\": [
      $(stalled_entry deliver__review 'bats run' 3600),
      $(stalled_entry deliver__update-pr-body 'wait for bats' 10800)]")]}"
    export STUB_PAYLOAD_PAUSED='{"runs": []}'
    archon_runs_snapshot
    three_h=$(snapshot_field 12)
    [ $(( $(date +%s) - three_h - 10800 )) -le 2 ]

    run archon_stalled_tool_calls 7200
    [ "${#lines[@]}" -eq 1 ]
    [ "$output" = "$(printf '197afe4f-aaaa\tarchon-ship-block\t/mnt/ext-fast/proj\tfix #242\t%s\tdeliver__update-pr-body: wait for bats' "$three_h")" ]

    [ -z "$(archon_stalled_tool_calls 14400)" ]
}

@test "a running run with no stalled call carries 0 and nothing, and is not reported" {
    export STUB_PAYLOAD="{\"runs\": [$(running_run run-null '"tool_call_attention": null'),
      $(running_run run-absent)]}"
    export STUB_PAYLOAD_PAUSED='{"runs": []}'
    archon_runs_snapshot
    [ "$(awk -F'\t' '{ print $5 "|" $6 "|" $9 "|" $12 "|" $13 }' "$ARCHON_RUNS_SNAPSHOT")" = \
      "$(printf 'run-null||/w/proj/worktrees/archon/task-run-null|0|\nrun-absent||/w/proj/worktrees/archon/task-run-absent|0|')" ]
    [ -z "$(archon_stalled_tool_calls 0)" ]
}

@test "a listed call with no readable lastProgressAt is reported at once, not dropped" {
    export STUB_PAYLOAD="{\"runs\": [$(running_run run-bad "\"tool_call_attention\": [
      $(stalled_entry deliver__review 'bats run' 600),
      {\"nodeId\": \"deliver__update-pr-body\", \"title\": \"wait for bats\", \"lastProgressAt\": \"soon\"}]"),
      $(running_run run-odd '"tool_call_attention": {}')]}"
    export STUB_PAYLOAD_PAUSED='{"runs": []}'
    archon_runs_snapshot

    run archon_stalled_tool_calls 86400
    [ "$output" = "$(printf 'run-bad\tarchon-ship-block\t/mnt/ext-fast/proj\tfix #242\t-1\tdeliver__update-pr-body: wait for bats
run-odd\tarchon-ship-block\t/mnt/ext-fast/proj\tfix #242\t-1\tunreadable tool_call_attention')" ]
}

@test "a paused run's stale tool_call_attention is never reported" {
    no_running
    export STUB_PAYLOAD_PAUSED="$(paused_run 500946af-aaaa "$(ci_wait 240 60),
      \"tool_call_attention\": [$(stalled_entry deliver__update-pr-body 'wait for bats' 10800)]")"
    archon_runs_snapshot
    [ "$(snapshot_field 6)" = "wait" ]
    [ "$(snapshot_field 12)" = "0" ]
    [ -z "$(archon_stalled_tool_calls 7200)" ]
}

# ── failed runs nothing adopted (`workflow runs --open`) ─────────────────────

FAILED_SHIP_RUN='{"runs": [{"id": "run-329", "workflow_name": "archon-ship", "status": "failed",
  "working_path": "/w/un-reminder/worktrees/archon/task-archon-ship-17"}], "total": 1}'

@test "failed-run snapshot asks for the unadopted failed runs of every project" {
    export STUB_PAYLOAD='{"runs": [], "total": 0}'
    archon_failed_runs_snapshot
    archon_failed_runs_known
    [[ "$(cat "$STUB_ARGV")" == "workflow runs --all --open --limit 10000 --json --cwd "* ]]
}

@test "archon_branch_failed_run names the failed run whose worktree is the branch" {
    export STUB_PAYLOAD="$FAILED_SHIP_RUN"
    archon_failed_runs_snapshot
    [ "$(archon_branch_failed_run archon/task-archon-ship-17)" = "run-329" ]
    # Whole path components only.
    ! archon_branch_failed_run archon/task-archon-ship-7
    ! archon_branch_failed_run ship-17
    ! archon_branch_failed_run ""
}

@test "a failed-run listing error marks it unknown and says so on stderr" {
    export STUB_PAYLOAD="$NOT_A_REPO" STUB_RC=1
    run --separate-stderr archon_failed_runs_snapshot
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"could not list failed runs"*"Not in a git repository"* ]]
    archon_failed_runs_snapshot 2>/dev/null
    ! archon_failed_runs_known
    ! archon_branch_failed_run archon/task-archon-ship-17
}

@test "a failed-run listing that fills its limit is treated as truncated" {
    export STUB_PAYLOAD="$FAILED_SHIP_RUN"
    ARCHON_FAILED_RUNS_LIMIT=1
    run --separate-stderr archon_failed_runs_snapshot
    [[ "$stderr" == *"listing may be truncated: 1 runs at --limit 1"* ]]
    archon_failed_runs_snapshot 2>/dev/null
    ! archon_failed_runs_known
    ! archon_branch_failed_run archon/task-archon-ship-17
}
