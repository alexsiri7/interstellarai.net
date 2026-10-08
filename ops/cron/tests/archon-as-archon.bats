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

# gh-probe judges the token by a write it can never complete (a ref at the
# all-zero sha): 422 = may write, 403/404 = may not.
stub_gh() {  # stub_gh <token> <archon-fork-status>
    cat > "$T/home/.local/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "auth status") exit 0 ;;
  "api user --jq .login") echo alexsiri7 ;;
  "auth token") echo "$1" ;;
  *"repos/alexsiri7/Archon/git/refs"*) echo "HTTP/2.0 $2 X"; exit 1 ;;
  *"/git/refs"*) echo "HTTP/2.0 422 Unprocessable Entity"; exit 1 ;;
esac
STUB
    chmod +x "$T/home/.local/bin/gh"
}

@test "gh-probe: a fine-grained token that can write the factory repos and not the fork passes" {
    stub_gh github_pat_abc 404
    run "$W" gh-probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS gh: token can write alexsiri7/reli"* ]]
    [[ "$output" == *"PASS gh: token can write alexsiri7/filmduel"* ]]
    [[ "$output" == *"PASS gh: token cannot write alexsiri7/Archon (404)"* ]]
}

@test "gh-probe: a classic token or one that reaches the fork fails" {
    export ARCHON_AS_CONFIG_FILE="$T/no-config"   # not the host's /etc/archon-user/config (it may hold the opt-in)
    stub_gh gho_classic 404
    run "$W" gh-probe
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gh: not a fine-grained PAT"* ]]
    stub_gh github_pat_abc 422
    run "$W" gh-probe
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL gh: token can write alexsiri7/Archon"* ]]
}

@test "gh-probe: fork write access is a WARN only with the owner's ALLOW_ALL_REPOS_TOKEN=1 opt-in" {
    stub_gh github_pat_abc 422
    export ARCHON_AS_CONFIG_FILE="$T/config"
    printf '# opt-ins\nALLOW_ALL_REPOS_TOKEN=1\n' > "$T/config"
    run "$W" gh-probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN gh: token can write alexsiri7/Archon — owner opted in to an all-repositories token"* ]]
    [[ "$output" != *"FAIL"* ]]
    for c in 'ALLOW_ALL_REPOS_TOKEN=0' 'ALLOW_ALL_REPOS_TOKEN=yes' '# ALLOW_ALL_REPOS_TOKEN=1' 'ALLOW_ALL_REPOS_TOKEN=1x'; do
        printf '%s\n' "$c" > "$T/config"
        run "$W" gh-probe
        [ "$status" -eq 1 ] || { echo "accepted: $c"; return 1; }
        [[ "$output" == *"FAIL gh: token can write alexsiri7/Archon"*"--allow-all-repos-token"* ]]
    done
    rm -f "$T/config"
    run "$W" gh-probe
    [ "$status" -eq 1 ]
}

@test "selftest sweep skips exactly Debian's dpkg/apt/alternatives backups in /var/backups" {
    eval "$(grep -E '^SYSTEM_BACKUPS_RE=' "$W")"
    for f in dpkg.status.0 dpkg.status.1.gz dpkg.arch.0 dpkg.arch.6.gz dpkg.diversions.0 dpkg.statoverride.3.gz \
             apt.extended_states.0 apt.extended_states.2.gz alternatives.tar.0 alternatives.tar.1.gz dpkg.status; do
        [[ "/var/backups/$f" =~ $SYSTEM_BACKUPS_RE ]] || { echo "not skipped: $f"; return 1; }
    done
    for f in passwd.bak shadow.bak group.bak gshadow.bak dpkg.status.0/x dpkg.statusx dpkg.status.0.gz.bak \
             sub/dpkg.status.0 secrets.tar.gz; do
        ! [[ "/var/backups/$f" =~ $SYSTEM_BACKUPS_RE ]] || { echo "wrongly skipped: $f"; return 1; }
    done
    ! [[ "/home/x/var/backups/dpkg.status.0" =~ $SYSTEM_BACKUPS_RE ]]
}

