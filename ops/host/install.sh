#!/usr/bin/env bash
# ops/host/install.sh — one-time host setup for the archon build machine.
#
#   sudo -n /usr/local/sbin/archon-host-install   # apply, from the root-owned ops snapshot, no password
#                                       # (ops/host/archon-ops; set up by archon-user/install.sh --install-sudo-ops)
#   sudo ops/host/install.sh            # apply from the checkout (needs the password)
#   ops/host/install.sh --dry-run       # print every command and file it would write, as any user
#
# What it does (see ops/host/README.md):
#   1. /etc/sudoers.d/archon-cron          NOPASSWD for the weekly system-maintenance.sh
#   2. journald                            SystemMaxUse=500M
#   3. unattended-upgrades                 also take -updates, autoremove; NO auto-reboot (step 8 reboots)
#   4. snap                                refresh.retain=2, drop disabled revisions
#   5. smartmontools                       smartd with ntfy hook, short/long self-tests
#   6. NodeSource                          node_20.x (EOL) -> node_24.x (current LTS)
#   7. report whether a reboot is pending
#   8. safe-reboot                         gate timer (reboot only when idle, 02:30-06:30) + restore at boot
#   9. systemd-oomd                        no memory-pressure kills of user@.service (ManagedOOMMemoryPressure=auto)
#  10. sysctl                              vm.dirty_background_bytes 256M, vm.dirty_bytes 1G
#  11. /tmp on the NVMe                    tmp.mount: bind of /mnt/ext-fast/.tmp-root, from the NEXT boot
#                                          (marks a reboot pending for the safe-reboot gate); once active,
#                                          empties the old /tmp left hidden on / underneath it
#  12. tmpfiles                            /tmp entries idle 2 days are removed (Ubuntu: 30 days)
#  13. cargo /tmp build-dir                /etc/tmpfiles.d/cargo-tmp-build-dir.conf → /tmp/.cargo/config.toml (root-owned)
#
# Every step is guarded so it can be run again after a partial failure.
#
# Test hook (ops/cron/tests/host-install.bats): HOST_INSTALL_SUDOERS_D=<dir>
# points step 1 at <dir> instead of /etc/sudoers.d, skips the root check and
# stops after step 1, so the sudoers logic runs against a stubbed visudo.
# Ignored when running as root.

set -uo pipefail

DRY=0
case "${1:-}" in
    --dry-run|-n) DRY=1 ;;
    "") ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (only --dry-run)" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd / || exit 1   # root never works from a cwd someone else picked
if [ "$(id -u)" -eq 0 ] && [ -n "${HOST_INSTALL_SUDOERS_D:-}" ]; then
    echo "ignoring HOST_INSTALL_SUDOERS_D (test hook) as root" >&2
    unset HOST_INSTALL_SUDOERS_D
fi
REPO_SUDOERS="$SCRIPT_DIR/sudoers-archon-cron"
REPO_SMARTD_NTFY="$SCRIPT_DIR/smartd-ntfy"
REPO_SAFE_REBOOT="$SCRIPT_DIR/safe-reboot"
REPO_OOMD_DROPIN="$SCRIPT_DIR/20-oomd-pressure-limit.conf"
REPO_SYSCTL_DIRTY="$SCRIPT_DIR/60-dirty-bytes.conf"
REPO_TMP_MOUNT="$SCRIPT_DIR/tmp-on-nvme/tmp.mount"
REPO_TMPFILES_TMP="$SCRIPT_DIR/tmp-on-nvme/tmpfiles-tmp.conf"
REPO_TMPFILES_CARGO="$SCRIPT_DIR/cargo-tmp-build-dir.conf"

