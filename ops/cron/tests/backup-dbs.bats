#!/usr/bin/env bats
# End-to-end tests for ops/cron/backup-dbs.sh with stubbed pg_dump/psql/docker.
# Covers the #64 regressions: empty dump rejected and deleted, wrong/missing
# schema rejected before dumping, client older than server rejected.
#
# Run: bunx bats ops/cron/tests/backup-dbs.bats

setup() {
    export T="$BATS_TMPDIR/backup-dbs-$$"
    mkdir -p "$T/bin" "$T/backups" "$T/state"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$CRON_DIR/backup-dbs.sh"
    export PATH="$T/bin:$PATH"
    export BACKUP_ROOT="$T/backups"
    export DB_BACKUP_STATE_DIR="$T/state"
    export STUB_ARGV="$T/argv"
    export STUB_ENV="$T/env"
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    # Only reli configured; the others must be reported as skipped, not failed.
    echo 'RELI_DB_URL=postgresql://alice:p%40ss@db.example.com:5432/postgres' > "$T/secrets.env"
    export NTFY_TOPIC=""

    # docker: never usable → forces the local client path (stubbed below).
    printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/docker"
    # rclone: no gdrive remote → SKIP branch.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/rclone"
    # curl: record ntfy calls.
    printf '#!/usr/bin/env bash\ntouch "%s/ntfy-called"\n' "$T" > "$T/bin/curl"

    cat > "$T/bin/pg_dump" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "pg_dump (PostgreSQL) ${STUB_PG_DUMP_VERSION:-17.6}"; exit 0; fi
printf '%s ' "$@" >> "$STUB_ARGV"; echo >> "$STUB_ARGV"
env | grep '^PG' > "$STUB_ENV"
[ -n "${STUB_DUMP_FILE:-}" ] && cat "$STUB_DUMP_FILE"
exit "${STUB_DUMP_RC:-0}"
STUB

    cat > "$T/bin/psql" <<'STUB'
#!/usr/bin/env bash
q="$*"
case "$q" in
    *server_version*) echo "${STUB_SERVER_VERSION:-17.6}" ;;
    *information_schema.schemata*) printf '%s\n' "${STUB_SCHEMA_FOUND-1}" ;;
    *"count(*)"*)
        if [ "${STUB_ROWS:-224}" = "ERR" ]; then echo 'ERROR: relation "public.things" does not exist' >&2; exit 1; fi
        echo "${STUB_ROWS:-224}" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$T"/bin/*

    # A plausible dump: > 1 KB compressed, sanity table near the top, and
    # larger than the 64 KiB pipe buffer (a grep -q that closes the pipe early
    # used to SIGPIPE zcat and fail validation on every real-sized dump).
    { echo "-- PostgreSQL database dump"; echo "CREATE TABLE public.things ("; echo "    id integer"; echo ");";
      head -c 300000 /dev/urandom | base64; } > "$T/good.sql"
    export STUB_DUMP_FILE="$T/good.sql"
}

teardown() {
    rm -rf "$T"
}

archives() { find "$T/backups/reli" -name '*.sql.gz' 2>/dev/null; }

@test "verified backup: dumps --schema=public, keeps the archive, exits 0, records last_ok" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: reli backed up"* ]]
    [[ "$output" == *"224 rows in public.things"* ]]
    [[ "$output" == *"pg_dump via local"* ]]
    [[ "$output" == *"SKIP: annie"* ]]
    [ "$(archives | wc -l)" -eq 1 ]
    grep -q -- '--schema=public' "$STUB_ARGV"
    ! grep -q -- '--schema=reli' "$STUB_ARGV"
    grep -q '^last_run_status=ok$' "$T/state/db-backup-status"
    grep -q '^last_ok=[1-9]' "$T/state/db-backup-status"
    [ ! -f "$T/ntfy-called" ]
}

@test "credentials reach pg_dump through the environment, not argv, and are decoded" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^PGPASSWORD=p@ss$' "$STUB_ENV"
    grep -q '^PGUSER=alice$' "$STUB_ENV"
    grep -q '^PGHOST=db.example.com$' "$STUB_ENV"
    ! grep -q 'alice\|p@ss\|p%40ss\|postgresql://' "$STUB_ARGV"
    [[ "$output" != *"p@ss"* ]]
    [[ "$output" != *"postgresql://"* ]]
}

@test "empty dump (20-byte gzip) is a FAILED backup: artifact deleted, exit 1, ntfy" {
    export STUB_DUMP_FILE="/dev/null"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: reli backup FAILED"* ]]
    [[ "$output" == *"below the 1024B minimum"* ]]
    [[ "$output" == *"ERROR: backup FAILED for: reli"* ]]
    [ "$(archives | wc -l)" -eq 0 ]
    grep -q '^last_run_status=failed$' "$T/state/db-backup-status"
    grep -q '^last_run_failed=reli$' "$T/state/db-backup-status"
    grep -q '^last_ok=0$' "$T/state/db-backup-status"
}

@test "failed run preserves the previous last_ok in the status file" {
    printf 'last_run=1\nlast_run_status=ok\nlast_run_failed=\nlast_ok=1700000000\n' > "$T/state/db-backup-status"
    export STUB_DUMP_FILE="/dev/null"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -q '^last_ok=1700000000$' "$T/state/db-backup-status"
}

@test "pg_dump exiting non-zero is a FAILED backup even if it wrote output" {
    export STUB_DUMP_RC=1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pg_dump (local, v17 server) exited non-zero"* ]]
    [ "$(archives | wc -l)" -eq 0 ]
}

@test "dump missing the sanity table is rejected (wrong schema dumped)" {
    { echo "CREATE TABLE reli.other ("; echo ");"; head -c 300000 /dev/urandom | base64; } > "$T/wrong.sql"
    export STUB_DUMP_FILE="$T/wrong.sql"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not contain public.things"* ]]
    [ "$(archives | wc -l)" -eq 0 ]
}

@test "schema not present on the server fails before pg_dump runs" {
    export STUB_SCHEMA_FOUND=""
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"schema 'public' not found"* ]]
    [ ! -f "$STUB_ARGV" ]
    [ "$(archives | wc -l)" -eq 0 ]
}

@test "local pg_dump older than the server is rejected instead of writing an empty file" {
    export STUB_PG_DUMP_VERSION=16.15
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no usable pg_dump for a v17 server"* ]]
    [[ "$output" == *"local pg_dump is v16, server is v17"* ]]
    [ ! -f "$STUB_ARGV" ]
    [ "$(archives | wc -l)" -eq 0 ]
}

@test "failing row-count sanity query is a FAILED backup" {
    export STUB_ROWS=ERR
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"row-count query on public.things failed"* ]]
    [ "$(archives | wc -l)" -eq 0 ]
}

@test "zero rows is a warning, not a failure" {
    export STUB_ROWS=0
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: reli backup has 0 rows"* ]]
    [ "$(archives | wc -l)" -eq 1 ]
}

@test "failure sends an ntfy when NTFY_TOPIC is set" {
    export NTFY_TOPIC="t"
    export STUB_DUMP_FILE="/dev/null"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ -f "$T/ntfy-called" ]
}
