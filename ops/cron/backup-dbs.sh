#!/usr/bin/env bash
# Backup Annie, Reli (Supabase PostgreSQL → SQLite), FilmDuel, Kindred, Lachesis (pg_dump)
# - Local: /mnt/steam-slow/backups/ (7-day rotation)
# - Remote: Google Drive via rclone (if configured)

set -euo pipefail

# Secrets: ANNIE_DB_URL, RELI_DB_URL, FILMDUEL_DB_URL, KINDRED_DB_URL, LACHESIS_DB_URL
# loaded from an env file outside the repo. chmod 600 recommended.
# Override with $ARCHON_CRON_SECRETS.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${ANNIE_DB_URL:?ANNIE_DB_URL not set — populate $SECRETS_FILE}"
: "${RELI_DB_URL:?RELI_DB_URL not set — populate $SECRETS_FILE}"
: "${FILMDUEL_DB_URL:?FILMDUEL_DB_URL not set — populate $SECRETS_FILE}"
: "${KINDRED_DB_URL:?KINDRED_DB_URL not set — populate $SECRETS_FILE}"
: "${LACHESIS_DB_URL:?LACHESIS_DB_URL not set — populate $SECRETS_FILE}"

BACKUP_ROOT="/mnt/steam-slow/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
KEEP_DAYS=7
RCLONE_REMOTE="gdrive:backups/gas-town"
LOG_TAG="[db-backup]"

log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# --- Annie (Supabase PostgreSQL → SQLite export) ---
ANNIE_PROJECT_DIR="/mnt/ext-fast/gc/rigs/annie"
ANNIE_BACKUP_DIR="$BACKUP_ROOT/annie"
mkdir -p "$ANNIE_BACKUP_DIR"

ANNIE_OUT="$ANNIE_BACKUP_DIR/word-coach-annie-${TIMESTAMP}.db"
if cd "$ANNIE_PROJECT_DIR" && DATABASE_URL="$ANNIE_DB_URL" node scripts/export-to-sqlite.mjs "$ANNIE_OUT" 2>&1; then
    SIZE=$(du -h "$ANNIE_OUT" | cut -f1)
    PROJECTS=$(sqlite3 "$ANNIE_OUT" "SELECT count(*) FROM Project" 2>/dev/null || echo "?")
    log "Annie backed up: $ANNIE_OUT ($SIZE, $PROJECTS projects)"
    if [ "$PROJECTS" = "0" ]; then
        log "WARNING: Annie backup has 0 projects — possible data loss!"
    fi
else
    log "ERROR: Annie Supabase export failed"
fi

# --- Reli (Supabase PostgreSQL → SQLite export) ---
RELI_BACKUP_DIR="$BACKUP_ROOT/reli"
mkdir -p "$RELI_BACKUP_DIR"

RELI_OUT="$RELI_BACKUP_DIR/reli-${TIMESTAMP}.db"
if cd "$ANNIE_PROJECT_DIR" && DATABASE_URL="$RELI_DB_URL" node scripts/export-to-sqlite.mjs "$RELI_OUT" 2>&1; then
    SIZE=$(du -h "$RELI_OUT" | cut -f1)
    THINGS=$(sqlite3 "$RELI_OUT" "SELECT count(*) FROM things" 2>/dev/null || echo "?")
    log "Reli backed up: $RELI_OUT ($SIZE, $THINGS things)"
else
    log "ERROR: Reli Supabase export failed"
fi

# --- FilmDuel (Supabase PostgreSQL → pg_dump) ---
FILMDUEL_BACKUP_DIR="$BACKUP_ROOT/filmduel"
mkdir -p "$FILMDUEL_BACKUP_DIR"

FILMDUEL_OUT="$FILMDUEL_BACKUP_DIR/filmduel-${TIMESTAMP}.sql.gz"
# Note: --schema=filmduel and filmduel.users assume:
#   1. 014-filmduel-schema-isolation.sql has been run against the consolidated DB
#   2. FILMDUEL_DB_URL (in Railway) has been updated to the consolidated DB URL
if pg_dump "$FILMDUEL_DB_URL" --no-owner --no-acl --schema=filmduel 2>&1 | gzip > "$FILMDUEL_OUT"; then
    SIZE=$(du -h "$FILMDUEL_OUT" | cut -f1)
    USERS=$(psql "$FILMDUEL_DB_URL" -t -c "SELECT count(*) FROM filmduel.users" 2>/dev/null | tr -d ' ' || echo "?")
    log "FilmDuel backed up: $FILMDUEL_OUT ($SIZE, $USERS users)"
    if [ "$USERS" = "0" ]; then
        log "WARNING: FilmDuel backup has 0 users — possible data loss!"
    fi
