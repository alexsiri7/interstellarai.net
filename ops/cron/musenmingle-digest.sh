#!/usr/bin/env bash
# musenmingle-digest.sh — once a day, one ntfy to the owner about what is new
# in Muse & Mingle (repo alexsiri7/musenmingle, formerly alexsiri7/thaleia):
#
#   1. venue contact requests (events.contact_requests): kind + domain + result
#      (filed → issue #N, commented → added to issue #N, pending_issue)
#   2. site suggestions (events.site_suggestions): domain + result (accepted →
#      new-scraper issue #N, duplicate → which source covers it / already
#      suggested, refused → reason_code, rejected, pending)
#   3. sources whose first successful run fell in the window (events found),
#      and sources whose first run fell in it and never succeeded (error
#      summary, truncated)
#   4. sites newly refused (events.refused_sources) with reason_code
#   5. sources that broke (a scraper-broken issue opened, events.health_issues)
#
# Privacy: the reply email, the free-text details of a contact request, the
# submitter's note on a suggestion and every IP hash are never selected, so
# they cannot reach the message or the log.
#
# Window: from the end of the last successful digest (state file) to now,
# at most MM_DIGEST_MAX_DAYS (7) back; 24 h on the very first run. The state
# advances only after a delivered ntfy, or when there was nothing to report —
# so a failed or missed day is included in the next digest. No items → no
# ntfy (never an empty ping).
#
# Read-only: the transaction is BEGIN READ ONLY with a statement_timeout, and
# the session also carries default_transaction_read_only=on.
#
# Failure (DB unreachable/query error, ntfy undelivered): logged, exit 1, and
# one "digest failed" ntfy at most once per calendar day.
#
# Secrets (~/.config/archon-cron/secrets.env): MUSENMINGLE_DB_URL, else
# THALEIA_DB_URL (the same role; renamed with the project), and NTFY_TOPIC.
# The URL is turned into the libpq PG* environment (lib/pg-backup.sh) and is
# never printed.
#
# Usage: musenmingle-digest.sh [--dry-run]
#   --dry-run  print the would-be ntfy (title, click URL, body) to stdout;
#              sends nothing and never touches the state files.

set -euo pipefail

# cron's PATH is /usr/bin:/bin.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
    esac
done

SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"

CRON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pg-backup.sh
. "$CRON_DIR/lib/pg-backup.sh"

LOG_TAG="[musenmingle-digest]"
STATE_DIR="${MM_DIGEST_STATE_DIR:-$HOME/.archon/pipeline-health-state/musenmingle-digest}"
WINDOW_FILE="$STATE_DIR/last-window-end"      # epoch seconds
FAILED_FILE="$STATE_DIR/last-failure-ntfy"     # YYYY-MM-DD (Europe/London)
MAX_DAYS="${MM_DIGEST_MAX_DAYS:-7}"
STATEMENT_TIMEOUT_MS="${MM_DIGEST_STATEMENT_TIMEOUT_MS:-15000}"
# ntfy truncates message bodies above 4096 bytes; stay clear of it.
MAX_BODY_BYTES="${MM_DIGEST_MAX_BODY_BYTES:-3800}"
CLICK_PRIMARY="${MM_DIGEST_CLICK_URL:-https://musenmingle.interstellarai.net/sources}"
CLICK_FALLBACK="${MM_DIGEST_CLICK_FALLBACK:-https://thaleia.interstellarai.net/sources}"
NOW="${MM_DIGEST_NOW:-$(date +%s)}"
export TZ=Europe/London

log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# bytes STRING — length in bytes (the lines carry multi-byte → and —).
bytes() { local LC_ALL=C; echo "${#1}"; }

