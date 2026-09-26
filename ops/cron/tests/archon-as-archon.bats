#!/usr/bin/env bats
# Tests for ops/host/archon-user/archon-as-archon — the only door from the
# owner's cron jobs into the factory user. Runs the wrapper as the current user
# through its test hook (ARCHON_AS_TEST=1, ARCHON_AS_DRY_EXEC=1 prints the
# directory, environment and argv it would exec).
#
# Run: bunx bats ops/cron/tests/archon-as-archon.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    W="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../host/archon-user" && pwd)/archon-as-archon"
    mkdir -p "$T/home/repos/reli/.git" "$T/home/repos/filmduel/.git" "$T/home/.local/bin" "$T/home/tmp" \
             "$T/owner/reli/ops/cron/lib" "$T/owner/filmduel" "$T/owner/notaproject" "$T/elsewhere"
    printf '# comment\nreli\nfilmduel   # trailing\n\n../evil\n' > "$T/projects"
    export ARCHON_AS_TEST=1 ARCHON_AS_DRY_EXEC=1
    export ARCHON_AS_HOME="$T/home" ARCHON_AS_PROJECTS_FILE="$T/projects" ARCHON_AS_OWNER_BASE="$T/owner"
    export ARCHON_AS_ARCHON_BIN=/usr/local/lib/archon-user/bin/archon
    unset SUDO_USER
    # A secret in the caller's environment must never reach the child.
    export RELI_DB_URL=postgres://secret NTFY_TOPIC=secret-topic GH_TOKEN=ghp_secret CLAUDE_CONFIG_DIR=/home/asiri/.claude
}

@test "workflow run from the owner's clone runs in the factory clone, no --cwd passed on" {
    cd "$T/owner/reli"
    run "$W" workflow run archon-ship "fix #12"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR=$T/home/repos/reli"* ]]
    [[ "$output" == *"ARGV: /usr/local/lib/archon-user/bin/archon workflow run archon-ship fix #12"* ]]
}

@test "the child environment is built from scratch: no caller secrets, the factory's own settings" {
    cd "$T/owner/reli"
    run "$W" workflow run archon-ship "fix #12"
    [ "$status" -eq 0 ]
    [[ "$output" != *secret* ]]
    [[ "$output" != *CLAUDE_CONFIG_DIR* ]]
    [[ "$output" == *"ENV=HOME=$T/home"* ]]
    [[ "$output" == *"ENV=CLAUDECODE=0"* ]]
    [[ "$output" == *"ENV=ENABLE_CLAUDEAI_MCP_SERVERS=false"* ]]
    [[ "$output" == *"ENV=TMPDIR=$T/home/tmp"* ]]
    [[ "$output" == *"ENV=PATH=$T/home/.bun/bin:"* ]]
}

@test "--cwd pointing at the owner's clone is mapped and stripped" {
    run "$W" workflow run archon-pr-maintenance --cwd "$T/owner/filmduel" "PR #7"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR=$T/home/repos/filmduel"* ]]
    [[ "$output" == *"ARGV: /usr/local/lib/archon-user/bin/archon workflow run archon-pr-maintenance PR #7"* ]]
}

@test "--cwd=<path> form is mapped too" {
    run "$W" workflow run archon-assist "--cwd=$T/owner/reli" "hi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR=$T/home/repos/reli"* ]]
}

@test "the factory clone path itself is accepted" {
    run "$W" workflow run archon-assist --dry-run --default-stubs --cwd "$T/home/repos/reli" "x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ARGV: /usr/local/lib/archon-user/bin/archon workflow run archon-assist --dry-run --default-stubs x"* ]]
}

@test "flags with values are validated and passed through" {
    cd "$T/owner/reli"
    run "$W" workflow run archon-review --input "scope=87" "review PR #87"
    [ "$status" -eq 0 ]
    [[ "$output" == *"workflow run archon-review --input scope=87 review PR #87"* ]]
    run "$W" workflow run archon-triage-issue "triage #5" --no-worktree
    [ "$status" -eq 0 ]
    [[ "$output" == *"workflow run archon-triage-issue triage #5 --no-worktree"* ]]
}

@test "workflow run outside a project root is refused" {
    cd "$T/elsewhere"
    run "$W" workflow run archon-ship "fix #1"
    [ "$status" -eq 66 ]
    cd "$T/owner/notaproject"
    run "$W" workflow run archon-ship "fix #1"
    [ "$status" -eq 66 ]
    run "$W" workflow run archon-ship --cwd "$T/owner/reli/ops" "fix #1"
    [ "$status" -eq 64 ]
}

@test "dangerous or unknown flags are refused" {
    cd "$T/owner/reli"
    for f in --workflow-source --config --stubs --stubs-init --folder --exec-code --spawn --bogus; do
        run "$W" workflow run archon-assist "$f" /tmp/x "hi"
        [ "$status" -eq 64 ] || { echo "not refused: $f"; return 1; }
    done
}

@test "paths with .. are refused" {
    run "$W" workflow run archon-assist --cwd "$T/owner/reli/../filmduel" "hi"
    [ "$status" -eq 64 ]
    run "$W" workflow runs --all --cwd "$T/owner/reli/../../elsewhere"
    [ "$status" -eq 64 ]
}

@test "a project name from the list that is not a plain name is ignored" {
    mkdir -p "$T/owner/evil" "$T/home/repos/evil/.git"
    run "$W" workflow run archon-assist --cwd "$T/owner/evil" "hi"
    [ "$status" -eq 66 ]
}

@test "unknown verbs and subcommands are refused" {
    run "$W" bash -c id
    [ "$status" -eq 64 ]
    run "$W" workflow install evil
    [ "$status" -eq 64 ]
    run "$W" workflow approve abc
    [ "$status" -eq 64 ]
    run "$W"
    [ "$status" -eq 64 ]
    run "$W" isolation cleanup
    [ "$status" -eq 64 ]
}

