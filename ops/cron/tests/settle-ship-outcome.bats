#!/usr/bin/env bats
# Tests for ops/cron/lib/settle-ship-outcome.sh.
#
# Run: bunx bats ops/cron/tests/settle-ship-outcome.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/settle-ship-$$"
    mkdir -p "$T/bin" "$T/fixtures"
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/settle-ship-outcome.sh"

    # Stub gh: records argv, answers sub_issues with what its --jq would print,
    # "<total>\t<open>" (absent = no sub-issues), and runs the script's own --jq
    # over the ref-<N> GitHub JSON for a single issue or PR (see ref()).
    # `issue view` prints {title, body} from the title-<issue> and body-<issue>
    # fixtures (default: an ordinary issue), or fails with GH_VIEW_RC. The deferral checks (#211) read state-<N>
    # ("issue|pr<TAB>open|closed") and pull-<N> ("<state><TAB><merged><TAB>
    # <cross><TAB><login>"); gone-<N> makes both answer 404; comments-<N>
    # is the issue's one comment body, which the script's --jq reads, and
    # comments-json-<N> the full comment array (login, association, url) instead.
    # The #259 lookups read head (main's SHA), runs-<sha> (gh run list JSON),
    # deps-<sha> (deployments) with depstate-<id> (its latest state), and
    # file-<path with / as _> (a file that exists). GH_COMMENT_RC fails `issue comment`.
    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
case "$*" in
  *sub_issues*)       cat "$GH_FIXTURES/sub-$(sed -E 's#.*/issues/([0-9]+)/.*#\1#' <<<"$*")" 2>/dev/null || printf '0\t0\n' ;;
  *"/comments"*)
    n=$(sed -E 's#.*/issues/([0-9]+)/.*#\1#' <<<"$*")
    f="$GH_FIXTURES/comments-$n"
    if [ -e "$GH_FIXTURES/comments-json-$n" ]; then jq -r "$5" "$GH_FIXTURES/comments-json-$n"
    elif [ -e "$f" ]; then jq -Rs '[{body: .}]' "$f" | jq -r "$5"; fi
    exit "${GH_COMMENTS_RC:-0}" ;;
  "api "*/commits/main*)
    [ -e "$GH_FIXTURES/head" ] || exit 1
    cat "$GH_FIXTURES/head" ;;
  "run list "*)
    sha=$(sed -E 's/.*--commit ([0-9a-f]+).*/\1/' <<<"$*")
    cat "$GH_FIXTURES/runs-$sha" 2>/dev/null || echo '[]' ;;
  "api "*/deployments/*/statuses*)
    id=$(sed -E 's#.*/deployments/([0-9]+)/.*#\1#' <<<"$*")
    cat "$GH_FIXTURES/depstate-$id" 2>/dev/null || exit 1 ;;
  "api "*/deployments*)
    sha=$(sed -E 's/.*sha=([0-9a-f]+).*/\1/' <<<"$*")
    cat "$GH_FIXTURES/deps-$sha" 2>/dev/null || echo '[]' ;;
  "api "*/contents/*)
    p=${2#*/contents/}
    [ -e "$GH_FIXTURES/file-${p//\//_}" ] && echo file || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; } ;;
  "api "*/pulls/*)
    [ -e "$GH_FIXTURES/gone-${2##*/}" ] && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    cat "$GH_FIXTURES/pull-${2##*/}" 2>/dev/null || exit 1 ;;
  "api "*/issues/*@tsv*)
    [ -e "$GH_FIXTURES/gone-${2##*/}" ] && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    cat "$GH_FIXTURES/state-${2##*/}" 2>/dev/null || exit 1 ;;
  "api "*/issues/*)   [ "$3" = --jq ] && jq -r "$4" "$GH_FIXTURES/ref-${2##*/}" 2>/dev/null ;;
  *"issue view"*)
    [ -n "${GH_VIEW_RC:-}" ] && exit "$GH_VIEW_RC"
    n=$(sed -E 's/^issue view ([0-9]+).*/\1/' <<<"$*")
    jq -n --arg t "$(cat "$GH_FIXTURES/title-$n" 2>/dev/null || echo 'An ordinary issue')" \
      --arg b "$(cat "$GH_FIXTURES/body-$n" 2>/dev/null || echo 'An ordinary issue.')" \
      '{title: $t, body: $b}' ;;
  *"issue close"*)    exit "${GH_CLOSE_RC:-0}" ;;
  *"issue edit"*)     exit "${GH_EDIT_RC:-0}" ;;
  *"issue comment"*)  exit "${GH_COMMENT_RC:-0}" ;;
esac
STUB
    chmod +x "$T/bin/gh"
    export PATH="$T/bin:$PATH"
    export GH_ARGV="$T/gh-argv"
    export GH_FIXTURES="$T/fixtures"
    : > "$GH_ARGV"
    RUN_LOG="$T/run.log"
    # trust.sh: no Doppler call, default TRUSTED_AUTHORS.
    export NTFY_TOPIC=test ARCHON_CRON_TRUST_FILE=/nonexistent
}

teardown() {
    rm -rf "$T"
}

gh_calls() {
    grep -c -- "$1" "$GH_ARGV" || true
}

fixture() { printf '%s\n' "$2" > "$T/fixtures/$1"; }

# ref <N> open-issue|closed-issue|closed-duplicate|merged-pr|pr: what
# GitHub's issues API returns for #N.
ref() {
    local json
    case "$2" in
        open-issue)   json='{"state":"open"}' ;;
        closed-issue) json='{"state":"closed","state_reason":"completed"}' ;;
        closed-duplicate) json='{"state":"closed","state_reason":"duplicate"}' ;;
        merged-pr)    json='{"state":"closed","pull_request":{"merged_at":"2026-09-16T10:00:00Z"}}' ;;
        pr)           json='{"state":"open","pull_request":{"merged_at":null}}' ;;
    esac
    fixture "ref-$1" "$json"
}

assert_parked() {
    grep -q -- "issue edit $1 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:skipped" "$GH_ARGV"
    [ "$(gh_calls 'issue close')" -eq 0 ]
    [ "$(gh_calls '--add-label archon:done')" -eq 0 ]
}

# The verdict archon-ship actually left on un-reminder #431 (2026-09-16). The
# closed duplicate is a maintainer's call (#212); the merged PR is not.
@test "the real #431 verdict closes on the merged PR it names, not as a duplicate of the closed issue" {
    cat > "$RUN_LOG" <<'LOG'
[outcome] running
No delivery needed: Issue #431 and closed issue #432 are duplicate GitHub records of the exact same Sentry event (UN-REMINDER-1C). The merged PR #433 already fixed #432 at HEAD. No engineering work remains; #431 just needs closing as a duplicate. Full evidence in /home/x/triage.md.
Report: /home/x/artifacts/triage.md
LOG
    ref 432 closed-issue
    ref 433 merged-pr

    run "$SCRIPT" testproj 431 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 431 --repo alexsiri7/testproj --reason completed --comment" "$GH_ARGV"
    [ "$(gh_calls '--duplicate-of')" -eq 0 ]
    grep -q -- "issue edit 431 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:done" "$GH_ARGV"
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/431 ')" -eq 0 ]
    [[ "$output" == *"#431 settled as archon:done (already fixed by merged PR #433)"* ]]
}

# #212: the triage policy closes a duplicate of a still-open issue without a person.
@test "a verdict naming one open original closes as its duplicate" {
    printf 'No delivery needed: duplicate of #8, which tracks the same crash; PR #50 was abandoned.\nReport: /x\n' > "$RUN_LOG"
    ref 8 open-issue
    ref 50 pr

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --duplicate-of 8 --comment archon-ship finished without a PR: No delivery needed: duplicate of #8" "$GH_ARGV"
    [ "$(gh_calls '--reason')" -eq 0 ]
    grep -q -- "issue edit 7 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:done" "$GH_ARGV"
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
    [[ "$output" == *"#7 settled as archon:done (duplicate of #8, which is still open)"* ]]
}

@test "a verdict naming a merged PR and an open issue closes on the PR, not as a duplicate" {
    printf 'No delivery needed: merged PR #50 already delivered this; the follow-up refactor stays open in #8.\nReport: /x\n' > "$RUN_LOG"
    ref 8 open-issue
    ref 50 merged-pr

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed --comment" "$GH_ARGV"
    [ "$(gh_calls '--duplicate-of')" -eq 0 ]
    [[ "$output" == *"#7 settled as archon:done (already fixed by merged PR #50)"* ]]
}

