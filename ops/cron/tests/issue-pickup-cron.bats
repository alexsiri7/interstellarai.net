#!/usr/bin/env bats
# Tests for unstick_stale, auto_queue, auto_triage, promote_unblocked and
# pick_and_fire in ops/cron/issue-pickup-cron.sh.
#
# Run: bunx bats ops/cron/tests/issue-pickup-cron.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/issue-pickup-$$"
    mkdir -p "$T/bin" "$T/fixtures" "$T/base/testproj/.git"
    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/issue-pickup-cron.sh"

    # Stub gh: records argv, answers list/api/view calls from fixture files.
    # The api stubs return what `gh api --jq` would print: a count for
    # blocked_by/sub_issues (has_open_blockers only reads the length), a bare
    # timestamp for /events (when the label was last added; absent = never).
    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
issue_of() { sed -E 's#.*/issues/([0-9]+)/.*#\1#' <<<"$1"; }
case "$*" in
  *"issue list"*"--label archon:blocked"*)     cat "$GH_FIXTURES/blocked.json" ;;
  *"issue list"*"--label archon:queued"*)      cat "$GH_FIXTURES/queued.json" ;;
  *"issue list"*"--label archon:in-progress"*) cat "$GH_FIXTURES/in-progress.json" ;;
  *"issue list"*)                              cat "$GH_FIXTURES/open.json" ;;
  *"issue view "*)                             cat "$GH_FIXTURES/labels-$(sed -E 's/^issue view ([0-9]+).*/\1/' <<<"$*")" 2>/dev/null || echo '[]' ;;
  *"pr list"*)                                 echo 0 ;;
  *dependencies/blocked_by*)                   cat "$GH_FIXTURES/blockers-$(issue_of "$*")" 2>/dev/null || echo 0 ;;
  *sub_issues*)                                cat "$GH_FIXTURES/children-$(issue_of "$*")" 2>/dev/null || echo 0 ;;
  */events*)                                   cat "$GH_FIXTURES/events-$(issue_of "$*")" 2>/dev/null || true ;;
  *"issue edit"*)                              exit "${GH_EDIT_RC:-0}" ;;
  *"issue comment"*)                           exit 0 ;;
esac
STUB
    chmod +x "$T/bin/gh"
    export PATH="$T/bin:$PATH"
    export GH_ARGV="$T/gh-argv"
    export GH_FIXTURES="$T/fixtures"
    : > "$GH_ARGV"
    echo '[]' > "$T/fixtures/open.json"
    echo '[]' > "$T/fixtures/blocked.json"
    echo '[]' > "$T/fixtures/queued.json"
    echo '[]' > "$T/fixtures/in-progress.json"

    # Nothing is running: no live process, no run in the archon DB.
    pgrep() { return 1; }
    archon_run_active() { return 1; }
    archon_run_active_msg() { :; }
    # Keep the archon launch out of the test — it is backgrounded and disowned,
    # so there is nothing to synchronize on. The label edit and the log line
    # that precede it are the synchronous evidence a launch happened.
    nohup() { :; }

    LOGGED="$T/logged"
    log() { echo "$*" >> "$LOGGED"; }
    : > "$LOGGED"

    BASE_DIR="$T/base"
    SCRIPT_DIR="$T"
    SUMMARY_IN_PROGRESS=0
    SUMMARY_STALE=0
    SUMMARY_QUEUED=0
    SUMMARY_BLOCKED=0
    SUMMARY_PROMOTED=0
    SUMMARY_ACTION="none"
    SUMMARY_NOTE=""
    PROMOTED_ISSUES=()

    # shellcheck disable=SC1090
    source <(grep -E '^(INGEST|ARCHON|HUMAN)_LABELS=\(|^STUCK_AGE_SECONDS=' "$SCRIPT_FILE")
    load_fn has_open_blockers
    load_fn has_archon_label
    load_fn has_human_label
}

teardown() {
    rm -rf "$T"
}

# Load one function out of the cron script without executing the script.
load_fn() {
    # shellcheck disable=SC1090
    source <(awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\)" { p = 1 }
        p { print }
        p && /^}$/ { p = 0 }
    ' "$SCRIPT_FILE")
}

