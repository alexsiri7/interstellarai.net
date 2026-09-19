#!/usr/bin/env bash
# Helpers for ops/cron/backup-dbs.sh and ops/cron/restore-test.sh. Sourced,
# never executed.
#
# The helpers never print a connection URL or password. Credentials travel
# to pg_dump/psql through the libpq PG* environment (PGHOST, PGUSER,
# PGPASSWORD, ...) so they never show up in `ps`.
#
# pg_dump/psql are whatever is first on PATH. backup-dbs.sh puts
# ~/.local/bin first, where a user-level PostgreSQL 17 client lives
# (~/.local/opt/postgresql-17, see ops/cron/README.md). No docker.
#
# Tunables (override from the environment before sourcing):
#   PG_BACKUP_MIN_BYTES  smallest compressed archive accepted as a backup

: "${PG_BACKUP_MIN_BYTES:=1024}"

# The backed-up projects, shared by backup-dbs.sh (dump + verify) and
# restore-test.sh (restore the archive somewhere else and re-verify):
#   project | URL variable | schema | sanity table (quoted as SQL needs it)
# All five live on Supabase with their tables in `public`; backup-dbs.sh
# still verifies the schema on the server at runtime so a migration to a
# per-project schema fails loudly there instead of silently producing an
# empty dump.
# shellcheck disable=SC2034  # consumed by the sourcing scripts
PG_BACKUP_PROJECTS=(
    'annie|ANNIE_DB_URL|public|"Project"'
    'reli|RELI_DB_URL|public|things'
    'filmduel|FILMDUEL_DB_URL|public|users'
    'kindred|KINDRED_DB_URL|public|entries'
    'lachesis|LACHESIS_DB_URL|public|lachesis_backlog'
)

# pg_url_percent_decode STRING → prints STRING with %XX sequences decoded.
pg_url_percent_decode() {
    local s="$1"
    s="${s//\\/\\\\}"     # keep literal backslashes literal through printf %b
    s="${s//%/\\x}"
    printf '%b' "$s"
}