@test "a verdict naming two open issues parks, since neither is known to be the original" {
    printf 'No delivery needed: duplicate of #8; see also the parent epic #9.\nReport: /x\n' > "$RUN_LOG"
    ref 8 open-issue
    ref 9 open-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

@test "a verdict whose sixth ref goes unchecked does not close as a duplicate" {
    printf 'No delivery needed: duplicate of #8; see #1, #2, #3, #4 and the parent epic #9.\nReport: /x\n' > "$RUN_LOG"
    ref 8 open-issue
    ref 1 pr; ref 2 pr; ref 3 pr; ref 4 pr
    ref 9 open-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/9 ')" -eq 0 ]
    assert_parked 7
}

@test "a verdict with one open issue and a ref whose lookup fails does not close as a duplicate" {
    printf 'No delivery needed: duplicate of #8; see #9 the parent epic.\nReport: /x\n' > "$RUN_LOG"
    ref 8 open-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

# #259 turned this around: a duplicate of a closed issue closes, citing it.
@test "a verdict naming only a closed original closes on that precedent, labelled factory-closed" {
    printf 'No delivery needed: duplicate of #8, closed last week.\nReport: /x\n' > "$RUN_LOG"
    ref 8 closed-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason not planned --comment" "$GH_ARGV"
    grep -q -- "Closed as archon:done: matches closed precedent #8" "$GH_ARGV"
    grep -q -- "issue edit 7 --repo alexsiri7/testproj --add-label factory-closed" "$GH_ARGV"
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
}

@test "a closed ref the verdict gives no precedent reason for still parks, naming it" {
    printf 'No delivery needed: see #8, closed last week, for background.\nReport: /x\n' > "$RUN_LOG"
    ref 8 closed-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    grep -q -- "Not auto-closed: the verdict names closed issue #8" "$GH_ARGV"
}

@test "a verdict naming only a merged PR closes as completed" {
    printf 'No delivery needed: already fixed at HEAD by PR #50.\nReport: /x\n' > "$RUN_LOG"
    ref 50 merged-pr

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed --comment" "$GH_ARGV"
    grep -q -- "--add-label archon:done" "$GH_ARGV"
    [[ "$output" == *"already fixed by merged PR #50"* ]]
}

@test "an epic whose sub-issues are all closed closes as completed" {
    printf 'No delivery needed: every phase of this epic has shipped.\nReport: /x\n' > "$RUN_LOG"
    printf '3\t0\n' > "$T/fixtures/sub-7"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed --comment" "$GH_ARGV"
    [[ "$output" == *"all 3 sub-issues are closed"* ]]
}

@test "an epic with an open sub-issue is parked" {
    printf 'No delivery needed: every phase of this epic has shipped.\nReport: /x\n' > "$RUN_LOG"
    printf '3\t1\n' > "$T/fixtures/sub-7"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

@test "an issue with no sub-issues and no verifiable reference is parked as today" {
    printf 'No delivery needed: false positive alert, not a code change.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    grep -q -- "issue comment 7 " "$GH_ARGV"
}

@test "a self-reference, a closed issue, an unmerged PR and another repo's issue do not close" {
    printf 'No delivery needed: #7 duplicates #8, see PR #9 and alexsiri7/other#10.\nReport: /x\n' > "$RUN_LOG"
    ref 7 open-issue
    ref 8 closed-issue
    ref 9 pr
    ref 10 open-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/10 ')" -eq 0 ]
}

@test "a reference that cannot be looked up does not close" {
    printf 'No delivery needed: duplicate of #8.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

@test "No delivery started never closes, even when it names a merged PR" {
    printf 'No delivery started: investigation found PR #50 may already cover this.\nReport: /x\n' > "$RUN_LOG"
    ref 50 merged-pr
    printf '2\t0\n' > "$T/fixtures/sub-7"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    [ "$(gh_calls 'api ')" -eq 0 ]
}

@test "a failed close falls back to parking" {
    printf 'No delivery needed: already fixed by PR #50.\nReport: /x\n' > "$RUN_LOG"
    ref 50 merged-pr
    export GH_CLOSE_RC=1

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue edit 7 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:skipped" "$GH_ARGV"
    [ "$(gh_calls '--add-label archon:done')" -eq 0 ]
    [[ "$output" != *"close failed"* ]]
}

@test "a log with no verdict exits 1 and touches nothing" {
    printf 'Error: rate limited\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ ! -s "$GH_ARGV" ]
}

@test "a multi-line summary is searched past its first line, but not past Report" {
    printf 'No delivery needed: nothing left to do here.\nThe crash was fixed by PR #50.\nReport: /x\nlater noise #60\n' > "$RUN_LOG"
    ref 50 merged-pr
    ref 60 open-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed" "$GH_ARGV"
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/60 ')" -eq 0 ]
}

# ── Archon >= 0.11: the outcome report as one JSON line ──────────────────────

# Since the 0.11.1 sync (2026-10-09) the outcome node prints its report as
# {"delivered":<bool>,"summary":"<report, \n-escaped>"}; before this, none of
# these matched and every run looped through unstick_stale (101 by 2026-10-11).
json_outcome() {  # <delivered> <summary, with literal \n escapes>
    {
        echo '[outcome] Started'
        echo '[outcome] Completed (83ms)'
        printf '{"delivered":%s,"summary":"%s"}\n' "$1" "$2"
        printf '\nWorkflow finished.\n  Status: completed\n  Authored outcome: failed\n'
    } > "$RUN_LOG"
}

# The shape of interstellarai.net #161's run (2026-10-11), shortened.
@test "a JSON No delivery needed verdict with no confirmation parks, with the decoded summary as the verdict" {
    json_outcome false 'No delivery needed: Issue #7 is BLOCKED on alexsiri7/lachesis#301, which is still open. Full evidence in triage.md.\nReport: /home/x/artifacts/runs/6e46/triage.md'

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    grep -q -- 'archon-ship finished without a PR: No delivery needed: Issue #7 is BLOCKED on alexsiri7/lachesis#301, which is still open. Full evidence in triage.md.$' "$GH_ARGV"
    [ "$(gh_calls 'Report: ')" -eq 0 ]
    [ "$(gh_calls '\\n')" -eq 0 ]
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/301 ')" -eq 0 ]
}

@test "a JSON No delivery needed verdict naming a merged PR closes as completed" {
    json_outcome false 'No delivery needed: already fixed at HEAD by PR #50.\nReport: /x/triage.md'
    ref 50 merged-pr

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed --comment archon-ship finished without a PR: No delivery needed: already fixed at HEAD by PR #50." "$GH_ARGV"
    grep -q -- "--remove-label archon:in-progress --add-label archon:done" "$GH_ARGV"
}

@test "a JSON summary is searched past its first line, but not past Report" {
    json_outcome false 'No delivery needed: nothing left to do here.\n\nThe crash was fixed by PR #50.\nReport: /x\nlater noise #60'
    ref 50 merged-pr
    ref 60 open-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed" "$GH_ARGV"
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/60 ')" -eq 0 ]
}

@test "a JSON No delivery started verdict parks and never closes, even naming a merged PR" {
    json_outcome false 'No delivery started: investigate found no safe fix boundary; see PR #50.\nReport: /x/investigation.md'
    ref 50 merged-pr

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    grep -q -- 'archon-ship finished without a PR: No delivery started: investigate found no safe fix boundary; see PR #50.$' "$GH_ARGV"
    [ "$(gh_calls 'api ')" -eq 0 ]
}

# Archon v0.12's ship tail (scripts/outcome.ts), as archon-ship-block prints it:
# {delivered, reason, pr_url, summary}, with the stops reworded.
@test "v0.12 Not done verdicts park and never close, even naming a merged PR" {
    for summary in \
        'Not done: blocked on #12 landing first. Triage says the fix needs #12; see PR #50.\nReport: /x/triage.md' \
        'Not done: the work item needs contract work before a run can start. Scope unclear; PR #50 touched it.\nReport: /x/triage.md' \
        'Not done: the investigation was inconclusive. PR #50 may be related.\nReport: /x/investigation.md' \
        'Not done: planning stopped on calls only a person can make. Pick a storage engine.\n- Postgres or SQLite?\nReport: /x/plan.md'; do
        : > "$GH_ARGV"
        printf '{"delivered":false,"reason":"blocked","pr_url":"","summary":"%s"}\n' "$summary" > "$RUN_LOG"
        ref 50 merged-pr
        printf '2\t0\n' > "$T/fixtures/sub-7"

        run "$SCRIPT" testproj 7 "$RUN_LOG"

        [ "$status" -eq 0 ]
        assert_parked 7
        grep -q -- 'archon-ship finished without a PR: Not done: ' "$GH_ARGV"
        # Only "blocked on" looks its refs up, and only to release (#211).
        [ "$(gh_calls 'sub_issues')" -eq 0 ]
        [ "$(gh_calls 'merged-pr')" -eq 0 ]
    done
}

# filmduel #814 and musenmingle #348 (2026-10-18/20): triage__triage returned
# "test" in every reason field; the outcome node printed exactly this.
@test "a placeholder verdict (blocked on test. test) is not settled: no park, no question (#209)" {
    lachesis_on
    printf '{"delivered":false,"reason":"blocked","pr_url":"","summary":"%s"}\n' \
        'Not done: blocked on test. test\nReport: /x/triage.md' > "$RUN_LOG"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ ! -s "$GH_ARGV" ]
    [ ! -s "$LACHESIS_ARGV" ]
    [[ "$output" == *"placeholder verdict"* ]]
}

@test "placeholder verdicts of other shapes are not settled, nor closed on recheck (#209)" {
    for summary in 'No delivery needed: placeholder' 'Not done: blocked on asdf. asdf' 'Not done: blocked on . '; do
        : > "$GH_ARGV"
        printf '{"delivered":false,"reason":"blocked","pr_url":"","summary":"%s"}\n' "$summary" > "$RUN_LOG"

        run "$SCRIPT" testproj 7 "$RUN_LOG"

        [ "$status" -eq 1 ]
        [ ! -s "$GH_ARGV" ]
    done

    printf 'No delivery needed: placeholder\n' > "$RUN_LOG"
    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ ! -s "$GH_ARGV" ]
}

@test "a v0.12 refuted investigation (No work owed in this repository) parks and never closes" {
    printf '{"delivered":false,"reason":"refuted","pr_url":"","summary":"%s"}\n' \
        'No work owed in this repository: the crash is in the upstream SDK, fixed by PR #50.\nReport: /x/investigation.md' > "$RUN_LOG"
    ref 50 merged-pr

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    grep -q -- 'archon-ship finished without a PR: No work owed in this repository: the crash is in the upstream SDK, fixed by PR #50.$' "$GH_ARGV"
    [ "$(gh_calls 'api ')" -eq 0 ]
}

@test "a v0.12 No delivery needed report with reason and pr_url still closes on a merged PR" {
    printf '{"delivered":false,"reason":"no_action","pr_url":"","summary":"%s"}\n' \
        'No delivery needed: already fixed by merged PR #50.\nReport: /x/triage.md' > "$RUN_LOG"
    ref 50 merged-pr

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- 'issue close 7 --repo alexsiri7/testproj --reason completed' "$GH_ARGV"
}

@test "a v0.12 delivered:false report from a delivery that ran settles nothing" {
    printf '{"delivered":false,"reason":"not_ready","pr_url":"https://github.com/alexsiri7/testproj/pull/9","summary":"%s"}\n' \
        'Delivery ended not ready: CI red after 3 rounds.' > "$RUN_LOG"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ "$(gh_calls 'issue ')" -eq 0 ]
}

@test "a JSON delivered:true report settles nothing, even when the log also carries a plain verdict" {
    {
        echo 'No delivery needed: an earlier node said so, but the run went on to open a PR (#50).'
        echo '{"delivered":true,"summary":"https://github.com/alexsiri7/testproj/pull/51\n\nDelivered on red (1)"}'
    } > "$RUN_LOG"
    ref 50 merged-pr

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ ! -s "$GH_ARGV" ]
}

