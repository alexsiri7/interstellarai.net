#!/usr/bin/env bats
# Tests for ops/cron/restore-test.sh: newest archive per project, age limit,
# recorded-row-count sources (.meta sidecar, db-backup log fallback), the
# Supabase shim + NOT VALID foreign-key rewrite, verification after restore,
# status file, ntfy, and cluster teardown on every path. The server binaries
# (initdb/pg_ctl/psql) are stubs; the last tests use the real PostgreSQL 17
# tree in ~/.local/opt/postgresql-17 when it is installed.
#
# Run: bunx bats ops/cron/tests/restore-test.bats

setup() {
    # Short path on purpose: it becomes the unix-socket directory.
    export T="$BATS_TMPDIR/rt-$$"
    mkdir -p "$T/bin" "$T/backups/reli" "$T/state" "$T/share/extension"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$CRON_DIR/restore-test.sh"
    export PG_BIN="$T/bin"
    export PATH="$T/bin:$PATH"
    export BACKUP_ROOT="$T/backups"
    export DB_BACKUP_STATE_DIR="$T/state"
    export DB_BACKUP_LOG="$T/db-backup.log"
    export RESTORE_TEST_TMP_ROOT="$T"
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    # Only reli configured; the others must be reported as skipped.
    echo 'RELI_DB_URL=postgresql://alice:p%40ss@db.example.com:5432/postgres' > "$T/secrets.env"
    export NTFY_TOPIC=""
    export STUB_ROWS=224

    printf '#!/usr/bin/env bash\ntouch "%s/ntfy-called"\n' "$T" > "$T/bin/curl"
    printf '#!/usr/bin/env bash\necho "postgres (PostgreSQL) 17.11"\n' > "$T/bin/postgres"

    cat > "$T/bin/initdb" <<'STUB'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$T/initdb.argv"; echo >> "$T/initdb.argv"
while [ $# -gt 0 ]; do [ "$1" = "-D" ] && mkdir -p "$2"; shift; done
[ "${STUB_INITDB_RC:-0}" = 0 ] || echo "initdb: error: could not create directory" >&2
exit "${STUB_INITDB_RC:-0}"
STUB

    cat > "$T/bin/pg_ctl" <<'STUB'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$T/pg_ctl.argv"; echo >> "$T/pg_ctl.argv"
d=""; while [ $# -gt 1 ]; do [ "$1" = "-D" ] && d="$2"; shift; done
case "${!#}" in
    start) [ "${STUB_PGCTL_RC:-0}" = 0 ] && echo 1234 > "$d/postmaster.pid"; exit "${STUB_PGCTL_RC:-0}" ;;
    stop)  rm -f "$d/postmaster.pid"; echo "stop $d" >> "$T/pg_ctl.stops" ;;
esac
STUB

    cat > "$T/bin/psql" <<'STUB'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$T/psql.argv"; echo >> "$T/psql.argv"
q=""; db=""
while [ $# -gt 0 ]; do
    case "$1" in -c) q="$2"; shift ;; -d|-Atd) db="$2"; shift ;; esac
    shift
done
if [ -z "$q" ]; then                     # the restore stream on stdin
    cat > "$T/restored-$db.sql"
    if [ "${STUB_RESTORE_RC:-0}" != 0 ]; then echo 'ERROR:  type "extensions.vector" does not exist' >&2; fi
    exit "${STUB_RESTORE_RC:-0}"
fi
case "$q" in
    "CREATE DATABASE"*) exit 0 ;;
    *information_schema.schemata*) printf '%s\n' "${STUB_SCHEMA_FOUND-1}" ;;
    *to_regclass*) printf '%s\n' "${STUB_TABLE_FOUND-t}" ;;
    *"FROM pg_tables"*) echo 9 ;;
    *"count(*)"*) echo "$STUB_ROWS" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$T"/bin/*

    make_archive "reli" "reli-20260919-091701" 224
}

teardown() {
    rm -rf "$T"
}

# make_archive PROJECT BASENAME ROWS [EXTRA_SQL_FILE] — a plausible plain dump
# (> 1 KB compressed, sanity table present) plus its .meta sidecar. The
# schema is the project's: `reli` for reli, `public` otherwise.
make_archive() {
    local dir="$T/backups/$1" f="$T/backups/$1/$2.sql.gz" s=public
    # reli lives in its own schema of the consolidated project (2026-09-26).
    [ "$1" = reli ] && s=reli
    mkdir -p "$dir"
    { echo "-- PostgreSQL database dump"; echo "CREATE SCHEMA $s;"
      echo "CREATE TABLE $s.things ("; echo "    id integer"; echo ");"
      [ -n "${4:-}" ] && cat "$4"
      head -c 3000 /dev/urandom | base64 | sed 's/^/-- /'; } | gzip > "$f"
    printf 'rows=%s\ntable=%s.things\n' "$3" "$s" > "$f.meta"
    echo "$f"
}