# Same convention as tool-freshness.sh: --fail so a 5xx counts as undelivered.
notify_checked() {
    local title="$1" msg="$2" click="${3:-}" priority="${4:-default}" tags="${5:-performing_arts}"
    local args=(-s --fail -o /dev/null -m 30 -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags")
    [ -n "$click" ] && args+=(-H "Click: $click")
    curl "${args[@]}" -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null
}

# fail REASON — log, ntfy once per day, exit 1. The state file is untouched,
# so the next run covers this window too.
fail() {
    local today
    today=$(date -d "@$NOW" +%F)
    log "ERROR: $1"
    if [ "$DRY_RUN" = 1 ]; then exit 1; fi
    if [ "$(cat "$FAILED_FILE" 2>/dev/null || true)" = "$today" ]; then
        log "failure ntfy already sent today — not repeating"
    elif [ -z "${NTFY_TOPIC:-}" ]; then
        log "WARNING: NTFY_TOPIC not set — cannot ntfy the failure"
    elif notify_checked "Muse & Mingle: digest failed" \
            "$1 — see ~/.local/state/archon-cron/logs/musenmingle-digest.log. The next run retries the same window." \
            "" high warning; then
        echo "$today" > "$FAILED_FILE"
    else
        log "WARNING: failure ntfy undelivered"
    fi
    exit 1
}

[ "$DRY_RUN" = 1 ] || mkdir -p "$STATE_DIR"

if [ "$DRY_RUN" = 0 ] && [ -z "${NTFY_TOPIC:-}" ]; then
    log "ERROR: NTFY_TOPIC not set — populate $SECRETS_FILE"
    exit 1
fi

DB_URL="${MUSENMINGLE_DB_URL:-${THALEIA_DB_URL:-}}"
[ -n "$DB_URL" ] || fail "neither MUSENMINGLE_DB_URL nor THALEIA_DB_URL is set in secrets.env"

# ---------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------
floor=$((NOW - MAX_DAYS * 86400))
since=""
if [ -r "$WINDOW_FILE" ]; then
    since=$(tr -dc '0-9' < "$WINDOW_FILE")
fi
if [ -z "$since" ]; then
    since=$((NOW - 86400))
elif [ "$since" -lt "$floor" ]; then
    log "last digest window ended $(date -d "@$since" '+%F %H:%M') — capping at $MAX_DAYS days"
    since=$floor
fi
if [ "$since" -ge "$NOW" ]; then
    log "window is empty (state $since >= now $NOW) — nothing to do"
    exit 0
fi
log "window $(date -d "@$since" '+%F %H:%M %Z') → $(date -d "@$NOW" '+%F %H:%M %Z')"

# ---------------------------------------------------------------------------
# Query (one read-only transaction; one tab-separated row per item)
# ---------------------------------------------------------------------------
pg_url_to_env "$DB_URL" 2>/dev/null || fail "the Muse & Mingle DB URL does not parse"
export PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c default_transaction_read_only=on -c statement_timeout=$STATEMENT_TIMEOUT_MS"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"
export PGAPPNAME="musenmingle-digest"

# kind <TAB> sort-time <TAB> line. Every free-text column that is selected
# (error_summary) is whitespace-collapsed and truncated in SQL.
SQL=$(cat <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout = :'timeout';
WITH w AS (SELECT to_timestamp(:'since'::bigint) AS since, to_timestamp(:'until'::bigint) AS until)
SELECT 'contact', c.created_at, c.request_type || ' · ' || c.domain || ' → ' ||
       CASE c.status
            WHEN 'filed' THEN 'issue #' || c.github_issue_number
            WHEN 'commented' THEN 'added to issue #' || c.github_issue_number
            WHEN 'pending_issue' THEN 'issue pending'
            ELSE c.status END
  FROM events.contact_requests c, w
 WHERE c.created_at >= w.since AND c.created_at < w.until
UNION ALL
SELECT 'suggestion', g.created_at, g.domain || ' → ' ||
       CASE g.status
            WHEN 'accepted' THEN 'new-scraper issue #' || g.github_issue_number
            WHEN 'pending' THEN 'pending (issue not filed yet)'
            WHEN 'rejected' THEN 'rejected'
            WHEN 'refused' THEN 'refused (' || COALESCE((
                SELECT r.reason_code FROM events.refused_sources r
                 WHERE r.domain = g.domain OR r.domain LIKE '%.' || g.domain OR g.domain LIKE '%.' || r.domain
                 LIMIT 1), 'refused site') || ')'
            WHEN 'duplicate' THEN COALESCE('already covered by ' || (
                SELECT s.key FROM events.sources s
                 WHERE s.domain = g.domain OR s.domain LIKE '%.' || g.domain
                 ORDER BY s.key LIMIT 1), 'already suggested')
            ELSE g.status END
  FROM events.site_suggestions g, w
 WHERE g.created_at >= w.since AND g.created_at < w.until
UNION ALL
SELECT 'live', r.started_at, s.key || ' — ' || r.events_found || ' events'
  FROM events.source_runs r JOIN events.sources s ON s.id = r.source_id, w
 WHERE r.ok AND r.started_at >= w.since AND r.started_at < w.until
   AND NOT EXISTS (SELECT 1 FROM events.source_runs e
                    WHERE e.source_id = r.source_id AND e.ok
                      AND (e.started_at, e.id) < (r.started_at, r.id))
UNION ALL
SELECT 'firstfail', r.started_at, s.key || ' — ' ||
       COALESCE(NULLIF(left(regexp_replace(r.error_summary, '\s+', ' ', 'g'), 80), ''), 'no error summary')
  FROM events.source_runs r JOIN events.sources s ON s.id = r.source_id, w
 WHERE r.started_at >= w.since AND r.started_at < w.until
   AND NOT EXISTS (SELECT 1 FROM events.source_runs e
                    WHERE e.source_id = r.source_id AND (e.started_at, e.id) < (r.started_at, r.id))
   AND NOT EXISTS (SELECT 1 FROM events.source_runs o WHERE o.source_id = r.source_id AND o.ok)
UNION ALL
SELECT 'refused', r.created_at, r.domain || ' (' || r.reason_code || ')'
  FROM events.refused_sources r, w
 WHERE r.created_at >= w.since AND r.created_at < w.until
UNION ALL
SELECT 'broken', h.opened_at, s.key || ' → issue #' || h.github_issue_number ||
       CASE WHEN h.closed_at IS NOT NULL THEN ' (recovered)' ELSE '' END
  FROM events.health_issues h JOIN events.sources s ON s.id = h.source_id, w
 WHERE h.opened_at >= w.since AND h.opened_at < w.until
ORDER BY 1, 2;
COMMIT;
SQL
)

rows_file=$(mktemp)
err_file=$(mktemp)
trap 'rm -f "$rows_file" "$err_file"' EXIT
if ! psql -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1 \
        -v since="$since" -v until="$NOW" -v timeout="$STATEMENT_TIMEOUT_MS" \
        -f - > "$rows_file" 2> "$err_file" <<< "$SQL"; then
    pg_clear_env
    # psql errors never contain the password; keep only the first line.
    fail "DB query failed: $(head -n 1 "$err_file" | cut -c1-200)"
fi
pg_clear_env

# ---------------------------------------------------------------------------
# Message
# ---------------------------------------------------------------------------
declare -A LABEL=(
    [contact]="Contact"
    [suggestion]="Suggested"
    [live]="Live"
    [firstfail]="First run failed"
    [refused]="Refused"
    [broken]="Broken"
)
lines=()
while IFS=$'\t' read -r kind _ text; do
    [ -n "$kind" ] || continue
    lines+=("${LABEL[$kind]:-$kind}: $text")
done < "$rows_file"
# Section order: what needs the owner first.
ordered=()
for k in Contact Suggested Broken "First run failed" Live Refused; do
    for l in "${lines[@]+"${lines[@]}"}"; do
        [[ "$l" == "$k: "* ]] && ordered+=("$l")
    done
done

n=${#ordered[@]}
if [ "$n" -eq 0 ]; then
    log "nothing new — no ntfy"
    if [ "$DRY_RUN" = 1 ]; then
        echo "(nothing to report — no ntfy would be sent)"
    else
        echo "$NOW" > "$WINDOW_FILE"
    fi
    exit 0
fi

counts=""
for k in Contact Suggested Broken "First run failed" Live Refused; do
    c=0
    for l in "${ordered[@]}"; do [[ "$l" == "$k: "* ]] && c=$((c + 1)); done
    [ "$c" -gt 0 ] && counts+="${counts:+, }$k $c"
done
log "$n item(s): $counts"

header="Since $(date -d "@$since" '+%a %d %b %H:%M')"
body="$header"
i=0
for l in "${ordered[@]}"; do
    rest=$((n - i))
    more="+$rest more"
    # Leave room for the "+K more" line whenever this is not the last item.
    if [ $(( $(bytes "$body") + 1 + $(bytes "$l") + ( rest > 1 ? 1 + ${#more} : 0 ) )) -gt "$MAX_BODY_BYTES" ]; then
        body+=$'\n'"$more"
        break
    fi
    body+=$'\n'"$l"
    i=$((i + 1))
done
title="Muse & Mingle: $n new"

click="$CLICK_FALLBACK"
if curl -s -I -o /dev/null -m 10 --fail "$CLICK_PRIMARY" 2>/dev/null; then
    click="$CLICK_PRIMARY"
fi

if [ "$DRY_RUN" = 1 ]; then
    printf 'Title: %s\nClick: %s\n\n%s\n' "$title" "$click" "$body"
    exit 0
fi

if notify_checked "$title" "$body" "$click"; then
    echo "$NOW" > "$WINDOW_FILE"
    log "ntfy delivered ($n item(s), $(bytes "$body") bytes); window advanced"
else
    fail "digest ntfy undelivered (curl exit $?)"
fi
