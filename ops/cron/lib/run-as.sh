#!/usr/bin/env bash
# Which Unix user the factory's agent sessions run as — the ARCHON_RUN_AS flag.
#
#   source "$SCRIPT_DIR/lib/run-as.sh"     # right after SCRIPT_DIR, before
#                                          # lib/archon-active-runs.sh
#
# Modes (see ops/host/archon-user/README.md):
#   asiri  (default, also when unset) — today's behaviour, byte for byte: the
#          cron scripts run `archon` as asiri, nothing here changes PATH or
#          any call.
#   drain  — cutover in progress: the launching scripts skip their tick
#          (runas_may_launch), `archon workflow run` is refused by the shim,
#          everything else still runs as asiri so live runs can finish.
#   archon — every `archon` call goes through ops/cron/lib/archon-shim/archon
#          (first on PATH) -> sudo -n -u archon /usr/local/bin/archon-as-archon,
#          so agents run as the unprivileged `archon` user with its own Claude
#          and GitHub credentials, its own ~/.archon (DB, worktrees) and its
#          own clones. The helpers below switch the few things that differ.
#
# The flag lives outside this repo, in the owner's 0700 config dir, so it is
# flipped without a PR and archon cannot flip it:
#   $ARCHON_RUN_AS_FILE (default ~/.config/archon-cron/run-as), one line
#   ARCHON_RUN_AS=asiri|drain|archon
# The environment variable ARCHON_RUN_AS wins over the file. Under bats the
# file is ignored (tests must not follow the host's live flag); set
# ARCHON_RUN_AS explicitly in a test to exercise a mode.

[ -n "${_ARCHON_RUN_AS_SH:-}" ] && return 0
_ARCHON_RUN_AS_SH=1

ARCHON_RUN_AS_FILE="${ARCHON_RUN_AS_FILE:-$HOME/.config/archon-cron/run-as}"
ARCHON_AS_WRAPPER="${ARCHON_AS_WRAPPER:-/usr/local/bin/archon-as-archon}"
ARCHON_AS_USER="${ARCHON_AS_USER:-archon}"
ARCHON_SERVE_UNIT="${ARCHON_SERVE_UNIT:-archon-serve.service}"

# runas_read_flag — prints the configured mode (asiri|drain|archon).
runas_read_flag() {
  local mode="${ARCHON_RUN_AS:-}"
  if [ -z "$mode" ] && [ -z "${BATS_TEST_FILENAME:-}" ] && [ -r "$ARCHON_RUN_AS_FILE" ]; then
    mode=$(sed -nE 's/^[[:space:]]*ARCHON_RUN_AS=["'\'']?([a-z]+)["'\'']?[[:space:]]*(#.*)?$/\1/p' "$ARCHON_RUN_AS_FILE" | tail -n 1)
  fi
  case "$mode" in
    archon|drain) echo "$mode" ;;
    *) echo asiri ;;
  esac
}

ARCHON_RUN_AS="$(runas_read_flag)"
export ARCHON_RUN_AS

runas_archon() { [ "$ARCHON_RUN_AS" = archon ]; }
runas_drain()  { [ "$ARCHON_RUN_AS" = drain ]; }

# In archon and drain mode the shim answers every `archon` call; the per-tick
# run snapshot moves out of /tmp (archon could pre-create a file there and make
# the owner's write fail; a DoS, but a cheap one to close).
if runas_archon || runas_drain; then
  PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archon-shim:$PATH"
  export PATH
  if [ -z "${ARCHON_RUNS_SNAPSHOT:-}" ]; then
    mkdir -p "$HOME/.local/state/archon-cron" 2>/dev/null || true
    ARCHON_RUNS_SNAPSHOT="$HOME/.local/state/archon-cron/.archon-active-runs.$(basename "${0:-tick}" .sh)"
  fi
fi

# runas_may_launch <script-name> — false (and one log line) while draining:
# the scripts that start archon runs skip the whole tick so the run list can
# empty out before the cutover moves the engine state.
runas_may_launch() {
  if runas_drain; then
    echo "$(date -Is) [run-as] $1: draining for the archon-user cutover (ARCHON_RUN_AS=drain) — no launches this tick"
    return 1
  fi
  return 0
}

# runas_wrapper <verb> [args...] — the factory user's door (see archon-as-archon).
runas_wrapper() {
  sudo -n -u "$ARCHON_AS_USER" "$ARCHON_AS_WRAPPER" "$@"
}

# runas_serve_restart [unit] — restart the archon server wherever it runs:
# the owner's user unit today, the system unit (User=archon) after cutover,
# through the one systemctl shape /etc/sudoers.d/archon-user grants.
runas_serve_restart() {
  local unit="${1:-$ARCHON_SERVE_UNIT}"
  if runas_archon; then
    sudo -n /usr/bin/systemctl restart "$unit"
  else
    systemctl --user restart "$unit"
  fi
}

# runas_claude_accounts — the Claude accounts cron probes and sweeps with.
# Under archon it is the factory user's own credential ("archon"), whatever
# CLAUDE_ACCOUNTS says; otherwise CLAUDE_ACCOUNTS unchanged.
runas_claude_accounts() {
  if runas_archon; then echo archon; else echo "${CLAUDE_ACCOUNTS:-}"; fi
}

# runas_merge_blocked <project> <pr> — under archon, a PR on the ops repo that
# touches ops/** or .github/** is never auto-merged: the crontab runs ops/cron
# as asiri out of that repo's main within 10 minutes, and ops/host is what the
# owner runs as root, so merging it would hand archon-written code the owner's
# secrets. Prints the reason and returns 0 when the merge must wait for a human;
# fails closed when the file list cannot be read. Always 1 outside archon mode.
ARCHON_RUNAS_PROTECTED_REPOS="${ARCHON_RUNAS_PROTECTED_REPOS:-interstellarai.net}"
runas_merge_blocked() {
  local project="$1" pr="$2" files hits
  runas_archon || return 1
  case " $ARCHON_RUNAS_PROTECTED_REPOS " in *" $project "*) ;; *) return 1 ;; esac
  if ! files=$(gh pr diff "$pr" --repo "alexsiri7/$project" --name-only 2>/dev/null); then
    echo "cannot list the files of PR #$pr — not merging a possibly privileged change blind"
    return 0
  fi
  hits=$(grep -E '^(ops/|\.github/)' <<<"$files" | head -n 5 | tr '\n' ' ')
  if [ -n "$hits" ]; then
    echo "touches ${hits}— code the owner's cron or install runs; needs a human merge"
    return 0
  fi
  return 1
}
