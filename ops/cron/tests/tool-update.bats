#!/usr/bin/env bats
# ops/cron/tool-freshness.sh --apply (lib/tool-update.sh) against the fake
# $HOME from tool-freshness-env.bash: each tool's upgrade path, checksum
# mismatch → nothing installed + failure recorded, the PostgreSQL tree swap
# and its rollbacks, bun skipped while an archon run is live, the lock, and
# silence when everything is current.
#
# Run: bunx bats ops/cron/tests/tool-update.bats

load tool-freshness-env

setup() {
    tool_freshness_sandbox
}

teardown() {
    tool_freshness_teardown
}

status_file() { cat "$SANDBOX/state/tool-freshness"; }

@test "all current: --apply touches nothing, no ntfy, apply_status=ok" {
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    [ ! -e "$NTFY_OUT" ]
    [ ! -e "$CALLS" ]
    [[ "$output" == *"everything current (7 checked, 0 unknown), nothing to apply — no ntfy"* ]]
    grep -qx 'status=current' "$SANDBOX/state/tool-freshness"
    grep -qx 'apply_status=ok' "$SANDBOX/state/tool-freshness"
    grep -qx 'apply_count=0' "$SANDBOX/state/tool-freshness"
}

@test "an unknown flag is refused" {
    run "$SCRIPT" --frobnicate
    [ "$status" -eq 2 ]
}

@test "lock: a second run exits at once while the first holds the lock" {
    mkdir -p "$SANDBOX/state"
    exec 8>"$SANDBOX/state/tool-freshness.lock"
    flock 8
    run "$SCRIPT" --apply
    exec 8>&-
    [ "$status" -eq 0 ]
    [[ "$output" == *"another tool-freshness run holds"* ]]
    [ ! -e "$SANDBOX/state/tool-freshness" ]
}

# --- bun -------------------------------------------------------------------

@test "bun behind: bun upgrade, archon-serve restarted, health 200 → upgraded" {
    export STUB_BUN=1.4.1; install_fake_tools
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    grep -qx 'bun upgrade' "$CALLS"
    grep -qx 'systemctl --user restart archon-serve.service' "$CALLS"
    [ "$("$HOME/.bun/bin/bun" --version)" = 1.4.2 ]
    grep -qx 'apply: bun upgraded 1.4.1 → 1.4.2 (archon-serve.service restarted, http://health.test/ 200)' "$SANDBOX/state/tool-freshness"
    grep -qx 'apply_status=ok' "$SANDBOX/state/tool-freshness"
    grep -qx 'current: bun 1.4.2' "$SANDBOX/state/tool-freshness"
    grep -qx 'Title: Tools upgraded: bun' "$NTFY_OUT"
    grep -qx 'upgraded: bun 1.4.1 → 1.4.2' "$NTFY_OUT"
    ! grep -q 'still behind' "$NTFY_OUT"
}

@test "bun skipped while an archon run is running; retried next week" {
    export STUB_BUN=1.4.1; install_fake_tools
    export STUB_RUNS='{"runs": [{"workflow_name": "archon-ship", "status": "running", "user_message": "fix #528", "metadata": {"workflow_source": {"origin": "/mnt/ext-fast/filmduel"}}}], "total": 1}'
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    ! grep -q 'bun upgrade' "$CALLS"
    ! grep -q 'systemctl' "$CALLS"
    [ "$("$HOME/.bun/bin/bun" --version)" = 1.4.1 ]
    grep -qx 'apply: bun skipped 1.4.1 → 1.4.2: 1 running archon run(s) — retry next week' "$SANDBOX/state/tool-freshness"
    grep -qx 'apply_status=ok' "$SANDBOX/state/tool-freshness"
    grep -qx 'Title: Tools behind: bun' "$NTFY_OUT"
    grep -qx 'skipped: bun (1.4.1 → 1.4.2: 1 running archon run(s) — retry next week)' "$NTFY_OUT"
    grep -qx 'still behind (manual): bun 1.4.1 → 1.4.2' "$NTFY_OUT"
}

@test "bun skipped when an 'archon workflow run' process is live (pgrep)" {
    export STUB_BUN=1.4.1 STUB_PGREP_RC=0; install_fake_tools
    run "$SCRIPT" --apply
    ! grep -q 'bun upgrade' "$CALLS"
    grep -q "^apply: bun skipped 1.4.1 → 1.4.2: an 'archon workflow run' process is live" "$SANDBOX/state/tool-freshness"
}

