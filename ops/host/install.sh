#!/usr/bin/env bash
# ops/host/install.sh — one-time host setup for the archon build machine.
#
#   sudo ops/host/install.sh            # apply (idempotent: re-runs say "already done")
#   ops/host/install.sh --dry-run       # print every command and file it would write, as any user
#
# What it does (see ops/host/README.md):
#   1. /etc/sudoers.d/archon-cron          NOPASSWD for the weekly system-maintenance.sh
#   2. journald                            SystemMaxUse=500M
#   3. unattended-upgrades                 also take -updates, autoremove, auto-reboot 05:45
#   4. snap                                refresh.retain=2, drop disabled revisions
#   5. smartmontools                       smartd with ntfy hook, short/long self-tests
#   6. NodeSource                          node_20.x (EOL) -> node_24.x (current LTS)
#   7. report whether a reboot is pending
#
# Every step is guarded so it can be run again after a partial failure.
#
# Test hook (ops/cron/tests/host-install.bats): HOST_INSTALL_SUDOERS_D=<dir>
# points step 1 at <dir> instead of /etc/sudoers.d, skips the root check and
# stops after step 1, so the sudoers logic runs against a stubbed visudo.

set -uo pipefail

DRY=0
case "${1:-}" in
    --dry-run|-n) DRY=1 ;;
    "") ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (only --dry-run)" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SUDOERS="$SCRIPT_DIR/sudoers-archon-cron"
REPO_SMARTD_NTFY="$SCRIPT_DIR/smartd-ntfy"

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
say "3. unattended-upgrades: -updates origin, autoremove, auto-reboot 05:45"
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
Unattended-Upgrade::Automatic-Reboot "true";
// 05:45, not earlier: the Sunday crontab runs system-maintenance at 04:00 (apt can
// run long), the backup restore test at 04:30 and pipeline-health --trim at 05:00;
// every one of them has finished before this.
Unattended-Upgrade::Automatic-Reboot-Time "05:45";
'
write_file "$APT_DROPIN" 0644 "$APT_CONTENT" || true
if [ "$DRY" -eq 0 ]; then
    if apt-config dump Unattended-Upgrade::Allowed-Origins | grep -q -- '-updates'; then
        done_ "apt-config sees the -updates origin"
    else
        fail unattended-upgrades "apt-config dump does not list the -updates origin after writing $APT_DROPIN"
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
    done_ "/var/run/reboot-required EXISTS — a reboot is pending$( [ -r /var/run/reboot-required.pkgs ] && printf ' (%s)' "$(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')" ). unattended-upgrades will reboot at 05:45 once it next runs; or: sudo reboot"
else
    done_ "/var/run/reboot-required absent — no reboot pending"
fi

finish
