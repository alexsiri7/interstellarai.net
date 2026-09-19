#!/usr/bin/env bats
# End-to-end tests for ops/cron/archon-update.sh against a fixture of real git
# repos — a bare "upstream" with release tags, a bare "origin" (the fork) and
# a "live" clone on upstream-sync-0.10 with one factory commit on top — and
# stubs for bun, archon, systemctl, curl (ntfy + health), gh and pgrep.
#
# Run: bunx bats ops/cron/tests/archon-update.bats

setup() {
    export T="$BATS_TMPDIR/archon-update-$$"
    rm -rf "$T"
    mkdir -p "$T/bin" "$T/state" "$T/logs" "$T/home" "$T/wt" "$T/projects"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$CRON_DIR/archon-update.sh"
    export PATH="$T/bin:$PATH"
    export HOME="$T/home"
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
    export GIT_CONFIG_GLOBAL="$T/gitconfig"
    printf '[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n' > "$GIT_CONFIG_GLOBAL"

    export ARCHON_LIVE_DIR="$T/live"
    export ARCHON_WORKTREE_BASE="$T/wt"
    export ARCHON_UPDATE_STATE_DIR="$T/state"
    export ARCHON_CRON_LOG_DIR="$T/logs"
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    echo 'NTFY_TOPIC=test-topic' > "$T/secrets.env"
    export ARCHON_UPDATE_VALIDATE_DIRS="$T/projects/reli"
    export ARCHON_UPDATE_HEALTH_TIMEOUT=4
    export ARCHON_RUNS_SNAPSHOT="$T/runs-snapshot"
    export ARCHON_UPDATE_ISSUE_REPO="alexsiri7/Archon"

    export NTFY_LOG="$T/ntfy"            # "<title> | <body>" per ntfy
    export BUN_ARGV="$T/bun-argv"        # every bun invocation: "<cwd> :: <args>"
    export GH_ARGV="$T/gh-argv"
    export SYSTEMCTL_ARGV="$T/systemctl-argv"
    export STUB_TYPECHECK_RC=0
    export STUB_TEST_FAIL=""             # name of a test that fails under the new tree
    export STUB_VALIDATE_NEW_ERROR=""    # workflow that errors only under the new CLI
    export STUB_GENERATE_CHANGE=0        # 1: generate:bundled rewrites the generated file
    export STUB_BUN_LOCK_CHANGE=0        # 1: bun install (unfrozen) rewrites bun.lock
    export STUB_HEALTH_FAIL_VERSION=""   # live VERSION for which the health URL answers 500
    export STUB_ARCHON_RUNNING=""        # workflow_name of a running run in the listing
    export STUB_ARCHON_RUNS_FAIL=0       # 1: the run listing is unreadable
    export STUB_PGREP_HIT=0

    write_stubs
    build_repos
}

teardown() {
    rm -rf "$T"
}

write_stubs() {
    # A validate report in the CLI's shape: one pre-existing error, always.
    cat > "$T/bin/validate-report" <<'STUB'
#!/usr/bin/env bash
# $1 = dir, $2 = extra erroring workflow (optional)
echo
echo "Validating workflows in $1"
echo
echo "  archon-architect                         ok"
echo "  archon-smart-pr-review                   ERRORS"
echo "    ERROR [mcp] Node 'notify': MCP config file not found: '.archon/mcp/ntfy.json'"
[ -n "${2:-}" ] && printf '  %-40s ERRORS\n    ERROR [schema] stub\n' "$2"
echo "  archon-ship                              ok"
echo
echo "Results: 36 valid, 1 with errors, 8 with warnings"
STUB
    cat > "$T/bin/bun" <<'STUB'
#!/usr/bin/env bash
echo "$PWD :: $*" >> "$BUN_ARGV"
case "$*" in
    "install"|"install --frozen-lockfile")
        mkdir -p node_modules
        if [ "$STUB_BUN_LOCK_CHANGE" = 1 ] && [ "$*" = "install" ]; then echo "# resolved by stub" >> bun.lock; fi
        exit 0 ;;
    "run type-check")
        echo "@archon/cli type-check: Exited with code $STUB_TYPECHECK_RC"; exit "$STUB_TYPECHECK_RC" ;;
    "--filter * test")
        echo "@archon/cli test: (pass) something [1.00ms]"
        if [ -n "$STUB_TEST_FAIL" ]; then
            echo "@archon/cli test: (fail) $STUB_TEST_FAIL [5000.00ms]"
            echo "@archon/cli test:  1 pass"; echo "@archon/cli test:  1 fail"; exit 1
        fi
        echo "@archon/cli test:  2 pass"; echo "@archon/cli test:  0 fail"; exit 0 ;;
    "test ./scripts/")
        echo " 147 pass"; echo " 0 fail"; exit 0 ;;
    "run generate:bundled")
        [ "$STUB_GENERATE_CHANGE" = 1 ] && echo "// regenerated for $(cat VERSION)" >> packages/workflows/src/defaults/bundled-defaults.generated.ts
        echo "Wrote bundled-defaults.generated.ts"; exit 0 ;;
    */packages/cli/src/cli.ts" validate workflows --cwd "*)
        cli="$1"; wt="${cli%/packages/cli/src/cli.ts}"
        [ -f "$wt/VERSION" ] || { echo "stub: no VERSION in $wt" >&2; exit 2; }
        validate-report "${*##* --cwd }" "$STUB_VALIDATE_NEW_ERROR"; exit 1 ;;