@test "a JSON delivered:false report whose summary is no verdict settles nothing" {
    json_outcome false 'Run stopped: the plan gate failed.\nNo delivery needed: quoted, not the verdict.'

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ ! -s "$GH_ARGV" ]
}

@test "other nodes' JSON lines and malformed JSON are not taken for the outcome report" {
    {
        echo '{"ready":true,"summary":"No delivery needed: from the plan node"}'
        echo '{"delivered":false,"summary":"No delivery needed: truncated'
    } > "$RUN_LOG"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ ! -s "$GH_ARGV" ]
}

# The factory comments as the owner; Lachesis tells its comments from the
# author's answers by this last line (lachesis #386).
@test "the park and close comments end with the lachesis:automated marker" {
    printf 'No delivery needed: false positive alert, not a code change.\nReport: /x\n' > "$RUN_LOG"
    run "$SCRIPT" testproj 7 "$RUN_LOG"
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$GH_ARGV")" = "<!-- lachesis:automated -->" ]

    : > "$GH_ARGV"
    printf 'No delivery needed: fixed by PR #50.\nReport: /x\n' > "$RUN_LOG"
    ref 50 merged-pr
    run "$SCRIPT" testproj 8 "$RUN_LOG"
    [ "$status" -eq 0 ]
    [ "$(grep -B1 '^issue edit 8 ' "$GH_ARGV" | head -n 1)" = "<!-- lachesis:automated -->" ]
}

@test "the parked comment a JSON verdict leaves is one --recheck reads back" {
    json_outcome false 'No delivery needed: PR #50 is not merged yet.\nReport: /x'
    ref 50 pr
    run "$SCRIPT" testproj 7 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 7

    # What settle_parked hands --recheck: the comment body, prefix stripped.
    body=$(sed -n 's/^issue comment 7 --repo alexsiri7\/testproj --body //p' "$GH_ARGV")
    [[ "$body" == "archon-ship finished without a PR: No delivery needed: PR #50 is not merged yet." ]]
    sed -n '/^issue comment 7 /,$p' "$GH_ARGV" | sed '1s/^.*--body archon-ship finished without a PR: //' > "$RUN_LOG"
    grep -q '^Parked as archon:skipped\.' "$RUN_LOG"
    ref 50 merged-pr
    : > "$GH_ARGV"

    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue edit 7 --repo alexsiri7/testproj --remove-label archon:skipped --add-label archon:done" "$GH_ARGV"
}

@test "settle-ship-outcome passes shellcheck" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    cd "$(dirname "$SCRIPT")/.."
    run shellcheck -x lib/settle-ship-outcome.sh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ── --recheck ────────────────────────────────────────────────────────────────

# issue-pickup's settle_parked passes the parked comment with its
# "archon-ship finished without a PR: " prefix already stripped.
parked_verdict() { printf 'No delivery needed: %s\n\nParked as archon:skipped. Remove the label and add archon:queued to run it again. Run log: `logs/archon-runs/7.log`\n' "$1" > "$RUN_LOG"; }

assert_untouched() {
    [ "$(gh_calls 'issue close')" -eq 0 ]
    [ "$(gh_calls 'issue edit')" -eq 0 ]
    [ "$(gh_calls 'issue comment')" -eq 0 ]
}

# Run every tick: re-parking would post the same comment every 15 minutes.
@test "--recheck leaves an unconfirmable parked verdict untouched" {
    parked_verdict 'false positive, nothing to change.'

    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ "$(gh_calls 'sub_issues')" -eq 1 ]
    assert_untouched
}

# The verdict parked on filmduel #535 (2026-09-10).
@test "--recheck closes a parked verdict naming a merged PR, removing archon:skipped" {
    parked_verdict 'Merged PR #541 already delivered exactly that: the watchlist toggle ships on HEAD. Recommend closing #7.'
    ref 541 merged-pr

    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed --comment" "$GH_ARGV"
    grep -q -- "issue edit 7 --repo alexsiri7/testproj --remove-label archon:skipped --add-label archon:done" "$GH_ARGV"
    [ "$(gh_calls 'archon:in-progress')" -eq 0 ]
    grep -q "Re-checked by issue-pickup" "$GH_ARGV"
    [ "$(gh_calls 'Run log:')" -eq 0 ]
}

@test "--recheck does not search past the Parked paragraph" {
    printf 'No delivery needed: nothing left to do, see #61.\n\nParked as archon:skipped. See #60.\n' > "$RUN_LOG"
    ref 60 open-issue

    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/61 ')" -eq 1 ]
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/60 ')" -eq 0 ]
    assert_untouched
}

@test "--recheck with a failed close exits 1 without re-parking" {
    parked_verdict 'already fixed at HEAD by PR #50.'
    ref 50 merged-pr
    export GH_CLOSE_RC=1

    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ "$(gh_calls 'issue close 7 ')" -eq 1 ]
    [ "$(gh_calls 'issue edit')" -eq 0 ]
    [ "$(gh_calls 'issue comment')" -eq 0 ]
    [[ "$output" == *"#7 — GitHub confirms already fixed by merged PR #50, but the close failed"* ]]
}

# un-reminder #450 (2026-09-25): PR #449 is what turned Release red, not a fix.
health_verdict() {
    printf '%s\n' "$1" > "$RUN_LOG"
    printf '## Main CI red\n\nAuto-filed by `pipeline-health-cron.sh`. Main CI is a pipeline bottleneck.\n' > "$T/fixtures/body-450"
    ref 449 merged-pr
}

@test "the real #450 verdict parks a health-filed issue instead of closing it via the merged PR it cites" {
    health_verdict 'No delivery needed: Issue #450 flags Release CI failing at the current main HEAD (6975b17), but that commit — PR #449, merged one step before the issue was auto-filed — deliberately added the guard that fails Release when the secret is unset.
Report: /x'

    run "$SCRIPT" testproj 450 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue edit 450 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:skipped" "$GH_ARGV"
    [ "$(gh_calls 'issue close')" -eq 0 ]
    grep -q -- "issue comment 450 " "$GH_ARGV"
    grep -q "Not auto-closed: the issue was filed by pipeline-health-cron.sh" "$GH_ARGV"
    # The merged PR is never looked up; only the alert's own condition (#259).
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/')" -eq 0 ]
}

@test "--recheck leaves a parked health-filed verdict untouched even when it names a merged PR" {
    health_verdict 'No delivery needed: main is red because merged PR #449 added a guard; owner action needed.

Parked as archon:skipped. Remove the label and add archon:queued to run it again.'

    run "$SCRIPT" --recheck testproj 450 "$RUN_LOG"

    [ "$status" -eq 1 ]
    assert_untouched
}

