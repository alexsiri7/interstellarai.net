# shellcheck shell=bash
# ops/host/watchdog/verify-host.sh — the watchdog and kernel-cmdline checks of
# ops/host/archon-user/verify.sh (section 1), sourced from there; the caller
# provides pass/warn/fail. Paths are variables so the bats suite can point them
# at a sandbox (ops/cron/tests/host-watchdog.bats).
#
# Before install.sh steps 14/15 ran (no drop-in on the host) a missing piece is
# a WARN, after that a FAIL. A `splash` still on /proc/cmdline is a WARN while
# the grub drop-in is newer than the current boot (the new cmdline only applies
# from the next one).

VH_WDT_DROPIN="${VH_WDT_DROPIN:-/etc/systemd/system.conf.d/60-watchdog.conf}"   # = install.sh WDT_DROPIN
VH_WDT_SYSFS="${VH_WDT_SYSFS:-/sys/class/watchdog/watchdog0}"
VH_WDT_DEV="${VH_WDT_DEV:-/dev/watchdog0}"
VH_GRUB_DROPIN="${VH_GRUB_DROPIN:-/etc/default/grub.d/90-interstellar.cfg}"     # = install.sh GRUB_DROPIN
VH_PROC_CMDLINE="${VH_PROC_CMDLINE:-/proc/cmdline}"

# vh_boot_epoch — when the running kernel booted (epoch seconds).
vh_boot_epoch() {
    if [ -n "${VH_BOOT_EPOCH:-}" ]; then echo "$VH_BOOT_EPOCH"; return; fi
    awk '/^btime /{print $2}' /proc/stat
}

verify_watchdog_and_cmdline() {
    local installed=0 rt state cmdline
    [ -e "$VH_WDT_DROPIN" ] && installed=1
    # vh_check <ok?> <pass-text> <fail-text>
    vh_check() {
        if [ "$1" = 1 ]; then pass "$2"
        elif [ "$installed" = 1 ]; then fail "$3"
        else warn "$3 (watchdog not installed yet — sudo -n /usr/local/sbin/archon-host-install)"; fi
    }
    local ok=0
    [ -c "$VH_WDT_DEV" ] && ok=1
    vh_check "$ok" "watchdog: $VH_WDT_DEV present ($(cat "$VH_WDT_SYSFS/identity" 2>/dev/null || echo '?'))" \
        "watchdog: no $VH_WDT_DEV — iTCO_wdt not loaded (systemctl status itco-wdt.service)"
    rt=$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null)
    ok=0; [ -n "$rt" ] && [ "$rt" != 0 ] && [ "$rt" != infinity ] && ok=1
    vh_check "$ok" "watchdog: PID 1 RuntimeWatchdogUSec=$rt" \
        "watchdog: PID 1 RuntimeWatchdogUSec=${rt:-?} (want non-zero: $VH_WDT_DROPIN)"
    state=$(cat "$VH_WDT_SYSFS/state" 2>/dev/null)
    ok=0; [ "$state" = active ] && ok=1
    vh_check "$ok" "watchdog: $VH_WDT_SYSFS active (PID 1 is pinging it)" \
        "watchdog: $VH_WDT_SYSFS state '${state:-missing}' (want active)"

    cmdline=$(cat "$VH_PROC_CMDLINE" 2>/dev/null)
    if [[ " $cmdline " != *" splash "* ]]; then
        pass "kernel cmdline has no splash"
    elif [ ! -e "$VH_GRUB_DROPIN" ]; then
        warn "kernel cmdline still has splash ($VH_GRUB_DROPIN not installed yet — sudo -n /usr/local/sbin/archon-host-install)"
    elif [ "$(stat -c %Y "$VH_GRUB_DROPIN")" -ge "$(vh_boot_epoch)" ]; then
        warn "kernel cmdline still has splash: $VH_GRUB_DROPIN was installed after this boot, applies from the next one"
    else
        fail "kernel cmdline still has splash although $VH_GRUB_DROPIN predates this boot — did update-grub run? (sudo -n /usr/local/sbin/archon-host-install)"
    fi
}
