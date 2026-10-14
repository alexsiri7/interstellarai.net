#!/usr/bin/env bash
# system-maintenance.sh — weekly host upkeep, run as asiri from cron:
#   0 4 * * 0 <repo>/ops/cron/system-maintenance.sh >> ~/.local/state/archon-cron/logs/system-maintenance.log 2>&1
#
# Every privileged command goes through `sudo -n` against the fixed shapes in
# /etc/sudoers.d/archon-cron (ops/host/sudoers-archon-cron, installed by
# ops/host/install.sh). `-n` means a missing or drifted sudoers entry fails
# loud ("sudo: a password is required") instead of hanging on a prompt.
#
#   1. apt-get update / full-upgrade / autoremove (upgradable count logged before
#      and after; anything still upgradable afterwards is explained: kept back
#      or deferred by phasing). full-upgrade, not upgrade: `upgrade` never
#      installs a new package or removes an old one, so an update whose deps
#      changed (nvidia-driver pulling in nvidia-firmware-*, linux-firmware
#      splitting into sub-packages, fwupd 1.9 -> 2.0 needing libfwupd3) stays
#      "kept back" forever. Ubuntu phased updates are left alone by apt's default
#      (APT::Get::Always-Include-Phased-Updates is unset), as they should be.
#   2. remove every disabled snap revision
#   3. journalctl --vacuum-size=500M
#   4. smartctl -H on every disk lsblk reports; ntfy anything not PASSED. A USB
#      disk plain smartctl cannot reach through its bridge is retried with the
#      -d types below; if none answers it is logged "health unknown", not failed.
#   5. /var/run/reboot-required → one ntfy per running kernel (marker in STATE_DIR)
#
# Writes $STATE_DIR/system-maintenance-status (same shape as db-backup-status);
# pipeline-health-cron.sh (check_system_maintenance) ntfys when it reads
# `failed` or goes stale. Any failed step: log + ntfy + exit 1.

set -uo pipefail

# cron's PATH is /usr/bin:/bin; privileged commands use full paths (below), the
# rest (apt, lsblk, curl, sudo) live in /usr/bin. Append, never prepend, so a
# test harness can put stubs first.
export PATH="$PATH:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

LOG_TAG="[system-maintenance]"
STATE_DIR="${SYSTEM_MAINT_STATE_DIR:-$HOME/.archon/pipeline-health-state}"
# Where the crontab sends this script's output (see ops/cron/crontab); named in ntfy bodies only.
LOG_DIR="${ARCHON_CRON_LOG_DIR:-$HOME/.local/state/archon-cron/logs}"
STATUS_FILE="$STATE_DIR/system-maintenance-status"
REBOOT_MARKER="$STATE_DIR/system-maintenance-reboot-notified"
REBOOT_REQUIRED="${SYSTEM_MAINT_REBOOT_REQUIRED:-/var/run/reboot-required}"
JOURNAL_MAX="${SYSTEM_MAINT_JOURNAL_MAX:-500M}"
# Space-separated disk names (as lsblk prints them) to leave out of the SMART check.
SMART_SKIP="${SYSTEM_MAINT_SMART_SKIP:-}"
# Space-separated <disk>:<type> pairs (e.g. "sdd:sntasmedia"): query that disk
# with `smartctl -d <type>` only, and fail the run when it does not answer.
SMART_TYPE="${SYSTEM_MAINT_SMART_TYPE:-}"
# Tried in order on a USB disk without a SYSTEM_MAINT_SMART_TYPE entry whose
# bridge plain `smartctl -H` cannot talk through: SAT, then the NVMe-over-USB
# bridges. Every type here (and any override) needs its own sudoers shape.
SMART_USB_TYPES=(sat sntasmedia sntjmicron sntrealtek)

# Full paths for every `sudo -n` call: they are what the sudoers entries match,
# independent of cron's PATH. Read-only calls (snap list, apt list, lsblk,
# journalctl --disk-usage) go through PATH like any other command.
APT_GET=/usr/bin/apt-get
SNAP=/usr/bin/snap
JOURNALCTL=/usr/bin/journalctl
SMARTCTL=/usr/sbin/smartctl

SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set — populate $SECRETS_FILE}"

log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $*"; }

notify() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-robot}"
    if ! curl -s --fail -o /dev/null --max-time 20 \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
        -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null; then
        log "WARNING: ntfy undelivered: $title"
    fi
}

FAILED=()
fail() {  # <step> <reason> — every error is logged; a step is listed once in the status file
    log "ERROR: $1 — $2"
    case " ${FAILED[*]-} " in *" $1 "*) return ;; esac
    FAILED+=("$1")
}

