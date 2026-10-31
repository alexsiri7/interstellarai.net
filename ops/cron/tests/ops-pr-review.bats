#!/usr/bin/env bats
# Tests for ops/cron/ops-pr-review.sh (#246): the scheduled reviewer that
# merges the ops PRs pr-maintenance holds for a human. The real script end to
# end, with gh, claude and curl stubbed in $HOME/.local/bin (each records its
# argv), ops-self-update.sh replaced by OPS_SELF_UPDATE, Lachesis by
# LACHESIS_CALL_CMD, and the held PRs as ops-merge marks in a temp
# DEADLINE_STATE_DIR.
#
# Run: npx bats@1.13.0 ops/cron/tests/ops-pr-review.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    CRON="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export HOME="$T/home"
    STUB_BIN="$HOME/.local/bin"
    mkdir -p "$STUB_BIN" "$T/gh"
    unset _ARCHON_TRUST_SH _ARCHON_DEADLINES_SH TRUSTED_AUTHORS TRUSTED_ISSUE_BOTS TRUSTED_MERGE_ONLY_AUTHORS TRUSTED_COMMENT_BOTS DEADLINE_FRESH_SECONDS DEADLINE_NOW
    export ARCHON_RUN_AS=archon
    export ARCHON_CRON_TRUST_FILE="$T/no-trust.env"
    export NTFY_TOPIC=test-topic
    export TRUST_STATE_DIR="$T/trust"
    export DEADLINE_STATE_DIR="$T/deadlines"
    export OPS_REVIEW_STATE="$T/state"
    export OPS_REPO=alexsiri7/interstellarai.net
    export OPS_SELF_UPDATE="$T/self-update"
    export LACHESIS_CALL_CMD="$T/lachesis"
    export GH="$T/gh"

    # gh: answers from files under $GH, records argv (and a comment's body).
    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$T/argv"
