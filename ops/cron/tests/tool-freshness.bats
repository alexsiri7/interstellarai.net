#!/usr/bin/env bats
# ops/cron/tool-freshness.sh with every external lookup stubbed: no ntfy when
# everything is current, one ntfy naming `tool installed → latest` when a tool
# is behind, node flagged when its major is past EOL, and the status file.
#
# Run: bunx bats ops/cron/tests/tool-freshness.bats

setup() {
    export SANDBOX="$BATS_TMPDIR/tool-freshness-$$"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX/home" "$SANDBOX/state" "$SANDBOX/archon/.git" "$SANDBOX/bin"
    export HOME="$SANDBOX/home"
    export ARCHON_CRON_SECRETS="$SANDBOX/secrets.env"
    echo 'NTFY_TOPIC=test-topic' > "$ARCHON_CRON_SECRETS"
    export TOOL_FRESHNESS_STATE_DIR="$SANDBOX/state"
    export TOOL_FRESHNESS_ARCHON_DIR="$SANDBOX/archon"
    export TOOL_FRESHNESS_PG_DUMP="$SANDBOX/bin/pg_dump"
    export TOOL_FRESHNESS_NODE_INDEX_URL="file://node-index"
    export TOOL_FRESHNESS_NODE_SCHEDULE_URL="file://node-schedule"
    export TOOL_FRESHNESS_TODAY="2026-09-21"
    export NTFY_OUT="$SANDBOX/ntfy"          # every curl to ntfy.sh dumps its argv here
    export FIXTURES="$SANDBOX/fixtures"
    mkdir -p "$FIXTURES"

    # Installed versions (override per test).
    export STUB_BUN=1.4.2 STUB_GH=2.101.0 STUB_UV=0.12.17 STUB_NODE=v24.21.0 STUB_PG=17.11
    export STUB_ARCHON_DESCRIBE=v0.10.1-14-gac9c9f21
    export STUB_ARCHON_TAG_IN_HEAD=1         # merge-base --is-ancestor result
    export STUB_ARCHON_BEHIND=37
    # Latest versions.
    export LATEST_BUN=bun-v1.4.2 LATEST_GH=v2.101.0 LATEST_UV=0.12.17 LATEST_ARCHON=v0.10.1
    export LATEST_PG_TAGS=$'18.1.0\n17.11.0\n17.10.0\n16.9.0'
    write_node_fixtures v24.21.0 Krypton

    printf '#!/usr/bin/env bash\necho "pg_dump (PostgreSQL) $STUB_PG"\n' > "$SANDBOX/bin/pg_dump"
    chmod +x "$SANDBOX/bin/pg_dump"

    bun()  { echo "$STUB_BUN"; }
    uv()   { echo "uv $STUB_UV (abc 2026-01-01 x86_64-unknown-linux-gnu)"; }
    node() { echo "$STUB_NODE"; }
    gh() {
        if [ "$1" = "--version" ]; then echo "gh version $STUB_GH (2026-01-01)"; return 0; fi
        case "$2" in
            repos/oven-sh/bun/releases/latest)   echo "$LATEST_BUN" ;;
            repos/cli/cli/releases/latest)       echo "$LATEST_GH" ;;
            repos/astral-sh/uv/releases/latest)  echo "$LATEST_UV" ;;
            repos/coleam00/archon/releases/latest) echo "$LATEST_ARCHON" ;;
            repos/theseus-rs/postgresql-binaries/releases*) printf '%s\n' "$LATEST_PG_TAGS" ;;
            *) echo "gh stub: unexpected $*" >&2; return 1 ;;
        esac
    }
    curl() {
        local a
        for a in "$@"; do
            case "$a" in
                file://node-index)    cat "$FIXTURES/index.json"; return 0 ;;
                file://node-schedule) cat "$FIXTURES/schedule.json"; return 0 ;;
                ntfy.sh/*)            printf '%s\n' "$@" > "$NTFY_OUT"; return 0 ;;
            esac
        done
        echo "curl stub: unexpected $*" >&2; return 1
    }
    git() {
        [ "$1" = "-C" ] && shift 2
        case "$1 ${2:-}" in
            "remote ")            printf 'origin\nupstream\n' ;;
            "remote get-url")     echo "https://github.com/coleam00/archon" ;;
            "describe --tags")    echo "$STUB_ARCHON_DESCRIBE" ;;
            "fetch -q")           : ;;
            "ls-remote --symref") printf 'ref: refs/heads/dev\tHEAD\nabc123\tHEAD\n' ;;
            "ls-remote upstream") printf 'deadbeef\trefs/tags/%s^{}\n' "$LATEST_ARCHON" ;;
            "rev-list --count")   echo "$STUB_ARCHON_BEHIND" ;;
            "merge-base --is-ancestor") [ "$STUB_ARCHON_TAG_IN_HEAD" = 1 ] ;;
            *) echo "git stub: unexpected $*" >&2; return 1 ;;
        esac
    }
    export -f bun uv node gh curl git

    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tool-freshness.sh"
}

teardown() {
    rm -rf "$SANDBOX"
}

# write_node_fixtures <newest-lts-version> <codename>: index.json newest-first
# with a Current line above the LTS one; schedule.json with v20 already EOL.
write_node_fixtures() {
    cat > "$FIXTURES/index.json" <<JSON
[
  {"version": "v26.9.0", "lts": false},
  {"version": "$1", "lts": "$2"},
  {"version": "v24.20.0", "lts": "$2"},
  {"version": "v22.22.0", "lts": "Jod"},
  {"version": "v20.20.2", "lts": "Iron"}
]
JSON
    cat > "$FIXTURES/schedule.json" <<'JSON'
{
  "v20": {"start": "2023-04-18", "lts": "2023-10-24", "end": "2026-04-30"},
  "v22": {"start": "2024-04-24", "lts": "2024-10-29", "end": "2027-04-30"},
  "v24": {"start": "2025-05-06", "lts": "2025-10-28", "end": "2028-04-30"},
  "v26": {"start": "2026-04-22", "end": "2029-04-30"}
}
JSON
}

@test "everything current: no ntfy, status file says current" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$NTFY_OUT" ]
    [[ "$output" == *"everything current (6 checked, 0 unknown) — no ntfy"* ]]
    grep -qx 'status=current' "$SANDBOX/state/tool-freshness"
    grep -qx 'behind_count=0' "$SANDBOX/state/tool-freshness"
    grep -q '^current: bun 1.4.2$' "$SANDBOX/state/tool-freshness"
    grep -q '^current: node v24.21.0 (LTS Krypton)$' "$SANDBOX/state/tool-freshness"
    grep -q '^current: pg_dump 17.11 (theseus-rs/postgresql-binaries 17.x)$' "$SANDBOX/state/tool-freshness"
    grep -q '^current: archon v0.10.1-14-gac9c9f21 (v0.10.1; upstream/dev is 37 commit(s) ahead of HEAD)$' "$SANDBOX/state/tool-freshness"
}

@test "one tool behind: one ntfy with the 'tool installed → latest' line" {
    export STUB_GH=2.100.0
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
    export STUB_BUN=1.3.11 STUB_UV=0.12.6 STUB_PG=17.10
    run "$SCRIPT"
    grep -qx 'Title: Tools behind: bun, uv, pg_dump' "$NTFY_OUT"
    grep -qx 'bun 1.3.11 → 1.4.2' "$NTFY_OUT"
    grep -qx 'uv 0.12.6 → 0.12.17' "$NTFY_OUT"
    grep -qx 'pg_dump 17.10 → 17.11 (theseus-rs/postgresql-binaries 17.x)' "$NTFY_OUT"
}

@test "pg_dump only follows its own major line" {
    export STUB_PG=17.11 LATEST_PG_TAGS=$'18.2.0\n17.11.0'
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

@test "a failed lookup is unknown, not behind, and does not ntfy on its own" {
    export LATEST_UV=""
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$NTFY_OUT" ]
    grep -qx 'unknown_count=1' "$SANDBOX/state/tool-freshness"
    grep -q '^unknown: uv: could not look up' "$SANDBOX/state/tool-freshness"
    [[ "$output" == *"everything current (5 checked, 1 unknown)"* ]]
}

@test "unknowns ride along in the ntfy when something else is behind" {
    export LATEST_UV="" STUB_BUN=1.0.0
    run "$SCRIPT"
    grep -qx '(could not check: uv)' "$NTFY_OUT"
}

@test "missing NTFY_TOPIC fails loud" {
    : > "$ARCHON_CRON_SECRETS"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_TOPIC not set"* ]]
}
