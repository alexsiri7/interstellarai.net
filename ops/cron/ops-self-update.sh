#!/usr/bin/env bash
# ops-self-update.sh — keep the live ops checkout on origin/main (crontab, */10).
#
#   ops/cron/ops-self-update.sh                 # the cron tick
#   ops/cron/ops-self-update.sh --approve       # owner, at the console: review and release a held update
#   ops/cron/ops-self-update.sh --dry-run       # say what a tick would do; changes nothing
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
#   Since 2026-10-06 the factory pushes as its own GitHub user
#   (alexsiri7-factory), so GitHub can tell its work from the owner's: an
#   update goes through without --approve when every commit in the range that
#   touches ops/** is the merge of a pull request opened by OPS_OWNER
#   (alexsiri7), as GitHub's API reports it. A direct push, a factory pull
#   request, or an API failure holds it as before.
#
#   After such a fast-forward (a tick or --approve) whose range changes
#   ops/host/** (or ops/cron/archon-projects.txt), the script installs it itself, as the owner did by hand
#   (#182): `sudo -n archon-ops-promote`, then, only if that succeeded,
#   `sudo -n archon-user-install` (asiri's NOPASSWD rules allow exactly these).
#   Each command and its exit status go to the log; a failure sends one ntfy
#   and leaves the checkout where it is. This trusts nothing new: only commits
#   this script has already let in get installed. Asiri mode installs nothing
#   (it pulls ops/** unreviewed). Promote refuses anything but HEAD on origin/main.
#
# Env: OPS_CHECKOUT (default: the repo this script lives in), OPS_APPROVED_FILE,
# OPS_SELF_UPDATE_STATE (held-notice markers), ARCHON_CRON_SECRETS (NTFY_TOPIC),
# OPS_PROMOTE / OPS_USER_INSTALL (the two sudo entrypoints; tests point them elsewhere).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-as.sh
source "$SCRIPT_DIR/lib/run-as.sh"
REPO="${OPS_CHECKOUT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
APPROVED_FILE="${OPS_APPROVED_FILE:-$HOME/.config/archon-cron/ops-approved}"
STATE="${OPS_SELF_UPDATE_STATE:-$HOME/.local/state/archon-cron/ops-self-update}"
GUARDED_PATHS=(ops/)
OPS_OWNER="${OPS_OWNER:-alexsiri7}"
OPS_REPO="${OPS_REPO:-alexsiri7/interstellarai.net}"
# What the root installer reads from the promoted snapshot: ops/host, and the
# project list it writes to /etc/archon-user/projects.
HOST_PATHS=(ops/host/ ops/cron/archon-projects.txt)
OPS_PROMOTE="${OPS_PROMOTE:-/usr/local/sbin/archon-ops-promote}"
OPS_USER_INSTALL="${OPS_USER_INSTALL:-/usr/local/sbin/archon-user-install}"
DRY_RUN=0
[ "${1:-}" = --dry-run ] && DRY_RUN=1

log() { echo "$(date -Is) [ops-self-update] $*"; }

