#!/usr/bin/env bats
# Tests for lib/secrets.sh: Doppler first, secrets.env one key at a time as
# fallback, nothing exported, nothing printed, and the outcome of the Doppler
# read in SECRETS_DOPPLER_RC for pipeline-health's check_doppler_token.
#
# Run: bunx bats ops/cron/tests/secrets.bats

bats_require_minimum_version 1.5.0

load doppler-stub

setup() {
    export T="$BATS_TEST_TMPDIR"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export HOME="$T/home"
    mkdir -p "$HOME"
    export PATH="$T/bin:$PATH"
    doppler_stub "$T/bin" '{"NTFY_TOPIC":"topic-from-doppler","RELI_DB_URL":"postgresql://reli:pw-doppler@db.example/postgres","UNASKED_TOKEN":"tok-unasked"}'
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    printf '%s\n' 'NTFY_TOPIC=topic-from-file' \
        'export ANNIE_DB_URL="postgresql://annie:pw-file@db.example/postgres"' > "$ARCHON_CRON_SECRETS"
    unset NTFY_TOPIC RELI_DB_URL ANNIE_DB_URL UNASKED_TOKEN
    # shellcheck source=../lib/secrets.sh
    source "$CRON_DIR/lib/secrets.sh"
}

@test "Doppler wins, a key only in the file falls back, a key in neither keeps its value" {
    CLAUDE_ACCOUNTS="/preset/a:/preset/b"
    secrets_load NTFY_TOPIC ANNIE_DB_URL CLAUDE_ACCOUNTS
    [ "$NTFY_TOPIC" = topic-from-doppler ]
    [ "$ANNIE_DB_URL" = "postgresql://annie:pw-file@db.example/postgres" ]
    [ "$CLAUDE_ACCOUNTS" = "/preset/a:/preset/b" ]
    [ "$SECRETS_DOPPLER_RC" -eq 0 ]
}

@test "one doppler call for all names, a full download with the token as a prefix" {
    secrets_load NTFY_TOPIC RELI_DB_URL ANNIE_DB_URL
    [ "$(doppler_calls)" -eq 1 ]
    grep -q '^secrets download --no-file --format json .*token=set$' "$DOPPLER_STUB_LOG"
    run ! grep -q 'fake-token' "$DOPPLER_STUB_LOG"
}

@test "nothing loaded is exported, and the token never reaches a child" {
    secrets_load NTFY_TOPIC RELI_DB_URL ANNIE_DB_URL
    [ -n "$RELI_DB_URL" ]
    run bash -c env
    [[ "$output" != *pw-doppler* ]]
    [[ "$output" != *pw-file* ]]
    [[ "$output" != *topic-from* ]]
    [[ "$output" != *fake-token* ]]
    run ! grep -q '^DOPPLER_TOKEN=' <<<"$output"
}

@test "token file missing: rc 1, the file is the fallback, nothing printed" {
    rm -f "$ARCHON_CRON_DOPPLER_TOKEN"
    run secrets_load NTFY_TOPIC
    [ -z "$output" ]
    secrets_load NTFY_TOPIC
    [ "$SECRETS_DOPPLER_RC" -eq 1 ]
    [ "$NTFY_TOPIC" = topic-from-file ]
    [ "$(doppler_calls)" -eq 0 ]
}

@test "doppler fails: rc 2, the file is the fallback, nothing printed" {
    export STUB_DOPPLER_FAIL=1
    run secrets_load NTFY_TOPIC
    [ -z "$output" ]
    secrets_load NTFY_TOPIC
    [ "$SECRETS_DOPPLER_RC" -eq 2 ]
    [ "$NTFY_TOPIC" = topic-from-file ]
}

@test "doppler CLI missing: rc 2" {
    rm -f "$T/bin/doppler"
    PATH="$T/bin:/usr/bin:/bin" secrets_load NTFY_TOPIC
    [ "$SECRETS_DOPPLER_RC" -eq 2 ]
    [ "$NTFY_TOPIC" = topic-from-file ]
}

@test "under bats the host's token is ignored unless the test names one" {
    mkdir -p "$HOME/.config/archon-cron"
    mv "$ARCHON_CRON_DOPPLER_TOKEN" "$HOME/.config/archon-cron/doppler.token"
    unset ARCHON_CRON_DOPPLER_TOKEN
    secrets_load NTFY_TOPIC
    [ "$SECRETS_DOPPLER_RC" -eq 3 ]
    [ "$(doppler_calls)" -eq 0 ]
    [ "$NTFY_TOPIC" = topic-from-file ]
}

@test "secrets_get prints the one value asked for and sets nothing" {
    run secrets_get RELI_DB_URL
    [ "$output" = "postgresql://reli:pw-doppler@db.example/postgres" ]
    run secrets_get ANNIE_DB_URL
    [ "$output" = "postgresql://annie:pw-file@db.example/postgres" ]
    run secrets_get UNSET_ANYWHERE
    [ -z "$output" ]
    [ "$status" -eq 0 ]
    secrets_get NTFY_TOPIC >/dev/null
    [ -z "${NTFY_TOPIC:-}" ]
}

@test "only the names asked for are loaded" {
    secrets_load NTFY_TOPIC
    [ -z "${UNASKED_TOKEN:-}" ]
    [ -z "${RELI_DB_URL:-}" ]
}

@test "safe under set -euo pipefail when nothing resolves" {
    run bash -euo pipefail -c '
        source "$1"
        secrets_load NOT_IN_DOPPLER NOT_IN_FILE
        echo "reached rc=$SECRETS_DOPPLER_RC"' _ "$CRON_DIR/lib/secrets.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "reached rc=0" ]
    rm -f "$ARCHON_CRON_SECRETS"
    STUB_DOPPLER_FAIL=1 run bash -euo pipefail -c '
        source "$1"
        secrets_load NTFY_TOPIC
        echo "reached rc=$SECRETS_DOPPLER_RC"' _ "$CRON_DIR/lib/secrets.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "reached rc=2" ]
}

@test "lib/secrets.sh and doppler-push.sh pass shellcheck" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    cd "$CRON_DIR"
    run shellcheck -x lib/secrets.sh doppler-push.sh
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
