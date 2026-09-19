#!/usr/bin/env bats
# ops/cron/tool-freshness.sh (report mode) with every external lookup stubbed
# (tool-freshness-env.bash): no ntfy when everything is current, one ntfy
# naming `tool installed → latest` when a tool is behind, node flagged when its
# major is past EOL, and the status file. --apply is covered by tool-update.bats.
#
# Run: bunx bats ops/cron/tests/tool-freshness.bats

load tool-freshness-env

setup() {
    tool_freshness_sandbox
}

teardown() {
    tool_freshness_teardown
}

@test "everything current: no ntfy, status file says current" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$NTFY_OUT" ]
    [[ "$output" == *"everything current (7 checked, 0 unknown) — no ntfy"* ]]
    grep -qx 'status=current' "$SANDBOX/state/tool-freshness"
    grep -qx 'behind_count=0' "$SANDBOX/state/tool-freshness"
    grep -q '^current: bun 1.4.2$' "$SANDBOX/state/tool-freshness"
    grep -q '^current: shellcheck 0.11.0$' "$SANDBOX/state/tool-freshness"
    grep -q '^current: uv 0.12.17 (snap astral-uv latest/stable)$' "$SANDBOX/state/tool-freshness"
    grep -q '^current: node v24.21.0 (LTS Krypton)$' "$SANDBOX/state/tool-freshness"
    grep -q '^current: pg_dump 17.11 (theseus-rs/postgresql-binaries 17.x)$' "$SANDBOX/state/tool-freshness"
    grep -q '^current: archon v0.10.1-14-gac9c9f21 (v0.10.1; upstream/dev is 37 commit(s) ahead of HEAD)$' "$SANDBOX/state/tool-freshness"
}

@test "one tool behind: one ntfy with the 'tool installed → latest' line" {
    export STUB_GH=2.100.0; install_fake_tools
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$NTFY_OUT" ]
    grep -qx 'Title: Tools behind: gh' "$NTFY_OUT"
    grep -qx 'gh 2.100.0 → 2.101.0' "$NTFY_OUT"
    ! grep -q 'bun' "$NTFY_OUT"
    grep -qx 'status=behind' "$SANDBOX/state/tool-freshness"
    grep -qx 'behind: gh 2.100.0 → 2.101.0' "$SANDBOX/state/tool-freshness"
}

@test "node on an EOL major is flagged with the EOL date and the newest LTS" {
    export STUB_NODE=v20.20.2
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$NTFY_OUT" ]
    grep -qx 'node v20.20.2 → v24.21.0 (LTS Krypton; v20 EOL since 2026-04-30)' "$NTFY_OUT"
    grep -qx 'Title: Tools behind: node' "$NTFY_OUT"
}

@test "node newer than the LTS line but past EOL is still behind" {
    export STUB_NODE=v26.9.0
    cat > "$FIXTURES/schedule.json" <<'JSON'
{"v24": {"end": "2028-04-30"}, "v26": {"end": "2026-09-01"}}
JSON
    run "$SCRIPT"
    [ -f "$NTFY_OUT" ]
    grep -qx 'node v26.9.0 → v24.21.0 (LTS Krypton; v26 EOL since 2026-09-01)' "$NTFY_OUT"
}

@test "node behind within a supported line is behind without an EOL note" {
    export STUB_NODE=v24.20.0
    run "$SCRIPT"
    [ -f "$NTFY_OUT" ]
    grep -qx 'node v24.20.0 → v24.21.0 (LTS Krypton)' "$NTFY_OUT"
}

@test "several behind: all listed, title names each" {
    export STUB_BUN=1.3.11 STUB_SHELLCHECK=0.10.0 STUB_UV=0.12.6 STUB_PG=17.10; install_fake_tools
    run "$SCRIPT"
    grep -qx 'Title: Tools behind: bun, shellcheck, uv, pg_dump' "$NTFY_OUT"
    grep -qx 'bun 1.3.11 → 1.4.2' "$NTFY_OUT"
    grep -qx 'shellcheck 0.10.0 → 0.11.0' "$NTFY_OUT"
    grep -qx 'uv 0.12.6 → 0.12.17 (snap astral-uv latest/stable)' "$NTFY_OUT"
    grep -qx 'pg_dump 17.10 → 17.11 (theseus-rs/postgresql-binaries 17.x)' "$NTFY_OUT"
}

@test "pg_dump only follows its own major line" {
    export LATEST_PG_TAGS=$'18.2.0\n17.11.0'
    run "$SCRIPT"
    [ ! -e "$NTFY_OUT" ]
    grep -q '^current: pg_dump 17.11' "$SANDBOX/state/tool-freshness"
}

@test "archon behind when the latest upstream release is not in HEAD" {
    export STUB_ARCHON_TAG_IN_HEAD=0 LATEST_ARCHON=v0.11.0
    run "$SCRIPT"
    [ -f "$NTFY_OUT" ]
    grep -qx 'archon v0.10.1-14-gac9c9f21 → v0.11.0 (upstream/dev is 37 commit(s) ahead of HEAD)' "$NTFY_OUT"
}

@test "archon branch tracking flags the default-branch gap instead" {
    export TOOL_FRESHNESS_ARCHON_TRACK=branch
    run "$SCRIPT"
    grep -qx 'archon v0.10.1-14-gac9c9f21 → upstream/dev (37 commit(s) behind)' "$NTFY_OUT"
    export STUB_ARCHON_BEHIND=0; rm -f "$NTFY_OUT"
    run "$SCRIPT"
    [ ! -e "$NTFY_OUT" ]
}

@test "a failed lookup (snap info answering nothing) is unknown, not behind, and does not ntfy on its own" {
    export LATEST_UV=""
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$NTFY_OUT" ]
    grep -qx 'unknown_count=1' "$SANDBOX/state/tool-freshness"
    grep -q '^unknown: uv: could not look up' "$SANDBOX/state/tool-freshness"
    [[ "$output" == *"everything current (6 checked, 1 unknown)"* ]]
}

@test "unknowns ride along in the ntfy when something else is behind" {
    export LATEST_UV="" STUB_BUN=1.0.0; install_fake_tools
    run "$SCRIPT"
    grep -qx '(could not check: uv)' "$NTFY_OUT"
}

@test "missing NTFY_TOPIC fails loud" {
    : > "$ARCHON_CRON_SECRETS"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC not set"* ]]
}

@test "uv follows the snap store channel, not GitHub: same version as the channel is current" {
    export STUB_UV=0.12.6 LATEST_UV=0.12.6
    run "$SCRIPT"
    [ ! -e "$NTFY_OUT" ]
    grep -q '^current: uv 0.12.6 (snap astral-uv latest/stable)$' "$SANDBOX/state/tool-freshness"
    export LATEST_UV=0.12.7; rm -f "$NTFY_OUT"
    run "$SCRIPT"
    grep -qx 'uv 0.12.6 → 0.12.7 (snap astral-uv latest/stable)' "$NTFY_OUT"
}

@test "report mode never upgrades, even with everything behind" {
    export STUB_BUN=1.4.1 STUB_GH=2.100.0 STUB_SHELLCHECK=0.10.0; install_fake_tools
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$CALLS" ]
    [ "$("$HOME/.local/bin/gh" --version)" = "gh version 2.100.0 (2026-01-01)" ]
    ! grep -q '^apply' "$SANDBOX/state/tool-freshness"
    grep -qx 'Title: Tools behind: bun, gh, shellcheck' "$NTFY_OUT"
}