@test "a failed issue lookup parks rather than closes" {
    printf 'No delivery needed: already fixed by PR #50.\nReport: /x\n' > "$RUN_LOG"
    ref 50 merged-pr
    export GH_VIEW_RC=1

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

@test "an empty non-health body still closes on a merged PR" {
    printf 'No delivery needed: already fixed by PR #50.\nReport: /x\n' > "$RUN_LOG"
    ref 50 merged-pr
    : > "$T/fixtures/body-7"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed --comment" "$GH_ARGV"
    [ "$(gh_calls 'Not auto-closed')" -eq 0 ]
}

# ── Lachesis pickup (lib/lachesis.sh) ────────────────────────────────────────

lachesis_on() {
    export LACHESIS_FLAG_TEST=1 LACHESIS_PICKUP_FLAG="$T/lachesis-pickup"
    echo 'LACHESIS_PICKUP=on' > "$LACHESIS_PICKUP_FLAG"
    cat > "$T/bin/lachesis" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${2:-}" >> "$LACHESIS_ARGV"
[ "$1" = add_dependency ] && exit "${LACHESIS_DEPEND_RC:-0}"
exit "${LACHESIS_RC:-0}"
STUB
    chmod +x "$T/bin/lachesis"
    export LACHESIS_CALL_CMD="$T/bin/lachesis" LACHESIS_ARGV="$T/lachesis-argv"
    : > "$LACHESIS_ARGV"
}

@test "lachesis pickup off: an unconfirmed verdict parks exactly as before, asking nothing" {
    export LACHESIS_CALL_CMD="$T/no-such-lachesis"
    echo 'No delivery needed: nothing to do here.' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    grep -q -- "Remove the label and add archon:queued to run it again" "$GH_ARGV"
}

@test "lachesis pickup on: an unconfirmed verdict asks the author before it parks" {
    lachesis_on
    echo 'No delivery needed: nothing to do here.' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    grep -q '^ask_question .*"repo":"alexsiri7/testproj".*"blocks":\[9\]' "$LACHESIS_ARGV"
    grep -q -- "Waiting on the author's answer" "$GH_ARGV"
}

@test "lachesis pickup on: a duplicate of an open issue closes without a question" {
    lachesis_on
    echo 'No delivery needed: duplicate of #8.' > "$RUN_LOG"
    ref 8 open-issue
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    grep -q -- "issue close 9 --repo alexsiri7/testproj --duplicate-of 8 --comment" "$GH_ARGV"
    [ ! -s "$LACHESIS_ARGV" ]
}

@test "lachesis pickup on: a duplicate of a closed issue closes without a question (#259)" {
    lachesis_on
    echo 'No delivery needed: duplicate of #8.' > "$RUN_LOG"
    ref 8 closed-issue
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    grep -q -- "issue close 9 --repo alexsiri7/testproj --reason not planned --comment" "$GH_ARGV"
    [ ! -s "$LACHESIS_ARGV" ]
}

@test "lachesis pickup on: a closed ref with no precedent reason asks, naming it" {
    lachesis_on
    echo 'No delivery needed: see #8 for background.' > "$RUN_LOG"
    ref 8 closed-issue
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    grep -q '^ask_question .*names closed issue #8: if #9 duplicates it, close #9 as a duplicate' "$LACHESIS_ARGV"
}

@test "lachesis pickup on: a question Lachesis refuses leaves the issue in progress" {
    lachesis_on
    export LACHESIS_RC=2
    echo 'No delivery needed: nothing to do here.' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    [ "$(gh_calls 'issue edit')" -eq 0 ]
    [ "$(gh_calls 'issue comment')" -eq 0 ]
    [[ "$output" == *"could not record a question in Lachesis"* ]]
}

# ── Deferring to a PR that cannot merge (#211) ───────────────────────────────

# 2026-10-13: GitHub hid every PR the flagged factory account opened, and six
# issues stayed parked a week behind PR numbers nothing could merge.
assert_released() {
    grep -q -- "issue edit $1 --repo alexsiri7/testproj --remove-label archon:in-progress${2:+ $2}\$" "$GH_ARGV"
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
    [ "$(gh_calls 'issue close')" -eq 0 ]
}

@test "blocked on a PR that answers 404 releases the issue to the queue once" {
    printf 'Not done: blocked on PR #186 implementing this, waiting on it to merge. Triage stopped.\nReport: /x\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_released 7 "--add-label archon:queued"
    grep -q -- "- #186 does not resolve (GitHub answers 404" "$GH_ARGV"
    grep -q -- "<!-- archon-settle-stale-refs: 186 -->" "$GH_ARGV"
    grep -q -- "Re-queued as archon:queued" "$GH_ARGV"
    [[ "$output" == *"#7 released to run again (stale PR refs: #186)"* ]]
}

@test "lachesis pickup on: a release only drops archon:in-progress and asks nothing" {
    lachesis_on
    printf 'Not done: blocked on PR #186. Triage stopped.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_released 7
    [ "$(gh_calls 'archon:queued')" -eq 0 ]
    grep -q -- "Lachesis next_issue decides" "$GH_ARGV"
    [ ! -s "$LACHESIS_ARGV" ]
}

@test "blocked on an open PR by a trusted author parks as today" {
    printf 'Not done: blocked on PR #9. Triage stopped.\n' > "$RUN_LOG"
    printf 'pr\topen\n' > "$T/fixtures/state-9"
    printf 'open\tfalse\tfalse\talexsiri7\n' > "$T/fixtures/pull-9"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    [ "$(gh_calls '/comments')" -eq 0 ]
}

@test "an open PR by an untrusted author, a fork, a closed or a merged PR each release" {
    printf 'pr\topen\n' > "$T/fixtures/state-9"
    printf 'open\tfalse\tfalse\tstranger\n' > "$T/fixtures/pull-9"
    printf 'pr\topen\n' > "$T/fixtures/state-10"
    printf 'open\tfalse\ttrue\talexsiri7\n' > "$T/fixtures/pull-10"
    printf 'pr\tclosed\n' > "$T/fixtures/state-11"
    printf 'closed\tfalse\tfalse\talexsiri7\n' > "$T/fixtures/pull-11"
    printf 'pr\tclosed\n' > "$T/fixtures/state-12"
    printf 'closed\ttrue\tfalse\talexsiri7\n' > "$T/fixtures/pull-12"
    printf 'Not done: blocked on PRs #9, #10, #11 and #12. Triage stopped.\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_released 7 "--add-label archon:queued"
    grep -q -- "- #9 is by stranger, not an account the factory can act for" "$GH_ARGV"
    grep -q -- "- #10 comes from a fork" "$GH_ARGV"
    grep -q -- "- #11 is closed without merging" "$GH_ARGV"
    grep -q -- "- #12 is already merged" "$GH_ARGV"
    grep -q -- "<!-- archon-settle-stale-refs: 9 10 11 12 -->" "$GH_ARGV"
}

@test "a hidden PR alongside an open issue parks" {
    printf 'Not done: blocked on PR #186 and issue #8. Triage stopped.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"
    printf 'issue\topen\n' > "$T/fixtures/state-8"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

@test "a hidden PR alongside a closed issue releases" {
    printf 'Not done: blocked on PR #186, see #8. Triage stopped.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"
    printf 'issue\tclosed\n' > "$T/fixtures/state-8"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_released 7 "--add-label archon:queued"
    grep -q -- "<!-- archon-settle-stale-refs: 186 -->" "$GH_ARGV"
}

@test "a hidden PR alongside a ref that cannot be looked up parks" {
    printf 'Not done: blocked on PR #186 and #8. Triage stopped.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

@test "an open PR whose pulls lookup fails parks" {
    printf 'Not done: blocked on PR #9. Triage stopped.\n' > "$RUN_LOG"
    printf 'pr\topen\n' > "$T/fixtures/state-9"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

@test "a PR an earlier settle already released parks with a note" {
    printf 'Not done: blocked on PR #186. Triage stopped.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"
    printf 'archon-ship finished without a PR: ...\n\n<!-- archon-settle-stale-refs: 12 186 -->\n' > "$T/fixtures/comments-7"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    grep -q -- "Not released again: the run deferred again to #186" "$GH_ARGV"
}

@test "a marker naming a different PR does not stop a release" {
    printf 'Not done: blocked on PR #18. Triage stopped.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-18"
    printf '<!-- archon-settle-stale-refs: 186 -->\n' > "$T/fixtures/comments-7"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_released 7 "--add-label archon:queued"
}

@test "a comment listing that fails parks" {
    printf 'Not done: blocked on PR #186. Triage stopped.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"
    export GH_COMMENTS_RC=1

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
}

@test "a failed release edit exits 1 without commenting" {
    printf 'Not done: blocked on PR #186. Triage stopped.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"
    export GH_EDIT_RC=1

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ "$(gh_calls 'issue comment')" -eq 0 ]
    [[ "$output" == *"could not release to run again"* ]]
}

@test "No delivery needed deferring to a hidden PR releases" {
    json_outcome false 'No delivery needed: PR #186 already implements this.\nReport: /x'
    touch "$T/fixtures/gone-186"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_released 7 "--add-label archon:queued"
}

@test "a Not done verdict that is not a deferral parks even when its PR is hidden" {
    printf 'Not done: planning stopped on calls only a person can make; see PR #186.\n' > "$RUN_LOG"
    touch "$T/fixtures/gone-186"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    [ "$(gh_calls 'api ')" -eq 0 ]
}

@test "a health-filed issue blocked on a hidden PR parks" {
    health_verdict 'Not done: blocked on PR #186. Triage stopped.'
    touch "$T/fixtures/gone-186"

    run "$SCRIPT" testproj 450 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue edit 450 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:skipped" "$GH_ARGV"
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/')" -eq 0 ]
    [ "$(gh_calls 'pulls/')" -eq 0 ]
    grep -q -- "Not auto-closed" "$GH_ARGV"
}

@test "--recheck never releases, even when the parked verdict's PR is hidden" {
    parked_verdict 'PR #186 already implements this.'
    touch "$T/fixtures/gone-186"

    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    assert_untouched
}

@test "No delivery needed naming a merged PR whose close failed parks, not releases" {
    printf 'No delivery needed: already fixed by PR #50.\nReport: /x\n' > "$RUN_LOG"
    fixture ref-50 merged-pr
    printf 'pr\tclosed\n' > "$T/fixtures/state-50"
    printf 'closed\ttrue\tfalse\talexsiri7\n' > "$T/fixtures/pull-50"
    export GH_CLOSE_RC=1

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "--add-label archon:skipped" "$GH_ARGV"
    [ "$(gh_calls 'archon-settle-stale-refs')" -eq 0 ]
}

# ── Severity tiers (#237), with Lachesis pickup on ───────────────────────────

# asked_default — the default of the one question asked ("" for none).
asked_default() {
    [ "$(grep -c '^ask_question ' "$LACHESIS_ARGV")" -eq 1 ]
    sed -n 's/^ask_question //p' "$LACHESIS_ARGV" | jq -r '.default // ""'
}

# tier_outcome <tier> <summary> — a v0.12 outcome line declaring <tier>.
tier_outcome() {
    jq -nc --argjson t "$1" --arg s "$2" '{delivered: false, reason: "blocked", pr_url: "", summary: $s, tier: $t}' > "$RUN_LOG"
}

@test "tiers: an unconfirmed No delivery needed with no tier asks with closing as its 2-day default" {
    lachesis_on
    echo 'No delivery needed: false positive alert, not a code change.' > "$RUN_LOG"

    run "$SCRIPT" testproj 9 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(asked_default)" = "Close #9 as completed: the run found nothing left to deliver. <!-- archon-settle-default: close-completed -->" ]
    sed -n 's/^ask_question //p' "$LACHESIS_ARGV" | jq -e '.wait_days == 2 and .kind == "clarification"
        and .options == ["Run #9 once more, with this verdict as direction.",
                         "Answer with what the next run should do differently."]'
    [[ "$output" == *"tier 2, default close-completed"* ]]
}

@test "tiers: No work owed defaults to closing as not planned" {
    lachesis_on
    echo 'No work owed in this repository: the crash is in the upstream SDK.' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    [[ "$(asked_default)" == *"<!-- archon-settle-default: close-not-planned -->" ]]
}

@test "tiers: blocked on one open issue defaults to recording the dependency" {
    lachesis_on
    printf 'Not done: blocked on #8 landing first.\n' > "$RUN_LOG"
    printf 'issue\topen\n' > "$T/fixtures/state-8"
    ref 8 open-issue
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [[ "$(asked_default)" == "Record #8 as blocking #9; "*"<!-- archon-settle-default: depend-8 -->" ]]
}

# An answer only releases the issue to run again; pickup carries out a close or
# a dependency only as a taken default, so no option may offer one.
@test "tiers: a question offers as options only answers that run the issue again" {
    lachesis_on
    printf 'issue\topen\n' > "$T/fixtures/state-8"
    ref 8 open-issue
    for verdict in 'No delivery needed: false positive alert, not a code change.' \
            'No work owed in this repository: the crash is in the upstream SDK.' \
            'Not done: blocked on #8 landing first.'; do
        : > "$LACHESIS_ARGV"
        echo "$verdict" > "$RUN_LOG"
        run "$SCRIPT" testproj 9 "$RUN_LOG"
        [ "$status" -eq 0 ]
        [ -n "$(asked_default)" ]
        sed -n 's/^ask_question //p' "$LACHESIS_ARGV" | jq -e '.options == ["Run #9 once more, with this verdict as direction.",
            "Answer with what the next run should do differently."]'
    done
}

# Pickup acts on a taken default only when its action matches
# SETTLE_DEFAULT_ACTION_RE; any other would launch a run instead.
@test "tiers: every default settle offers, but proceed, is one pickup carries out" {
    lachesis_on
    # shellcheck source=../lib/severity.sh
    source "$(dirname "$SCRIPT")/severity.sh"
    printf 'issue\topen\n' > "$T/fixtures/state-8"
    ref 8 open-issue
    local verdict action
    for verdict in 'No delivery needed: false positive alert, not a code change.' \
            'No work owed in this repository: the crash is in the upstream SDK.' \
            'Not done: blocked on #8 landing first.' \
            'Not done: blocked on Owner-level product decision: keep the documented tradeoff.' \
            'Not done: the investigation was inconclusive. The crash did not reproduce.'; do
        : > "$LACHESIS_ARGV"
        echo "$verdict" > "$RUN_LOG"
        run "$SCRIPT" testproj 9 "$RUN_LOG"
        [ "$status" -eq 0 ]
        action=$(asked_default | sed -nE 's/.*<!-- archon-settle-default: (.*) -->$/\1/p')
        [ -n "$action" ]
        [ "$action" = proceed ] || [[ "$action" =~ ^($SETTLE_DEFAULT_ACTION_RE)$ ]] \
            || { echo "pickup would not carry out $action"; return 1; }
    done
}

# asked_proceed — the one question asked defaults to running #9 once more,
# taken after two days.
asked_proceed() {
    [ "$(asked_default)" = "Run #9 once more, with this verdict as direction. <!-- archon-settle-default: proceed -->" ]
    sed -n 's/^ask_question //p' "$LACHESIS_ARGV" | jq -e '.wait_days == 2'
}

@test "tiers: blocked on an open PR, or on two issues, defaults to running once more" {
    lachesis_on
    printf 'Not done: blocked on PR #8.\n' > "$RUN_LOG"
    printf 'pr\topen\n' > "$T/fixtures/state-8"
    printf 'open\tfalse\tfalse\talexsiri7\n' > "$T/fixtures/pull-8"
    ref 8 pr
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    asked_proceed
    [[ "$output" == *"tier 2, default proceed"* ]]

    : > "$LACHESIS_ARGV"; : > "$GH_ARGV"
    printf 'Not done: blocked on #8 and #10.\n' > "$RUN_LOG"
    for n in 8 10; do printf 'issue\topen\n' > "$T/fixtures/state-$n"; ref "$n" open-issue; done
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    asked_proceed
    [[ "$output" == *"tier 2, default proceed"* ]]
}

@test "tiers: blocked on a decision naming no issue defaults to running once more" {
    lachesis_on
    printf 'Not done: blocked on Owner-level product decision: keep the documented no-revocation tradeoff, or restore server-side revocation.\n' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    asked_proceed
    [[ "$output" == *"tier 2, default proceed"* ]]
}

@test "tiers: a tier-3 blocked-on verdict naming no issue still asks with no default" {
    lachesis_on
    printf "Not done: blocked on the owner's GDPR position for data-subject requests.\n" > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(asked_default)" = "" ]
    sed -n 's/^ask_question //p' "$LACHESIS_ARGV" | jq -e 'has("wait_days") or has("options") | not'
    [[ "$output" == *"tier 3, default none"* ]]
}

@test "tiers: any other Not done defaults to running once more" {
    lachesis_on
    printf 'Not done: the investigation was inconclusive. The crash did not reproduce.\n' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    [[ "$(asked_default)" == "Run #9 once more, with this verdict as direction. <!-- archon-settle-default: proceed -->" ]]
}

@test "tiers: No delivery needed naming an open PR, an open sub-issue, or an unlooked-up ref, defaults to running once more" {
    lachesis_on
    echo 'No delivery needed: PR #50 implements this.' > "$RUN_LOG"
    ref 50 pr
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    asked_proceed

    : > "$LACHESIS_ARGV"; : > "$GH_ARGV"
    echo 'No delivery needed: every phase of this epic has shipped.' > "$RUN_LOG"
    printf '3\t1\n' > "$T/fixtures/sub-9"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    asked_proceed

    : > "$LACHESIS_ARGV"; : > "$GH_ARGV"; rm "$T/fixtures/sub-9"
    echo 'No delivery needed: see #8 for details.' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    asked_proceed
}

@test "tiers: a tier-3 word in the verdict or the title asks with no default, even when tier 1 is declared" {
    lachesis_on
    tier_outcome 1 'No delivery needed: the fix needs a production database backfill.'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(asked_default)" = "" ]
    [[ "$output" == *"tier 3, default none"* ]]

    : > "$LACHESIS_ARGV"; : > "$GH_ARGV"
    tier_outcome 1 'No delivery needed: nothing left to change.'
    fixture title-9 'Rotate the signing key before the next release'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(asked_default)" = "" ]
}

@test "tiers: tier 1 No delivery needed closes as completed with the act marker and a note, asking nothing" {
    lachesis_on
    tier_outcome 1 'No delivery needed: false positive alert, not a code change.'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    grep -q -- "issue close 9 --repo alexsiri7/testproj --reason completed --comment" "$GH_ARGV"
    grep -qx -- "<!-- archon-settle-act: close-completed -->" "$GH_ARGV"
    grep -q -- "--add-label archon:done" "$GH_ARGV"
    [ "$(grep -c '^ask_question' "$LACHESIS_ARGV")" -eq 0 ]
    sed -n 's/^add_note //p' "$LACHESIS_ARGV" | jq -e '.repo == "alexsiri7/testproj" and .issue == 9 and .type == "decision"'
}

@test "tiers: tier 1 No work owed closes as not planned" {
    lachesis_on
    tier_outcome 1 'No work owed in this repository: the crash is in the upstream SDK.'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    grep -q -- "issue close 9 --repo alexsiri7/testproj --reason not planned --comment" "$GH_ARGV"
    grep -qx -- "<!-- archon-settle-act: close-not-planned -->" "$GH_ARGV"
}

@test "tiers: tier 1 blocked on an open issue records the dependency and releases" {
    lachesis_on
    tier_outcome 1 'Not done: blocked on #8 landing first.'
    printf 'issue\topen\n' > "$T/fixtures/state-8"
    ref 8 open-issue
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    sed -n 's/^add_dependency //p' "$LACHESIS_ARGV" | jq -e '. == {repo: "alexsiri7/testproj", issue_number: 9, blocked_by_issue_number: 8}'
    assert_released 9
    grep -qx -- "<!-- archon-settle-act: depend-8 -->" "$GH_ARGV"
    [ "$(grep -c '^ask_question' "$LACHESIS_ARGV")" -eq 0 ]
    [ "$(grep -c '^add_note' "$LACHESIS_ARGV")" -eq 1 ]
}

@test "tiers: tier 1 other Not done releases to run again with the proceed marker" {
    lachesis_on
    tier_outcome 1 'Not done: the investigation was inconclusive. The crash did not reproduce.'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_released 9
    grep -qx -- "<!-- archon-settle-act: proceed -->" "$GH_ARGV"
    grep -q -- "the next run takes this verdict as direction" "$GH_ARGV"
    [ "$(grep -c '^ask_question' "$LACHESIS_ARGV")" -eq 0 ]
    [[ "$output" == *"#9 settled by tier-1 action proceed"* ]]
}

@test "tiers: proceed runs again at most once per issue, acted or offered" {
    lachesis_on
    for marker in '<!-- archon-settle-act: proceed -->' '<!-- archon-settle-default: proceed -->'; do
        : > "$LACHESIS_ARGV"; : > "$GH_ARGV"
        printf 'earlier\n%s\n' "$marker" > "$T/fixtures/comments-9"
        tier_outcome 1 'Not done: the investigation was inconclusive. The crash did not reproduce.'
        run "$SCRIPT" testproj 9 "$RUN_LOG"
        [ "$status" -eq 0 ]
        assert_parked 9
        [ "$(asked_default)" = "" ]
        [ "$(gh_calls 'archon-settle-act')" -eq 0 ]
    done
}

@test "tiers: a default offered before is not offered again" {
    lachesis_on
    printf '<!-- archon-settle-default: close-completed -->\n' > "$T/fixtures/comments-9"
    echo 'No delivery needed: false positive alert, not a code change.' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    [ "$(asked_default)" = "" ]
}

@test "tiers: comments that cannot be read leave the issue unsettled, asking nothing" {
    lachesis_on
    export GH_COMMENTS_RC=1
    tier_outcome 1 'No delivery needed: false positive alert, not a code change.'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not read its comments"* ]]
    [ "$(gh_calls 'issue comment')" -eq 0 ]
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
    [ "$(grep -c '^ask_question' "$LACHESIS_ARGV")" -eq 0 ]
}

@test "tiers: a tier-1 act whose release failed is not asked when the next settle cannot read its comments" {
    lachesis_on
    tier_outcome 1 'Not done: the investigation was inconclusive. The crash did not reproduce.'
    GH_EDIT_RC=1 run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 1 ]
    sed -n '/^issue comment 9 /,/lachesis:automated/p' "$GH_ARGV" \
        | sed '1s/^issue comment 9 --repo alexsiri7\/testproj --body //' > "$T/fixtures/comments-9"
    : > "$LACHESIS_ARGV"; : > "$GH_ARGV"
    GH_COMMENTS_RC=1 run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 1 ]
    [ "$(gh_calls 'issue comment')" -eq 0 ]
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
    [ "$(grep -c '^ask_question' "$LACHESIS_ARGV")" -eq 0 ]
}