SUDOERS_D="${HOST_INSTALL_SUDOERS_D:-/etc/sudoers.d}"
SUDOERS_DST="$SUDOERS_D/archon-cron"
SUDOERS_OWNER=root
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/50-cap.conf
APT_DROPIN=/etc/apt/apt.conf.d/52-archon-updates
SMARTD_CONF=/etc/smartd.conf
SMARTD_NTFY_DST=/usr/local/bin/smartd-ntfy
NODESOURCE=/etc/apt/sources.list.d/nodesource.sources
NODE_MAJOR=24   # current LTS line (Krypton); node 20 is EOL since 2026-04-30, 22 is maintenance-only
JOURNAL_MAX=500M
SNAP_RETAIN=2
SAFE_REBOOT_BIN=/usr/local/sbin/safe-reboot
SAFE_REBOOT_STATE=/var/lib/safe-reboot
UNIT_DIR=/etc/systemd/system
OOMD_DROPIN=/etc/systemd/system/user@.service.d/20-oomd-pressure-limit.conf
SYSCTL_DIRTY=/etc/sysctl.d/60-dirty-bytes.conf
TMP_BASE=/mnt/ext-fast
TMP_SRC=$TMP_BASE/.tmp-root          # also in tmp-on-nvme/tmp.mount, archon-user/install.sh BASE_ALLOW, archon-as-archon selftest
TMP_DEFER=/run/tmp-on-nvme.defer     # also in tmp-on-nvme/tmp.mount
TMPFILES_TMP=/etc/tmpfiles.d/tmp.conf
REBOOT_REQUIRED=/var/run/reboot-required
TMPFILES_CARGO=/etc/tmpfiles.d/cargo-tmp-build-dir.conf

export DEBIAN_FRONTEND=noninteractive

if [ "$DRY" -eq 0 ] && [ -z "${HOST_INSTALL_SUDOERS_D:-}" ] && [ "$(id -u)" -ne 0 ]; then
    echo "run as root: sudo $0   (or $0 --dry-run to preview)" >&2
    exit 1
fi
[ -n "${HOST_INSTALL_SUDOERS_D:-}" ] && SUDOERS_OWNER=$(id -un)   # test sandbox is not root-owned

# ---------------------------------------------------------------- helpers ---
say()  { printf '==> %s\n' "$*"; }
done_() { printf '    %s\n' "$*"; }   # "already done" / status lines
did()   { if [ "$DRY" -eq 1 ]; then done_ "(dry-run, would report) $*"; else done_ "$*"; fi; }   # after an action
fail() { printf '    ERROR: %s\n' "$*" >&2; FAILED+=("$1"); }
FAILED=()

# run <cmd...>: execute, or in dry-run print the exact command.
run() {
    if [ "$DRY" -eq 1 ]; then
        printf '    DRY-RUN: would run:'; printf ' %q' "$@"; printf '\n'
        return 0
    fi
    "$@"
}

# file_is <path> <content>: true when <path> already holds exactly <content>.
file_is() {
    [ -e "$1" ] || return 1
    if [ ! -r "$1" ]; then
        # dry-run as a normal user cannot read e.g. a 0440 root file
        done_ "(cannot read $1 without root — assuming it differs)"
        return 1
    fi
    cmp -s "$1" <(printf '%s' "$2")
}

# write_file <path> <mode> <content>: install <content> at <path> atomically,
# or in dry-run print what would be written. Returns 1 when nothing changed.
write_file() {
    local path="$1" mode="$2" content="$3"
    if file_is "$path" "$content"; then
        done_ "$path already done"
        return 1
    fi
    if [ "$DRY" -eq 1 ]; then
        printf '    DRY-RUN: would write %s (mode %s):\n' "$path" "$mode"
        printf '%s' "$content" | sed 's/^/        | /'
        return 0
    fi
    local tmp
    tmp=$(mktemp "${path}.XXXXXX") || return 1
    if ! { printf '%s' "$content" > "$tmp" && chmod "$mode" "$tmp" && chown root:root "$tmp" && mv -f "$tmp" "$path"; }; then
        rm -f "$tmp"
        return 1
    fi
    done_ "wrote $path (mode $mode)"
    return 0
}

