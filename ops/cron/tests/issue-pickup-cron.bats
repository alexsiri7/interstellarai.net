#!/usr/bin/env bats
# Tests for auto_triage, promote_unblocked and pick_and_fire in
# ops/cron/issue-pickup-cron.sh.
#
# Run: bunx bats ops/cron/tests/issue-pickup-cron.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/issue-pickup-$$"
    mkdir -p "$T/bin" "$T/fixtures" "$T/base/testproj/.git"
    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/issue-pickup-cron.sh"

    # Stub gh: records argv, answers list/api calls from fixture files.
    # The api stubs return what `gh api --jq` would print — a count — because
    # has_open_blockers only ever reads the length.
    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
issue_of() { sed -E 's#.*/issues/([0-9]+)/.*#\1#' <<<"$1"; }
case "$*" in
  *"issue list"*"--label archon:blocked"*) cat "$GH_FIXTURES/blocked.json" ;;
  *"issue list"*"--label archon:queued"*)  cat "$GH_FIXTURES/queued.json" ;;
  *"issue list"*)                          cat "$GH_FIXTURES/open.json" ;;
  *dependencies/blocked_by*)               cat "$GH_FIXTURES/blockers-$(issue_of "$*")" 2>/dev/null || echo 0 ;;
  *sub_issues*)                            cat "$GH_FIXTURES/children-$(issue_of "$*")" 2>/dev/null || echo 0 ;;
  *"issue edit"*)                          exit "${GH_EDIT_RC:-0}" ;;
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
    SUMMARY_QUEUED=0
    SUMMARY_BLOCKED=0
    SUMMARY_PROMOTED=0
    SUMMARY_ACTION="none"
    SUMMARY_NOTE=""
    PROMOTED_ISSUES=()

    # shellcheck disable=SC1090
    source <(grep -E '^(INGEST|ARCHON|HUMAN)_LABELS=\(' "$SCRIPT_FILE")
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
    grep -c -- "$1" "$GH_ARGV" || true
}

# ── auto_triage ──────────────────────────────────────────────────────────────

# The reli case from #63: a blocked_by chain filed in one burst. Timestamps are
# identical here, so ordering cannot be what saves the root — the blocker check
# is: the leaves are parked without spending the tick's one triage run.
@test "auto_triage parks a same-second blocked chain and triages only its root" {
    cat > "$T/fixtures/open.json" <<'JSON'
[{"number":3,"labels":[],"createdAt":"2026-01-01T00:00:00Z"},
 {"number":2,"labels":[],"createdAt":"2026-01-01T00:00:00Z"},
 {"number":1,"labels":[],"createdAt":"2026-01-01T00:00:00Z"}]
JSON
    echo 1 > "$T/fixtures/blockers-3"
    echo 1 > "$T/fixtures/blockers-2"
    load_fn auto_triage

    auto_triage testproj

    grep -q -- "issue edit 3 --repo alexsiri7/testproj --add-label archon:blocked" "$GH_ARGV"
    grep -q -- "issue edit 2 --repo alexsiri7/testproj --add-label archon:blocked" "$GH_ARGV"
    grep -q -- "issue edit 1 --repo alexsiri7/testproj --add-label archon:triage-in-progress" "$GH_ARGV"
    [ "$(gh_calls 'archon:triage-in-progress')" -eq 1 ]
    [ "$SUMMARY_ACTION" = "triage #1" ]
    grep -q "triage launched for #1" "$LOGGED"
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
