#!/usr/bin/env bats
# Tests for doppler-push.sh: only the keys whose value differs are set on the
# Railway service, through stdin; Railway-only variables are reported, never
# deleted; no value is ever printed.
#
# Run: bunx bats ops/cron/tests/doppler-push.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/doppler-push.sh"
    export HOME="$T/home"
    mkdir -p "$HOME" "$T/bin" "$T/set"
    export PATH="$T/bin:$PATH"
    export DOPPLER_PUSH_TOKEN_FILE="$T/doppler-push.token"
    export RAILWAY_ARGV="$T/railway-argv" DOPPLER_ARGV="$T/doppler-argv" SET_DIR="$T/set"
    export DOPPLER_FIXTURE='{"DOPPLER_PROJECT":"musenmingle","DOPPLER_CONFIG":"prd_api","A":"val-same","B":"val-new-b","D":"val-new-d"}'
    export RAILWAY_FIXTURE='{"A":"val-same","B":"val-old-b","C":"val-railway-only","RAILWAY_PUBLIC_DOMAIN":"x.up.railway.app"}'

    cat > "$T/bin/doppler" <<'STUB'
#!/usr/bin/env bash
printf '%s token=%s\n' "$*" "${DOPPLER_TOKEN:+set}" >> "$DOPPLER_ARGV"
[ "${STUB_DOPPLER_FAIL:-0}" = 1 ] && exit 1
printf '%s' "$DOPPLER_FIXTURE"
STUB
    # railway: argv and cwd to $RAILWAY_ARGV; `variable set NAME --stdin`
    # keeps stdin in $SET_DIR/NAME so the test can compare it, never logs it.
    cat > "$T/bin/railway" <<'STUB'
#!/usr/bin/env bash
printf '%s | cwd=%s\n' "$*" "$PWD" >> "$RAILWAY_ARGV"
case "$1 $2" in
  "variable list") printf '%s' "$RAILWAY_FIXTURE" ;;
  "variable set")
    cat > "$SET_DIR/$3"
    [ "$3" = "${STUB_RAILWAY_SET_FAIL:-}" ] && exit 1
    echo "Set $3" ;;
esac
exit 0
STUB
    chmod +x "$T/bin/doppler" "$T/bin/railway"
}

push() { run "$SCRIPT" "$@"; }

@test "sets only the keys that differ, by stdin, without a trailing newline" {
    push musenmingle prd_api proj-123 musenmingle-api
    [ "$status" -eq 0 ]
    [ "$(grep -c '^variable set' "$RAILWAY_ARGV")" -eq 2 ]
    grep -q '^variable set B --stdin --skip-deploys --service musenmingle-api --environment production ' "$RAILWAY_ARGV"
    grep -q '^variable set D --stdin --skip-deploys --service musenmingle-api --environment production ' "$RAILWAY_ARGV"
    [ "$(cat "$SET_DIR/B")" = val-new-b ]
    [ "$(wc -c < "$SET_DIR/B")" -eq 9 ]
    [ ! -e "$SET_DIR/A" ]
    [ ! -e "$SET_DIR/DOPPLER_PROJECT" ]
}

@test "prints the names it changed and the Railway-only ones, never a value" {
    push musenmingle prd_api proj-123 musenmingle-api staging
    [ "$status" -eq 0 ]
    [[ "$output" == *"changed: B D"* ]]
    [[ "$output" == *"not in Doppler (left alone): C"* ]]
    [[ "$output" != *RAILWAY_PUBLIC_DOMAIN* ]]
    [[ "$output" != *val-* ]]
    run ! grep -q 'val-' "$RAILWAY_ARGV" "$DOPPLER_ARGV"
    run ! grep -Eq '^variable (delete|rm)|^(delete|unlink)' "$RAILWAY_ARGV"
    grep -q -- '--environment staging' "$RAILWAY_ARGV"
}

@test "nothing differs: changed none, and --redeploy does not redeploy" {
    export RAILWAY_FIXTURE='{"A":"val-same","B":"val-new-b","D":"val-new-d"}'
    push --redeploy musenmingle prd_api proj-123 musenmingle-api
    [ "$status" -eq 0 ]
    [[ "$output" == *"changed: none"* ]]
    run ! grep -q '^redeploy' "$RAILWAY_ARGV"
}

@test "--redeploy redeploys once after a change; without it, never" {
    push musenmingle prd_api proj-123 musenmingle-api
    run ! grep -q '^redeploy' "$RAILWAY_ARGV"
    : > "$RAILWAY_ARGV"
    push --redeploy musenmingle prd_api proj-123 musenmingle-api
    [ "$(grep -c '^redeploy --service musenmingle-api --yes' "$RAILWAY_ARGV")" -eq 1 ]
}

@test "links from a throw-away dir, never the caller's" {
    cd "$T"
    push kindred prd_web proj-456 web
    grep -q "^link --project proj-456 --environment production --service web | cwd=" "$RAILWAY_ARGV"
    run ! grep -q "cwd=$T |" "$RAILWAY_ARGV"
    run ! grep -q "cwd=$T\$" "$RAILWAY_ARGV"
    local link_dir; link_dir=$(sed -n 's/^link .* | cwd=//p' "$RAILWAY_ARGV")
    [ ! -e "$link_dir" ]
}

@test "reads Doppler with the push token when present, else the CLI login" {
    push kindred prd_mcp proj-456 mcp
    grep -q '^secrets download --project kindred --config prd_mcp --no-file --format json .*token=$' "$DOPPLER_ARGV"
    echo 'dp.pt.fake' > "$DOPPLER_PUSH_TOKEN_FILE"
    : > "$DOPPLER_ARGV"
    push kindred prd_mcp proj-456 mcp
    grep -q 'token=set$' "$DOPPLER_ARGV"
}

@test "a failed set is named and exits 1; the others still go through" {
    STUB_RAILWAY_SET_FAIL=B push musenmingle prd_api proj-123 musenmingle-api
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: setting B on musenmingle-api failed"* ]]
    [[ "$output" == *"changed: D"* ]]
}

@test "Doppler unreadable: exit 2 before Railway is touched" {
    STUB_DOPPLER_FAIL=1 push musenmingle prd_api proj-123 musenmingle-api
    [ "$status" -eq 2 ]
    [ ! -s "$RAILWAY_ARGV" ]
}

@test "usage errors exit 2" {
    push musenmingle prd_api proj-123
    [ "$status" -eq 2 ]
    push musenmingle prd_api proj-123 svc production extra
    [ "$status" -eq 2 ]
    push --bogus musenmingle prd_api proj-123 svc
    [ "$status" -eq 2 ]
    [ ! -s "$DOPPLER_ARGV" ]
}