# make_schema_archive PROJECT BASENAME ROWS SCHEMA.TABLE SQL_FILE — an
# archive of one non-public schema: SQL_FILE is the dump body, padded past
# the 1 KB minimum, plus its .meta sidecar.
make_schema_archive() {
    local dir="$T/backups/$1" f="$T/backups/$1/$2.sql.gz"
    mkdir -p "$dir"
    { echo "-- PostgreSQL database dump"; cat "$5"
      head -c 3000 /dev/urandom | base64 | sed 's/^/-- /'; } | gzip > "$f"
    printf 'rows=%s\ntable=%s\n' "$3" "$4" > "$f.meta"
    echo "$f"
}

# A pg_dump --schema=auth of Supabase Auth, cut down: it brings its own
# auth.users / auth.uid() and FKs inside auth.
auth_dump_sql() {
    cat <<'SQL'
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE TABLE auth.users (
    id uuid NOT NULL,
    email character varying(255)
);
CREATE TABLE auth.identities (
    id uuid NOT NULL,
    user_id uuid NOT NULL
);
COPY auth.users (id, email) FROM stdin;
00000000-0000-0000-0000-000000000001	a@example.com
00000000-0000-0000-0000-000000000002	b@example.com
\.
ALTER TABLE ONLY auth.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);
ALTER TABLE ONLY auth.identities
    ADD CONSTRAINT identities_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
SQL
}

# A pg_dump --schema=events (Thaleia on the consolidated project).
events_dump_sql() {
    cat <<'SQL'
CREATE SCHEMA events;
CREATE TABLE events.sources (
    id bigint NOT NULL,
    key text NOT NULL
);
CREATE TABLE events.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL
);
COPY events.sources (id, key) FROM stdin;
1	ticketmaster
2	barbican
\.
SQL
}

only_configured() {
    printf '%s\n' "$@" > "$T/secrets.env"
}

cluster_dirs() { find "$T" -maxdepth 1 -name 'restore-test.*' 2>/dev/null; }

@test "newest archive restores into a socket-only throwaway cluster, matches the recorded count, exits 0" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Throwaway cluster up: $T/restore-test."* ]]
    [[ "$output" == *"OK: reli restored: $T/backups/reli/reli-20260919-091701.sql.gz (224 rows in reli.things = backup count, 9 tables in reli,"* ]]
    [[ "$output" == *"SKIP: annie"* ]]
    [[ "$output" == *"Restore test complete (ok: reli; skipped: annie filmduel kindred lachesis thaleia kindred-auth)"* ]]
    grep -q -- '-A trust' "$T/initdb.argv"
    grep -q -- "-k $T/restore-test\." "$T/pg_ctl.argv"
    grep -q -- "listen_addresses=''" "$T/pg_ctl.argv"
    grep -q -- '-w ' "$T/pg_ctl.argv"
    grep -q -- "-v ON_ERROR_STOP=1 -h $T/restore-test\..* -d restore_reli" "$T/psql.argv"
    ! grep -q 'DROP SCHEMA public' "$T/restored-restore_reli.sql"
    grep -q '^CREATE FUNCTION auth.uid()' "$T/restored-restore_reli.sql"
    grep -q '^CREATE TABLE reli.things ($' "$T/restored-restore_reli.sql"
    ! grep -q 'CREATE EXTENSION vector' "$T/restored-restore_reli.sql"
    grep -q '^last_run_status=ok$' "$T/state/restore-test-status"
    grep -q '^last_ok=[1-9]' "$T/state/restore-test-status"
    grep -q "^reli=ok $T/backups/reli/reli-20260919-091701.sql.gz rows=224 tables=9 ms=" "$T/state/restore-test-status"
    grep -q '^annie=skipped$' "$T/state/restore-test-status"
    [ ! -f "$T/ntfy-called" ]
    [ -f "$T/pg_ctl.stops" ]
    [ -z "$(cluster_dirs)" ]
}