# install_file <src> <dst> <mode>: copy a repo file to a root-owned path
# unless it is already identical. Returns 0 when it (would have) changed.
install_file() {
    if [ ! -r "$1" ]; then fail "${2##*/}" "$1 not found"; return 1; fi
    if [ -r "$2" ] && cmp -s "$1" "$2"; then done_ "$2 already done"; return 1; fi
    run install -D -m "$3" -o root -g root "$1" "$2" && did "installed $2"
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# sudoers_d_offenders: every file in $SUDOERS_D visudo will reject on sight —
# mode not 0440 or owner not $SUDOERS_OWNER — as "<mode> <owner>:<group> <path>".
sudoers_d_offenders() {
    find "$SUDOERS_D" -maxdepth 1 -type f \( ! -perm 0440 -o ! -user "$SUDOERS_OWNER" \) -exec stat -c '%a %U:%G %n' {} + 2>/dev/null | sort
}

# finish: print the summary and exit — the tail of the script, callable early.
finish() {
    echo
    if [ "${#FAILED[@]}" -gt 0 ]; then
        echo "FAILED steps: ${FAILED[*]} — fix and re-run (safe to repeat)." >&2
        exit 1
    fi
    [ "$DRY" -eq 1 ] && echo "dry-run complete — nothing was changed. Apply with: sudo $0"
    exit 0
}

# ------------------------------------------------------- 1. sudoers ---------
say "1. sudoers drop-in for the weekly maintenance job"
if [ ! -r "$REPO_SUDOERS" ]; then
    fail sudoers "$REPO_SUDOERS not found"
elif ! visudo -c -q -f "$REPO_SUDOERS"; then
    fail sudoers "$REPO_SUDOERS does not parse (visudo -c) — not installed"
elif [ -r "$SUDOERS_DST" ] && cmp -s "$REPO_SUDOERS" "$SUDOERS_DST"; then
    done_ "$SUDOERS_DST already done"
else
    done_ "visudo -c: $REPO_SUDOERS parses"
    [ -e "$SUDOERS_DST" ] && [ ! -r "$SUDOERS_DST" ] && done_ "(cannot read $SUDOERS_DST without root — assuming it differs)"
    # Baseline: the sudoers set as it stands must already pass visudo -c.
    # Otherwise the post-install check below fails for a reason that has nothing
    # to do with our file and the rollback blames the wrong one (2026-09-19: an
    # unrelated /etc/sudoers.d/gc-resize at 0644 did exactly that). visudo needs
    # root to read /etc/sudoers, so a --dry-run as a normal user cannot check.
    baseline_ok=1
    if [ "$(id -u)" -ne 0 ] && [ -z "${HOST_INSTALL_SUDOERS_D:-}" ]; then
        done_ "(cannot run visudo -c without root — existing sudoers set not checked)"
    elif ! visudo_out=$(visudo -c 2>&1); then
        baseline_ok=0
        printf '%s\n' "$visudo_out" | sed 's/^/        | /'
        offenders=$(sudoers_d_offenders)
        if [ -n "$offenders" ]; then
            done_ "files in $SUDOERS_D that are not mode 0440 owned by $SUDOERS_OWNER (visudo rejects the whole set for any one of them):"
            printf '%s\n' "$offenders" | sed 's/^/        /'
        fi
        fail sudoers "pre-existing sudoers problem (visudo -c fails before $SUDOERS_DST is installed) — not installed; fix it (e.g. chmod 0440 $SUDOERS_D/<file>, or remove the file) and re-run"
    else
        done_ "visudo -c: existing sudoers set parses"
    fi
    if [ "$baseline_ok" -eq 1 ]; then
        run install -m 0440 -o root -g root "$REPO_SUDOERS" "$SUDOERS_DST" \
            && did "installed $SUDOERS_DST (0440)"
        # The whole sudoers set must still parse with the new file in place;
        # otherwise sudo locks everyone out. Roll back on failure.
        if [ "$DRY" -eq 0 ] && ! visudo_out=$(visudo -c 2>&1); then
            rm -f "$SUDOERS_DST"
            printf '%s\n' "$visudo_out" | sed 's/^/        | /'
            fail sudoers "combined sudoers failed visudo -c after install — $SUDOERS_DST removed"
        fi
    fi
fi
[ -n "${HOST_INSTALL_SUDOERS_D:-}" ] && finish   # test hook: step 1 only

# ------------------------------------------------------- 2. journald --------
say "2. journald size cap ($JOURNAL_MAX)"
JOURNALD_CONTENT="# Managed by interstellarai.net ops/host/install.sh
[Journal]
SystemMaxUse=$JOURNAL_MAX
"
run mkdir -p "$(dirname "$JOURNALD_DROPIN")"
if write_file "$JOURNALD_DROPIN" 0644 "$JOURNALD_CONTENT"; then
    run systemctl restart systemd-journald && did "restarted systemd-journald"
fi
[ "$DRY" -eq 1 ] || done_ "journal now: $(journalctl --disk-usage 2>/dev/null || echo '?')"

# ------------------------------------------ 3. unattended-upgrades ----------
say "3. unattended-upgrades: -updates origin, autoremove, no automatic reboot"
if ! pkg_installed unattended-upgrades; then
    run apt-get install -y unattended-upgrades && did "installed unattended-upgrades"
else
    done_ "unattended-upgrades already installed"
fi
# shellcheck disable=SC2016  # ${distro_id} is apt.conf syntax, not shell
APT_CONTENT='// Managed by interstellarai.net ops/host/install.sh — do not edit 50unattended-upgrades.
// apt.conf lists merge across files, so this adds to Allowed-Origins instead of replacing it.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// No automatic reboot here: it fired at 05:45 on whatever day a reboot became
// pending, regardless of running sessions or jobs (2026-09-26). The safe-reboot
// gate (step 8, /usr/local/sbin/safe-reboot) reboots instead, only when idle.
Unattended-Upgrade::Automatic-Reboot "false";
'
write_file "$APT_DROPIN" 0644 "$APT_CONTENT" || true
if [ "$DRY" -eq 0 ]; then
    if apt-config dump Unattended-Upgrade::Allowed-Origins | grep -q -- '-updates'; then
        done_ "apt-config sees the -updates origin"
    else
        fail unattended-upgrades "apt-config dump does not list the -updates origin after writing $APT_DROPIN"
    fi
    if apt-config dump Unattended-Upgrade::Automatic-Reboot | grep -q '"false"'; then
        done_ "apt-config: Automatic-Reboot false"
    else
        fail unattended-upgrades "apt-config still has Unattended-Upgrade::Automatic-Reboot on — another apt.conf.d file sets it after $APT_DROPIN"
    fi
fi
for key in Update-Package-Lists Unattended-Upgrade; do
    if apt-config dump "APT::Periodic::$key" 2>/dev/null | grep -q '"1"'; then
        done_ "APT::Periodic::$key already 1"
    else
        fail unattended-upgrades "APT::Periodic::$key is not 1 in /etc/apt/apt.conf.d/20auto-upgrades — unattended-upgrades will not run"
    fi
done

# ------------------------------------------------------- 4. snap ------------
say "4. snap: refresh.retain=$SNAP_RETAIN and remove disabled revisions"
if command -v snap >/dev/null; then
    if [ "$DRY" -eq 0 ] && [ "$(snap get system refresh.retain 2>/dev/null)" = "$SNAP_RETAIN" ]; then
        done_ "refresh.retain already $SNAP_RETAIN"
    else
        run snap set system refresh.retain="$SNAP_RETAIN" && did "set refresh.retain=$SNAP_RETAIN"
    fi
    n=0
    while read -r name rev; do
        [ -n "$name" ] || continue
        run snap remove --revision="$rev" "$name" && n=$((n + 1))
    done < <(snap list --all 2>/dev/null | awk 'NR > 1 && $6 ~ /disabled/ {print $1, $3}')
    if [ "$n" -eq 0 ]; then done_ "no disabled snap revisions — already done"; else did "removed $n disabled snap revision(s)"; fi
else
    done_ "snap not installed — skipped"
fi

# ------------------------------------------------------- 5. smartmontools ---
say "5. smartmontools: smartd with ntfy hook"
if pkg_installed smartmontools; then
    done_ "smartmontools already installed"
else
    run apt-get install -y smartmontools && did "installed smartmontools"
fi
if [ -r "$SMARTD_NTFY_DST" ] && cmp -s "$REPO_SMARTD_NTFY" "$SMARTD_NTFY_DST"; then
    done_ "$SMARTD_NTFY_DST already done"
else
    run install -m 0755 -o root -g root "$REPO_SMARTD_NTFY" "$SMARTD_NTFY_DST" && did "installed $SMARTD_NTFY_DST"
fi
SMARTD_CONTENT="# Managed by interstellarai.net ops/host/install.sh
# -a all checks; -o on offline testing; -S on attribute autosave; -n standby,q don't wake
# spun-down disks (quietly); -s short test daily 02:00, long test Saturdays 03:00;
# -m root -M exec: every alert goes through smartd-ntfy (posts to the private ntfy topic).
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -m root -M exec $SMARTD_NTFY_DST
"
smartd_changed=0
write_file "$SMARTD_CONF" 0644 "$SMARTD_CONTENT" && smartd_changed=1
if [ "$DRY" -eq 1 ]; then
    run systemctl enable --now smartd
    run systemctl restart smartd
else
    if systemctl is-enabled -q smartd 2>/dev/null && systemctl is-active -q smartd 2>/dev/null; then
        done_ "smartd already enabled and running"
        [ "$smartd_changed" -eq 1 ] && { run systemctl restart smartd && did "restarted smartd (config changed)"; }
    else
        run systemctl enable --now smartd && did "enabled and started smartd"
    fi
    systemctl is-active -q smartd || fail smartd "smartd is not running after enable — check: journalctl -u smartd"
fi

# ------------------------------------------------------- 6. NodeSource ------
say "6. NodeSource: Node ${NODE_MAJOR}.x"
node_now=$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || echo none)
if [ ! -r "$NODESOURCE" ]; then
    fail nodesource "$NODESOURCE not found — is NodeSource still configured?"
