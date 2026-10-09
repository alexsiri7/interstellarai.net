#!/usr/bin/env bats
# Tests for lib/ship-breaker.sh (archon-ship circuit breaker) and
# lib/quota-pause.sh (rate-limit launch hold), against a scratch run DB with
# the two archon tables they read.
#
# Run: bunx bats ops/cron/tests/ship-breaker.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TMPDIR/ship-breaker-$$"
    mkdir -p "$T/bin"
    LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../lib" && pwd)"
    export ARCHON_DB="$T/archon.db"
    sqlite3 "$ARCHON_DB" "
      CREATE TABLE remote_agent_codebases (id TEXT PRIMARY KEY, name TEXT);
      CREATE TABLE remote_agent_workflow_runs (id TEXT PRIMARY KEY, codebase_id TEXT,
        workflow_name TEXT, user_message TEXT, status TEXT, started_at TEXT);
      CREATE TABLE remote_agent_workflow_events (id INTEGER PRIMARY KEY,
        workflow_run_id TEXT, event_type TEXT, data TEXT,
        created_at TEXT DEFAULT (datetime('now')));
      INSERT INTO remote_agent_codebases VALUES ('cb', 'alexsiri7/testproj');"

    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
case "$*" in
  *"/comments"*) cat "$GH_COMMENTS" 2>/dev/null || true ;;
  *"issue edit"*) exit "${GH_EDIT_RC:-0}" ;;
esac
STUB
    chmod +x "$T/bin/gh"
    export PATH="$T/bin:$PATH"
    export GH_ARGV="$T/gh-argv" GH_COMMENTS="$T/comments"
    : > "$GH_ARGV"

    unset _SHIP_BREAKER_SH _QUOTA_PAUSE_SH
    # shellcheck source=../lib/ship-breaker.sh
    source "$LIB/ship-breaker.sh"
    # shellcheck source=../lib/quota-pause.sh
    source "$LIB/quota-pause.sh"
}

teardown() {
    rm -rf "$T"
}

N=0
# run_row <status> <minutes ago> [event data...] — one archon-ship run on #5.
run_row() {
    local status="$1" ago="$2"; shift 2
    N=$((N + 1))
    sqlite3 "$ARCHON_DB" "INSERT INTO remote_agent_workflow_runs VALUES
      ('r$N', 'cb', 'archon-ship', 'fix #5', '$status', datetime('now', '-$ago minutes'));"
    local d
    for d in "$@"; do
        sqlite3 "$ARCHON_DB" "INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, data)
          VALUES ('r$N', 'node_failed', '$d');"
    done
}

@test "an issue with fewer failed runs than the threshold may launch" {
    run_row failed 30
    run_row failed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [ ! -s "$GH_ARGV" ]
}

@test "three consecutive failed runs park the issue" {
    run_row failed 50
    run_row failed 30
    run_row failed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    grep -q -- "issue edit 5 --repo alexsiri7/testproj .*--add-label manual-review --add-label archon:skipped" "$GH_ARGV"
    grep -q -- "issue comment 5 " "$GH_ARGV"
    [[ "$output" == *"circuit open (failed:3)"* ]]
}

@test "a park whose relabel fails posts no marker comment (it would reset the count)" {
    run_row failed 50
    run_row failed 30
    run_row failed 10
    GH_EDIT_RC=1 run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    [ "$(grep -c 'issue comment' "$GH_ARGV")" -eq 0 ]
}

@test "a completed run resets the count" {
    run_row failed 70
    run_row failed 50
    run_row completed 30
    run_row failed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
}

@test "rate-limit failures are not counted" {
    run_row failed 50
    run_row failed 30 '{"error":"Claude API error (rate_limit): You have hit your weekly limit"}'
    run_row failed 20 '{"error":"Claude API error (rate_limit): You have hit your weekly limit"}'
    run_row failed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
}

@test "one run refused a push for lack of the Workflows permission parks at once" {
    run_row failed 10 '{"node_output":"! [remote rejected] (refusing to allow a Personal Access Token to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)"}'
    run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"circuit open (workflow-scope)"* ]]
}