@test "worktree-trim drops cargo build dirs idle 2 days, keeps fresh ones; --dry-run removes nothing" {
    echo notcloned > "$T/noprojects"   # no clone: the worktree half makes no gh calls
    export ARCHON_AS_PROJECTS_FILE="$T/noprojects"
    bd="$T/home/.cache/cargo-build"
    mkdir -p "$bd/ab/old1/debug/deps" "$bd/cd/new1/debug/deps" "$bd/ab/mixed/debug"
    touch -d '3 days ago' "$bd/ab/old1/debug/deps/libx.rlib" "$bd/ab/old1/debug/deps" "$bd/ab/old1/debug" "$bd/ab/old1"
    touch "$bd/cd/new1/debug/deps/liby.rlib"
    touch -d '3 days ago' "$bd/ab/mixed" "$bd/ab/mixed/debug"; touch "$bd/ab/mixed/debug/fresh"
    run "$W" worktree-trim --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would remove cargo build dir $bd/ab/old1 "* ]]
    [[ "$output" != *new1* && "$output" != *mixed* ]]
    [ -d "$bd/ab/old1" ]
    run "$W" worktree-trim
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed 1 idle cargo build dirs"* ]]
    [ ! -e "$bd/ab/old1" ] && [ -d "$bd/ab/mixed" ] && [ -d "$bd/cd/new1" ]
}

