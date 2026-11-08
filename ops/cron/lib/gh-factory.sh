#!/usr/bin/env bash
# Can the factory's GitHub identity still work? Probed from the cron scripts.
#
#   source "$SCRIPT_DIR/lib/gh-factory.sh"     # after lib/run-as.sh
#   gh_factory_probe                           # sets GH_FACTORY_* below; 0 ok, 1 blocked, 2 unknown
#   gh_factory_may_launch "<script>" || <skip the launch>
#   gh_factory_try_switch "<script>"           # blocked: fall back to the owner account
#
# Why: from 2026-10-13 to 10-16 about 90% of factory runs failed with
# "GraphQL: API rate limit already exceeded for user ID 338831144" — GitHub had
# flagged alexsiri7-factory: `gh api rate_limit` showed graphql.limit 0 (and the
# REST core limit at 60, the unauthenticated value), and its public profile was
# a 404. pipeline-status and pipeline-health stayed green, and every run burned
# Claude tokens on work that could never open a PR.
#
# Which identity: in ARCHON_RUN_AS=archon (and drain, the way into and out of
# it) the factory's gh runs as the archon user with its own HOME, so the probe
# does too (sudo -n -u archon env HOME=$GH_FACTORY_HOME gh ...); in asiri mode
# it is the owner's own gh.
#
# Blocked (positive evidence only), any of:
#   - graphql.limit is 0
#   - graphql.remaining below GH_FACTORY_GRAPHQL_MIN (default 200) — until its reset
#   - core.limit below GH_FACTORY_CORE_MIN_LIMIT (default 1000; a working
#     token gets 5000, an unauthenticated or flagged one 60)
#   - the account's public profile (github.com/<login>) answers 404
# Unknown: the probe itself failed (sudo, gh, network, timeout). Unknown never
# holds a launch (the same rule as lib/quota-pause.sh: a gate that cannot read
# its evidence lets the per-run checks decide); pipeline-health logs it.
#
# Owner fallback (#272): since 2026-10-17 the factory runs as the owner's own
# account (GH_FACTORY_OWNER_LOGIN) on purpose, and archon's hosts.yml holds
# tokens for both. On 2026-11-07 something ran `gh auth switch` back to the
# flagged account and pickup held for 25h. So a blocked active account that is
# not the owner's is switched to the owner's when its stored token works, with
# one ntfy, under a lock the morning pass's own switch shares; every launch gate logs the active account and the hosts.yml mtime,
# so the next flip can be dated.

[ -n "${_GH_FACTORY_SH:-}" ] && return 0
_GH_FACTORY_SH=1

# shellcheck source=secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

GH_FACTORY_HOME="${GH_FACTORY_HOME:-/mnt/ext-fast/archon-home}"
GH_FACTORY_GRAPHQL_MIN="${GH_FACTORY_GRAPHQL_MIN:-200}"
GH_FACTORY_CORE_MIN_LIMIT="${GH_FACTORY_CORE_MIN_LIMIT:-1000}"
GH_FACTORY_TIMEOUT="${GH_FACTORY_TIMEOUT:-20}"
GH_FACTORY_PROFILE_BASE="${GH_FACTORY_PROFILE_BASE:-https://github.com}"
GH_FACTORY_OWNER_LOGIN="${GH_FACTORY_OWNER_LOGIN:-alexsiri7}"
GH_FACTORY_SWITCH_LOCK="${GH_FACTORY_SWITCH_LOCK:-$HOME/.archon/state/gh-factory-switch.lock}"

# gh_factory_as_archon — true when the factory's gh is the archon user's.
gh_factory_as_archon() {
  case "${ARCHON_RUN_AS:-asiri}" in archon|drain) return 0 ;; *) return 1 ;; esac
}

# _gh_factory_exec <cmd...> — cmd as the factory identity's OS user, bounded in time.
_gh_factory_exec() {
  if gh_factory_as_archon; then
    timeout "$GH_FACTORY_TIMEOUT" sudo -n -u "${ARCHON_AS_USER:-archon}" env HOME="$GH_FACTORY_HOME" "$@" </dev/null
  else
    timeout "$GH_FACTORY_TIMEOUT" "$@" </dev/null
  fi
}

# gh_factory_gh <args...> — gh as the factory identity, bounded in time.
gh_factory_gh() { _gh_factory_exec gh "$@"; }