@test "the newest archive by mtime is the one restored" {
    make_archive reli reli-20260919-061701 200 > /dev/null
    touch -d '4 hours ago' "$T/backups/reli/reli-20260919-061701.sql.gz"
    make_archive reli reli-20260918-231701 150 > /dev/null   # older name, newest mtime
    touch "$T/backups/reli/reli-20260918-231701.sql.gz"
    touch -d '1 hour ago' "$T/backups/reli/reli-20260919-091701.sql.gz"
    export STUB_ROWS=150
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: reli restored: $T/backups/reli/reli-20260918-231701.sql.gz (150 rows"* ]]
}

@test "row count after restore differing from the recorded count fails, ntfys, tears the cluster down" {
    export STUB_ROWS=200 NTFY_TOPIC=t
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: reli restore FAILED — reli.things has 200 rows after restore, backup recorded 224"* ]]
    [[ "$output" == *"ERROR: restore test FAILED for: reli (ok: none; skipped: annie filmduel kindred lachesis thaleia kindred-auth)"* ]]
    grep -q '^last_run_status=failed$' "$T/state/restore-test-status"
    grep -q '^last_run_failed=reli$' "$T/state/restore-test-status"
    grep -q '^last_ok=0$' "$T/state/restore-test-status"
    grep -q '^reli=failed .*200 rows after restore' "$T/state/restore-test-status"
    [ -f "$T/ntfy-called" ]
    [ -f "$T/pg_ctl.stops" ]
    [ -z "$(cluster_dirs)" ]
}

@test "a failed run preserves the previous last_ok" {
    printf 'last_run=1\nlast_run_status=ok\nlast_run_failed=\nlast_ok=1700000000\n' > "$T/state/restore-test-status"
    export STUB_ROWS=200
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -q '^last_ok=1700000000$' "$T/state/restore-test-status"
}

@test "newest archive older than 6h fails before anything is restored" {
    touch -d '7 hours ago' "$T/backups/reli/reli-20260919-091701.sql.gz"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"newest archive $T/backups/reli/reli-20260919-091701.sql.gz is 7h old (limit 6h)"* ]]
    [ ! -f "$T/restored-restore_reli.sql" ]
}

@test "no archive at all fails" {
    rm -rf "$T/backups/reli"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: reli restore FAILED — no reli-*.sql.gz under $T/backups/reli"* ]]
    grep -q '^reli=failed no-archive' "$T/state/restore-test-status"
}

@test "an archive that fails backup validation (too small) is not restored" {
    printf 'CREATE TABLE reli.things (\n' | gzip > "$T/backups/reli/reli-20260919-091701.sql.gz"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"below the 1024B minimum"* ]]
    [ ! -f "$T/restored-restore_reli.sql" ]
}

@test "without a .meta sidecar the count comes from the db-backup log line for that archive" {
    rm "$T/backups/reli/reli-20260919-091701.sql.gz.meta"
    {
        echo "[db-backup] 2026-09-19 06:17:11 OK: reli backed up: $T/backups/reli/reli-20260919-061701.sql.gz (16K, 21 rows in reli.things, pg_dump v17 from /x/pg_dump, server v17)"
        echo "[db-backup] 2026-09-19 09:17:11 OK: reli backed up: $T/backups/reli/reli-20260919-091701.sql.gz (16K, 224 rows in reli.things, pg_dump v17 from /x/pg_dump, server v17)"
    } > "$T/db-backup.log"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"224 rows in reli.things = backup count"* ]]
}

@test "no .meta and no log line for the archive fails (never guesses a count)" {
    rm "$T/backups/reli/reli-20260919-091701.sql.gz.meta"
    echo "[db-backup] OK: reli backed up: $T/backups/reli/reli-20260919-061701.sql.gz (16K, 21 rows in reli.things, x)" > "$T/db-backup.log"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no recorded row count: $T/backups/reli/reli-20260919-091701.sql.gz.meta missing and no OK line for the archive in $T/db-backup.log"* ]]
    [ ! -f "$T/restored-restore_reli.sql" ]
}

@test ".meta naming a different table than the project's sanity table fails" {
    printf 'rows=224\ntable=reli.other\n' > "$T/backups/reli/reli-20260919-091701.sql.gz.meta"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"records table reli.other, expected reli.things"* ]]
}

@test "psql aborting on the archive (ON_ERROR_STOP) is a failure with the first error quoted" {
    export STUB_RESTORE_RC=3
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *'psql -v ON_ERROR_STOP=1 aborted: ERROR:  type "extensions.vector" does not exist'* ]]
    [ -f "$T/pg_ctl.stops" ]
    [ -z "$(cluster_dirs)" ]
}

