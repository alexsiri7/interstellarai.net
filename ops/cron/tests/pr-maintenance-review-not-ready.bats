#!/usr/bin/env bats
# Tests for pr-maintenance-cron.sh's review-not-ready marks: a draft PR on an
# archon branch whose run finished (none running, paused or failed holds the
# branch), whose latest trusted review report says not ready, and whose head
# has not moved for 6h, is marked review-not-ready for lib/deadlines.sh, with
# the review's action in the reason (2026-10-26: punland #50 replan, #51
# needs_human). And for archon_branch_active_run in lib/archon-active-runs.sh.
#
# Same harness as pr-maintenance-review-retry.bats: the real script end to
# end, with `gh` and `archon` stubbed in $HOME/.local/bin under a temp HOME.
# The gh stub applies the caller's --jq to a JSON fixture per endpoint, so the
# trust check and the report read see the same comments. DEADLINE_NOW drives
# the clock.
#
# Run: npx bats@1.13.0 ops/cron/tests/pr-maintenance-review-not-ready.bats

bats_require_minimum_version 1.5.0

H=3600
T0=1800000000

setup() {
    export T="$BATS_TMPDIR/review-not-ready-$$"
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
    unset NTFY_TOPIC _ARCHON_TRUST_SH _ARCHON_DEADLINES_SH TRUSTED_AUTHORS TRUSTED_ISSUE_BOTS TRUSTED_MERGE_ONLY_AUTHORS TRUSTED_COMMENT_BOTS TRUST_STATE_DIR ARCHON_CRON_TRUST_FILE ARCHON_CRON_SECRETS REVIEW_NOT_READY_SECONDS DEADLINE_STATE_DIR

    export STUB_GH_ARGV="$T/gh-argv" STUB_ARCHON_ARGV="$T/archon-argv"
    : > "$STUB_GH_ARGV"; : > "$STUB_ARCHON_ARGV"
    export GH_COMMENTS_DIR="$T/comments"
    mkdir -p "$GH_COMMENTS_DIR"
    export ARCHON_OPEN_RUNS='{"runs": [], "total": 0}'
    export ARCHON_LIVE_RUNS='{"runs": [], "total": 0}'
    export ARCHON_PAUSED_RUNS='{"runs": [], "total": 0}'

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
if [ "$1 $2" = "pr list" ]; then printf '%s' "$GH_PR_LIST"; fi
if [ "$1 $2" = "pr view" ]; then printf '{"title":"t","body":"b","statusCheckRollup":[]}'; fi
[ "$1 $2" = "issue view" ] && printf '{"labels":[]}'
if [ "$1 $2" = "api --paginate" ]; then
  [ -n "${GH_COMMENTS_FAIL:-}" ] && exit 1
  key=$(sed -E 's#^repos/[^/]+/[^/]+/(issues|pulls)/([0-9]+)/(comments|reviews)$#\1-\2-\3#' <<<"$3")
  json=$(cat "$GH_COMMENTS_DIR/$key.json" 2>/dev/null || echo '[]')
  if [ "$4" = "--jq" ]; then printf '%s' "$json" | jq -r "$5"; else printf '%s' "$json"; fi
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
    *" --status paused "*) printf '%s' "$ARCHON_PAUSED_RUNS" ;;
    *) printf '{"runs": [], "total": 0}' ;;
  esac
fi
exit 0
STUB
    chmod +x "$STUB_BIN/gh" "$STUB_BIN/archon"
    export PATH="$STUB_BIN:$PATH"
    D="$HOME/.archon/state/deadlines"
}

teardown() {
    rm -rf "$T"
}

draft() { # draft <number> <branch> [sha] [labels-json] — an owner draft, BLOCKED (never Phase 0/1)
    printf '{"number": %s, "isDraft": true, "mergeStateStatus": "BLOCKED", "headRefName": "%s", "headRefOid": "%s", "body": "Refs #30", "labels": %s, "author": {"login": "alexsiri7"}, "isCrossRepository": false, "title": "t", "createdAt": "2026-10-20T00:00:00Z"}' \
        "$1" "$2" "${3:-sha$1}" "${4:-[]}"
}

report() { # report <login> <updated_at> <verdict line> <ready/action line> — one review-report comment
    jq -nc --arg u "$1" --arg at "$2" --arg v "$3" --arg a "$4" \
      '{user: {login: $u, type: "User"}, created_at: "2026-10-26T00:00:00Z", updated_at: $at,
        body: ("<!-- archon-review-report -->\nReviewed commit: `x`\n" + $v + "\n\n# Review report\n\n## 1. Verdict\n\n" + $a + "\n")}'
}
comments() { # comments <number> <comment-json>... — the PR's issue comments
    printf '[%s]' "$(IFS=,; echo "${*:2}")" > "$GH_COMMENTS_DIR/issues-$1-comments.json"
}

