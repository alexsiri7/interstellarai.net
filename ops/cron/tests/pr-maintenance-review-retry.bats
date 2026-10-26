#!/usr/bin/env bats
# Tests for pr-maintenance-cron.sh's review-stage retry: a PR left by a failed
# archon-ship-block run whose ONLY failure is its AI review stage is resumed
# (never adopted, never merged here) once its checks are green, at most once
# per project per tick and REVIEW_RETRY_MAX times per PR. And for the failure
# classifier in lib/archon-active-runs.sh, which fails closed.
#
# Same harness as pr-maintenance-failed-run.bats: the real script end to end,
# with `gh` and `archon` stubbed in $HOME/.local/bin under a temp HOME.
#
# Run: npx bats@1.13.0 ops/cron/tests/pr-maintenance-review-retry.bats

bats_require_minimum_version 1.5.0

# Real metadata.error strings from the 2026-10-26 parked runs.
ROUTE_ERR="DAG workflow 'archon-ship-block' completed with failures: 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 3: 'review__route': Node 'review__route': output_format declared but the provider returned no schema-valid structured output. The model likely replied with prose, refused, or emitted unparseable JSON.; 'review__synthesize': '\$review__route.output' references node 'review__route', but it failed (Node 'review__route': output_format declared but the provider returned no schema-valid structured output. The model likely replied with prose, refused, or emitted unparseable JSON.), so its output cannot be spliced into this node's prompt/script — a failed producer's stale output is never trusted. Fix the failure, or guard this node with a 'when:' condition that excludes the failed branch."
SCOPE_ERR="DAG workflow 'archon-ship-block' completed with failures: 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 2: 'review__scope': Node \`review__scope\` declared \`mutates_checkout: false\` but modified the working tree: openspec/specs/in-app-feedback/spec.md; 'review__review-complete': '\$review__scope.output.head_matches' references field 'head_matches', but node 'review__scope' failed, so its output cannot be trusted. Guard this reference with a 'when:' condition, or fix the failure."

setup() {
    export T="$BATS_TMPDIR/review-retry-$$"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    export HOME="$T/home"
    STUB_BIN="$HOME/.local/bin"
    mkdir -p "$STUB_BIN" "$T/base/proj/.git" "$HOME/.config/archon-cron"
    export BASE_DIR="$T/base"
    export ARCHON_CRON_FORCE_TICK=1
    export ARCHON_RUNS_SNAPSHOT="$T/snapshot"
    export ARCHON_PROJECTS_FILE="$T/projects.txt"
    echo "proj" > "$ARCHON_PROJECTS_FILE"
    printf 'NTFY_TOPIC=test-topic\n' > "$HOME/.config/archon-cron/secrets.env"
    unset NTFY_TOPIC _ARCHON_TRUST_SH TRUSTED_AUTHORS TRUSTED_ISSUE_BOTS TRUSTED_MERGE_ONLY_AUTHORS TRUSTED_COMMENT_BOTS TRUST_STATE_DIR ARCHON_CRON_TRUST_FILE ARCHON_CRON_SECRETS REVIEW_RETRY_MAX

    export STUB_GH_ARGV="$T/gh-argv" STUB_ARCHON_ARGV="$T/archon-argv"
    : > "$STUB_GH_ARGV"; : > "$STUB_ARCHON_ARGV"
    export GH_CHECKS='{"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}]}'
    export GH_COMMENTS_DIR="$T/comments"
    mkdir -p "$GH_COMMENTS_DIR"
    export ARCHON_OPEN_RUNS='{"runs": [], "total": 0}'
    export ARCHON_LIVE_RUNS='{"runs": [], "total": 0}'

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
if [ "$1 $2" = "pr list" ]; then printf '%s' "$GH_PR_LIST"; fi
if [ "$1 $2" = "pr view" ]; then
  case " $* " in *statusCheckRollup*) printf '%s' "$GH_CHECKS" ;; *) printf '{"title":"t","body":"b"}' ;; esac
