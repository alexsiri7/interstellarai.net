#!/usr/bin/env bash
# Secrets for the cron scripts (interstellarai.net #175). Doppler is the store
# of record: project factory, config prd, read with the read-only service token
# in $ARCHON_CRON_DOPPLER_TOKEN (default ~/.config/archon-cron/doppler.token).
# A name Doppler does not have falls back to its line in $ARCHON_CRON_SECRETS
# (default ~/.config/archon-cron/secrets.env), read one key at a time; that
# file is never sourced.
#
#   source "$SCRIPT_DIR/lib/secrets.sh"
#   secrets_load NTFY_TOPIC CLAUDE_ACCOUNTS   # one Doppler call for all names
#   topic=$(secrets_get NTFY_TOPIC)
#
# Values become plain shell variables, never exported: the archon runs these
# scripts start must not inherit them. The token reaches doppler only as a
# command prefix, and nothing here prints a value except secrets_get to its
# caller. A name found nowhere keeps the value it already had.
#
# SECRETS_DOPPLER_RC is the outcome of secrets_load's Doppler read: 0 ok,
# 1 token file missing or empty, 2 doppler failed (CLI missing, token
# rejected, Doppler unreachable), 3 not tried. Under bats the host's token is
# ignored (3) unless the test sets ARCHON_CRON_DOPPLER_TOKEN.
# pipeline-health-cron.sh (check_doppler_token) alerts on 1 and 2.

SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
SECRETS_DOPPLER_RC=3

# _secrets_doppler_json NAME... — {NAME: value} for the names Doppler has, as
# compact JSON on stdout; exit status as SECRETS_DOPPLER_RC. The whole store
# only ever passes through the pipe into jq.
_secrets_doppler_json() {
  if [ -n "${BATS_TEST_FILENAME:-}" ] && [ -z "${ARCHON_CRON_DOPPLER_TOKEN:-}" ]; then
    return 3
  fi
  local token_file="${ARCHON_CRON_DOPPLER_TOKEN:-$HOME/.config/archon-cron/doppler.token}"
  local token="" bin
  [ -r "$token_file" ] && token=$(tr -d '[:space:]' < "$token_file")
  [ -n "$token" ] || return 1
  # cron's PATH may not include ~/.local/bin, where the CLI is installed.
  bin=$(command -v doppler) || bin="$HOME/.local/bin/doppler"
  [ -x "$bin" ] || return 2
  DOPPLER_TOKEN="$token" "$bin" secrets download --no-file --format json --no-check-version 2>/dev/null \
    | jq -c 'with_entries(select(.key | IN($ARGS.positional[])))' --args "$@" 2>/dev/null
  local -a rcs=("${PIPESTATUS[@]}")
  if [ "${rcs[0]}" -ne 0 ] || [ "${rcs[1]}" -ne 0 ]; then
    return 2
  fi
}

# _secrets_file_get NAME — NAME's last value in $SECRETS_FILE. Values with
# quotes or whitespace inside are not supported.
_secrets_file_get() {
  [ -r "$SECRETS_FILE" ] || return 0
  sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$1=[\"']?([^\"'[:space:]#]*).*/\\2/p" "$SECRETS_FILE" | tail -n 1
}

# secrets_load NAME... — set each NAME from Doppler, else from $SECRETS_FILE.
# Always returns 0, so it is safe under set -e.
secrets_load() {
  local _secrets_json _secrets_name _secrets_value
  # shellcheck disable=SC2034  # read by the caller (check_doppler_token)
  if _secrets_json=$(_secrets_doppler_json "$@"); then
    SECRETS_DOPPLER_RC=0
  else
    SECRETS_DOPPLER_RC=$?
    _secrets_json='{}'
  fi
  for _secrets_name in "$@"; do
    _secrets_value=$(printf '%s' "$_secrets_json" | jq -r --arg k "$_secrets_name" '.[$k] // empty')
    if [ -z "$_secrets_value" ]; then
      _secrets_value=$(_secrets_file_get "$_secrets_name")
    fi
    if [ -n "$_secrets_value" ]; then
      printf -v "$_secrets_name" '%s' "$_secrets_value"
    fi
  done
  return 0
}

# secrets_get NAME — NAME's value on stdout, by secrets_load's precedence;
# nothing when neither source has it. Runs in a subshell, so it sets nothing.
secrets_get() (
  unset "$1"
  secrets_load "$1"
  printf '%s' "${!1:-}"
)
