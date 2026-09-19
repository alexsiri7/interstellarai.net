#!/usr/bin/env bash
# restore-test.sh — weekly proof that the DB backups are restorable, not just
# non-empty. Runs Sunday 04:30 from cron (73 minutes after the 03:17 backup).
#
# For every project in PG_BACKUP_PROJECTS (lib/pg-backup.sh) it takes the
# newest archive under $BACKUP_ROOT/<project>/, refuses one older than
# RESTORE_TEST_MAX_ARCHIVE_AGE_H (6: two 3-hourly backups missed), and
# restores it into a throwaway PostgreSQL cluster (initdb + pg_ctl from the
# user-level PostgreSQL 17 in ~/.local/opt/postgresql-17, unix socket only,
# random port, temp dir removed on exit). The restore runs under
# `psql -v ON_ERROR_STOP=1`, so any statement the archive cannot replay is a
# failure. It then checks that the project's schema and sanity table exist
# and that the table holds exactly the row count backup-dbs.sh recorded for
# that archive (the `<archive>.meta` sidecar, or the OK: line in the
# db-backup log for archives made before the sidecar existed).
#
# Nothing here connects to the real databases: secrets.env is read only for
# NTFY_TOPIC and to know which projects are configured (unset URL → skipped,
# exactly as backup-dbs.sh skips them).
#
# The archives are `pg_dump --schema=public` from Supabase, so they reference
# two things a bare cluster lacks and which are not part of the backup:
#   - the Supabase `auth` schema (auth.uid() in RLS policies, auth.users as a
#     foreign-key target) and the `extensions` schema — a stub of each is
#     created before the restore (see supabase_shim);
#   - pgvector (`extensions.vector`, hnsw indexes) — the real extension, built
#     into ~/.local/opt/postgresql-17 (see ops/cron/README.md), is created
#     only when the archive uses it.
# Foreign keys pointing into those stub schemas are added NOT VALID, since
# the referenced rows (Supabase auth users) are not in the archive. Every
# such rewrite is counted and logged. Nothing else in the archive is changed.
#
# Output: log lines per project (OK: / ERROR:), a status file for
# pipeline-health-cron.sh (check_restore_test) in the style of
# db-backup-status, exit 1 + ntfy on any failure.

set -euo pipefail

# cron's PATH is /usr/bin:/bin. The server binaries live only in the
# PostgreSQL 17 tree (only pg_dump/pg_restore are symlinked into ~/.local/bin).
PG_BIN="${PG_BIN:-$HOME/.local/opt/postgresql-17/bin}"
export PATH="$PG_BIN:$HOME/.local/bin:/usr/local/bin:$PATH"

# Secrets: only NTFY_TOPIC and the presence of <PROJECT>_DB_URL are used.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"

CRON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pg-backup.sh
. "$CRON_DIR/lib/pg-backup.sh"
# Never let a stray libpq variable point the throwaway psql anywhere else.
pg_clear_env

BACKUP_ROOT="${BACKUP_ROOT:-/mnt/steam-slow/backups}"
LOG_DIR="${ARCHON_CRON_LOG_DIR:-$HOME/.local/state/archon-cron/logs}"
DB_BACKUP_LOG="${DB_BACKUP_LOG:-$LOG_DIR/db-backup.log}"
MAX_ARCHIVE_AGE_H="${RESTORE_TEST_MAX_ARCHIVE_AGE_H:-6}"
# Unix socket paths are capped at 107 bytes, so the cluster lives directly
# under a short root, never under a deep mktemp default.
TMP_ROOT="${RESTORE_TEST_TMP_ROOT:-/tmp}"
LOG_TAG="[restore-test]"
# Shared with pipeline-health-cron.sh (check_restore_test).
DB_BACKUP_STATE_DIR="${DB_BACKUP_STATE_DIR:-$HOME/.archon/pipeline-health-state}"
STATUS_FILE="$DB_BACKUP_STATE_DIR/restore-test-status"
PROJECTS=("${PG_BACKUP_PROJECTS[@]}")

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

