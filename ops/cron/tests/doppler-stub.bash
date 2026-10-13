#!/usr/bin/env bash
# tests/doppler-stub.bash — a fake `doppler` CLI for suites that exercise
# lib/secrets.sh or doppler-push.sh. Load with `load doppler-stub`, then
# `doppler_stub <bindir>` and put <bindir> first on PATH.
#
# The stub appends its argv to $DOPPLER_STUB_ARGV and the DOPPLER_TOKEN it saw
# (or <unset>) to $DOPPLER_STUB_TOKEN_SEEN. With DOPPLER_STUB_FAIL set it
# refuses like a rejected token; otherwise it prints $DOPPLER_STUB_JSON.

doppler_stub() {
    mkdir -p "$1"
    cat > "$1/doppler" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOPPLER_STUB_ARGV:-/dev/null}"
printf '%s\n' "${DOPPLER_TOKEN-<unset>}" >> "${DOPPLER_STUB_TOKEN_SEEN:-/dev/null}"
if [ -n "${DOPPLER_STUB_FAIL:-}" ]; then
    echo "Doppler Error: Invalid Auth token" >&2
    exit 1
fi
cat "$DOPPLER_STUB_JSON"
STUB
    chmod +x "$1/doppler"
}
