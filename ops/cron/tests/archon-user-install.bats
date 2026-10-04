#!/usr/bin/env bats
# ops/host/archon-user: what can be checked without root. The sudoers step of
# install.sh runs through its sandbox hook (ARCHON_USER_INSTALL_SANDBOX) with a
# stubbed visudo; the rest is --dry-run, the real visudo parse of the drop-in,
# and the shape of the systemd unit.
#
# Run: bunx bats ops/cron/tests/archon-user-install.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    D="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../host/archon-user" && pwd)"
    mkdir -p "$T/bin" "$T/sudoers.d"
    cat > "$T/bin/visudo" <<'STUB'
#!/usr/bin/env bash
# -c -q -f <file>: parse check of one file; -c: the whole set (fails if STUB_VISUDO_FAIL=1)
if [ "$1" = -c ] && [ "$2" = -q ] && [ "$3" = -f ]; then [ -r "$4" ]; exit; fi
[ "${STUB_VISUDO_FAIL:-0}" = 1 ] && { echo "syntax error" >&2; exit 1; }
exit 0
STUB
    chmod +x "$T/bin/visudo"
}

# The drop-in with continuation lines joined and comments dropped.
sudoers_rules() { sed -e 's/#.*//' "$D/sudoers-archon-user" | sed -e ':a' -e '/\\$/N; s/[[:space:]]*\\\n[[:space:]]*/ /; ta' | grep -v '^[[:space:]]*$'; }

@test "the sudoers drop-in parses (real visudo)" {
    command -v visudo >/dev/null || skip "visudo not installed"
    run visudo -c -f "$D/sudoers-archon-user"
    [ "$status" -eq 0 ]
}

@test "sudoers: asiri -> archon anything (NOSETENV), the wrapper kept for cron; root only for root-owned entrypoints" {
    rules=$(sudoers_rules)
    grep -qx 'asiri ALL=(archon) NOPASSWD: ARCHON_AS' <<<"$rules"
    grep -qx 'asiri ALL=(archon) NOPASSWD:NOSETENV: ALL' <<<"$rules"
    grep -qx 'asiri ALL=(root)   NOPASSWD: ARCHON_SERVE, ARCHON_OPS' <<<"$rules"
    grep -qx 'Cmnd_Alias ARCHON_AS    = /usr/local/bin/archon-as-archon' <<<"$rules"
    grep -qx 'Cmnd_Alias ARCHON_SERVE = /usr/bin/systemctl restart archon-serve.service' <<<"$rules"
    grep -qx 'Cmnd_Alias ARCHON_OPS   = /usr/local/sbin/archon-user-install, /usr/local/sbin/archon-host-install, /usr/local/sbin/archon-ops-promote' <<<"$rules"
    grep -qx 'Defaults!ARCHON_AS !use_pty' <<<"$rules"
    # no ALL as root or any user, no SETENV, no runas list beyond archon/root
    ! grep -E '\((ALL|[^)]*,)' <<<"$rules"
    ! grep -E '\(root\).*:[[:space:]]*ALL' <<<"$rules"
    ! grep -E '(^|[^O])SETENV' <<<"$rules"
    ! grep -E 'env_keep|!env_reset|setenv' <<<"$rules"
    # nothing root may run lives where asiri or archon can write
    ! grep -E '/mnt/|/home/|/tmp/|~' <<<"$rules"
    [ "$(grep -c '^asiri ' <<<"$rules")" -eq 3 ]
}

@test "the entrypoints the sudoers names are the ones install.sh installs" {
    for e in archon-user-install archon-host-install archon-ops-promote; do
        grep -q "/usr/local/sbin/$e" "$D/sudoers-archon-user"
        grep -q "$e" <(sed -n 's/^OPS_ENTRYPOINTS=(\(.*\))$/\1/p' "$D/install.sh")
    done
}

@test "sandboxed sudoers step installs at 0440 and is idempotent" {
    PATH="$T/bin:$PATH" ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$T/sudoers.d/archon-user")" = 440 ]
    cmp -s "$D/sudoers-archon-user" "$T/sudoers.d/archon-user"
    PATH="$T/bin:$PATH" ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already done"* ]]
}

@test "sandboxed sudoers step rolls back when the combined set fails" {
    PATH="$T/bin:$PATH" STUB_VISUDO_FAIL=1 ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh"
    [ "$status" -eq 1 ]
    [ ! -e "$T/sudoers.d/archon-user" ]
    [[ "$output" == *"removed"* ]]
}

