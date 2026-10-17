#!/usr/bin/env bats
# ops/cron/doppler-push.sh (#175): one Doppler config onto one Railway
# service, values over stdin only, never printed, never deleting.
#
# Run: bunx bats ops/cron/tests/doppler-push.bats

load doppler-stub

setup() {
    export T="$BATS_TMPDIR/doppler-push-$$"
    rm -rf "$T"; mkdir -p "$T/bin" "$T/set" "$T/tmp" "$T/home"
    export HOME="$T/home" TMPDIR="$T/tmp"
    SCRIPT="$BATS_TEST_DIRNAME/../doppler-push.sh"
    doppler_stub "$T/bin"
    export PATH="$T/bin:$PATH"
    export DOPPLER_STUB_ARGV="$T/doppler-argv" DOPPLER_STUB_TOKEN_SEEN="$T/token-seen"
    export DOPPLER_STUB_JSON="$T/doppler.json"
    cat > "$DOPPLER_STUB_JSON" <<'JSON'
{"API_KEY":"value-new-1","DB_URL":"postgres://secret@changed","SAME":"value-same","DOPPLER_PROJECT":"musenmingle","DOPPLER_CONFIG":"prd_api","DOPPLER_ENVIRONMENT":"prd"}
JSON
    export RW_JSON="$T/railway.json" RW_ARGV="$T/railway-argv" RW_SET_DIR="$T/set"
    cat > "$RW_JSON" <<'JSON'
{"DB_URL":"postgres://secret@old","SAME":"value-same","LEGACY_FLAG":"value-legacy","RAILWAY_ENVIRONMENT":"production"}
JSON
    unset RW_SET_FAIL DOPPLER_STUB_FAIL DOPPLER_PUSH_TOKEN_FILE
    cat > "$T/bin/railway" <<'STUB'
#!/usr/bin/env bash
printf '%s | %s\n' "$PWD" "$*" >> "$RW_ARGV"
case "$1 ${2:-}" in
  "variables --json") cat "$RW_JSON" ;;
  "variable set")
    [ "$3" = "${RW_SET_FAIL:-}" ] && exit 1
    cat > "$RW_SET_DIR/$3" ;;
esac
exit 0
STUB
    chmod +x "$T/bin/railway"
}

teardown() { rm -rf "$T"; }

push() { run "$SCRIPT" "$@" musenmingle prd_api rw-proj-id musenmingle-api; }

@test "sets exactly the new and changed names, each value over stdin" {
    push
    [ "$status" -eq 0 ]
    [ "$(ls "$T/set" | tr '\n' ' ')" = "API_KEY DB_URL " ]
    [ "$(cat "$T/set/API_KEY")" = value-new-1 ]
    [ "$(cat "$T/set/DB_URL")" = "postgres://secret@changed" ]
    [[ "$output" == *"changed: API_KEY DB_URL"* ]]
    grep -q "| variable set API_KEY --stdin --skip-deploys$" "$RW_ARGV"
}

@test "no value reaches railway's argv or the script's output" {
    push
    run grep -E 'value-|secret@' "$RW_ARGV"
    [ "$status" -eq 1 ]
    push
    [[ "$output" != *value-* ]]
    [[ "$output" != *secret@* ]]
}

@test "DOPPLER_* keys are never pushed" {
    push
    [ ! -e "$T/set/DOPPLER_PROJECT" ]
    [ ! -e "$T/set/DOPPLER_CONFIG" ]
    [ ! -e "$T/set/DOPPLER_ENVIRONMENT" ]
}

@test "Railway-only names are reported, never deleted" {
    push
    [[ "$output" == *"only on Railway (not deleted): LEGACY_FLAG"* ]]
    [[ "$output" != *RAILWAY_ENVIRONMENT* ]]
    run grep -E 'delete|unset|remove' "$RW_ARGV"
    [ "$status" -eq 1 ]
}

@test "Railway calls run linked from a private temp dir that is unlinked and removed" {
    push
    [ "$status" -eq 0 ]
    grep -q "| link --project rw-proj-id --service musenmingle-api --environment production$" "$RW_ARGV"
    [ "$(tail -n 1 "$RW_ARGV" | cut -d'|' -f2)" = " unlink" ]
    [ "$(cut -d'|' -f1 "$RW_ARGV" | sort -u | wc -l)" -eq 1 ]
    [ -z "$(ls -A "$T/tmp")" ]
}

@test "--redeploy redeploys after the sets; without it nothing is redeployed" {
    push
    run grep -q redeploy "$RW_ARGV"
    [ "$status" -eq 1 ]
    push --redeploy
    [ "$status" -eq 0 ]
    grep -q "| redeploy --service musenmingle-api --yes$" "$RW_ARGV"
}

@test "a failed set: exit 1, the name reported, no redeploy" {
    export RW_SET_FAIL=DB_URL
    push --redeploy
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED: DB_URL"* ]]
    run grep -q redeploy "$RW_ARGV"
    [ "$status" -eq 1 ]
}

@test "a Doppler failure: exit 1 with its reason, Railway untouched" {
    export DOPPLER_STUB_FAIL=1
    push
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid Auth token"* ]]
    [ ! -e "$RW_ARGV" ]
    [ -z "$(ls -A "$T/tmp")" ]
}

@test "the push token reaches only doppler's environment; without it the CLI login is used" {
    push
    [ "$(cat "$T/token-seen")" = "<unset>" ]
    grep -q "^secrets download --no-file --format json --project musenmingle --config prd_api$" "$DOPPLER_STUB_ARGV"
    echo dp.pt.fake > "$T/push.token"
    export DOPPLER_PUSH_TOKEN_FILE="$T/push.token"
    push
    [ "$(tail -n 1 "$T/token-seen")" = dp.pt.fake ]
    run grep -q dp.pt.fake "$DOPPLER_STUB_ARGV" "$RW_ARGV"
    [ "$status" -eq 1 ]
}

@test "under bats the default push token path is ignored" {
    mkdir -p "$HOME/.config/archon-cron"
    echo dp.pt.fake > "$HOME/.config/archon-cron/doppler-push.token"
    push
    [ "$(cat "$T/token-seen")" = "<unset>" ]
}

@test "wrong argument count or an unknown flag: usage, exit 2" {
    run "$SCRIPT" musenmingle prd_api rw-proj-id
    [ "$status" -eq 2 ]
    [[ "$output" == *usage:* ]]
    run "$SCRIPT" a b c d e f
    [ "$status" -eq 2 ]
    run "$SCRIPT" --dry-run a b c d
    [ "$status" -eq 2 ]
    [ ! -e "$DOPPLER_STUB_ARGV" ]
}

@test "an explicit environment is linked" {
    run "$SCRIPT" kindred prd_web rw-kindred web staging
    [ "$status" -eq 0 ]
    grep -q "| link --project rw-kindred --service web --environment staging$" "$RW_ARGV"
}
