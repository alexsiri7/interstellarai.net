#!/usr/bin/env bats
# `pipeline-health-cron.sh --trim`: the weekly light autoclean. It must run the
# always-safe steps (uv/pip prune, idle Gradle caches, old APKs, stale
# worktrees, stale /tmp) and none of the >=85%-only ones that wipe hot caches
# (go clean -cache, bun pm cache rm, npm cache clean, journal vacuum), skip the
# throttle gate and the archon run snapshot, run no health check, and log the
# MB it freed.
#
# Run: bunx bats ops/cron/tests/pipeline-health-trim.bats

setup() {
    export SANDBOX="$BATS_TMPDIR/trim-$$"
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX/home" "$SANDBOX/tmp" "$SANDBOX/base" "$SANDBOX/gradle" "$SANDBOX/apks" "$SANDBOX/pip-cache"
    export HOME="$SANDBOX/home"                    # no real ~/.archon, ~/.gradle, ~/.config
    export BASE_DIR="$SANDBOX/base"                # no repos: autoclean_stale_worktrees has nothing to scan
    export PIPELINE_HEALTH_TMP_ROOT="$SANDBOX/tmp"
    export PIPELINE_HEALTH_GRADLE_CACHES="$SANDBOX/gradle"
    export PIPELINE_HEALTH_APK_DIR="$SANDBOX/apks"
    export ARCHON_CRON_SECRETS="$SANDBOX/secrets.env"
    echo 'NTFY_TOPIC=test-topic' > "$ARCHON_CRON_SECRETS"
    export CALLS="$SANDBOX/calls"
    : > "$CALLS"
    export PIP_STUB_CACHE="$SANDBOX/pip-cache"
    echo wheel > "$PIP_STUB_CACHE/some.whl"        # populated, so `pip cache purge` is attempted

    # Every external command records its argv; exported functions win over
    # PATH lookups, so the script's own PATH prepend cannot reach the real ones.
    go()         { echo "go $*" >> "$CALLS"; }
    bun()        { echo "bun $*" >> "$CALLS"; }
    npm()        { echo "npm $*" >> "$CALLS"; }
    journalctl() { echo "journalctl $*" >> "$CALLS"; }
    uv()         { echo "uv $*" >> "$CALLS"; [ "$*" = "cache dir" ] && echo "$SANDBOX/uv-cache"; return 0; }
    pip()        { echo "pip $*" >> "$CALLS"; [ "$*" = "cache dir" ] && echo "$PIP_STUB_CACHE"; return 0; }
    archon()     { echo "archon $*" >> "$CALLS"; }
    gh()         { echo "gh $*" >> "$CALLS"; }
    curl()       { echo "curl $*" >> "$CALLS"; }
    export -f go bun npm journalctl uv pip archon gh curl

    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "--trim runs the light steps and none of the hot-cache ones" {
    run "$SCRIPT" --trim
    [ "$status" -eq 0 ]
    grep -qx 'uv cache prune' "$CALLS"
    grep -qx 'pip cache purge' "$CALLS"
    ! grep -q '^go ' "$CALLS"
    ! grep -q '^bun ' "$CALLS"
    ! grep -q '^npm ' "$CALLS"
    ! grep -q '^journalctl ' "$CALLS"
    [[ "$output" == *"autoclean: uv cache prune ok"* ]]
    [[ "$output" == *"autoclean: pip cache purge ok"* ]]
}

@test "--trim prunes idle Gradle version caches, old APKs and stale /tmp entries" {
    mkdir -p "$PIPELINE_HEALTH_GRADLE_CACHES/8.5/x" "$PIPELINE_HEALTH_GRADLE_CACHES/8.9/x" "$PIPELINE_HEALTH_GRADLE_CACHES/modules-2"
    echo a > "$PIPELINE_HEALTH_GRADLE_CACHES/8.5/x/f"; touch -d "45 days ago" "$PIPELINE_HEALTH_GRADLE_CACHES/8.5/x/f"
    echo b > "$PIPELINE_HEALTH_GRADLE_CACHES/8.9/x/f"                      # fresh
    echo m > "$PIPELINE_HEALTH_GRADLE_CACHES/modules-2/f"; touch -d "45 days ago" "$PIPELINE_HEALTH_GRADLE_CACHES/modules-2/f"
    echo x > "$PIPELINE_HEALTH_APK_DIR/reli-old.apk"; touch -d "45 days ago" "$PIPELINE_HEALTH_APK_DIR/reli-old.apk"
    echo x > "$PIPELINE_HEALTH_APK_DIR/reli-new.apk"
    mkdir -p "$PIPELINE_HEALTH_TMP_ROOT/foo-venv" "$PIPELINE_HEALTH_TMP_ROOT/claude-1000"
    touch -d "2 days ago" "$PIPELINE_HEALTH_TMP_ROOT/foo-venv"
    touch -d "10 days ago" "$PIPELINE_HEALTH_TMP_ROOT/claude-1000"
    echo log > "$PIPELINE_HEALTH_TMP_ROOT/.archon-active-runs.tick"; touch -d "10 days ago" "$PIPELINE_HEALTH_TMP_ROOT/.archon-active-runs.tick"

    run "$SCRIPT" --trim
    [ "$status" -eq 0 ]
    [ ! -e "$PIPELINE_HEALTH_GRADLE_CACHES/8.5" ]
    [ -d "$PIPELINE_HEALTH_GRADLE_CACHES/8.9" ]
    [ -d "$PIPELINE_HEALTH_GRADLE_CACHES/modules-2" ]
    [ ! -e "$PIPELINE_HEALTH_APK_DIR/reli-old.apk" ]
    [ -f "$PIPELINE_HEALTH_APK_DIR/reli-new.apk" ]
    [ ! -e "$PIPELINE_HEALTH_TMP_ROOT/foo-venv" ]
    [ -d "$PIPELINE_HEALTH_TMP_ROOT/claude-1000" ]
    [ -f "$PIPELINE_HEALTH_TMP_ROOT/.archon-active-runs.tick" ]
}

@test "--trim skips the throttle gate, the archon snapshot and every health check" {
    # A fresh stamp would make a normal tick skip; --trim must ignore it and not rewrite it.
    mkdir -p "$HOME/.config/archon-cron/state"
    date +%s > "$HOME/.config/archon-cron/state/pipeline-health.last_run"
    local before; before=$(cat "$HOME/.config/archon-cron/state/pipeline-health.last_run")
    sleep 1
    run "$SCRIPT" --trim
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.config/archon-cron/state/pipeline-health.last_run")" = "$before" ]
    [[ "$output" != *"[throttle]"* ]]
    ! grep -q '^archon ' "$CALLS"
    ! grep -q '^curl ' "$CALLS"                    # no ntfy
    [[ "$output" != *"=== pipeline health check ==="* ]]
    [[ "$output" == *"=== weekly trim (light autoclean) ==="* ]]
}

@test "--trim logs the MB freed" {
    run "$SCRIPT" --trim
    [ "$status" -eq 0 ]
    [[ "$output" =~ "=== trim done — freed "[0-9]+"MB on / (now "[0-9]+"%) ===" ]]
}

@test "an unknown flag is rejected before anything runs" {
    run "$SCRIPT" --nope
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
    [ ! -s "$CALLS" ]
}