else
    log "ERROR: FilmDuel pg_dump failed"
fi

# --- Kindred (Supabase PostgreSQL → pg_dump) ---
KINDRED_BACKUP_DIR="$BACKUP_ROOT/kindred"
mkdir -p "$KINDRED_BACKUP_DIR"

KINDRED_OUT="$KINDRED_BACKUP_DIR/kindred-${TIMESTAMP}.sql.gz"
if pg_dump "$KINDRED_DB_URL" --no-owner --no-acl 2>&1 | gzip > "$KINDRED_OUT"; then
    SIZE=$(du -h "$KINDRED_OUT" | cut -f1)
    ENTRIES=$(psql "$KINDRED_DB_URL" -t -c "SELECT count(*) FROM entries" 2>/dev/null | tr -d ' ' || echo "?")
    log "Kindred backed up: $KINDRED_OUT ($SIZE, $ENTRIES entries)"
    if [ "$ENTRIES" = "0" ]; then
        log "WARNING: Kindred backup has 0 entries — possible data loss!"
    fi
else
    log "ERROR: Kindred pg_dump failed"
fi

# --- Lachesis (Supabase PostgreSQL → pg_dump, schema-scoped) ---
LACHESIS_BACKUP_DIR="$BACKUP_ROOT/lachesis"
mkdir -p "$LACHESIS_BACKUP_DIR"

LACHESIS_OUT="$LACHESIS_BACKUP_DIR/lachesis-${TIMESTAMP}.sql.gz"
if pg_dump "$LACHESIS_DB_URL" --no-owner --no-acl --schema=lachesis 2>&1 | gzip > "$LACHESIS_OUT"; then
    SIZE=$(du -h "$LACHESIS_OUT" | cut -f1)
    log "Lachesis backed up: $LACHESIS_OUT ($SIZE)"
    # TODO: once lachesis schema is populated, add row count check like FilmDuel/Kindred:
    # ROWS=$(psql "$LACHESIS_DB_URL" -t -c "SELECT count(*) FROM lachesis.{primary_table}" 2>/dev/null | tr -d ' ' || echo "?")
    # log "Lachesis backup: $ROWS rows in {primary_table}"
    # if [ "$ROWS" = "0" ]; then log "WARNING: Lachesis backup has 0 rows — possible data loss!"; fi
else
    log "ERROR: Lachesis pg_dump failed"
fi

# --- Rotate old backups ---
find "$ANNIE_BACKUP_DIR" -name "*.db" -mtime +$KEEP_DAYS -delete 2>/dev/null && \
    log "Rotated Annie backups older than ${KEEP_DAYS} days" || true
find "$RELI_BACKUP_DIR" -name "*.db" -mtime +$KEEP_DAYS -delete 2>/dev/null && \
    log "Rotated Reli backups older than ${KEEP_DAYS} days" || true
find "$FILMDUEL_BACKUP_DIR" -name "*.sql.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null && \
    log "Rotated FilmDuel backups older than ${KEEP_DAYS} days" || true
find "$KINDRED_BACKUP_DIR" -name "*.sql.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null && \
    log "Rotated Kindred backups older than ${KEEP_DAYS} days" || true
find "$LACHESIS_BACKUP_DIR" -name "*.sql.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null && \
    log "Rotated Lachesis backups older than ${KEEP_DAYS} days" || true

# --- Google Drive sync (if rclone configured) ---
if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
    rclone copy "$ANNIE_BACKUP_DIR" "$RCLONE_REMOTE/annie" --max-age 2d -q
    rclone copy "$RELI_BACKUP_DIR" "$RCLONE_REMOTE/reli" --max-age 2d -q
    rclone copy "$FILMDUEL_BACKUP_DIR" "$RCLONE_REMOTE/filmduel" --max-age 2d -q
    rclone copy "$KINDRED_BACKUP_DIR" "$RCLONE_REMOTE/kindred" --max-age 2d -q
    rclone copy "$LACHESIS_BACKUP_DIR" "$RCLONE_REMOTE/lachesis" --max-age 2d -q
    log "Synced to Google Drive ($RCLONE_REMOTE)"
else
    log "SKIP: rclone/gdrive not configured, local backup only"
fi

log "Backup complete"
