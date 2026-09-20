#!/usr/bin/env bats
# End-to-end tests for ops/cron/cloud-mirror.sh with a stubbed rclone.
# Covers the guards (marker, free space, lock), the agreed rclone flags, the
# rclone exit-code policy, the additive Takeout extraction (manifest skip by
# path+size and by sha256, --keep-newer-files semantics, same archive twice),
# corrupt archives, --dry-run, --takeout-only and .versions pruning.
#
# Run: bunx bats ops/cron/tests/cloud-mirror.bats

setup() {
    export T="$BATS_TMPDIR/cloud-mirror-$$"
    mkdir -p "$T/bin" "$T/nas" "$T/state" "$T/src" "$T/deliver/Takeout"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$CRON_DIR/cloud-mirror.sh"
    export PATH="$T/bin:$PATH"
    export HOME="$T"
    export NAS_ROOT="$T/nas"
    touch "$NAS_ROOT/.nas-root"
    export CLOUD_MIRROR_STATE_DIR="$T/state"
    export CLOUD_MIRROR_MIN_FREE_GIB=0
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    : > "$T/secrets.env"
    export NTFY_TOPIC="t"
    export STUB_ARGV="$T/rclone-argv"
    export STUB_RCLONE_RC=0
    export STUB_RCLONE_OUT=""
    # Directory whose contents the rclone stub "syncs" into the destination
    # (mirrors the Drive layout: Takeout/<archive>). Empty = deliver nothing.
    export STUB_RCLONE_DELIVER="$T/deliver"

    cat > "$T/bin/rclone" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGV"
# rclone sync SRC DST ... → $3 is the destination
if [ -n "${STUB_RCLONE_DELIVER:-}" ] && [ "$1" = sync ]; then
    case " $* " in
        *" --dry-run "*) ;;
        *) mkdir -p "$3"; cp -a "$STUB_RCLONE_DELIVER"/. "$3"/ ;;
    esac
