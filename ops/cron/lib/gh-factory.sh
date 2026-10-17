#!/usr/bin/env bash
# Can the factory's GitHub identity still work? Probed from the cron scripts.
#
#   source "$SCRIPT_DIR/lib/gh-factory.sh"     # after lib/run-as.sh
#   gh_factory_probe                           # sets GH_FACTORY_* below; 0 ok, 1 blocked, 2 unknown
#   gh_factory_may_launch "<script>" || <skip the launch>
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

[ -n "${_GH_FACTORY_SH:-}" ] && return 0
_GH_FACTORY_SH=1

GH_FACTORY_HOME="${GH_FACTORY_HOME:-/mnt/ext-fast/archon-home}"
GH_FACTORY_GRAPHQL_MIN="${GH_FACTORY_GRAPHQL_MIN:-200}"
GH_FACTORY_CORE_MIN_LIMIT="${GH_FACTORY_CORE_MIN_LIMIT:-1000}"
GH_FACTORY_TIMEOUT="${GH_FACTORY_TIMEOUT:-20}"
GH_FACTORY_PROFILE_BASE="${GH_FACTORY_PROFILE_BASE:-https://github.com}"

# gh_factory_as_archon — true when the factory's gh is the archon user's.
gh_factory_as_archon() {
  case "${ARCHON_RUN_AS:-asiri}" in archon|drain) return 0 ;; *) return 1 ;; esac
}

# gh_factory_gh <args...> — gh as the factory identity, bounded in time.
gh_factory_gh() {
  if gh_factory_as_archon; then
    timeout "$GH_FACTORY_TIMEOUT" sudo -n -u "${ARCHON_AS_USER:-archon}" env HOME="$GH_FACTORY_HOME" gh "$@" </dev/null
  else
    timeout "$GH_FACTORY_TIMEOUT" gh "$@" </dev/null
  fi
}

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

# gh_factory_may_launch <script> — false (and one log line) while the factory
# identity is blocked; true when it is fine or the probe could not tell.
gh_factory_may_launch() {
  gh_factory_probe
  case $? in
    1)
      echo "$(date -Is) [gh-factory] $1: factory GitHub identity ($(gh_factory_who)) cannot open PRs: $GH_FACTORY_DETAIL — no launches this tick"
      return 1 ;;
    2)
      echo "$(date -Is) [gh-factory] $1: could not probe the factory GitHub identity ($GH_FACTORY_DETAIL) — not holding launches"
      return 0 ;;
  esac
  return 0
}
