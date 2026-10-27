#!/usr/bin/env bats
# Tests for ops/cron/sweep-audits.sh: the audit Lachesis offers (or the
# fallback when no workflow runs its kind), the report_audit_run for each run,
# the Claude account preflight and its fallback, and the last-sweep summary
# ops/bin/pipeline-status reads.
#
# Runs the real script under a throwaway HOME. Stubs live in $HOME/.local/bin,
# which the script puts on PATH ahead of /usr/local/bin (where the real archon
# is installed).
#
# Run: bunx bats ops/cron/tests/sweep-audits.bats

SCRIPT="$BATS_TEST_DIRNAME/../sweep-audits.sh"

load doppler-stub

setup() {
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"
    export ARCHON_CRON_FORCE_TICK=1
    export ARCHON_CRON_SECRETS="$TEST_TMP/secrets.env"
    echo 'NTFY_TOPIC=test-topic' > "$ARCHON_CRON_SECRETS"
    unset CLAUDE_ACCOUNTS CLAUDE_AUTH_STATE_DIR CLAUDE_CONFIG_DIR
    export GH_CALLS="$TEST_TMP/gh-calls"
    export ARCHON_DB="$TEST_TMP/none.db"
    export LACHESIS_CALL_CMD="$TEST_TMP/lachesis"
    unset LACHESIS_FAIL GH_FAIL
    offer '{"repo":"alexsiri7/reli","kind":"security","capability":null,"model":"claude"}'

    local repo
    for repo in filmduel word-coach-annie reli cosmic-match; do
        mkdir -p "$HOME/.archon/workspaces/alexsiri7/$repo/source/.git"
    done
    PRIMARY="$HOME/.claude"
    SECONDARY="$HOME/.claude-secondary"
    mkdir -p "$PRIMARY" "$SECONDARY" "$HOME/.local/bin"

    local bin="$HOME/.local/bin"
    cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$CLAUDE_CONFIG_DIR" >> "$HOME/claude-calls"
if [ -e "$CLAUDE_CONFIG_DIR/broken" ]; then
  echo "Failed to authenticate. API Error: 401 OAuth access token is invalid."
  exit 1
fi
echo ok
EOF
    cat > "$bin/archon" <<'EOF'
#!/usr/bin/env bash
echo "$CLAUDE_CONFIG_DIR $*" >> "$HOME/archon-calls"
EOF
    cat > "$bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "\$GH_CALLS"
case "\$1 \$2" in
  "issue list") echo '[]' ;;
  "api user") echo factory-bot ;;
  "api repos/"*) [ -n "\${GH_FAIL:-}" ] && { echo "HTTP 502" >&2; exit 1; } ;;&
  "api repos/"*/issues*) cat "$TEST_TMP/issues.json" 2>/dev/null || echo '[]' ;;
  "api repos/"*/pulls*) cat "$TEST_TMP/pulls.json" 2>/dev/null || echo '[]' ;;
esac
exit 0
EOF
    cat > "$TEST_TMP/lachesis" <<EOF
#!/usr/bin/env bash
echo "\$1 \$2" >> "\$HOME/lachesis-calls"
[ "\$1" = "\${LACHESIS_FAIL:-}" ] && { echo "unreachable" >&2; exit 2; }
case "\$1" in
  next_issue) cat "$TEST_TMP/next.json" ;;
  read_audit_history) cat "$TEST_TMP/history.json" ;;
  *) echo '{}' ;;
esac
EOF
    cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in "Title: "*) echo "${a#Title: }" >> "$HOME/ntfy" ;; esac; done