gh_calls() {
    [ "$1" = "--" ] && shift
    grep -c -- "$1" "$GH_ARGV" || true
}

# ── unstick_stale ────────────────────────────────────────────────────────────

# The 2026-09-14 shape: a ship run died on the weekly rate limit before doing
# anything, and the issue's human-intent label kept the unstick pass from
# re-queuing it, so it sat archon:in-progress for three days as phantom
# pending work. It must leave the in-progress state, but not into the queue.
@test "unstick_stale parks a stale in-progress issue that a human owns" {
    echo '[{"number":71}]' > "$T/fixtures/in-progress.json"
    echo '2026-01-01T00:00:00Z' > "$T/fixtures/events-71"
    echo '["bug","factory-gap","archon:in-progress"]' > "$T/fixtures/labels-71"
    load_fn unstick_stale

    unstick_stale testproj

    grep -q -- "issue edit 71 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:skipped" "$GH_ARGV"
    grep -q -- "issue comment 71 " "$GH_ARGV"
    [ "$(gh_calls -- '--add-label archon:queued')" -eq 0 ]
    [ "$SUMMARY_STALE" -eq 1 ]
    [ "$SUMMARY_IN_PROGRESS" -eq 1 ]
    grep -q "#71 — stale in-progress with human-intent label, parking as archon:skipped" "$LOGGED"
}

@test "unstick_stale still re-queues a stale in-progress issue nobody owns" {
    echo '[{"number":72}]' > "$T/fixtures/in-progress.json"
    echo '2026-01-01T00:00:00Z' > "$T/fixtures/events-72"
    echo '["bug","archon:in-progress"]' > "$T/fixtures/labels-72"
    load_fn unstick_stale

    unstick_stale testproj

    grep -q -- "issue edit 72 --repo alexsiri7/testproj --remove-label archon:in-progress --add-label archon:queued" "$GH_ARGV"
    [ "$(gh_calls 'archon:skipped')" -eq 0 ]
    [ "$SUMMARY_STALE" -eq 1 ]
}

@test "unstick_stale leaves an issue alone while its in-progress label is young" {
    echo '[{"number":73}]' > "$T/fixtures/in-progress.json"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$T/fixtures/events-73"
    echo '["bug","factory-gap","archon:in-progress"]' > "$T/fixtures/labels-73"
    load_fn unstick_stale

    unstick_stale testproj

    [ "$(gh_calls 'issue edit')" -eq 0 ]
    [ "$SUMMARY_STALE" -eq 0 ]
}

# ── auto_queue ───────────────────────────────────────────────────────────────

# #72: triage had already added `bug` before a human parked the issue, and
# auto_queue looked only at the ingest label. Human intent wins over ingest.
@test "auto_queue skips ingest-labeled issues that carry a human-intent label" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":30,"labels":[{"name":"bug"},{"name":"human-needed"}],"createdAt":"2026-01-01T00:00:00Z"},
 {"number":31,"labels":[{"name":"enhancement"},{"name":"requirements-gap"}],"createdAt":"2026-01-01T00:00:00Z"},
 {"number":32,"labels":[{"name":"bug"}],"createdAt":"2026-01-01T00:00:00Z"}]
JSON
    load_fn auto_queue

    auto_queue testproj

    grep -q -- "issue edit 32 --repo alexsiri7/testproj --add-label archon:queued" "$GH_ARGV"
    [ "$(gh_calls 'issue edit')" -eq 1 ]
}

@test "an issue labeled only requirements-gap is neither triaged nor queued" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":40,"labels":[{"name":"requirements-gap"}],"createdAt":"2026-01-01T00:00:00Z"}]
JSON
    load_fn auto_queue
    load_fn auto_triage

    auto_queue testproj
    auto_triage testproj

    [ "$(gh_calls 'issue edit')" -eq 0 ]
    [ "$SUMMARY_ACTION" = "none" ]
}

# ── auto_triage ──────────────────────────────────────────────────────────────