# pg_url_to_env URL
# Parses postgres://[user[:pass]@]host[:port][/db][?k=v&...] and exports the
# matching libpq variables (PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE and
# PGSSLMODE / PGOPTIONS / PGAPPNAME from the query string). Returns 1 on a
# URL it cannot parse. Never echoes the URL.
pg_url_to_env() {
    local url="$1" rest auth hostport query="" user="" pass="" host port="" db=""
    case "$url" in
        postgresql://*|postgres://*) rest="${url#*://}" ;;
        *) echo "pg_url_to_env: not a postgresql:// URL" >&2; return 1 ;;
    esac
    if [[ "$rest" == *\?* ]]; then query="${rest#*\?}"; rest="${rest%%\?*}"; fi
    if [[ "$rest" == *@* ]]; then auth="${rest%@*}"; rest="${rest##*@}"; else auth=""; fi
    if [[ "$rest" == */* ]]; then db="${rest#*/}"; hostport="${rest%%/*}"; else hostport="$rest"; fi
    if [[ "$auth" == *:* ]]; then user="${auth%%:*}"; pass="${auth#*:}"; else user="$auth"; fi
    if [[ "$hostport" == \[*\]* ]]; then            # [ipv6]:port
        host="${hostport%%]*}"; host="${host#[}"
        [[ "$hostport" == *]:* ]] && port="${hostport##*:}"
    elif [[ "$hostport" == *:* ]]; then
        host="${hostport%%:*}"; port="${hostport##*:}"
    else
        host="$hostport"
    fi
    if [ -z "$host" ]; then echo "pg_url_to_env: URL has no host" >&2; return 1; fi

    unset PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE PGSSLMODE PGOPTIONS PGAPPNAME
    export PGHOST="$host"
    [ -n "$port" ] && export PGPORT="$port"
    [ -n "$user" ] && export PGUSER="$(pg_url_percent_decode "$user")"
    [ -n "$pass" ] && export PGPASSWORD="$(pg_url_percent_decode "$pass")"
    [ -n "$db" ] && export PGDATABASE="$(pg_url_percent_decode "$db")"

    local kv k v
    IFS='&' read -r -a _pg_kvs <<< "$query"
    for kv in "${_pg_kvs[@]}"; do
        [ -z "$kv" ] && continue
        k="${kv%%=*}"; v="$(pg_url_percent_decode "${kv#*=}")"
        case "$k" in
            sslmode) export PGSSLMODE="$v" ;;
            options) export PGOPTIONS="$v" ;;
            application_name) export PGAPPNAME="$v" ;;
            *) echo "pg_url_to_env: ignoring unsupported URL parameter '$k'" >&2 ;;
        esac
    done
    return 0
}

# pg_clear_env — drop the credentials from the environment again.
pg_clear_env() { unset PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE PGSSLMODE PGOPTIONS PGAPPNAME; }

# pg_major_of "pg_dump (PostgreSQL) 17.6" → 17 ; "16.15 (Ubuntu ...)" → 16
pg_major_of() {
    local s="$1"
    s="${s#*(PostgreSQL) }"
    s="${s%%.*}"
    s="${s%% *}"
    [[ "$s" =~ ^[0-9]+$ ]] && printf '%s' "$s" && return 0
    return 1
}

# pg_client_major — major version of the pg_dump found on PATH.
pg_client_major() {
    local out
    out=$(pg_dump --version 2>/dev/null) || return 1
    pg_major_of "$out"
}

# pg_server_major — major version of the server the PG* env points at.
# Any psql can ask the version, so the system one is fine here.
pg_server_major() {
    local out
    command -v psql >/dev/null 2>&1 || return 1
    out=$(psql -X -Atq -c "SHOW server_version" 2>/dev/null) || return 1
    pg_major_of "$out"
}

# pg_check_client SERVER_MAJOR → prints the pg_dump major version when the
# pg_dump on PATH is at least as new as the server; otherwise fails with a
# reason on stderr. pg_dump aborts on any server newer than itself, and that
# abort used to become a 20-byte empty archive (#64) — so refuse up front.
pg_check_client() {
    local server_major="$1" m
    if ! command -v pg_dump >/dev/null 2>&1; then
        echo "pg_check_client: no pg_dump on PATH — install the PostgreSQL client into ~/.local/opt/postgresql-17 (see ops/cron/README.md)" >&2
        return 1
    fi
    m=$(pg_client_major) || m=""
    if [ -n "$m" ] && [ "$m" -ge "$server_major" ]; then printf '%s' "$m"; return 0; fi
    echo "pg_check_client: local pg_dump is v${m:-?}, server is v$server_major (pg_dump refuses older clients) — upgrade ~/.local/opt/postgresql-17 (see ops/cron/README.md)" >&2
    return 1
}

# pg_validate_archive FILE → 0 when FILE looks like a real pg_dump archive:
# at least PG_BACKUP_MIN_BYTES compressed and containing a CREATE TABLE.
# Prints the reason on stdout when it rejects.
pg_validate_archive() {
    local f="$1" size
    if [ ! -s "$f" ]; then echo "archive missing or zero bytes"; return 1; fi
    size=$(stat -c %s "$f")
    if [ "$size" -lt "$PG_BACKUP_MIN_BYTES" ]; then
        echo "archive is ${size}B, below the ${PG_BACKUP_MIN_BYTES}B minimum (empty dump)"; return 1
    fi
    if ! gzip -t "$f" 2>/dev/null; then echo "archive is not a valid gzip stream"; return 1; fi
    if [ "$(pg_archive_count_tables "$f")" -lt 1 ]; then
        echo "archive contains no CREATE TABLE statement"; return 1
    fi
    return 0
}

# pg_archive_count_tables FILE [SCHEMA.TABLE] → number of CREATE TABLE
# statements in the gzip'd dump (for the one table when given). Uses grep -c
# rather than grep -q: with pipefail, -q closing the pipe early makes zcat
# fail with SIGPIPE on any dump larger than the pipe buffer.
pg_archive_count_tables() {
    local f="$1" name="${2:-}" n
    if [ -n "$name" ]; then
        n=$(zcat "$f" | grep -c "^CREATE TABLE ${name} (" || true)
    else
        n=$(zcat "$f" | grep -c '^CREATE TABLE ' || true)
    fi
    printf '%s' "${n:-0}"
}
