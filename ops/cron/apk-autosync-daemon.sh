#!/usr/bin/env bash
# apk-autosync-daemon.sh — event-driven companion to auto-apk-sync.sh.
# Streams `adb track-devices` and invokes the sync script the moment a
# device transitions to `device` state (fully authorised / ready). Sends
# a ntfy notification summarising what was installed / skipped / failed.
#
# One-line usage:
#   status:  systemctl --user status apk-autosync.service
#   logs:    journalctl --user -u apk-autosync.service -f   (or tail -f /tmp/apk-autosync-daemon.log)
#   stop:    systemctl --user stop apk-autosync.service
#   restart: systemctl --user restart apk-autosync.service
#   disable: systemctl --user disable --now apk-autosync.service
#
# ntfy topic is read from $NTFY_TOPIC in $ARCHON_CRON_SECRETS (default
# ~/.config/archon-cron/secrets.env). Missing → fails loud; no guessable fallback.
#
# The 5-min cron (`auto-apk-sync.sh`) is still the belt-and-braces fallback.

set -euo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/auto-apk-sync.sh"
LOG_FILE="/tmp/apk-autosync-daemon.log"
SYNC_LOG="/tmp/apk-sync.log"
LOG_PREFIX="[apk-autosync-daemon]"
DEBOUNCE_SECONDS=60

# NTFY_TOPIC loaded from secrets.env (see ops/cron/README.md). Fail loud if unset
# — falling back to a guessable default would let anyone publish to this topic.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set — populate $SECRETS_FILE}"
# Base URL for ntfy — override with NTFY_BASE_URL for local testing.
NTFY_BASE_URL="${NTFY_BASE_URL:-https://ntfy.sh}"

log() {
  local line
  line="$(date -Is) $LOG_PREFIX $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE"
}

notify() {
  local title="$1" msg="$2" priority="${3:-default}" tags="${4:-iphone}"
  curl -s -o /dev/null \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
    -d "$msg" "$NTFY_BASE_URL/$NTFY_TOPIC" 2>/dev/null || true
}

# Debounce table: serial → epoch of last run.
declare -A LAST_RUN

# Parse `auto-apk-sync.sh` output for a specific serial and build a
# human-friendly multi-line body. Echoes the body; sets global
# PRIORITY=default|high based on whether any install failed.
PRIORITY="default"
summarise_run() {
  local serial="$1" run_log="$2"
  PRIORITY="default"

  # Only lines matching this serial (ignore other devices).
  # Looking for `installed`, `install failed`, or implicit "skipped" when
  # the state file already records the current SHA (no install/skip line).
  local body=""
  local -A STATUS      # project -> status string
  local -A SHA_NOW     # project -> installed sha
  local -A SHA_PREV    # project -> previous sha

  while IFS= read -r line; do
    # e.g. `... [apk-sync] cosmic-match: installing cosmic-match-26a4bdb.apk on 41110DLJG000P5 (prev=cosmic-match-d723d44.apk)`
    if [[ "$line" =~ \[apk-sync\]\ ([a-z-]+):\ installing\ [a-z-]+-([0-9a-f]+)\.apk\ on\ ${serial}\ \(prev=([^\)]*)\) ]]; then
      local proj="${BASH_REMATCH[1]}" sha="${BASH_REMATCH[2]}" prev="${BASH_REMATCH[3]}"
      # Strip filename wrapper from prev -> keep just the sha (or empty).
      if [[ "$prev" =~ -([0-9a-f]+)\.apk$ ]]; then
        prev="${BASH_REMATCH[1]}"
      fi
      SHA_NOW[$proj]="$sha"
      SHA_PREV[$proj]="$prev"
      STATUS[$proj]="installing"
      continue
    fi
    # e.g. `... [apk-sync] cosmic-match: installed cosmic-match-26a4bdb.apk on 41110DLJG000P5`
    if [[ "$line" =~ \[apk-sync\]\ ([a-z-]+):\ installed\ [a-z-]+-([0-9a-f]+)\.apk\ on\ ${serial}$ ]]; then
      local proj="${BASH_REMATCH[1]}"
      STATUS[$proj]="installed"
      continue
    fi
    # e.g. `... [apk-sync] cosmic-match: install failed on 41110DLJG000P5 — <msg>`
    if [[ "$line" =~ \[apk-sync\]\ ([a-z-]+):\ install\ failed\ on\ ${serial} ]]; then
      local proj="${BASH_REMATCH[1]}"
      STATUS[$proj]="failed"
      PRIORITY="high"
      continue
    fi
  done < "$run_log"

  # Also pick up "skipped — already installed" for projects that didn't
  # appear in installing lines. Read current symlinks + state files.
  local projects=(cosmic-match un-reminder)
  for proj in "${projects[@]}"; do
    if [ -z "${STATUS[$proj]:-}" ]; then
      local link="$HOME/apks/${proj}-latest.apk"
      local state_file="$HOME/.apk-sync-state/${serial}-${proj}.sha"
      if [ -e "$link" ] && [ -f "$state_file" ]; then
        local cur prev
        cur=$(readlink "$link")
        prev=$(cat "$state_file")
        if [ "$cur" = "$prev" ] && [[ "$cur" =~ -([0-9a-f]+)\.apk$ ]]; then
          SHA_NOW[$proj]="${BASH_REMATCH[1]}"
          STATUS[$proj]="skipped"
        fi
      fi
    fi
  done

  # Build body lines in a stable order.
  for proj in "${projects[@]}"; do
    local st="${STATUS[$proj]:-unknown}"
    local sha="${SHA_NOW[$proj]:-?}"
    local prev="${SHA_PREV[$proj]:-}"
    case "$st" in
      installed)
        if [ -n "$prev" ]; then
          body+="${proj}: ${sha} (installed, was ${prev})"$'\n'
        else
          body+="${proj}: ${sha} (installed, fresh)"$'\n'
        fi
        ;;
      skipped)
        body+="${proj}: ${sha} (skipped — already installed)"$'\n'
        ;;
      installing)
        body+="${proj}: ${sha} (install started — no completion line)"$'\n'
        PRIORITY="high"
        ;;
      failed)
        body+="${proj}: install failed"$'\n'
        ;;
      unknown)
        body+="${proj}: no state (APK not yet fetched?)"$'\n'
        ;;
    esac
  done

  # Trim trailing newline.
  printf '%s' "${body%$'\n'}"
}

