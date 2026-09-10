#!/usr/bin/env bash
# Backup Annie, Reli, FilmDuel, Kindred, Lachesis (pg_dump, schema-scoped)
# - Local: /mnt/steam-slow/backups/<project>/ (7-day rotation)
# - Remote: Google Drive via rclone (if configured)
#
# Every backup is verified before it counts: the dump client must be at least
# the server's major version, the schema must exist, the archive must be a
# non-trivial gzip containing the project's sanity table, and a row count of
# that table must succeed. Anything else is a FAILED backup: the artifact is
# deleted, the project is reported in the exit status / log / ntfy, and the
# status file read by pipeline-health-cron.sh records the failure.
#
# History: until 2026-09-10 (#64) this script dumped --schema=<project> while
# every project keeps its tables in `public`, and ran a v16 pg_dump against
# v17 servers. Both errors produced 20-byte empty gzips that were rotated and
# rclone'd as if they were backups.

set -euo pipefail

# Secrets: ANNIE_DB_URL, RELI_DB_URL, FILMDUEL_DB_URL, KINDRED_DB_URL, LACHESIS_DB_URL
# (+ optional NTFY_TOPIC) loaded from an env file outside the repo. chmod 600.
# Override with $ARCHON_CRON_SECRETS.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"

CRON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pg-backup.sh
. "$CRON_DIR/lib/pg-backup.sh"

BACKUP_ROOT="${BACKUP_ROOT:-/mnt/steam-slow/backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
KEEP_DAYS=7
RCLONE_REMOTE="gdrive:backups/gas-town"
LOG_TAG="[db-backup]"
# Shared with pipeline-health-cron.sh, which alerts when no successful run
# has landed recently (see check_db_backup there).
DB_BACKUP_STATE_DIR="${DB_BACKUP_STATE_DIR:-$HOME/.archon/pipeline-health-state}"
STATUS_FILE="$DB_BACKUP_STATE_DIR/db-backup-status"

# project | URL variable | schema | sanity table (quoted as SQL needs it)
# All five live on Supabase with their tables in `public`; the schema is
# still verified at runtime so a migration to a per-project schema fails
# loudly here instead of silently producing an empty dump.
PROJECTS=(
    'annie|ANNIE_DB_URL|public|"Project"'
    'reli|RELI_DB_URL|public|things'
    'filmduel|FILMDUEL_DB_URL|public|users'
    'kindred|KINDRED_DB_URL|public|entries'
    'lachesis|LACHESIS_DB_URL|public|lachesis_backlog'
)

log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $*"; }

notify() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-robot}"
    if [ -z "${NTFY_TOPIC:-}" ]; then
        log "WARNING: NTFY_TOPIC not set — cannot ntfy: $title"
        return 0
    fi
    curl -s -o /dev/null \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
        -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
}

rotate_backups() {
    local dir="$1" pattern="$2" name="$3"
    find "$dir" -name "$pattern" -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
    log "Rotated $name backups older than ${KEEP_DAYS} days"
}

# Strip anything that looks like a connection URL from tool output before it
# reaches the log (pg tools do not echo passwords, but never rely on that).
scrub() { sed -E 's#(postgres(ql)?://)[^[:space:]]*#\1***#g'; }

FAILED=()
OK=()
SKIPPED=()