@test "tiers: a health-filed issue, or one whose body cannot be read, is never closed by tier 1" {
    lachesis_on
    tier_outcome 1 'No work owed in this repository: main is red on a flaky runner.'
    printf '## Main CI red\n\nAuto-filed by `pipeline-health-cron.sh`.\n' > "$T/fixtures/body-9"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(asked_default)" = "" ]

    : > "$LACHESIS_ARGV"; : > "$GH_ARGV"
    rm "$T/fixtures/body-9"
    export GH_VIEW_RC=1
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(asked_default)" = "" ]
}

@test "tiers: a tier-1 close that fails asks with no default" {
    lachesis_on
    export GH_CLOSE_RC=1
    tier_outcome 1 'No delivery needed: false positive alert, not a code change.'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    grep -q -- "--add-label archon:skipped" "$GH_ARGV"
    [ "$(asked_default)" = "" ]
    [ "$(grep -c '^add_note' "$LACHESIS_ARGV")" -eq 0 ]
}

@test "tiers: a tier-1 action whose marker comment cannot be posted is not taken: it asks with no default" {
    lachesis_on
    export GH_COMMENT_RC=1
    tier_outcome 1 'Not done: the investigation was inconclusive. The crash did not reproduce.'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not post the tier-1 proceed comment; asking instead"* ]]
    [ "$(grep -c -- '--remove-label archon:in-progress$' "$GH_ARGV")" -eq 0 ]
    [ "$(grep -c '^add_note' "$LACHESIS_ARGV")" -eq 0 ]
    [ "$(asked_default)" = "" ]
    assert_parked 9
}