@test "without root and without --dry-run it refuses" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    run "$D/install.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"run as root"* ]]
    run "$D/install.sh" --cutover
    [ "$status" -eq 1 ]
    run "$D/install.sh" --bogus
    [ "$status" -eq 2 ]
}

@test "--dry-run as a normal user changes nothing and walks every prepare step" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    [ -d /mnt/ext-fast ] && getent passwd asiri >/dev/null && command -v setfacl >/dev/null \
        || skip "not the factory host (needs /mnt/ext-fast, user asiri, setfacl)"
    run "$D/install.sh" --dry-run
    [ "$status" -eq 0 ]
    for s in "1. user archon" "2. owner secrets" "3. ACL" "4. NTFS" "5. archon's home" "6. toolchains" "7. wrapper"; do
        [[ "$output" == *"==> $s"* ]] || { echo "missing step: $s"; return 1; }
    done
    [[ "$output" == *"dry-run complete — nothing was changed."* ]]
    [[ "$output" != *"ERROR"* ]] || { echo "$output" | grep ERROR; return 1; }
}

@test "--help prints the header" {
    run "$D/install.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--cutover"* ]]
    [[ "$output" == *"--rollback"* ]]
}

@test "the system unit runs the server as archon, hardened, from archon's own bun" {
    u="$D/archon-serve.service"
    grep -qx 'User=archon' "$u"
    grep -qx 'NoNewPrivileges=yes' "$u"
    grep -qx 'ProtectHome=yes' "$u"
    grep -qx 'Environment=HOME=/mnt/ext-fast/archon-home' "$u"
    grep -qx 'Environment=CLAUDECODE=0' "$u"
    grep -qx 'Environment=HOST=127.0.0.1' "$u"
    grep -qx 'ExecStart=/mnt/ext-fast/archon-home/.bun/bin/bun /mnt/ext-fast/archon/packages/server/src/index.ts' "$u"
    ! grep -q '/home/asiri' "$u"
}

@test "the wrapper and every script here pass shellcheck" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    run shellcheck -x -P SCRIPTDIR "$D/archon-as-archon" "$D/install.sh" "$D/verify.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "--allow-all-repos-token writes the opt-in (0644), idempotently; --no-allow-all-repos-token removes it" {
    ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh" --allow-all-repos-token
    [ "$status" -eq 0 ]
    grep -qx 'ALLOW_ALL_REPOS_TOKEN=1' "$T/etc-archon-user/config"
    [ "$(stat -c %a "$T/etc-archon-user/config")" = 644 ]
    ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh" --allow-all-repos-token
    [ "$status" -eq 0 ]
    [[ "$output" == *"already done"* ]]
    [ "$(grep -c ALLOW_ALL_REPOS_TOKEN "$T/etc-archon-user/config")" -eq 1 ]
    ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh" --no-allow-all-repos-token
    [ "$status" -eq 0 ]
    ! grep -q '^ALLOW_ALL_REPOS_TOKEN' "$T/etc-archon-user/config"
    [ ! -e "$T/sudoers.d/archon-user" ]    # the opt-in modes never touch sudoers
}

@test "--allow-all-repos-token needs root unless --dry-run, which prints the config" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    run "$D/install.sh" --allow-all-repos-token
    [ "$status" -eq 1 ]
    [[ "$output" == *"run as root"* ]]
    run "$D/install.sh" --allow-all-repos-token --dry-run
    [ "$status" -eq 0 ]
    # on a host where the owner already opted in, the file is already right
    if [[ "$output" != *"/etc/archon-user/config already done"* ]]; then
        [[ "$output" == *"would write /etc/archon-user/config"* ]]
        [[ "$output" == *"| ALLOW_ALL_REPOS_TOKEN=1"* ]]
    fi
}

@test "verify.sh probes sudoers with cached credentials ignored (sudo -k)" {
    grep -q 'sudo -k -n -u archon /bin/true' "$D/verify.sh"
    grep -q 'sudo -k -n -u archon "$WRAPPER" --version' "$D/verify.sh"
    grep -q 'sudo -k -n -E -u archon /bin/true' "$D/verify.sh"
    grep -q 'sudo -k -n /bin/true' "$D/verify.sh"
    ! grep -qE 'sudo -n (-E )?(-u archon )?/bin/true' "$D/verify.sh"
}

@test "the test hooks are ignored as root (sandbox, disk thresholds; host-install's sudoers dir)" {
    grep -q 'ignoring ARCHON_USER_INSTALL_SANDBOX (test hook) as root' "$D/install.sh"
    grep -q 'unset ARCHON_USER_MIN_ROOT_MB ARCHON_USER_MIN_BASE_MB' "$D/install.sh"
    grep -q 'unset HOST_INSTALL_SUDOERS_D' "$D/../install.sh"
}

