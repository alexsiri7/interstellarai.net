#!/usr/bin/env bats
# Unit tests for ops/cron/lib/pg-backup.sh (URL → libpq env, client/server
# version selection, archive validation).
#
# Run: bunx bats ops/cron/tests/pg-backup.bats

setup() {
    export T="$BATS_TMPDIR/pg-backup-$$"
    mkdir -p "$T/bin"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PATH="$T/bin:$PATH"
    export STUB_ARGV="$T/argv"
    # shellcheck disable=SC1091
    source "$CRON_DIR/lib/pg-backup.sh"
    pg_clear_env
}

teardown() {
    rm -rf "$T"
}

# docker stub: `image inspect` honours $STUB_DOCKER_IMAGE_RC, `run ... pg_dump
# --version` prints $STUB_DOCKER_PG_VERSION, everything is recorded in argv.
stub_docker() {
    cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$STUB_ARGV"; echo >> "$STUB_ARGV"
case "$1 $2" in
    "image inspect") exit "${STUB_DOCKER_IMAGE_RC:-0}" ;;
    "run "*)
        for a in "$@"; do
            [ "$a" = "--version" ] && { echo "pg_dump (PostgreSQL) ${STUB_DOCKER_PG_VERSION:-17.6}"; exit 0; }
        done
        echo "env PGPASSWORD=${PGPASSWORD:-unset}"; exit 0 ;;
esac
exit 1
STUB
    chmod +x "$T/bin/docker"
}

stub_local_pg_dump() {
    cat > "$T/bin/pg_dump" <<STUB
#!/usr/bin/env bash
echo "pg_dump (PostgreSQL) $1"
STUB
    chmod +x "$T/bin/pg_dump"
}

# ── pg_url_to_env ────────────────────────────────────────────────────────────

@test "pg_url_to_env exports host/port/user/password/database" {
    pg_url_to_env "postgresql://alice:s3cret@db.example.com:6543/postgres"
    [ "$PGHOST" = "db.example.com" ]
    [ "$PGPORT" = "6543" ]
    [ "$PGUSER" = "alice" ]
    [ "$PGPASSWORD" = "s3cret" ]
    [ "$PGDATABASE" = "postgres" ]
}

@test "pg_url_to_env percent-decodes user, password and database" {
    pg_url_to_env "postgres://postgres.proj%2Dref:p%40ss%25w%3Ard@h/my%20db"
    [ "$PGUSER" = "postgres.proj-ref" ]
    [ "$PGPASSWORD" = 'p@ss%w:rd' ]
    [ "$PGDATABASE" = "my db" ]
    [ -z "${PGPORT:-}" ]
}

@test "pg_url_to_env keeps backslashes in passwords literal" {
    pg_url_to_env 'postgresql://u:a\nb@h/d'
    [ "$PGPASSWORD" = 'a\nb' ]
}

@test "pg_url_to_env maps sslmode and options query parameters" {
    pg_url_to_env "postgresql://u:p@h:5432/d?sslmode=require&options=-c%20search_path%3Dpublic"
    [ "$PGSSLMODE" = "require" ]
    [ "$PGOPTIONS" = "-c search_path=public" ]
    [ "$PGDATABASE" = "d" ]
}

@test "pg_url_to_env rejects non-postgres URLs and URLs without a host" {
    run pg_url_to_env "mysql://u:p@h/d"
    [ "$status" -eq 1 ]
    run pg_url_to_env "postgresql:///d"
    [ "$status" -eq 1 ]
}

@test "pg_url_to_env never prints the URL or password" {
    run pg_url_to_env "postgresql://u:hunter2@h/d?bogus=1"
    [ "$status" -eq 0 ]
    [[ "$output" != *hunter2* ]]
    [[ "$output" == *"ignoring unsupported URL parameter 'bogus'"* ]]
}

# ── version parsing / client selection ───────────────────────────────────────

@test "pg_major_of parses pg_dump --version and SHOW server_version output" {
    [ "$(pg_major_of 'pg_dump (PostgreSQL) 17.6')" = "17" ]
    [ "$(pg_major_of '16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)')" = "16" ]
    [ "$(pg_major_of '17.6')" = "17" ]
    run pg_major_of "garbage"
    [ "$status" -eq 1 ]
}

