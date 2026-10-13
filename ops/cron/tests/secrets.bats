#!/usr/bin/env bats
# lib/secrets.sh (#175): named keys from Doppler factory/prd through a
# read-only service token that only the doppler process sees, secrets.env as
# the fallback, never the whole store and never an export.
#
# Run: bunx bats ops/cron/tests/secrets.bats

load doppler-stub

setup() {
    export T="$BATS_TMPDIR/secrets-$$"
    rm -rf "$T"; mkdir -p "$T/bin" "$T/home"
    export HOME="$T/home"
    doppler_stub "$T/bin"
    export PATH="$T/bin:$PATH"
    export DOPPLER_STUB_ARGV="$T/argv" DOPPLER_STUB_TOKEN_SEEN="$T/token-seen"
    export DOPPLER_STUB_JSON="$T/doppler.json"
    echo '{"NTFY_TOPIC":"topic-from-doppler","RELI_DB_URL":"postgres://secret@doppler","DOPPLER_CONFIG":"prd"}' > "$DOPPLER_STUB_JSON"
    echo 'dp.st.fake' > "$T/doppler.token"; chmod 600 "$T/doppler.token"
    export ARCHON_CRON_DOPPLER_TOKEN="$T/doppler.token"
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    : > "$ARCHON_CRON_SECRETS"
    unset DOPPLER_TOKEN DOPPLER_STUB_FAIL NTFY_TOPIC RELI_DB_URL KINDRED_DB_URL
    # shellcheck source=../lib/secrets.sh
    source "$BATS_TEST_DIRNAME/../lib/secrets.sh"
}

teardown() { rm -rf "$T"; }

@test "secrets_load: named keys from Doppler, unexported; the token reaches only doppler's env" {
    secrets_load NTFY_TOPIC RELI_DB_URL
    [ "$NTFY_TOPIC" = topic-from-doppler ]
    [ "$RELI_DB_URL" = "postgres://secret@doppler" ]
    [ -z "$(bash -c 'printf %s "${NTFY_TOPIC-}${RELI_DB_URL-}"')" ]
    [ -z "${DOPPLER_TOKEN+x}" ]
    [ "$(cat "$T/token-seen")" = dp.st.fake ]
    [ "$(cat "$T/argv")" = "secrets download --no-file --format json" ]
}

@test "secrets_load: one Doppler call for many names, and only the names asked for" {
    secrets_load NTFY_TOPIC
    [ "$NTFY_TOPIC" = topic-from-doppler ]
    [ -z "${RELI_DB_URL+x}" ]
    [ -z "${DOPPLER_CONFIG+x}" ]
    secrets_load NTFY_TOPIC RELI_DB_URL KINDRED_DB_URL
    [ "$(wc -l < "$T/argv")" -eq 2 ]
}

@test "Doppler wins over secrets.env; a name Doppler lacks comes from secrets.env, export lines too" {
    printf 'NTFY_TOPIC=topic-from-file\nexport KINDRED_DB_URL="postgres://kindred@file"\n' > "$ARCHON_CRON_SECRETS"
    secrets_load NTFY_TOPIC KINDRED_DB_URL
    [ "$NTFY_TOPIC" = topic-from-doppler ]
    [ "$KINDRED_DB_URL" = "postgres://kindred@file" ]
    # The fallback sources the file in a subshell: nothing else leaks over.
    [ -z "$(bash -c 'printf %s "${KINDRED_DB_URL-}"')" ]
}

@test "a rejected token falls back to secrets.env; the reason names the error, never the token" {
    export DOPPLER_STUB_FAIL=1
    echo 'NTFY_TOPIC=topic-from-file' > "$ARCHON_CRON_SECRETS"
    secrets_load NTFY_TOPIC
    [ "$NTFY_TOPIC" = topic-from-file ]
    run secrets_doppler_json
    [ "$status" -eq 2 ]
    [[ "$output" == *"Invalid Auth token"* ]]
    [[ "$output" != *dp.st.fake* ]]
}

@test "a missing token file never runs doppler; secrets.env supplies the values" {
    rm "$T/doppler.token"
    echo 'NTFY_TOPIC=topic-from-file' > "$ARCHON_CRON_SECRETS"
    secrets_load NTFY_TOPIC
    [ "$NTFY_TOPIC" = topic-from-file ]
    [ ! -e "$T/argv" ]
    run secrets_doppler_json
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing or unreadable"* ]]
}

@test "an empty token file never runs doppler" {
    : > "$T/doppler.token"
    run secrets_doppler_json
    [ "$status" -eq 1 ]
    [[ "$output" == *"is empty"* ]]
    [ ! -e "$T/argv" ]
}

@test "under bats the host's default token path is ignored" {
    unset ARCHON_CRON_DOPPLER_TOKEN
    mkdir -p "$HOME/.config/archon-cron"
    echo dp.st.fake > "$HOME/.config/archon-cron/doppler.token"
    secrets_load NTFY_TOPIC
    [ ! -e "$T/argv" ]
    [ -z "$(secrets_doppler_token_file)" ]
}

@test "doppler is found in ~/.local/bin when cron's PATH lacks it" {
    mkdir -p "$HOME/.local/bin"
    mv "$T/bin/doppler" "$HOME/.local/bin/doppler"
    PATH=/usr/bin:/bin secrets_load NTFY_TOPIC
    [ "$NTFY_TOPIC" = topic-from-doppler ]
}

@test "a name no source supplies keeps its value, empty or not" {
    KINDRED_DB_URL=already-set
    NTFY_TOPIC=""
    echo '{}' > "$DOPPLER_STUB_JSON"
    secrets_load KINDRED_DB_URL NTFY_TOPIC
    [ "$KINDRED_DB_URL" = already-set ]
    [ -z "$NTFY_TOPIC" ]
}

@test "secret_get prints one value, from Doppler or else secrets.env" {
    echo 'KINDRED_DB_URL=postgres://kindred@file' > "$ARCHON_CRON_SECRETS"
    [ "$(secret_get NTFY_TOPIC)" = topic-from-doppler ]
    [ "$(secret_get KINDRED_DB_URL)" = "postgres://kindred@file" ]
    [ -z "$(secret_get NOPE)" ]
}

@test "works under set -euo pipefail with Doppler and secrets.env both absent" {
    rm "$T/doppler.token"
    rm "$ARCHON_CRON_SECRETS"
    run bash -c 'set -euo pipefail; source "$1"; secrets_load NTFY_TOPIC; echo "ok:${NTFY_TOPIC-unset}:$(secret_get NTFY_TOPIC)"' _ "$BATS_TEST_DIRNAME/../lib/secrets.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "ok:unset:" ]
}
