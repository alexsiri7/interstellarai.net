# Shared by the suites that exercise lib/secrets.sh against a stubbed Doppler.
#
#   load doppler-stub
#   doppler_stub "$T/bin" '{"NTFY_TOPIC":"t-1"}'   # store contents, as JSON
#
# The stub is `doppler` in the given dir (put it on PATH). Each call appends
# its argv, and whether DOPPLER_TOKEN was set (never its value), to
# $DOPPLER_STUB_LOG; STUB_DOPPLER_FAIL=1 makes it fail like a rejected token.
# ARCHON_CRON_DOPPLER_TOKEN points at a fake token, which also lifts
# lib/secrets.sh's bats guard.

doppler_stub() {
    local dir="$1"
    mkdir -p "$dir"
    export DOPPLER_STUB_LOG="$dir/doppler-calls" DOPPLER_STUB_STORE="$dir/doppler-store.json"
    printf '%s' "$2" > "$DOPPLER_STUB_STORE"
    : > "$DOPPLER_STUB_LOG"
    cat > "$dir/doppler" <<'STUB'
#!/usr/bin/env bash
printf '%s token=%s\n' "$*" "${DOPPLER_TOKEN:+set}" >> "$DOPPLER_STUB_LOG"
if [ "${STUB_DOPPLER_FAIL:-0}" = 1 ]; then
  echo 'Doppler Error: Unable to authenticate' >&2
  exit 1
fi
cat "$DOPPLER_STUB_STORE"
STUB
    chmod +x "$dir/doppler"
    export ARCHON_CRON_DOPPLER_TOKEN="$dir/doppler.token"
    echo 'dp.st.fake-token' > "$ARCHON_CRON_DOPPLER_TOKEN"
}

doppler_calls() { cat "$DOPPLER_STUB_LOG" 2>/dev/null | grep -c . || true; }
