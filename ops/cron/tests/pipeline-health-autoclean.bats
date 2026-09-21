#!/usr/bin/env bats
# Unit tests for the disk-pressure autoclean in ops/cron/pipeline-health-cron.sh
# (autoclean_root and the step functions it calls).
#
# Run: bunx bats ops/cron/tests/pipeline-health-autoclean.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/autoclean-state-$$"
    mkdir -p "$STATE_DIR"
    # mktemp inside the functions under test lands here, so a leaked temp
    # dir is visible to the assertions and cleaned by teardown.
    export TMPDIR="$STATE_DIR/tmpdir"
    mkdir -p "$TMPDIR"

    log() { echo "$*"; }
    export -f log

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    load_fn dir_size_mb
    load_fn autoclean_step
    load_fn bun_pm_cache
    load_fn autoclean_idle_dir
    load_fn autoclean_gradle_caches
    load_fn autoclean_apks
    load_fn autoclean_tmp
}

teardown() {
    rm -rf "$STATE_DIR"
}

# Source only the named function's body from the script.
load_fn() {
    # shellcheck disable=SC1090
    source <(awk -v fn="^$1\\(\\)" '$0 ~ fn {p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

# A `bun` that behaves like bun 1.3.11: `pm cache` and `pm cache rm` refuse
# to run unless ./package.json exists in the cwd.
install_bun_stub() {
    export BUN_STUB_CACHE="$STATE_DIR/bun-cache"
    export BUN_STUB_RM_SENTINEL="$STATE_DIR/bun-rm-called"
    mkdir -p "$STATE_DIR/bin" "$BUN_STUB_CACHE"
    cat > "$STATE_DIR/bin/bun" <<'STUB'
#!/usr/bin/env bash
if [ ! -f ./package.json ]; then
    echo "error: No package.json was found for directory \"$PWD\"" >&2
    exit 1
fi
case "$*" in
    "pm cache") printf '%s' "$BUN_STUB_CACHE" ;;
    "pm cache rm") touch "$BUN_STUB_RM_SENTINEL" ;;
    *) echo "unexpected: $*" >&2; exit 2 ;;
esac
STUB
    chmod +x "$STATE_DIR/bin/bun"
    export PATH="$STATE_DIR/bin:$PATH"
}

# ── bun cache step ───────────────────────────────────────────────────────────

@test "bun cache step succeeds when the cwd has no package.json (cron runs from \$HOME)" {
    install_bun_stub
    cd "$STATE_DIR"
    [ ! -f ./package.json ]

    # The pre-fix invocation is exactly what cron ran, and it fails.
    run bun pm cache rm
    [ "$status" -eq 1 ]
    [ ! -f "$BUN_STUB_RM_SENTINEL" ]

    run autoclean_step "bun pm cache rm" "$(bun_pm_cache 2>/dev/null)" bun_pm_cache rm
    [ "$status" -eq 0 ]
    [ -f "$BUN_STUB_RM_SENTINEL" ]
    [[ "$output" == *"bun pm cache rm ok"* ]]
    [[ "$output" != *"failed"* ]]
}

