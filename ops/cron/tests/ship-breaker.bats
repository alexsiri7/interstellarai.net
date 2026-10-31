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
        workflow_run_id TEXT, event_type TEXT, step_name TEXT, data TEXT,
        created_at TEXT DEFAULT (datetime('now')));
      INSERT INTO remote_agent_codebases VALUES ('cb', 'alexsiri7/testproj');"

    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
case "$*" in
  *"/comments"*) cat "$GH_COMMENTS" 2>/dev/null || true ;;
  *"issue edit"*) exit "${GH_EDIT_RC:-0}" ;;
  *"issue comment"*) exit "${GH_COMMENT_RC:-0}" ;;
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
# breaker_comment park|retry <minutes ago> — one of the breaker's comments on
# #5, as ship_breaker_check's --jq prints it.
breaker_comment() {
    printf '%s\t%s\n' "$1" "$(date -u -d "-$2 minutes" +%Y-%m-%dT%H:%M:%SZ)" >> "$GH_COMMENTS"
}

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

@test "three consecutive failed runs first get one diagnose-and-retry run (#237)" {
    run_row failed 50
    run_row failed 30 '{"error":"boom\nat line 2"}'
    run_row failed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue edit' "$GH_ARGV")" -eq 0 ]
    grep -q -- "issue comment 5 --repo alexsiri7/testproj --body The archon-ship circuit breaker would park #5: its last 3 runs all failed" "$GH_ARGV"
    grep -qE -- "^- [0-9-]+ [0-9:]+: boom at line 2$" "$GH_ARGV"
    [ "$(grep -c -- '^- .*: no error recorded' "$GH_ARGV")" -eq 2 ]
    grep -qx -- "$SHIP_BREAKER_RETRY_MARKER" "$GH_ARGV"
    grep -qx -- '<!-- lachesis:automated -->' "$GH_ARGV"
    [[ "$output" == *"circuit would open (failed:3); one diagnose-and-retry run first"* ]]
}

@test "a retry comment that cannot be posted launches nothing" {
    run_row failed 50
    run_row failed 30
    run_row failed 10
    GH_COMMENT_RC=1 run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not post the retry comment"* ]]
}

@test "the diagnosis says so when the run history cannot be read" {
    export ARCHON_DB="$T/missing.db"
    [ "$(ship_breaker_diagnosis testproj 5)" = "- the run history could not be read" ]
}

@test "a retry newer than the last failed run may launch" {
    run_row failed 50
    run_row failed 30
    run_row failed 10
    breaker_comment retry 5
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue ' "$GH_ARGV")" -eq 0 ]
}

@test "a retry followed by a completed run may launch" {
    run_row failed 50
    run_row failed 40
    run_row failed 30
    breaker_comment retry 20
    run_row completed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
}

@test "a failed run after the retry parks the issue" {
    run_row failed 50
    run_row failed 40
    run_row failed 30
    breaker_comment retry 20
    run_row failed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    grep -q -- "issue edit 5 --repo alexsiri7/testproj .*--add-label manual-review --add-label archon:skipped" "$GH_ARGV"
    grep -q -- "One diagnose-and-retry run after the breaker's comment failed too." "$GH_ARGV"
    grep -qx -- "$SHIP_BREAKER_MARKER" "$GH_ARGV"
    grep -qx -- '<!-- lachesis:automated -->' "$GH_ARGV"
    [[ "$output" == *"circuit open (failed:4)"* ]]
}

@test "a retry run that completed resets the count: a later streak retries again, it does not park" {
    run_row failed 90
    run_row failed 80
    run_row failed 70
    breaker_comment retry 65
    run_row completed 60
    run_row failed 50
    run_row failed 30
    run_row failed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue edit' "$GH_ARGV")" -eq 0 ]
    grep -qx -- "$SHIP_BREAKER_RETRY_MARKER" "$GH_ARGV"
    [ "$(grep -c -- 'failed too' "$GH_ARGV")" -eq 0 ]
}

@test "only rate-limited runs since the retry leave it pending: may launch" {
    run_row failed 50
    run_row failed 40
    run_row failed 30
    breaker_comment retry 20
    run_row failed 10 '{"error":"Claude API error (rate_limit): You have hit your weekly limit"}'
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [ "$(grep -c 'issue ' "$GH_ARGV")" -eq 0 ]
}

@test "the diagnosis posted to the issue carries no secret-shaped text" {
    run_row failed 50 '{"error":"git push https://x-access-token:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/a/b failed"}'
    run_row failed 30 '{"error":"env: GH_TOKEN=github_pat_11ABCDEFGHIJ_klmnopqrst NTFY_TOPIC=sekrit, Authorization: Bearer abcdefghijklmnopqrstu"}'
    run_row failed 10 '{"error":"the factory token could not push; password: hunter2"}'
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    ! grep -qE -- 'ghp_|github_pat_|sekrit|abcdefghijklmnopqrstu|hunter2|x-access-token' "$GH_ARGV"
    grep -q -- "https://\[redacted\]@github.com/a/b failed" "$GH_ARGV"
    grep -q -- "the factory token could not push; password: \[redacted\]" "$GH_ARGV"
}