elif grep -q "node_${NODE_MAJOR}\.x" "$NODESOURCE"; then
    done_ "$NODESOURCE already points at node_${NODE_MAJOR}.x"
else
    current=$(grep -oE 'node_[0-9]+\.x' "$NODESOURCE" | head -n1)
    if [ "$DRY" -eq 1 ]; then
        done_ "DRY-RUN: would rewrite $NODESOURCE: ${current:-?} -> node_${NODE_MAJOR}.x in Suites/URIs, i.e.:"
        run sed -i -E "s#node_[0-9]+\.x#node_${NODE_MAJOR}.x#g" "$NODESOURCE"
    else
        cp -a "$NODESOURCE" "$NODESOURCE.bak-$(date +%Y%m%d)"
        sed -i -E "s#node_[0-9]+\.x#node_${NODE_MAJOR}.x#g" "$NODESOURCE" \
            && did "rewrote $NODESOURCE: ${current:-?} -> node_${NODE_MAJOR}.x (backup alongside)"
    fi
fi
case "$node_now" in
    "$NODE_MAJOR".*) done_ "nodejs $node_now already installed" ;;
    *)
        done_ "nodejs is $node_now — upgrading"
        if run apt-get update && run apt-get install -y nodejs; then
            did "nodejs now $(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || echo '?') — restart the archon user services to pick it up: systemctl --user restart archon-serve.service (as asiri)"
        else
            fail nodesource "apt-get install nodejs failed"
        fi
        ;;