fi
[ "$1 $2" = "issue view" ] && printf '{"labels":[]}'
if [ "$1 $2" = "api --paginate" ]; then
  [ -n "${GH_COMMENTS_FAIL:-}" ] && exit 1
  key=$(sed -E 's#^repos/[^/]+/[^/]+/(issues|pulls)/([0-9]+)/(comments|reviews)$#\1-\2-\3#' <<<"$3")
  cat "$GH_COMMENTS_DIR/$key" 2>/dev/null || true
fi
exit 0
STUB
    cat > "$STUB_BIN/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARCHON_ARGV"
if [ "$1 $2" = "workflow runs" ]; then
  case " $* " in
    *" --open "*) printf '%s' "$ARCHON_OPEN_RUNS" ;;
    *" --status running "*) printf '%s' "$ARCHON_LIVE_RUNS" ;;
    *) printf '{"runs": [], "total": 0}' ;;
  esac
fi
[ "$1 $2" = "workflow resume" ] && echo '{"ok":true,"action":"resume"}'
exit 0
STUB
    chmod +x "$STUB_BIN/gh" "$STUB_BIN/archon"
    export PATH="$STUB_BIN:$PATH"
}

teardown() {
    rm -rf "$T"
}

pr() { # pr <number> <branch> [author] — a non-draft, BLOCKED owner PR (not CLEAN: Phase 1 must not matter)
    printf '{"number": %s, "isDraft": false, "mergeStateStatus": "BLOCKED", "headRefName": "%s", "headRefOid": "sha%s", "body": "Fixes #1", "labels": [], "author": {"login": "%s"}, "isCrossRepository": false, "title": "t", "createdAt": "2026-10-20T00:00:00Z"}' \
        "$1" "$2" "$1" "${3:-alexsiri7}"
}

wt() { mkdir -p "$T/wt/$1"; printf '%s' "$T/wt/$1"; }

run_obj() { # run_obj <id> <branch> <error> — a failed run whose worktree exists
    jq -nc --arg id "$1" --arg wp "$(wt "$2")" --arg e "$3" \
      '{id: $id, workflow_name: "archon-ship-block", status: "failed", user_message: "fix #1", working_path: $wp, metadata: {error: $e}}'
}

runs() { printf '{"runs": [%s], "total": %s}' "$(IFS=,; echo "$*")" "$#"; }

resumed() { grep -cE "^workflow resume $1 --detach --json" "$STUB_ARCHON_ARGV" || true; }
gh_called() { grep -qE "$1" "$STUB_GH_ARGV"; }

# ── classifier (lib/archon-active-runs.sh) ───────────────────────────────────

classify() { # classify <error or "null"> — print the class of one failed run
    export ARCHON_OPEN_RUNS
    if [ "$1" = null ]; then
        ARCHON_OPEN_RUNS='{"runs":[{"id":"r1","working_path":"/w/b","metadata":{}}],"total":1}'
    else
        ARCHON_OPEN_RUNS=$(jq -nc --arg e "$1" '{runs:[{id:"r1",working_path:"/w/b",metadata:{error:$e}}],total:1}')
    fi
    (
        # shellcheck source=../lib/archon-active-runs.sh
        source "$CRON_DIR/lib/archon-active-runs.sh"
        archon_failed_runs_snapshot
        archon_failed_run_class r1
    )
}

@test "classifier: the real review-stage failures are review" {
    [ "$(classify "$ROUTE_ERR")" = review ]
    [ "$(classify "$SCOPE_ERR")" = review ]
    [ "$(classify "DAG workflow 'archon-ship-block' completed with failures: 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 1: 'review__seams': Claude API error")" = review ]
}

