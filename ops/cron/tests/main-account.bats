#!/usr/bin/env bats
# Tests for lib/main-account.sh (the owner's main account as the factory's
# paced fallback), its use in lib/quota-pause.sh and the archon shim.
#
# Run: bunx bats ops/cron/tests/main-account.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../lib" && pwd)"
    SHIM="$LIB/archon-shim/archon"
    mkdir -p "$T/bin" "$T/home/.config/archon-cron" "$T/main"
    export HOME="$T/home"
    printf '#!/usr/bin/env bash\necho "sudo $*" >> "%s/argv"\n' "$T" > "$T/bin/sudo"
    chmod +x "$T/bin/sudo"
    export PATH="$T/bin:$PATH"
    export MAIN_ACCOUNT_FLAG="$T/home/.config/archon-cron/main-account" MAIN_ACCOUNT_FLAG_TEST=1
    export MAIN_ACCOUNT_DIR="$T/main"
    echo "ARCHON_MAIN_ACCOUNT=on" > "$MAIN_ACCOUNT_FLAG"
    guard '{ "enabled": true, "weeklyCapPercent": 65, "fiveHourCapPercent": 60, "pace": true }'
    # The probe stands in for one haiku request: it writes what PROBE_WRITES holds.
    export MAIN_ACCOUNT_PROBE_CMD="$T/bin/probe"
    printf '#!/usr/bin/env bash\necho probe >> "%s/argv"\n[ -n "${PROBE_WRITES:-}" ] && cp "$PROBE_WRITES" "%s/main/plan-usage.json"\nexit 0\n' "$T" "$T" > "$T/bin/probe"
    chmod +x "$T/bin/probe"
    : > "$T/argv"
    unset _MAIN_ACCOUNT_SH _QUOTA_PAUSE_SH _SHIP_BREAKER_SH ARCHON_RUN_AS
    source "$LIB/main-account.sh"
}

guard() { printf '%s\n' "$1" > "$T/main/budget-guard.json"; }

# usage <file> <recorded-seconds-ago> <7d %> <7d resets in seconds> [5h %]
usage() {
    local now; now=$(date +%s)
    cat > "$1" <<JSON
{ "recordedAt": "$(date -u -d "@$((now - $2))" +%FT%TZ)",
  "rateLimits": [
    { "kind": "five_hour", "percentUsed": ${5:-10}, "resetsAt": "$(date -u -d "@$((now + 3600))" +%FT%TZ)" },
    { "kind": "seven_day", "percentUsed": $3, "resetsAt": "$(date -u -d "@$((now + $4))" +%FT%TZ)" } ] }
JSON
}

DAY=86400

@test "pace: the weekly cap is 65% times the share of the week elapsed" {
    # 4 of 7 days left: 3/7 elapsed, cap 65 * 3/7 = 27.9%.
    usage "$T/main/plan-usage.json" 60 27 $((4 * DAY))
    run main_account_verdict
    [[ "$output" == "ok 7d 27% of a 27.9% cap"* ]]
    usage "$T/main/plan-usage.json" 60 28 $((4 * DAY))
    run main_account_verdict
    [ "$output" = "hold 7d 28% at or past its cap 27.9%" ]
}

@test "pace: early in the week the cap is small, by the reset it is the full 65%" {
    usage "$T/main/plan-usage.json" 60 7 $((7 * DAY - DAY * 7 / 10))   # 10% of the week gone
    run main_account_verdict
    [ "$output" = "hold 7d 7% at or past its cap 6.5%" ]
    usage "$T/main/plan-usage.json" 60 64 60                           # a minute to the reset
    run main_account_verdict
    [[ "$output" == "ok 7d 64% of a 65% cap"* ]]
}

@test "the 5-hour cap holds too" {
    usage "$T/main/plan-usage.json" 60 10 $((2 * DAY)) 60
    run main_account_verdict
    [ "$output" = "hold 5h 60% at or past its cap 60%" ]
}

@test "a guard that is off or missing holds every launch" {
    usage "$T/main/plan-usage.json" 60 1 $((2 * DAY))
    guard '{ "enabled": false }'
    run main_account_verdict
    [[ "$output" == hold* ]]
    rm "$T/main/budget-guard.json"
    run main_account_verdict
    [[ "$output" == hold* ]]
}