live_run() { # live_run <status> <branch> — a run snapshot row that holds <branch>
    printf '{"runs": [{"id": "run-live", "workflow_name": "archon-ship-block", "status": "%s", "user_message": "fix #30", "working_path": "/w/archon/worktrees/proj/%s", "metadata": {"wait": {"resumeAt": "2099-01-01T00:00:00Z"}}}], "total": 1}' "$1" "$2"
}

tick() { DEADLINE_NOW=$((T0 + $1)) run "$CRON_DIR/pr-maintenance-cron.sh"; } # tick <seconds after T0>
marked() { [ -f "$D/$1--proj--$2" ]; }
reason() { awk 'index($0, "reason=") == 1 { print substr($0, 8) }' "$D/$1--proj--$2"; }

NEEDS_HUMAN() { report alexsiri7 2026-10-26T21:11:13Z "Verdict: not ready" "**ready: false** — **action: needs_human**"; }

# ── positive ─────────────────────────────────────────────────────────────────

@test "a finished draft its review left not ready, head unchanged 6h, is marked review-not-ready with the action" {
    export GH_PR_LIST="[$(draft 51 archon/task-archon-ship-block-1)]"
    comments 51 "$(NEEDS_HUMAN)"
    tick 0
    ! marked review-not-ready 51
    tick $((5 * H))
    ! marked review-not-ready 51
    tick $((6 * H))
    marked review-not-ready 51
    [ "$(reason review-not-ready 51)" = "draft left not ready by its review (action: needs_human), head sha51 unchanged 6h" ]
    grep -q '^branch=archon/task-archon-ship-block-1$' "$D/review-not-ready--proj--51"
    grep -q '^sha=sha51$' "$D/review-not-ready--proj--51"
    [[ "$output" == *"draft PR #51 — its run finished, its review says not ready (action: needs_human)"* ]]
}

@test "the replan and correct actions are read through markdown bold and backticks" {
    export GH_PR_LIST="[$(draft 50 archon/task-a), $(draft 52 archon/task-b)]"
    comments 50 "$(report alexsiri7 2026-10-26T18:49:36Z "Verdict: not ready" "**ready: false** — **action: replan**.")"
    comments 52 "$(report alexsiri7 2026-10-26T18:49:36Z "Verdict: not ready" 'ready: false, `action: correct`')"
    tick 0; tick $((6 * H))
    [[ "$(reason review-not-ready 50)" == *"(action: replan)"* ]]
    [[ "$(reason review-not-ready 52)" == *"(action: correct)"* ]]
}

# ── negatives ────────────────────────────────────────────────────────────────

@test "a running run on the branch: not marked" {
    export GH_PR_LIST="[$(draft 51 archon/task-a)]"
    comments 51 "$(NEEDS_HUMAN)"
    ARCHON_LIVE_RUNS=$(live_run running archon/task-a)
    tick 0; tick $((7 * H))
    ! marked review-not-ready 51
}

@test "a paused run on the branch: not marked" {
    export GH_PR_LIST="[$(draft 51 archon/task-a)]"
    comments 51 "$(NEEDS_HUMAN)"
    ARCHON_PAUSED_RUNS=$(live_run paused archon/task-a)
    tick 0; tick $((7 * H))
    ! marked review-not-ready 51
}

@test "a failed run's PR is the failed-run kind's, not this one" {
    export GH_PR_LIST="[$(draft 51 archon/task-a)]"
    comments 51 "$(NEEDS_HUMAN)"
    mkdir -p "$T/wt/archon/task-a"
    ARCHON_OPEN_RUNS=$(jq -nc --arg wp "$T/wt/archon/task-a" '{runs: [{id: "run-f", workflow_name: "archon-ship-block", status: "failed", user_message: "fix #30", working_path: $wp, metadata: {error: "Process terminated (SIGTERM)"}}], total: 1}')
    tick 0; tick $((7 * H))
    ! marked review-not-ready 51
}

@test "a ready verdict: not marked; the newest report by updated_at decides" {
    export GH_PR_LIST="[$(draft 51 archon/task-a)]"
    comments 51 "$(report alexsiri7 2026-10-26T20:00:00Z "Verdict: not ready" "ready: false, action: correct")" \
                "$(report alexsiri7 2026-10-26T22:00:00Z "Verdict: ready" "ready: true, the earlier round was ready: false")"
    tick 0; tick $((7 * H))
    ! marked review-not-ready 51
    # The same two, the not-ready one rewritten last.
    comments 51 "$(report alexsiri7 2026-10-26T23:00:00Z "Verdict: not ready" "ready: false, action: correct")" \
                "$(report alexsiri7 2026-10-26T22:00:00Z "Verdict: ready" "ready: true")"
    tick $((8 * H))
    marked review-not-ready 51
}