@test "bun skipped when the run listing cannot be trusted" {
    export STUB_BUN=1.4.1 STUB_RUNS='{"ok": false, "error": "Not in a git repository"}' STUB_RUNS_RC=1; install_fake_tools
    run "$SCRIPT" --apply
    ! grep -q 'bun upgrade' "$CALLS"
    grep -q '^apply: bun skipped 1.4.1 → 1.4.2: could not list archon runs' "$SANDBOX/state/tool-freshness"
}

@test "bun upgraded but archon-serve unhealthy afterwards: failed + urgent ntfy" {
    export STUB_BUN=1.4.1 STUB_HEALTH=503; install_fake_tools
    run "$SCRIPT" --apply
    grep -qx 'bun upgrade' "$CALLS"
    grep -qx 'Title: archon-serve unhealthy after bun upgrade' "$NTFY_OUT"
    grep -qx 'Priority: urgent' "$NTFY_OUT"
    grep -qx 'apply: bun failed upgraded 1.4.1 → 1.4.2 but http://health.test/ answered 503 after restarting archon-serve.service' "$SANDBOX/state/tool-freshness"
    grep -qx 'apply_status=failed' "$SANDBOX/state/tool-freshness"
    grep -qx 'Title: Tool update FAILED: bun' "$NTFY_OUT"
}

# --- gh --------------------------------------------------------------------

@test "gh behind: tarball + checksums verified, installed over ~/.local/bin/gh, version and auth checked" {
    export STUB_GH=2.100.0; install_fake_tools
    make_gh_release 2.101.0
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    grep -qx 'curl https://releases.test/cli/cli/releases/download/v2.101.0/gh_2.101.0_linux_amd64.tar.gz' "$CALLS"
    grep -qx 'curl https://releases.test/cli/cli/releases/download/v2.101.0/gh_2.101.0_checksums.txt' "$CALLS"
    [ "$("$HOME/.local/bin/gh" --version)" = "gh version 2.101.0 (2026-01-01)" ]
    [ -x "$HOME/.local/bin/gh" ]
    [ ! -e "$HOME/.local/bin/gh.prev" ]
    grep -qx 'apply: gh upgraded 2.100.0 → 2.101.0' "$SANDBOX/state/tool-freshness"
    grep -qx 'current: gh 2.101.0' "$SANDBOX/state/tool-freshness"
    grep -qx 'upgraded: gh 2.100.0 → 2.101.0' "$NTFY_OUT"
    [ -z "$(ls -A "$SANDBOX/scratch")" ]   # scratch dir cleaned up
}

@test "gh checksum mismatch: nothing installed, failure recorded, ntfy titled FAILED" {
    export STUB_GH=2.100.0; install_fake_tools
    make_gh_release 2.101.0 deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    [ "$("$HOME/.local/bin/gh" --version)" = "gh version 2.100.0 (2026-01-01)" ]
    grep -qx 'apply: gh failed sha256 mismatch for gh_2.101.0_linux_amd64.tar.gz against gh_2.101.0_checksums.txt — not installed' "$SANDBOX/state/tool-freshness"
    grep -qx 'apply_status=failed' "$SANDBOX/state/tool-freshness"
    grep -qx 'behind: gh 2.100.0 → 2.101.0' "$SANDBOX/state/tool-freshness"
    grep -qx 'Title: Tool update FAILED: gh' "$NTFY_OUT"
    grep -qx 'Priority: high' "$NTFY_OUT"
    grep -qx 'failed: gh (sha256 mismatch for gh_2.101.0_linux_amd64.tar.gz against gh_2.101.0_checksums.txt — not installed)' "$NTFY_OUT"
    grep -qx 'still behind (manual): gh 2.100.0 → 2.101.0' "$NTFY_OUT"
}

@test "gh download failure is a failure, not an install" {
    export STUB_GH=2.100.0; install_fake_tools
    run "$SCRIPT" --apply
    [ "$("$HOME/.local/bin/gh" --version)" = "gh version 2.100.0 (2026-01-01)" ]
    grep -q '^apply: gh failed download failed: https://releases.test/cli/cli/releases/download/v2.101.0/gh_2.101.0_linux_amd64.tar.gz' "$SANDBOX/state/tool-freshness"
}

