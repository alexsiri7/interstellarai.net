#!/usr/bin/env bats
# Unit tests for ops/cron/lib/claude-auth.sh: the real-request probe of a
# Claude config dir, the once-a-day ntfy, the single `human-needed` tracking
# issue and its close on recovery — plus check_claude_auth in
# pipeline-health-cron.sh, which runs the probe over every account once a day.
#
# Run: bunx bats ops/cron/tests/claude-auth.bats

setup() {
    TEST_TMP="$(mktemp -d)"
    export CLAUDE_AUTH_STATE_DIR="$TEST_TMP/state"
    export GH_CALLS="$TEST_TMP/gh-calls"
    export GH_ISSUES="$TEST_TMP/gh-issues.json"
    export NTFY_SENTINEL="$TEST_TMP/ntfy"
    echo '[]' > "$GH_ISSUES"
    mkdir -p "$TEST_TMP/bin" "$TEST_TMP/good" "$TEST_TMP/bad"
    touch "$TEST_TMP/bad/broken"

    # A config dir holding a `broken` file answers like the dead secondary token.
    cat > "$TEST_TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$CLAUDE_CONFIG_DIR" >> "$(dirname "$0")/../claude-calls"
if [ -e "$CLAUDE_CONFIG_DIR/broken" ]; then
  echo "Failed to authenticate. API Error: 401 OAuth access token is invalid."
  exit 1
fi
echo "ok"
EOF
    cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$1 $2" in
  "issue list") [ -e "$GH_ISSUES.fail" ] && exit 1; cat "$GH_ISSUES" ;;
  "issue create") echo "https://github.com/alexsiri7/interstellarai.net/issues/7" ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMP/bin/claude" "$TEST_TMP/bin/gh"
    export PATH="$TEST_TMP/bin:$PATH"

    log() { echo "$*"; }
    notify() { echo "$1 | ${2//$'\n'/ }" >> "$NTFY_SENTINEL"; }   # one line per ntfy

    unset _ARCHON_CLAUDE_AUTH_SH
    # shellcheck source=../lib/claude-auth.sh
    source "$BATS_TEST_DIRNAME/../lib/claude-auth.sh"
    GOOD="$TEST_TMP/good"
    BAD="$TEST_TMP/bad"
}

teardown() {
    rm -rf "$TEST_TMP"
}

open_issue_for() {
    printf '[{"number":7,"title":"Claude account auth failing: %s"}]' "$1" > "$GH_ISSUES"
}

@test "healthy account: probe passes, no ntfy, no gh call" {
    run claude_auth_check "$GOOD"
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_SENTINEL" ]
    [ ! -f "$GH_CALLS" ]
}

@test "401 account: fails, ntfys with the re-login command, opens one human-needed issue" {
    run claude_auth_check "$BAD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"401 OAuth access token is invalid"* ]]
    grep -q "CLAUDE_CONFIG_DIR=$BAD claude auth login" "$NTFY_SENTINEL"
    [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 1 ]
    grep '^issue create' "$GH_CALLS" | grep -q -- "--label human-needed"
    grep -q "^CLAUDE_CONFIG_DIR=$BAD claude auth login" "$GH_CALLS"    # issue body
    grep -q "^Failed to authenticate. API Error: 401" "$GH_CALLS"
}

@test "same account failing again the same day: no second ntfy, no second issue, no comment" {
    claude_auth_check "$BAD" || true
    open_issue_for "$BAD"
    : > "$GH_CALLS"
    run claude_auth_check "$BAD"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$NTFY_SENTINEL")" -eq 1 ]
    [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 0 ]
    [ "$(grep -c '^issue comment' "$GH_CALLS")" -eq 0 ]
}

@test "still failing on a later day: one more ntfy and a comment on the open issue" {
    claude_auth_check "$BAD" || true
    open_issue_for "$BAD"
    echo "2026-01-01" > "$CLAUDE_AUTH_STATE_DIR/${BAD//\//_}.alerted"
    : > "$GH_CALLS"
    run claude_auth_check "$BAD"
    [ "$(wc -l < "$NTFY_SENTINEL")" -eq 2 ]
    grep -q '^issue comment 7' "$GH_CALLS"
    [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 0 ]
}