# gh_factory_probe — sets
#   GH_FACTORY_STATE   ok | blocked | unknown
#   GH_FACTORY_LOGIN   the account's login ("" when it could not be read)
#   GH_FACTORY_GRAPHQL "<remaining>/<limit>" ("" when unknown)
#   GH_FACTORY_DETAIL  one line: why blocked / why unknown / a summary when ok
# Returns 0 ok, 1 blocked, 2 unknown. Call it directly, not in $( ).
# shellcheck disable=SC2034  # the GH_FACTORY_* results are read by the callers
gh_factory_probe() {
  GH_FACTORY_STATE=unknown GH_FACTORY_LOGIN="" GH_FACTORY_GRAPHQL="" GH_FACTORY_DETAIL=""
  local rl gl gr greset cl code
  local -a why=()
  if ! rl=$(gh_factory_gh api rate_limit 2>&1); then
    GH_FACTORY_DETAIL="gh api rate_limit failed: $(tail -n 1 <<<"$rl" | cut -c1-200)"
    return 2
  fi
  IFS=$'\t' read -r gl gr greset cl < <(jq -r '[.resources.graphql.limit, .resources.graphql.remaining,
      .resources.graphql.reset, .resources.core.limit] | @tsv' <<<"$rl" 2>/dev/null)
  if ! [[ "$gl" =~ ^[0-9]+$ && "$gr" =~ ^[0-9]+$ && "$cl" =~ ^[0-9]+$ ]]; then
    GH_FACTORY_DETAIL="gh api rate_limit: unexpected answer: $(head -c 200 <<<"$rl" | tr '\n' ' ')"
    return 2
  fi
  GH_FACTORY_GRAPHQL="$gr/$gl"
  if [ "$gl" -eq 0 ]; then
    why+=("GraphQL limit 0 (GitHub has cut the account off)")
  elif [ "$gr" -lt "$GH_FACTORY_GRAPHQL_MIN" ]; then
    why+=("GraphQL $gr/$gl left, resets $(date -d "@${greset:-0}" '+%H:%M' 2>/dev/null || echo '?')")
  fi
  [ "$cl" -lt "$GH_FACTORY_CORE_MIN_LIMIT" ] \
    && why+=("REST core limit $cl (a working token gets 5000)")

  GH_FACTORY_LOGIN=$(gh_factory_gh api user --jq .login 2>/dev/null) || GH_FACTORY_LOGIN=""
  [[ "$GH_FACTORY_LOGIN" =~ ^[A-Za-z0-9-]+$ ]] || GH_FACTORY_LOGIN=""
  if [ -n "$GH_FACTORY_LOGIN" ]; then
    # Only a 404 counts: anything else (429, 5xx, no network) proves nothing.
    code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "$GH_FACTORY_PROFILE_BASE/$GH_FACTORY_LOGIN" 2>/dev/null) || true
    [ "$code" = 404 ] && why+=("public profile $GH_FACTORY_PROFILE_BASE/$GH_FACTORY_LOGIN is 404 (account flagged)")
  fi

  if [ "${#why[@]}" -gt 0 ]; then
    GH_FACTORY_STATE=blocked
    local IFS=';'
    GH_FACTORY_DETAIL="${why[*]}"
    GH_FACTORY_DETAIL="${GH_FACTORY_DETAIL//;/; }"
    return 1
  fi
  GH_FACTORY_STATE=ok
  GH_FACTORY_DETAIL="GraphQL $gr/$gl, core limit $cl"
  return 0
}

# gh_factory_who — "alexsiri7-factory, as archon" for messages.
gh_factory_who() {
  local as=asiri
  gh_factory_as_archon && as="${ARCHON_AS_USER:-archon}"
  echo "${GH_FACTORY_LOGIN:-?}, as $as"
}

# gh_factory_hosts_mtime — when the factory gh's hosts.yml last changed, or "?".
gh_factory_hosts_mtime() {
  # shellcheck disable=SC2016  # expanded by the factory user's shell
  _gh_factory_exec sh -c 'date -Is -r "${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"' 2>/dev/null \
    || echo "?"
}

# _gh_factory_notify <title> <message> — one ntfy, logged when it cannot go out.
_gh_factory_notify() {
  [ -n "${NTFY_TOPIC:-}" ] || NTFY_TOPIC=$(secret_get NTFY_TOPIC)
  if [ -z "${NTFY_TOPIC:-}" ]; then
    echo "$(date -Is) [gh-factory] NTFY_TOPIC not set — logged only"
  elif ! curl -s --fail -o /dev/null -H "Title: $1" -H "Priority: high" -H "Tags: arrows_counterclockwise" \
      -d "$2" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null; then
    echo "$(date -Is) [gh-factory] ntfy not delivered"
  fi
}