run_sync_for_device() {
  local serial="$1"
  log "device $serial attached; triggering sync"
  local run_log
  run_log=$(mktemp /tmp/apk-autosync-run.XXXXXX)

  # Execute the existing cron script. Tee its output into the tmp file AND
  # the shared /tmp/apk-sync.log so the normal log history is preserved.
  if "$SYNC_SCRIPT" 2>&1 | tee -a "$SYNC_LOG" > "$run_log"; then
    local body
    body=$(summarise_run "$serial" "$run_log")
    log "sync completed for $serial; priority=$PRIORITY"
    notify "📱 Phone synced" "$body" "$PRIORITY"
  else
    local rc=$?
    log "sync script exited non-zero (rc=$rc) for $serial"
    local tail_lines
    tail_lines=$(tail -n 10 "$run_log" 2>/dev/null || echo "(no output)")
    notify "📱 Phone sync FAILED" "auto-apk-sync.sh exited rc=$rc"$'\n\n'"$tail_lines" "high" "warning"
  fi

  rm -f "$run_log"
}

log "daemon starting (ntfy topic=$NTFY_TOPIC, debounce=${DEBOUNCE_SECONDS}s)"

# Ensure adb server is up so track-devices doesn't race with a cold start.
adb start-server >/dev/null 2>&1 || true

# `adb track-devices` streams binary-framed records: a 4-char hex length
# prefix followed by `<serial>\t<state>\n` (multiple serials separated by
# newlines within one record). We track each serial's last-seen state so
# we only fire on transitions into `device`.
declare -A DEVICE_STATE

# Read adb track-devices one framed record at a time. bash's builtin
# `read` is line-oriented and would strip the newlines in the payload,
# so we read exact byte counts from stdin's fd 0 using `head -c`.
# Note: `head -c` on stdin consumes exactly N bytes and stops — this is
# what we want. The parent `stdbuf -o0 adb track-devices | ...` pipes
# keep the stream alive.
process_stream() {
  local hex n payload
  while hex=$(head -c 4); do
    [ -z "$hex" ] && break
    [ "${#hex}" -lt 4 ] && break
    if [[ ! "$hex" =~ ^[0-9a-fA-F]{4}$ ]]; then
      log "stream desync: got non-hex prefix '$hex' — bailing"
      return 1
    fi
    n=$((16#$hex))
    if [ "$n" -gt 0 ]; then
      payload=$(head -c "$n")
    else
      payload=""
    fi
    handle_record "$payload"
  done
}

handle_record() {
  local payload="$1"
  # Empty payload means "no devices".
  if [ -z "$payload" ]; then
    # Mark all known devices as offline.
    for s in "${!DEVICE_STATE[@]}"; do
      if [ "${DEVICE_STATE[$s]}" != "offline" ]; then
        log "device $s removed"
        DEVICE_STATE[$s]="offline"
      fi
    done
    return
  fi
  # Build set of serials present in this record.
  declare -A SEEN=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local serial state
    serial="${line%%$'\t'*}"
    state="${line#*$'\t'}"
    SEEN[$serial]=1
    local prev="${DEVICE_STATE[$serial]:-absent}"
    if [ "$prev" != "$state" ]; then
      log "device $serial: $prev -> $state"
      DEVICE_STATE[$serial]="$state"
      if [ "$state" = "device" ] && [ "$prev" != "device" ]; then
        # Debounce in the parent so state survives across the fork.
        local now last delta
        now=$(date +%s)
        last="${LAST_RUN[$serial]:-0}"
        delta=$((now - last))
        if [ "$last" -gt 0 ] && [ "$delta" -lt "$DEBOUNCE_SECONDS" ]; then
          log "device $serial reconnected after ${delta}s — debounced (threshold ${DEBOUNCE_SECONDS}s), skipping"
        else
          LAST_RUN[$serial]="$now"
          # Fire async so we don't block the stream reader.
          ( run_sync_for_device "$serial" ) &
        fi
      fi
    fi
  done <<< "$payload"
  # Any serial we previously knew about that isn't in this record is gone.
  for s in "${!DEVICE_STATE[@]}"; do
    if [ -z "${SEEN[$s]:-}" ] && [ "${DEVICE_STATE[$s]}" != "offline" ]; then
      log "device $s removed"
      DEVICE_STATE[$s]="offline"
    fi
  done
}

# Trap SIGTERM cleanly.
trap 'log "daemon received signal, exiting"; exit 0' TERM INT

# Run the stream. adb track-devices writes binary framing, so disable
# buffering where possible and read it as a byte stream.
stdbuf -o0 adb track-devices 2>>"$LOG_FILE" | process_stream

# If we reach here, the stream ended — systemd will restart us.
log "adb track-devices stream ended; exiting to let systemd restart"
exit 1