# The triage half of the 2026-09-14 shape: the run that owned the label died
# on its first node, and only that workflow ever removes the label.
@test "auto_triage retries an issue whose triage run died before classifying it" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":50,"labels":[{"name":"archon:triage-in-progress"}],"createdAt":"2026-01-01T00:00:00Z"}]
JSON
    echo '2026-01-01T01:00:00Z' > "$T/fixtures/events-50"
    load_fn auto_triage

    auto_triage testproj

    grep -q -- "issue edit 50 --repo alexsiri7/testproj --remove-label archon:triage-in-progress" "$GH_ARGV"
    grep -q -- "issue edit 50 --repo alexsiri7/testproj --add-label archon:triage-in-progress" "$GH_ARGV"
    [ "$SUMMARY_ACTION" = "triage #50" ]
    grep -q "#50 — triage-in-progress for" "$LOGGED"
}

@test "auto_triage leaves a triage-in-progress issue alone while its label is young" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":51,"labels":[{"name":"archon:triage-in-progress"}],"createdAt":"2026-01-01T00:00:00Z"}]
JSON
    date -u +%Y-%m-%dT%H:%M:%SZ > "$T/fixtures/events-51"
    load_fn auto_triage

    auto_triage testproj

    [ "$(gh_calls 'issue edit')" -eq 0 ]
    [ "$SUMMARY_ACTION" = "none" ]
}


# The #63 case: members of a blocked_by chain that sort ahead of a runnable
# candidate. Every blocked one is parked as the scan passes it, and the tick's
# single triage run still goes to the issue that can actually be worked on.
# Timestamps are distinct so the scan order is the sort, not jq's tie-break.
@test "auto_triage parks every blocked candidate it scans past and triages the runnable one" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":3,"labels":[],"createdAt":"2026-01-03T00:00:00Z"},
 {"number":2,"labels":[],"createdAt":"2026-01-02T00:00:00Z"},
 {"number":1,"labels":[],"createdAt":"2026-01-01T00:00:00Z"}]
JSON
    echo 1 > "$T/fixtures/blockers-1"
    echo 1 > "$T/fixtures/blockers-2"
    load_fn auto_triage

    auto_triage testproj

    grep -q -- "issue edit 1 --repo alexsiri7/testproj --add-label archon:blocked" "$GH_ARGV"
    grep -q -- "issue edit 2 --repo alexsiri7/testproj --add-label archon:blocked" "$GH_ARGV"
    grep -q -- "issue edit 3 --repo alexsiri7/testproj --add-label archon:triage-in-progress" "$GH_ARGV"
    [ "$(gh_calls 'archon:triage-in-progress')" -eq 1 ]
    [ "$SUMMARY_ACTION" = "triage #3" ]
    grep -q "triage launched for #3" "$LOGGED"
}

# Steady state for a chain whose root is the oldest: the root was triaged on an
# earlier tick and is skipped on archon:triage-in-progress, so this tick has no
# runnable candidate to break on and drains every blocked leaf in one pass.
@test "auto_triage parks a whole blocked chain on a tick with no runnable candidate" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":3,"labels":[],"createdAt":"2026-01-03T00:00:00Z"},
 {"number":2,"labels":[],"createdAt":"2026-01-02T00:00:00Z"},
 {"number":1,"labels":[{"name":"archon:triage-in-progress"}],"createdAt":"2026-01-01T00:00:00Z"}]
JSON
    echo 1 > "$T/fixtures/blockers-3"
    echo 1 > "$T/fixtures/blockers-2"
    load_fn auto_triage

    auto_triage testproj

    grep -q -- "issue edit 2 --repo alexsiri7/testproj --add-label archon:blocked" "$GH_ARGV"
    grep -q -- "issue edit 3 --repo alexsiri7/testproj --add-label archon:blocked" "$GH_ARGV"
    [ "$(gh_calls -- '--add-label archon:triage-in-progress')" -eq 0 ]
    [ "$SUMMARY_ACTION" = "none" ]
    [ "$SUMMARY_BLOCKED" -eq 2 ]
}

