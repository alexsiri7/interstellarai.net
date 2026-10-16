#!/usr/bin/env bats
# ops/host install.sh steps 14-15 (hardware watchdog, kernel cmdline) and their
# verify.sh checks (ops/host/watchdog/verify-host.sh):
#   - verify-host passes a healthy host, WARNs before install, FAILs after,
#     and treats a leftover `splash` as pending only until the next boot;
#   - install.sh's grub_cfg_current decides when update-grub must run;
#   - the grub.d drop-in wins over /etc/default/grub the way grub-mkconfig
#     sources them, and grub-mkconfig on this machine does source in that order;
#   - the module unit passes systemd-analyze verify.
#
# Run: bunx bats ops/cron/tests/host-watchdog.bats

setup() {
    export T="$BATS_TMPDIR/host-watchdog-$$"
    rm -rf "$T"
    mkdir -p "$T/bin" "$T/sys/watchdog0" "$T/etc"
    HOST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../host" && pwd)"
    export PATH="$T/bin:$PATH"

    # systemctl show -p RuntimeWatchdogUSec --value → $STUB_RUNTIME_WDT
    cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
[ "$1" = show ] && { echo "${STUB_RUNTIME_WDT:-0}"; exit 0; }
exit 1
STUB
    chmod +x "$T/bin/systemctl"

    export VH_WDT_DROPIN="$T/etc/60-watchdog.conf"
    export VH_WDT_SYSFS="$T/sys/watchdog0"
    export VH_WDT_DEV="/dev/null"            # any character device
    export VH_GRUB_DROPIN="$T/etc/90-interstellar.cfg"
    export VH_PROC_CMDLINE="$T/cmdline"
    export VH_BOOT_EPOCH=$(( $(date +%s) - 3600 ))
    echo iTCO_wdt > "$T/sys/watchdog0/identity"

    PASSES=0 WARNS=0 FAILS=0
    pass() { echo "PASS $*"; PASSES=$((PASSES + 1)); }
    warn() { echo "WARN $*"; WARNS=$((WARNS + 1)); }
    fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
    # shellcheck source=../../host/watchdog/verify-host.sh
    source "$HOST_DIR/watchdog/verify-host.sh"
}

teardown() { rm -rf "$T"; }

healthy() {
    touch "$VH_WDT_DROPIN" "$VH_GRUB_DROPIN"
    touch -d "@$(( VH_BOOT_EPOCH - 60 ))" "$VH_GRUB_DROPIN"
    echo active > "$T/sys/watchdog0/state"
    export STUB_RUNTIME_WDT=2min
    echo "BOOT_IMAGE=/boot/vmlinuz root=UUID=x ro quiet reboot=efi" > "$VH_PROC_CMDLINE"
}

@test "verify-host: an armed watchdog and a cmdline without splash pass" {
    healthy
    verify_watchdog_and_cmdline > "$T/out"
    [ "$FAILS" -eq 0 ] && [ "$WARNS" -eq 0 ] && [ "$PASSES" -eq 4 ]
    grep -q 'PASS watchdog: PID 1 RuntimeWatchdogUSec=2min' "$T/out"
    grep -q 'PASS kernel cmdline has no splash' "$T/out"
}

@test "verify-host: before install.sh ran, a missing watchdog and splash only WARN" {
    echo inactive > "$T/sys/watchdog0/state"
    export VH_WDT_DEV="$T/no-such-dev"
    echo "BOOT_IMAGE=/boot/vmlinuz ro quiet splash reboot=pci vt.handoff=7" > "$VH_PROC_CMDLINE"
    verify_watchdog_and_cmdline > "$T/out"
    [ "$FAILS" -eq 0 ]
    [ "$WARNS" -eq 4 ]
    grep -q 'not installed yet' "$T/out"
}

@test "verify-host: installed but PID 1 not pinging FAILs" {
    healthy
    echo inactive > "$T/sys/watchdog0/state"
    export STUB_RUNTIME_WDT=0
    verify_watchdog_and_cmdline > "$T/out"
    [ "$FAILS" -eq 2 ]
    grep -q "FAIL watchdog: PID 1 RuntimeWatchdogUSec=0" "$T/out"
    grep -q "FAIL watchdog: .* state 'inactive'" "$T/out"
}

