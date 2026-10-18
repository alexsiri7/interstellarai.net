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

# ── the next_issue read streak ───────────────────────────────────────────────

@test "lachesis_next_record counts failures in a row and a read resets them" {
    [ "$LACHESIS_NEXT_STATUS" = "$T/state/next-issue-status" ]
    lachesis_next_record failed
    lachesis_next_record failed
    [ "$(lachesis_next_status_get failures)" = 2 ]
    [ "$(lachesis_next_status_get last_ok)" = 0 ]
    [ "$(lachesis_next_status_get last_failed)" -gt 0 ]
    lachesis_next_record ok
    [ "$(lachesis_next_status_get failures)" = 0 ]
    [ "$(lachesis_next_status_get last_ok)" -gt 0 ]
}

@test "lachesis_next_failing: three failed ticks in a row are a failure, two are not" {
    run ! lachesis_next_failing
    lachesis_next_record ok
    lachesis_next_record failed
    lachesis_next_record failed
    run ! lachesis_next_failing
    lachesis_next_record failed
    lachesis_next_failing
    [[ "$LACHESIS_NEXT_PROBLEM" == "Lachesis next_issue could not be read on 3 issue-pickup ticks in a row (last read: $(date +%F) "* ]]
    lachesis_next_record ok
    run ! lachesis_next_failing
}

@test "lachesis_next_failing names a streak with no read ever recorded" {
    mkdir -p "$(dirname "$LACHESIS_NEXT_STATUS")"
    printf 'failures=5\n' > "$LACHESIS_NEXT_STATUS"
    lachesis_next_failing
    [[ "$LACHESIS_NEXT_PROBLEM" == *"on 5 issue-pickup ticks in a row (last read: never recorded)" ]]
}

@test "lachesis_next_record never fails the tick when the status cannot be written" {
    LACHESIS_NEXT_STATUS=/proc/nope/next-issue-status
    lachesis_next_record failed
}

# ── check_lachesis_next_issue (pipeline-health-cron.sh) ──────────────────────

load_check() {
    STATE_DIR="$T/ph-state"
    mkdir -p "$STATE_DIR"
    LOG_DIR="$T/logs"
    export NTFY_SENT="$T/ntfy"
    log() { echo "$*"; }
    notify_checked() { echo "$1 | $2 | $3" >> "$NTFY_SENT"; return "${STUB_NTFY_RC:-0}"; }
    # shellcheck disable=SC1090
    source <(awk '/^check_lachesis_next_issue\(\)/{p=1} p{print} p && /^}$/{p=0}' "$LIB/../pipeline-health-cron.sh")
}

@test "check_lachesis_next_issue: a failing streak alerts once per episode, a read clears it" {
    load_check
    lachesis_next_record failed
    lachesis_next_record failed
    run check_lachesis_next_issue
    [ ! -e "$NTFY_SENT" ]
    lachesis_next_record failed
    run check_lachesis_next_issue
    [ "$(wc -l < "$NTFY_SENT")" -eq 1 ]
    grep -q '^Factory issue pickup failing | Lachesis next_issue could not be read on 3 issue-pickup ticks in a row' "$NTFY_SENT"
    grep -q '| high$' "$NTFY_SENT"
    lachesis_next_record failed
    run check_lachesis_next_issue
    [[ "$output" == *"on 4 issue-pickup ticks in a row"* ]]
    [ "$(wc -l < "$NTFY_SENT")" -eq 1 ]       # the marker holds the repeat

    lachesis_next_record ok
    run check_lachesis_next_issue
    [[ "$output" == *"lachesis-next-issue: recovered"* ]]
    [ ! -f "$STATE_DIR/lachesis-next-issue-alerted" ]

    lachesis_next_record failed; lachesis_next_record failed; lachesis_next_record failed
    run check_lachesis_next_issue
    [ "$(wc -l < "$NTFY_SENT")" -eq 2 ]       # a new episode alerts again
}

@test "check_lachesis_next_issue: an undelivered ntfy is retried next tick" {
    load_check
    lachesis_next_record failed; lachesis_next_record failed; lachesis_next_record failed
    export STUB_NTFY_RC=1
    run check_lachesis_next_issue
    [ ! -f "$STATE_DIR/lachesis-next-issue-alerted" ]
    [[ "$output" == *"ntfy not delivered"* ]]
}

@test "check_lachesis_next_issue: no record yet is quiet" {
    load_check
    run check_lachesis_next_issue
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$NTFY_SENT" ]
}