@test "a stale reading is refreshed by one probe before it is used" {
    usage "$T/main/plan-usage.json" 7200 1 $((2 * DAY))
    usage "$T/fresh.json" 5 30 $((2 * DAY))
    export PROBE_WRITES="$T/fresh.json"
    run main_account_may_launch test
    [ "$status" -eq 0 ]
    [[ "$output" == *"launching on main (7d 30% of a 46.4% cap"* ]]
    [ "$(grep -c probe "$T/argv")" -eq 1 ]
}

@test "a fresh reading needs no probe" {
    usage "$T/main/plan-usage.json" 5 1 $((2 * DAY))
    run main_account_may_launch test
    [ "$status" -eq 0 ]
    [ "$(grep -c probe "$T/argv")" -eq 0 ]
}

@test "no reading even after the probe: held, never taken as room" {
    run main_account_may_launch test
    [ "$status" -eq 1 ]
    [[ "$output" == *"no current plan-usage.json after a probe"* ]]
}

@test "off unless the owner's flag says on" {
    usage "$T/main/plan-usage.json" 5 1 $((2 * DAY))
    echo "ARCHON_MAIN_ACCOUNT=off" > "$MAIN_ACCOUNT_FLAG"
    run main_account_may_launch test
    [ "$status" -eq 1 ]
    rm "$MAIN_ACCOUNT_FLAG"
    run main_account_may_launch test
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# ── with the factory held ────────────────────────────────────────────────────

hold_factory() {
    export ARCHON_DB="$T/archon.db"
    local spec; spec=$(TZ=Europe/London date -d '+2 hours' '+%-I%P')
    sqlite3 "$ARCHON_DB" "CREATE TABLE remote_agent_workflow_events (id INTEGER PRIMARY KEY,
        workflow_run_id TEXT, event_type TEXT, data TEXT, created_at TEXT DEFAULT (datetime('now')));
      INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, data)
        VALUES ('r1', 'node_failed', '{\"error\":\"You have hit your weekly limit · resets $spec (Europe/London)\"}');"
}

@test "quota: held factory, main within its pace — the launch goes ahead on main" {
    hold_factory
    usage "$T/main/plan-usage.json" 5 1 $((2 * DAY))
    source "$LIB/ship-breaker.sh"; source "$LIB/quota-pause.sh"
    quota_launch_account test >/dev/null
    [ "$QUOTA_ACCOUNT" = main ]
    run quota_may_launch test
    [ "$status" -eq 0 ]
}

@test "quota: held factory, main past its pace — held as before" {
    hold_factory
    usage "$T/main/plan-usage.json" 5 64 $((2 * DAY))
    source "$LIB/ship-breaker.sh"; source "$LIB/quota-pause.sh"
    run quota_may_launch test
    [ "$status" -eq 1 ]
    [[ "$output" == *"rate limit in effect until"* ]]
}

@test "quota: factory not held — factory, main never asked" {
    export ARCHON_DB="$T/missing.db"
    source "$LIB/ship-breaker.sh"; source "$LIB/quota-pause.sh"
    quota_launch_account test
    [ "$QUOTA_ACCOUNT" = factory ]
    [ "$(grep -c probe "$T/argv")" -eq 0 ]
}

@test "shim: held factory and main within pace — the wrapper gets --account main" {
    hold_factory
    usage "$T/main/plan-usage.json" 5 1 $((2 * DAY))
    ARCHON_RUN_AS=archon run "$SHIM" workflow run archon-ship "fix #12"
    [ "$status" -eq 0 ]
    grep -q "^sudo -n -u archon /usr/local/bin/archon-as-archon --account main workflow run archon-ship fix #12$" "$T/argv"
}

@test "shim: held factory and main past pace — refused" {
    hold_factory
    usage "$T/main/plan-usage.json" 5 64 $((2 * DAY))
    ARCHON_RUN_AS=archon run "$SHIM" workflow run archon-ship "fix #12"
    [ "$status" -eq 75 ]
    ! grep -q archon-as-archon "$T/argv"
}

@test "shim: factory not held — the argv reaches the wrapper untouched" {
    export ARCHON_DB="$T/missing.db"
    ARCHON_RUN_AS=archon run "$SHIM" workflow run archon-ship "fix #12"
    [ "$status" -eq 0 ]
    grep -q "^sudo -n -u archon /usr/local/bin/archon-as-archon workflow run archon-ship fix #12$" "$T/argv"
}
