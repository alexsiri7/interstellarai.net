#!/usr/bin/env bats
# ops/host/archon-ops/archon-ops: the root-owned entrypoints and the snapshot
# promotion, run as a normal user through the ARCHON_OPS_TEST hook (the test
# user stands in for root and for asiri; the snapshot lives in a sandbox).
#
# Run: bunx bats ops/cron/tests/archon-ops.bats

bats_require_minimum_version 1.5.0

setup() {
    T="$BATS_TEST_TMPDIR"
    A="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../host/archon-ops" && pwd)/archon-ops"
    L="$T/live"
    R="$T/ops-root"
    mkdir -m 0755 "$R"
    export ARCHON_OPS_TEST=1 ARCHON_OPS_ROOT="$R" ARCHON_OPS_LIVE="$L" ARCHON_OPS_FLAG_FILE="$T/run-as"
    echo "ARCHON_RUN_AS=archon" > "$T/run-as"
    unset SUDO_USER
    git init -q -b main "$L"
    mkdir -p "$L/ops/host/archon-user" "$L/ops/cron" "$L/web"
    # stub installers: print the args, cwd and environment they were started with
    printf '#!/bin/bash\necho "user-install args:$*"; echo "cwd:$PWD"; env | sort | sed "s/^/env:/"\n' > "$L/ops/host/archon-user/install.sh"
    printf '#!/bin/bash\necho "host-install args:$*"\n' > "$L/ops/host/install.sh"
    chmod +x "$L/ops/host/archon-user/install.sh" "$L/ops/host/install.sh"
    echo data > "$L/ops/cron/data.txt"
    echo site > "$L/web/index.html"
    commit init
    git -C "$L" update-ref refs/remotes/origin/main HEAD
}

commit() { git -C "$L" add -A && git -C "$L" -c user.name=t -c user.email=t@t commit -q -m "$1"; }
promote() { "$A" archon-ops-promote "$@"; }

@test "promote: snapshots HEAD's ops/ (committed content only), flips current, root-only modes" {
    sha=$(git -C "$L" rev-parse HEAD)
    run promote
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"promoted $sha (was none)"* ]]
    [ -L "$R/current" ]
    [ "$(readlink "$R/current")" = "releases/$sha" ]
    rel="$R/releases/$sha"
    [ -f "$rel/ops/cron/data.txt" ]
    [ ! -e "$rel/web" ]                                    # only ops/
    [ "$(stat -c %a "$rel/ops/host/install.sh")" = 755 ]
    [ "$(stat -c %a "$rel/ops/cron/data.txt")" = 644 ]
    [ -z "$(find "$rel" -type d ! -perm 0755)" ]
    [ -z "$(find "$rel" -perm /022)" ]
    [ -z "$(find "$rel" ! -type f ! -type d)" ]
    [ -z "$(find "$R" ! -user "$(id -un)")" ]
}

@test "promote: a modified tracked file under ops/ is refused, nothing changes" {
    promote
    before=$(readlink "$R/current")
    echo changed >> "$L/ops/cron/data.txt"
    run promote
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to promote: ops/ has local changes"* ]]
    [[ "$output" == *"ops/cron/data.txt"* ]]
    [ "$(readlink "$R/current")" = "$before" ]
}

@test "promote: an untracked file under ops/ is refused; changes outside ops/ are not" {
    echo new > "$L/ops/cron/stray.sh"
    run promote
    [ "$status" -eq 1 ]
    [[ "$output" == *"?? ops/cron/stray.sh"* ]]
    [ ! -e "$R/current" ]
    rm "$L/ops/cron/stray.sh"
    echo edited >> "$L/web/index.html"; echo x > "$L/web/new.html"
    run promote
    [ "$status" -eq 0 ]
}

@test "promote: HEAD not on origin/main is refused (a local commit the review gate never saw)" {
    echo local >> "$L/ops/cron/data.txt"; commit local
    run promote
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not on origin/main"* ]]
    [ ! -e "$R/current" ]
    git -C "$L" update-ref -d refs/remotes/origin/main
    run promote
    [ "$status" -eq 1 ]
    [[ "$output" == *"no refs/remotes/origin/main"* ]]
}

@test "promote: HEAD behind origin/main (fetched, not yet approved) promotes HEAD, not origin/main" {
    old=$(git -C "$L" rev-parse HEAD)
    echo unreviewed >> "$L/ops/cron/data.txt"; commit unreviewed
    git -C "$L" update-ref refs/remotes/origin/main HEAD
    git -C "$L" reset -q --hard "$old"
    run promote
    [ "$status" -eq 0 ]
    [ "$(readlink "$R/current")" = "releases/$old" ]
    ! grep -q unreviewed "$R/releases/$old/ops/cron/data.txt"
}

@test "promote: a symlink under ops/ is refused" {
    ln -s /etc/shadow "$L/ops/cron/evil"; commit link
    git -C "$L" update-ref refs/remotes/origin/main HEAD
    run promote
    [ "$status" -eq 1 ]
    [[ "$output" == *"not plain files"* ]]
    [ ! -e "$R/current" ]
}