@test "a failed issue listing never opens a duplicate issue" {
    touch "$GH_ISSUES.fail"
    run claude_auth_check "$BAD"
    [ "$status" -eq 1 ]
    [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 0 ]
    [[ "$output" == *"could not list issues"* ]]
    [ -f "$NTFY_SENTINEL" ]
}

@test "an issue for another account does not count as this account's issue" {
    open_issue_for "/elsewhere/.claude"
    run claude_auth_check "$BAD"
    [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 1 ]
}

@test "recovery closes the tracking issue and clears the state" {
    claude_auth_check "$BAD" || true
    open_issue_for "$BAD"
    rm "$BAD/broken"
    run claude_auth_check "$BAD"
    [ "$status" -eq 0 ]
    grep -q '^issue close 7' "$GH_CALLS"
    [[ "$output" == *"recovered — closed #7"* ]]
    [ ! -e "$CLAUDE_AUTH_STATE_DIR/${BAD//\//_}.failing" ]
    [ ! -e "$CLAUDE_AUTH_STATE_DIR/${BAD//\//_}.alerted" ]
}

@test "a failed issue listing during recovery is logged and keeps the failing state" {
    claude_auth_check "$BAD" || true
    rm "$BAD/broken"
    touch "$GH_ISSUES.fail"
    run claude_auth_check "$BAD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not list issues"*"recovery check for $BAD"* ]]
    [ -e "$CLAUDE_AUTH_STATE_DIR/${BAD//\//_}.failing" ]
}

@test "the tracking issue's label is one issue-pickup-cron.sh never ingests" {
    SCRIPT_FILE="$BATS_TEST_DIRNAME/../issue-pickup-cron.sh"
    # shellcheck disable=SC1090
    source <(awk '/^has_human_label\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
    has_human_label "[\"bug\",\"$HUMAN_NEEDED_LABEL\"]"
}

@test "a probe that hangs is cut off and counts as a failure" {
    cat > "$TEST_TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
    CLAUDE_AUTH_PROBE_TIMEOUT=1
    run claude_auth_check "$GOOD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"probe timed out after 1s"* ]]
}

@test "check_claude_auth probes every account once a day" {
    SCRIPT_FILE="$BATS_TEST_DIRNAME/../pipeline-health-cron.sh"
    source "$BATS_TEST_DIRNAME/../lib/run-as.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_claude_auth\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
    CLAUDE_ACCOUNTS="$GOOD:$BAD"
    run check_claude_auth
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_TMP/claude-calls")" = "$GOOD
$BAD" ]
    [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 1 ]
    [[ "$output" == *"$GOOD ok"* ]]
    run check_claude_auth
    [ "$(wc -l < "$TEST_TMP/claude-calls")" -eq 2 ]    # second tick today: no probe
}

@test "under ARCHON_RUN_AS=archon the factory user's own credential is probed, through the wrapper" {
    SCRIPT_FILE="$BATS_TEST_DIRNAME/../pipeline-health-cron.sh"
    export ARCHON_RUN_AS=archon
    unset _ARCHON_RUN_AS_SH
    source "$BATS_TEST_DIRNAME/../lib/run-as.sh"
    # shellcheck disable=SC1090
    source <(awk '/^check_claude_auth\(\)/{p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/sudo-calls"\necho ok\n' "$TEST_TMP" > "$TEST_TMP/bin/sudo"
    chmod +x "$TEST_TMP/bin/sudo"
    CLAUDE_ACCOUNTS="$GOOD:$BAD"
    run check_claude_auth
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TMP/claude-calls" ]                  # the owner's accounts are not touched
    [[ "$(cat "$TEST_TMP/sudo-calls")" == "-n -u archon /usr/local/bin/archon-as-archon claude-probe "* ]]
    [[ "$output" == *"archon ok"* ]]
}

@test "a failing factory credential names the setup-token fix, not CLAUDE_CONFIG_DIR" {
    [[ "$(claude_auth_login_cmd archon)" == "claude setup-token"* ]]
    [ "$(claude_auth_login_cmd /x/.claude)" = "CLAUDE_CONFIG_DIR=/x/.claude claude auth login" ]
}
