#!/usr/bin/env bash
# Shared throttle gate for Archon pipeline cron scripts.
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/throttle.sh"
#   should_tick "<script-name>" || exit 0
#
# Reads TICK_INTERVAL_MINUTES from the throttle.conf file that lives alongside
# the lib/ directory. Defaults to 60 if the file is missing or the key is
# absent. State is kept in ~/.config/archon-cron/state/<script-name>.last_run
# as a Unix timestamp.

# Guard against being sourced more than once.
[ -n "${_ARCHON_THROTTLE_SH:-}" ] && return 0
_ARCHON_THROTTLE_SH=1

# Returns 0 (do work) or 1 (skip — too soon since last run).
# Args: $1 = script-name (used as state file key)
should_tick() {
    local _name="$1"
    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _conf="${_lib_dir}/../throttle.conf"

    # Parse TICK_INTERVAL_MINUTES from config, defaulting to 60.
    local _interval=60
    if [ -f "$_conf" ]; then
        local _raw
        _raw=$(grep -E '^TICK_INTERVAL_MINUTES=' "$_conf" 2>/dev/null | tail -1 | cut -d= -f2-)
        # Strip inline comments and whitespace.
        _raw="${_raw%%#*}"
        _raw="${_raw//[[:space:]]/}"
        case "$_raw" in
            '') ;;
            *[!0-9]*)
                echo "$(date -Is) [throttle] ${_name}: WARNING — invalid TICK_INTERVAL_MINUTES='$_raw', using default ${_interval}m" >&2
                ;;
            *) _interval="$_raw" ;;
        esac
    fi

    local _state_dir="$HOME/.config/archon-cron/state"
    if ! mkdir -p "$_state_dir" 2>/dev/null; then
        echo "$(date -Is) [throttle] ${_name}: WARNING — cannot create state dir $_state_dir, throttle disabled" >&2
    fi
    local _state_file="$_state_dir/${_name}.last_run"

    local _last_run=0
    if [ -f "$_state_file" ]; then
        local _content
        _content=$(cat "$_state_file" 2>/dev/null || echo "")
        case "$_content" in
            '') _last_run=0 ;;
            *[!0-9]*)
                echo "$(date -Is) [throttle] ${_name}: WARNING — corrupt state file, resetting" >&2
                _last_run=0
                ;;
            *) _last_run="$_content" ;;
        esac
    fi

    local _now; _now=$(date +%s)
    local _elapsed=$(( _now - _last_run ))
    local _interval_secs=$(( _interval * 60 ))

    if [ "$_elapsed" -lt "$_interval_secs" ]; then
        local _remaining=$(( _interval_secs - _elapsed ))
        local _rem_m=$(( _remaining / 60 ))
        local _rem_s=$(( _remaining % 60 ))
        echo "$(date -Is) [throttle] ${_name}: skipping (next tick in ${_rem_m}m ${_rem_s}s)"
        return 1
    fi

    if ! echo "$_now" > "$_state_file" 2>/dev/null; then
        echo "$(date -Is) [throttle] ${_name}: WARNING — cannot write state file $_state_file, next run will not be throttled" >&2
    fi
    return 0
}
