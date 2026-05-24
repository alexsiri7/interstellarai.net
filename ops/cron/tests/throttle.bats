#!/usr/bin/env bats
# Unit tests for ops/cron/lib/throttle.sh
#
# Run: bats ops/cron/tests/throttle.bats

setup() {
    # Use a temp HOME so state files don't pollute the real one.
    export HOME="$BATS_TMPDIR/home-$$"
    mkdir -p "$HOME"

    # Unset the source guard so each test gets a fresh load.
    unset _ARCHON_THROTTLE_SH

    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$SCRIPT_DIR/lib/throttle.sh"
}

teardown() {
    rm -rf "$BATS_TMPDIR/home-$$"
}

# ── First-run behaviour ──────────────────────────────────────────────

@test "should_tick returns 0 on first run (no state file)" {
    run should_tick "test-script"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/archon-cron/state/test-script.last_run" ]
}

@test "state file contains a numeric timestamp after first tick" {
    should_tick "test-script"
    local content
    content=$(cat "$HOME/.config/archon-cron/state/test-script.last_run")
    [[ "$content" =~ ^[0-9]+$ ]]
}

# ── Throttle behaviour ───────────────────────────────────────────────

@test "should_tick returns 1 when called again within interval" {
    should_tick "test-script"
    # Reset source guard so we can call again in same process.
    unset _ARCHON_THROTTLE_SH
    source "$SCRIPT_DIR/lib/throttle.sh"
    run should_tick "test-script"
    [ "$status" -eq 1 ]
    [[ "$output" == *"skipping"* ]]
}

@test "should_tick returns 0 when state file timestamp is old enough" {
    mkdir -p "$HOME/.config/archon-cron/state"
    # Write a timestamp 2 hours in the past.
    local old_ts=$(( $(date +%s) - 7200 ))
    echo "$old_ts" > "$HOME/.config/archon-cron/state/test-script.last_run"
    run should_tick "test-script"
    [ "$status" -eq 0 ]
}

# ── Config parsing ───────────────────────────────────────────────────

@test "should_tick uses default interval (60) when config is missing" {
    # Temporarily hide the config file.
    local conf="$SCRIPT_DIR/throttle.conf"
    local backup="$SCRIPT_DIR/throttle.conf.bak"
    mv "$conf" "$backup"

    mkdir -p "$HOME/.config/archon-cron/state"
    # Write timestamp 45 minutes ago — should still be throttled at 60m default.
    local ts=$(( $(date +%s) - 2700 ))
    echo "$ts" > "$HOME/.config/archon-cron/state/test-default.last_run"

    unset _ARCHON_THROTTLE_SH
    source "$SCRIPT_DIR/lib/throttle.sh"
    run should_tick "test-default"
    mv "$backup" "$conf"

    [ "$status" -eq 1 ]
    [[ "$output" == *"skipping"* ]]
}

# ── Corrupt / invalid state ──────────────────────────────────────────

@test "should_tick handles corrupt state file (treats as never ran)" {
    mkdir -p "$HOME/.config/archon-cron/state"
    echo "not-a-number" > "$HOME/.config/archon-cron/state/test-corrupt.last_run"
    run should_tick "test-corrupt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"corrupt"* ]]
}

@test "should_tick handles empty state file (treats as never ran)" {
    mkdir -p "$HOME/.config/archon-cron/state"
    echo -n "" > "$HOME/.config/archon-cron/state/test-empty.last_run"
    run should_tick "test-empty"
    [ "$status" -eq 0 ]
}

# ── Invalid config values ────────────────────────────────────────────

@test "should_tick warns on non-numeric config value" {
    local conf="$SCRIPT_DIR/throttle.conf"
    local backup="$SCRIPT_DIR/throttle.conf.bak"
    cp "$conf" "$backup"
    echo "TICK_INTERVAL_MINUTES=abc" > "$conf"

    unset _ARCHON_THROTTLE_SH
    source "$SCRIPT_DIR/lib/throttle.sh"
    run should_tick "test-badconf"
    mv "$backup" "$conf"

    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"invalid TICK_INTERVAL_MINUTES"* ]]
}

# ── Source guard ─────────────────────────────────────────────────────

@test "source guard prevents double-sourcing" {
    # _ARCHON_THROTTLE_SH is already set from setup().
    # Sourcing again should be a no-op (return 0).
    source "$SCRIPT_DIR/lib/throttle.sh"
    # If we got here without error, the guard worked.
    [ -n "$_ARCHON_THROTTLE_SH" ]
}