@test "bun_pm_cache reports the cache dir and leaves no temp dir behind" {
    install_bun_stub
    cd "$STATE_DIR"

    run bun_pm_cache
    [ "$status" -eq 0 ]
    [ "$output" = "$BUN_STUB_CACHE" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "bun_pm_cache passes bun's own exit code through" {
    install_bun_stub
    # `pm cache nope` hits the stub's unexpected-args branch: exit 2.
    run bun_pm_cache nope
    [ "$status" -eq 2 ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

# ── autoclean_step ───────────────────────────────────────────────────────────

@test "autoclean_step logs a failing step with its exit code and last stderr line" {
    boom() { echo "first line"; echo "kaput: no such cache" >&2; return 3; }
    run autoclean_step "boom step" "" boom
    [ "$status" -eq 0 ]          # non-fatal: caller continues to the next step
    [[ "$output" == *"autoclean: boom step failed (exit 3): kaput: no such cache"* ]]
}

@test "autoclean_step reports MB freed from the target dir" {
    mkdir -p "$STATE_DIR/cache"
    dd if=/dev/zero of="$STATE_DIR/cache/blob" bs=1M count=5 status=none
    wipe() { rm -rf "$STATE_DIR/cache"/*; }
    run autoclean_step "wipe cache" "$STATE_DIR/cache" wipe
    [ "$status" -eq 0 ]
    [[ "$output" == *"wipe cache ok — freed 5MB"* ]]
}

# ── /tmp rules ───────────────────────────────────────────────────────────────

make_tmp_root() {
    export PIPELINE_HEALTH_TMP_ROOT="$STATE_DIR/tmp"
    local t="$PIPELINE_HEALTH_TMP_ROOT"
    mkdir -p "$t"
    local old="10 days ago"
    # Rule 2 candidates: arbitrary agent-session dirs.
    mkdir -p "$t/validate_venv_579" "$t/jdk21/bin" "$t/node-v22.14.0-linux-x64"
    touch -d "$old" "$t/jdk21/bin" "$t/validate_venv_579" "$t/jdk21" "$t/node-v22.14.0-linux-x64"
    # Fresh dir: kept.
    mkdir -p "$t/venv_fresh"
    # Protected prefixes and dotdirs, all old: kept.
    mkdir -p "$t/claude-1000/scratch" "$t/tmux-1000" "$t/ssh-XYZ" "$t/systemd-private-x" "$t/.X11-unix"
    touch -d "$old" "$t/claude-1000" "$t/tmux-1000" "$t/ssh-XYZ" "$t/systemd-private-x" "$t/.X11-unix"
    # Regular files, all old: never removed by rule 2.
    echo log > "$t/pipeline-health.log"
    echo state > "$t/.archon-active-runs.json"
    echo fire > "$t/.pr-review-fire.reli.42"
    echo tar > "$t/node-v22.14.0-linux-x64.tar.xz"
    touch -d "$old" "$t/pipeline-health.log" "$t/.archon-active-runs.json" "$t/.pr-review-fire.reli.42" "$t/node-v22.14.0-linux-x64.tar.xz"
    # Old symlink to a dir: not a directory to find, kept.
    ln -s "$t/venv_fresh" "$t/old-link"
    touch -h -d "$old" "$t/old-link"
    # Rule 1 (pattern list, 1 day): an old *-venv dir goes, a fresh one stays.
    mkdir -p "$t/foo-venv" "$t/bar-venv"
    touch -d "2 days ago" "$t/foo-venv"
}

@test "autoclean_tmp removes user dirs idle for 3 days and keeps fresh ones" {
    make_tmp_root
    run autoclean_tmp
    [ "$status" -eq 0 ]
    local t="$PIPELINE_HEALTH_TMP_ROOT"
    [ ! -e "$t/validate_venv_579" ]
    [ ! -e "$t/jdk21" ]
    [ ! -e "$t/node-v22.14.0-linux-x64" ]
    [ -d "$t/venv_fresh" ]
    [[ "$output" == *"removed 4 stale entries"* ]]   # 3 by rule 2 + foo-venv by rule 1
}

@test "autoclean_tmp keeps claude-*, tmux-*, ssh-*, systemd-* and dotdirs however old" {
    make_tmp_root
    run autoclean_tmp
    local t="$PIPELINE_HEALTH_TMP_ROOT"
    [ -d "$t/claude-1000/scratch" ]
    [ -d "$t/tmux-1000" ]
    [ -d "$t/ssh-XYZ" ]
    [ -d "$t/systemd-private-x" ]
    [ -d "$t/.X11-unix" ]
}

@test "autoclean_tmp never removes a regular file or a symlink" {
    make_tmp_root
    run autoclean_tmp
    local t="$PIPELINE_HEALTH_TMP_ROOT"
    [ -f "$t/pipeline-health.log" ]
    [ -f "$t/.archon-active-runs.json" ]
    [ -f "$t/.pr-review-fire.reli.42" ]
    [ -f "$t/node-v22.14.0-linux-x64.tar.xz" ]
    [ -L "$t/old-link" ]
}

@test "autoclean_tmp still applies the 1-day pattern list" {
    make_tmp_root
    run autoclean_tmp
    local t="$PIPELINE_HEALTH_TMP_ROOT"
    [ ! -e "$t/foo-venv" ]      # 2 days old, matches *-venv
    [ -d "$t/bar-venv" ]        # fresh
}

@test "autoclean_tmp is a no-op when the tmp root does not exist" {
    export PIPELINE_HEALTH_TMP_ROOT="$STATE_DIR/nope"
    run autoclean_tmp
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Gradle version caches ────────────────────────────────────────────────────

@test "autoclean_gradle_caches removes version dirs with no file written in 30d, keeps live ones and shared dirs" {
    export PIPELINE_HEALTH_GRADLE_CACHES="$STATE_DIR/gradle"
    local g="$PIPELINE_HEALTH_GRADLE_CACHES"
    mkdir -p "$g/8.14.1/transforms" "$g/9.0.0/transforms" "$g/9.4.1" "$g/modules-2/files-2.1" "$g/jars-9" "$g/journal-1"
    echo x > "$g/8.14.1/transforms/live"
    echo x > "$g/8.14.1/old";           touch -d "60 days ago" "$g/8.14.1/old"
    echo x > "$g/9.0.0/transforms/old"; touch -d "60 days ago" "$g/9.0.0/transforms/old"
    echo x > "$g/modules-2/files-2.1/old"; touch -d "60 days ago" "$g/modules-2/files-2.1/old"
    touch -d "60 days ago" "$g/9.4.1" "$g/jars-9" "$g/journal-1"

    run autoclean_gradle_caches
    [ "$status" -eq 0 ]
    [ -d "$g/8.14.1/transforms" ]       # has a fresh file: kept, transforms untouched
    [ -f "$g/8.14.1/old" ]
    [ ! -e "$g/9.0.0" ]
    [ ! -e "$g/9.4.1" ]                 # empty version dir counts as idle
    [ -d "$g/modules-2/files-2.1" ]
    [ -d "$g/jars-9" ]
    [ -d "$g/journal-1" ]
    [[ "$output" == *"removed $g/9.0.0 (idle >30d)"* ]]
}

# ── APK builds ───────────────────────────────────────────────────────────────

@test "autoclean_apks drops builds older than 30d except the *-latest.* targets, never the symlinks" {
    export PIPELINE_HEALTH_APK_DIR="$STATE_DIR/apks"
    local a="$PIPELINE_HEALTH_APK_DIR"
    mkdir -p "$a/aab"
    for f in reli-aaa.apk reli-bbb.apk un-reminder-ccc.apk; do echo x > "$a/$f"; done
    echo x > "$a/reli-ddd.apk"                     # fresh
    echo x > "$a/aab/app-release.aab"
    echo x > "$a/aab/old-release.aab"
    ln -s reli-bbb.apk "$a/reli-latest.apk"
    ln -s app-release.aab "$a/aab/app-latest.aab"
    touch -d "45 days ago" "$a/reli-aaa.apk" "$a/reli-bbb.apk" "$a/un-reminder-ccc.apk" "$a/aab/app-release.aab" "$a/aab/old-release.aab"
    touch -h -d "45 days ago" "$a/reli-latest.apk" "$a/aab/app-latest.aab"

    run autoclean_apks
    [ "$status" -eq 0 ]
    [ ! -e "$a/reli-aaa.apk" ]
    [ ! -e "$a/un-reminder-ccc.apk" ]
    [ ! -e "$a/aab/old-release.aab" ]
    [ -f "$a/reli-bbb.apk" ]                       # latest target
    [ -f "$a/reli-ddd.apk" ]                       # fresh
    [ -f "$a/aab/app-release.aab" ]                # latest target in aab/
    [ -L "$a/reli-latest.apk" ] && [ -f "$a/reli-latest.apk" ]
    [ -L "$a/aab/app-latest.aab" ] && [ -f "$a/aab/app-latest.aab" ]
    [[ "$output" == *"removed 3 APK/AAB builds older than 30d"* ]]
}

@test "autoclean_apks is silent when nothing qualifies" {
    export PIPELINE_HEALTH_APK_DIR="$STATE_DIR/apks"
    mkdir -p "$PIPELINE_HEALTH_APK_DIR"
    echo x > "$PIPELINE_HEALTH_APK_DIR/reli-new.apk"
    run autoclean_apks
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$PIPELINE_HEALTH_APK_DIR/reli-new.apk" ]
}

# ── idle cache dir ───────────────────────────────────────────────────────────

@test "autoclean_idle_dir removes a dir with no recent file and keeps one with a fresh file" {
    mkdir -p "$STATE_DIR/idle/sub" "$STATE_DIR/live/sub"
    echo x > "$STATE_DIR/idle/sub/f"; touch -d "40 days ago" "$STATE_DIR/idle/sub/f"
    echo x > "$STATE_DIR/live/sub/old"; touch -d "40 days ago" "$STATE_DIR/live/sub/old"
    echo x > "$STATE_DIR/live/sub/fresh"

    run autoclean_idle_dir "$STATE_DIR/idle" 30
    [ ! -e "$STATE_DIR/idle" ]
    [[ "$output" == *"removed $STATE_DIR/idle (idle >30d)"* ]]

    run autoclean_idle_dir "$STATE_DIR/live" 30
    [ -d "$STATE_DIR/live/sub" ]
    [ -z "$output" ]

    run autoclean_idle_dir "$STATE_DIR/missing" 30
    [ "$status" -eq 0 ]
}

# ── stale archon worktrees ───────────────────────────────────────────────────

# autoclean_stale_worktrees walks the real $HOME and $BASE_DIR, so it is only
# loaded once both point into the sandbox, with a `gh` that answers from
# $GH_OPEN_BRANCHES (or fails when $GH_FAIL is set).
make_worktree_sandbox() {
    export HOME="$STATE_DIR/home"
    export BASE_DIR="$STATE_DIR/base"
    git init -q "$BASE_DIR/reli"
    export LEGACY="$BASE_DIR/.archon/worktrees/ext-fast/reli/archon"
    export MODERN="$HOME/.archon/workspaces/alexsiri7/reli/worktrees/archon"
    local old="5 hours ago"
    mkdir -p "$LEGACY/task-archon-ship-1" "$LEGACY/task-archon-ship-2" "$LEGACY/task-archon-ship-3" "$MODERN/task-archon-ship-4"
    dd if=/dev/zero of="$LEGACY/task-archon-ship-1/blob" bs=1M count=5 status=none
    dd if=/dev/zero of="$MODERN/task-archon-ship-4/blob" bs=1M count=2 status=none
    touch -d "$old" "$LEGACY/task-archon-ship-1" "$LEGACY/task-archon-ship-2" "$MODERN/task-archon-ship-4"
    # task-archon-ship-3 keeps its fresh mtime; task-archon-ship-2 has an open PR.
    export GH_OPEN_BRANCHES="archon/task-archon-ship-2"
    gh() {
        [ -n "${GH_FAIL:-}" ] && return 1
        printf '%s\n' "$GH_OPEN_BRANCHES"
    }
    export -f gh
    load_fn autoclean_stale_worktrees
}

@test "autoclean_stale_worktrees removes stale worktrees under the legacy and 0.10 layouts, keeps open-PR and fresh ones" {
    make_worktree_sandbox
    run autoclean_stale_worktrees
    [ "$status" -eq 0 ]
    [ ! -e "$LEGACY/task-archon-ship-1" ]
    [ ! -e "$MODERN/task-archon-ship-4" ]
    [ -d "$LEGACY/task-archon-ship-2" ]      # open PR
    [ -d "$LEGACY/task-archon-ship-3" ]      # modified <4h
    [[ "$output" == *"pruned 2 stale worktrees for reli"* ]]
    [[ "$output" != *"failed"* ]]
}

@test "autoclean_stale_worktrees --dry-run lists each candidate with its size and a total, removes nothing" {
    make_worktree_sandbox
    run autoclean_stale_worktrees --dry-run
    [ "$status" -eq 0 ]
    [ -d "$LEGACY/task-archon-ship-1" ]
    [ -d "$MODERN/task-archon-ship-4" ]
    [[ "$output" == *"would remove $LEGACY/task-archon-ship-1 ("*"MB)"* ]]
    [[ "$output" == *"would remove $MODERN/task-archon-ship-4 ("*"MB)"* ]]
    [[ "$output" != *"task-archon-ship-2"* ]]
    [[ "$output" != *"task-archon-ship-3"* ]]
    [[ "$output" != *"pruned"* ]]
    local total; total=$(printf '%s\n' "$output" | sed -n 's/.*dry run — 2 stale worktrees, \([0-9]*\)MB total.*/\1/p')
    [ -n "$total" ] && [ "$total" -ge 7 ]
}

@test "autoclean_stale_worktrees skips a project whose gh pr list fails" {
    make_worktree_sandbox
    export GH_FAIL=1
    run autoclean_stale_worktrees
    [ "$status" -eq 0 ]
    [ -d "$LEGACY/task-archon-ship-1" ]
    [ -d "$MODERN/task-archon-ship-4" ]
    [[ "$output" == *"gh pr list failed for reli — skipping its worktrees"* ]]
}

# ── check_disk ───────────────────────────────────────────────────────────────

# / stays at 50%; /mnt/ext-fast reads 90% first and $EXT_FAST_AFTER once the
# cleanup has run. The autoclean entry points and notify only record the call.
make_disk_sandbox() {
    export CALLS="$STATE_DIR/calls"; : > "$CALLS"
    export LOG_DIR="$STATE_DIR/logs"
    export EXT_FAST_AFTER="$1"
    disk_used_pct() {
        case "$1" in
            /) echo 50 ;;
            /mnt/ext-fast)
                if [ -e "$STATE_DIR/ext-fast-read" ]; then echo "$EXT_FAST_AFTER"; else touch "$STATE_DIR/ext-fast-read"; echo 90; fi ;;
        esac
    }
    autoclean_root() { echo "autoclean_root" >> "$CALLS"; }
    autoclean_stale_worktrees() { echo "autoclean_stale_worktrees" >> "$CALLS"; }
    notify() { echo "notify $1" >> "$CALLS"; }
    load_fn check_disk
}

@test "check_disk on /mnt/ext-fast pressure removes stale worktrees and skips the ntfy once recovered" {
    make_disk_sandbox 70
    run check_disk
    [ "$status" -eq 0 ]
    grep -qx 'autoclean_stale_worktrees' "$CALLS"
    ! grep -q 'autoclean_root' "$CALLS"
    ! grep -q '^notify' "$CALLS"
    [[ "$output" == *"disk /mnt/ext-fast 90% → 70% after cleanup"* ]]
    [[ "$output" == *"disk /mnt/ext-fast recovered (90% → 70%) — no ntfy"* ]]
}

@test "check_disk on /mnt/ext-fast pressure still ntfys when the cleanup did not bring it under 85%" {
    make_disk_sandbox 88
    run check_disk
    [ "$status" -eq 0 ]
    grep -qx 'autoclean_stale_worktrees' "$CALLS"
    grep -qx 'notify Disk warning: /mnt/ext-fast 88% (was 90%)' "$CALLS"
    [[ "$output" == *"disk /mnt/ext-fast still at 88% after cleanup — ntfying"* ]]
}
