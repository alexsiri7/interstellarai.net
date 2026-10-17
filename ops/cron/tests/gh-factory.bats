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
    # `api user --jq .login` prints $STUB_LOGIN.
    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s HOME=%s\n' "$*" "$HOME" >> "$ARGV"
case "$*" in
  "api rate_limit") cat "$T/rate_limit.json"; exit "${STUB_GH_RC:-0}" ;;
  "api user --jq .login") echo "${STUB_LOGIN-alexsiri7-factory}" ;;
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
    # curl -s -o /dev/null --max-time 15 -w %{http_code} <url> → $STUB_PROFILE_CODE
    cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$ARGV"
printf '%s' "${STUB_PROFILE_CODE:-200}"
STUB
    chmod +x "$T/bin/gh" "$T/bin/sudo" "$T/bin/curl"
    rate_limit 5000 4800 5000

    export ARCHON_RUN_AS=asiri
    unset _GH_FACTORY_SH
    # shellcheck source=../lib/gh-factory.sh
    source "$CRON_DIR/lib/gh-factory.sh"
}

teardown() { rm -rf "$T"; }

rate_limit() {  # rate_limit <graphql limit> <graphql remaining> <core limit>
    printf '{"resources":{"core":{"limit":%s,"remaining":%s,"reset":1792183905},"graphql":{"limit":%s,"remaining":%s,"reset":1792183905}}}\n' \
        "$3" "$3" "$1" "$2" > "$T/rate_limit.json"
}

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
    [ -z "$output" ]
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

@test "check_gh_factory: blocked alerts once per episode, recovery clears it" {
    load_check
    rate_limit 0 0 60
    run check_gh_factory
    [ "$(wc -l < "$NTFY_SENT")" -eq 1 ]
    grep -q 'Factory GitHub identity blocked | alexsiri7-factory, as asiri: GraphQL limit 0' "$NTFY_SENT"
    grep -q '| urgent$' "$NTFY_SENT"
    [ -f "$T/state/gh-factory-alerted" ]
    run check_gh_factory
    [[ "$output" == *"gh-factory: BLOCKED"* ]]
    [ "$(wc -l < "$NTFY_SENT")" -eq 1 ]       # the marker holds the repeat

    rate_limit 5000 5000 5000
    run check_gh_factory
    [[ "$output" == *"gh-factory: recovered"* ]]
    [ ! -f "$T/state/gh-factory-alerted" ]

    rate_limit 0 0 60
    run check_gh_factory
    [ "$(wc -l < "$NTFY_SENT")" -eq 2 ]       # a new episode alerts again
}

@test "check_gh_factory: an undelivered ntfy is retried next tick" {
    load_check
    rate_limit 0 0 60
    export STUB_NTFY_RC=1
    run check_gh_factory
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

@test "pipeline-health runs check_gh_factory every tick" {
    grep -qx 'check_gh_factory' "$CRON_DIR/pipeline-health-cron.sh"
}

@test "issue-pickup sets GH_FACTORY_HELD from gh_factory_may_launch" {
    grep -q '^gh_factory_may_launch "issue-pickup" || GH_FACTORY_HELD=1$' "$CRON_DIR/issue-pickup-cron.sh"
}