@test "verify-host: splash is a WARN while the grub drop-in is newer than this boot" {
    healthy
    touch "$VH_GRUB_DROPIN"      # now: after the boot
    echo "ro quiet splash reboot=pci" > "$VH_PROC_CMDLINE"
    verify_watchdog_and_cmdline > "$T/out"
    [ "$FAILS" -eq 0 ]
    grep -q 'WARN kernel cmdline still has splash: .* applies from the next one' "$T/out"
}

@test "verify-host: splash after a boot that should have dropped it FAILs" {
    healthy
    echo "ro quiet splash reboot=pci" > "$VH_PROC_CMDLINE"
    verify_watchdog_and_cmdline > "$T/out"
    [ "$FAILS" -eq 1 ]
    grep -q 'FAIL kernel cmdline still has splash although' "$T/out"
}

load_grub_cfg_current() {
    # shellcheck disable=SC1090
    source <(awk '/^grub_cfg_current\(\)/{p=1} p{print} p && /^}$/{p=0}' "$HOST_DIR/install.sh")
    want_cmdline=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$HOST_DIR/watchdog/90-interstellar.cfg")
    GRUB_CFG="$T/grub.cfg"
}

grub_cfg() {  # grub_cfg <default entry args>
    printf 'menuentry "Ubuntu" {\n\tlinux\t/boot/vmlinuz-7.0.0-38-generic root=UUID=x ro %s\n}\nmenuentry "recovery" {\n\tlinux\t/boot/vmlinuz root=UUID=x ro recovery nomodeset\n}\n' "$1" > "$GRUB_CFG"
}

@test "grub_cfg_current: the drop-in's cmdline is what the repo file says" {
    load_grub_cfg_current
    [ "$want_cmdline" = "quiet reboot=efi" ]
}

@test "grub_cfg_current: true only when the default entry has every word and no splash" {
    load_grub_cfg_current
    run grub_cfg_current
    [ "$status" -ne 0 ]                                      # unreadable / missing
    grub_cfg 'quiet splash reboot=pci $vt_handoff'
    run grub_cfg_current; [ "$status" -ne 0 ]
    grub_cfg 'quiet splash reboot=efi'
    run grub_cfg_current; [ "$status" -ne 0 ]                # splash still there
    grub_cfg 'quiet reboot=pci'
    run grub_cfg_current; [ "$status" -ne 0 ]                # reboot=efi missing
    grub_cfg 'quiet reboot=efi'
    run grub_cfg_current; [ "$status" -eq 0 ]
}

@test "the grub.d drop-in overrides /etc/default/grub when sourced in grub-mkconfig's order" {
    printf 'GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash reboot=pci"\nGRUB_CMDLINE_LINUX=""\n' > "$T/etc/grub"
    run bash -c '. "$1"; for x in "$2"/*.cfg; do . "$x"; done; echo "$GRUB_CMDLINE_LINUX_DEFAULT"' _ "$T/etc/grub" "$HOST_DIR/watchdog"
    [ "$status" -eq 0 ]
    [ "$output" = "quiet reboot=efi" ]
}

@test "grub-mkconfig on this machine sources /etc/default/grub before /etc/default/grub.d/*.cfg" {
    local mk=/usr/sbin/grub-mkconfig
    [ -r "$mk" ] || skip "no $mk"
    local a b
    a=$(grep -n '^ *\. \${sysconfdir}/default/grub *$' "$mk" | head -1 | cut -d: -f1)
    b=$(grep -n 'for x in \${sysconfdir}/default/grub.d/\*.cfg' "$mk" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ]
    [ "$a" -lt "$b" ]
}

@test "itco-wdt.service loads by name with plain modprobe (no -b) and verifies" {
    grep -qx 'ExecStart=/sbin/modprobe iTCO_wdt' "$HOST_DIR/watchdog/itco-wdt.service"
    grep -qx 'WantedBy=sysinit.target' "$HOST_DIR/watchdog/itco-wdt.service"
    command -v systemd-analyze >/dev/null || skip "no systemd-analyze"
    run systemd-analyze verify "$HOST_DIR/watchdog/itco-wdt.service"
    [ "$status" -eq 0 ]
}

@test "the system.conf drop-in sets the runtime and reboot watchdog" {
    grep -qx 'RuntimeWatchdogSec=2min' "$HOST_DIR/watchdog/60-watchdog.conf"
    grep -qx 'RebootWatchdogSec=3min' "$HOST_DIR/watchdog/60-watchdog.conf"
    grep -qx '\[Manager\]' "$HOST_DIR/watchdog/60-watchdog.conf"
}