@test "the installer never names the snapshot as the cron's checkout (shim, crontab, --cwd use the live one)" {
    grep -qx 'LIVE_CHECKOUT=/mnt/ext-fast/interstellarai.net' "$D/install.sh"
    grep -q '^SHIM="$LIVE_CHECKOUT/ops/cron/lib/archon-shim/archon"' "$D/install.sh"
    ! grep -nE 'REPO_DIR/ops/cron/ops-self-update|git -C \$REPO_DIR|--cwd "\$REPO_DIR"|SHIM="\$REPO_DIR' "$D/install.sh"
}

@test "no root write into archon's home goes through a path archon controls (steps 5, 6, claude token)" {
    # every install -d / ln / chmod there runs as archon; files go through write_ah_file
    ! grep -nE '^[[:space:]]*run (install -d|ln -sfn|chmod|chown)[^#]*"\$AH/' "$D/install.sh"
    ! grep -nE 'write_file "\$AH/|write_file "\$dir/claude.env' "$D/install.sh"
    ! grep -n 'rsync -a ' "$D/install.sh"
    grep -q 'runuser -u $ARCHON_USER --" "$src/" "env:$dst/"' "$D/install.sh"
}

# A tiny live checkout for the snapshot bootstrap: ops/ with both installers,
# HEAD on origin/main.
make_live() {
    local L="$T/live"
    git init -q -b main "$L"
    mkdir -p "$L/ops/host/archon-user"
    printf '#!/bin/bash\necho user-install "$@"\n' > "$L/ops/host/archon-user/install.sh"
    printf '#!/bin/bash\necho host-install "$@"\n' > "$L/ops/host/install.sh"
    chmod +x "$L/ops/host/archon-user/install.sh" "$L/ops/host/install.sh"
    git -C "$L" add -A && git -C "$L" -c user.name=t -c user.email=t@t commit -q -m init
    git -C "$L" update-ref refs/remotes/origin/main HEAD
}

@test "--install-sudo-ops (sandbox): entrypoints 0755, snapshot bootstrapped from the live checkout, sudoers 0440; idempotent" {
    make_live
    export ARCHON_OPS_LIVE="$T/live" ARCHON_OPS_FLAG_FILE="$T/flag"
    PATH="$T/bin:$PATH" ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh" --install-sudo-ops
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    for e in archon-user-install archon-host-install archon-ops-promote; do
        [ "$(stat -c %a "$T/sbin/$e")" = 755 ]
        cmp -s "$D/../archon-ops/archon-ops" "$T/sbin/$e"
    done
    sha=$(git -C "$T/live" rev-parse HEAD)
    [ "$(readlink "$T/archon-ops/current")" = "releases/$sha" ]
    [[ "$output" == *"promoted $sha"* ]]
    [ "$(stat -c %a "$T/sudoers.d/archon-user")" = 440 ]
    cmp -s "$D/sudoers-archon-user" "$T/sudoers.d/archon-user"
    PATH="$T/bin:$PATH" ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh" --install-sudo-ops
    [ "$status" -eq 0 ]
    [[ "$output" == *"archon-ops-promote already done"* ]]
    [[ "$output" == *"snapshot: $T/archon-ops/current -> releases/$sha"* ]]
    [[ "$output" == *"archon-user already done"* ]]
}

@test "--install-sudo-ops (sandbox): a dirty live checkout is not snapshotted, the step fails, sudoers still checked" {
    make_live
    echo dirty >> "$T/live/ops/host/install.sh"
    export ARCHON_OPS_LIVE="$T/live" ARCHON_OPS_FLAG_FILE="$T/flag"
    PATH="$T/bin:$PATH" ARCHON_USER_INSTALL_SANDBOX="$T" run "$D/install.sh" --install-sudo-ops
    [ "$status" -eq 1 ]
    [ ! -e "$T/archon-ops/current" ]
    [[ "$output" == *"refusing to promote: ops/ has local changes"* ]]
    [[ "$output" == *"FAILED steps: ops-sudo"* ]]
}

@test "--install-sudo-ops needs root unless --dry-run, which writes nothing" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    run "$D/install.sh" --install-sudo-ops
    [ "$status" -eq 1 ]
    [[ "$output" == *"run as root"* ]]
    run "$D/install.sh" --install-sudo-ops --dry-run
    [[ "$output" == *"DRY-RUN"*"/usr/local/sbin/archon-user-install"* ]]
    [[ "$output" == *"/etc/sudoers.d/archon-user"* ]]
}
