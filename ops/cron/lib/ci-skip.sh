#!/usr/bin/env bash
# Shared handling of the CI-skip tokens GitHub honours in a commit message.
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/ci-skip.sh"
#   subject="$(ci_skip_clean_line "$(gh pr view "$pr" --json title --jq .title)")"
#   has_ci_skip_token "$commit_message" && ...
#
# GitHub creates no workflow run at all for a push whose head commit message
# carries one of these tokens. A squash merge composes its message from the
# branch's commit subjects, so a CI-authored snapshot commit can silently
# poison main (interstellarai.net#76).

# Guard against being sourced more than once.
[ -n "${_ARCHON_CI_SKIP_SH:-}" ] && return 0
_ARCHON_CI_SKIP_SH=1

# The six forms GitHub documents, matched case-insensitively and nothing else.
# Matching a form GitHub ignores (e.g. "[skip-ci]") would make the detector in
# pipeline-health-cron.sh diagnose a skipped push that never happened.
_CI_SKIP_RE='\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|\*\*\*NO_CI\*\*\*'

# has_ci_skip_token <text> — true when the text carries a token.
# Returns non-zero on no match, so call it only from an `if`/`&&` position.
has_ci_skip_token() {
    printf '%s' "$1" | grep -qiE "$_CI_SKIP_RE"
}

# strip_ci_skip_tokens <text> — echo the text with every token removed.
# Multi-line safe: lines carrying no token come back byte-identical, so
# indentation, blank lines and fenced code in a PR body survive intact.
strip_ci_skip_tokens() {
    printf '%s' "$1" \
        | sed -E "/$_CI_SKIP_RE/I{s/[[:blank:]]*($_CI_SKIP_RE)//gI; s/[[:blank:]]+\$//;}"
    return 0
}

# ci_skip_clean_line <text> — strip_ci_skip_tokens plus whitespace collapsed to
# single spaces and both ends trimmed. Single-line use only (merge subjects).
ci_skip_clean_line() {
    local _stripped
    _stripped="$(strip_ci_skip_tokens "$1")"
    printf '%s' "$_stripped" | tr -s '[:blank:]' ' ' | sed -E 's/^ //; s/ $//'
    return 0
}
