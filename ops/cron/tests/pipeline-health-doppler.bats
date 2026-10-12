#!/usr/bin/env bats
# Tests for check_doppler_token in ops/cron/pipeline-health-cron.sh, run
# against the real lib/secrets.sh and a stubbed doppler: one ntfy per episode
# when Doppler cannot be read, recovery logged once it reads again, silence
# when Doppler was not tried.
#
# Run: bunx bats ops/cron/tests/pipeline-health-doppler.bats

load doppler-stub

setup() {
    export T="$BATS_TEST_TMPDIR"
    export HOME="$T/home"
    mkdir -p "$HOME"
    export STATE_DIR="$T/state"
    mkdir -p "$STATE_DIR"
    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"
    export PATH="$T/bin:$PATH"
    doppler_stub "$T/bin" '{"NTFY_TOPIC":"t-1"}'
    NTFY_RC=0

    log() { echo "$*"; }
    notify_checked() { echo "$1 | $2" >> "$NTFY_SENTINEL"; return "$NTFY_RC"; }

    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    # shellcheck source=../lib/secrets.sh
    source "$CRON_DIR/lib/secrets.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_doppler_token\(\)/{p=1} p{print} p && /^}$/{p=0}' "$CRON_DIR/pipeline-health-cron.sh")
}

ntfys() { cat "$NTFY_SENTINEL" 2>/dev/null | grep -c . || true; }

@test "token missing: one ntfy naming the file, then quiet while it stays missing" {
    rm -f "$ARCHON_CRON_DOPPLER_TOKEN"
    run check_doppler_token
    [ "$(ntfys)" -eq 1 ]
    grep -q "^Doppler token | Doppler token missing: $ARCHON_CRON_DOPPLER_TOKEN" "$NTFY_SENTINEL"
    grep -q 'doppler secrets --only-names' "$NTFY_SENTINEL"
    [ -f "$STATE_DIR/doppler-alerted" ]
    run check_doppler_token
    [[ "$output" == *"doppler: Doppler token missing"* ]]
    [ "$(ntfys)" -eq 1 ]
}

@test "token rejected or Doppler unreachable alerts" {
    export STUB_DOPPLER_FAIL=1
    run check_doppler_token
    [ "$(ntfys)" -eq 1 ]
    grep -q 'refused the token or is unreachable' "$NTFY_SENTINEL"
}

@test "probes Doppler itself, not an earlier secrets_load's outcome" {
    secrets_load NTFY_TOPIC
    [ "$SECRETS_DOPPLER_RC" -eq 0 ]
    export STUB_DOPPLER_FAIL=1
    run check_doppler_token
    [ "$(ntfys)" -eq 1 ]
    [ "$(doppler_calls)" -eq 2 ]
}

@test "an undelivered ntfy leaves no marker, so the next tick retries" {
    export STUB_DOPPLER_FAIL=1
    NTFY_RC=22
    run check_doppler_token
    [ ! -f "$STATE_DIR/doppler-alerted" ]
    NTFY_RC=0
    run check_doppler_token
    [ "$(ntfys)" -eq 2 ]
    [ -f "$STATE_DIR/doppler-alerted" ]
}

@test "Doppler reads again: marker cleared, recovery logged once" {
    touch "$STATE_DIR/doppler-alerted"
    run check_doppler_token
    [[ "$output" == *"doppler: recovered"* ]]
    [ ! -f "$STATE_DIR/doppler-alerted" ]
    run check_doppler_token
    [ -z "$output" ]
    [ "$(ntfys)" -eq 0 ]
}

@test "not tried (bats guard): no ntfy, no marker" {
    unset ARCHON_CRON_DOPPLER_TOKEN
    run check_doppler_token
    [ -z "$output" ]
    [ "$(ntfys)" -eq 0 ]
    [ ! -f "$STATE_DIR/doppler-alerted" ]
    [ "$(doppler_calls)" -eq 0 ]
}