@test "tiers: a tier-1 depend or proceed that cannot release archon:in-progress fails closed" {
    lachesis_on
    export GH_EDIT_RC=1
    printf 'issue\topen\n' > "$T/fixtures/state-8"
    ref 8 open-issue
    for verdict in 'Not done: blocked on #8 landing first.' \
            'Not done: the investigation was inconclusive. The crash did not reproduce.'; do
        : > "$LACHESIS_ARGV"; : > "$GH_ARGV"
        tier_outcome 1 "$verdict"
        run "$SCRIPT" testproj 9 "$RUN_LOG"
        [ "$status" -eq 1 ]
        [[ "$output" == *"could not release archon:in-progress"* ]]
        [[ "$output" != *"settled by tier-1 action"* ]]
        [ "$(grep -c '^add_note' "$LACHESIS_ARGV")" -eq 0 ]
        [ "$(grep -c '^ask_question' "$LACHESIS_ARGV")" -eq 0 ]
    done
}

@test "tiers: a tier-1 act whose release failed is released by the next settle of its run, not asked" {
    lachesis_on
    printf 'issue\topen\n' > "$T/fixtures/state-8"
    ref 8 open-issue
    for verdict in 'Not done: blocked on #8 landing first.' \
            'Not done: the investigation was inconclusive. The crash did not reproduce.'; do
        : > "$LACHESIS_ARGV"; : > "$GH_ARGV"; rm -f "$T/fixtures/comments-9"
        tier_outcome 1 "$verdict"
        GH_EDIT_RC=1 run "$SCRIPT" testproj 9 "$RUN_LOG"
        [ "$status" -eq 1 ]
        # The act comment landed on GitHub; the unstick_stale re-settle passes
        # the same log by another path.
        sed -n '/^issue comment 9 /,/lachesis:automated/p' "$GH_ARGV" \
            | sed '1s/^issue comment 9 --repo alexsiri7\/testproj --body //' > "$T/fixtures/comments-9"
        grep -q 'archon-settle-act: ' "$T/fixtures/comments-9"
        : > "$LACHESIS_ARGV"; : > "$GH_ARGV"
        run "$SCRIPT" testproj 9 "$T/../${T##*/}/run.log"
        [ "$status" -eq 0 ]
        [[ "$output" == *"#9 settled by tier-1 action "* ]]
        grep -q -- '--remove-label archon:in-progress$' "$GH_ARGV"
        [ "$(gh_calls 'issue comment')" -eq 0 ]
        [ "$(gh_calls 'archon:skipped')" -eq 0 ]
        [ "$(grep -c '^add_note' "$LACHESIS_ARGV")" -eq 1 ]
        [ "$(grep -c '^add_dependency' "$LACHESIS_ARGV")" -eq 0 ]
        [ "$(grep -c '^ask_question' "$LACHESIS_ARGV")" -eq 0 ]
    done
}

@test "tiers: a tier-1 dependency Lachesis refuses asks with no default" {
    lachesis_on
    export LACHESIS_DEPEND_RC=1
    tier_outcome 1 'Not done: blocked on #8 landing first.'
    printf 'issue\topen\n' > "$T/fixtures/state-8"
    ref 8 open-issue
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(asked_default)" = "" ]
}

@test "tiers: --recheck never acts on a tier" {
    lachesis_on
    printf '{"delivered":false,"tier":1,"summary":"No delivery needed: false positive alert.\\n\\nParked as archon:skipped. x"}\n' > "$RUN_LOG"
    run "$SCRIPT" --recheck testproj 9 "$RUN_LOG"
    [ "$status" -eq 1 ]
    assert_untouched
    [ ! -s "$LACHESIS_ARGV" ]
}

@test "tiers: with pickup off a tier-1 outcome parks exactly as before" {
    export LACHESIS_CALL_CMD="$T/no-such-lachesis"
    tier_outcome 1 'No delivery needed: false positive alert, not a code change.'
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(gh_calls 'comments')" -eq 0 ]
    [[ "$output" != *"tier"* ]]
}

# ── Closes with a reason (#259) ──────────────────────────────────────────────
# The owner's rule of 2026-11-08: the factory closes any issue it can give a
# reason and evidence for, labels it factory-closed, and asks only for a spec
# decision or when it has no reason. Fixtures are the verbatim verdicts the
# factory parked on the owner before the rule.

assert_factory_closed() {
    grep -q -- "label create factory-closed --repo alexsiri7/testproj" "$GH_ARGV"
    grep -q -- "issue close $1 --repo alexsiri7/testproj $2 --comment" "$GH_ARGV"
    grep -q -- "issue edit $1 --repo alexsiri7/testproj --add-label factory-closed" "$GH_ARGV"
    grep -q -- "--add-label archon:done" "$GH_ARGV"
    grep -q -- "Closed by the factory without asking the owner" "$GH_ARGV"
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
}

HEAD_SHA=1111111111aaaaaaaaaa2222222222bbbbbbbbbb
ALERT_SHA=3333333333cccccccccc4444444444dddddddddd

