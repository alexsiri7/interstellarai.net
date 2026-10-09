#!/usr/bin/env bats
# Tests for lib/lachesis.sh (the owner's Lachesis switches and the factory's
# one MCP call) and lib/lachesis_call.py.
#
# Run: bunx bats ops/cron/tests/lachesis.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../lib" && pwd)"
    mkdir -p "$T/bin" "$T/home/.config/archon-cron"
    export HOME="$T/home"
    export LACHESIS_PICKUP_FLAG="$T/home/.config/archon-cron/lachesis-pickup"
    export LACHESIS_STATE_DIR="$T/state"
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    cat > "$T/bin/lachesis" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${2:-}" >> "$LACHESIS_ARGV"
exit "${LACHESIS_RC:-0}"
STUB
    chmod +x "$T/bin/lachesis"
    export LACHESIS_ARGV="$T/lachesis-argv"
    : > "$LACHESIS_ARGV"
    unset _LACHESIS_SH LACHESIS_FLAG_TEST LACHESIS_CALL_CMD LACHESIS_FACTORY_TOKEN
    source "$LIB/lachesis.sh"
}

# ── the switch ───────────────────────────────────────────────────────────────

@test "pickup is off with no flag file" {
    export LACHESIS_FLAG_TEST=1
    run ! lachesis_pickup_enabled
}

@test "pickup is on only when the flag file's last line says on" {
    export LACHESIS_FLAG_TEST=1
    echo 'LACHESIS_PICKUP=on' > "$LACHESIS_PICKUP_FLAG"
    lachesis_pickup_enabled
    printf 'LACHESIS_PICKUP=on\nLACHESIS_PICKUP=off\n' > "$LACHESIS_PICKUP_FLAG"
    run ! lachesis_pickup_enabled
    echo 'LACHESIS_PICKUP="on"  # owner, 2026-10-09' > "$LACHESIS_PICKUP_FLAG"
    lachesis_pickup_enabled
    echo 'LACHESIS_PICKUP=yes' > "$LACHESIS_PICKUP_FLAG"
    run ! lachesis_pickup_enabled
}

@test "under bats the host's flag is ignored unless the test asks for it" {
    echo 'LACHESIS_PICKUP=on' > "$LACHESIS_PICKUP_FLAG"
    run ! lachesis_pickup_enabled
}

# ── the call ─────────────────────────────────────────────────────────────────

@test "lachesis_token reads only LACHESIS_FACTORY_TOKEN from secrets.env" {
    printf 'NTFY_TOPIC=x\nexport LACHESIS_FACTORY_TOKEN="tok-123"\nRELI_DB_URL=postgres://secret\n' > "$ARCHON_CRON_SECRETS"
    [ "$(lachesis_token)" = tok-123 ]
    # shellcheck disable=SC2034  # read by lachesis_token
    LACHESIS_FACTORY_TOKEN=env-tok
    [ "$(lachesis_token)" = env-tok ]
}

@test "lachesis_call.py without a token exits 2 and calls nothing" {
    run env -u LACHESIS_FACTORY_TOKEN python3 -B "$LIB/lachesis_call.py" next_issue '{}'
    [ "$status" -eq 2 ]
    [[ "$output" == *"LACHESIS_FACTORY_TOKEN is not set"* ]]
}

@test "lachesis_call.py refuses arguments that are not JSON" {
    LACHESIS_FACTORY_TOKEN=x run python3 -B "$LIB/lachesis_call.py" next_issue '{nope'
    [ "$status" -eq 2 ]
    [[ "$output" == *"not JSON"* ]]
}

@test "lachesis_call.py exits 2 when Lachesis cannot be reached" {
    LACHESIS_FACTORY_TOKEN=x LACHESIS_URL=http://127.0.0.1:9/mcp \
        run python3 -B "$LIB/lachesis_call.py" next_issue '{}'
    [ "$status" -eq 2 ]
    [[ "$output" == *"next_issue failed"* ]]
}

# ── questions ────────────────────────────────────────────────────────────────

@test "lachesis_ask records a clarification question blocking the issue" {
    export LACHESIS_CALL_CMD="$T/bin/lachesis"
    lachesis_ask testproj 12 'Why "this"?' 'some context'
    run jq -c . <<<"$(sed -E 's/^ask_question //' "$LACHESIS_ARGV")"
    [ "$output" = '{"repo":"alexsiri7/testproj","question":"Why \"this\"?","kind":"clarification","asker":"factory","blocks":[12],"issue":12,"context":"some context"}' ]
}

@test "lachesis_ask_once asks once per issue and key, and again after a failure" {
    export LACHESIS_CALL_CMD="$T/bin/lachesis"
    LACHESIS_RC=1 run lachesis_ask_once testproj 12 k 'q?'
    [ "$status" -ne 0 ]
    lachesis_ask_once testproj 12 k 'q?'
    lachesis_ask_once testproj 12 k 'q?'
    lachesis_ask_once testproj 12 other 'q?'
    [ "$(grep -c '^ask_question' "$LACHESIS_ARGV")" -eq 3 ]
}