# root <step> <cmd...>: run one privileged command through `sudo -n`, streaming
# its output into the log. A sudo refusal is reported as such so the fix is
# obvious (re-run `sudo ops/host/install.sh`).
root() {
    local step="$1"; shift
    local out rc
    log "+ sudo -n $*"
    out=$(sudo -n "$@" 2>&1); rc=$?
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
    if [ "$rc" -ne 0 ]; then
        if printf '%s\n' "$out" | grep -q '^sudo: '; then
            fail "$step" "sudo -n refused '$*' (exit $rc) — sudoers entry missing? re-run: sudo ops/host/install.sh"
        else
            fail "$step" "'$*' exited $rc"
        fi
    fi
    return "$rc"
}

upgradable_count() { apt list --upgradable 2>/dev/null | grep -c '\[upgradable from:' || true; }

# apt_sim_section <heading regex>: the package names listed under that heading
# in a `apt-get -s full-upgrade` simulation (needs no root; `-s` is not one of
# the sudoers shapes and never runs through sudo), space-separated, or empty.
APT_SIM=""
apt_sim_section() {
    printf '%s\n' "$APT_SIM" | awk -v h="$1" '$0 ~ h {on=1; next} on && !/^ / {exit} on {print}' | xargs
}

mkdir -p "$STATE_DIR"
log "=== system maintenance start ==="

# --- 1. apt ---------------------------------------------------------------
before=$(upgradable_count)
log "apt: $before package(s) upgradable before"
if root apt "$APT_GET" update; then
    root apt "$APT_GET" -y -o Dpkg::Options::=--force-confold full-upgrade
    root apt "$APT_GET" -y autoremove
fi
after=$(upgradable_count)
log "apt: $after package(s) upgradable after (was $before)"
# Anything still upgradable is either kept back (unsatisfiable deps, a hold —
# stuck until a human looks) or deferred by phasing (fine). Name them so the
# log says which, and record the kept-back set in the status file.
kept_back=""; phased=""
if [ "$after" -gt 0 ]; then
    APT_SIM=$(apt-get -s -o Dpkg::Options::=--force-confold full-upgrade 2>&1)
    kept_back=$(apt_sim_section '^The following packages have been kept back:')
    phased=$(apt_sim_section '^The following upgrades have been deferred due to phasing:')
    [ -n "$phased" ] && log "apt: deferred by phasing (left alone): $phased"
    if [ -n "$kept_back" ]; then
        log "apt: KEPT BACK after full-upgrade (needs a look — hold, or unsatisfiable deps): $kept_back"
    elif [ -z "$phased" ]; then
        log "apt: $after still upgradable but the simulation lists nothing kept back or phased:"
        printf '%s\n' "$APT_SIM" | grep -vE '^(NOTE:|      |Inst |Conf |Remv )' | sed 's/^/    /'
    fi
fi

# --- 2. snap ----------------------------------------------------------------
removed=0
while read -r name rev; do
    [ -n "$name" ] || continue
    root snap "$SNAP" remove --revision="$rev" "$name" && removed=$((removed + 1))
done < <(snap list --all 2>/dev/null | awk 'NR > 1 && $6 ~ /disabled/ {print $1, $3}')
log "snap: removed $removed disabled revision(s)"

# --- 3. journal ---------------------------------------------------------------
log "journal: $(journalctl --disk-usage 2>/dev/null || echo 'usage unknown')"
root journal "$JOURNALCTL" --vacuum-size="$JOURNAL_MAX"

# --- 4. SMART -----------------------------------------------------------------
smart_type_for() {  # <dev>: its SYSTEM_MAINT_SMART_TYPE entry, or nothing
    local pair
    for pair in $SMART_TYPE; do
        [ "${pair%%:*}" = "$1" ] && { printf '%s\n' "${pair#*:}"; return; }
    done
}

# smart_query <dev> [type]: one `smartctl [-d type] -H` through sudo -n. Sets
# SMART_OUT, SMART_RC and SMART_HEALTH: passed; failed (the disk gave a health
# verdict other than PASSED); refused (by sudo); none (no verdict at all — the
# device could not be queried this way).
smart_query() {
    local args=(-H "/dev/$1")
    [ -n "${2:-}" ] && args=(-d "$2" "${args[@]}")
    log "+ sudo -n $SMARTCTL ${args[*]}"
    SMART_OUT=$(sudo -n "$SMARTCTL" "${args[@]}" 2>&1); SMART_RC=$?
    if [ "$SMART_RC" -eq 0 ] && grep -q 'PASSED' <<<"$SMART_OUT"; then
        SMART_HEALTH=passed; return
    fi
    printf '%s\n' "$SMART_OUT" | sed 's/^/    /'
    if grep -q '^sudo: ' <<<"$SMART_OUT"; then
        SMART_HEALTH=refused
    elif [ $((SMART_RC & 8)) -ne 0 ] || grep -qE 'self-assessment test result:|SMART Health Status:' <<<"$SMART_OUT"; then
        SMART_HEALTH=failed   # smartctl exit bit 3: "SMART status check returned DISK FAILING"
    else
        SMART_HEALTH=none
    fi
}