case "$1 $2" in
  "pr view")
    case " $* " in
      *mergeCommit*) printf '%040d\n' "$3" ;;
      *) cat "$GH/view-$3.json" ;;
    esac ;;
  "pr diff")
    case " $* " in
      *" --name-only "*) cat "$GH/files-$3" ;;
      *) cat "$GH/diff-$3" ;;
    esac ;;
  "issue view") cat "$GH/issue-$3.json" 2>/dev/null || echo '{"title":"Fix the thing","body":"Please fix it.","labels":[]}' ;;
  "pr comment")
    while [ $# -gt 0 ]; do [ "$1" = --body ] && printf '%s\n' "$2" >> "$T/comments"; shift; done ;;
esac
exit 0
STUB
    printf '#!/usr/bin/env bash\nprintf "claude %%s\\n" "$*" >> "%s/argv"\ncat > "%s/prompt"\nprintf "%%s" "$CLAUDE_OUT"\n' "$T" "$T" > "$STUB_BIN/claude"
    printf '#!/usr/bin/env bash\nprintf "curl %%s\\n" "$*" >> "%s/argv"\n' "$T" > "$STUB_BIN/curl"
    printf '#!/usr/bin/env bash\nprintf "self-update %%s\\n" "$*" >> "%s/argv"\nexit "${SELF_UPDATE_RC:-0}"\n' "$T" > "$OPS_SELF_UPDATE"
    printf '#!/usr/bin/env bash\nprintf "lachesis %%s\\n" "$*" >> "%s/argv"\necho "{}"\n' "$T" > "$LACHESIS_CALL_CMD"
    chmod +x "$STUB_BIN"/* "$OPS_SELF_UPDATE" "$LACHESIS_CALL_CMD"
    export PATH="$STUB_BIN:$PATH"
    : > "$T/argv"

    # The live checkout: main already names ntfy.sh.
    git init -q -b main --bare "$T/origin.git"
    git clone -q "$T/origin.git" "$T/work" 2>/dev/null
    echo 'curl "https://ntfy.sh/$topic"' > "$T/work/notify.sh"
    git -C "$T/work" add notify.sh
    git -C "$T/work" -c user.email=t@t -c user.name=t commit -q -m init
    git -C "$T/work" push -q origin main
    git clone -q "$T/origin.git" "$T/live"
    export OPS_CHECKOUT="$T/live"
}

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222

mark() { # mark <pr> <sha> — pr-maintenance Phase 1 held it this tick
    bash -c 'source "$1/lib/deadlines.sh"; deadline_mark ops-merge interstellarai.net "$2" "$3" "archon/task-x" "touches ops/; needs a human merge"' _ "$CRON" "$1" "$2"
}

pr() { # pr <number> <head sha> [mergeState] [files...] — a green, owner's PR
    local n="$1" sha="$2" state="${3:-CLEAN}"
    shift 3 2>/dev/null || shift $#
    jq -nc --argjson n "$n" --arg sha "$sha" --arg st "$state" \
      '{number: $n, state: "OPEN", isDraft: false, headRefOid: $sha, mergeStateStatus: $st,
        title: "Fix the thing", body: "Fixes #30", author: {login: "alexsiri7"},
        isCrossRepository: false, labels: [], closingIssuesReferences: [{number: 30}],
        statusCheckRollup: [{name: "bats", conclusion: "SUCCESS"}]}' > "$GH/view-$n.json"
    [ $# -gt 0 ] || set -- ops/cron/pr-maintenance-cron.sh
    printf '%s\n' "$@" > "$GH/files-$n"
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-old\n+new\n' "$1" "$1" "$1" "$1" > "$GH/diff-$n"
}

verdict() { # verdict merge|block|escalate [blocking finding title]
    local findings='[]'
    [ -n "${2:-}" ] && findings=$(jq -nc --arg t "$2" '[{severity: "blocking", file: "ops/cron/x.sh", line: 3, title: $t, detail: "it breaks"}]')
    CLAUDE_OUT=$(jq -nc --arg v "$1" --argjson f "$findings" \
      '{type: "result", is_error: false, structured_output: {verdict: $v, matches_issue: true, summary: "looked at it", findings: $f}}')
    export CLAUDE_OUT
}

review() { run "$CRON/ops-pr-review.sh"; [ "$status" -eq 0 ]; }
calls() { grep -c "^$1" "$T/argv" || true; }

# ---------------------------------------------------------------- deny list
@test "deny list: the sensitive set is a hit, ordinary ops code is not" {
    source <(awk '/^ops_review_sensitive\(\)/{p=1} p{print} p && /^}$/{p=0}' "$CRON/ops-pr-review.sh")
    for f in ops/host/archon-user/install.sh ops/host/sudoers-archon-cron \
             ops/cron/lib/trust.sh ops/cron/lib/screen.sh ops/cron/lib/claude-auth.sh ops/cron/lib/secrets.sh \
             secrets.env ops/cron/doppler-push.sh ops/cron/crontab ops/cron/lib/run-as.sh \
             ops/cron/lib/archon-shim/archon ops/cron/archon-projects.txt \
             ops/cron/ops-pr-review.sh ops/cron/ops-self-update.sh .github/unsafe-change.yml; do
        run ops_review_sensitive <<<"$f"
        [ "$status" -eq 0 ] || { echo "not flagged: $f"; false; }
        [[ "$output" == "$f ("*")" ]]
    done
    for f in ops/cron/pr-maintenance-cron.sh ops/cron/README.md .github/workflows/deploy.yml \
             ops/cron/lib/archon-active-runs.sh ops/cron/tests/pr-hold-label.bats; do
        run ops_review_sensitive <<<"$f"
        [ "$status" -eq 1 ] || { echo "flagged: $f"; false; }
        [ -z "$output" ]
    done
}

@test "egress: a host main does not name is flagged, one it does is not" {
    source <(awk '/^ops_review_new_hosts\(\)/{p=1} p{print} p && /^}$/{p=0}' "$CRON/ops-pr-review.sh")
    printf '+++ b/ops/cron/x.sh\n+curl https://evil.example.net/x\n+curl https://ntfy.sh/topic\n https://unchanged.example.org\n' > "$T/d"
    run ops_review_new_hosts "$T/d" "$T/live" "$(git -C "$T/live" rev-parse HEAD)"
    [ "$output" = "evil.example.net (new network egress host)" ]
}

# ---------------------------------------------------------------- no-op
@test "no marks, or only a stale one: nothing to do, no gh, no claude" {
    review
    [[ "$output" == *"no held ops PRs"* ]]
    mkdir -p "$DEADLINE_STATE_DIR"
    printf 'kind=ops-merge\nproject=interstellarai.net\nnumber=500\nfirst_seen=1000\nlast_seen=1000\nsha=%s\n' "$SHA1" \
        > "$DEADLINE_STATE_DIR/ops-merge--interstellarai.net--500"
    pr 500 "$SHA1"
    review
    [[ "$output" == *"no held ops PRs"* ]]
    [ "$(calls gh)" -eq 0 ]
    [ "$(calls claude)" -eq 0 ]
}

@test "outside archon mode it does nothing, even with a mark" {
    export ARCHON_RUN_AS=asiri
    mark 500 "$SHA1"; pr 500 "$SHA1"
    review
    [[ "$output" == *"pr-maintenance merges ops PRs itself"* ]]
    [ ! -s "$T/argv" ]
}

# ---------------------------------------------------------------- decisions
@test "a sensitive PR is never merged: one comment, one ntfy, no review" {
    mark 500 "$SHA1"; pr 500 "$SHA1" CLEAN ops/cron/lib/trust.sh
    review
    review
    [ "$(calls 'gh pr merge')" -eq 0 ]
    [ "$(calls claude)" -eq 0 ]
    [ "$(calls 'gh pr comment')" -eq 1 ]
    [ "$(calls curl)" -eq 1 ]
    grep -q "ops/cron/lib/trust.sh (trust, screening or Claude auth)" "$T/comments"
}

@test "a PR closing an issue only screening vetted waits for the owner" {
    mark 500 "$SHA1"; pr 500 "$SHA1"
    echo '{"title":"Bug: x","body":"from a form","labels":[{"name":"archon:auto-approved"}]}' > "$GH/issue-30.json"
    review
    [ "$(calls 'gh pr merge')" -eq 0 ]
    [ "$(calls claude)" -eq 0 ]
    grep -q "linked issue #30" "$T/comments"
}

@test "a green, non-sensitive PR the review passes is merged at its head and released" {
    mark 500 "$SHA1"; pr 500 "$SHA1"
    verdict merge
    review
    grep -q "^gh pr merge 500 --repo alexsiri7/interstellarai.net --squash --delete-branch --match-head-commit $SHA1 --subject Fix the thing (#500)" "$T/argv"
    grep -qx "self-update --approve-reviewed $(printf '%040d' 500)" "$T/argv"
    [ ! -e "$OPS_REVIEW_STATE/pending-approve" ]
    grep -q "BEGIN UNTRUSTED [0-9a-f]* linked-issues" "$T/prompt"
    grep -q "^lachesis add_note .*merged" "$T/argv"
    [[ "$output" == *"1 held, 1 merged"* ]]
}

@test "a blocking review posts a review report pr-maintenance corrects, once per head" {
    mark 500 "$SHA1"; pr 500 "$SHA1"
    verdict merge "breaks the tick"   # merge with a blocking finding is a block
    review
    review
    [ "$(calls claude)" -eq 1 ]
    [ "$(calls 'gh pr merge')" -eq 0 ]
    [ "$(calls 'gh pr comment')" -eq 1 ]
    grep -qF '<!-- archon-review-report -->' "$T/comments"
    grep -qF "Reviewed commit: \`$SHA1\`" "$T/comments"
    grep -qx 'Verdict: not ready' "$T/comments"
    grep -qF 'action: **correct**' "$T/comments"
    grep -qF 'breaks the tick' "$T/comments"
}

@test "a head that moved since the mark is not reviewed" {
    mark 500 "$SHA1"; pr 500 "$SHA2"
    verdict merge
    review
    [ "$(calls claude)" -eq 0 ]
    [ "$(calls 'gh pr merge')" -eq 0 ]
    [[ "$output" == *"head moved since pr-maintenance last checked it"* ]]
}

@test "a refused approval stops further merges until it passes" {
    mark 500 "$SHA1"; pr 500 "$SHA1"
    mark 501 "$SHA2"; pr 501 "$SHA2"
    verdict merge
    export SELF_UPDATE_RC=1
    review
    [ "$(calls 'gh pr merge')" -eq 1 ]
    grep -q "^gh pr merge 500 " "$T/argv"
    jq -c '.state = "MERGED"' "$GH/view-500.json" > "$T/v" && mv "$T/v" "$GH/view-500.json"
    [ "$(cat "$OPS_REVIEW_STATE/pending-approve")" = "$(printf '%040d' 500) 500" ]
    [ "$(calls curl)" -eq 1 ]
    review
    [ "$(calls 'gh pr merge')" -eq 1 ]
    [ "$(calls self-update)" -eq 2 ]
    [ "$(calls curl)" -eq 1 ]
    # released by hand: the next run clears it and merges the next PR
    export SELF_UPDATE_RC=0
    review
    [ ! -e "$OPS_REVIEW_STATE/pending-approve" ]
    grep -q "^gh pr merge 501 " "$T/argv"
}

@test "a review that keeps failing is retried up to the cap, then one ntfy" {
    mark 500 "$SHA1"; pr 500 "$SHA1"
    export CLAUDE_OUT='{"type":"result","is_error":true,"result":"Not logged in"}'
    review
    review
    review
    review
    [ "$(calls claude)" -eq 2 ]
    [ "$(calls curl)" -eq 1 ]
    [ "$(calls 'gh pr merge')" -eq 0 ]
}
