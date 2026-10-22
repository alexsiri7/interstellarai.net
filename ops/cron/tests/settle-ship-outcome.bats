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
    # `issue view` prints the body-<issue> fixture (default: an ordinary body),
    # or fails with GH_VIEW_RC.
    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
case "$*" in
  *sub_issues*)       cat "$GH_FIXTURES/sub-$(sed -E 's#.*/issues/([0-9]+)/.*#\1#' <<<"$*")" 2>/dev/null || printf '0\t0\n' ;;
  "api "*/issues/*)   [ "$3" = --jq ] && jq -r "$4" "$GH_FIXTURES/ref-${2##*/}" 2>/dev/null ;;
  *"issue view"*)
    [ -n "${GH_VIEW_RC:-}" ] && exit "$GH_VIEW_RC"
    cat "$GH_FIXTURES/body-$(sed -E 's/^issue view ([0-9]+).*/\1/' <<<"$*")" 2>/dev/null || echo 'An ordinary issue.' ;;
  *"issue close"*)    exit "${GH_CLOSE_RC:-0}" ;;
  *"issue edit"*)     exit "${GH_EDIT_RC:-0}" ;;
  *"issue comment"*)  exit 0 ;;
esac
STUB
    chmod +x "$T/bin/gh"
    export PATH="$T/bin:$PATH"
    export GH_ARGV="$T/gh-argv"
    export GH_FIXTURES="$T/fixtures"
    : > "$GH_ARGV"
    RUN_LOG="$T/run.log"
}

teardown() {
    rm -rf "$T"
}

gh_calls() {
    grep -c -- "$1" "$GH_ARGV" || true
}

fixture() { printf '%s\n' "$2" > "$T/fixtures/$1"; }

# ref <N> open-issue|closed-issue|merged-pr|pr: what GitHub's issues API
# returns for #N.
ref() {
    local json
    case "$2" in
        open-issue)   json='{"state":"open"}' ;;
        closed-issue) json='{"state":"closed","state_reason":"completed"}' ;;
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

@test "a verdict naming only a closed original parks for a maintainer, naming it" {
    printf 'No delivery needed: duplicate of #8, closed last week.\nReport: /x\n' > "$RUN_LOG"
    ref 8 closed-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    grep -q -- "Not auto-closed: the verdict names closed issue #8, and a duplicate of a closed issue is a maintainer's call" "$GH_ARGV"
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
        [ "$(gh_calls 'api ')" -eq 0 ]
    done
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
    [ "$(gh_calls 'api ')" -eq 0 ]
    grep -q -- "issue comment 450 " "$GH_ARGV"
    grep -q "Not auto-closed: the issue was filed by pipeline-health-cron.sh" "$GH_ARGV"
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

@test "lachesis pickup on: a duplicate of a closed issue asks, naming it" {
    lachesis_on
    echo 'No delivery needed: duplicate of #8.' > "$RUN_LOG"
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