# ---------------------------------------------------------------------------
# Throwaway cluster
# ---------------------------------------------------------------------------
CLUSTER_DIR=""
CLUSTER_PORT=""

cleanup() {
    local rc=$?
    if [ -n "$CLUSTER_DIR" ]; then
        if [ -f "$CLUSTER_DIR/data/postmaster.pid" ]; then
            pg_ctl -D "$CLUSTER_DIR/data" -m immediate -s stop >/dev/null 2>&1 || true
        fi
        rm -rf "$CLUSTER_DIR"
    fi
    exit "$rc"
}
trap cleanup EXIT

# psql against the throwaway cluster. Every option is explicit so no PG*
# variable from the environment can redirect it.
q() { psql -X -q -v ON_ERROR_STOP=1 -h "$CLUSTER_DIR" -p "$CLUSTER_PORT" -U postgres "$@"; }

# start_cluster → 0 with CLUSTER_DIR/CLUSTER_PORT set, 1 with the reason logged.
start_cluster() {
    local b
    for b in initdb pg_ctl psql; do
        if [ ! -x "$PG_BIN/$b" ]; then
            log "ERROR: $PG_BIN/$b missing — install the PostgreSQL 17 server tree (see ops/cron/README.md)"
            return 1
        fi
    done
    CLUSTER_DIR=$(mktemp -d "$TMP_ROOT/restore-test.XXXXXX")
    if [ "${#CLUSTER_DIR}" -gt 90 ]; then
        log "ERROR: $CLUSTER_DIR is too long for a unix socket path — set RESTORE_TEST_TMP_ROOT to a short directory"
        return 1
    fi
    CLUSTER_PORT=$(( 20000 + RANDOM % 40000 ))
    if ! initdb -D "$CLUSTER_DIR/data" -A trust -U postgres -E UTF8 --locale=C --no-sync \
            > "$CLUSTER_DIR/initdb.log" 2>&1; then
        log "ERROR: initdb failed: $(tail -3 "$CLUSTER_DIR/initdb.log" | tr '\n' ' ')"
        return 1
    fi
    # Socket only (listen_addresses=''), durability off: the cluster is
    # thrown away the moment this script exits.
    if ! pg_ctl -D "$CLUSTER_DIR/data" -w -s -l "$CLUSTER_DIR/postgres.log" \
            -o "-k $CLUSTER_DIR -c listen_addresses='' -p $CLUSTER_PORT -c fsync=off -c synchronous_commit=off -c full_page_writes=off" \
            start > "$CLUSTER_DIR/pg_ctl.log" 2>&1; then
        log "ERROR: pg_ctl start failed: $(tail -3 "$CLUSTER_DIR/postgres.log" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
    log "Throwaway cluster up: $CLUSTER_DIR (port $CLUSTER_PORT, $(postgres --version 2>/dev/null || echo 'postgres ?'))"
    return 0
}

# ---------------------------------------------------------------------------
# Per-archive helpers
# ---------------------------------------------------------------------------

# newest_archive DIR NAME → prints the path of the newest NAME-*.sql.gz by
# mtime, nothing when there is none.
newest_archive() {
    find "$1" -maxdepth 1 -name "$2-*.sql.gz" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-
}