@test "gh post-install check fails (auth status): previous binary restored" {
    export STUB_GH=2.100.0 STUB_GH_AUTH_RC=1; install_fake_tools
    make_gh_release 2.101.0
    run "$SCRIPT" --apply
    [ "$("$HOME/.local/bin/gh" --version)" = "gh version 2.100.0 (2026-01-01)" ]
    [ ! -e "$HOME/.local/bin/gh.prev" ]
    grep -qx 'apply: gh failed gh auth status failed with gh 2.101.0 (previous binary restored)' "$SANDBOX/state/tool-freshness"
}

# --- shellcheck ------------------------------------------------------------

@test "shellcheck behind: sha256 from the release asset digest, installed" {
    export STUB_SHELLCHECK=0.10.0; install_fake_tools
    make_shellcheck_release v0.11.0
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    grep -qx 'curl https://releases.test/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz' "$CALLS"
    [ "$("$HOME/.local/bin/shellcheck" --version | awk '$1 == "version:" { print $2 }')" = 0.11.0 ]
    grep -qx 'apply: shellcheck upgraded 0.10.0 → 0.11.0' "$SANDBOX/state/tool-freshness"
    grep -qx 'current: shellcheck 0.11.0' "$SANDBOX/state/tool-freshness"
    grep -qx 'upgraded: shellcheck 0.10.0 → 0.11.0' "$NTFY_OUT"
}

@test "shellcheck digest mismatch: not installed" {
    export STUB_SHELLCHECK=0.10.0; install_fake_tools
    make_shellcheck_release v0.11.0 deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    run "$SCRIPT" --apply
    [ "$("$HOME/.local/bin/shellcheck" --version | awk '$1 == "version:" { print $2 }')" = 0.10.0 ]
    grep -qx 'apply: shellcheck failed sha256 mismatch for shellcheck-v0.11.0.linux.x86_64.tar.xz against the release asset digest — not installed' "$SANDBOX/state/tool-freshness"
}

@test "shellcheck with no digest in the release: not installed" {
    export STUB_SHELLCHECK=0.10.0; install_fake_tools
    make_shellcheck_release v0.11.0
    : > "$FIXTURES/shellcheck.digest"
    run "$SCRIPT" --apply
    ! grep -q 'curl https://releases.test/koalaman' "$CALLS"
    grep -qx 'apply: shellcheck failed the v0.11.0 release lists no sha256 digest for shellcheck-v0.11.0.linux.x86_64.tar.xz — not installed' "$SANDBOX/state/tool-freshness"
}

# --- postgresql-17 tree -----------------------------------------------------

@test "pg_dump behind: verified tarball → .new, pgvector built in, self-tested, swapped, old tree kept as .prev" {
    export LATEST_PG_TAGS=$'18.1.0\n17.12.0\n17.11.0'
    make_pg_release 17.12.0
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    local opt="$HOME/.local/opt"
    grep -qx 'curl https://releases.test/theseus-rs/postgresql-binaries/releases/download/17.12.0/postgresql-17.12.0-x86_64-unknown-linux-gnu.tar.gz' "$CALLS"
    grep -qx 'curl https://releases.test/theseus-rs/postgresql-binaries/releases/download/17.12.0/postgresql-17.12.0-x86_64-unknown-linux-gnu.tar.gz.sha256' "$CALLS"
    # pgvector: cloned at the version the old tree carried, built against the .new tree's pg_config.
    grep -q '^git clone -q --depth 1 --branch v0.8.1 https://releases.test/pgvector.git ' "$CALLS"
    grep -q "^make -s -C .* install PG_CONFIG=$opt/postgresql-17.new/bin/pg_config$" "$CALLS"
    # self-test ran on the .new tree: initdb, start, CREATE EXTENSION vector, stop.
    grep -q "^pg_ctl start $opt/postgresql-17.new$" "$CALLS"
    grep -q "^psql .*CREATE EXTENSION vector" "$CALLS"
    grep -q "^pg_ctl stop $opt/postgresql-17.new$" "$CALLS"
    # swapped: new tree in place with pgvector, old one parked with the marker, .new gone.
    [ "$("$opt/postgresql-17/bin/pg_dump" --version)" = "pg_dump (PostgreSQL) 17.12" ]
    [ -f "$opt/postgresql-17/lib/vector.so" ]
    [ -f "$opt/postgresql-17/share/extension/vector.control" ]
    [ "$("$opt/postgresql-17.prev/bin/pg_dump" --version)" = "pg_dump (PostgreSQL) 17.11" ]
    [ -f "$opt/postgresql-17.prev/.tool-update-swapped-at" ]
    [ ! -e "$opt/postgresql-17.new" ]
    [ "$(readlink "$HOME/.local/bin/pg_dump")" = ../opt/postgresql-17/bin/pg_dump ]
    [ "$(readlink "$HOME/.local/bin/pg_restore")" = ../opt/postgresql-17/bin/pg_restore ]
    [ "$("$HOME/.local/bin/pg_dump" --version)" = "pg_dump (PostgreSQL) 17.12" ]
    grep -qx 'apply: pg_dump upgraded 17.11 → 17.12 (pgvector v0.8.1 rebuilt; old tree kept as postgresql-17.prev for one cycle)' "$SANDBOX/state/tool-freshness"
    grep -qx 'current: pg_dump 17.12 (theseus-rs/postgresql-binaries 17.x)' "$SANDBOX/state/tool-freshness"
    grep -qx 'upgraded: pg_dump 17.11 → 17.12' "$NTFY_OUT"
    [ -z "$(ls -A "$SANDBOX/scratch")" ]
}

