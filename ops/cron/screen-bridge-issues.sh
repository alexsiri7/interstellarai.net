#!/usr/bin/env bash
# screen-bridge-issues.sh — dry run of the bridge-issue screening (lib/screen.sh)
# over past issues. Writes nothing to GitHub: prints one line per bridge-filed
# issue with what screening would decide today, then a summary.
#
# Usage:
#   ops/cron/screen-bridge-issues.sh [--days N] [project ...]   # default 30 days, all projects
#
# Uses the classifier (one request per issue that passes the heuristics).

set -uo pipefail
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
load_archon_projects DEFAULT_PROJECTS
# shellcheck source=lib/human-labels.sh
source "$SCRIPT_DIR/lib/human-labels.sh"
# shellcheck source=lib/trust.sh
source "$SCRIPT_DIR/lib/trust.sh"
# shellcheck source=lib/screen.sh
source "$SCRIPT_DIR/lib/screen.sh"

DAYS=30
if [ "${1:-}" = "--days" ]; then DAYS="$2"; shift 2; fi
PROJECTS=("${DEFAULT_PROJECTS[@]}")
[ $# -gt 0 ] && PROJECTS=("$@")
since=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)
human=$(printf '%s\n' "${HUMAN_LABELS[@]}" | jq -R . | jq -sc .)

declare -A total=()
for project in "${PROJECTS[@]}"; do
  list=$(gh issue list --repo "$TRUST_OWNER/$project" --state all --limit 300 \
    --search "created:>=${since%%T*}" --json number,author,labels,title,body,createdAt,state 2>/dev/null || echo '[]')
  while IFS=$'\t' read -r num source human_only; do
    [ -n "$num" ] || continue
    if [ "$human_only" = "true" ]; then
      decision="human-only (never built)"
    else
      issue=$(gh issue view "$num" --repo "$TRUST_OWNER/$project" --json number,title,body 2>/dev/null) || continue
      decision=$(screen_issue_text "$project" "$source" "$(_screen_text "$issue")")
    fi
    title=$(jq -r --argjson n "$num" '.[] | select(.number == $n) | .title[0:70]' <<<"$list")
    printf '%s #%s [%s] %s — %s\n' "$project" "$num" "$source" "$decision" "$title"
    total["${decision%% *}"]=$(( ${total["${decision%% *}"]:-0} + 1 ))
  done < <(jq -r --argjson human "$human" "$_TRUST_SOURCE_JQ"'
      sort_by(.createdAt)[] | select(bridge_source != "")
      | "\(.number)\t\(bridge_source)\t\([.labels[]?.name] | any(IN($human[])))"' <<<"$list" 2>/dev/null)
done
echo "--- last $DAYS days:$(for k in "${!total[@]}"; do printf ' %s=%s' "$k" "${total[$k]}"; done)"