@test "classifier: anything else is other (fail closed)" {
    # A top-level review node of archon-ship, not the rounds loop.
    [ "$(classify "DAG workflow 'archon-ship' completed with failures: 'deliver__review__code': Claude API error (rate_limit)")" = other ]
    # An implementation node failed inside the rounds.
    [ "$(classify "DAG workflow 'archon-ship-block' completed with failures: 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 1: 'impl__implement': boom")" = other ]
    # Review plus a non-review node inside the rounds.
    [ "$(classify "DAG workflow 'archon-ship-block' completed with failures: 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 1: 'review__code': x; 'pr__publish': y")" = other ]
    # The rounds plus a second top-level failure, after it or before it.
    [ "$(classify "DAG workflow 'archon-ship-block' completed with failures: 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 1: 'review__code': x; 'outcome': y")" = other ]
    [ "$(classify "DAG workflow 'archon-ship-block' completed with failures: 'triage__triage': x; 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 1: 'review__code': y")" = other ]
    # No inner node named at all.
    [ "$(classify "DAG workflow 'archon-ship-block' completed with failures: 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 1: ")" = other ]
    # Other shapes.
    [ "$(classify "DAG workflow 'archon-ship' failed: node triage__triage failed. 3 downstream nodes were skipped.")" = other ]
    [ "$(classify "Process terminated (SIGTERM)")" = other ]
    [ "$(classify "")" = other ]
    [ "$(classify null)" = other ]
}

@test "classifier: an unknown run id is other" {
    ARCHON_OPEN_RUNS='{"runs":[],"total":0}'
    run bash -c 'source "$0"; archon_failed_runs_snapshot; archon_failed_run_class nope' "$CRON_DIR/lib/archon-active-runs.sh"
    [ "$output" = other ]
}

# ── pr-maintenance-cron.sh ───────────────────────────────────────────────────

@test "a green PR left by a review-stage failure is resumed once, counted first, never merged or adopted" {
    export GH_PR_LIST="[$(pr 361 archon/task-a)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "$ROUTE_ERR")")
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    [ "$(resumed run-361)" -eq 1 ]
    [ "$(cat "$HOME/.archon/state/pr-maintenance/proj-361.review-retries")" = 1 ]
    [[ "$output" == *"PR #361 is green and run run-361 failed only in review — resuming it (review retry 1/2)"* ]]
    ! grep -q -- '--adopt' "$STUB_ARCHON_ARGV"
    ! gh_called '^pr merge'
    ! gh_called '^pr ready'
}

@test "a PR is retried at most twice" {
    export GH_PR_LIST="[$(pr 361 archon/task-a)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "$ROUTE_ERR")")
    run "$CRON_DIR/pr-maintenance-cron.sh"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$(resumed run-361)" -eq 2 ]
    [[ "$output" == *"PR #361 — not retrying failed run run-361: out of review retries (2/2)"* ]]
}

@test "at most one retry per project per tick" {
    export GH_PR_LIST="[$(pr 361 archon/task-a), $(pr 362 archon/task-b)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "$ROUTE_ERR")" "$(run_obj run-362 archon/task-b "$SCOPE_ERR")")
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$(( $(resumed run-361) + $(resumed run-362) ))" -eq 1 ]
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$(resumed run-361)" -eq 1 ] || [ "$(resumed run-361)" -eq 2 ]
    [ "$(( $(resumed run-361) + $(resumed run-362) ))" -eq 2 ]
}

@test "a non-review failure is never resumed" {
    export GH_PR_LIST="[$(pr 361 archon/task-a)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "DAG workflow 'archon-ship-block' completed with failures: 'deliver__rounds': Loop-group node 'deliver__rounds' failed at iteration 1: 'impl__implement': boom")")
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$(resumed run-361)" -eq 0 ]
    [[ "$output" == *"PR #361 — not retrying failed run run-361: its failure is not review-stage only"* ]]
    [ ! -e "$HOME/.archon/state/pr-maintenance/proj-361.review-retries" ]
}

@test "red, pending or missing checks hold the retry, and spend none" {
    export GH_PR_LIST="[$(pr 361 archon/task-a)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "$ROUTE_ERR")")
    for checks in '{"statusCheckRollup":[{"name":"ci","conclusion":"FAILURE"}]}' \
                  '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}]}' \
                  '{"statusCheckRollup":[]}'; do
        GH_CHECKS="$checks" run "$CRON_DIR/pr-maintenance-cron.sh"
        [[ "$output" == *"not retrying failed run run-361: its checks are not all green"* ]]
    done
    [ "$(resumed run-361)" -eq 0 ]
    [ ! -e "$HOME/.archon/state/pr-maintenance/proj-361.review-retries" ]
}