@test "read-only verbs map any path inside a project (the ops lib dir) to its clone" {
    run "$W" workflow runs --all --status running --limit 100 --json --cwd "$T/owner/reli/ops/cron/lib"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR=$T/home/repos/reli"* ]]
    [[ "$output" == *"ARGV: /usr/local/lib/archon-user/bin/archon workflow runs --all --status running --limit 100 --json"* ]]
}

@test "read-only verbs from an unrelated cwd use the first factory clone" {
    cd "$T/elsewhere"
    run "$W" workflow status
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR=$T/home/repos/reli"* ]]
}

@test "run ids are validated" {
    run "$W" workflow resume "abc-123_x" --detach --json --cwd "$T/owner/reli"
    [ "$status" -eq 0 ]
    [[ "$output" == *"workflow resume abc-123_x --detach --json"* ]]
    run "$W" workflow abandon '$(id)'
    [ "$status" -eq 64 ]
    run "$W" workflow get
    [ "$status" -eq 64 ]
    run "$W" workflow get a b
    [ "$status" -eq 64 ]
}

@test "--status and --limit values are validated" {
    run "$W" workflow runs --status 'running;id'
    [ "$status" -eq 64 ]
    run "$W" workflow runs --limit 1e9
    [ "$status" -eq 64 ]
}

@test "--version and validate run in a factory clone" {
    run "$W" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"ARGV: /usr/local/lib/archon-user/bin/archon --version"* ]]
    run "$W" validate workflows --cwd "$T/owner/filmduel"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR=$T/home/repos/filmduel"* ]]
    [[ "$output" == *"ARGV: /usr/local/lib/archon-user/bin/archon validate workflows"* ]]
    run "$W" --version extra
    [ "$status" -eq 64 ]
}

@test "claude-probe runs one haiku request with a bounded timeout" {
    run "$W" claude-probe 45
    [ "$status" -eq 0 ]
    [[ "$output" == *"ARGV: timeout 45 claude -p --model haiku ok"* ]]
    run "$W" claude-probe '5; id'
    [ "$status" -eq 64 ]
}

@test "the factory's Claude token is passed from its token file, read as data" {
    mkdir -p "$T/home/.config/archon-user"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abcDEF_123\n' > "$T/home/.config/archon-user/claude.env"
    run "$W" claude-probe
    [[ "$output" == *"ENV=CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abcDEF_123"* ]]
    printf 'CLAUDE_CODE_OAUTH_TOKEN=$(touch %s/pwned)\n' "$T" > "$T/home/.config/archon-user/claude.env"
    run "$W" claude-probe
    [[ "$output" != *CLAUDE_CODE_OAUTH_TOKEN* ]]
    [ ! -e "$T/pwned" ]
}

@test "a missing factory clone is cloned from GitHub, as the factory user" {
    rm -rf "$T/home/repos/filmduel"
    cat > "$T/home/.local/bin/git" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$T/git-argv"
[ "\$1" = clone ] && mkdir -p "\$4/.git"
exit 0
STUB
    chmod +x "$T/home/.local/bin/git"
    cd "$T/owner/filmduel"
    run "$W" workflow run archon-ship "fix #3"
    [ "$status" -eq 0 ]
    grep -q "clone -q https://github.com/alexsiri7/filmduel.git $T/home/repos/filmduel" "$T/git-argv"
    [[ "$output" == *"DIR=$T/home/repos/filmduel"* ]]
}

@test "refuses to run as anyone but the factory user" {
    export ARCHON_AS_USER=someone-else
    run "$W" --version
    [ "$status" -eq 65 ]
}

@test "the test hook is ignored under sudo (SUDO_USER set)" {
    export SUDO_USER=asiri
    run "$W" --version
    # Real constants apply: not user archon -> 65 (or 66 if /etc/archon-user is absent first).
    [ "$status" -eq 65 ] || [ "$status" -eq 66 ]
}

# The cron scripts detect live runs with pgrep over command lines. After the
# cutover a run shows up as the owner's sudo process plus archon's bun child;
# every guard pattern must still match them the way it matched the old
# "bun ~/.bun/bin/archon workflow run ..." process.
@test "pgrep guard patterns still match the runs the wrapper starts" {
    cd "$T/owner/reli"
    run "$W" workflow run archon-ship "fix #1572"
    child="bun ${output##*ARGV: }"                     # env -> #!/usr/bin/env bun
    parent="sudo -n -u archon /usr/local/bin/archon-as-archon workflow run archon-ship fix #1572"
    pm_parent="sudo -n -u archon /usr/local/bin/archon-as-archon workflow run archon-pr-maintenance --cwd /mnt/ext-fast/reli PR #9"
    review_parent="sudo -n -u archon /usr/local/bin/archon-as-archon workflow run archon-review --input scope=87 review PR #87"
    num=1572 repo_dir=/mnt/ext-fast/reli
    for line in "$child" "$parent"; do
        grep -qE "archon workflow run" <<<"$line"                                          # tool-update, issue-pickup
        grep -qE "archon workflow run|cli\.ts workflow run" <<<"$line"                     # archon-update
        grep -qE "archon workflow run archon-(ship|fix-github-issue).*#$num\\b" <<<"$line" # issue-pickup settle guard
        grep -qE "archon workflow run archon-(ship|fix-github-issue)" <<<"$line"           # issue-pickup pick_and_fire
    done
    grep -qE "archon workflow run.*--cwd.*$repo_dir" <<<"$pm_parent"                        # issue-pickup triage guard
    grep -qE "archon workflow run archon-(review|smart-pr-review)" <<<"$review_parent"     # pr-review
}