# backup_project NAME URL_VAR SCHEMA TABLE → 0 on a verified backup, 1 on
# failure (artifact removed), 2 when skipped (URL not configured).
backup_project() {
    local name="$1" url_var="$2" schema="$3" table="$4"
    local dir="$BACKUP_ROOT/$name" out errfile rc reason
    local url="${!url_var:-}"
    local server_major mode found rows

    if [ -z "$url" ]; then
        log "SKIP: $name — $url_var not set (populate $SECRETS_FILE)"
        return 2
    fi

    mkdir -p "$dir"
    out="$dir/${name}-${TIMESTAMP}.sql.gz"
    errfile=$(mktemp)

    fail() {
        log "ERROR: $name backup FAILED — $1"
        rm -f "$out" "$errfile"
        pg_clear_env
        return 1
    }

    if ! pg_url_to_env "$url" 2>"$errfile"; then
        fail "$url_var is not a parseable postgresql:// URL ($(scrub < "$errfile"))"; return 1
    fi

    if ! server_major=$(pg_server_major) || [ -z "$server_major" ]; then
        fail "cannot reach the server or read its version"; return 1
    fi
    if ! mode=$(pg_select_client_mode "$server_major" 2>"$errfile"); then
        fail "no usable pg_dump for a v$server_major server: $(scrub < "$errfile" | tr '\n' ' ')"; return 1
    fi
    export PG_CLIENT_MODE="$mode"

    found=$(pg_run psql -X -Atq -c \
        "SELECT 1 FROM information_schema.schemata WHERE schema_name = '$schema'" 2>"$errfile") || found=""
    if [ "$found" != "1" ]; then
        fail "schema '$schema' not found on the server ($(scrub < "$errfile" | head -1))"; return 1
    fi

    if ! pg_run pg_dump --no-owner --no-acl --schema="$schema" 2>"$errfile" | gzip > "$out"; then
        fail "pg_dump ($mode, v$server_major server) exited non-zero: $(scrub < "$errfile" | head -2 | tr '\n' ' ')"; return 1
    fi
    if [ -s "$errfile" ]; then
        log "WARNING: $name pg_dump stderr: $(scrub < "$errfile" | head -3 | tr '\n' ' ')"
    fi

    if ! reason=$(pg_validate_archive "$out"); then
        fail "$reason"; return 1
    fi
    if [ "$(pg_archive_count_tables "$out" "${schema}.${table}")" -lt 1 ]; then
        fail "archive does not contain ${schema}.${table} — wrong schema or truncated dump"; return 1
    fi

    rows=$(pg_run psql -X -Atq -c "SELECT count(*) FROM ${schema}.${table}" 2>"$errfile") || rows=""
    if ! [[ "$rows" =~ ^[0-9]+$ ]]; then
        fail "row-count query on ${schema}.${table} failed ($(scrub < "$errfile" | head -1))"; return 1
    fi

    log "OK: $name backed up: $out ($(du -h "$out" | cut -f1), $rows rows in ${schema}.${table}, pg_dump via $mode, server v$server_major)"
    if [ "$rows" = "0" ]; then
        log "WARNING: $name backup has 0 rows in ${schema}.${table} — possible data loss!"
    fi
    rm -f "$errfile"
    pg_clear_env
    return 0
}

for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r name url_var schema table <<< "$entry"
    rc=0
    backup_project "$name" "$url_var" "$schema" "$table" || rc=$?
    case "$rc" in
        0) OK+=("$name") ;;
        2) SKIPPED+=("$name") ;;
        *) FAILED+=("$name") ;;
    esac
done

# --- Rotate old backups ---
for entry in "${PROJECTS[@]}"; do
    name="${entry%%|*}"
    [ -d "$BACKUP_ROOT/$name" ] && rotate_backups "$BACKUP_ROOT/$name" "*.sql.gz" "$name"
done

# --- Google Drive sync (if rclone configured) ---
if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
    for entry in "${PROJECTS[@]}"; do
        name="${entry%%|*}"
        [ -d "$BACKUP_ROOT/$name" ] && rclone copy "$BACKUP_ROOT/$name" "$RCLONE_REMOTE/$name" --max-age 2d -q
    done
    log "Synced to Google Drive ($RCLONE_REMOTE)"
else
    log "SKIP: rclone/gdrive not configured, local backup only"
fi

# --- Status for pipeline-health-cron.sh + exit code ---
mkdir -p "$DB_BACKUP_STATE_DIR"
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
    log "ERROR: backup FAILED for: $failed_csv (ok: ${OK[*]-none}; skipped: ${SKIPPED[*]-none})"
    notify "DB backup FAILED: $failed_csv" \
        "backup-dbs.sh could not produce a verified backup for $failed_csv. See /tmp/db-backup.log on $(hostname)." \
        high floppy_disk
    exit 1
fi
log "Backup complete (ok: ${OK[*]-none}; skipped: ${SKIPPED[*]-none})"