@test "only runs after the breaker's last park comment count" {
    run_row failed 50
    run_row failed 40
    run_row failed 30
    run_row failed 5
    date -u -d '-20 minutes' +%Y-%m-%dT%H:%M:%SZ > "$GH_COMMENTS"
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue edit' "$GH_ARGV")" -eq 0 ]
}

@test "another project's or issue's runs are not counted" {
    sqlite3 "$ARCHON_DB" "INSERT INTO remote_agent_codebases VALUES ('cb2', 'alexsiri7/other');"
    for i in 1 2 3; do
        sqlite3 "$ARCHON_DB" "INSERT INTO remote_agent_workflow_runs VALUES
          ('o$i', 'cb2', 'archon-ship', 'fix #5', 'failed', datetime('now'));
          INSERT INTO remote_agent_workflow_runs VALUES
          ('p$i', 'cb', 'archon-ship', 'fix #50', 'failed', datetime('now'));"
    done
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
}

@test "an unreadable run DB is reported, not read as a clean history" {
    export ARCHON_DB="$T/missing.db"
    run ship_breaker_check testproj 5
    [ "$status" -eq 2 ]
    [ ! -s "$GH_ARGV" ]
}

# ── quota-pause ──────────────────────────────────────────────────────────────

@test "quota: the reset a message names is the first such moment after the error" {
    local at
    at=$(date -d '2026-10-03 10:00 UTC' +%s)
    [ "$(quota_reset_epoch "$at" "You've hit your weekly limit · resets 3pm (Europe/London)")" = "$(date -d '2026-10-03 14:00 UTC' +%s)" ]
    [ "$(quota_reset_epoch "$at" "You've hit your limit · resets 9am (Europe/London)")" = "$(date -d '2026-10-04 08:00 UTC' +%s)" ]
    [ "$(quota_reset_epoch "$at" "You've hit your weekly limit · resets Oct 9, 3pm (Europe/London)")" = "$(date -d '2026-10-09 14:00 UTC' +%s)" ]
    [ "$(quota_reset_epoch "$at" "no reset here")" = "$((at + QUOTA_PAUSE_FALLBACK))" ]
}

@test "quota: a recent rate-limit error holds launches" {
    local spec
    spec=$(TZ=Europe/London date -d '+2 hours' '+%-I%P')
    run_row failed 1 "{\"error\":\"Claude API error (rate_limit): You have hit your weekly limit · resets $spec (Europe/London)\"}"
    run quota_may_launch test
    [ "$status" -eq 1 ]
    [[ "$output" == *"rate limit in effect until"* ]]
}

@test "quota: a rate-limit error whose reset has passed holds nothing" {
    sqlite3 "$ARCHON_DB" "INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, data, created_at)
      VALUES ('x', 'node_failed', '{\"error\":\"You have hit your limit · resets 3pm (Europe/London)\"}', datetime('now', '-3 days'));"
    run quota_may_launch test
    [ "$status" -eq 0 ]
}

@test "quota: an unreadable run DB holds nothing" {
    export ARCHON_DB="$T/missing.db"
    run quota_may_launch test
    [ "$status" -eq 0 ]
}

# ── Lachesis pickup: the park is a question (SHIP_BREAKER_ASK) ───────────────

@test "with SHIP_BREAKER_ASK a trip asks the author instead of relabelling" {
    run_row failed 50
    run_row failed 30
    run_row failed 10
    ask() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" > "$T/asked"; }
    SHIP_BREAKER_ASK=ask run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"asked the author in Lachesis"* ]]
    grep -q '^testproj|5|archon-ship keeps failing on #5' "$T/asked"
    grep -q -- "$SHIP_BREAKER_MARKER" "$T/asked"
    run ! grep -q 'issue edit\|issue comment' "$GH_ARGV"
}

@test "with SHIP_BREAKER_ASK a question that fails still launches nothing" {
    run_row failed 50
    run_row failed 30
    run_row failed 10
    ask() { return 1; }
    SHIP_BREAKER_ASK=ask run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not record the question in Lachesis"* ]]
    run ! grep -q 'issue edit\|issue comment' "$GH_ARGV"
}