# expected_rows ARCHIVE NAME SCHEMA.TABLE → prints the row count recorded for
# ARCHIVE. Prefers the `.meta` sidecar backup-dbs.sh writes; falls back to
# the `OK: <name> backed up: <archive> (..., <n> rows in <table>, ...)` log
# line for archives from before the sidecar. Fails with the reason on stdout.
expected_rows() {
    local archive="$1" name="$2" table="$3" rows="" seen="" line
    local meta="$archive.meta"
    if [ -f "$meta" ]; then
        rows=$(grep -s '^rows=' "$meta" | cut -d= -f2-)
        seen=$(grep -s '^table=' "$meta" | cut -d= -f2-)
        if ! [[ "$rows" =~ ^[0-9]+$ ]]; then echo "$meta has no rows=<n> line"; return 1; fi
        if [ "$seen" != "$table" ]; then echo "$meta records table $seen, expected $table"; return 1; fi
        printf '%s' "$rows"; return 0
    fi
    line=$(grep -s -F "OK: $name backed up: $archive (" "$DB_BACKUP_LOG" | tail -1 || true)
    if [ -z "$line" ]; then
        echo "no recorded row count: $meta missing and no OK line for the archive in $DB_BACKUP_LOG"; return 1
    fi
    rows=$(sed -E 's/.* ([0-9]+) rows in ([^,]+),.*/\1/' <<< "$line")
    seen=$(sed -E 's/.* ([0-9]+) rows in ([^,]+),.*/\2/' <<< "$line")
    if ! [[ "$rows" =~ ^[0-9]+$ ]] || [ "$seen" != "$table" ]; then
        echo "cannot parse the row count for $table from $DB_BACKUP_LOG: ${line#*OK: }"; return 1
    fi
    printf '%s' "$rows"; return 0
}

# supabase_shim ARCHIVE → the SQL that precedes the archive: drop the public
# schema (the dump recreates it — template0 already has one), stub the
# Supabase-managed schemas the dump refers to, and create pgvector when the
# archive uses it.
supabase_shim() {
    cat <<'SQL'
DROP SCHEMA public CASCADE;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULL::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT NULL::text $$;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT NULL::jsonb $$;
CREATE SCHEMA extensions;
SQL
    if archive_uses_vector "$1"; then
        echo 'CREATE EXTENSION vector SCHEMA extensions;'
    fi
}

archive_uses_vector() {
    local n
    n=$(zcat "$1" | grep -c 'extensions\.vector' || true)
    [ "${n:-0}" -gt 0 ]
}

# Foreign keys whose target lives in a stub schema are added NOT VALID: the
# rows they point at (Supabase auth users) are not part of the backup. The
# regex is pinned to pg_dump's own layout for FK constraints.
FK_STUB_RE='^(    ADD CONSTRAINT [^ ]+ FOREIGN KEY \([^)]*\) REFERENCES (auth|extensions)\.[^;]*);$'

FAILED=()
OK=()
SKIPPED=()
STATUS_LINES=()