EOF
    chmod +x "$bin"/* "$TEST_TMP/lachesis"
}

teardown() {
    rm -rf "$TEST_TMP"
}

summary() { grep "^$1=" "$HOME/.archon/sweep-state/last-sweep" | cut -d= -f2-; }

# offer <audit-json> — next_issue offers this audit.
offer() { jq -nc --argjson a "$1" '{reason: "selected", audit: $a}' > "$TEST_TMP/next.json"; }

# report — the arguments of the one report_audit_run call.
report() {
    [ "$(grep -c '^report_audit_run ' "$HOME/lachesis-calls")" -eq 1 ]
    sed -n 's/^report_audit_run //p' "$HOME/lachesis-calls"
}

# The fallback's history: reli's due tests audit was run more recently than
# filmduel's due security audit, busy has an open audit issue, and clean-code
# and north-star have no workflow.
history_fixture() {
    cat > "$TEST_TMP/history.json" <<'EOF'
{"model":"claude","unreadable":[],"due":[],
 "repos":[
  {"repo":"alexsiri7/busy","open_audit":12,"audits":[{"kind":"architecture","due":true,"capability":null,"last_run":null}]},
  {"repo":"alexsiri7/reli","open_audit":null,"audits":[
     {"kind":"clean-code","due":true,"capability":null,"last_run":null},
     {"kind":"tests","due":true,"capability":"auth","last_run":{"finished_at":"2026-10-20T02:00:00+00:00"}},
     {"kind":"architecture","due":false,"capability":null,"last_run":{"finished_at":"2026-01-01T00:00:00+00:00"}}]},
  {"repo":"alexsiri7/filmduel","open_audit":null,"audits":[
     {"kind":"security","due":true,"capability":null,"last_run":{"finished_at":"2026-09-01T02:00:00+00:00"}},
     {"kind":"north-star","due":true,"capability":null,"last_run":null}]}]}
EOF
}

@test "both accounts healthy: one probe, workflow runs on the slot's account, OK recorded" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$HOME/claude-calls")" -eq 1 ]
    slot_account="$(cat "$HOME/claude-calls")"
    grep -q "^$slot_account workflow run archon-security-audit " "$HOME/archon-calls"
    ! grep -q '^issue create' "$GH_CALLS" || false
    [ "$(summary outcome)" = ok ]
    [ "$(summary account)" = "$slot_account" ]
    [ ! -e "$HOME/.archon/sweep-state/$(summary repo).lock" ]
}

@test "broken secondary, either slot parity: sweep completes on the primary" {
    touch "$SECONDARY/broken"
    local accounts fell_back=0
    for accounts in "$PRIMARY:$SECONDARY" "$SECONDARY:$PRIMARY"; do
        rm -f "$HOME/archon-calls" "$GH_CALLS" "$HOME/claude-calls" "$HOME/lachesis-calls"
        rm -rf "$HOME/.archon/pipeline-health-state"
        CLAUDE_ACCOUNTS="$accounts" run "$SCRIPT"
        [ "$status" -eq 0 ]
        grep -q "^$PRIMARY workflow run archon-security-audit " "$HOME/archon-calls"
        [ "$(summary outcome)" = ok ]
        [ "$(summary account)" = "$PRIMARY" ]
        if [ "$(head -1 "$HOME/claude-calls")" = "$SECONDARY" ]; then
            # The slot's account was the broken one: one issue, then the primary.
            fell_back=1
            [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 1 ]
            [ "$(tail -1 "$HOME/claude-calls")" = "$PRIMARY" ]
        else
            ! grep -q '^issue create' "$GH_CALLS" || false
        fi
    done
    [ "$fell_back" -eq 1 ]
}

@test "every account broken: no workflow, FAILED (auth) recorded, no lock left, exit 1" {
    touch "$PRIMARY/broken" "$SECONDARY/broken"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -f "$HOME/archon-calls" ]
    [ "$(summary outcome)" = failed ]
    [ "$(summary reason)" = auth ]
    [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 2 ]
    [ -z "$(find "$HOME/.archon/sweep-state" -name '*.lock')" ]
    grep -q '^Sweep failed' "$HOME/ntfy"
    ! grep -q '^report_audit_run' "$HOME/lachesis-calls" || false
}

@test "workflow failure is recorded as FAILED (workflow) with the account used" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$HOME/.local/bin/archon"
    run "$SCRIPT"
    [ "$(summary outcome)" = failed ]
    [ "$(summary reason)" = workflow ]
    [ -n "$(summary account)" ]
    [ "$(report | jq -r .outcome)" = failed ]
}

@test "a clone gone by launch time: no workflow, FAILED (no-clone) recorded, no lock left, exit 1" {
    cat >> "$HOME/.local/bin/claude" <<'EOF'
rm -rf "$HOME/.archon/workspaces/alexsiri7/reli/source"
EOF
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -f "$HOME/archon-calls" ]
    [ "$(summary outcome)" = failed ]
    [ "$(summary reason)" = no-clone ]
    [ -z "$(find "$HOME/.archon/sweep-state" -name '*.lock')" ]
    grep -q '^Sweep: reli' "$HOME/ntfy"
    ! grep -q '^report_audit_run' "$HOME/lachesis-calls" || false
}

@test "secrets come from Doppler by name: the archon run sees neither the store nor the token" {
    : > "$ARCHON_CRON_SECRETS"
    doppler_stub "$TEST_TMP/dbin"
    export PATH="$TEST_TMP/dbin:$PATH"
    echo '{"NTFY_TOPIC":"topic-from-doppler","RELI_DB_URL":"postgres://secret@doppler"}' > "$TEST_TMP/doppler.json"
    export DOPPLER_STUB_JSON="$TEST_TMP/doppler.json" DOPPLER_STUB_ARGV="$TEST_TMP/doppler-argv"
    echo dp.st.fake > "$TEST_TMP/doppler.token"
    export ARCHON_CRON_DOPPLER_TOKEN="$TEST_TMP/doppler.token"
    cat > "$HOME/.local/bin/archon" <<'EOF'
#!/usr/bin/env bash
env > "$HOME/archon-env"
EOF
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -s "$TEST_TMP/doppler-argv" ]
    [ -s "$HOME/archon-env" ]
    run grep -E 'secret@doppler|^DOPPLER_TOKEN=|dp\.st\.fake' "$HOME/archon-env"
    [ "$status" -eq 1 ]
}

@test "an offered kind with a workflow runs in the repo's clone and is reported clean" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$HOME/archon-calls")" -eq 1 ]
    grep -q ' workflow run archon-security-audit Perform a deep security' "$HOME/archon-calls"
    ! grep -q '^read_audit_history' "$HOME/lachesis-calls" || false
    report > "$TEST_TMP/report.json"
    [ "$(jq -c 'del(.finished_at)' "$TEST_TMP/report.json")" = \
      '{"repo":"alexsiri7/reli","kind":"security","outcome":"clean","model":"claude","issues":[],"tokens_in":0,"tokens_out":0}' ]
    jq -e '.finished_at | test("^20[0-9-]+T")' "$TEST_TMP/report.json"
    [ "$(summary sweep)" = security-audit ]
    [ "$(summary repo)" = reli ]
    [[ "$output" == *"tokens could not be read"* ]]
}

@test "an offered kind no workflow runs falls back to the oldest due one that has one" {
    offer '{"repo":"alexsiri7/reli","kind":"clean-code","capability":null,"model":"claude"}'
    history_fixture
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^read_audit_history' "$HOME/lachesis-calls"
    [ "$(wc -l < "$HOME/archon-calls")" -eq 1 ]
    grep -q ' workflow run archon-security-audit ' "$HOME/archon-calls"
    [ "$(summary repo)" = filmduel ]
    [ "$(report | jq -c '[.repo, .kind, .model]')" = '["alexsiri7/filmduel","security","claude"]' ]
}

@test "an offered capability focuses the audit and is reported back" {
    offer '{"repo":"alexsiri7/reli","kind":"tests","capability":"auth","model":"claude"}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q ' workflow run archon-test-audit .* Focus this audit on the auth capability (specs/auth/)\.$' "$HOME/archon-calls"
    [ "$(report | jq -r .capability)" = auth ]
}

@test "nothing offered: nothing runs, nothing reported, last-sweep left as it was" {
    echo '{"reason":"none_ready"}' > "$TEST_TMP/next.json"
    mkdir -p "$HOME/.archon/sweep-state"
    printf 'last_run=1\noutcome=ok\n' > "$HOME/.archon/sweep-state/last-sweep"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/archon-calls" ]
    ! grep -q '^report_audit_run' "$HOME/lachesis-calls" || false
    [ "$(cat "$HOME/.archon/sweep-state/last-sweep")" = "$(printf 'last_run=1\noutcome=ok')" ]
}

@test "the fallback runs a never-run due audit before one run long ago" {
    offer '{"repo":"alexsiri7/reli","kind":"clean-code","capability":null,"model":"claude"}'
    echo '{"model":"claude","repos":[
      {"repo":"alexsiri7/filmduel","open_audit":null,"audits":[
        {"kind":"security","due":true,"capability":null,"last_run":{"finished_at":"2020-01-01T00:00:00+00:00"}}]},
      {"repo":"alexsiri7/reli","open_audit":null,"audits":[
        {"kind":"architecture","due":true,"capability":null,"last_run":null}]}]}' > "$TEST_TMP/history.json"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q ' workflow run archon-architect ' "$HOME/archon-calls"
    [ "$(report | jq -c '[.repo, .kind]')" = '["alexsiri7/reli","architecture"]' ]
}

@test "fallback with no due workflow-backed audit runs nothing" {
    offer '{"repo":"alexsiri7/reli","kind":"clean-code","capability":null,"model":"claude"}'
    echo '{"model":"claude","repos":[{"repo":"alexsiri7/reli","open_audit":null,"audits":[
      {"kind":"clean-code","due":true,"capability":null,"last_run":null},
      {"kind":"security","due":false,"capability":null,"last_run":null}]}]}' > "$TEST_TMP/history.json"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/archon-calls" ]
    ! grep -q '^report_audit_run' "$HOME/lachesis-calls" || false
}

@test "Lachesis unreachable: nothing runs, FAILED (lachesis) recorded, exit 1" {
    export LACHESIS_FAIL=next_issue
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -f "$HOME/archon-calls" ]
    [ "$(summary outcome)" = failed ]
    [ "$(summary reason)" = lachesis ]
    [ "$(summary sweep)" = - ]
}

@test "an unreadable Lachesis offer or history is a failure, not a quiet night" {
    local next history
    for next in 'not json' '{"audit":"security"}' 'unreadable-history'; do
        rm -f "$HOME/lachesis-calls" "$HOME/.archon/sweep-state/last-sweep"
        if [ "$next" = unreadable-history ]; then
            offer '{"repo":"alexsiri7/reli","kind":"clean-code","capability":null,"model":"claude"}'
            echo '{"model":"claude"}' > "$TEST_TMP/history.json"
        else
            echo "$next" > "$TEST_TMP/next.json"
        fi
        run "$SCRIPT"
        [ "$status" -eq 1 ]
        [ ! -f "$HOME/archon-calls" ]
        [ "$(summary reason)" = lachesis ]
    done
}

@test "a non-Claude model for audits: nothing runs, nothing reported" {
    offer '{"repo":"alexsiri7/reli","kind":"security","capability":null,"model":"glm-5"}'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/archon-calls" ]
    ! grep -q '^report_audit_run' "$HOME/lachesis-calls" || false
    [[ "$output" == *"Lachesis names glm-5 for audits"* ]]
}

# The issues listing as GitHub answers it: the stub ignores the query, so the
# label and creator filters are asserted on the call itself.
issues_fixture() {
    echo '[{"number":41,"created_at":"2999-01-01T00:00:00Z"},
           {"number":42,"created_at":"2999-01-01T00:00:00Z","pull_request":{}},
           {"number":7,"created_at":"2020-01-01T00:00:00Z"}]' > "$TEST_TMP/issues.json"
}

# pulls_fixture <head-ref>... — the repo's PRs, on these branches.
pulls_fixture() {
    printf '%s\n' "$@" | jq -Rn '[inputs | {head: {ref: .}}]' > "$TEST_TMP/pulls.json"
}

@test "the issues its workflow files make the run findings; PRs among them are not listed" {
    issues_fixture
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^api repos/alexsiri7/reli/issues?creator=factory-bot&labels=security&state=all&since=' "$GH_CALLS"
    [ "$(report | jq -c '[.outcome, .issues]')" = '["findings",[41]]' ]
}

@test "a requirements audit's findings are the requirements-gap issues it files" {
    offer '{"repo":"alexsiri7/reli","kind":"requirements","capability":null,"model":"claude"}'
    issues_fixture
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^api repos/alexsiri7/reli/issues?creator=factory-bot&labels=requirements-gap&state=all&since=' "$GH_CALLS"
    [ "$(report | jq -c '[.kind, .outcome, .issues]')" = '["requirements","findings",[41]]' ]
}

@test "the run's own PR makes it findings; another run's PR in the repo does not" {
    pulls_fixture archon/task-archon-security-audit-9999999999999
    run "$SCRIPT"
    [ "$(report | jq -c '[.outcome, .issues]')" = '["findings",[]]' ]

    rm -f "$HOME/lachesis-calls"
    pulls_fixture archon/task-archon-ship-block-9999999999999 archon/task-archon-security-audit-1000
    run "$SCRIPT"
    [ "$(report | jq -r .outcome)" = clean ]
}

@test "a kind whose workflow files no issues never counts the factory's other issues" {
    offer '{"repo":"alexsiri7/reli","kind":"tests","capability":null,"model":"claude"}'
    issues_fixture
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -q '/issues' "$GH_CALLS" || false
    [ "$(report | jq -c '[.outcome, .issues]')" = '["clean",[]]' ]
}

@test "GitHub unreadable after the run: reported failed, not clean, and notified" {
    export GH_FAIL=1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(report | jq -c '[.outcome, .issues]')" = '["failed",[]]' ]
    grep -q '^Sweep unread: reli' "$HOME/ntfy"
    [ "$(summary outcome)" = ok ]
}

@test "a report Lachesis refuses is logged and notified; the sweep still records OK" {
    export LACHESIS_FAIL=report_audit_run
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(summary outcome)" = ok ]
    grep -q '^Sweep not reported' "$HOME/ntfy"
}