@test "promote: git runs no repo hooks or fsmonitor from the checkout's config" {
    printf '#!/bin/sh\ntouch %s/fsmonitor-ran\n' "$T" > "$T/fsmon"; chmod +x "$T/fsmon"
    git -C "$L" config core.fsmonitor "$T/fsmon"
    mkdir -p "$T/hooks"; printf '#!/bin/sh\ntouch %s/hook-ran\n' "$T" > "$T/hooks/post-index-change"; chmod +x "$T/hooks/post-index-change"
    git -C "$L" config core.hooksPath "$T/hooks"
    run promote
    [ "$status" -eq 0 ]
    [ ! -e "$T/fsmonitor-ran" ]
    [ ! -e "$T/hook-ran" ]
}

@test "promote: a gitfile or symlinked .git is refused" {
    mv "$L/.git" "$T/real.git"; ln -s "$T/real.git" "$L/.git"
    run promote
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a plain directory"* ]]
}

@test "promote: same sha again is a no-op flip; keeps the last 5 releases and never prunes current" {
    promote
    first=$(git -C "$L" rev-parse HEAD)
    run promote
    [[ "$output" == *"already present"* ]]
    [[ "$output" == *"(unchanged)"* ]]
    for i in 1 2 3 4 5 6; do
        echo "$i" >> "$L/ops/cron/data.txt"; commit "c$i"
        git -C "$L" update-ref refs/remotes/origin/main HEAD
        # Age only the release about to stop being current, so every release
        # keeps a distinct, ordered mtime (touching all of them tied the oldest
        # and left which one prune kept to hash order: a flaky test).
        touch -d "-$((10 - i)) min" "$R/$(readlink "$R/current")"
        promote >/dev/null
    done
    [ "$(find "$R/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 5 ]
    [ ! -e "$R/releases/$first" ]
    [ -d "$R/$(readlink "$R/current")" ]
    [ "$(readlink "$R/current")" = "releases/$(git -C "$L" rev-parse HEAD)" ]
}

@test "promote --status: current, promotability and the review-gate warning" {
    promote
    run promote --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"current:       $(git -C "$L" rev-parse HEAD) (checked: root-only)"* ]]
    [[ "$output" == *"(promotable)"* ]]
    [[ "$output" == *"up to date:    yes"* ]]
    echo x >> "$L/ops/cron/data.txt"; commit more
    run promote --status
    [[ "$output" == *"NOT promotable"*"not on origin/main"* ]]
    run promote --bogus
    [ "$status" -eq 1 ]
    echo "ARCHON_RUN_AS=asiri" > "$T/run-as"
    git -C "$L" update-ref refs/remotes/origin/main HEAD
    run promote
    [[ "$output" == *"WARNING: ARCHON_RUN_AS is 'asiri'"* ]]
}

@test "entrypoints: run the snapshot's installer with the args, from /, under env -i" {
    promote
    mkdir -p "$T/sbin"; cp "$A" "$T/sbin/archon-user-install"; cp "$A" "$T/sbin/archon-host-install"
    SECRET_THING=leak ARCHON_USER_INSTALL_SANDBOX=/tmp/x run "$T/sbin/archon-user-install" --drain --force
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"user-install args:--drain --force"* ]]
    [[ "$output" == *"cwd:/"* ]]
    [[ "$output" == *"env:PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"* ]]
    [[ "$output" != *SECRET_THING* ]]
    [[ "$output" != *ARCHON_USER_INSTALL_SANDBOX* ]]
    [[ "$output" != *ARCHON_OPS_* ]]
    run "$T/sbin/archon-host-install" --dry-run
    [[ "$output" == *"host-install args:--dry-run"* ]]
    run "$A" archon-user-install x
    [[ "$output" == *"user-install args:x"* ]]
}

@test "entrypoints refuse a snapshot that is not root-only, missing, or pointing elsewhere" {
    run "$A" archon-user-install
    [ "$status" -eq 1 ]
    [[ "$output" == *"no snapshot"* ]]
    promote
    rel="$R/$(readlink "$R/current")"
    chmod g+w "$rel/ops/host/install.sh"
    run "$A" archon-host-install
    [ "$status" -eq 1 ]
    [[ "$output" == *"not root-only"* ]]
    chmod g-w "$rel/ops/host/install.sh"
    chmod o+w "$R"
    run "$A" archon-host-install
    [ "$status" -eq 1 ]
    [[ "$output" == *"group/other-writable"* ]]
    chmod o-w "$R"
    ln -s "$L/ops" "$rel/ops/link"
    run "$A" archon-host-install
    [ "$status" -eq 1 ]
    rm "$rel/ops/link"
    ln -sfn "$L" "$R/current"
    run "$A" archon-host-install
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not releases/<sha>"* ]]
}

@test "the test hook is ignored under sudo: then it needs root" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    SUDO_USER=asiri run "$A" archon-ops-promote
    [ "$status" -eq 1 ]
    [[ "$output" == *"run as root"* ]]
    [ ! -e "$R/current" ]
    run "$A" bogus-verb
    [ "$status" -eq 1 ]
}

@test "archon-ops passes shellcheck" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    run shellcheck "$A"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
