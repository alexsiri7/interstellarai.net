#!/usr/bin/env bats
# Tests for ops/cron/musenmingle-digest.sh: no empty pings, item lines and
# counts, privacy (no reply email / details / note / IP hash), the state
# window (first run, 7-day cap, advance only on delivery), the Click
# fallback, truncation, and the once-a-day failure ntfy. psql and curl are
# stubs; nothing talks to a real database or ntfy.sh.
#
# Run: bunx bats ops/cron/tests/musenmingle-digest.bats

setup() {
    export T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/state"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$CRON_DIR/musenmingle-digest.sh"
    export PATH="$T/bin:$PATH"
    export HOME="$T/home"
    mkdir -p "$HOME"
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    cat > "$T/secrets.env" <<'EOF'
THALEIA_DB_URL=postgresql://thaleia:s3cr%40t@db.example.com:5432/postgres?sslmode=require
NTFY_TOPIC=test-topic
EOF
    export MM_DIGEST_STATE_DIR="$T/state"
    # 2026-09-27 09:00 BST
    export MM_DIGEST_NOW=1790496000
    export STUB_ROWS="$T/rows.tsv"
    : > "$STUB_ROWS"
    export PLANTED_EMAIL="owner-secret@venue.example"

    # psql: record argv + the SQL from stdin, print the fixture rows. It
    # behaves like the real table: if the SQL ever selects a private column,
    # the planted email comes back in the output.
    cat > "$T/bin/psql" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$T/psql.argv"
cat > "$T/psql.sql"
env | grep -E '^PG(OPTIONS|PASSWORD|HOST)=' > "$T/psql.env"
if [ "${STUB_PSQL_RC:-0}" != 0 ]; then
    echo 'psql: error: connection to server at "db.example.com" failed: timeout expired' >&2
    exit "$STUB_PSQL_RC"
fi
cat "$STUB_ROWS"
if grep -Eqi 'reply_email|details|\bnote\b|ip_hash' "$T/psql.sql"; then
    printf 'contact\t2026-09-26 10:00:00+00\tother · leak.example → %s\n' "$PLANTED_EMAIL"
fi
exit 0
STUB

    # curl: a HEAD probe (-I) or an ntfy POST. Each POST is recorded as
    # $T/ntfy.<n>.{headers,body}.
    cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
head=0; data=""; hdrs=()
while [ $# -gt 0 ]; do
    case "$1" in
        -I) head=1 ;;
        -H) hdrs+=("$2"); shift ;;
        -d) data="$2"; shift ;;
        -o|-m) shift ;;
    esac
    shift