@test "sanity table missing after the restore fails even when psql succeeded" {
    export STUB_TABLE_FOUND=f
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"table reli.things missing after restore"* ]]
}

@test "foreign keys into the stub auth schema are added NOT VALID and counted; in-schema ones untouched" {
    cat > "$T/extra.sql" <<'SQL'
ALTER TABLE ONLY reli.entries
    ADD CONSTRAINT entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE ONLY reli.entries
    ADD CONSTRAINT entries_thing_id_fkey FOREIGN KEY (thing_id) REFERENCES reli.things(id);
SQL
    make_archive reli reli-20260919-091701 224 "$T/extra.sql" > /dev/null
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *", 1 foreign keys into auth/extensions added NOT VALID)"* ]]
    grep -q '^    ADD CONSTRAINT entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE NOT VALID;$' "$T/restored-restore_reli.sql"
    grep -q '^    ADD CONSTRAINT entries_thing_id_fkey FOREIGN KEY (thing_id) REFERENCES reli.things(id);$' "$T/restored-restore_reli.sql"
}

@test "an archive using extensions.vector needs pgvector: fails when absent, creates the extension when present" {
    echo "CREATE TABLE reli.e (embedding extensions.vector(1536));" > "$T/extra.sql"
    make_archive reli reli-20260919-091701 224 "$T/extra.sql" > /dev/null
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"uses extensions.vector but pgvector is not installed in $T/bin/.."* ]]
    [ ! -f "$T/restored-restore_reli.sql" ]

    touch "$T/share/extension/vector.control"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^CREATE EXTENSION vector SCHEMA extensions;$' "$T/restored-restore_reli.sql"
}

@test "an auth-schema archive (kindred-auth) restores without the auth stub, into a hyphen-free database, FKs inside auth untouched" {
    only_configured 'KINDRED_DB_URL=postgresql://u:p@h/d'
    auth_dump_sql > "$T/auth.sql"
    make_schema_archive kindred-auth kindred-auth-20260919-091701 2 auth.users "$T/auth.sql" > /dev/null
    make_archive kindred kindred-20260919-091701 224 > /dev/null
    sed -i 's/^table=public.things$/table=public.entries/' "$T/backups/kindred/kindred-20260919-091701.sql.gz.meta"
    export STUB_ROWS=2
    run "$SCRIPT"
    [[ "$output" == *"OK: kindred-auth restored: $T/backups/kindred-auth/kindred-auth-20260919-091701.sql.gz (2 rows in auth.users = backup count, 9 tables in auth, "*"ms)"* ]]
    [[ "$output" != *"kindred-auth restored:"*"NOT VALID"* ]]
    grep -q -- '-d restore_kindred_auth' "$T/psql.argv"
    f="$T/restored-restore_kindred_auth.sql"
    [ -f "$f" ]
    # The archive's own CREATE SCHEMA auth / auth.users / auth.uid() are the only ones.
    [ "$(grep -c '^CREATE SCHEMA auth;$' "$f")" -eq 1 ]
    [ "$(grep -c '^CREATE TABLE auth.users ' "$f")" -eq 1 ]
    [ "$(grep -c '^CREATE FUNCTION auth.uid()' "$f")" -eq 1 ]
    ! grep -q 'DROP SCHEMA public' "$f"
    grep -q '^CREATE SCHEMA extensions;$' "$f"
    grep -q '^    ADD CONSTRAINT identities_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;$' "$f"
    # kindred's public archive still gets the full shim.
    grep -q '^DROP SCHEMA public CASCADE;$' "$T/restored-restore_kindred.sql"
    grep -q '^CREATE TABLE auth.users (id uuid PRIMARY KEY);$' "$T/restored-restore_kindred.sql"
}