# word-coach-annie "Prod deploy lagging main": the deploy succeeded ~16 min
# after the commit, before the run ended.
lagging_alert() {
    printf 'Prod deploy lagging main' > "$T/fixtures/title-$1"
    cat > "$T/fixtures/body-$1" <<BODY
## Prod deploy lagging main

**Repo**: alexsiri7/testproj
**main HEAD**: \`$ALERT_SHA\` (committed 2026-11-06T08:00:00Z, age 960s)
**Latest prod deploy**: \`0000000000eeeeeeeeee\` at 2026-11-06T07:00:00Z

Auto-filed by \`pipeline-health-cron.sh\`. main has been ahead of prod for >15 minutes.
BODY
}

ci_red_alert() {
    printf 'Main CI red: check' > "$T/fixtures/title-$1"
    cat > "$T/fixtures/body-$1" <<BODY
## Main CI red

**Repo**: alexsiri7/testproj
**SHA**: \`$ALERT_SHA\`
**Workflow**: CI
**Failing workflows at this SHA**: CI
**Failed jobs**: check

Auto-filed by \`pipeline-health-cron.sh\`. Main CI is a pipeline bottleneck.
BODY
}

@test "reason: a self-resolved deploy-lag alert closes, citing the deploy now on prod" {
    lachesis_on
    lagging_alert 1300
    echo "$HEAD_SHA" > "$T/fixtures/head"
    echo '[{"name":"Staging → Production Pipeline","conclusion":"success","createdAt":"2026-11-06T08:16:00Z"}]' \
        > "$T/fixtures/runs-$ALERT_SHA"
    printf 'No delivery needed: the deploy of %s succeeded about 16 minutes after the commit; the alert fired before it finished.\nReport: /x\n' "$ALERT_SHA" > "$RUN_LOG"

    run "$SCRIPT" testproj 1300 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 1300 "--reason completed"
    grep -q -- "Reason: the alert resolved itself. Evidence: prod deployed the alert's SHA ${ALERT_SHA:0:10} successfully" "$GH_ARGV"
    [ ! -s "$LACHESIS_ARGV" ]
}

@test "reason: a deploy alert whose SHA is only live through a production deployment closes" {
    lagging_alert 1300
    echo "$HEAD_SHA" > "$T/fixtures/head"
    echo '[{"id":77,"environment":"production"}]' > "$T/fixtures/deps-$HEAD_SHA"
    echo success > "$T/fixtures/depstate-77"
    printf 'Not done: blocked on nothing the code can change: Railway redeployed on its own.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 1300 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 1300 "--reason completed"
    grep -q -- "prod deployed main's HEAD ${HEAD_SHA:0:10} successfully" "$GH_ARGV"
}

@test "reason: a Main CI red alert closes once main's push CI is green at HEAD" {
    ci_red_alert 60
    echo "$HEAD_SHA" > "$T/fixtures/head"
    echo '[{"name":"CI","status":"completed","conclusion":"success","createdAt":"2026-11-06T09:00:00Z"},{"name":"CI","status":"completed","conclusion":"failure","createdAt":"2026-11-06T08:00:00Z"}]' \
        > "$T/fixtures/runs-$HEAD_SHA"
    printf 'No delivery needed: the brain.test.ts timeout is a flake; it passes 5 of 5 locally.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 60 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 60 "--reason completed"
    grep -q -- "main's push CI (CI) is green now at HEAD ${HEAD_SHA:0:10}" "$GH_ARGV"
    grep -q -- "run list --repo alexsiri7/testproj --branch main --commit $HEAD_SHA --event push" "$GH_ARGV"
}

@test "reason: an alert still red at HEAD, or whose HEAD cannot be read, parks for the owner" {
    ci_red_alert 60
    printf 'No delivery needed: the timeout is a flake.\nReport: /x\n' > "$RUN_LOG"
    echo "$HEAD_SHA" > "$T/fixtures/head"
    echo '[{"name":"CI","status":"completed","conclusion":"failure","createdAt":"2026-11-06T09:00:00Z"}]' \
        > "$T/fixtures/runs-$HEAD_SHA"

    run "$SCRIPT" testproj 60 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 60
    [ "$(gh_calls 'factory-closed')" -eq 0 ]

    : > "$GH_ARGV"
    rm "$T/fixtures/head"
    run "$SCRIPT" testproj 60 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 60
}

@test "reason: --recheck closes a parked alert once its condition is false, removing archon:skipped" {
    lagging_alert 1300
    printf 'No delivery needed: prod should catch up once Railway redeploys.\n\nParked as archon:skipped. Remove the label and add archon:queued to run it again.\n' > "$RUN_LOG"

    run "$SCRIPT" --recheck testproj 1300 "$RUN_LOG"
    [ "$status" -eq 1 ]
    assert_untouched

    echo "$HEAD_SHA" > "$T/fixtures/head"
    echo '[{"name":"Production","conclusion":"success","createdAt":"2026-11-06T08:16:00Z"}]' > "$T/fixtures/runs-$HEAD_SHA"
    run "$SCRIPT" --recheck testproj 1300 "$RUN_LOG"
    [ "$status" -eq 0 ]
    grep -q -- "issue edit 1300 --repo alexsiri7/testproj --remove-label archon:skipped --add-label archon:done" "$GH_ARGV"
    grep -q -- "issue edit 1300 --repo alexsiri7/testproj --add-label factory-closed" "$GH_ARGV"
}

# kith #60 (2026-11-06): a second filing of the alert #59 still tracks.
@test "reason: a health alert duplicating the open alert with the same title closes as its duplicate" {
    ci_red_alert 60
    ci_red_alert 59
    ref 59 open-issue
    printf 'No delivery needed: #60 ("Main CI red: check") is a duplicate auto-filing: issue #59, still open, cites the identical SHA (18ee9674b468cd743a120f173ba054d47ac3c4e7), the same CI run 42363331165, and the same failing job/test. Routed NO_ACTION/duplicate per the default triage policy, pointing to #59 as the open original. Full evidence in triage.md.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 60 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 60 "--duplicate-of 59"
    grep -q -- "#59 is the open alert pipeline-health filed with the same title" "$GH_ARGV"
}

@test "reason: a health alert whose named open issue is not the same alert parks" {
    ci_red_alert 60
    ref 59 open-issue
    printf 'No delivery needed: duplicate of #59.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 60 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 60
}

# musenmingle #399 (2026-11-06): a scraper check the owner had twice closed as
# a false positive (#242, #334).
@test "reason: the real musenmingle #399 false positive closes on its closed precedent, asking nothing" {
    lachesis_on
    cat > "$RUN_LOG" <<'LOG'
Not done: blocked on Both of #399's two claims look closable rather than workable, but neither qualifies for a no-person close under the project's default triage policy (duplicate of a still-open issue, or outcome delivered by a merged change). The "Camera-works missing" claim is a confirmed, maintainer-reaffirmed false positive (precedent #242, #334 — both closed without any code change, #334 explicitly "Agreed: false positive") against four_corners.rs's deliberate category() scope and its own test; neither precedent is itself open, and no merged change delivered the restated outcome (the code still deliberately skips it). A maintainer needs to decide whether to close this again as before, or invest in a qa_scope()/detail-page-fetch follow-up.. Issue #399 bundles two four-corners scraper QA findings. Both look like false positives rather than real bugs. Full evidence in triage.md.
Report: /x/triage.md
LOG
    ref 242 closed-issue
    ref 334 closed-issue

    run "$SCRIPT" testproj 399 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 399 "--reason not planned"
    grep -q -- "Closed as archon:done: matches closed precedent #242, #334" "$GH_ARGV"
    grep -q -- "Evidence: GitHub shows #242, #334 closed" "$GH_ARGV"
    [ ! -s "$LACHESIS_ARGV" ]
}

@test "reason: a false positive whose precedent is still open, or a blocker that is closed, does not close" {
    printf 'Not done: blocked on a maintainer: false positive, same as #242.\nReport: /x\n' > "$RUN_LOG"
    ref 242 open-issue
    run "$SCRIPT" testproj 399 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 399

    : > "$GH_ARGV"
    printf 'Not done: blocked on #12 landing first.\nReport: /x\n' > "$RUN_LOG"
    ref 12 closed-issue
    run "$SCRIPT" testproj 399 "$RUN_LOG"
    [ "$status" -eq 0 ]
    [ "$(gh_calls 'issue close')" -eq 0 ]
    [ "$(gh_calls 'factory-closed')" -eq 0 ]
}

# un-reminder #491 (2026-11-12): blocked on a Worker secret only the owner can
# rotate, and closed on "precedent" #490, itself closed as a duplicate of #491.
@test "reason: the real un-reminder #491 verdict (an owner-held secret, a circular duplicate precedent) asks with no default, naming the secret" {
    lachesis_on
    cat > "$RUN_LOG" <<'LOG'
Not done: blocked on Fixing this requires rotating/repairing the Cloudflare Worker secret UR_REQUESTY_KEY (and/or the underlying Requesty.ai API key), which only the owner can do via their Requesty.ai account and wrangler secret access; no code change in this repository can repair an upstream credential that Requesty's router is rejecting.. BLOCKED. The restated 403 "Invalid authorization token" comes from Requesty.ai's own router rejecting the Cloudflare secret UR_REQUESTY_KEY forwarded verbatim by worker/src/lib/requesty.ts:28 — the request-building and retry/Sentry-reporting code there is correct and unchanged by any likely fix. #490, closed as a duplicate of #491, confirms this is the same persistent Sentry issue (159900521) recurring since 2026-11-09, not a transient blip a code retry would absorb. No file in this repo sets or formats that secret; only the owner, via their Requesty.ai account and wrangler secret access, can rotate or repair it. Full evidence in triage.md.
Report: /x/triage.md
LOG
    ref 490 closed-duplicate

    run "$SCRIPT" testproj 491 "$RUN_LOG"

    [ "$status" -eq 0 ]
    [ "$(gh_calls 'issue close')" -eq 0 ]
    [ "$(gh_calls 'factory-closed')" -eq 0 ]
    assert_parked 491
    [ "$(asked_default)" = "" ]
    grep -q '^ask_question .*only the owner can set (UR_REQUESTY_KEY)' "$LACHESIS_ARGV"
    [[ "$output" == *"tier 3, default none"* ]]
}

@test "reason: a precedent closed as a duplicate of this issue is no precedent (#305 duplicate pair)" {
    printf 'Not done: blocked on a maintainer: this is a duplicate of #490, closed as a duplicate of #491.\nReport: /x\n' > "$RUN_LOG"
    ref 490 closed-duplicate
    run "$SCRIPT" testproj 491 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 491
    [ "$(gh_calls 'factory-closed')" -eq 0 ]

    : > "$GH_ARGV"
    lachesis_on
    run "$SCRIPT" testproj 491 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 491
    grep -q '^ask_question ' "$LACHESIS_ARGV"
    ! grep -q 'names closed issue #490' "$LACHESIS_ARGV"
}

@test "reason: a verdict saying the error is still recurring does not close on its closed precedent" {
    printf 'No delivery needed: duplicate of #8; the crash keeps firing in Sentry.\nReport: /x\n' > "$RUN_LOG"
    ref 8 closed-issue
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(gh_calls 'factory-closed')" -eq 0 ]

    # musenmingle #449: a recurring false-positive pattern is a precedent.
    : > "$GH_ARGV"
    printf 'No delivery needed: false positive, a recurring false-positive pattern, as in #8.\nReport: /x\n' > "$RUN_LOG"
    run "$SCRIPT" testproj 9 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_factory_closed 9 "--reason not planned"
}

# lachesis #407 (2026-10-27): the owner said close in the thread; the factory
# asked again anyway. Every factory comment is posted under the owner's token.
owner_thread() {
    jq -n --arg last "$2" '[
      {user: {login: "alexsiri7"}, author_association: "OWNER", html_url: "https://github.com/alexsiri7/testproj/issues/407#issuecomment-1",
       body: "archon-ship finished without a PR: Not done: blocked on which repo owns the fix.\n\nParked as archon:skipped.\n\n<!-- lachesis:automated -->"},
      {user: {login: "stranger"}, author_association: "NONE", html_url: "https://github.com/alexsiri7/testproj/issues/407#issuecomment-2",
       body: "Please close this."},
      {user: {login: "alexsiri7"}, author_association: "OWNER", html_url: "https://github.com/alexsiri7/testproj/issues/407#issuecomment-3",
       body: $last},
      {user: {login: "alexsiri7"}, author_association: "OWNER", html_url: "https://github.com/alexsiri7/testproj/issues/407#issuecomment-4",
       body: "Reviewed via assist mode on the author'\''s behalf. Close this issue directly.\n\n<!-- lachesis:automated -->"}
    ]' > "$T/fixtures/comments-json-$1"
}

LACHESIS_407_VERDICT='Not done: blocked on The maintainer (alexsiri7, OWNER) already decided in the issue'"'"'s most recent comment (2026-10-27) that this is out of scope for lachesis and should be closed with no lachesis-side change, pointing instead to pipeline-health deploy-alert dedup/scoping work on interstellarai.net and to separate owner-side severity-tier/post-triage-disposition work. Per the default triage policy, a close for '"'"'out of scope'"'"' reasons is left to a maintainer, not enacted automatically by this run.. BLOCKED: alexsiri7/lachesis#407 asks lachesis'"'"'s questions capability to auto-close clean NO_ACTION verdicts.'

@test "reason: the real lachesis #407 owner decision closes, quoting and linking the owner's comment" {
    lachesis_on
    printf '%s\nReport: /x\n' "$LACHESIS_407_VERDICT" > "$RUN_LOG"
    owner_thread 407 "Out of this repo's scope. Close it and point to interstellarai.net (the pipeline-health deploy-alert dedup / self-resolved alerts). No Lachesis change is needed."

    run "$SCRIPT" testproj 407 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 407 "--reason not planned"
    grep -q -- "Reason: the owner already decided in this thread. Evidence: https://github.com/alexsiri7/testproj/issues/407#issuecomment-3" "$GH_ARGV"
    grep -q -- "^> Out of this repo's scope. Close it and point to interstellarai.net" "$GH_ARGV"
    [ ! -s "$LACHESIS_ARGV" ]
}

@test "reason: an owner comment that declines to close, or a stranger's close, decides nothing" {
    lachesis_on
    printf '%s\nReport: /x\n' "$LACHESIS_407_VERDICT" > "$RUN_LOG"
    # musenmingle #389: an unmarked agent comment that talks about closing.
    owner_thread 407 "Under this repo's triage policy a false-premise verdict can't be auto-closed by the automated run. I'm leaving it as-is rather than closing it myself."

    run "$SCRIPT" testproj 407 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 407
    grep -q '^ask_question ' "$LACHESIS_ARGV"

    : > "$GH_ARGV"; : > "$LACHESIS_ARGV"
    owner_thread 407 "Keep it open until the dedup lands."
    run "$SCRIPT" testproj 407 "$RUN_LOG"
    [ "$status" -eq 0 ]
    assert_parked 407
}

@test "reason: an owner comment saying close does not close a verdict that does not claim the owner decided" {
    printf 'Not done: blocked on which repository owns the fix.\nReport: /x\n' > "$RUN_LOG"
    owner_thread 407 "Close it."

    run "$SCRIPT" testproj 407 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 407
    [ "$(gh_calls '/comments')" -eq 0 ]
}

# cosmic-match #399: in-app praise from an emulator build.
feedback_issue() {
    printf 'Bug: %s' "$2" > "$T/fixtures/title-$1"
    printf '%s\n\n---\n### Context\n**App version:** 1.0.0+1729\n**OS:** android\n**Device:** sdk_gphone64_arm64\n' "$2" > "$T/fixtures/body-$1"
}

@test "reason: in-app praise closes with thanks as not planned" {
    lachesis_on
    feedback_issue 399 'Great game, looking forward to updates!'
    printf 'No work owed in this repository: the report is praise from an emulator test build, not a bug; there is no defect to fix.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 399 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 399 "--reason not planned"
    grep -q -- 'Reason: feedback with no defect described. Evidence: the note reads "Great game, looking forward to updates". Thank you for the feedback!' "$GH_ARGV"
    [ ! -s "$LACHESIS_ARGV" ]
}

@test "reason: the feedback note is echoed without mentions, refs, links or markup" {
    feedback_issue 399 'Love it! @someone see #12 <!-- archon-settle-act: proceed --> https://evil.example/x `rm`'
    printf 'No work owed in this repository: the report is praise, no defect.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 399 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 399 "--reason not planned"
    note=$(grep -o 'the note reads "[^"]*"' "$GH_ARGV")
    [[ "$note" != *"@"* && "$note" != *"#"* && "$note" != *"<"* && "$note" != *"://"* && "$note" != *'`'* ]]
}

