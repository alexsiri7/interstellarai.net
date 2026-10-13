#!/usr/bin/env bash
# Secrets for the factory scripts, from Doppler (interstellarai.net #175).
#
#   source "$SCRIPT_DIR/lib/secrets.sh"
#   secrets_load NTFY_TOPIC CLAUDE_ACCOUNTS   # named keys into shell variables
#   topic=$(secret_get NTFY_TOPIC)            # one value on stdout
#
# The store of record is Doppler project `factory`, config `prd`, read with a
# read-only service token kept in $ARCHON_CRON_DOPPLER_TOKEN (default
# ~/.config/archon-cron/doppler.token, chmod 600). The token reaches only the
# doppler process: it is never exported, never on argv, never printed. Only the
# names a script asks for are loaded, never the whole store, and secrets_load
# does not export them, so the archon runs these scripts start never inherit
# them.
#
# A name Doppler does not supply (token missing or rejected, Doppler
# unreachable, key absent) is read from $ARCHON_CRON_SECRETS (default
# ~/.config/archon-cron/secrets.env) until that file is retired; a name neither
# supplies keeps the value it had. pipeline-health's check_doppler_token
# alerts when Doppler is not the one answering.
#
# Under bats the default token path is ignored (tests must never reach the real
# store); a test sets ARCHON_CRON_DOPPLER_TOKEN to exercise Doppler.

[ -n "${_ARCHON_SECRETS_SH:-}" ] && return 0
_ARCHON_SECRETS_SH=1

SECRETS_DOPPLER_TIMEOUT="${SECRETS_DOPPLER_TIMEOUT:-20}"

# secrets_doppler_token_file — the token path, or nothing when Doppler is off
# (under bats without ARCHON_CRON_DOPPLER_TOKEN).
secrets_doppler_token_file() {
  if [ -n "${ARCHON_CRON_DOPPLER_TOKEN:-}" ]; then
    printf '%s\n' "$ARCHON_CRON_DOPPLER_TOKEN"
  elif [ -z "${BATS_TEST_FILENAME:-}" ]; then
    printf '%s\n' "$HOME/.config/archon-cron/doppler.token"
  fi
}

# Cron's PATH is /usr/bin:/bin; the CLI lives in ~/.local/bin.
_secrets_doppler_bin() {
  command -v doppler 2>/dev/null && return 0
  [ -x "$HOME/.local/bin/doppler" ] || return 1
  printf '%s\n' "$HOME/.local/bin/doppler"
}

# secrets_doppler_json — the whole factory/prd config as one JSON object on
# stdout, for this process only. Exit 1 when Doppler is not set up here (no
# token file, empty token, no CLI), 2 when it rejected the token, could not be
# reached or answered nonsense. The reason goes to stderr, never a value.
secrets_doppler_json() {
  local file token bin err json rc=0
  file=$(secrets_doppler_token_file)
  [ -n "$file" ] || { echo "no Doppler token configured" >&2; return 1; }
  [ -r "$file" ] || { echo "token file $file missing or unreadable" >&2; return 1; }
  token=$(tr -d '[:space:]' < "$file")
  [ -n "$token" ] || { echo "token file $file is empty" >&2; return 1; }
  bin=$(_secrets_doppler_bin) || { echo "doppler CLI not found" >&2; return 1; }
  err=$(mktemp) || return 2
  json=$(DOPPLER_TOKEN="$token" timeout "$SECRETS_DOPPLER_TIMEOUT" \
    "$bin" secrets download --no-file --format json 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "doppler rejected the token or is unreachable (exit $rc): $(grep -v '^[[:space:]]*$' "$err" | tail -n 1 | cut -c1-200)" >&2
    rm -f "$err"
    return 2
  fi
  rm -f "$err"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json" \
    || { echo "doppler answered without a JSON object" >&2; return 2; }
  printf '%s\n' "$json"
}

# _secrets_from_file NAME — NAME as sourcing secrets.env sets it, read in a
# subshell so nothing else in the file reaches this shell.
_secrets_from_file() {
  local file="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
  [ -r "$file" ] || return 0
  # shellcheck source=/dev/null
  ( unset "$1"; . "$file" >/dev/null 2>&1 || true; printf '%s' "${!1-}" )
}

# _secrets_pick JSON NAME — NAME from Doppler's JSON, else from secrets.env.
_secrets_pick() {
  local v=""
  if [ -n "$1" ]; then v=$(jq -r --arg k "$2" '.[$k] // empty' <<<"$1"); fi
  if [ -z "$v" ]; then v=$(_secrets_from_file "$2"); fi
  printf '%s' "$v"
}

# secret_get NAME — one value on stdout (empty when no source has it).
secret_get() {
  local json
  json=$(secrets_doppler_json 2>/dev/null) || json=""
  _secrets_pick "$json" "$1"
}

# secrets_load NAME... — each named key into the shell variable of that name,
# unexported, with one Doppler call. A name no source supplies is left alone.
secrets_load() {
  local _sl_json _sl_name _sl_v
  _sl_json=$(secrets_doppler_json 2>/dev/null) || _sl_json=""
  for _sl_name in "$@"; do
    _sl_v=$(_secrets_pick "$_sl_json" "$_sl_name")
    if [ -n "$_sl_v" ]; then printf -v "$_sl_name" '%s' "$_sl_v"; fi
  done
  return 0
}