fi
[ -n "${STUB_RCLONE_OUT:-}" ] && printf '%s\n' "$STUB_RCLONE_OUT"
exit "${STUB_RCLONE_RC:-0}"
STUB
    # curl: record the ntfy title.
    printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in Title:*) echo "$a" >> "%s/ntfy-called";; esac; done\n' "$T" > "$T/bin/curl"
    chmod +x "$T"/bin/*

    ARCHIVE1="takeout-20260920T090000Z-001.tgz"
    make_takeout "$T/deliver/Takeout/$ARCHIVE1" "Photos from 2026" a.jpg photo-a
}

teardown() {
    rm -rf "$T"
}

# make_takeout OUT ALBUM FILE CONTENT — a fake Takeout export: Takeout/Google
# Photos/<album>/<file> plus its .json sidecar, gzipped tar like the real ones.
make_takeout() {
    local src; src=$(mktemp -d "$T/src/XXXXXX")
    mkdir -p "$src/Takeout/Google Photos/$2"
    echo "$4" > "$src/Takeout/Google Photos/$2/$3"
    printf '{"title":"%s"}\n' "$3" > "$src/Takeout/Google Photos/$2/$3.json"
    tar -czf "$1" -C "$src" Takeout
    rm -rf "$src"
}

photo() { cat "$NAS_ROOT/photos/Google Photos/$1"; }
manifest_lines() { wc -l < "$NAS_ROOT/.state/takeout-manifest.tsv"; }
status_val() { grep "^$1=" "$T/state/cloud-mirror-status" | cut -d= -f2; }

@test "missing .nas-root marker aborts before rclone runs: exit 1, ntfy, nothing written under NAS_ROOT" {
    rm "$NAS_ROOT/.nas-root"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$NAS_ROOT/.nas-root is missing"* ]]
    [ ! -f "$STUB_ARGV" ]
    [ ! -d "$NAS_ROOT/gdrive" ]
    [ ! -d "$NAS_ROOT/photos" ]
    grep -q 'Title: Cloud mirror FAILED' "$T/ntfy-called"
    [ "$(status_val last_run_status)" = failed ]
    [ "$(status_val last_run_failed)" = nas-root-missing ]
    [ "$(status_val last_ok)" = 0 ]
}

@test "free-space guard refuses to start below the minimum: exit 1, ntfy, no rclone" {
    export CLOUD_MIRROR_MIN_FREE_GIB=999999999
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"minimum 999999999 GiB"* ]]
    [[ "$output" == *"refusing to start"* ]]
    [ ! -f "$STUB_ARGV" ]
    grep -q 'Title: Cloud mirror FAILED' "$T/ntfy-called"
    [ "$(status_val last_run_failed)" = low-disk ]
}

@test "happy path: agreed rclone flags, Takeout extracted under photos/ without the Takeout/ prefix, manifest + status" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$STUB_ARGV")" = sync ]
    [ "$(sed -n 2p "$STUB_ARGV")" = "gdrive-full:" ]
    [ "$(sed -n 3p "$STUB_ARGV")" = "$NAS_ROOT/gdrive" ]
    grep -qx -- '--backup-dir' "$STUB_ARGV"
    grep -qx -- "$NAS_ROOT/.versions/gdrive/$(date +%Y%m%d)" "$STUB_ARGV"
    grep -qx -- '--exclude' "$STUB_ARGV"
    grep -qxF -- 'backups/**' "$STUB_ARGV"
    grep -qx -- '--drive-acknowledge-abuse' "$STUB_ARGV"
    grep -qx -- '--fast-list' "$STUB_ARGV"
    grep -qx -- '--create-empty-src-dirs' "$STUB_ARGV"
    ! grep -qx -- '--dry-run' "$STUB_ARGV"
    [ "$(photo 'Photos from 2026/a.jpg')" = photo-a ]
    [ -f "$NAS_ROOT/photos/Google Photos/Photos from 2026/a.jpg.json" ]
    [ ! -e "$NAS_ROOT/photos/Takeout" ]
    [ "$(manifest_lines)" -eq 1 ]
    IFS=$'\t' read -r sha size path at < "$NAS_ROOT/.state/takeout-manifest.tsv"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]]
    [ "$sha" = "$(sha256sum "$NAS_ROOT/gdrive/Takeout/$ARCHIVE1" | cut -d' ' -f1)" ]
    [ "$size" = "$(stat -c %s "$NAS_ROOT/gdrive/Takeout/$ARCHIVE1")" ]
    [ "$path" = "gdrive/Takeout/$ARCHIVE1" ]
    [ -n "$at" ]
    [[ "$output" == *"OK: ingested gdrive/Takeout/$ARCHIVE1"* ]]
    [ "$(status_val last_run_status)" = ok ]
    [[ "$(status_val last_ok)" =~ ^[1-9][0-9]*$ ]]
    [ "$(status_val newest_takeout_epoch)" = "$(stat -c %Y "$NAS_ROOT/gdrive/Takeout/$ARCHIVE1")" ]
    [ "$(status_val ingested)" = 1 ]
    [ ! -f "$T/ntfy-called" ]
}

@test "an archive already in the manifest is skipped without re-hashing or re-extracting" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    echo edited > "$NAS_ROOT/photos/Google Photos/Photos from 2026/a.jpg"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"hashing"* ]]
    [[ "$output" != *"OK: ingested"* ]]
    [[ "$output" == *"1 already in manifest"* ]]
    [ "$(manifest_lines)" -eq 1 ]
    [ "$(photo 'Photos from 2026/a.jpg')" = edited ]
}

@test "the manifest is keyed by sha256: a moved archive is recognised and not extracted twice" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    export STUB_RCLONE_DELIVER=""
    mkdir -p "$NAS_ROOT/gdrive/Takeout (2)"
    mv "$NAS_ROOT/gdrive/Takeout/$ARCHIVE1" "$NAS_ROOT/gdrive/Takeout (2)/$ARCHIVE1"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: gdrive/Takeout (2)/$ARCHIVE1 already ingested under another path"* ]]
    [ "$(manifest_lines)" -eq 1 ]
}

@test "extraction is additive: an incremental archive adds files, replaces older copies, keeps newer and unrelated local files" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    local album="$NAS_ROOT/photos/Google Photos/Photos from 2026"
    echo local-only > "$album/local.jpg"                      # not in any archive
    echo local-newer > "$album/a.jpg"; touch -d '+1 day' "$album/a.jpg"
    echo stale > "$album/b.jpg"; touch -d '2000-01-01' "$album/b.jpg"
    ARCHIVE2="takeout-20261020T090000Z-001.tgz"
    make_takeout "$T/deliver/Takeout/$ARCHIVE2" "Photos from 2026" b.jpg photo-b
    # the second export also carries a new album, tarred into the same archive
    local src; src=$(mktemp -d "$T/src/XXXXXX")
    mkdir -p "$src/Takeout/Google Photos/Trip" "$src/Takeout/Google Photos/Photos from 2026"
    echo photo-c > "$src/Takeout/Google Photos/Trip/c.jpg"
    echo photo-b > "$src/Takeout/Google Photos/Photos from 2026/b.jpg"
    echo old-a > "$src/Takeout/Google Photos/Photos from 2026/a.jpg"
    tar -czf "$T/deliver/Takeout/$ARCHIVE2" -C "$src" Takeout
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: ingested gdrive/Takeout/$ARCHIVE2"* ]]
    [ "$(cat "$album/local.jpg")" = local-only ]
    [ "$(cat "$album/a.jpg")" = local-newer ]
    [ "$(cat "$album/b.jpg")" = photo-b ]
    [ "$(photo Trip/c.jpg)" = photo-c ]
    [ -f "$album/a.jpg.json" ]
    [ "$(manifest_lines)" -eq 2 ]
    [ ! -f "$T/ntfy-called" ]
}

@test "extracting the same archive twice is harmless (tar 1.35 pre-existing-directory exit 2 is not a failure)" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    rm "$NAS_ROOT/.state/takeout-manifest.tsv"       # force a re-extraction
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: ingested"* ]]
    [[ "$output" != *"ERROR"* ]]
    [ "$(photo 'Photos from 2026/a.jpg')" = photo-a ]
    [ "$(manifest_lines)" -eq 1 ]
    [ ! -f "$T/ntfy-called" ]
}

@test "a corrupt archive fails that archive only: the run continues, exits 1, ntfys, and retries it next time" {
    BAD="takeout-20260920T090000Z-002.tgz"
    head -c 4000 /dev/urandom > "$T/deliver/Takeout/$BAD"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: gdrive/Takeout/$BAD failed gzip -t"* ]]
    [[ "$output" == *"OK: ingested gdrive/Takeout/$ARCHIVE1"* ]]
    [ "$(photo 'Photos from 2026/a.jpg')" = photo-a ]
    [ "$(manifest_lines)" -eq 1 ]
    ! grep -q "$BAD" "$NAS_ROOT/.state/takeout-manifest.tsv"
    [ "$(status_val last_run_status)" = failed ]
    [ "$(status_val last_run_failed)" = "corrupt:$BAD" ]
    [ "$(status_val last_ok)" = 0 ]
    grep -q 'Title: Cloud mirror FAILED' "$T/ntfy-called"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: gdrive/Takeout/$BAD failed gzip -t"* ]]
}

@test "a failed run preserves last_ok and newest_takeout_epoch from the previous status" {
    printf 'last_run=1\nlast_run_status=ok\nlast_run_failed=\nlast_ok=1700000000\nnewest_takeout_epoch=1699999999\n' > "$T/state/cloud-mirror-status"
    rm "$NAS_ROOT/.nas-root"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(status_val last_ok)" = 1700000000 ]
    [ "$(status_val newest_takeout_epoch)" = 1699999999 ]
}

@test "rclone exit 9 (successful, nothing transferred) is not a failure" {
    export STUB_RCLONE_RC=9
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: rclone sync finished (exit 9)"* ]]
    [ ! -f "$T/ntfy-called" ]
}

@test "rclone nonzero exit whose only errors are duplicate-directory notices is not a failure" {
    export STUB_RCLONE_RC=1
    export STUB_RCLONE_OUT=$'2026/09/20 03:30:01 NOTICE: Takeout: Duplicate directory found in source - ignoring\n2026/09/20 03:30:01 ERROR : Takeout: Duplicate directory found in source - ignoring\n2026/09/20 03:31:01 NOTICE: 1.2 GiB / 1.2 GiB, 100%, 0 B/s, ETA -'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the only errors are duplicate-directory notices — treating as ok"* ]]
    [ "$(status_val last_run_status)" = ok ]
    [ ! -f "$T/ntfy-called" ]
}

@test "a real rclone error fails the run (exit 1, ntfy) but the Takeout ingest still happens" {
    export STUB_RCLONE_RC=1
    export STUB_RCLONE_OUT=$'2026/09/20 03:30:01 NOTICE: Takeout: Duplicate directory found in source - ignoring\n2026/09/20 03:30:05 ERROR : Photos/x.jpg: Failed to copy: googleapi: Error 403: rateLimitExceeded'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: rclone sync exited 1"* ]]
    [[ "$output" == *"rateLimitExceeded"* ]]
    [ "$(photo 'Photos from 2026/a.jpg')" = photo-a ]
    [ "$(status_val last_run_status)" = failed ]
    [ "$(status_val last_run_failed)" = rclone-sync ]
    grep -q 'Title: Cloud mirror FAILED' "$T/ntfy-called"
}

@test "--dry-run passes --dry-run to rclone, extracts nothing, prints what it would ingest, writes no status" {
    export STUB_RCLONE_DELIVER=""
    mkdir -p "$NAS_ROOT/gdrive/Takeout"
    cp "$T/deliver/Takeout/$ARCHIVE1" "$NAS_ROOT/gdrive/Takeout/"
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    grep -qx -- '--dry-run' "$STUB_ARGV"
    [[ "$output" == *"dry-run: would ingest gdrive/Takeout/$ARCHIVE1"* ]]
    [ ! -e "$NAS_ROOT/photos/Google Photos" ]
    [ "$(manifest_lines)" -eq 0 ]
    [ ! -f "$T/state/cloud-mirror-status" ]
    [[ "$output" == *"status file"*"not written"* ]]
}

@test "--takeout-only skips the rclone sync and still ingests what is in the mirror" {
    mkdir -p "$NAS_ROOT/gdrive/Some Folder/Takeout"
    cp "$T/deliver/Takeout/$ARCHIVE1" "$NAS_ROOT/gdrive/Some Folder/Takeout/"
    run "$SCRIPT" --takeout-only
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_ARGV" ]
    [[ "$output" == *"takeout-only: skipping rclone sync"* ]]
    [[ "$output" == *"OK: ingested gdrive/Some Folder/Takeout/$ARCHIVE1"* ]]
    [ "$(photo 'Photos from 2026/a.jpg')" = photo-a ]
}

@test "no Takeout archive in the mirror: warning, newest_takeout_epoch=0, still a successful run" {
    export STUB_RCLONE_DELIVER=""
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: no takeout-*.tgz"* ]]
    [ "$(status_val newest_takeout_epoch)" = 0 ]
    [ "$(status_val last_run_status)" = ok ]
}

@test ".versions/gdrive days older than 30 days are pruned, recent ones kept" {
    mkdir -p "$NAS_ROOT/.versions/gdrive/20250101/x" "$NAS_ROOT/.versions/gdrive/$(date -d '29 days ago' +%Y%m%d)" "$NAS_ROOT/.versions/gdrive/$(date +%Y%m%d)"
    touch "$NAS_ROOT/.versions/gdrive/20250101/x/old.txt"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pruned 1 .versions day(s)"* ]]
    [ ! -d "$NAS_ROOT/.versions/gdrive/20250101" ]
    [ -d "$NAS_ROOT/.versions/gdrive/$(date -d '29 days ago' +%Y%m%d)" ]
    [ -d "$NAS_ROOT/.versions/gdrive/$(date +%Y%m%d)" ]
}

@test "a run still holding the lock makes the next one log and exit 0 without syncing" {
    flock -x "$T/state/cloud-mirror.lock" sleep 30 &
    LOCKER=$!
    sleep 0.3
    run "$SCRIPT"
    kill "$LOCKER" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"another cloud-mirror run holds"* ]]
    [ ! -f "$STUB_ARGV" ]
    [ ! -f "$T/ntfy-called" ]
}

@test "zip archives are ingested with the same layout" {
    command -v zip >/dev/null || skip "zip not installed"
    local src; src=$(mktemp -d "$T/src/XXXXXX")
    mkdir -p "$src/Takeout/Google Photos/Zipped"
    echo photo-z > "$src/Takeout/Google Photos/Zipped/z.jpg"
    (cd "$src" && zip -qr "$T/deliver/Takeout/takeout-20260920T090000Z-003.zip" Takeout)
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: ingested gdrive/Takeout/takeout-20260920T090000Z-003.zip"* ]]
    [ "$(photo Zipped/z.jpg)" = photo-z ]
    [ ! -e "$NAS_ROOT/photos/Takeout" ]
    [ -z "$(find "$NAS_ROOT/photos" -maxdepth 1 -name '.staging.*')" ]
    [ "$(manifest_lines)" -eq 2 ]
}