# 2026-10-02/03: pipeline-health ran worktree-trim from asiri's home, which
# archon cannot enter. The host's find (bfs) fails outright from there, every
# freshness test read "idle", and live run worktrees were deleted. The stub find
# fails the same way from $T/no-entry and is the real find anywhere else.
stub_find_failing_in() {
    mkdir -p "$T/fbin"
    cat > "$T/fbin/find" <<STUB
#!/usr/bin/env bash
case "\$(pwd -P)" in $1|$1/*) echo "find: cannot open working directory" >&2; exit 1 ;; esac
exec $(command -v find) "\$@"
STUB
    chmod +x "$T/fbin/find"
    export PATH="$T/fbin:$PATH"
}

@test "worktree-trim started from a directory find cannot work in removes nothing fresh" {
    echo testproj > "$T/projects"
    mkdir -p "$T/home/repos/testproj/.git" "$T/no-entry"
    wt="$T/home/.archon/workspaces/alexsiri7/testproj/worktrees/archon"
    mkdir -p "$wt/task-archon-ship-1" "$wt/task-archon-ship-2"
    touch -d '5 hours ago' "$wt/task-archon-ship-1"
    bd="$T/home/.cache/cargo-build"
    mkdir -p "$bd/cd/new1/debug"; touch "$bd/cd/new1/debug/x"
    stub_find_failing_in "$T/no-entry"
    # gh runs in the wrapper's own environment (archon's PATH): no open PRs.
    mkdir -p "$T/home/.local/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$T/home/.local/bin/gh"; chmod +x "$T/home/.local/bin/gh"
    cd "$T/no-entry"
    run "$W" worktree-trim
    cd /
    [ "$status" -eq 0 ]
    [ ! -e "$wt/task-archon-ship-1" ]      # idle 5h: still trimmed
    [ -d "$wt/task-archon-ship-2" ]        # fresh: a live run's
    [ -d "$bd/cd/new1" ]
}

@test "worktree-trim keeps whatever find cannot vouch for" {
    echo notcloned > "$T/noprojects"
    export ARCHON_AS_PROJECTS_FILE="$T/noprojects"
    bd="$T/home/.cache/cargo-build"
    mkdir -p "$bd/ab/old1/debug"
    touch -d '3 days ago' "$bd/ab/old1/debug" "$bd/ab/old1"
    stub_find_failing_in ""     # fails everywhere
    run "$W" worktree-trim
    [ "$status" -eq 0 ]
    [ -d "$bd/ab/old1" ]
}

# ── worktree-trim: /tmp and archon's own TMPDIR (#133) ──────────────────────
# make_tmp_sandbox: an idle dir, an idle file, a dir idle on the outside with a
# fresh file inside, a fresh dir and an idle session dir, in the /tmp stand-in
# and in $ARCHON_AS_HOME/tmp.
make_tmp_sandbox() {
    echo notcloned > "$T/noprojects"   # no clone: the worktree half makes no gh calls
    export ARCHON_AS_PROJECTS_FILE="$T/noprojects" ARCHON_AS_TMP_ROOT="$T/systmp"
    S="$T/systmp" H="$T/home/tmp"
    mkdir -p "$S/cargotest-builddir/ab/cdef/deps" "$S/review_5ea34/src" "$S/fresh" "$S/claude-1000/x" "$H/vam_check/target"
    touch "$S/cargotest-builddir/ab/cdef/deps/libx.rlib" "$S/review_5ea34/src/fresh.rs" "$S/fresh/a" "$S/old.log" "$H/vam_check/target/y"
    old='13 hours ago'
    touch -d "$old" "$S/cargotest-builddir/ab/cdef/deps/libx.rlib" "$S/cargotest-builddir/ab/cdef/deps" \
        "$S/cargotest-builddir/ab/cdef" "$S/cargotest-builddir/ab" "$S/cargotest-builddir" \
        "$S/review_5ea34/src" "$S/review_5ea34" "$S/old.log" "$S/claude-1000/x" "$S/claude-1000" \
        "$H/vam_check/target/y" "$H/vam_check/target" "$H/vam_check"
}

@test "worktree-trim --tmp-only: removes archon's entries idle 12h in /tmp and its TMPDIR, keeps active ones" {
    make_tmp_sandbox
    run "$W" worktree-trim --tmp-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed 3 idle tmp entries"* ]]
    [ ! -e "$S/cargotest-builddir" ] && [ ! -e "$S/old.log" ] && [ ! -e "$H/vam_check" ]
    [ -d "$S/review_5ea34" ]      # fresh file inside: a build still writing
    [ -d "$S/fresh" ]
    [ -d "$S/claude-1000" ]       # session dirs are never trimmed
}

@test "worktree-trim --tmp-only --dry-run lists candidates with sizes and removes nothing" {
    make_tmp_sandbox
    run "$W" worktree-trim --dry-run --tmp-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"would remove tmp entry $S/cargotest-builddir ("*"MB)"* ]]
    [[ "$output" == *"would remove tmp entry $H/vam_check ("* ]]
    [[ "$output" == *"dry run — 3 idle tmp entries"* ]]
    [[ "$output" != *review_5ea34* && "$output" != *fresh* && "$output" != *claude-1000* ]]
    [ -d "$S/cargotest-builddir" ] && [ -e "$S/old.log" ] && [ -d "$H/vam_check" ]
}

@test "worktree-trim keeps an idle tmp dir a live process has its cwd in, and sockets" {
    make_tmp_sandbox
    mkdir -p "$S/venv-server"; touch -d '13 hours ago' "$S/venv-server"
    (cd "$S/venv-server" && exec sleep 30) & pid=$!
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$S/agent.sock"
    touch -h -d '13 hours ago' "$S/agent.sock"
    run "$W" worktree-trim --tmp-only
    kill "$pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [ -d "$S/venv-server" ] && [ -S "$S/agent.sock" ]
    [ ! -e "$S/cargotest-builddir" ]
}

@test "worktree-trim without --tmp-only trims the tmp roots too; unknown flags are refused" {
    make_tmp_sandbox
    run "$W" worktree-trim
    [ "$status" -eq 0 ]
    [ ! -e "$S/cargotest-builddir" ] && [ -d "$S/review_5ea34" ]
    run "$W" worktree-trim --all
    [ "$status" -eq 64 ]
    run "$W" worktree-trim /tmp
    [ "$status" -eq 64 ]
}

@test "worktree-trim never removes a symlink's target, only an idle link it owns" {
    make_tmp_sandbox
    mkdir -p "$T/precious"; touch "$T/precious/keep"
    ln -s "$T/precious" "$S/link"; touch -h -d '13 hours ago' "$S/link"
    run "$W" worktree-trim --tmp-only
    [ "$status" -eq 0 ]
    [ ! -L "$S/link" ] && [ -e "$T/precious/keep" ]
}

@test "--account main: main's token file and config dir, never the factory's" {
    mkdir -p "$T/home/.config/archon-user" "$T/home/.claude-main"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-factoryTOKEN_1\n' > "$T/home/.config/archon-user/claude.env"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-mainTOKEN_22\n' > "$T/home/.config/archon-user/claude-main.env"
    cd "$T/owner/reli"
    run "$W" --account main workflow run archon-ship "fix #12"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ENV=CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-mainTOKEN_22"* ]]
    [[ "$output" != *factoryTOKEN* ]]
    [[ "$output" == *"ENV=CLAUDE_CONFIG_DIR=$T/home/.claude-main"* ]]
    [[ "$output" == *"ARGV: /usr/local/lib/archon-user/bin/archon workflow run archon-ship fix #12"* ]]
    run "$W" --account factory claude-probe
    [[ "$output" == *factoryTOKEN* ]]
    [[ "$output" != *CLAUDE_CONFIG_DIR* ]]
}

@test "--account main without its credential or config dir: refused, no fallback to the factory" {
    mkdir -p "$T/home/.config/archon-user"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-factoryTOKEN_1\n' > "$T/home/.config/archon-user/claude.env"
    run "$W" --account main claude-probe
    [ "$status" -eq 69 ]
    [[ "$output" != *factoryTOKEN* ]]
    printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-mainTOKEN_22\n' > "$T/home/.config/archon-user/claude-main.env"
    run "$W" --account main claude-probe
    [ "$status" -eq 69 ]
}

@test "--account takes only factory or main" {
    run "$W" --account other claude-probe
    [ "$status" -eq 64 ]
    run "$W" --account
    [ "$status" -eq 64 ]
}