@test "every secret shape the diagnosis can quote is redacted" {
    local secret line
    local -a secrets=(
        ghs_abcdefghijklmnopqrstuvwxyz github_pat_11ABCDEFGHIJ_klmnopqrst
        sk-abcdefghijklmnopqrstuvwx xoxb-1234567890-abcdefghijkl dp.st.prd.abcdefghijklmnopqrst
        AKIAABCDEFGHIJKLMNOP
        eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlc2lnbmF0dXJl
        userpass1234 bearerabcdefghijklmno basicabcdefghijklmnop tokenabcdefghijklmnop
        tokval1 secval1 pwval1 apikeyval1 privval1 upperval1)
    run ship_breaker_redact <<'EOF'
push as ghs_abcdefghijklmnopqrstuvwxyz failed
cloned with github_pat_11ABCDEFGHIJ_klmnopqrst
openai rejected sk-abcdefghijklmnopqrstuvwx
slack rejected xoxb-1234567890-abcdefghijkl
doppler rejected dp.st.prd.abcdefghijklmnopqrst
aws rejected AKIAABCDEFGHIJKLMNOP
session eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlc2lnbmF0dXJl expired
fetch https://bot:userpass1234@example.com/x failed
Authorization: Bearer bearerabcdefghijklmno
Authorization: Basic basicabcdefghijklmnop
Authorization: token tokenabcdefghijklmnop
access_token=tokval1
client_secret: secval1
"passwd": "pwval1"
API-KEY=apikeyval1
private_key: privval1
export MY_VAR=upperval1
EOF
    [ "$status" -eq 0 ]
    for secret in "${secrets[@]}"; do
        [[ "$output" != *"$secret"* ]] || { echo "leaked: $secret"; return 1; }
    done
    while IFS= read -r line; do
        [[ "$line" == *"[redacted]"* ]] || { echo "not redacted: $line"; return 1; }
    done <<<"$output"
}

@test "a retry from before the last park is spent: the next trip retries again" {
    breaker_comment retry 90
    breaker_comment park 80
    run_row failed 50
    run_row failed 30
    run_row failed 10
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    grep -qx -- "$SHIP_BREAKER_RETRY_MARKER" "$GH_ARGV"
    [ "$(grep -c 'issue edit' "$GH_ARGV")" -eq 0 ]
}

@test "a park whose relabel fails posts no marker comment (it would reset the count)" {
    run_row failed 50
    run_row failed 30
    breaker_comment retry 20
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

# outcome_row <minutes ago> <summary> — a completed run whose outcome node
# printed {delivered:false, summary} (Archon v0.12 ship tail).
outcome_row() {
    run_row completed "$1"
    local out; out=$(jq -cn --arg s "$2" '{delivered: false, reason: "blocked", pr_url: "", summary: $s}')
    sqlite3 "$ARCHON_DB" "INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, step_name, data)
      VALUES ('r$N', 'node_completed', 'outcome', '$(jq -cn --arg o "$out" '{node_output: $o}')');"
}

@test "completed runs with a placeholder verdict count as failed (#209)" {
    outcome_row 50 $'Not done: blocked on test. test\nReport: /x/triage.md'
    outcome_row 30 $'Not done: blocked on test. test\nReport: /x/triage.md'
    outcome_row 10 $'Not done: blocked on test. test\nReport: /x/triage.md'
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"circuit would open (failed:3)"* ]]
}

@test "a completed run with a real verdict still resets the count" {
    run_row failed 50
    run_row failed 40
    outcome_row 30 $'Not done: blocked on #12 landing first. Triage says the fix needs #12.\nReport: /x/triage.md'
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
    run ! grep -qx -- "$SHIP_BREAKER_RETRY_MARKER" "$GH_ARGV"
}

@test "the agent stream quoting the scope patterns is not a refused push (#209)" {
    run_row failed 10
    local q="AND (e.data LIKE '%create or update workflow%' OR e.data LIKE '%without workflow scope%')"
    local t
    for t in provider_event tool_called tool_completed; do
        sqlite3 "$ARCHON_DB" "INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, data)
          VALUES ('r$N', '$t', '$(printf '%s' "{\"text\":\"$q\"}" | sed "s/'/''/g")');"
    done
    run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [[ "$output" != *"workflow-scope"* ]]
}

@test "a refused push reported in a completed node's output parks at once" {
    run_row failed 10
    sqlite3 "$ARCHON_DB" "INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, data)
      VALUES ('r$N', 'node_completed', '{\"node_output\":\"git push was rejected: refusing to allow a Personal Access Token to create or update workflow .github/workflows/ci.yml without workflow scope\"}');"
    run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"circuit open (workflow-scope)"* ]]
}

@test "only runs after the breaker's last park comment count" {
    run_row failed 50
    run_row failed 40
    run_row failed 30
    run_row failed 5
    breaker_comment park 20
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

@test "with SHIP_BREAKER_ASK a trip retries before it asks" {
    run_row failed 50
    run_row failed 30
    run_row failed 10
    ask() { touch "$T/asked"; }
    SHIP_BREAKER_ASK=ask run ship_breaker_check testproj 5
    [ "$status" -eq 0 ]
    [ ! -e "$T/asked" ]
    grep -qx -- "$SHIP_BREAKER_RETRY_MARKER" "$GH_ARGV"
}

@test "with SHIP_BREAKER_ASK a failed retry asks the author instead of relabelling" {
    run_row failed 50
    run_row failed 30
    breaker_comment retry 20
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
    breaker_comment retry 20
    run_row failed 10
    ask() { return 1; }
    SHIP_BREAKER_ASK=ask run ship_breaker_check testproj 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not record the question in Lachesis"* ]]
    run ! grep -q 'issue edit\|issue comment' "$GH_ARGV"
}