# restore_project NAME URL_VAR SCHEMA TABLE → 0 restored and verified,
# 1 failed (reason logged), 2 skipped (project not configured).
restore_project() {
    local name="$1" url_var="$2" schema="$3" table="$4"
    local dir="$BACKUP_ROOT/$name" archive age reason rows db errfile fkfile
    local t0 ms found ntables fks got

    if [ -z "${!url_var:-}" ]; then
        log "SKIP: $name — $url_var not set (populate $SECRETS_FILE)"
        STATUS_LINES+=("$name=skipped")
        return 2
    fi

    fail() {
        log "ERROR: $name restore FAILED — $1"
        STATUS_LINES+=("$name=failed ${archive:-no-archive} $1")
        rm -f "$errfile" "$fkfile"
        return 1
    }
    errfile=$(mktemp "$CLUSTER_DIR/$name.err.XXXXXX")
    fkfile=$(mktemp "$CLUSTER_DIR/$name.fk.XXXXXX")

    archive=$(newest_archive "$dir" "$name")
    if [ -z "$archive" ]; then
        fail "no $name-*.sql.gz under $dir"; return 1
    fi
    age=$(( $(date +%s) - $(stat -c %Y "$archive") ))
    if [ "$age" -gt $(( MAX_ARCHIVE_AGE_H * 3600 )) ]; then
        fail "newest archive $archive is $(( age / 3600 ))h old (limit ${MAX_ARCHIVE_AGE_H}h) — is backup-dbs.sh running?"; return 1
    fi
    if ! reason=$(pg_validate_archive "$archive"); then
        fail "$archive: $reason"; return 1
    fi
    if ! rows=$(expected_rows "$archive" "$name" "${schema}.${table}"); then
        fail "$rows"; return 1
    fi
    if archive_uses_vector "$archive" && [ ! -f "$PG_BIN/../share/extension/vector.control" ]; then
        fail "$archive uses extensions.vector but pgvector is not installed in $PG_BIN/.. (see ops/cron/README.md)"; return 1
    fi

    db="restore_$name"
    t0=$(date +%s%N)
    if ! q -c "CREATE DATABASE $db TEMPLATE template0" 2>"$errfile"; then
        fail "cannot create database $db: $(head -1 "$errfile")"; return 1
    fi
    if ! { supabase_shim "$archive"; zcat "$archive" | sed -E "s/$FK_STUB_RE/\1 NOT VALID;/w $fkfile"; } \
            | q -d "$db" > /dev/null 2>"$errfile"; then
        fail "psql -v ON_ERROR_STOP=1 aborted: $(grep -m2 'ERROR' "$errfile" | tr '\n' ' ')"; return 1
    fi
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    fks=$(grep -c '' "$fkfile" || true)
    [ "${fks:-0}" -gt 0 ] && fks=", $fks foreign keys into auth/extensions added NOT VALID" || fks=""

    found=$(q -Atd "$db" -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = '$schema'" 2>"$errfile") || found=""
    if [ "$found" != "1" ]; then
        fail "schema '$schema' missing after restore ($(head -1 "$errfile"))"; return 1
    fi
    found=$(q -Atd "$db" -c "SELECT to_regclass('${schema}.${table}') IS NOT NULL" 2>"$errfile") || found=""
    if [ "$found" != "t" ]; then
        fail "table ${schema}.${table} missing after restore ($(head -1 "$errfile"))"; return 1
    fi
    got=$(q -Atd "$db" -c "SELECT count(*) FROM ${schema}.${table}" 2>"$errfile") || got=""
    if ! [[ "$got" =~ ^[0-9]+$ ]]; then
        fail "row count on ${schema}.${table} failed after restore ($(head -1 "$errfile"))"; return 1
    fi
    if [ "$got" != "$rows" ]; then
        fail "${schema}.${table} has $got rows after restore, backup recorded $rows"; return 1
    fi
    ntables=$(q -Atd "$db" -c "SELECT count(*) FROM pg_tables WHERE schemaname = '$schema'" 2>/dev/null || echo '?')

    log "OK: $name restored: $archive ($got rows in ${schema}.${table} = backup count, $ntables tables in $schema, ${ms}ms$fks)"
    STATUS_LINES+=("$name=ok $archive rows=$got tables=$ntables ms=$ms")
    rm -f "$errfile" "$fkfile"
    return 0
}

# ---------------------------------------------------------------------------
log "=== restore test ==="
if start_cluster; then
    for entry in "${PROJECTS[@]}"; do
        IFS='|' read -r name url_var schema table <<< "$entry"
        rc=0
        restore_project "$name" "$url_var" "$schema" "$table" || rc=$?
        case "$rc" in
            0) OK+=("$name") ;;
            2) SKIPPED+=("$name") ;;
            *) FAILED+=("$name") ;;
        esac
    done
else
    for entry in "${PROJECTS[@]}"; do
        name="${entry%%|*}"
        FAILED+=("$name")
        STATUS_LINES+=("$name=failed cluster-not-started")
    done
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
    printf '%s\n' "${STATUS_LINES[@]}"
} > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"

if [ ${#FAILED[@]} -gt 0 ]; then
    log "ERROR: restore test FAILED for: $failed_csv (ok: ${OK[*]-none}; skipped: ${SKIPPED[*]-none})"
    notify "DB restore test FAILED: $failed_csv" \
        "restore-test.sh could not restore and verify the newest backup of $failed_csv. See $LOG_DIR/restore-test.log on $(hostname)." \
        high floppy_disk
    exit 1
fi
log "Restore test complete (ok: ${OK[*]-none}; skipped: ${SKIPPED[*]-none})"