@test "pg_dump checksum mismatch: nothing unpacked, tree untouched" {
    export LATEST_PG_TAGS=$'17.12.0\n17.11.0'
    make_pg_release 17.12.0 ok deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    run "$SCRIPT" --apply
    [ "$("$HOME/.local/bin/pg_dump" --version)" = "pg_dump (PostgreSQL) 17.11" ]
    [ ! -e "$HOME/.local/opt/postgresql-17.new" ]
    [ ! -e "$HOME/.local/opt/postgresql-17.prev" ]
    ! grep -q 'make' "$CALLS"
    grep -qx 'apply: pg_dump failed sha256 mismatch for postgresql-17.12.0-x86_64-unknown-linux-gnu.tar.gz against postgresql-17.12.0-x86_64-unknown-linux-gnu.tar.gz.sha256 — not installed' "$SANDBOX/state/tool-freshness"
}

@test "pg_dump self-test failure (CREATE EXTENSION vector fails): no swap, .new removed" {
    export LATEST_PG_TAGS=$'17.12.0\n17.11.0'
    make_pg_release 17.12.0 broken
    run "$SCRIPT" --apply
    grep -q "^pg_ctl start " "$CALLS"
    grep -q "^pg_ctl stop " "$CALLS"
    [ "$("$HOME/.local/bin/pg_dump" --version)" = "pg_dump (PostgreSQL) 17.11" ]
    [ "$("$HOME/.local/opt/postgresql-17/bin/pg_dump" --version)" = "pg_dump (PostgreSQL) 17.11" ]
    [ ! -e "$HOME/.local/opt/postgresql-17.new" ]
    [ ! -e "$HOME/.local/opt/postgresql-17.prev" ]
    grep -q '^apply: pg_dump failed new tree failed its self-test: CREATE EXTENSION vector failed on the new tree: .*psql: error: connection refused.* — .*/postgresql-17 untouched$' "$SANDBOX/state/tool-freshness"
    grep -qx 'apply_status=failed' "$SANDBOX/state/tool-freshness"
    grep -qx 'Title: Tool update FAILED: pg_dump' "$NTFY_OUT"
}

@test "pg_dump pgvector build failure: no swap, .new removed" {
    export LATEST_PG_TAGS=$'17.12.0\n17.11.0' STUB_MAKE_RC=2
    make_pg_release 17.12.0
    run "$SCRIPT" --apply
    ! grep -q '^pg_ctl' "$CALLS"
    [ "$("$HOME/.local/bin/pg_dump" --version)" = "pg_dump (PostgreSQL) 17.11" ]
    [ ! -e "$HOME/.local/opt/postgresql-17.new" ]
    grep -q '^apply: pg_dump failed pgvector v0.8.1 build failed: make: \*\*\* \[vector.o\] Error 1' "$SANDBOX/state/tool-freshness"
}

@test "pg_dump post-swap check fails: previous tree and symlinks restored" {
    export LATEST_PG_TAGS=$'17.12.0\n17.11.0'
    make_pg_release 17.12.0 badversion        # tree says 17.12, its pg_dump reports 17.11
    run "$SCRIPT" --apply
    local opt="$HOME/.local/opt"
    [ "$("$opt/postgresql-17/bin/pg_restore" --version)" = "pg_restore (PostgreSQL) 17.11" ]
    [ -f "$opt/postgresql-17/lib/vector.so" ]
    [ ! -e "$opt/postgresql-17.new" ]
    [ ! -e "$opt/postgresql-17.prev" ]
    [ "$(readlink "$HOME/.local/bin/pg_dump")" = ../opt/postgresql-17/bin/pg_dump ]
    grep -qx "apply: pg_dump failed pg_dump --version said '17.11' after the swap, expected 17.12 — previous tree restored" "$SANDBOX/state/tool-freshness"
    grep -qx 'behind: pg_dump 17.11 → 17.12 (theseus-rs/postgresql-binaries 17.x)' "$SANDBOX/state/tool-freshness"
}