@test "no review report, or an action it does not know: not marked" {
    export GH_PR_LIST="[$(draft 51 archon/task-a), $(draft 52 archon/task-b)]"
    comments 51 '{"user": {"login": "alexsiri7", "type": "User"}, "updated_at": "2026-10-26T00:00:00Z", "body": "Verdict: not ready"}'
    comments 52 "$(report alexsiri7 2026-10-26T00:00:00Z "Verdict: not ready" "action: shrug")"
    tick 0; tick $((7 * H))
    ! marked review-not-ready 51
    ! marked review-not-ready 52
}

@test "a recent push: the 6h restart from the new head" {
    export GH_PR_LIST="[$(draft 51 archon/task-a sha-old)]"
    comments 51 "$(NEEDS_HUMAN)"
    tick 0
    export GH_PR_LIST="[$(draft 51 archon/task-a sha-new)]"
    tick $((5 * H))
    tick $((7 * H))
    ! marked review-not-ready 51
    tick $((11 * H))
    marked review-not-ready 51
    [[ "$(reason review-not-ready 51)" == *"head sha-new unchanged 6h"* ]]
}

@test "untrusted comments: marked untrusted, never review-not-ready; a stranger's report is not read" {
    export GH_PR_LIST="[$(draft 51 archon/task-a)]"
    comments 51 "$(NEEDS_HUMAN)" '{"user": {"login": "stranger", "type": "User"}, "updated_at": "2026-10-26T20:00:00Z", "body": "hi"}'
    tick 0; tick $((7 * H))
    ! marked review-not-ready 51
    marked untrusted 51
    # A stranger's newer "report" saying not ready does not count; the trusted
    # one under it says ready.
    rm -rf "$D"
    export GH_PR_LIST="[$(draft 52 archon/task-b)]"
    comments 52 "$(report stranger 2026-10-27T00:00:00Z "Verdict: not ready" "action: correct")" \
                "$(report alexsiri7 2026-10-26T00:00:00Z "Verdict: ready" "ready: true")"
    tick $((8 * H)); tick $((15 * H))
    ! marked review-not-ready 52
}

@test "unreadable comments: nothing marked" {
    export GH_PR_LIST="[$(draft 51 archon/task-a)]"
    comments 51 "$(NEEDS_HUMAN)"
    tick 0
    GH_COMMENTS_FAIL=1 tick $((7 * H))
    [ -z "$(ls -A "$D" 2>/dev/null)" ]
}

@test "hold, a non-archon branch or a non-draft: not marked" {
    export GH_PR_LIST="[$(draft 51 archon/task-a sha51 '[{"name": "hold"}]'), $(draft 52 feat/x), $(draft 53 archon/task-c | sed 's/"isDraft": true/"isDraft": false/')]"
    comments 51 "$(NEEDS_HUMAN)"; comments 52 "$(NEEDS_HUMAN)"; comments 53 "$(NEEDS_HUMAN)"
    tick 0; tick $((7 * H))
    [ -z "$(ls -A "$D" 2>/dev/null)" ]
}

@test "no run snapshot this tick: nothing marked" {
    export GH_PR_LIST="[$(draft 51 archon/task-a)]"
    comments 51 "$(NEEDS_HUMAN)"
    tick 0
    ARCHON_PAUSED_RUNS='{"ok": false, "error": "db locked"}' tick $((7 * H))
    ! marked review-not-ready 51
}

# ── archon_branch_active_run (lib/archon-active-runs.sh) ─────────────────────

@test "archon_branch_active_run matches running and paused runs by worktree tail" {
    printf 'archon-ship-block\trunning\t/o\tm\trun-1\t\t0\t0\t/w/proj/archon/task-a\t\t\n' > "$ARCHON_RUNS_SNAPSHOT"
    printf 'archon-ship-block\tpaused\t/o\tm\trun-2\twait\t0\t0\t/w/proj/archon/task-b\t\t\n' >> "$ARCHON_RUNS_SNAPSHOT"
    run bash -c 'source "$0"; archon_branch_active_run archon/task-a; archon_branch_active_run archon/task-b; archon_branch_active_run archon/task-c || echo none' "$CRON_DIR/lib/archon-active-runs.sh"
    [ "$output" = $'run-1\nrun-2\nnone' ]
}
