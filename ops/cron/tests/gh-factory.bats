#!/usr/bin/env bats
# ops/cron/lib/gh-factory.sh (is the factory's GitHub identity usable?) and its
# callers: check_gh_factory in pipeline-health-cron.sh (ntfy once per episode)
# and the gh_factory_may_launch hold in issue-pickup-cron.sh.
#
# Run: bunx bats ops/cron/tests/gh-factory.bats

setup() {
    export T="$BATS_TMPDIR/gh-factory-$$"
    rm -rf "$T"
    mkdir -p "$T/bin" "$T/state"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PATH="$T/bin:$PATH"
    export ARGV="$T/argv"
    : > "$ARGV"

    # gh: `api rate_limit` prints $T/rate_limit.json (exit $STUB_GH_RC),
    # `api user --jq .login` prints $STUB_LOGIN. The owner account (alexsiri7):
    # `auth token -u alexsiri7` prints $STUB_OWNER_TOKEN, `api rate_limit` with
    # that GH_TOKEN, or after `auth switch -u alexsiri7`, prints
    # $T/owner_rate_limit.json — after the switch, $STUB_SWITCHED_FAIL instead
    # makes it fail with that message.
    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s HOME=%s\n' "$*" "$HOME" >> "$ARGV"
owner=0
{ [ -n "${GH_TOKEN:-}" ] && [ "$GH_TOKEN" = "${STUB_OWNER_TOKEN-tok-owner}" ]; } && owner=1
[ "$(cat "$T/active" 2>/dev/null)" = alexsiri7 ] && owner=1
case "$*" in
  "api rate_limit")
    if [ "$owner" = 1 ] && [ -z "${GH_TOKEN:-}" ] && [ -n "${STUB_SWITCHED_FAIL:-}" ]; then
      echo "$STUB_SWITCHED_FAIL" >&2; exit 1
    fi
    if [ "$owner" = 1 ]; then cat "$T/owner_rate_limit.json"; exit 0; fi
    cat "$T/rate_limit.json"; exit "${STUB_GH_RC:-0}" ;;
  "api user --jq .login")
    if [ "$owner" = 1 ]; then echo alexsiri7; else echo "${STUB_LOGIN-alexsiri7-factory}"; fi ;;
  "auth token -u alexsiri7")
    [ -n "${STUB_OWNER_TOKEN-tok-owner}" ] || { echo "no oauth token found for alexsiri7" >&2; exit 1; }
    echo "${STUB_OWNER_TOKEN-tok-owner}" ;;
  "auth switch -u alexsiri7")
    [ "${STUB_SWITCH_RC:-0}" = 0 ] || { echo "switch refused" >&2; exit 1; }
    echo alexsiri7 > "$T/active" ;;
esac
STUB
    # sudo -n -u <user> env HOME=<home> gh ...: record, then run the rest.
    cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$ARGV"
[ "$1" = -n ] && [ "$2" = -u ] || exit 1
shift 3
exec "$@"
STUB
    # curl -s -o /dev/null --max-time 15 -w %{http_code} <url> → $STUB_PROFILE_CODE;
    # an ntfy.sh post (its -d body) goes to $T/ntfy-curl.
    cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$ARGV"