@test "the Claude rate-limit hold keeps the retry, and spends none" {
    export GH_PR_LIST="[$(pr 361 archon/task-a)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "$ROUTE_ERR")")
    # A recent rate-limit error in the run DB is what quota_may_launch reads.
    export ARCHON_DB="$T/archon.db"
    local spec; spec=$(TZ=Europe/London date -d '+2 hours' '+%-I%P')
    sqlite3 "$ARCHON_DB" "CREATE TABLE remote_agent_workflow_events (id INTEGER PRIMARY KEY,
        workflow_run_id TEXT, event_type TEXT, data TEXT, created_at TEXT DEFAULT (datetime('now')));
      INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, data)
        VALUES ('r1', 'node_failed', '{\"error\":\"You have hit your weekly limit · resets $spec (Europe/London)\"}');"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [[ "$output" == *"failed run run-361 may retry its review, held: Claude rate limit in effect"* ]]
    [ "$(resumed run-361)" -eq 0 ]
    [ ! -e "$HOME/.archon/state/pr-maintenance/proj-361.review-retries" ]
}

@test "a gone worktree, a held PR, untrusted or unreadable comments, or a live run hold the retry" {
    export GH_PR_LIST="[$(pr 361 archon/task-a)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "$ROUTE_ERR")")
    # Untrusted comment.
    echo stranger > "$GH_COMMENTS_DIR/issues-361-comments"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [[ "$output" == *"not retrying failed run run-361: it has untrusted comments or reviews"* ]]
    rm "$GH_COMMENTS_DIR/issues-361-comments"
    # Unreadable comments.
    GH_COMMENTS_FAIL=1 run "$CRON_DIR/pr-maintenance-cron.sh"
    [[ "$output" == *"not retrying failed run run-361: its comments could not be read"* ]]
    # A live run in the same worktree.
    ARCHON_LIVE_RUNS=$(jq -nc --arg wp "$T/wt/archon/task-a" '{runs:[{id:"live-1",workflow_name:"archon-assist",status:"running",user_message:"x",working_path:$wp,metadata:{}}],total:1}')
    ARCHON_LIVE_RUNS="$ARCHON_LIVE_RUNS" run "$CRON_DIR/pr-maintenance-cron.sh"
    [[ "$output" == *"not retrying failed run run-361: a live archon run holds its worktree"* ]]
    # Hold label.
    GH_PR_LIST="[$(pr 361 archon/task-a | jq -c '.labels = [{"name":"hold"}]')]" run "$CRON_DIR/pr-maintenance-cron.sh"
    # Worktree gone.
    rm -rf "$T/wt/archon/task-a"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [[ "$output" == *"not retrying failed run run-361: its worktree $T/wt/archon/task-a is gone"* ]]
    [ "$(resumed run-361)" -eq 0 ]
    [ ! -e "$HOME/.archon/state/pr-maintenance/proj-361.review-retries" ]
}

@test "an unreadable retry counter counts as spent" {
    export GH_PR_LIST="[$(pr 361 archon/task-a)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "$ROUTE_ERR")")
    mkdir -p "$HOME/.archon/state/pr-maintenance"
    echo garbage > "$HOME/.archon/state/pr-maintenance/proj-361.review-retries"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$(resumed run-361)" -eq 0 ]
    [[ "$output" == *"out of review retries"* ]]
}

@test "an unreadable failed-run listing retries nothing" {
    export GH_PR_LIST="[$(pr 361 archon/task-a)]"
    export ARCHON_OPEN_RUNS='{"ok": false, "error": "db down"}'
    run "$CRON_DIR/pr-maintenance-cron.sh"
    ! grep -q '^workflow resume' "$STUB_ARCHON_ARGV"
}

@test "a stranger's PR on a failed branch is never retried" {
    export GH_PR_LIST="[$(pr 361 archon/task-a stranger)]"
    ARCHON_OPEN_RUNS=$(runs "$(run_obj run-361 archon/task-a "$ROUTE_ERR")")
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$(resumed run-361)" -eq 0 ]
}
