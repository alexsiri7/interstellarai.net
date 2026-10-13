#!/usr/bin/env bats
# Unit tests for check_doppler_token in ops/cron/pipeline-health-cron.sh
# (#175): one ntfy per episode when the Doppler token lib/secrets.sh uses is
# missing, readable by others or rejected; the reason only, never the token.
#
# Run: bunx bats ops/cron/tests/pipeline-health-doppler.bats

load doppler-stub

setup() {
    export T="$BATS_TMPDIR/ph-doppler-$$"
    rm -rf "$T"; mkdir -p "$T/state" "$T/bin"
    export STATE_DIR="$T/state"
    export NTFY_OUT="$T/ntfy"
    export NOTIFY_RC=0
    doppler_stub "$T/bin"
    export PATH="$T/bin:$PATH"
    export DOPPLER_STUB_JSON="$T/doppler.json" DOPPLER_STUB_ARGV="$T/argv"
    echo '{"NTFY_TOPIC":"t"}' > "$DOPPLER_STUB_JSON"
    echo 'dp.st.fake' > "$T/doppler.token"; chmod 600 "$T/doppler.token"
    export ARCHON_CRON_DOPPLER_TOKEN="$T/doppler.token"
    unset DOPPLER_STUB_FAIL

    log() { echo "$*"; }
    notify_checked() { echo "$1 | $2" >> "$NTFY_OUT"; return "$NOTIFY_RC"; }

    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    # shellcheck source=../lib/secrets.sh
    source "$CRON_DIR/lib/secrets.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_doppler_token\(\)/{p=1} p{print} p && /^}$/{p=0}' "$CRON_DIR/pipeline-health-cron.sh")
}

teardown() { rm -rf "$T"; }

ntfys() { [ -f "$NTFY_OUT" ] && wc -l < "$NTFY_OUT" || echo 0; }

@test "a working token: no ntfy, no marker" {
    run check_doppler_token
    [ "$status" -eq 0 ]
    [ "$(ntfys)" -eq 0 ]
    [ ! -e "$STATE_DIR/doppler-alerted" ]
}

@test "working again after an alert: marker removed, recovered logged" {
    touch "$STATE_DIR/doppler-alerted"
    run check_doppler_token
    [[ "$output" == *"doppler: recovered"* ]]
    [ ! -e "$STATE_DIR/doppler-alerted" ]
    [ "$(ntfys)" -eq 0 ]
}

@test "a missing token alerts once across two runs" {
    rm "$T/doppler.token"
    run check_doppler_token
    run check_doppler_token
    [[ "$output" == *"missing or unreadable"* ]]
    [ "$(ntfys)" -eq 1 ]
    grep -q '^Doppler token unusable | token file .*missing or unreadable' "$NTFY_OUT"
    [ ! -e "$T/argv" ]
}

@test "a rejected token: the ntfy names the reason, never the token" {
    export DOPPLER_STUB_FAIL=1
    run check_doppler_token
    [ "$(ntfys)" -eq 1 ]
    grep -q 'Invalid Auth token' "$NTFY_OUT"
    [ -z "$(grep dp.st.fake "$NTFY_OUT")" ]
    [[ "$output" != *dp.st.fake* ]]
}

@test "a token file others can read alerts with its mode, without calling Doppler" {
    chmod 644 "$T/doppler.token"
    run check_doppler_token
    [ "$(ntfys)" -eq 1 ]
    grep -q 'mode 644 (want 600)' "$NTFY_OUT"
    [ ! -e "$T/argv" ]
}

@test "an undelivered ntfy writes no marker, so the next tick retries" {
    rm "$T/doppler.token"
    export NOTIFY_RC=1
    run check_doppler_token
    [ "$status" -eq 0 ]
    [ ! -e "$STATE_DIR/doppler-alerted" ]
    export NOTIFY_RC=0
    run check_doppler_token
    [ "$(ntfys)" -eq 2 ]
    [ -e "$STATE_DIR/doppler-alerted" ]
}

@test "no token file configured (bats default): silent" {
    unset ARCHON_CRON_DOPPLER_TOKEN
    run check_doppler_token
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(ntfys)" -eq 0 ]
}