esac
echo "bun stub: unexpected $*" >&2; exit 2
STUB
    cat > "$T/bin/archon" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "--version"|"version") echo "Archon CLI v$(cat "$ARCHON_LIVE_DIR/VERSION")"; echo "  Build: stub"; exit 0 ;;
    "workflow runs --all --status "*)
        if [ "$STUB_ARCHON_RUNS_FAIL" = 1 ]; then echo '{"ok":false,"error":"db locked"}'; exit 1; fi
        st=$(printf '%s\n' "$*" | sed -E 's/.*--status ([a-z]+).*/\1/')
        if [ "$st" = running ] && [ -n "$STUB_ARCHON_RUNNING" ]; then
            printf '{"runs":[{"id":"r1","workflow_name":"%s","status":"running","user_message":"fix #7","metadata":{"workflow_source":{"origin":"/mnt/ext-fast/reli"}}}]}\n' "$STUB_ARCHON_RUNNING"
        else
            echo '{"runs":[]}'
        fi
        exit 0 ;;
    "validate workflows --cwd "*) validate-report "${*##* --cwd }"; exit 1 ;;
esac
echo "archon stub: unexpected $*" >&2; exit 2
STUB
    cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SYSTEMCTL_ARGV"
exit 0
STUB
    cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
title=""; body=""; health=0
while [ $# -gt 0 ]; do
    case "$1" in
        -H) case "$2" in Title:*) title="${2#Title: }" ;; esac; shift ;;
        -d) body="$2"; shift ;;
        -w) health=1; shift ;;
    esac
    shift
done
if [ "$health" = 1 ]; then
    v=$(cat "$ARCHON_LIVE_DIR/VERSION" 2>/dev/null)
    if [ -n "$STUB_HEALTH_FAIL_VERSION" ] && [ "$v" = "$STUB_HEALTH_FAIL_VERSION" ]; then printf 500; else printf 200; fi
    exit 0
fi
echo "$title | $body" >> "$NTFY_LOG"
STUB
    cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGV"
n=$(grep -c '^issue create' "$GH_ARGV")
echo "https://github.com/alexsiri7/Archon/issues/$((100 + n))"
STUB
    cat > "$T/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
