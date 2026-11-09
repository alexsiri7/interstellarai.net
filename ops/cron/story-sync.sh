#!/usr/bin/env bash
# story-sync.sh — bring story changes from Annie into the game repos.
#
# For each line of story-sync.txt (`<annie-project-id> <owner/repo>`):
#   1. Export the Annie project's story bible (story objects, relationships and
#      the outline with each node's latest text) with a READ-ONLY psql session
#      on ANNIE_DB_URL, as Markdown, via lib/annie_export.py.
#   2. Compare it with the export last handed to the factory (a hash in
#      $STATE_DIR). Unchanged: nothing runs.
#   3. Changed: run `archon-story-sync` in the repo's clone with the export dir.
#      That workflow mirrors the export into story/annie/, lets an LLM promote
#      only the settled parts into story/CANON.md (tentative material goes to
#      story/PENDING.md), opens a PR, and files one implementation issue for the
#      factory when the settled story changed what the game must do.
# The hash is recorded only when the workflow succeeded, so a failed run is
# retried the next day.
#
# Crontab:
#   30 6 * * * <repo>/ops/cron/story-sync.sh >> ~/.local/state/archon-cron/logs/story-sync.log 2>&1

set -uo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-as.sh
source "$SCRIPT_DIR/lib/run-as.sh"
# shellcheck source=lib/throttle.sh
source "$SCRIPT_DIR/lib/throttle.sh"
should_tick "story-sync" || exit 0
runas_may_launch "story-sync" || exit 0
# shellcheck source=lib/ship-breaker.sh
source "$SCRIPT_DIR/lib/ship-breaker.sh"
# shellcheck source=lib/quota-pause.sh
source "$SCRIPT_DIR/lib/quota-pause.sh"
quota_may_launch "story-sync" || exit 0
# shellcheck source=lib/secrets.sh
source "$SCRIPT_DIR/lib/secrets.sh"
secrets_load NTFY_TOPIC ANNIE_DB_URL
: "${NTFY_TOPIC:?NTFY_TOPIC not set}"
: "${ANNIE_DB_URL:?ANNIE_DB_URL not set}"

BASE_DIR="${STORY_SYNC_BASE_DIR:-/mnt/ext-fast}"
STATE_DIR="${STORY_SYNC_STATE_DIR:-$HOME/.archon/story-sync-state}"
LOG_DIR="${STORY_SYNC_LOG_DIR:-$HOME/.archon/logs/story-sync}"
CONFIG="${STORY_SYNC_CONFIG:-$SCRIPT_DIR/story-sync.txt}"
LOG_PREFIX="[story-sync]"
export ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1
mkdir -p "$STATE_DIR" "$LOG_DIR"

log() { echo "$(date -Is) $LOG_PREFIX $*"; }
notify() {
  curl -s -o /dev/null -H "Title: $1" -H "Priority: ${3:-default}" -H "Tags: ${4:-books}" \
    -d "$2" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
}

# export_json <project-id> — the project's story bible as one JSON document.
# The session is read-only (default_transaction_read_only), so nothing here can
# write to Annie's production database.
export_json() {
  local id="$1"
  [[ "$id" =~ ^[a-z0-9]+$ ]] || { log "bad Annie project id: $id"; return 1; }
  PGOPTIONS='-c default_transaction_read_only=on' psql "$ANNIE_DB_URL" -X -At -v ON_ERROR_STOP=1 <<SQL
select json_build_object(
  'objects', coalesce((select json_agg(json_build_object(
      'id', o.id, 'type', o.type, 'name', o.name, 'description', o.description,
      'notes', o.notes, 'role', o.role, 'tags', o.tags))
    from "StoryObject" o where o."projectId" = '$id'), '[]'),
  'relationships', coalesce((select json_agg(json_build_object(
      'type', r.type, 'label', r.label, 'fromObjectId', r."fromObjectId", 'toObjectId', r."toObjectId"))
    from "Relationship" r
    join "StoryObject" f on f.id = r."fromObjectId" and f."projectId" = '$id'
    join "StoryObject" t on t.id = r."toObjectId"), '[]'),
  'nodes', coalesce((select json_agg(json_build_object(
      'id', n.id, 'parentId', n."parentId", 'type', n.type, 'title', n.title,
      'synopsis', n.synopsis, 'status', n.status, 'orderIndex', n."orderIndex",
      'content', (select c.content from "ContentVersion" c where c."nodeId" = n.id
                  order by c."createdAt" desc limit 1)))
    from "StructureNode" n where n."projectId" = '$id'), '[]'));
SQL
}

# find_clone <owner/repo> — the repo's local clone, as sweep-audits.sh finds it.
find_clone() {
  local repo="$1" candidate
  for candidate in "$HOME/.archon/workspaces/$repo/source" "$BASE_DIR/$(basename "$repo")" "$HOME/$(basename "$repo")"; do
    [ -d "$candidate/.git" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

[ -r "$CONFIG" ] || { log "no config at $CONFIG"; exit 0; }
failed=0
while read -r project repo _; do
  [ -z "${project:-}" ] || [[ "$project" == \#* ]] && continue
  name=$(basename "$repo")
  # The export dir must be readable by the user archon runs agents as.
  export_dir=$(mktemp -d "${TMPDIR:-/tmp}/story-sync-$name-XXXXXX")
  chmod 755 "$export_dir"
  if ! json=$(export_json "$project") || ! python3 -I "$SCRIPT_DIR/lib/annie_export.py" "$export_dir/annie" <<<"$json"; then
    log "$name: could not export Annie project $project"
    notify "Story sync failed: $name" "Could not read Annie project $project" high x
    rm -rf "$export_dir"; failed=1; continue
  fi
  chmod -R a+rX "$export_dir"
  hash=$(cd "$export_dir/annie" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
  if [ "$(cat "$STATE_DIR/$name.sha" 2>/dev/null)" = "$hash" ]; then
    log "$name: Annie unchanged since the last sync"
    rm -rf "$export_dir"; continue
  fi
  if ! clone=$(find_clone "$repo"); then
    log "$name: no local clone of $repo"
    notify "Story sync: $name" "No local clone of $repo" high warning
    rm -rf "$export_dir"; failed=1; continue
  fi
  logfile="$LOG_DIR/$name-$(date +%Y%m%d-%H%M).log"
  log "$name: Annie changed — running archon-story-sync in $clone"
  if (cd "$clone" && CLAUDECODE=0 archon workflow run archon-story-sync "$export_dir/annie" > "$logfile" 2>&1); then
    echo "$hash" > "$STATE_DIR/$name.sha"
    summary=$(grep -E '^(STORY_SYNC_PR|STORY_SYNC_ISSUE|STORY_SYNC_NOTHING):' "$logfile" | tr '\n' ' ')
    log "$name: done ${summary:-}"
    notify "Story synced: $name" "${summary:-archon-story-sync finished}" default books
  else
    log "$name: archon-story-sync failed (see $logfile)"
    notify "Story sync failed: $name" "archon-story-sync failed — $logfile" high x
    failed=1
  fi
  rm -rf "$export_dir"
done < "$CONFIG"
exit "$failed"
