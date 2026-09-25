#!/usr/bin/env bats
# Tests for ops/cron/lib/settle-ship-outcome.sh.
#
# Run: bunx bats ops/cron/tests/settle-ship-outcome.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/settle-ship-$$"
    mkdir -p "$T/bin" "$T/fixtures"
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/settle-ship-outcome.sh"

    # Stub gh: records argv and answers `gh api` with what its --jq would print:
    # "<total>\t<open>" for sub_issues (absent = no sub-issues), one of
    # completed-issue / merged-pr / pr / other for a single issue or PR.
    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
case "$*" in
  *sub_issues*)       cat "$GH_FIXTURES/sub-$(sed -E 's#.*/issues/([0-9]+)/.*#\1#' <<<"$*")" 2>/dev/null || printf '0\t0\n' ;;
  "api "*/issues/*)   cat "$GH_FIXTURES/ref-${2##*/}" 2>/dev/null || exit 1 ;;
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

assert_parked() {
    grep -q -- "issue edit $1 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:skipped" "$GH_ARGV"
    [ "$(gh_calls 'issue close')" -eq 0 ]
    [ "$(gh_calls '--add-label archon:done')" -eq 0 ]
}

# The verdict archon-ship actually left on un-reminder #431 (2026-09-16).
@test "the real #431 verdict closes as a duplicate of the closed issue it names" {
    cat > "$RUN_LOG" <<'LOG'
[outcome] running
No delivery needed: Issue #431 and closed issue #432 are duplicate GitHub records of the exact same Sentry event (UN-REMINDER-1C). The merged PR #433 already fixed #432 at HEAD. No engineering work remains; #431 just needs closing as a duplicate. Full evidence in /home/x/triage.md.
Report: /home/x/artifacts/triage.md
LOG
    fixture ref-432 completed-issue
    fixture ref-433 merged-pr

    run "$SCRIPT" testproj 431 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 431 --repo alexsiri7/testproj --duplicate-of 432 --comment" "$GH_ARGV"
    grep -q -- "issue edit 431 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:done" "$GH_ARGV"
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/431 ')" -eq 0 ]
    [[ "$output" == *"#431 settled as archon:done (duplicate of #432, closed as completed)"* ]]
}

@test "a verdict naming only a merged PR closes as completed" {
    printf 'No delivery needed: already fixed at HEAD by PR #50.\nReport: /x\n' > "$RUN_LOG"
    fixture ref-50 merged-pr

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

@test "a self-reference, an open issue, an unmerged PR and another repo's issue do not close" {
    printf 'No delivery needed: #7 duplicates #8, see PR #9 and alexsiri7/other#10.\nReport: /x\n' > "$RUN_LOG"
    fixture ref-8 other
    fixture ref-9 pr
    fixture ref-10 completed-issue

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
    fixture ref-50 merged-pr
    printf '2\t0\n' > "$T/fixtures/sub-7"

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    assert_parked 7
    [ "$(gh_calls 'api ')" -eq 0 ]
}

@test "a failed close falls back to parking" {
    printf 'No delivery needed: already fixed by PR #50.\nReport: /x\n' > "$RUN_LOG"
    fixture ref-50 merged-pr
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
    fixture ref-50 merged-pr
    fixture ref-60 completed-issue

    run "$SCRIPT" testproj 7 "$RUN_LOG"

    [ "$status" -eq 0 ]
    grep -q -- "issue close 7 --repo alexsiri7/testproj --reason completed" "$GH_ARGV"
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/60 ')" -eq 0 ]
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
    fixture ref-541 merged-pr

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
    fixture ref-60 completed-issue

    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/61 ')" -eq 1 ]
    [ "$(gh_calls 'api repos/alexsiri7/testproj/issues/60 ')" -eq 0 ]
    assert_untouched
}

@test "--recheck with a failed close exits 1 without re-parking" {
    parked_verdict 'already fixed at HEAD by PR #50.'
    fixture ref-50 merged-pr
    export GH_CLOSE_RC=1

    run "$SCRIPT" --recheck testproj 7 "$RUN_LOG"

    [ "$status" -eq 1 ]
    [ "$(gh_calls 'issue close 7 ')" -eq 1 ]
    [ "$(gh_calls 'issue edit')" -eq 0 ]
    [ "$(gh_calls 'issue comment')" -eq 0 ]
    [[ "$output" == *"#7 — GitHub confirms already fixed by merged PR #50, but the close failed"* ]]
}
