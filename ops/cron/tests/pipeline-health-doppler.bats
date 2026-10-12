#!/usr/bin/env bats
# Unit tests for check_doppler_token in ops/cron/pipeline-health-cron.sh:
# one ntfy per episode when lib/secrets.sh could not read Doppler, recovery
# logged once it reads again, silence when Doppler was not tried.
#
# Run: bunx bats ops/cron/tests/pipeline-health-doppler.bats

setup() {
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$STATE_DIR"
    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"
    export ARCHON_CRON_DOPPLER_TOKEN="$BATS_TEST_TMPDIR/doppler.token"
    NTFY_RC=0

    log() { echo "$*"; }
    notify_checked() { echo "$1 | $2" >> "$NTFY_SENTINEL"; return "$NTFY_RC"; }

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_doppler_token\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

ntfys() { cat "$NTFY_SENTINEL" 2>/dev/null | grep -c . || true; }

@test "token missing: one ntfy naming the file, then quiet while it stays missing" {
    SECRETS_DOPPLER_RC=1
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
    SECRETS_DOPPLER_RC=2
    run check_doppler_token
    [ "$(ntfys)" -eq 1 ]
    grep -q 'refused the token or is unreachable' "$NTFY_SENTINEL"
}

@test "an undelivered ntfy leaves no marker, so the next tick retries" {
    SECRETS_DOPPLER_RC=2 NTFY_RC=22
    run check_doppler_token
    [ ! -f "$STATE_DIR/doppler-alerted" ]
    NTFY_RC=0
    run check_doppler_token
    [ "$(ntfys)" -eq 2 ]
    [ -f "$STATE_DIR/doppler-alerted" ]
}

@test "Doppler reads again: marker cleared, recovery logged once" {
    touch "$STATE_DIR/doppler-alerted"
    SECRETS_DOPPLER_RC=0
    run check_doppler_token
    [[ "$output" == *"doppler: recovered"* ]]
    [ ! -f "$STATE_DIR/doppler-alerted" ]
    run check_doppler_token
    [ -z "$output" ]
    [ "$(ntfys)" -eq 0 ]
}

@test "not tried (bats guard): no ntfy, no marker" {
    SECRETS_DOPPLER_RC=3
    run check_doppler_token
    [ -z "$output" ]
    [ "$(ntfys)" -eq 0 ]
    [ ! -f "$STATE_DIR/doppler-alerted" ]
}