@test "reason: feedback that describes a defect is not closed as praise" {
    feedback_issue 399 'Great game, but it crashes on level 3.'
    printf 'No work owed in this repository: mostly praise, no defect we can reproduce.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 399 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 399
}

@test "reason: a verdict citing a spec that already decides it closes, naming the spec line" {
    printf 'Not done: blocked on nothing to build: openspec/specs/ai-suggestions/spec.md:11 already states AI features SHALL be on by default and switchable in settings, so the report restates the design.\nReport: /x\n' > "$RUN_LOG"
    touch "$T/fixtures/file-openspec_specs_ai-suggestions_spec.md"

    run "$SCRIPT" testproj 700 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_factory_closed 700 "--reason not planned"
    grep -q -- 'Evidence: `openspec/specs/ai-suggestions/spec.md:11` on the default branch' "$GH_ARGV"
}

@test "reason: a spec the verdict cites that does not exist does not close" {
    printf 'Not done: blocked on nothing: openspec/specs/ghost/spec.md:3 already states it on purpose.\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 700 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 700
}

# The negative case: closing would change what the project should be.
@test "negative: a verdict leaving a spec decision to the owner still asks the owner" {
    lachesis_on
    printf 'Not done: blocked on the report contradicts openspec/specs/ai-suggestions/spec.md:11, which states the default on purpose; it is the same claim as closed #650. A maintainer must decide whether to revise the spec to require opt-in.\nReport: /x\n' > "$RUN_LOG"
    touch "$T/fixtures/file-openspec_specs_ai-suggestions_spec.md"
    ref 650 closed-issue

    run "$SCRIPT" testproj 700 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 700
    [ "$(gh_calls 'factory-closed')" -eq 0 ]
    grep -q '^ask_question .*"blocks":\[700\]' "$LACHESIS_ARGV"
}

@test "negative: the real filmduel #700 verdict (GDPR, tier 3, a spec call) is not closed" {
    lachesis_on
    cat > "$RUN_LOG" <<'LOG'
Not done: blocked on Issue #700 bundles two claims. The 'consent bundled / cannot withdraw without deleting account' half is already delivered by merged PR #900 (commit 733415f) and #901 (afaac20). The remaining half — AI data sharing defaulting to on — is not a bug but restates a requirement the project's own current direction (openspec/specs/ai-suggestions/spec.md:11, 'AI features ... SHALL be on by default and switchable in settings', introduced 2026-10-02 before the issue was filed) affirms on purpose. Per the triage policy, an item that looks closable because it is 'rejected by direction' waits for a maintainer, not an automatic NO_ACTION. A maintainer must decide whether to reaffirm the on-by-default design against this security/GDPR-flavored finding (and close #700) or revise the spec to require opt-in (which would then route to plan).. Full evidence in triage.md.
Report: /x/triage.md
LOG
    touch "$T/fixtures/file-openspec_specs_ai-suggestions_spec.md"
    ref 900 merged-pr
    ref 901 merged-pr

    run "$SCRIPT" testproj 700 "$RUN_LOG"

    [ "$status" -eq 0 ]
    [ "$(gh_calls 'issue close')" -eq 0 ]
    [ "$(gh_calls 'factory-closed')" -eq 0 ]
}

@test "negative: a verdict with no reason to close still asks the owner" {
    lachesis_on
    printf 'Not done: blocked on an owner-level product decision: should guests see the leaderboard?\nReport: /x\n' > "$RUN_LOG"

    run "$SCRIPT" testproj 9 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 9
    [ "$(gh_calls 'factory-closed')" -eq 0 ]
    grep -q '^ask_question ' "$LACHESIS_ARGV"
}

@test "factory-close passes shellcheck" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    cd "$(dirname "$SCRIPT")/.."
    run shellcheck -x lib/factory-close.sh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