if [[ "$*" == *ntfy.sh/* ]]; then
  while [ $# -gt 0 ]; do [ "$1" = -d ] && printf '%s\n' "$2" >> "$T/ntfy-curl"; shift; done
  exit 0
fi
printf '%s' "${STUB_PROFILE_CODE:-200}"
STUB
    chmod +x "$T/bin/gh" "$T/bin/sudo" "$T/bin/curl"
    rate_limit 5000 4800 5000
    owner_rate_limit 5000 5000 5000
    mkdir -p "$T/gh"
    touch -d '2026-11-07 10:29:00 UTC' "$T/gh/hosts.yml"
    export GH_CONFIG_DIR="$T/gh" NTFY_TOPIC=test-topic
    export GH_FACTORY_SWITCH_LOCK="$T/state/gh-factory-switch.lock"

    export ARCHON_RUN_AS=asiri
    unset _GH_FACTORY_SH
    # shellcheck source=../lib/gh-factory.sh
    source "$CRON_DIR/lib/gh-factory.sh"
}

teardown() { rm -rf "$T"; }

rate_limit() {  # rate_limit <graphql limit> <graphql remaining> <core limit> [file]
    printf '{"resources":{"core":{"limit":%s,"remaining":%s,"reset":1792183905},"graphql":{"limit":%s,"remaining":%s,"reset":1792183905}}}\n' \
        "$3" "$3" "$1" "$2" > "$T/${4:-rate_limit.json}"
}

owner_rate_limit() { rate_limit "$@" owner_rate_limit.json; }  # the owner account's token

@test "a healthy identity is ok" {
    gh_factory_probe
    [ "$GH_FACTORY_STATE" = ok ]
    [ "$GH_FACTORY_GRAPHQL" = "4800/5000" ]
    [ "$GH_FACTORY_LOGIN" = alexsiri7-factory ]
    grep -q '^curl .*https://github.com/alexsiri7-factory$' "$ARGV"
}

@test "asiri mode probes the owner's gh directly; archon and drain go through sudo -u archon with archon's HOME" {
    gh_factory_probe
    ! grep -q '^sudo' "$ARGV"
    for mode in archon drain; do
        : > "$ARGV"
        ARCHON_RUN_AS=$mode gh_factory_probe
        grep -q '^sudo -n -u archon env HOME=/mnt/ext-fast/archon-home gh api rate_limit$' "$ARGV"
        grep -q '^gh api rate_limit HOME=/mnt/ext-fast/archon-home$' "$ARGV"
    done
}

@test "the 2026-10-16 state (graphql limit 0, core 60, profile 404) is blocked with all three reasons" {
    rate_limit 0 0 60
    export STUB_PROFILE_CODE=404
    run gh_factory_probe
    [ "$status" -eq 1 ]
    gh_factory_probe || true
    [ "$GH_FACTORY_STATE" = blocked ]
    [[ "$GH_FACTORY_DETAIL" == *"GraphQL limit 0"* ]]
    [[ "$GH_FACTORY_DETAIL" == *"REST core limit 60"* ]]
    [[ "$GH_FACTORY_DETAIL" == *"github.com/alexsiri7-factory is 404"* ]]
    [[ "$GH_FACTORY_DETAIL" == *"; "* ]]
}

@test "GraphQL nearly used up is blocked until its reset" {
    rate_limit 5000 150 5000
    gh_factory_probe || true
    [ "$GH_FACTORY_STATE" = blocked ]
    [[ "$GH_FACTORY_DETAIL" == "GraphQL 150/5000 left, resets "* ]]
}

@test "only a 404 profile counts: a 429 or no answer is not evidence" {
    for code in 429 000 503; do
        STUB_PROFILE_CODE=$code gh_factory_probe
        [ "$GH_FACTORY_STATE" = ok ]
    done
}

@test "no login: the profile is not checked" {
    export STUB_LOGIN=""
    gh_factory_probe
    [ "$GH_FACTORY_STATE" = ok ]
    ! grep -q '^curl' "$ARGV"
}

@test "a failing probe is unknown and does not hold launches" {
    export STUB_GH_RC=1
    echo "sudo: a password is required" > "$T/rate_limit.json"
    run gh_factory_probe
    [ "$status" -eq 2 ]
    run gh_factory_may_launch issue-pickup
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not probe"*"not holding launches"* ]]
}

@test "garbage from gh is unknown, not ok" {
    echo '{"message":"Bad credentials"}' > "$T/rate_limit.json"
    run gh_factory_probe
    [ "$status" -eq 2 ]
}

@test "gh_factory_may_launch holds while blocked and says why" {
    rate_limit 0 0 60
    run gh_factory_may_launch issue-pickup
    [ "$status" -eq 1 ]
    [[ "$output" == *"issue-pickup: factory GitHub identity (alexsiri7-factory, as asiri) cannot open PRs: GraphQL limit 0"* ]]
    rate_limit 5000 5000 5000
    run gh_factory_may_launch issue-pickup
    [ "$status" -eq 0 ]
    [[ "$output" != *"no launches"* ]]
}

@test "every gate check logs the active account and when hosts.yml last changed" {
    run gh_factory_may_launch issue-pickup
    [ "$status" -eq 0 ]
    [[ "$output" == *"[gh-factory] issue-pickup: active account alexsiri7-factory, as asiri, ok; hosts.yml modified 2026-11-07T"* ]]
    rm "$T/gh/hosts.yml"
    run gh_factory_may_launch issue-pickup
    [[ "$output" == *"hosts.yml modified ?"* ]]
}

# ── switching to the owner account (#272) ────────────────────────────────────

@test "blocked in archon mode with a working owner token: switch to the owner, ntfy once, launch" {
    export ARCHON_RUN_AS=archon
    rate_limit 0 0 60
    run gh_factory_may_launch issue-pickup
    [ "$status" -eq 0 ]
    [ "$(cat "$T/active")" = alexsiri7 ]
    grep -q '^gh auth switch -u alexsiri7 HOME=/mnt/ext-fast/archon-home$' "$ARGV"
    [[ "$output" == *"Switched the factory GitHub account from alexsiri7-factory (GraphQL limit 0"*") to alexsiri7, now ok"* ]]
    [[ "$output" != *"no launches"* ]]
    [ "$(wc -l < "$T/ntfy-curl")" -eq 1 ]
    grep -q 'from alexsiri7-factory .* to alexsiri7, now ok: .* hosts.yml was last changed 2026-11-07T' "$T/ntfy-curl"
    ! grep -q 'tok-owner' "$ARGV"            # the token never reaches an argv

    : > "$ARGV"
    run gh_factory_may_launch issue-pickup   # the owner is active now: nothing to do
    [ "$status" -eq 0 ]
    [[ "$output" == *"active account alexsiri7, as archon, ok"* ]]
    ! grep -q '^gh auth' "$ARGV"
    [ "$(wc -l < "$T/ntfy-curl")" -eq 1 ]
}

@test "blocked with no working owner token: hold, never switch, no ntfy from the gate" {
    export ARCHON_RUN_AS=archon
    rate_limit 0 0 60
    # throttled and low: the probe's own bars (core limit 1000, GraphQL 200 left), not just a flag
    for owner in missing flagged throttled low; do
        : > "$ARGV"
        unset STUB_OWNER_TOKEN
        case $owner in
          missing)   export STUB_OWNER_TOKEN="" ;;
          flagged)   owner_rate_limit 0 0 60 ;;
          throttled) owner_rate_limit 5000 5000 100 ;;
          low)       owner_rate_limit 5000 150 5000 ;;
        esac
        run gh_factory_may_launch issue-pickup
        [ "$status" -eq 1 ]
        [[ "$output" == *"no working alexsiri7 token"*"no launches this tick"* ]]
        grep -q '^gh auth token -u alexsiri7' "$ARGV"
        ! grep -q '^gh auth switch' "$ARGV"
        [ ! -e "$T/ntfy-curl" ]
    done
}

@test "a switch whose re-probe cannot tell does not hold the launch" {
    export ARCHON_RUN_AS=archon STUB_SWITCHED_FAIL="HTTP 502: Bad Gateway"
    rate_limit 0 0 60
    run gh_factory_may_launch issue-pickup
    [ "$status" -eq 0 ]
    [ "$(cat "$T/active")" = alexsiri7 ]
    [[ "$output" == *"to alexsiri7, now unknown: gh api rate_limit failed: HTTP 502: Bad Gateway"* ]]
    [[ "$output" == *"could not probe"*"not holding launches"* ]]
    [ "$(wc -l < "$T/ntfy-curl")" -eq 1 ]
}

@test "a switch waits for another writer's lock and does not switch or announce again" {
    export ARCHON_RUN_AS=archon
    rate_limit 0 0 60
    gh_factory_probe || true                 # the caller saw the factory account blocked
    mkdir -p "$(dirname "$GH_FACTORY_SWITCH_LOCK")"
    ( exec 8>"$GH_FACTORY_SWITCH_LOCK"; flock 8; touch "$T/locked"; sleep 1; echo alexsiri7 > "$T/active" ) &
    until [ -e "$T/locked" ]; do sleep 0.1; done
    run gh_factory_try_switch issue-pickup
    wait
    [ "$status" -eq 0 ]
    ! grep -q '^gh auth' "$ARGV"
    [ ! -e "$T/ntfy-curl" ]
}

@test "a refused gh auth switch holds and says why" {
    export ARCHON_RUN_AS=archon STUB_SWITCH_RC=1
    rate_limit 0 0 60
    run gh_factory_may_launch issue-pickup
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh auth switch -u alexsiri7 failed: switch refused"*"no launches this tick"* ]]
    [ ! -e "$T/ntfy-curl" ]
}

@test "no switch when the active account is healthy, already the owner, unreadable, or in asiri mode" {
    export ARCHON_RUN_AS=archon
    run gh_factory_may_launch issue-pickup               # healthy
    [ "$status" -eq 0 ]
    rate_limit 0 0 60
    STUB_LOGIN=alexsiri7 run gh_factory_may_launch issue-pickup   # the owner itself is blocked
    [ "$status" -eq 1 ]
    STUB_LOGIN="" run gh_factory_may_launch issue-pickup          # who is active is unknown
    [ "$status" -eq 1 ]
    ARCHON_RUN_AS=asiri run gh_factory_may_launch issue-pickup    # the owner's own gh
    [ "$status" -eq 1 ]
    ! grep -q '^gh auth' "$ARGV"
    [ ! -e "$T/active" ]
    [ ! -e "$T/ntfy-curl" ]
}

# ── check_gh_factory (pipeline-health-cron.sh) ───────────────────────────────

load_check() {
    STATE_DIR="$T/state"
    export NTFY_SENT="$T/ntfy"
    log() { echo "$*"; }
    notify_checked() { echo "$1 | $2 | $3" >> "$NTFY_SENT"; return "${STUB_NTFY_RC:-0}"; }
    # shellcheck disable=SC1090
    source <(awk '/^check_gh_factory\(\)/{p=1} p{print} p && /^}$/{p=0}' "$CRON_DIR/pipeline-health-cron.sh")
}

@test "check_gh_factory: blocked alerts after 2 consecutive ticks, recovery clears it" {
    load_check
    rate_limit 0 0 60
    run check_gh_factory
    [ ! -e "$NTFY_SENT" ]                     # first held tick: no alert yet
    [[ "$output" == *"gh-factory: held"* ]]
    [ -f "$T/state/gh-factory-held" ]
    [ ! -f "$T/state/gh-factory-alerted" ]

    run check_gh_factory
    [ "$(wc -l < "$NTFY_SENT")" -eq 1 ]        # second consecutive tick: alerts
    grep -q 'factory launches held: GitHub identity blocked | alexsiri7-factory, as asiri: GraphQL limit 0' "$NTFY_SENT"
    grep -q '| urgent$' "$NTFY_SENT"
    [ -f "$T/state/gh-factory-alerted" ]

    run check_gh_factory
    [[ "$output" == *"gh-factory: BLOCKED"* ]]
    [ "$(wc -l < "$NTFY_SENT")" -eq 1 ]       # the marker holds the repeat

    rate_limit 5000 5000 5000
    run check_gh_factory
    [[ "$output" == *"gh-factory: recovered"* ]]
    [ ! -f "$T/state/gh-factory-alerted" ]
    [ ! -f "$T/state/gh-factory-held" ]

    rate_limit 0 0 60
    run check_gh_factory
    [ "$(wc -l < "$NTFY_SENT")" -eq 1 ]       # a new episode's first tick holds, not alerts
    run check_gh_factory
    [ "$(wc -l < "$NTFY_SENT")" -eq 2 ]       # its second tick alerts again
}

@test "check_gh_factory: an undelivered ntfy is retried next tick" {
    load_check
    rate_limit 0 0 60
    export STUB_NTFY_RC=1
    run check_gh_factory                      # first held tick: no ntfy attempt yet
    [ ! -e "$NTFY_SENT" ]
    run check_gh_factory                      # second tick: attempts, fails
    [ ! -f "$T/state/gh-factory-alerted" ]
    [[ "$output" == *"ntfy not delivered"* ]]
}

@test "check_gh_factory: a failed probe is logged, never alerted, and keeps an open episode open" {
    load_check
    touch "$T/state/gh-factory-alerted"
    export STUB_GH_RC=1
    run check_gh_factory
    [[ "$output" == *"gh-factory: probe failed"* ]]
    [ ! -e "$NTFY_SENT" ]
    [ -f "$T/state/gh-factory-alerted" ]
}

@test "check_gh_factory: a blocked account the owner switch fixes is no episode" {
    load_check
    export ARCHON_RUN_AS=archon
    touch "$T/state/gh-factory-alerted"
    rate_limit 0 0 60
    run check_gh_factory
    [ "$status" -eq 0 ]
    [ "$(cat "$T/active")" = alexsiri7 ]
    [ ! -e "$NTFY_SENT" ]                      # no "blocked" alert
    [ "$(wc -l < "$T/ntfy-curl")" -eq 1 ]      # the switch's own ntfy
    [[ "$output" == *"gh-factory: recovered — alexsiri7, as archon"* ]]
    [ ! -f "$T/state/gh-factory-alerted" ]
}

@test "check_gh_factory: a switch whose re-probe cannot tell is logged, not alerted as blocked" {
    load_check
    export ARCHON_RUN_AS=archon STUB_SWITCHED_FAIL="HTTP 502: Bad Gateway"
    rate_limit 0 0 60
    run check_gh_factory
    [ "$status" -eq 0 ]
    [[ "$output" == *"gh-factory: probe failed — gh api rate_limit failed: HTTP 502: Bad Gateway"* ]]
    [[ "$output" != *"BLOCKED"* ]]
    [ ! -e "$NTFY_SENT" ]
    [ "$(wc -l < "$T/ntfy-curl")" -eq 1 ]      # the switch's own ntfy
}

@test "check_gh_factory: blocked with no owner token to switch to alerts after 2 consecutive ticks" {
    load_check
    export ARCHON_RUN_AS=archon STUB_OWNER_TOKEN=""
    rate_limit 0 0 60
    run check_gh_factory
    [ ! -e "$NTFY_SENT" ]                     # first held tick: no alert yet
    run check_gh_factory
    [ "$(wc -l < "$NTFY_SENT")" -eq 1 ]        # second consecutive tick: alerts
    grep -q 'factory launches held: GitHub identity blocked | alexsiri7-factory, as archon: GraphQL limit 0' "$NTFY_SENT"
    ! grep -q '^gh auth switch' "$ARGV"
}

@test "pipeline-health runs check_gh_factory every tick" {
    grep -qx 'check_gh_factory' "$CRON_DIR/pipeline-health-cron.sh"
}

@test "issue-pickup sets GH_FACTORY_HELD from gh_factory_may_launch" {
    grep -q '^gh_factory_may_launch "issue-pickup" || GH_FACTORY_HELD=1$' "$CRON_DIR/issue-pickup-cron.sh"
}
