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

@test "the sudoers drop-in parses (real visudo) and grants nothing but the wrapper and one restart" {
    command -v visudo >/dev/null || skip "visudo not installed"
    run visudo -c -f "$D/sudoers-archon-user"
    [ "$status" -eq 0 ]
    grep -qx 'asiri ALL=(archon) NOPASSWD: ARCHON_AS' "$D/sudoers-archon-user"
    grep -qx 'asiri ALL=(root)   NOPASSWD: ARCHON_SERVE' "$D/sudoers-archon-user"
    grep -qx 'Cmnd_Alias ARCHON_AS    = /usr/local/bin/archon-as-archon' "$D/sudoers-archon-user"
    grep -qx 'Cmnd_Alias ARCHON_SERVE = /usr/bin/systemctl restart archon-serve.service' "$D/sudoers-archon-user"
    ! grep -E '^[^#]*\bALL\b[^=]*=[^:]*:[[:space:]]*ALL' "$D/sudoers-archon-user"
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