done
if [ "$head" = 1 ]; then echo head >> "$T/head.calls"; exit "${STUB_HEAD_RC:-0}"; fi
n=$(( $(ls "$T"/ntfy.*.body 2>/dev/null | wc -l) + 1 ))
printf '%s\n' "${hdrs[@]}" > "$T/ntfy.$n.headers"
printf '%s' "$data" > "$T/ntfy.$n.body"
exit "${STUB_NTFY_RC:-0}"
STUB
    chmod +x "$T"/bin/*
}

ntfy_count() { ls "$T"/ntfy.*.body 2>/dev/null | wc -l; }

row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STUB_ROWS"; }

mixed_rows() {
    row contact    '2026-09-26 10:00:00+00' 'remove_listings · barbican.org.uk → issue #71'
    row contact    '2026-09-26 11:00:00+00' 'other · tate.org.uk → issue pending'
    row suggestion '2026-09-26 12:00:00+00' 'newvenue.co.uk → new-scraper issue #80'
    row suggestion '2026-09-26 12:30:00+00' 'barbican.org.uk → already covered by barbican'
    row suggestion '2026-09-26 13:00:00+00' 'southbankcentre.co.uk → refused (bot_blocked)'
    row live       '2026-09-26 14:00:00+00' 'artrabbit — 331 events'
    row firstfail  '2026-09-26 15:00:00+00' 'kings-place — HTTP 500 from https://kingsplace.co.uk/whats-on'
    row refused    '2026-09-26 16:00:00+00' 'creativemornings.com (robots_disallowed)'
    row broken     '2026-09-26 17:00:00+00' 'design-museum → issue #90'
}

@test "nothing new: no ntfy, exit 0, window advances" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing new — no ntfy"* ]]
    [ "$(ntfy_count)" -eq 0 ]
    [ ! -e "$T/head.calls" ]
    [ "$(cat "$T/state/last-window-end")" = "$MM_DIGEST_NOW" ]
}

@test "first run covers the last 24 h and passes the window to psql" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "since=$((MM_DIGEST_NOW - 86400))" "$T/psql.argv"
    grep -qx "until=$MM_DIGEST_NOW" "$T/psql.argv"
}

@test "read-only transaction with a statement timeout" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^BEGIN READ ONLY;' "$T/psql.sql"
    grep -q 'SET LOCAL statement_timeout' "$T/psql.sql"
    grep -q 'default_transaction_read_only=on' "$T/psql.env"
    grep -q 'statement_timeout=15000' "$T/psql.env"
    # URL options are kept, not overwritten.
    grep -q '^PGHOST=db.example.com$' "$T/psql.env"
}

@test "mixed items: title count, section order, lines, click header" {
    mixed_rows
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(ntfy_count)" -eq 1 ]
    grep -qx 'Title: Muse & Mingle: 9 new' "$T/ntfy.1.headers"
    grep -qx 'Click: https://musenmingle.interstellarai.net/sources' "$T/ntfy.1.headers"
    body="$(cat "$T/ntfy.1.body")"
    expected="Since Sat 26 Sep 09:00
Contact: remove_listings · barbican.org.uk → issue #71
Contact: other · tate.org.uk → issue pending
Suggested: newvenue.co.uk → new-scraper issue #80
Suggested: barbican.org.uk → already covered by barbican
Suggested: southbankcentre.co.uk → refused (bot_blocked)
Broken: design-museum → issue #90
First run failed: kings-place — HTTP 500 from https://kingsplace.co.uk/whats-on
Live: artrabbit — 331 events
Refused: creativemornings.com (robots_disallowed)"
    [ "$body" = "$expected" ]
    [[ "$output" == *"9 item(s): Contact 2, Suggested 3, Broken 1, First run failed 1, Live 1, Refused 1"* ]]
    [ "$(cat "$T/state/last-window-end")" = "$MM_DIGEST_NOW" ]
}

@test "privacy: SQL never selects email/details/note/ip hash; nothing leaks" {
    mixed_rows
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -Eqi 'reply_email|details|\bnote\b|ip_hash' "$T/psql.sql" || false
    ! grep -rq "$PLANTED_EMAIL" "$T"/ntfy.* || false
    [[ "$output" != *"$PLANTED_EMAIL"* ]]
    # And the DB password never reaches the log or the message.
    [[ "$output" != *"s3cr"* ]]
    ! grep -rq 's3cr' "$T"/ntfy.* || false
}

@test "click falls back to thaleia.interstellarai.net when the new domain does not answer" {
    row live '2026-09-26 14:00:00+00' 'artrabbit — 331 events'
    STUB_HEAD_RC=6 run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'Click: https://thaleia.interstellarai.net/sources' "$T/ntfy.1.headers"
}

@test "missed days: window starts at the last delivered digest" {
    echo $((MM_DIGEST_NOW - 3 * 86400)) > "$T/state/last-window-end"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "since=$((MM_DIGEST_NOW - 3 * 86400))" "$T/psql.argv"
}

@test "window is capped at 7 days" {
    echo $((MM_DIGEST_NOW - 30 * 86400)) > "$T/state/last-window-end"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "since=$((MM_DIGEST_NOW - 7 * 86400))" "$T/psql.argv"
    [[ "$output" == *"capping at 7 days"* ]]
}

@test "undelivered ntfy: exit 1, window not advanced, one failure ntfy" {
    echo $((MM_DIGEST_NOW - 86400)) > "$T/state/last-window-end"
    row live '2026-09-26 14:00:00+00' 'artrabbit — 331 events'
    STUB_NTFY_RC=22 run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(cat "$T/state/last-window-end")" = "$((MM_DIGEST_NOW - 86400))" ]
    [[ "$output" == *"digest ntfy undelivered"* ]]
}

@test "DB failure: exit 1, state untouched, 'digest failed' ntfy at most once a day" {
    echo $((MM_DIGEST_NOW - 86400)) > "$T/state/last-window-end"
    STUB_PSQL_RC=2 run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DB query failed: psql: error: connection to server"* ]]
    [ "$(ntfy_count)" -eq 1 ]
    grep -qx 'Title: Muse & Mingle: digest failed' "$T/ntfy.1.headers"
    [ "$(cat "$T/state/last-window-end")" = "$((MM_DIGEST_NOW - 86400))" ]

    # Same day again: logged, not re-sent.
    STUB_PSQL_RC=2 run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already sent today"* ]]
    [ "$(ntfy_count)" -eq 1 ]

    # Next day: one more.
    MM_DIGEST_NOW=$((MM_DIGEST_NOW + 86400)) STUB_PSQL_RC=2 run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(ntfy_count)" -eq 2 ]

    # Recovery: the next digest still covers the failed days.
    MM_DIGEST_NOW=$((MM_DIGEST_NOW + 2 * 86400)) run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "since=$((MM_DIGEST_NOW - 86400))" "$T/psql.argv"
}

@test "missing DB URL is a failure; MUSENMINGLE_DB_URL wins over THALEIA_DB_URL" {
    echo 'NTFY_TOPIC=test-topic' > "$T/secrets.env"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"neither MUSENMINGLE_DB_URL nor THALEIA_DB_URL"* ]]

    printf '%s\n' 'NTFY_TOPIC=test-topic' \
        'THALEIA_DB_URL=postgresql://old@old.example.com/postgres' \
        'MUSENMINGLE_DB_URL=postgresql://new@new.example.com/postgres' > "$T/secrets.env"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^PGHOST=new.example.com$' "$T/psql.env"
}

@test "long digest is truncated with '+K more' and the title keeps the full count" {
    for i in $(seq 1 60); do
        row live '2026-09-26 14:00:00+00' "source-number-$i-with-a-rather-long-key — $i events"
    done
    MM_DIGEST_MAX_BODY_BYTES=500 run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'Title: Muse & Mingle: 60 new' "$T/ntfy.1.headers"
    [ "$(LC_ALL=C wc -c < "$T/ntfy.1.body")" -le 500 ]
    last="$(tail -n 1 "$T/ntfy.1.body")"
    [[ "$last" =~ ^\+[0-9]+\ more$ ]]
    shown=$(grep -c '^Live: ' "$T/ntfy.1.body")
    [ "$((shown + ${last//[^0-9]/}))" -eq 60 ]
}

@test "--dry-run prints the message, sends nothing, writes no state" {
    mixed_rows
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Title: Muse & Mingle: 9 new"* ]]
    [[ "$output" == *"Live: artrabbit — 331 events"* ]]
    [ "$(ntfy_count)" -eq 0 ]
    [ ! -e "$T/state/last-window-end" ]
}
