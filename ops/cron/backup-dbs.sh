#!/usr/bin/env bash
# Backup Annie, Reli, FilmDuel, Kindred, Lachesis (pg_dump)
# - Local: /mnt/steam-slow/backups/ (7-day rotation)
# - Remote: Google Drive via rclone (if configured)

set -euo pipefail

# Secrets: ANNIE_DB_URL, RELI_DB_URL, FILMDUEL_DB_URL, KINDRED_DB_URL, LACHESIS_DB_URL
# loaded from an env file outside the repo. chmod 600 recommended.
# Override with $ARCHON_CRON_SECRETS.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
# We load DB URLs from secrets.env and make them all optional.
# If a URL is missing, we'll log a skip message and gracefully proceed.

BACKUP_ROOT="/mnt/steam-slow/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
KEEP_DAYS=7
RCLONE_REMOTE="gdrive:backups/gas-town"
LOG_TAG="[db-backup]"

log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $*"; }
rotate_backups() {
    local dir="$1" pattern="$2" name="$3"
    find "$dir" -name "$pattern" -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
    log "Rotated $name backups older than ${KEEP_DAYS} days"
}

# --- Annie (Supabase PostgreSQL → pg_dump, schema-scoped) ---
if [ -n "${ANNIE_DB_URL:-}" ]; then
    ANNIE_PROJECT_DIR="/mnt/ext-fast/gc/rigs/annie"
    ANNIE_BACKUP_DIR="$BACKUP_ROOT/annie"
    mkdir -p "$ANNIE_BACKUP_DIR"

    ANNIE_OUT="$ANNIE_BACKUP_DIR/annie-${TIMESTAMP}.sql.gz"
    # Note: --schema=annie and annie."Project" assume:
    #   1. 017-annie-schema-isolation.sql has been run against the consolidated DB
    #   2. ANNIE_DB_URL (in secrets.env) has been updated to the consolidated DB URL
    if docker run --rm postgres:17-alpine pg_dump "$ANNIE_DB_URL" --no-owner --no-acl --schema=public | gzip > "$ANNIE_OUT"; then
        SIZE=$(du -h "$ANNIE_OUT" | cut -f1)
        PROJECTS=$(psql "$ANNIE_DB_URL" -t -c "SELECT count(*) FROM public.\"Project\"" 2>/dev/null | tr -d ' ' || echo "?")
        log "Annie backed up: $ANNIE_OUT ($SIZE, $PROJECTS projects)"
        if [ "$PROJECTS" = "0" ]; then
            log "WARNING: Annie backup has 0 projects — possible data loss!"
        fi
    else
        log "ERROR: Annie pg_dump failed"
    fi
    rotate_backups "$ANNIE_BACKUP_DIR" "*.sql.gz" "Annie"
    if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
        rclone copy "$ANNIE_BACKUP_DIR" "$RCLONE_REMOTE/annie" --max-age 2d -q
        log "Annie backup synced to Google Drive"
    fi
else
    log "SKIP: Annie backup (ANNIE_DB_URL not set)"
fi

# --- Reli (Supabase PostgreSQL → pg_dump, schema-scoped) ---
if [ -n "${RELI_DB_URL:-}" ]; then
    RELI_BACKUP_DIR="$BACKUP_ROOT/reli"
    mkdir -p "$RELI_BACKUP_DIR"

    RELI_OUT="$RELI_BACKUP_DIR/reli-${TIMESTAMP}.sql.gz"
    if docker run --rm postgres:17-alpine pg_dump "$RELI_DB_URL" --no-owner --no-acl --schema=public | gzip > "$RELI_OUT"; then
        SIZE=$(du -h "$RELI_OUT" | cut -f1)
        THINGS=$(psql "$RELI_DB_URL" -t -c "SELECT count(*) FROM public.things" 2>/dev/null | tr -d ' ' || echo "?")
        log "Reli backed up: $RELI_OUT ($SIZE, $THINGS things)"
        if [ "$THINGS" = "0" ] || [ "$THINGS" = "?" ]; then
            log "WARNING: Reli backup has 0 or unknown things — possible data loss or schema not yet migrated!"
        fi
    else
        log "ERROR: Reli pg_dump failed"
    fi
    rotate_backups "$RELI_BACKUP_DIR" "*.sql.gz" "Reli"
    if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
        rclone copy "$RELI_BACKUP_DIR" "$RCLONE_REMOTE/reli" --max-age 2d -q
        log "Reli backup synced to Google Drive"
    fi
else
    log "SKIP: Reli backup (RELI_DB_URL not set)"
fi