@test "a .prev tree is pruned once it is older than the keep window, kept when younger, ignored without the marker" {
    local opt="$HOME/.local/opt"
    mkdir -p "$opt/postgresql-17.prev" "$opt/postgresql-16.prev"
    echo old > "$opt/postgresql-17.prev/.tool-update-swapped-at"
    touch -d '-7 days' "$opt/postgresql-17.prev/.tool-update-swapped-at"
    run "$SCRIPT" --apply
    [ ! -e "$opt/postgresql-17.prev" ]
    [ -d "$opt/postgresql-16.prev" ]
    [[ "$output" == *"removed $opt/postgresql-17.prev (previous PostgreSQL tree, kept one cycle)"* ]]
    [[ "$output" == *"leaving $opt/postgresql-16.prev alone (no swap marker"* ]]
    mkdir -p "$opt/postgresql-17.prev"; date -Is > "$opt/postgresql-17.prev/.tool-update-swapped-at"
    run "$SCRIPT" --apply
    [ -d "$opt/postgresql-17.prev" ]
    [[ "$output" == *"keeping $opt/postgresql-17.prev"* ]]
}

# --- everything at once -----------------------------------------------------

@test "several behind: upgraded in order bun, gh, shellcheck, pg_dump; one summary ntfy" {
    export STUB_BUN=1.4.1 STUB_GH=2.100.0 STUB_SHELLCHECK=0.10.0; install_fake_tools
    export LATEST_PG_TAGS=$'17.12.0\n17.11.0'
    make_gh_release 2.101.0; make_shellcheck_release v0.11.0; make_pg_release 17.12.0
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    [ "$(grep '^apply: ' "$SANDBOX/state/tool-freshness" | awk '{ print $2 }' | tr '\n' ' ')" = "bun gh shellcheck pg_dump " ]
    grep -qx 'apply_count=4' "$SANDBOX/state/tool-freshness"
    grep -qx 'status=current' "$SANDBOX/state/tool-freshness"
    grep -qx 'Title: Tools upgraded: bun, gh, shellcheck, pg_dump' "$NTFY_OUT"
    grep -qx 'upgraded: bun 1.4.1 → 1.4.2, gh 2.100.0 → 2.101.0, shellcheck 0.10.0 → 0.11.0, pg_dump 17.11 → 17.12' "$NTFY_OUT"
    [ "$(grep -c '^Title: ' "$NTFY_OUT")" -eq 1 ]
}

@test "node and uv are report-only: listed as still behind (manual), never touched" {
    export STUB_NODE=v20.20.2 STUB_UV=0.12.6
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    [ ! -e "$CALLS" ]
    grep -qx 'apply_count=0' "$SANDBOX/state/tool-freshness"
    grep -qx 'Title: Tools behind: uv, node' "$NTFY_OUT"
    grep -qx 'still behind (manual): uv 0.12.6 → 0.12.17 (snap astral-uv latest/stable), node v20.20.2 → v24.21.0 (LTS Krypton; v20 EOL since 2026-04-30)' "$NTFY_OUT"
    ! grep -q '^upgraded:' "$NTFY_OUT"
}

@test "upgraded some, one manual: both lines in the one ntfy" {
    export STUB_GH=2.100.0 STUB_NODE=v24.20.0; install_fake_tools
    make_gh_release 2.101.0
    run "$SCRIPT" --apply
    grep -qx 'Title: Tools upgraded: gh' "$NTFY_OUT"
    grep -qx 'upgraded: gh 2.100.0 → 2.101.0' "$NTFY_OUT"
    grep -qx 'still behind (manual): node v24.20.0 → v24.21.0 (LTS Krypton)' "$NTFY_OUT"
}

@test "unknowns ride along in the apply summary" {
    export STUB_GH=2.100.0 LATEST_UV=""; install_fake_tools
    make_gh_release 2.101.0
    run "$SCRIPT" --apply
    grep -qx '(could not check: uv)' "$NTFY_OUT"
    grep -qx 'unknown_count=1' "$SANDBOX/state/tool-freshness"
}
