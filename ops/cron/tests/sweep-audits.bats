#!/usr/bin/env bats
# Tests for ops/cron/sweep-audits.sh: the Claude account preflight and its
# fallback, and the last-sweep summary ops/bin/pipeline-status reads.
#
# Runs the real script under a throwaway HOME. Stubs live in $HOME/.local/bin,
# which the script puts on PATH ahead of /usr/local/bin (where the real archon
# is installed).
#
# Run: bunx bats ops/cron/tests/sweep-audits.bats

SCRIPT="$BATS_TEST_DIRNAME/../sweep-audits.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"
    export ARCHON_CRON_FORCE_TICK=1
    export ARCHON_CRON_SECRETS="$TEST_TMP/secrets.env"
    echo 'NTFY_TOPIC=test-topic' > "$ARCHON_CRON_SECRETS"
    unset CLAUDE_ACCOUNTS CLAUDE_AUTH_STATE_DIR CLAUDE_CONFIG_DIR
    export GH_CALLS="$TEST_TMP/gh-calls"

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
    cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
[ "$1 $2" = "issue list" ] && echo '[]'
exit 0
EOF
    cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in "Title: "*) echo "${a#Title: }" >> "$HOME/ntfy" ;; esac; done
EOF
    chmod +x "$bin"/*
}

teardown() {
    rm -rf "$TEST_TMP"
}

summary() { grep "^$1=" "$HOME/.archon/sweep-state/last-sweep" | cut -d= -f2-; }

@test "both accounts healthy: one probe, workflow runs on the slot's account, OK recorded" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$HOME/claude-calls")" -eq 1 ]
    slot_account="$(cat "$HOME/claude-calls")"
    grep -q "^$slot_account workflow run archon-" "$HOME/archon-calls"
    [ ! -f "$GH_CALLS" ]
    [ "$(summary outcome)" = ok ]
    [ "$(summary account)" = "$slot_account" ]
    [ ! -e "$HOME/.archon/sweep-state/$(summary repo).lock" ]
}

@test "broken secondary, either slot parity: sweep completes on the primary" {
    touch "$SECONDARY/broken"
    local accounts fell_back=0
    for accounts in "$PRIMARY:$SECONDARY" "$SECONDARY:$PRIMARY"; do
        rm -f "$HOME/archon-calls" "$GH_CALLS" "$HOME/claude-calls"
        rm -rf "$HOME/.archon/pipeline-health-state"
        CLAUDE_ACCOUNTS="$accounts" run "$SCRIPT"
        [ "$status" -eq 0 ]
        grep -q "^$PRIMARY workflow run archon-" "$HOME/archon-calls"
        [ "$(summary outcome)" = ok ]
        [ "$(summary account)" = "$PRIMARY" ]
        if [ "$(head -1 "$HOME/claude-calls")" = "$SECONDARY" ]; then
            # The slot's account was the broken one: one issue, then the primary.
            fell_back=1
            [ "$(grep -c '^issue create' "$GH_CALLS")" -eq 1 ]
            [ "$(tail -1 "$HOME/claude-calls")" = "$PRIMARY" ]
        else
            [ ! -f "$GH_CALLS" ]
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
}

@test "workflow failure is recorded as FAILED (workflow) with the account used" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$HOME/.local/bin/archon"
    run "$SCRIPT"
    [ "$(summary outcome)" = failed ]
    [ "$(summary reason)" = workflow ]
    [ -n "$(summary account)" ]
}