esac

# ------------------------------------------------------- 7. reboot ----------
say "7. reboot status"
if [ -f /var/run/reboot-required ]; then
    done_ "/var/run/reboot-required EXISTS — a reboot is pending$( [ -r /var/run/reboot-required.pkgs ] && printf ' (%s)' "$(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')" ). the safe-reboot gate (step 8) reboots in the next idle 02:30-06:30 window (safe-reboot status says what blocks it); or: sudo reboot"
else
    done_ "/var/run/reboot-required absent — no reboot pending"
fi

# ------------------------------------------------------- 8. safe-reboot -----
say "8. safe-reboot: gate timer every 15 min (window 02:30-06:30) + restore after boot"
units_changed=0
install_file "$REPO_SAFE_REBOOT/safe-reboot" "$SAFE_REBOOT_BIN" 0755 || true
for u in safe-reboot.service safe-reboot.timer safe-reboot-restore.service; do
    install_file "$REPO_SAFE_REBOOT/$u" "$UNIT_DIR/$u" 0644 && units_changed=1
done
if [ -d "$SAFE_REBOOT_STATE" ]; then done_ "$SAFE_REBOOT_STATE already done"
else run install -d -m 0755 -o root -g root "$SAFE_REBOOT_STATE" && did "created $SAFE_REBOOT_STATE"; fi
[ "$units_changed" -eq 1 ] && { run systemctl daemon-reload && did "daemon-reload"; }
if [ "$DRY" -eq 0 ] && systemctl is-enabled -q safe-reboot-restore.service 2>/dev/null; then
    done_ "safe-reboot-restore.service already enabled"
else
    # enabled, not started: it runs once per boot, and does nothing on a boot the gate did not cause
    run systemctl enable safe-reboot-restore.service && did "enabled safe-reboot-restore.service (runs at next boot)"
fi
if [ "$DRY" -eq 0 ] && systemctl is-enabled -q safe-reboot.timer 2>/dev/null && systemctl is-active -q safe-reboot.timer 2>/dev/null; then
    done_ "safe-reboot.timer already enabled and running"
else
    run systemctl enable --now safe-reboot.timer && did "enabled and started safe-reboot.timer"
fi
done_ "hold file (veto, as asiri): mkdir -p ~/.config/safe-reboot && touch ~/.config/safe-reboot/hold   — status: safe-reboot status"
[ "$DRY" -eq 0 ] && [ -x "$SAFE_REBOOT_BIN" ] && done_ "gate now: $("$SAFE_REBOOT_BIN" status 2>/dev/null | grep -m1 'decision:' | sed 's/^ *//')"

# ------------------------------------------------------- 9. systemd-oomd ----
say "9. systemd-oomd: no memory-pressure kills of user@.service (Ubuntu default: kill at 50%)"
if install_file "$REPO_OOMD_DROPIN" "$OOMD_DROPIN" 0644; then
    # daemon-reload only: restarting user@1000.service would end every session.
    run systemctl daemon-reload && did "daemon-reload"
    # oomd gets the monitored cgroups from PID 1 when it connects; a restart of
    # oomd itself kills nothing and makes it re-read them.
    run systemctl restart systemd-oomd && did "restarted systemd-oomd"
fi
if [ "$DRY" -eq 0 ]; then
    mode=$(systemctl show user@1000.service -p ManagedOOMMemoryPressure --value 2>/dev/null)
    if [ "$mode" = auto ]; then done_ "user@1000.service ManagedOOMMemoryPressure=auto (not monitored)"
    else fail oomd "user@1000.service ManagedOOMMemoryPressure=${mode:-?} after installing $OOMD_DROPIN (want auto) — systemd-analyze cat-config user@.service"; fi
    # The monitored list sits between "Memory Pressure Monitored CGroups:" and the end.
    if ! oomctl_out=$(oomctl 2>/dev/null); then
        done_ "(oomctl failed — is systemd-oomd running? check: oomctl)"
    elif printf '%s\n' "$oomctl_out" | sed -n '/Memory Pressure Monitored CGroups:/,$p' | grep -q 'user@1000\.service$'; then
        fail oomd "oomctl still monitors user@1000.service for memory pressure — systemctl restart systemd-oomd, then: oomctl"
    else
        done_ "oomctl: user@1000.service not monitored for memory pressure"
    fi
fi

# ------------------------------------------------------- 10. sysctl ---------
say "10. sysctl: vm.dirty_background_bytes=256M, vm.dirty_bytes=1G"
install_file "$REPO_SYSCTL_DIRTY" "$SYSCTL_DIRTY" 0644 || true
if [ "$DRY" -eq 1 ]; then
    run sysctl -q -p "$SYSCTL_DIRTY"
elif [ "$(sysctl -n vm.dirty_background_bytes)" = 268435456 ] && [ "$(sysctl -n vm.dirty_bytes)" = 1073741824 ]; then
    done_ "vm.dirty_background_bytes / vm.dirty_bytes already 268435456 / 1073741824"
elif sysctl -q -p "$SYSCTL_DIRTY" && [ "$(sysctl -n vm.dirty_bytes)" = 1073741824 ]; then
    did "applied $SYSCTL_DIRTY (vm.dirty_ratio now $(sysctl -n vm.dirty_ratio): the *_bytes knobs replace the ratios)"
else
    fail sysctl "vm.dirty_bytes is $(sysctl -n vm.dirty_bytes) after sysctl -p $SYSCTL_DIRTY"
fi

# ------------------------------------------------------- 11. /tmp on NVMe ---
say "11. /tmp on the NVMe: bind $TMP_SRC onto /tmp (from the next boot)"
# tmp_bind_active: /tmp is a mount point whose filesystem is the NVMe's and
# whose root is $TMP_SRC (same device and inode).
tmp_bind_active() {
    mountpoint -q /tmp 2>/dev/null && [ -d "$TMP_SRC" ] \
        && [ "$(stat -c '%d:%i' /tmp 2>/dev/null)" = "$(stat -c '%d:%i' "$TMP_SRC" 2>/dev/null)" ]
}
if ! mountpoint -q "$TMP_BASE" 2>/dev/null; then
    fail tmp-on-nvme "$TMP_BASE is not mounted — /tmp is left on / (re-run once it is)"
elif grep -qE '^[[:space:]]*[^#[:space:]]+[[:space:]]+/tmp[[:space:]]' /etc/fstab; then
    fail tmp-on-nvme "/etc/fstab already has a /tmp line (its generated tmp.mount would fight $UNIT_DIR/tmp.mount) — remove it and re-run"
else
    # The source dir: root:root 1777 with no ACL entries, i.e. exactly /tmp's
    # semantics (sticky: nobody lists-and-deletes another user's files). It
    # must stay out of archon-user/install.sh's deny loop (BASE_ALLOW), which
    # would otherwise lock archon out of /tmp itself.
    if [ -d "$TMP_SRC" ] && [ "$(stat -c '%a %U:%G' "$TMP_SRC")" = "1777 root:root" ]; then
        done_ "$TMP_SRC already root:root 1777"
    else
        run install -d -m 1777 -o root -g root "$TMP_SRC" && run chmod 1777 "$TMP_SRC" && did "created $TMP_SRC (root:root 1777)"
    fi
    if [ -d "$TMP_SRC" ] && [ -n "$(getfacl -cps --skip-base "$TMP_SRC" 2>/dev/null)" ]; then
        run setfacl -b "$TMP_SRC" && did "removed ACL entries from $TMP_SRC (plain 1777, like /tmp)"
    fi
    if tmp_bind_active; then
        done_ "/tmp is already the bind of $TMP_SRC ($(df -h --output=avail /tmp | tail -n1 | tr -d ' ') free)"
        install_file "$REPO_TMP_MOUNT" "$UNIT_DIR/tmp.mount" 0644 && { run systemctl daemon-reload && did "daemon-reload"; }
        if [ "$DRY" -eq 0 ] && ! systemctl is-enabled -q tmp.mount 2>/dev/null; then
            run systemctl enable tmp.mount && did "enabled tmp.mount"
        fi
        # The old /tmp on / is hidden under the bind: systemd-tmpfiles empties
        # /tmp at boot only after the bind is up, so whatever sat there at the
        # switch-over reboot still fills /. Look underneath through a private
        # non-recursive bind of / (shows the root filesystem only) and empty it.
        if [ "$DRY" -eq 1 ]; then
            done_ "DRY-RUN: would bind / at a temp dir under /run, empty its tmp/ (the old /tmp on /, hidden under the bind) and unmount it"
        elif peek=$(mktemp -d /run/tmp-underlay.XXXXXX); then
            if mount --bind / "$peek"; then
                if [ "$(stat -c %d "$peek/tmp")" != "$(stat -c %d /)" ]; then
                    fail tmp-on-nvme "$peek/tmp is not on the root filesystem — not touching it"
                elif [ -z "$(find "$peek/tmp" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
                    done_ "old /tmp on / (under the bind) already empty"
                else
                    mb=$(du -sxm "$peek/tmp" 2>/dev/null | cut -f1)
                    if find "$peek/tmp" -xdev -mindepth 1 -delete 2>/dev/null; then
                        did "emptied the old /tmp on / hidden under the bind (${mb:-?}MB freed on /)"
                    else
                        fail tmp-on-nvme "could not empty all of the old /tmp on / (bound at $peek/tmp) — re-run"
                    fi
                fi
                umount "$peek" || fail tmp-on-nvme "umount $peek failed — umount it by hand"
            else
                fail tmp-on-nvme "mount --bind / $peek failed — old /tmp on / not reclaimed"
            fi
            rmdir "$peek" 2>/dev/null || true
        fi
    else
        # Not active yet. Order matters: the defer file first, so no service
        # start (PrivateTmp= services Want tmp.mount) can mount it over the live
        # /tmp between the daemon-reload and the reboot.
        if [ -e "$TMP_DEFER" ]; then done_ "$TMP_DEFER already there (no live remount before the reboot)"
        else run touch "$TMP_DEFER" && did "created $TMP_DEFER (tmp.mount skipped until the next boot)"; fi
        install_file "$REPO_TMP_MOUNT" "$UNIT_DIR/tmp.mount" 0644 && { run systemctl daemon-reload && did "daemon-reload"; }
        if [ "$DRY" -eq 0 ] && systemctl is-enabled -q tmp.mount 2>/dev/null; then
            done_ "tmp.mount already enabled"
        else
            run systemctl enable tmp.mount && did "enabled tmp.mount (not started: it mounts at the next boot)"
        fi
        # A reboot reason the safe-reboot gate acts on (step 8: idle, in its
        # window). Both files are on tmpfs, so after that boot, with the bind
        # active, nothing marks it again. Appended, never overwriting apt's lines.
        if [ -e "$REBOOT_REQUIRED" ]; then done_ "$REBOOT_REQUIRED already there"
        else run sh -c "echo '*** System restart required ***' > $REBOOT_REQUIRED" && did "created $REBOOT_REQUIRED"; fi
        if grep -qx tmp-on-nvme "$REBOOT_REQUIRED.pkgs" 2>/dev/null; then done_ "$REBOOT_REQUIRED.pkgs already names tmp-on-nvme"
        else run sh -c "echo tmp-on-nvme >> $REBOOT_REQUIRED.pkgs" && did "added tmp-on-nvme to $REBOOT_REQUIRED.pkgs"; fi
        done_ "/tmp moves at the next boot; the safe-reboot gate takes it in its next idle window (safe-reboot status). Re-run this script after that boot to reclaim the old /tmp on /."
    fi
fi

# ------------------------------------------------------- 12. tmpfiles -------
say "12. tmpfiles: /tmp entries idle for 2 days are removed (Ubuntu default: 30 days)"
# Takes effect at the next systemd-tmpfiles-clean.timer run (daily); nothing
# is cleaned now.
install_file "$REPO_TMPFILES_TMP" "$TMPFILES_TMP" 0644 || true

# ------------------------------------------------------- 13. cargo /tmp -----
say "13. cargo: builds under /tmp keep their build output off /"
install_file "$REPO_TMPFILES_CARGO" "$TMPFILES_CARGO" 0644 || true
# A /tmp/.cargo some user created first would feed its config to everyone's
# /tmp builds; tmpfiles would keep it. rm -rf does not follow symlinks.
cargo_tmp_owner=$(stat -c %U /tmp/.cargo 2>/dev/null)
if [ -n "$cargo_tmp_owner" ] && [ "$cargo_tmp_owner" != root ]; then
    run rm -rf /tmp/.cargo && did "removed /tmp/.cargo (owned by $cargo_tmp_owner, not root)"
fi
run systemd-tmpfiles --create "$TMPFILES_CARGO"
if [ "$DRY" -eq 0 ]; then
    if [ "$(stat -c %U /tmp/.cargo 2>/dev/null)" = root ] \
        && grep -qF 'build-dir = "{cargo-cache-home}/tmp-build/{workspace-path-hash}"' /tmp/.cargo/config.toml 2>/dev/null; then
        done_ "/tmp/.cargo/config.toml (root-owned) → build-dir {cargo-cache-home}/tmp-build/{workspace-path-hash}"
    else
        fail cargo-tmp "/tmp/.cargo/config.toml missing, not root-owned or without the build-dir line after systemd-tmpfiles --create $TMPFILES_CARGO"
    fi
fi

finish
