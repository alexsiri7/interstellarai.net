#!/usr/bin/env bash
# system-maintenance.sh — weekly host upkeep, run as asiri from cron:
#   0 4 * * 0 <repo>/ops/cron/system-maintenance.sh >> ~/.local/state/archon-cron/logs/system-maintenance.log 2>&1
#
# Every privileged command goes through `sudo -n` against the fixed shapes in
# /etc/sudoers.d/archon-cron (ops/host/sudoers-archon-cron, installed by
# ops/host/install.sh). `-n` means a missing or drifted sudoers entry fails
# loud ("sudo: a password is required") instead of hanging on a prompt.
#
#   1. apt-get update / upgrade / autoremove (upgradable count logged before and after)
#   2. remove every disabled snap revision
#   3. journalctl --vacuum-size=500M
#   4. smartctl -H on every disk lsblk reports; ntfy anything not PASSED
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

mkdir -p "$STATE_DIR"
log "=== system maintenance start ==="

# --- 1. apt ---------------------------------------------------------------
before=$(upgradable_count)
log "apt: $before package(s) upgradable before"
if root apt "$APT_GET" update; then
    root apt "$APT_GET" -y -o Dpkg::Options::=--force-confold upgrade
    root apt "$APT_GET" -y autoremove
fi
after=$(upgradable_count)
log "apt: $after package(s) upgradable after (was $before)"

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
checked=0
for dev in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}'); do
    case " $SMART_SKIP " in *" $dev "*) log "smart: /dev/$dev skipped (SYSTEM_MAINT_SMART_SKIP)"; continue ;; esac
    checked=$((checked + 1))
    log "+ sudo -n $SMARTCTL -H /dev/$dev"
    out=$(sudo -n "$SMARTCTL" -H "/dev/$dev" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'PASSED'; then
        log "smart: /dev/$dev PASSED"
        continue
    fi
    verdict=$(printf '%s\n' "$out" | grep -iE 'overall-health|result:|^sudo: |unable|failed' | head -n3 | tr '\n' ' ')
    [ -n "$verdict" ] || verdict="(no health line in output; exit $rc)"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail "smart:/dev/$dev" "not PASSED — $verdict"
    notify "SMART: /dev/$dev not PASSED on $(hostname)" \
        "smartctl -H /dev/$dev (exit $rc): $verdict — see $LOG_DIR/system-maintenance.log" \
        urgent rotating_light,floppy_disk
done
log "smart: checked $checked disk(s)"

# --- 5. reboot pending ----------------------------------------------------
if [ -f "$REBOOT_REQUIRED" ]; then
    kernel=$(uname -r)
    if [ -f "$REBOOT_MARKER" ] && [ "$(cat "$REBOOT_MARKER")" = "$kernel" ]; then
        log "reboot: pending, already notified for running kernel $kernel"
    else
        pkgs=$( [ -r "$REBOOT_REQUIRED.pkgs" ] && sort -u "$REBOOT_REQUIRED.pkgs" | tr '\n' ' ' )
        log "reboot: pending (running kernel $kernel${pkgs:+; packages: $pkgs}) — notifying"
        notify "Reboot pending on $(hostname)" \
            "reboot pending; auto-reboot at 04:30 (unattended-upgrades Automatic-Reboot). Running kernel $kernel.${pkgs:+ Triggered by: $pkgs}" \
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
    echo "last_ok=${last_ok:-0}"
} > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"

if [ ${#FAILED[@]} -gt 0 ]; then
    log "=== system maintenance FAILED: $failed_csv ==="
    notify "System maintenance FAILED: $failed_csv" \
        "system-maintenance.sh on $(hostname) failed step(s): $failed_csv. See $LOG_DIR/system-maintenance.log." \
        high warning
    exit 1
fi
log "=== system maintenance done (apt $before -> $after upgradable, $removed snap rev(s) removed, $checked disk(s) PASSED) ==="