# gh_factory_try_switch <script> — after gh_factory_probe found the active
# account blocked: when hosts.yml holds a token for GH_FACTORY_OWNER_LOGIN that
# passes the probe's own rate-limit bars, `gh auth switch` to it, re-probe and
# ntfy once. Only that account, never another, and only in archon or drain
# mode: in asiri mode the factory's gh is the owner's own. issue-pickup,
# pipeline-health and the morning pass can all reach for the switch in the same
# minute, so it holds GH_FACTORY_SWITCH_LOCK and re-probes under it: the
# account another writer just switched to is not switched or announced again.
# Returns like gh_factory_probe, for the account active when it returns.
gh_factory_try_switch() {
  local fd rc
  gh_factory_as_archon || return 1
  mkdir -p "$(dirname "$GH_FACTORY_SWITCH_LOCK")"
  exec {fd}>"$GH_FACTORY_SWITCH_LOCK"
  if flock -w "$((GH_FACTORY_TIMEOUT * 6))" "$fd"; then
    _gh_factory_switch_locked "$1"; rc=$?
  else
    echo "$(date -Is) [gh-factory] $1: another switch holds $GH_FACTORY_SWITCH_LOCK — not switching"
    rc=1
  fi
  exec {fd}>&-
  return "$rc"
}

_gh_factory_switch_locked() {
  local from reason rl err rc msg changed
  gh_factory_probe; rc=$?
  [ "$rc" -eq 1 ] || return "$rc"
  from="$GH_FACTORY_LOGIN" reason="$GH_FACTORY_DETAIL"
  # An unreadable login may already be the owner: switching would change nothing.
  [ -n "$from" ] && [ "$from" != "$GH_FACTORY_OWNER_LOGIN" ] || return 1
  # The token stays inside the factory user's own process, never on an argv.
  # shellcheck disable=SC2016
  if ! rl=$(_gh_factory_exec bash -c 'tok=$(gh auth token -u "$1" 2>/dev/null) && [ -n "$tok" ] && GH_TOKEN=$tok exec gh api rate_limit' \
        _ "$GH_FACTORY_OWNER_LOGIN" 2>/dev/null) \
     || ! jq -e --argjson gmin "$GH_FACTORY_GRAPHQL_MIN" --argjson cmin "$GH_FACTORY_CORE_MIN_LIMIT" \
          '.resources.graphql.limit > 0 and .resources.graphql.remaining >= $gmin and .resources.core.limit >= $cmin' \
          <<<"$rl" >/dev/null 2>&1; then
    echo "$(date -Is) [gh-factory] $1: no working $GH_FACTORY_OWNER_LOGIN token in the factory gh's hosts.yml — not switching"
    return 1
  fi
  changed=$(gh_factory_hosts_mtime)
  if ! err=$(gh_factory_gh auth switch -u "$GH_FACTORY_OWNER_LOGIN" 2>&1); then
    echo "$(date -Is) [gh-factory] $1: gh auth switch -u $GH_FACTORY_OWNER_LOGIN failed: $(tail -n 1 <<<"$err" | cut -c1-200)"
    return 1
  fi
  gh_factory_probe; rc=$?
  msg="Switched the factory GitHub account from $from ($reason) to $GH_FACTORY_OWNER_LOGIN, now $GH_FACTORY_STATE: $GH_FACTORY_DETAIL. hosts.yml was last changed $changed."
  echo "$(date -Is) [gh-factory] $1: $msg"
  _gh_factory_notify "Factory GitHub account switched" "$msg"
  return "$rc"
}

# gh_factory_may_launch <script> — logs the active account and the hosts.yml
# mtime, then false (and one log line) while the factory identity is blocked
# and no switch to the owner account fixed it; true when it is fine or the
# probe could not tell.
gh_factory_may_launch() {
  local rc
  gh_factory_probe; rc=$?
  echo "$(date -Is) [gh-factory] $1: active account $(gh_factory_who), $GH_FACTORY_STATE; hosts.yml modified $(gh_factory_hosts_mtime)"
  if [ "$rc" -eq 1 ]; then
    gh_factory_try_switch "$1"; rc=$?
  fi
  case $rc in
    1)
      echo "$(date -Is) [gh-factory] $1: factory GitHub identity ($(gh_factory_who)) cannot open PRs: $GH_FACTORY_DETAIL — no launches this tick"
      return 1 ;;
    2)
      echo "$(date -Is) [gh-factory] $1: could not probe the factory GitHub identity ($GH_FACTORY_DETAIL) — not holding launches"
      return 0 ;;
  esac
  return 0
}
