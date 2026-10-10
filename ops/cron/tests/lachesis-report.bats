#!/usr/bin/env bats
# Tests for lachesis-report.sh: the wrapper that turns the owner's main-account
# flag (lib/main-account.sh) into ARCHON_MAIN_ACCOUNT, the only gate
# lib/lachesis_report.py reads before it may probe main's fuel.
#
# Run: bunx bats ops/cron/tests/lachesis-report.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lachesis-report.sh"
    export HOME="$T/home"
    mkdir -p "$HOME/.local/bin" "$HOME/.config/archon-cron"
    # lachesis-report.sh puts $HOME/.local/bin first on PATH, so this python3
    # stands in for lib/lachesis_report.py and records what it was handed.
    printf '#!/usr/bin/env bash\necho "ARCHON_MAIN_ACCOUNT=${ARCHON_MAIN_ACCOUNT:-unset} args=$*" > "%s/seen"\n' "$T" \
        > "$HOME/.local/bin/python3"
    chmod +x "$HOME/.local/bin/python3"
    export ARCHON_CRON_SECRETS="$T/no-secrets.env"
    export MAIN_ACCOUNT_FLAG="$HOME/.config/archon-cron/main-account" MAIN_ACCOUNT_FLAG_TEST=1
    unset _MAIN_ACCOUNT_SH ARCHON_MAIN_ACCOUNT
}

@test "flag on: lachesis_report.py runs with ARCHON_MAIN_ACCOUNT=on" {
    echo "ARCHON_MAIN_ACCOUNT=on" > "$MAIN_ACCOUNT_FLAG"
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    grep -q '^ARCHON_MAIN_ACCOUNT=on ' "$T/seen"
    grep -q 'args=.*--dry-run' "$T/seen"
}

@test "flag off: ARCHON_MAIN_ACCOUNT=off" {
    echo "ARCHON_MAIN_ACCOUNT=off" > "$MAIN_ACCOUNT_FLAG"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^ARCHON_MAIN_ACCOUNT=off ' "$T/seen"
}

@test "no flag file: main is never probed (off)" {
    rm -f "$MAIN_ACCOUNT_FLAG"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^ARCHON_MAIN_ACCOUNT=off ' "$T/seen"
}

@test "an inherited ARCHON_MAIN_ACCOUNT=on cannot override the owner's flag" {
    echo "ARCHON_MAIN_ACCOUNT=off" > "$MAIN_ACCOUNT_FLAG"
    ARCHON_MAIN_ACCOUNT=on run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^ARCHON_MAIN_ACCOUNT=off ' "$T/seen"
}