[ "$STUB_PGREP_HIT" = 1 ] && { echo 4242; exit 0; }
exit 1
STUB
    chmod +x "$T"/bin/*
}

# upstream.git: main with v0.10.0, v0.10.1. origin.git: the fork. live: a
# clone with remotes upstream + origin, on upstream-sync-0.10 = v0.10.1 plus
# one factory commit (FACTORY.md, a line appended to README.md).
build_repos() {
    git init -q --bare "$T/upstream.git"
    git init -q --bare "$T/origin.git"
    git init -q "$T/seed"
    (
        cd "$T/seed"
        mkdir -p packages/cli/src packages/workflows/src/defaults
        echo "readme v1" > README.md
        echo "node_modules/" > .gitignore
        printf '{\n  "name": "archon",\n  "scripts": {\n    "test": "bun --filter * --parallel test",\n    "type-check": "bun --filter * type-check",\n    "generate:bundled": "bun run scripts/generate-bundled-defaults.ts"\n  }\n}\n' > package.json
        echo "# lock v0.10.0" > bun.lock
        echo "// cli" > packages/cli/src/cli.ts
        echo "// generated 0.10.0" > packages/workflows/src/defaults/bundled-defaults.generated.ts
        echo "0.10.0" > VERSION
        git add -A && git commit -q -m "Release 0.10.0" && git tag v0.10.0
        echo "0.10.1" > VERSION
        git commit -q -am "Release 0.10.1" && git tag v0.10.1
        git push -q "$T/upstream.git" main --tags
    )
    rm -rf "$T/seed"
    git clone -q "$T/upstream.git" "$T/live"
    (
        cd "$T/live"
        git remote rename origin upstream
        git remote add origin "$T/origin.git"
        git checkout -q -b upstream-sync-0.10
        echo "factory customizations" > FACTORY.md
        echo "factory line" >> README.md
        git add -A && git commit -q -m "carry local factory customizations"
        git push -q -u origin upstream-sync-0.10 2>/dev/null
    )
    git init -q "$T/projects/reli" && (cd "$T/projects/reli" && echo x > f && git add f && git commit -q -m init)
}

# publish_release <version> [conflict]: a new upstream release tag. With
# `conflict`, the release rewrites README.md line 1, which the factory commit
# touches next to.
publish_release() {
    local v="$1" mode="${2:-}"
    rm -rf "$T/rel"
    git clone -q "$T/upstream.git" "$T/rel" 2>/dev/null
    (
        cd "$T/rel"
        echo "$v" > VERSION
        echo "# lock $v" > bun.lock
        echo "- $v" >> CHANGELOG.md
        [ "$mode" = conflict ] && echo "readme v2 ($v)" > README.md
        git add -A && git commit -q -m "Release $v" && git tag "v$v"
        git push -q origin main "v$v"
    )
    rm -rf "$T/rel"
}

status_field() { grep "^$1=" "$T/state/archon-update-status" | cut -d= -f2-; }
live_sha() { git -C "$T/live" rev-parse HEAD; }
live_branch() { git -C "$T/live" branch --show-current; }
restarts() { grep -c 'restart archon-serve.service' "$SYSTEMCTL_ARGV" 2>/dev/null || echo 0; }
issues_filed() { grep -c '^issue create' "$GH_ARGV" 2>/dev/null || echo 0; }

@test "no newer release (pre-releases ignored): logs the current version, status ok/noop, nothing touched" {
    # a pre-release tag alone must not count
    rm -rf "$T/rel" && git clone -q "$T/upstream.git" "$T/rel" 2>/dev/null
    (cd "$T/rel" && git tag v0.12.0-rc.1 && git push -q origin v0.12.0-rc.1) && rm -rf "$T/rel"
    before=$(live_sha)
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"base release v0.10.1; upstream newest release v0.10.1"* ]]
    [[ "$output" == *"current v0.10.1 — nothing to do"* ]]
    [ "$(status_field last_run_status)" = "ok" ]
    [ "$(status_field outcome)" = "noop" ]
    [ "$(status_field current)" = "v0.10.1" ]
    [ "$(status_field last_ok)" = "$(status_field last_run)" ]
    [ ! -f "$NTFY_LOG" ]
    [ ! -f "$BUN_ARGV" ]
    [ ! -f "$SYSTEMCTL_ARGV" ]
    [ "$(live_sha)" = "$before" ]
    [ "$(live_branch)" = "upstream-sync-0.10" ]
    [ -z "$(git -C "$T/live" status --porcelain)" ]
    [ "$(git -C "$T/live" tag | wc -l)" -eq 2 ]          # no fetch on a no-op
    [ -z "$(ls -A "$T/wt")" ]
}

@test "newer release, clean merge: proven in a worktree, pushed, live swapped, service healthy, ntfy" {
    publish_release 0.11.0
    export STUB_GENERATE_CHANGE=1 STUB_BUN_LOCK_CHANGE=1
    old_sha=$(live_sha)
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"update available: v0.10.1 → v0.11.0 (branch upstream-sync-0.11.0"* ]]
    wt="$T/wt/archon-update-v0.11.0"
    # every proof step ran in the worktree, in order
    grep -q "^$wt :: install\$" "$BUN_ARGV"
    grep -q "^$wt :: run type-check\$" "$BUN_ARGV"
    grep -q "^$wt :: --filter \* test\$" "$BUN_ARGV"
    grep -q "^$wt :: test ./scripts/\$" "$BUN_ARGV"
    grep -q "^$wt :: run generate:bundled\$" "$BUN_ARGV"
    grep -q "^$T/projects/reli :: $wt/packages/cli/src/cli.ts validate workflows --cwd $T/projects/reli\$" "$BUN_ARGV"
    grep -q "^$wt :: $wt/packages/cli/src/cli.ts validate workflows --cwd $wt\$" "$BUN_ARGV"
    [ "$(grep -n 'run type-check' "$BUN_ARGV" | cut -d: -f1)" -lt "$(grep -n 'run generate:bundled' "$BUN_ARGV" | cut -d: -f1)" ]
    # the pre-existing validate error is not a regression
    [[ "$output" == *"validate $T/projects/reli: errors before [archon-smart-pr-review] after [archon-smart-pr-review]"* ]]
    [[ "$output" == *"validation: no new errors under v0.11.0"* ]]
    # branch on the fork, live swapped onto it, factory commit carried, follow-up commits present
    git -C "$T/origin.git" show-ref --verify --quiet refs/heads/upstream-sync-0.11.0
    [ "$(live_branch)" = "upstream-sync-0.11.0" ]
    [ "$(cat "$T/live/VERSION")" = "0.11.0" ]
    [ -f "$T/live/FACTORY.md" ]
    [ "$(git -C "$T/live" rev-parse origin/upstream-sync-0.11.0)" = "$(live_sha)" ]
    git -C "$T/live" log --format=%s | grep -q "^Merge tag 'v0.11.0'"
    git -C "$T/live" log --format=%s | grep -q "^chore: refresh bun.lock after merging v0.11.0"
    git -C "$T/live" log --format=%s | grep -q "^post-merge: regenerate bundled defaults for v0.11.0"
    grep -q "regenerated for 0.11.0" "$T/live/packages/workflows/src/defaults/bundled-defaults.generated.ts"
    [ -z "$(git -C "$T/live" status --porcelain)" ]
    [ "$(git -C "$T/live" describe --tags --abbrev=0)" = "v0.11.0" ]
    # live install is frozen; one restart; health polled
    grep -q "^$T/live :: install --frozen-lockfile\$" "$BUN_ARGV"
    [ "$(restarts)" -eq 1 ]
    [[ "$output" == *"healthy: http://127.0.0.1:3090/ → 200, Archon CLI v0.11.0"* ]]
    # rollback record, status, ntfy, worktree gone
    grep -q "^previous_sha=$old_sha\$" "$T/state/archon-update-previous"
    grep -q "^previous_branch=upstream-sync-0.10\$" "$T/state/archon-update-previous"
    [ "$(status_field last_run_status)" = "ok" ]
    [ "$(status_field outcome)" = "updated" ]
    [ "$(status_field latest)" = "v0.11.0" ]
    [ "$(grep -c '' "$NTFY_LOG")" -eq 1 ]
    grep -q '^Archon updated v0.10.1 → v0.11.0 |' "$NTFY_LOG"
    [ ! -d "$wt" ]
    [ "$(git -C "$T/live" worktree list | wc -l)" -eq 1 ]
    [ "$(issues_filed)" -eq 0 ]
    # the old branch stays as the rollback target
    git -C "$T/live" show-ref --verify --quiet refs/heads/upstream-sync-0.10

    # and the week after: nothing to do
    rm -f "$NTFY_LOG" "$BUN_ARGV"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"current v0.11.0 — nothing to do"* ]]
    [ ! -f "$NTFY_LOG" ]
}

@test "merge conflict: aborted, worktree removed, ntfy with the files, one issue per tag" {
    publish_release 0.11.0 conflict
    before=$(live_sha)
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflicting files: README.md"* ]]
    [ "$(status_field last_run_status)" = "failed" ]
    [ "$(status_field last_run_failed)" = "merge" ]
    [ "$(status_field last_ok)" = "0" ]
    grep -q '^Archon update FAILED: merge | merge conflicts' "$NTFY_LOG"
    [ "$(issues_filed)" -eq 1 ]
    grep -q '^issue create --repo alexsiri7/Archon --title Upstream v0.11.0 merge conflicts --body ' "$GH_ARGV"
    grep -q 'README.md' "$GH_ARGV"
    grep -q 'ARCHON-0.10-CUTOVER.md' "$GH_ARGV"
    [ "$(cat "$T/state/archon-update-issue-v0.11.0")" = "https://github.com/alexsiri7/Archon/issues/101" ]
    # nothing left behind, live untouched, nothing ran in the worktree
    [ ! -d "$T/wt/archon-update-v0.11.0" ]
    ! git -C "$T/live" show-ref --verify --quiet refs/heads/upstream-sync-0.11.0
    [ "$(live_sha)" = "$before" ]
    [ "$(live_branch)" = "upstream-sync-0.10" ]
    [ ! -f "$BUN_ARGV" ]
    [ ! -f "$SYSTEMCTL_ARGV" ]
    ! git -C "$T/origin.git" show-ref --verify --quiet refs/heads/upstream-sync-0.11.0

    # second run, same tag: ntfy again, no second issue
    rm -f "$NTFY_LOG"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"issue for v0.11.0 already filed: https://github.com/alexsiri7/Archon/issues/101"* ]]
    [ "$(issues_filed)" -eq 1 ]
    grep -q '^Archon update FAILED: merge' "$NTFY_LOG"
}

@test "type-check fails: no push, no swap, worktree kept, ntfy names it, issue filed once" {
    publish_release 0.11.0
    export STUB_TYPECHECK_RC=2
    before=$(live_sha)
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    wt="$T/wt/archon-update-v0.11.0"
    [ -d "$wt" ]
    [ "$(git -C "$wt" branch --show-current)" = "upstream-sync-0.11.0" ]
    [ "$(status_field last_run_failed)" = "type-check" ]
    [ "$(status_field worktree)" = "$wt" ]
    grep -q "^Archon update FAILED: type-check | bun run type-check failed. Worktree kept for inspection: $wt (branch upstream-sync-0.11.0)" "$NTFY_LOG"
    [ "$(issues_filed)" -eq 1 ]
    grep -q -- '--title Upstream v0.11.0 bun run type-check failed' "$GH_ARGV"
    ! grep -q 'test' "$BUN_ARGV"                        # stopped at the failing step
    ! git -C "$T/origin.git" show-ref --verify --quiet refs/heads/upstream-sync-0.11.0
    [ "$(live_sha)" = "$before" ]
    [ "$(live_branch)" = "upstream-sync-0.10" ]
    [ ! -f "$SYSTEMCTL_ARGV" ]

    # next week, still failing: the leftover worktree and branch are replaced, no second issue
    rm -f "$NTFY_LOG"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"removing leftover worktree $wt"* ]]
    [[ "$output" == *"deleting leftover local branch upstream-sync-0.11.0"* ]]
    [ "$(issues_filed)" -eq 1 ]
    [ -d "$wt" ]
}

@test "a failing test or a new validation error stops before the swap" {
    publish_release 0.11.0
    export STUB_TEST_FAIL="workflowRunCommand > applies the config"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(status_field last_run_failed)" = "test" ]
    grep -q 'workflowRunCommand > applies the config' "$GH_ARGV"
    [ "$(live_branch)" = "upstream-sync-0.10" ]
    ! grep -q 'generate:bundled' "$BUN_ARGV"

    export STUB_TEST_FAIL=""
    export STUB_VALIDATE_NEW_ERROR="archon-ship"
    rm -f "$NTFY_LOG" "$BUN_ARGV" "$T/state/archon-update-issue-v0.11.0"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(status_field last_run_failed)" = "validate" ]
    [[ "$output" == *"validate $T/projects/reli: errors before [archon-smart-pr-review] after [archon-ship archon-smart-pr-review]"* ]]
    [[ "$output" == *"$T/projects/reli: archon-ship"* ]]
    grep -q '^Archon update FAILED: validate | workflow validation regressed under v0.11.0' "$NTFY_LOG"
    grep -q 'archon-ship' "$GH_ARGV"
    [ "$(live_branch)" = "upstream-sync-0.10" ]
    ! git -C "$T/origin.git" show-ref --verify --quiet refs/heads/upstream-sync-0.11.0
    [ ! -f "$SYSTEMCTL_ARGV" ]
}

@test "health check fails after the swap: rolled back to the previous sha, ntfy, branch left on the fork" {
    publish_release 0.11.0
    export STUB_HEALTH_FAIL_VERSION=0.11.0
    old_sha=$(live_sha)
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not healthy after 4s: HTTP 500"* ]]
    [[ "$output" == *"rolling back to upstream-sync-0.10 ($old_sha)"* ]]
    [ "$(live_sha)" = "$old_sha" ]
    [ "$(live_branch)" = "upstream-sync-0.10" ]
    [ "$(cat "$T/live/VERSION")" = "0.10.1" ]
    [ "$(restarts)" -eq 2 ]
    [ "$(grep -c "^$T/live :: install --frozen-lockfile\$" "$BUN_ARGV")" -eq 2 ]
    [ "$(status_field last_run_status)" = "failed" ]
    [ "$(status_field last_run_failed)" = "health-rolled-back" ]
    grep -q "^Archon update rolled back | v0.11.0 failed the health check after the swap; $T/live is back on upstream-sync-0.10 @ ${old_sha:0:12} and healthy" "$NTFY_LOG"
    [ "$(issues_filed)" -eq 1 ]
    grep -q -- '--title Upstream v0.11.0: unhealthy after swap, rolled back' "$GH_ARGV"
    git -C "$T/origin.git" show-ref --verify --quiet refs/heads/upstream-sync-0.11.0
    git -C "$T/live" show-ref --verify --quiet refs/heads/upstream-sync-0.11.0
    [ ! -d "$T/wt/archon-update-v0.11.0" ]

    # the next attempt rebuilds the branch and refuses to push over the diverged one
    export STUB_HEALTH_FAIL_VERSION=""
    rm -f "$NTFY_LOG" "$SYSTEMCTL_ARGV"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(status_field last_run_failed)" = "push" ]
    [ "$(live_sha)" = "$old_sha" ]
    [ ! -f "$SYSTEMCTL_ARGV" ]
    grep -q '^Archon update FAILED: push |' "$NTFY_LOG"
    [ -d "$T/wt/archon-update-v0.11.0" ]
}

@test "an active archon run defers the update: nothing fetched, status deferred, last_ok untouched" {
    publish_release 0.11.0
    export STUB_ARCHON_RUNNING=archon-ship
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"archon run(s) active: archon-ship (/mnt/ext-fast/reli) — deferring the update"* ]]
    [ "$(status_field last_run_status)" = "ok" ]
    [ "$(status_field outcome)" = "deferred" ]
    [ "$(status_field last_ok)" = "0" ]
    [ "$(git -C "$T/live" tag | wc -l)" -eq 2 ]
    [ ! -f "$BUN_ARGV" ]
    [ ! -f "$NTFY_LOG" ]

    export STUB_ARCHON_RUNNING="" STUB_PGREP_HIT=1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"'archon workflow run' process is alive — deferring"* ]]

    export STUB_PGREP_HIT=0 STUB_ARCHON_RUNS_FAIL=1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot list archon runs this tick — deferring"* ]]
    [ "$(status_field outcome)" = "deferred" ]
}

@test "a second tick while one runs exits at the lock" {
    publish_release 0.11.0
    ( flock 9; sleep 3 ) 9>"$T/state/archon-update.lock" &
    sleep 0.5
    run "$SCRIPT"
    wait
    [ "$status" -eq 0 ]
    [[ "$output" == *"another archon-update run holds"* ]]
    [ ! -f "$BUN_ARGV" ]
}

@test "missing NTFY_TOPIC fails before doing anything" {
    : > "$T/secrets.env"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -f "$T/state/archon-update-status" ]
}
