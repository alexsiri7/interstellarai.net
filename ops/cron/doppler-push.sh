#!/usr/bin/env bash
# doppler-push.sh — push one Doppler config onto one Railway service, for the
# services Doppler's own Railway sync does not cover (free plan, 5 syncs;
# interstellarai.net #175). Run by hand, or by an agent, when a secret changes:
#
#   ops/cron/doppler-push.sh [--redeploy] <doppler-project> <config> <railway-project-id> <service> [environment]
#
# environment defaults to `production`. Every Doppler key except DOPPLER_* whose
# value Railway lacks or holds differently is set with
# `railway variable set NAME --stdin --skip-deploys`; then the changed names are
# printed. Railway variables Doppler does not have are reported, never deleted.
# --redeploy redeploys the service afterwards when every set succeeded.
#
# Never prints a value: values travel only through 0600 files in a private temp
# dir and over stdin, never through a shell variable or argv.
#
# Doppler access: the token in $DOPPLER_PUSH_TOKEN_FILE (default
# ~/.config/archon-cron/doppler-push.token, chmod 600) when it exists, passed to
# the doppler process only; otherwise the CLI's own login (the author's
# session). Under bats the default path is ignored.
#
# Exit: 0 all set, 1 a Doppler or Railway step failed, 2 usage.

set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

log() { echo "$(date -Is) [doppler-push] $*"; }
usage() {
  echo "usage: $0 [--redeploy] <doppler-project> <config> <railway-project-id> <service> [environment]" >&2
  exit 2
}

REDEPLOY=0
args=()
for a in "$@"; do
  case "$a" in
    --redeploy) REDEPLOY=1 ;;
    -*) usage ;;
    *) args+=("$a") ;;
  esac
done
{ [ "${#args[@]}" -eq 4 ] || [ "${#args[@]}" -eq 5 ]; } || usage
PROJECT="${args[0]}" CONFIG="${args[1]}" RW_PROJECT="${args[2]}" SERVICE="${args[3]}"
ENVIRONMENT="${args[4]:-production}"

TOKEN_FILE="${DOPPLER_PUSH_TOKEN_FILE:-}"
[ -z "$TOKEN_FILE" ] && [ -z "${BATS_TEST_FILENAME:-}" ] \
  && TOKEN_FILE="$HOME/.config/archon-cron/doppler-push.token"

umask 077
TMP=$(mktemp -d) || exit 1
mkdir "$TMP/rw"
# shellcheck disable=SC2329  # the EXIT trap calls it
cleanup() {
  [ -f "$TMP/linked" ] && (cd "$TMP/rw" && railway unlink) >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# Every Railway call runs from $TMP/rw, so the link never touches a real
# checkout; cleanup unlinks it.
rw_link()     { (cd "$TMP/rw" && railway link --project "$RW_PROJECT" --service "$SERVICE" --environment "$ENVIRONMENT") </dev/null >/dev/null 2>"$TMP/err"; }
rw_list()     { (cd "$TMP/rw" && railway variables --json) 2>"$TMP/err"; }
rw_set()      { (cd "$TMP/rw" && railway variable set "$1" --stdin --skip-deploys) >/dev/null 2>&1; }
rw_redeploy() { (cd "$TMP/rw" && railway redeploy --service "$SERVICE" --yes) </dev/null >/dev/null 2>"$TMP/err"; }
last_err()    { grep -v '^[[:space:]]*$' "$TMP/err" | tail -n 1 | cut -c1-200; }

doppler_download() {
  local token=""
  [ -n "$TOKEN_FILE" ] && [ -r "$TOKEN_FILE" ] && token=$(tr -d '[:space:]' < "$TOKEN_FILE")
  if [ -n "$token" ]; then
    DOPPLER_TOKEN="$token" doppler secrets download --no-file --format json --project "$PROJECT" --config "$CONFIG"
  else
    doppler secrets download --no-file --format json --project "$PROJECT" --config "$CONFIG"
  fi
}

if ! doppler_download > "$TMP/raw.json" 2>"$TMP/err" \
   || ! jq -e 'type == "object"' "$TMP/raw.json" >/dev/null 2>&1; then
  log "FAILED: doppler $PROJECT/$CONFIG: $(last_err)"
  exit 1
fi
jq 'with_entries(select(.key | startswith("DOPPLER_") | not))' "$TMP/raw.json" > "$TMP/doppler.json" || exit 1
rm -f "$TMP/raw.json"

rw_link || { log "FAILED: railway link $RW_PROJECT/$SERVICE ($ENVIRONMENT): $(last_err)"; exit 1; }
touch "$TMP/linked"
if ! rw_list > "$TMP/railway.json" || ! jq -e 'type == "object"' "$TMP/railway.json" >/dev/null 2>&1; then
  log "FAILED: railway variables for $SERVICE: $(last_err)"
  exit 1
fi

mapfile -t to_set < <(jq -r --slurpfile r "$TMP/railway.json" \
  'to_entries[] | select($r[0][.key] != .value) | .key' "$TMP/doppler.json" | sort)
mapfile -t railway_only < <(jq -r --slurpfile d "$TMP/doppler.json" \
  'keys[] | select(startswith("RAILWAY_") | not) | select(. as $k | $d[0] | has($k) | not)' "$TMP/railway.json")

changed=() failed=()
for name in "${to_set[@]}"; do
  if jq -j --arg k "$name" '.[$k]' "$TMP/doppler.json" | rw_set "$name"; then
    changed+=("$name")
  else
    failed+=("$name")
  fi
done

log "$PROJECT/$CONFIG -> $SERVICE ($ENVIRONMENT)"
log "changed: ${changed[*]:-none}"
[ "${#railway_only[@]}" -gt 0 ] && log "only on Railway (not deleted): ${railway_only[*]}"
if [ "${#failed[@]}" -gt 0 ]; then
  log "FAILED: ${failed[*]}"
  exit 1
fi

if [ "$REDEPLOY" = 1 ]; then
  rw_redeploy || { log "FAILED: railway redeploy $SERVICE: $(last_err)"; exit 1; }
  log "redeployed $SERVICE"
fi
exit 0
