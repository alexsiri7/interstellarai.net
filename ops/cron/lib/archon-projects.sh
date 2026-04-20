#!/usr/bin/env bash
# Shared loader for the archon-managed project list.
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/archon-projects.sh"
#   load_archon_projects MY_ARRAY
# Reads from $ARCHON_PROJECTS_FILE (default: archon-projects.txt sibling of the
# lib/ directory), one project per line. Lines may contain trailing `#`
# comments; blank lines and comment-only lines are ignored. Duplicates deduped.
# On missing or empty file, logs to stderr and exits 1.

# Populates the named array arg with the deduped project list.
# Usage: load_archon_projects PROJECTS
load_archon_projects() {
    local _out_name="$1"
    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _file="${ARCHON_PROJECTS_FILE:-$_lib_dir/../archon-projects.txt}"

    if [ ! -f "$_file" ]; then
        echo "archon-projects: file not found: $_file" >&2
        exit 1
    fi

    local -a _tmp=()
    local -A _seen=()
    local _line
    while IFS= read -r _line || [ -n "$_line" ]; do
        # Strip comments (everything from first '#') and all whitespace
        _line="${_line%%#*}"
        _line="${_line//[[:space:]]/}"
        [ -z "$_line" ] && continue
        if [ -z "${_seen[$_line]:-}" ]; then
            _seen[$_line]=1
            _tmp+=("$_line")
        fi
    done < "$_file"

    if [ "${#_tmp[@]}" -eq 0 ]; then
        echo "archon-projects: no projects parsed from $_file (file empty or all comments)" >&2
        exit 1
    fi

    # Assign to caller's array by name. Using eval for broad bash-4 compatibility
    # (nameref requires bash 4.3+; most systems have it but eval is safer).
    eval "$_out_name=(\"\${_tmp[@]}\")"
}