@test "pg_select_client_mode prefers the pinned docker image when it is new enough" {
    stub_docker; stub_local_pg_dump 16.15
    export STUB_DOCKER_PG_VERSION=17.6
    [ "$(pg_select_client_mode 17)" = "docker" ]
}

@test "pg_select_client_mode falls back to local pg_dump only when its major >= server" {
    stub_docker; export STUB_DOCKER_IMAGE_RC=1
    stub_local_pg_dump 17.2
    [ "$(pg_select_client_mode 16)" = "local" ]
    [ "$(pg_select_client_mode 17)" = "local" ]
}

@test "pg_select_client_mode fails loudly when every client is older than the server" {
    stub_docker; export STUB_DOCKER_IMAGE_RC=1
    stub_local_pg_dump 16.15
    run pg_select_client_mode 17
    [ "$status" -eq 1 ]
    [[ "$output" == *"local pg_dump is v16, server is v17"* ]]
}

@test "pg_select_client_mode fails when the docker image is too old and no local pg_dump fits" {
    stub_docker; export STUB_DOCKER_PG_VERSION=17.6
    stub_local_pg_dump 16.15
    run pg_select_client_mode 18
    [ "$status" -eq 1 ]
    [[ "$output" == *"pg_dump is v17, server is v18"* ]]
    [[ "$output" == *"bump PG_BACKUP_IMAGE"* ]]
}

@test "pg_run docker passes credentials by environment name, never on the command line" {
    stub_docker
    pg_url_to_env "postgresql://alice:hunter2@db.example.com:5432/postgres"
    export PG_CLIENT_MODE=docker
    run pg_run pg_dump --schema=public
    [ "$status" -eq 0 ]
    [[ "$output" == *"env PGPASSWORD=hunter2"* ]]      # reached the container env
    grep -q -- '-e PGPASSWORD ' "$STUB_ARGV"
    ! grep -q 'hunter2' "$STUB_ARGV"
    ! grep -q 'alice' "$STUB_ARGV"
    grep -q -- "postgres:17-alpine pg_dump --schema=public" "$STUB_ARGV"
}

# ── pg_validate_archive ──────────────────────────────────────────────────────

@test "pg_validate_archive rejects the 20-byte empty gzip the old script produced" {
    : | gzip > "$T/empty.sql.gz"
    [ "$(stat -c %s "$T/empty.sql.gz")" -le 32 ]
    run pg_validate_archive "$T/empty.sql.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"below the 1024B minimum"* ]]
}

@test "pg_validate_archive rejects a gzip'd pg_dump error message" {
    printf 'pg_dump: error: aborting because of server version mismatch\npg_dump: detail: server version: 17.6; pg_dump version: 16.15\n' \
        | gzip > "$T/err.sql.gz"
    run pg_validate_archive "$T/err.sql.gz"
    [ "$status" -eq 1 ]
}

@test "pg_validate_archive rejects a large archive with no CREATE TABLE" {
    head -c 8000 /dev/urandom | base64 | gzip > "$T/notables.sql.gz"
    [ "$(stat -c %s "$T/notables.sql.gz")" -ge 1024 ]
    run pg_validate_archive "$T/notables.sql.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no CREATE TABLE"* ]]
}

@test "pg_validate_archive rejects a missing file and a corrupt gzip" {
    run pg_validate_archive "$T/nope.sql.gz"
    [ "$status" -eq 1 ]
    head -c 4096 /dev/urandom > "$T/corrupt.sql.gz"
    run pg_validate_archive "$T/corrupt.sql.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a valid gzip"* ]]
}

@test "pg_validate_archive accepts a real-looking dump larger than the pipe buffer" {
    set -o pipefail   # backup-dbs.sh runs with pipefail; a grep -q here once SIGPIPE'd zcat
    { echo "-- PostgreSQL database dump"; echo "CREATE TABLE public.things ("; echo "    id integer"; echo ");";
      head -c 300000 /dev/urandom | base64; } | gzip > "$T/good.sql.gz"
    run pg_validate_archive "$T/good.sql.gz"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(pg_archive_count_tables "$T/good.sql.gz")" -eq 1 ]
    [ "$(pg_archive_count_tables "$T/good.sql.gz" public.things)" -eq 1 ]
    [ "$(pg_archive_count_tables "$T/good.sql.gz" public.other)" -eq 0 ]
}
