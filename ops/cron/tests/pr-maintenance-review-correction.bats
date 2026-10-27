#!/usr/bin/env bats
# Tests for pr-maintenance-cron.sh Phase 2's review corrections (#173): a
# CLEAN PR Phase 1 did not merge, whose latest trusted review report on its
# current head says ready: false, action: correct, gets one archon-assist
# correction per head SHA. A report on an earlier head starts nothing, so the
# correction's own push waits for pr-review-cron's re-review.
#
# Same harness as pr-maintenance-review-not-ready.bats: the real script end to
# end, with `gh` and `archon` stubbed in $HOME/.local/bin under a temp HOME.
# The gh stub refuses `pr merge`, so a CLEAN PR stays open past Phase 1 as an
# ops/ PR held for the owner does.
#
# Run: npx bats@1.13.0 ops/cron/tests/pr-maintenance-review-correction.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/review-correction-$$"
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
    unset NTFY_TOPIC _ARCHON_TRUST_SH _ARCHON_DEADLINES_SH TRUSTED_AUTHORS TRUSTED_ISSUE_BOTS TRUSTED_MERGE_ONLY_AUTHORS TRUSTED_COMMENT_BOTS TRUST_STATE_DIR ARCHON_CRON_TRUST_FILE ARCHON_CRON_SECRETS DEADLINE_STATE_DIR

    export STUB_ARCHON_ARGV="$T/archon-argv"
    : > "$STUB_ARCHON_ARGV"
    export GH_COMMENTS_DIR="$T/comments"
    mkdir -p "$GH_COMMENTS_DIR"
    export ARCHON_OPEN_RUNS='{"runs": [], "total": 0}'

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "pr list" ]; then printf '%s' "$GH_PR_LIST"; fi
if [ "$1 $2" = "pr view" ]; then printf '{"title":"t","body":"b","statusCheckRollup":[]}'; fi
[ "$1 $2" = "pr merge" ] && exit 1
if [ "$1 $2" = "api --paginate" ]; then
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

pr() { # pr <number> <sha> [mergeState] — an owner's ready archon-branch PR
    printf '{"number": %s, "isDraft": false, "mergeStateStatus": "%s", "headRefName": "archon/task-archon-ship-block-%s", "headRefOid": "%s", "body": "Refs #30", "labels": [], "author": {"login": "alexsiri7"}, "isCrossRepository": false, "title": "t", "createdAt": "2026-10-20T00:00:00Z"}' \
        "$1" "${3:-CLEAN}" "$1" "$2"
}

report() { # report <number> <reviewed sha> <verdict line> <ready/action line> — the PR's one review-report comment
    jq -nc --arg sha "$2" --arg v "$3" --arg a "$4" \
      '[{user: {login: "alexsiri7", type: "User"}, created_at: "2026-10-26T00:00:00Z", updated_at: "2026-10-26T00:00:00Z",
         body: ("<!-- archon-review-report -->\nReviewed commit: `" + $sha + "`\n" + $v + "\n\n# Review report\n\n## 1. Verdict\n\n" + $a + "\n")}]' \
      > "$GH_COMMENTS_DIR/issues-$1-comments.json"
}
correct() { report "$1" "$2" "Verdict: not ready" "**ready: false** — action: **correct**."; }

tick() { run "$CRON_DIR/pr-maintenance-cron.sh"; [ "$status" -eq 0 ]; }
launches() { grep -c "^workflow run " "$STUB_ARCHON_ARGV" || true; }

@test "a CLEAN PR its review on this head says to correct gets one archon-assist run per head" {
    export GH_PR_LIST="[$(pr 600 aaaaaaa1)]"
    correct 600 aaaaaaa1
    tick
    tick
    [ "$(launches)" -eq 1 ]
    grep -q "^workflow run archon-assist --cwd $BASE_DIR/proj PR #600 on alexsiri7/proj is green, but its latest archon review report says ready: false, action: correct" "$STUB_ARCHON_ARGV"
    [[ "$output" == *"proj: PR #600 already had a review correction launched at aaaaaaa — waiting for a new head and its review"* ]]
    [ "$(cat "$HOME/.archon/state/pr-maintenance/proj-600.corrected")" = aaaaaaa1 ]
}

@test "the correction's push waits for a review of the new head, which re-arms it" {
    export GH_PR_LIST="[$(pr 600 aaaaaaa1)]"
    correct 600 aaaaaaa1
    tick
    export GH_PR_LIST="[$(pr 600 bbbbbbb2)]"
    tick
    [ "$(launches)" -eq 1 ]
    correct 600 bbbbbbb2
    tick
    tick
    [ "$(launches)" -eq 2 ]
}

@test "a merge-state change at the same head does not launch a second correction" {
    export GH_PR_LIST="[$(pr 600 aaaaaaa1)]"
    correct 600 aaaaaaa1
    tick
    export GH_PR_LIST="[$(pr 600 aaaaaaa1 BEHIND)]"
    tick
    export GH_PR_LIST="[$(pr 600 aaaaaaa1)]"
    tick
    [ "$(grep -c '^workflow run archon-assist ' "$STUB_ARCHON_ARGV")" -eq 1 ]
}

@test "a review that is ready, or says replan or needs_human, starts no correction" {
    export GH_PR_LIST="[$(pr 600 aaaaaaa1), $(pr 601 ccccccc3), $(pr 602 ddddddd4)]"
    report 600 aaaaaaa1 "Verdict: ready" "**ready: true** — **action: none**."
    report 601 ccccccc3 "Verdict: not ready" "**ready: false** — **action: replan**."
    report 602 ddddddd4 "Verdict: not ready" "**ready: false** — **action: needs_human**."
    tick
    [ "$(launches)" -eq 0 ]
    [[ "$output" == *"proj: no PRs need AI maintenance"* ]]
}

@test "a CLEAN PR left by a failed run is the review retry's, not a correction's" {
    export GH_PR_LIST="[$(pr 600 aaaaaaa1)]"
    correct 600 aaaaaaa1
    ARCHON_OPEN_RUNS=$(jq -nc --arg wp "$T/wt/archon/task-archon-ship-block-600" '{runs: [{id: "run-f", workflow_name: "archon-ship-block", status: "failed", user_message: "fix #30", working_path: $wp, metadata: {error: "Process terminated (SIGTERM)"}}], total: 1}')
    tick
    [ "$(launches)" -eq 0 ]
}
