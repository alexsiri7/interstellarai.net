#!/usr/bin/env bash
# doppler-push.sh — copy one Doppler config onto one Railway service, for the
# configs Doppler's own Railway sync does not cover (the free plan allows 5;
# see README "Secrets"). Run by hand, or by an agent, when a secret changes:
#
#   doppler-push.sh [--redeploy] <doppler-project> <config> <railway-project-id> <service> [environment]
#
# Every key of the config except Doppler's own DOPPLER_* is set on the service
# (environment default: production) with `railway variable set --stdin
# --skip-deploys`, and only when Railway's value differs. Variables Railway has
# and Doppler does not are reported and left alone: nothing is ever deleted.
# Output is names only — never a value. --redeploy redeploys the service once
# afterwards, when something changed.
#
# Doppler is read with the token in $DOPPLER_PUSH_TOKEN_FILE (default
# ~/.config/archon-cron/doppler-push.token) when it exists, else with the
# CLI's logged-in session. Railway is linked from a throw-away directory, so
# the caller's own link is never touched. Values only ever pass through pipes.
#
# Exit: 0 all set, 1 a set failed (named in the log), 2 usage error or a read
# of Doppler or Railway failed.

set -uo pipefail

log() { echo "[doppler-push] $*"; }
usage() {
  echo "usage: $0 [--redeploy] <doppler-project> <config> <railway-project-id> <service> [environment]" >&2
  exit 2
}

REDEPLOY=0
if [ "${1:-}" = --redeploy ]; then
  REDEPLOY=1
  shift
fi
[ $# -eq 4 ] || [ $# -eq 5 ] || usage
PROJECT="$1" CONFIG="$2" RAILWAY_PROJECT="$3" SERVICE="$4" ENVIRONMENT="${5:-production}"
for arg in "$PROJECT" "$CONFIG" "$RAILWAY_PROJECT" "$SERVICE" "$ENVIRONMENT"; do
  case "$arg" in ''|-*) usage ;; esac
done

TOKEN_FILE="${DOPPLER_PUSH_TOKEN_FILE:-$HOME/.config/archon-cron/doppler-push.token}"

# doppler_download — the config as a JSON object, DOPPLER_* keys dropped.
doppler_download() {
  local token=""
  [ -r "$TOKEN_FILE" ] && token=$(tr -d '[:space:]' < "$TOKEN_FILE")
  if [ -n "$token" ]; then
    DOPPLER_TOKEN="$token" doppler secrets download --project "$PROJECT" --config "$CONFIG" \
      --no-file --format json --no-check-version
  else
    doppler secrets download --project "$PROJECT" --config "$CONFIG" \
      --no-file --format json --no-check-version
  fi | jq -c 'with_entries(select(.key | startswith("DOPPLER_") | not))'
}

doppler_json=$(doppler_download) || { log "ERROR: cannot read Doppler $PROJECT/$CONFIG"; exit 2; }

link_dir=$(mktemp -d) || exit 2
trap 'rm -rf "$link_dir"' EXIT
cd "$link_dir" || exit 2
if ! railway link --project "$RAILWAY_PROJECT" --environment "$ENVIRONMENT" --service "$SERVICE" >/dev/null; then
  log "ERROR: cannot link Railway project $RAILWAY_PROJECT ($SERVICE, $ENVIRONMENT)"
  exit 2
fi
railway_json=$(railway variable list --service "$SERVICE" --environment "$ENVIRONMENT" --json | jq -c .) \
  || { log "ERROR: cannot read Railway variables of $SERVICE ($ENVIRONMENT)"; exit 2; }

# both_maps — Doppler's map then Railway's, for `jq -s` (values stay off argv).
both_maps() { printf '%s\n%s\n' "$doppler_json" "$railway_json"; }

mapfile -t differing < <(both_maps | jq -rs '.[0] as $d | .[1] as $r
  | $d | keys[] | select($r[.] != $d[.])')
mapfile -t railway_only < <(both_maps | jq -rs '.[0] as $d | .[1]
  | keys[] | select(startswith("RAILWAY_") | not) | select(in($d) | not)')

rc=0
changed=()
for name in "${differing[@]}"; do
  if printf '%s' "$doppler_json" | jq -j --arg k "$name" '.[$k]' \
      | railway variable set "$name" --stdin --skip-deploys --service "$SERVICE" --environment "$ENVIRONMENT" >/dev/null; then
    changed+=("$name")
  else
    log "ERROR: setting $name on $SERVICE failed"
    rc=1
  fi
done

[ ${#railway_only[@]} -gt 0 ] && log "not in Doppler (left alone): ${railway_only[*]}"
if [ ${#changed[@]} -gt 0 ]; then
  log "changed: ${changed[*]}"
else
  log "changed: none"
fi

if [ "$REDEPLOY" -eq 1 ] && [ ${#changed[@]} -gt 0 ]; then
  railway redeploy --service "$SERVICE" --yes || { log "ERROR: redeploy of $SERVICE failed"; rc=1; }
fi
exit "$rc"