# --- FilmDuel (Supabase PostgreSQL → pg_dump) ---
if [ -n "${FILMDUEL_DB_URL:-}" ]; then
    FILMDUEL_BACKUP_DIR="$BACKUP_ROOT/filmduel"
    mkdir -p "$FILMDUEL_BACKUP_DIR"

    FILMDUEL_OUT="$FILMDUEL_BACKUP_DIR/filmduel-${TIMESTAMP}.sql.gz"
    # Note: --schema=filmduel and filmduel.users assume:
    #   1. 014-filmduel-schema-isolation.sql has been run against the consolidated DB
    #   2. FILMDUEL_DB_URL (in Railway) has been updated to the consolidated DB URL
    if docker run --rm postgres:17-alpine pg_dump "$FILMDUEL_DB_URL" --no-owner --no-acl --schema=public | gzip > "$FILMDUEL_OUT"; then
        SIZE=$(du -h "$FILMDUEL_OUT" | cut -f1)
        USERS=$(psql "$FILMDUEL_DB_URL" -t -c "SELECT count(*) FROM public.users" 2>/dev/null | tr -d ' ' || echo "?")
        log "FilmDuel backed up: $FILMDUEL_OUT ($SIZE, $USERS users)"
        if [ "$USERS" = "0" ]; then
            log "WARNING: FilmDuel backup has 0 users — possible data loss!"
        fi
    else
        log "ERROR: FilmDuel pg_dump failed"
    fi
    rotate_backups "$FILMDUEL_BACKUP_DIR" "*.sql.gz" "FilmDuel"
    if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
        rclone copy "$FILMDUEL_BACKUP_DIR" "$RCLONE_REMOTE/filmduel" --max-age 2d -q
        log "FilmDuel backup synced to Google Drive"
    fi
else
    log "SKIP: FilmDuel backup (FILMEL_DB_URL not set)"
fi

# --- Kindred (Supabase PostgreSQL → pg_dump) ---
if [ -n "${KINDRED_DB_URL:-}" ]; then
    KINDRED_BACKUP_DIR="$BACKUP_ROOT/kindred"
    mkdir -p "$KINDRED_BACKUP_DIR"

    KINDRED_OUT="$KINDRED_BACKUP_DIR/kindred-${TIMESTAMP}.sql.gz"
    if docker run --rm postgres:17-alpine pg_dump "$KINDRED_DB_URL" --no-owner --no-acl --schema=public | gzip > "$KINDRED_OUT"; then
        SIZE=$(du -h "$KINDRED_OUT" | cut -f1)
        ENTRIES=$(psql "$KINDRED_DB_URL" -t -c "SELECT count(*) FROM public.entries" 2>/dev/null | tr -d ' ' || echo "?")
        log "Kindred backed up: $KINDRED_OUT ($SIZE, $ENTRIES entries)"
        if [ "$ENTRIES" = "0" ] || [ "$ENTRIES" = "?" ]; then
            log "WARNING: Kindred backup has 0 or unknown entries — possible data loss or schema not yet migrated!"
        fi
    else
        log "ERROR: Kindred pg_dump failed"
    fi
    rotate_backups "$KINDRED_BACKUP_DIR" "*.sql.gz" "Kindred"
    if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
        rclone copy "$KINDRED_BACKUP_DIR" "$RCLONE_REMOTE/kindred" --max-age 2d -q
        log "Kindred backup synced to Google Drive"
    fi
else
    log "SKIP: Kindred backup (KINDRED_DB_URL not set)"
fi

# --- Lachesis (Supabase PostgreSQL → pg_dump, schema-scoped) ---
if [ -n "${LACHESIS_DB_URL:-}" ]; then
    LACHESIS_BACKUP_DIR="$BACKUP_ROOT/lachesis"
    mkdir -p "$LACHESIS_BACKUP_DIR"

    LACHESIS_OUT="$LACHESIS_BACKUP_DIR/lachesis-${TIMESTAMP}.sql.gz"
    if docker run --rm postgres:17-alpine pg_dump "$LACHESIS_DB_URL" --no-owner --no-acl --schema=public | gzip > "$LACHESIS_OUT"; then
        SIZE=$(du -h "$LACHESIS_OUT" | cut -f1)
        USERS=$(psql "$LACHESIS_DB_URL" -t -c "SELECT count(*) FROM public.lachesis_users" 2>/dev/null | tr -d ' ' || echo "?")
        log "Lachesis backed up: $LACHESIS_OUT ($SIZE, $USERS users)"
        if [ "$USERS" = "0" ]; then
            log "WARNING: Lachesis backup has 0 users — possible data loss!"
        fi
    else
        log "ERROR: Lachesis pg_dump failed"
    fi
    rotate_backups "$LACHESIS_BACKUP_DIR" "*.sql.gz" "Lachesis"
    if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
        rclone copy "$LACHESIS_BACKUP_DIR" "$RCLONE_REMOTE/lachesis" --max-age 2d -q
        log "Lachesis backup synced to Google Drive"
    fi
else
    log "SKIP: Lachesis backup (LACHESIS_DB_URL not set)"
fi

log "Backup complete"
