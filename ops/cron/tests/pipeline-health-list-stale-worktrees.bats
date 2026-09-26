#!/usr/bin/env bats
# `pipeline-health-cron.sh --list-stale-worktrees`: the dry run of the
# stale-worktree autoclean, run through the real script so the flag is proved
# to reach its handler. It must log each candidate with its size and a total,
# remove nothing, and — like `--trim` — skip the throttle gate, the archon
# snapshot and every health check.
#
# Run: bunx bats ops/cron/tests/pipeline-health-list-stale-worktrees.bats

setup() {
    export SANDBOX="$BATS_TMPDIR/list-worktrees-$$"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX/home" "$SANDBOX/base"
    export HOME="$SANDBOX/home"
    export BASE_DIR="$SANDBOX/base"
    export ARCHON_CRON_SECRETS="$SANDBOX/secrets.env"
    echo 'NTFY_TOPIC=test-topic' > "$ARCHON_CRON_SECRETS"
    export CALLS="$SANDBOX/calls"
    : > "$CALLS"

    # One project with one stale worktree under the legacy layout.
    git init -q "$BASE_DIR/reli"
    export STALE="$BASE_DIR/.archon/worktrees/ext-fast/reli/archon/task-archon-ship-1"
    mkdir -p "$STALE"
    dd if=/dev/zero of="$STALE/blob" bs=1M count=3 status=none
    touch -d "5 hours ago" "$STALE"

    # `gh` answers "no open PRs"; every other external command only records.
    gh()     { echo "gh $*" >> "$CALLS"; }
    archon() { echo "archon $*" >> "$CALLS"; }
    curl()   { echo "curl $*" >> "$CALLS"; }
    export -f gh archon curl

    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
}

# A flag that fell through to the full tick would sit in the health checks'
# retry sleeps; bound it so that shows up as a failure, not a hung suite.
list_stale_worktrees() {
    timeout 30 "$SCRIPT" --list-stale-worktrees
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "--list-stale-worktrees lists the stale worktree with its size and removes nothing" {
    run list_stale_worktrees
    [ "$status" -eq 0 ]
    [ -f "$STALE/blob" ]
    [[ "$output" == *"autoclean: would remove $STALE ("*"MB)"* ]]
    local total; total=$(printf '%s\n' "$output" | sed -n 's/.*dry run — 1 stale worktrees, \([0-9]*\)MB total.*/\1/p')
    [ -n "$total" ] && [ "$total" -ge 3 ]
    [[ "$output" != *"pruned"* ]]
}

@test "--list-stale-worktrees skips the throttle gate, the archon snapshot and every health check" {
    mkdir -p "$HOME/.config/archon-cron/state"
    date +%s > "$HOME/.config/archon-cron/state/pipeline-health.last_run"
    local before; before=$(cat "$HOME/.config/archon-cron/state/pipeline-health.last_run")
    sleep 1
    run list_stale_worktrees
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.config/archon-cron/state/pipeline-health.last_run")" = "$before" ]
    [[ "$output" != *"[throttle]"* ]]
    ! grep -q '^archon ' "$CALLS"
    ! grep -q '^curl ' "$CALLS"                    # no ntfy
    [[ "$output" != *"=== pipeline health check ==="* ]]
    [[ "$output" != *"=== weekly trim"* ]]
    grep -q '^gh pr list ' "$CALLS"
    [ "$(grep -c '^gh ' "$CALLS")" -eq 1 ]         # only the open-PR lookup
}

@test "ARCHON_RUN_AS=archon: the factory user's worktrees are listed through the wrapper, as archon" {
    sudo() { echo "sudo $*" >> "$CALLS"; echo "autoclean: would remove /mnt/ext-fast/archon-home/.archon/workspaces/alexsiri7/reli/worktrees/archon/task-archon-ship-9 (7MB)"; }
    export -f sudo
    ARCHON_RUN_AS=archon run list_stale_worktrees
    [ "$status" -eq 0 ]
    grep -qx 'sudo -n -u archon /usr/local/bin/archon-as-archon worktree-trim --dry-run' "$CALLS"
    [[ "$output" == *"[archon] autoclean: would remove /mnt/ext-fast/archon-home/"*"task-archon-ship-9 (7MB)"* ]]
    [ -f "$STALE/blob" ]                                  # asiri's own layout still listed, not removed
    [[ "$output" == *"autoclean: would remove $STALE ("* ]]
}

@test "flag off: the wrapper is never called" {
    sudo() { echo "sudo $*" >> "$CALLS"; }
    export -f sudo
    run list_stale_worktrees
    [ "$status" -eq 0 ]
    ! grep -q '^sudo' "$CALLS"
}