@test "a non-public schema archive (thaleia/events) keeps public and gets the auth stub" {
    only_configured 'THALEIA_DB_URL=postgresql://u:p@h/d'
    events_dump_sql > "$T/events.sql"
    make_schema_archive thaleia thaleia-20260919-091701 2 events.sources "$T/events.sql" > /dev/null
    export STUB_ROWS=2
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: thaleia restored: $T/backups/thaleia/thaleia-20260919-091701.sql.gz (2 rows in events.sources = backup count, 9 tables in events,"* ]]
    [[ "$output" == *"Restore test complete (ok: thaleia; skipped: annie reli filmduel kindred lachesis kindred-auth)"* ]]
    f="$T/restored-restore_thaleia.sql"
    ! grep -q 'DROP SCHEMA public' "$f"
    grep -q '^CREATE FUNCTION auth.uid()' "$f"
    grep -q '^CREATE TABLE events.sources ($' "$f"
}

@test "missing server binaries fail every project loud and name the README" {
    rm "$T/bin/initdb"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: $T/bin/initdb missing"* ]]
    [[ "$output" == *"ERROR: restore test FAILED for: annie,reli,filmduel,kindred,lachesis,thaleia,kindred-auth"* ]]
    grep -q '^reli=failed cluster-not-started$' "$T/state/restore-test-status"
    grep -q '^last_run_status=failed$' "$T/state/restore-test-status"
}

@test "pg_ctl failing to start fails every project and removes the temp dir" {
    export STUB_PGCTL_RC=1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: pg_ctl start failed"* ]]
    [ -z "$(cluster_dirs)" ]
}

# ── real binaries ───────────────────────────────────────────────────────────

REAL_PG_BIN="$HOME/.local/opt/postgresql-17/bin"

real_setup() {
    [ -x "$REAL_PG_BIN/initdb" ] || skip "no PostgreSQL 17 server tree at $REAL_PG_BIN"
    export PG_BIN="$REAL_PG_BIN"
    rm -f "$T/bin/initdb" "$T/bin/pg_ctl" "$T/bin/psql" "$T/bin/postgres"
    cat > "$T/real.sql" <<'SQL'
CREATE TABLE reli.owners (
    id uuid NOT NULL
);
INSERT INTO reli.things VALUES (1), (2), (3);
ALTER TABLE ONLY reli.owners
    ADD CONSTRAINT owners_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE reli.owners ENABLE ROW LEVEL SECURITY;
CREATE POLICY "owners select" ON reli.owners FOR SELECT USING ((auth.uid() = id));
SQL
    make_archive reli reli-20260919-091701 3 "$T/real.sql" > /dev/null
}

@test "real cluster: a generated archive restores, the count matches, nothing is left behind" {
    real_setup
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Throwaway cluster up: $T/restore-test."*"postgres (PostgreSQL) 17"* ]]
    [[ "$output" == *"OK: reli restored: "*"(3 rows in reli.things = backup count, 2 tables in reli, "*"ms, 1 foreign keys into auth/extensions added NOT VALID)"* ]]
    grep -q '^last_run_status=ok$' "$T/state/restore-test-status"
    [ -z "$(cluster_dirs)" ]
    ! pgrep -f "postgres.*-k $T/restore-test" > /dev/null
}

@test "real cluster: a recorded count the restore does not reproduce fails" {
    real_setup
    printf 'rows=4\ntable=reli.things\n' > "$T/backups/reli/reli-20260919-091701.sql.gz.meta"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"reli.things has 3 rows after restore, backup recorded 4"* ]]
    [ -z "$(cluster_dirs)" ]
}

@test "real cluster: an auth-schema archive (kindred-auth) restores with its own auth.users and internal FKs" {
    real_setup
    only_configured 'KINDRED_DB_URL=postgresql://u:p@h/d'
    auth_dump_sql > "$T/auth.sql"
    make_schema_archive kindred-auth kindred-auth-20260919-091701 2 auth.users "$T/auth.sql" > /dev/null
    run "$SCRIPT"
    echo "$output"
    # KINDRED_DB_URL also configures `kindred` (public), which has no archive
    # here and fails; only kindred-auth is under test.
    [[ "$output" == *"ERROR: restore test FAILED for: kindred (ok: kindred-auth;"* ]]
    [[ "$output" == *"OK: kindred-auth restored: "*"(2 rows in auth.users = backup count, 2 tables in auth, "*"ms)"* ]]
    [ -z "$(cluster_dirs)" ]
}

@test "real cluster: a non-public schema archive (thaleia/events) restores" {
    real_setup
    only_configured 'THALEIA_DB_URL=postgresql://u:p@h/d'
    events_dump_sql > "$T/events.sql"
    make_schema_archive thaleia thaleia-20260919-091701 2 events.sources "$T/events.sql" > /dev/null
    run "$SCRIPT"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: thaleia restored: "*"(2 rows in events.sources = backup count, 2 tables in events, "*"ms)"* ]]
    [ -z "$(cluster_dirs)" ]
}