# notify <title> <tags> <message> — one high-priority ntfy to NTFY_TOPIC, if set.
notify() {
  local secrets topic
  secrets="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
  topic=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?NTFY_TOPIC=["'\'']?([^"'\''[:space:]#]*).*/\2/p' "$secrets" 2>/dev/null | tail -1)
  [ -n "$topic" ] || return 0
  curl -fsS -m 15 -H "Title: $1" -H "Priority: high" -H "Tags: $2" -d "$3" \
    "https://ntfy.sh/$topic" >/dev/null 2>&1 || log "ntfy failed"
}

if ! runas_archon && [ "${1:-}" != --approve ]; then
  [ "$DRY_RUN" -eq 1 ] && { echo "DRY-RUN: would run: git -C $REPO pull --ff-only -q origin main"; exit 0; }
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

# install_host — after the fast-forward: when head..target changed ops/host/,
# (HOST_PATHS) promote the new checkout and re-run the user install, in that order, stopping
# at the first failure (one ntfy naming it). 0 when nothing failed.
install_host() {
  local cmd out rc
  [ -n "$(git -C "$REPO" diff --name-only "$head" "$target" -- "${HOST_PATHS[@]}")" ] || return 0
  for cmd in "$OPS_PROMOTE" "$OPS_USER_INSTALL"; do
    if [ "$DRY_RUN" -eq 1 ]; then echo "DRY-RUN: would run: sudo -n $cmd"; continue; fi
    log "ops/host changed: + sudo -n $cmd"
    out=$(sudo -n "$cmd" 2>&1); rc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
      log "sudo -n $cmd failed (exit $rc); checkout left at ${target:0:10}, run it by hand"
      notify "ops/host install failed" "warning" \
        "sudo -n $cmd exited $rc after fast-forwarding to ${target:0:10}: $(printf '%s\n' "$out" | tail -1). Run it by hand at the console."
      return 1
    fi
    log "sudo -n $cmd: ok"
  done
  return 0
}

# fast_forward — merge to $target (only say so under --dry-run), install
# ops/host if it changed, and exit.
fast_forward() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: would fast-forward to $target"
  else
    git -C "$REPO" merge --ff-only -q "$target" || exit $?
  fi
  install_host
  exit $?
}

if [ "${1:-}" = --approve ]; then
  if [ -z "$guarded" ]; then
    echo "nothing under ${GUARDED_PATHS[*]} changed; the next tick fast-forwards on its own"
    exit 0
  fi
  git -C "$REPO" --no-pager log --stat "$head..$target" -- "${GUARDED_PATHS[@]}"
  git -C "$REPO" --no-pager diff "$head" "$target" -- "${GUARDED_PATHS[@]}"
  printf '\nThis runs as %s from cron (and, if ops/host changed, promotes and installs it as root right after). Approve %s? [y/N] ' "$(id -un)" "$target"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "not approved"; exit 1; }
  mkdir -p "$(dirname "$APPROVED_FILE")"
  ( umask 077; echo "$target" >> "$APPROVED_FILE" )
  git -C "$REPO" merge --ff-only -q "$target" || exit $?
  echo "approved and fast-forwarded to $target"
  install_host
  exit $?
fi

if [ -z "$guarded" ] || grep -qxF "$target" "$APPROVED_FILE" 2>/dev/null; then
  fast_forward
fi

# owner_authored — 0 when every commit in head..target touching the guarded
# paths merged a pull request whose author is OPS_OWNER.
owner_authored() {
  local sha author
  for sha in $(git -C "$REPO" rev-list "$head..$target" -- "${GUARDED_PATHS[@]}"); do
    author=$(gh api "repos/$OPS_REPO/commits/$sha/pulls" \
      --jq "[.[] | select(.merged_at != null and .merge_commit_sha == \"$sha\")][0].user.login" \
      2>/dev/null) || return 1
    [ "$author" = "$OPS_OWNER" ] || { log "$sha: not a pull request by $OPS_OWNER (${author:-none})"; return 1; }
  done
  return 0
}

if owner_authored; then
  log "fast-forwarding to $target: every ops/ change is a pull request by $OPS_OWNER"
  fast_forward
fi

n=$(wc -l <<<"$guarded")
[ "$DRY_RUN" -eq 1 ] && { echo "DRY-RUN: would hold origin/main $target ($n file(s) under ${GUARDED_PATHS[*]}) for --approve"; exit 0; }
mkdir -p "$STATE"
if [ ! -e "$STATE/held-$target" ]; then
  : > "$STATE/held-$target"
  log "holding origin/main $target: $n file(s) under ${GUARDED_PATHS[*]} changed — approve with: $SCRIPT_DIR/ops-self-update.sh --approve"
  notify "ops update held for review" "lock" \
    "origin/main ${target:0:10} changes $n file(s) under ops/ — the cron runs these as asiri. Review and approve at the console: ops/cron/ops-self-update.sh --approve"
fi
exit 0