checked=0; unknown=()
while read -r dev tran; do
    case " $SMART_SKIP " in *" $dev "*) log "smart: /dev/$dev skipped (SYSTEM_MAINT_SMART_SKIP)"; continue ;; esac
    checked=$((checked + 1))
    pinned=$(smart_type_for "$dev")
    if [ -n "$pinned" ]; then
        types=("$pinned")
    elif [ "$tran" = usb ]; then
        types=("" "${SMART_USB_TYPES[@]}")
    else
        types=("")
    fi
    for type in "${types[@]}"; do
        smart_query "$dev" "$type"
        [ "$SMART_HEALTH" = none ] || break
    done
    query="smartctl${type:+ -d $type} -H /dev/$dev"
    case "$SMART_HEALTH" in
        passed)
            log "smart: /dev/$dev PASSED${type:+ (-d $type)}"
            continue ;;
        refused)
            fail "smart:/dev/$dev" "sudo -n refused '$query' — sudoers entry missing? re-run: sudo ops/host/install.sh"
            continue ;;
        none)
            if [ "$tran" = usb ] && [ -z "$pinned" ]; then
                log "smart: /dev/$dev health unknown (unsupported USB bridge: tried plain and -d ${SMART_USB_TYPES[*]}; pin a type with SYSTEM_MAINT_SMART_TYPE=$dev:<type>) — not a failure"
                unknown+=("/dev/$dev")
                continue
            fi ;;
    esac
    verdict=$(printf '%s\n' "$SMART_OUT" | grep -iE 'overall-health|result:|unable|failed' | head -n3 | tr '\n' ' ')
    [ -n "$verdict" ] || verdict="(no health line in output; exit $SMART_RC)"
    fail "smart:/dev/$dev" "not PASSED — $verdict"
    notify "SMART: /dev/$dev not PASSED on $(hostname)" \
        "$query (exit $SMART_RC): $verdict — see $LOG_DIR/system-maintenance.log" \
        urgent rotating_light,floppy_disk
done < <(lsblk -dno NAME,TYPE,TRAN 2>/dev/null | awk '$2 == "disk" {print $1, $3}')
log "smart: checked $checked disk(s)${unknown[*]:+, health unknown: ${unknown[*]}}"

# --- 5. reboot pending ----------------------------------------------------
if [ -f "$REBOOT_REQUIRED" ]; then
    kernel=$(uname -r)
    if [ -f "$REBOOT_MARKER" ] && [ "$(cat "$REBOOT_MARKER")" = "$kernel" ]; then
        log "reboot: pending, already notified for running kernel $kernel"
    else
        pkgs=$( [ -r "$REBOOT_REQUIRED.pkgs" ] && sort -u "$REBOOT_REQUIRED.pkgs" | tr '\n' ' ' )
        log "reboot: pending (running kernel $kernel${pkgs:+; packages: $pkgs}) — notifying"
        notify "Reboot pending on $(hostname)" \
            "reboot pending; safe-reboot reboots in the next idle 02:30-06:30 window (safe-reboot status says what blocks it). Running kernel $kernel.${pkgs:+ Triggered by: $pkgs}" \
            default arrows_counterclockwise
        printf '%s\n' "$kernel" > "$REBOOT_MARKER"
    fi
else
    [ -f "$REBOOT_MARKER" ] && { rm -f "$REBOOT_MARKER"; log "reboot: no longer pending — marker cleared"; }
fi

# --- status + exit -----------------------------------------------------------
now=$(date +%s)
last_ok=$(grep -s '^last_ok=' "$STATUS_FILE" | cut -d= -f2 || true)
failed_csv=$(IFS=,; echo "${FAILED[*]-}")
if [ ${#FAILED[@]} -eq 0 ]; then
    last_ok="$now"; run_status=ok
else
    run_status=failed
fi
{
    echo "last_run=$now"
    echo "last_run_status=$run_status"
    echo "last_run_failed=$failed_csv"
    echo "last_run_kept_back=$(printf '%s' "$kept_back" | tr ' ' ',')"
    echo "last_ok=${last_ok:-0}"
} > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"

if [ ${#FAILED[@]} -gt 0 ]; then
    log "=== system maintenance FAILED: $failed_csv ==="
    notify "System maintenance FAILED: $failed_csv" \
        "system-maintenance.sh on $(hostname) failed step(s): $failed_csv. See $LOG_DIR/system-maintenance.log." \
        high warning
    exit 1
fi
log "=== system maintenance done (apt $before -> $after upgradable${kept_back:+, KEPT BACK: $kept_back}, $removed snap rev(s) removed, $((checked - ${#unknown[@]})) disk(s) PASSED${unknown[*]:+, health unknown: ${unknown[*]}}) ==="