@test "auto_triage triages the oldest candidate, not the first row gh returns" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":9,"labels":[],"createdAt":"2026-03-01T00:00:00Z"},
 {"number":8,"labels":[],"createdAt":"2026-02-01T00:00:00Z"},
 {"number":7,"labels":[],"createdAt":"2026-01-01T00:00:00Z"}]
JSON
    load_fn auto_triage

    auto_triage testproj

    [ "$SUMMARY_ACTION" = "triage #7" ]
    [ "$(gh_calls 'archon:triage-in-progress')" -eq 1 ]
}

@test "auto_triage still skips labeled and human-parked issues" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":11,"labels":[{"name":"factory-gap"}],"createdAt":"2026-01-01T00:00:00Z"},
 {"number":12,"labels":[{"name":"archon:queued"}],"createdAt":"2026-01-02T00:00:00Z"},
 {"number":13,"labels":[{"name":"bug"}],"createdAt":"2026-01-03T00:00:00Z"}]
JSON
    echo 1 > "$T/fixtures/blockers-11"
    load_fn auto_triage

    auto_triage testproj

    [ "$SUMMARY_ACTION" = "none" ]
    [ "$(gh_calls 'issue edit')" -eq 0 ]
}

# ── promote_unblocked → pick_and_fire ────────────────────────────────────────

# The everyday path: the issue was queued on an earlier tick, so the search is
# the only thing that can supply it — nothing to fall back on from this tick's
# promotions. One candidate, so this asserts pickup happens, not pick order.
@test "pick_and_fire picks a queued issue the search reports with no promotion this tick" {
    echo '[{"number":20}]' > "$T/fixtures/queued.json"
    load_fn promote_unblocked
    load_fn pick_and_fire

    promote_unblocked testproj
    pick_and_fire testproj

    [ "$SUMMARY_PROMOTED" -eq 0 ]
    [ "$SUMMARY_QUEUED" -eq 1 ]
    [ "$SUMMARY_ACTION" = "pickup #20" ]
    grep -q -- "issue edit 20 --repo alexsiri7/testproj --remove-label archon:queued --add-label archon:in-progress" "$GH_ARGV"
}

@test "pick_and_fire picks an issue promoted this tick that the search misses" {
    echo '[{"number":10}]' > "$T/fixtures/blocked.json"
    load_fn promote_unblocked
    load_fn pick_and_fire

    promote_unblocked testproj
    pick_and_fire testproj

    grep -q -- "issue edit 10 --repo alexsiri7/testproj --remove-label archon:queued --add-label archon:in-progress" "$GH_ARGV"
    [ "$SUMMARY_ACTION" = "pickup #10" ]
    [ "$SUMMARY_QUEUED" -eq 1 ]
}

@test "a promoted issue the search already reports is not counted twice" {
    echo '[{"number":10}]' > "$T/fixtures/blocked.json"
    echo '[{"number":10}]' > "$T/fixtures/queued.json"
    load_fn promote_unblocked
    load_fn pick_and_fire

    promote_unblocked testproj
    pick_and_fire testproj

    [ "$SUMMARY_QUEUED" -eq 1 ]
    [ "$SUMMARY_ACTION" = "pickup #10" ]
}

@test "a promotion whose label swap failed is not picked up" {
    echo '[{"number":10}]' > "$T/fixtures/blocked.json"
    load_fn promote_unblocked
    load_fn pick_and_fire

    GH_EDIT_RC=1 promote_unblocked testproj
    pick_and_fire testproj

    [ "$SUMMARY_PROMOTED" -eq 0 ]
    [ "$SUMMARY_ACTION" = "none" ]
    [ "$SUMMARY_QUEUED" -eq 0 ]
}

@test "promoted numbers do not leak from one project into the next" {
    echo '[{"number":10}]' > "$T/fixtures/blocked.json"
    load_fn promote_unblocked
    load_fn pick_and_fire

    promote_unblocked testproj
    echo '[]' > "$T/fixtures/blocked.json"
    promote_unblocked otherproj
    pick_and_fire testproj

    [ "$SUMMARY_ACTION" = "none" ]
    [ "$SUMMARY_QUEUED" -eq 0 ]
}
