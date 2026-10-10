#!/usr/bin/env bats
# Unit tests for ops/cron/lib/heartbeat.sh
#
# Run: bats ops/cron/tests/heartbeat.bats

setup() {
    T="$BATS_TMPDIR/heartbeat-$$"
    mkdir -p "$T"
    export HOME="$T/home"
    export HEARTBEAT_STAMP_DIR="$T/stamps"
    export HEARTBEAT_STATE_DIR="$T/state"
    export ARCHON_THROTTLE_CONF="$T/throttle.conf"
    mkdir -p "$HOME" "$HEARTBEAT_STAMP_DIR"
    echo "TICK_INTERVAL_MINUTES=59" > "$ARCHON_THROTTLE_CONF"
    export NTFY_TOPIC="test-topic"
    export CURL_ARGV="$T/curl-argv"
    curl() { printf '%s\n' "$*" >> "$CURL_ARGV"; return "${CURL_RC:-0}"; }
    export -f curl

    unset _ARCHON_THROTTLE_SH _ARCHON_HEARTBEAT_SH
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$SCRIPT_DIR/lib/heartbeat.sh"
}

teardown() {
    rm -rf "$T"
}

# stamp <name> <age in seconds>
stamp() { echo $(( $(date +%s) - $2 )) > "$HEARTBEAT_STAMP_DIR/$1.last_run"; }

curl_calls() { [ -f "$CURL_ARGV" ] && wc -l < "$CURL_ARGV" || echo 0; }

# ── expected cadence ─────────────────────────────────────────────────

@test "expected minutes follow the throttle: T=59 gives 60 for 15- and 30-minute crons" {
    [ "$(heartbeat_expected_minutes 15)" = 60 ]
    [ "$(heartbeat_expected_minutes 30)" = 60 ]
}

@test "expected minutes: T=14 on a 15-minute cron is every slot; T=60 on 30 is 60" {
    echo "TICK_INTERVAL_MINUTES=14" > "$ARCHON_THROTTLE_CONF"
    [ "$(heartbeat_expected_minutes 15)" = 15 ]
    echo "TICK_INTERVAL_MINUTES=60" > "$ARCHON_THROTTLE_CONF"
    [ "$(heartbeat_expected_minutes 30)" = 60 ]
}

@test "expected minutes use the 60-minute default when the conf is missing" {
    export ARCHON_THROTTLE_CONF="$T/nonexistent.conf"
    [ "$(heartbeat_expected_minutes 15)" = 60 ]
}

# ── staleness ────────────────────────────────────────────────────────

@test "a fresh stamp raises nothing" {
    stamp issue-pickup $(( 30 * 60 ))
    run heartbeat_watch issue-pickup 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 0 ]
    [ ! -f "$HEARTBEAT_STATE_DIR/issue-pickup-alerted" ]
}

@test "one missed tick is not enough to alert" {
    # T=59, P=15: E=60, limit 2E+P = 135 min.
    stamp pr-maintenance $(( 135 * 60 - 60 ))
    run heartbeat_watch pr-maintenance 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 0 ]
    [ ! -f "$HEARTBEAT_STATE_DIR/pr-maintenance-alerted" ]
}

@test "two missed ticks alert once, naming the cron" {
    stamp pr-maintenance $(( 135 * 60 + 60 ))
    run heartbeat_watch pr-maintenance 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 1 ]
    grep -q "Factory cron silent: pr-maintenance" "$CURL_ARGV"
    grep -q "ntfy.sh/test-topic" "$CURL_ARGV"
    [ -f "$HEARTBEAT_STATE_DIR/pr-maintenance-alerted" ]

    run heartbeat_watch pr-maintenance 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 1 ]
}

@test "a missing stamp alerts as never ticked" {
    run heartbeat_watch pipeline-health 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"pipeline-health has never ticked"* ]]
    [ "$(curl_calls)" -eq 1 ]
    [ -f "$HEARTBEAT_STATE_DIR/pipeline-health-alerted" ]
}

@test "a failed ntfy leaves no marker and is retried on the next watch" {
    stamp issue-pickup $(( 4 * 3600 ))
    CURL_RC=22 run heartbeat_watch issue-pickup 15
    [ "$status" -eq 0 ]
    [[ "$output" == *"ntfy failed, retrying next tick"* ]]
    [ ! -f "$HEARTBEAT_STATE_DIR/issue-pickup-alerted" ]

    run heartbeat_watch issue-pickup 15
    [ "$(curl_calls)" -eq 2 ]
    [ -f "$HEARTBEAT_STATE_DIR/issue-pickup-alerted" ]
}

@test "a cron that ticks again clears the marker and logs recovered" {
    mkdir -p "$HEARTBEAT_STATE_DIR"
    touch "$HEARTBEAT_STATE_DIR/issue-pickup-alerted"
    stamp issue-pickup 120
    run heartbeat_watch issue-pickup 15
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue-pickup recovered"* ]]
    [ ! -f "$HEARTBEAT_STATE_DIR/issue-pickup-alerted" ]
    [ "$(curl_calls)" -eq 0 ]
}

@test "without NTFY_TOPIC the alert is logged only and marked" {
    export NTFY_TOPIC=""
    run heartbeat_watch pr-maintenance 15
    [ "$status" -eq 0 ]
    [[ "$output" == *"NTFY_TOPIC not set — logged only"* ]]
    [ "$(curl_calls)" -eq 0 ]
    [ -f "$HEARTBEAT_STATE_DIR/pr-maintenance-alerted" ]
}
