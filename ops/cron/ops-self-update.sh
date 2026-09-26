#!/usr/bin/env bash
# ops-self-update.sh — keep the live ops checkout on origin/main (crontab, */10).
#
#   ops/cron/ops-self-update.sh                 # the cron tick
#   ops/cron/ops-self-update.sh --approve       # owner, at the console: review and release a held update
#
# ARCHON_RUN_AS=asiri (default, lib/run-as.sh): exactly the old crontab line,
#   git -C <checkout> pull --ff-only -q origin main
#
# ARCHON_RUN_AS=archon: the factory user has push access to this repo, and the
#   crontab runs ops/** as asiri — with every secret — straight out of this
#   checkout. GitHub cannot tell the factory's token from the owner (both act as
#   alexsiri7), so the gate is local: an update whose range touches ops/** is
#   held until the owner approves that exact origin/main commit here, as asiri
#   (--approve shows the diff first). Anything else fast-forwards as before.
#   One ntfy per held commit. --approve records the sha in
#   ~/.config/archon-cron/ops-approved (0600, a dir archon cannot read).
#
# Env: OPS_CHECKOUT (default: the repo this script lives in), OPS_APPROVED_FILE,
# OPS_SELF_UPDATE_STATE (held-notice markers), ARCHON_CRON_SECRETS (NTFY_TOPIC).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-as.sh
source "$SCRIPT_DIR/lib/run-as.sh"
REPO="${OPS_CHECKOUT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
APPROVED_FILE="${OPS_APPROVED_FILE:-$HOME/.config/archon-cron/ops-approved}"
STATE="${OPS_SELF_UPDATE_STATE:-$HOME/.local/state/archon-cron/ops-self-update}"
GUARDED_PATHS=(ops/)

log() { echo "$(date -Is) [ops-self-update] $*"; }

if ! runas_archon && [ "${1:-}" != --approve ]; then
  exec git -C "$REPO" pull --ff-only -q origin main
fi

git -C "$REPO" fetch -q origin main || { log "git fetch failed"; exit 1; }
head=$(git -C "$REPO" rev-parse HEAD) || exit 1
target=$(git -C "$REPO" rev-parse FETCH_HEAD) || exit 1
[ "$head" = "$target" ] && { [ "${1:-}" = --approve ] && echo "already at origin/main ($target)"; exit 0; }
if ! git -C "$REPO" merge-base --is-ancestor "$head" "$target"; then
  log "HEAD $head is not an ancestor of origin/main $target — not fast-forwarding (fix by hand)"
  exit 1
fi
guarded=$(git -C "$REPO" diff --name-only "$head" "$target" -- "${GUARDED_PATHS[@]}")

if [ "${1:-}" = --approve ]; then
  if [ -z "$guarded" ]; then
    echo "nothing under ${GUARDED_PATHS[*]} changed; the next tick fast-forwards on its own"
    exit 0
  fi
  git -C "$REPO" --no-pager log --stat "$head..$target" -- "${GUARDED_PATHS[@]}"
  git -C "$REPO" --no-pager diff "$head" "$target" -- "${GUARDED_PATHS[@]}"
  printf '\nThis runs as %s from cron (and ops/host as root when you run it). Approve %s? [y/N] ' "$(id -un)" "$target"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "not approved"; exit 1; }
  mkdir -p "$(dirname "$APPROVED_FILE")"
  ( umask 077; echo "$target" >> "$APPROVED_FILE" )
  git -C "$REPO" merge --ff-only -q "$target" && echo "approved and fast-forwarded to $target"
  exit $?
fi

if [ -z "$guarded" ] || grep -qxF "$target" "$APPROVED_FILE" 2>/dev/null; then
  exec git -C "$REPO" merge --ff-only -q "$target"
fi

mkdir -p "$STATE"
if [ ! -e "$STATE/held-$target" ]; then
  : > "$STATE/held-$target"
  n=$(wc -l <<<"$guarded")
  log "holding origin/main $target: $n file(s) under ${GUARDED_PATHS[*]} changed — approve with: $SCRIPT_DIR/ops-self-update.sh --approve"
  SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
  topic=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?NTFY_TOPIC=["'\'']?([^"'\''[:space:]#]*).*/\2/p' "$SECRETS_FILE" 2>/dev/null | tail -1)
  if [ -n "$topic" ]; then
    curl -fsS -m 15 -H "Title: ops update held for review" -H "Priority: high" -H "Tags: lock" \
      -d "origin/main ${target:0:10} changes $n file(s) under ops/ — the cron runs these as asiri. Review and approve at the console: ops/cron/ops-self-update.sh --approve" \
      "https://ntfy.sh/$topic" >/dev/null 2>&1 || log "ntfy failed"
  fi
fi
exit 0
