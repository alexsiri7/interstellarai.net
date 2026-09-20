#!/usr/bin/env bash
# cloud-mirror.sh — nightly mirror of the owner's Google Drive to local disk,
# plus ingestion of the Google Takeout (Google Photos) archives that land there.
#
# Layout under $NAS_ROOT (default /mnt/ext-fast/nas; override in secrets.env
# once it moves to an external drive — see ops/cron/README.md, "Cloud mirror"):
#   .nas-root                    marker. Missing → abort + ntfy. Protects against
#                                writing a full mirror into an empty mountpoint on
#                                the root fs when the external drive is unplugged.
#                                This script never creates it.
#   gdrive/                      `rclone sync gdrive-full:` (Drive `backups/`
#                                excluded: that is what backup-dbs.sh uploads)
#   .versions/gdrive/YYYYMMDD/   rclone --backup-dir: files deleted or overwritten
#                                on Drive that day; directories older than 30 days
#                                are pruned
#   photos/                      Takeout content, `Takeout/` stripped, so
#                                `Takeout/Google Photos/<album>/x.jpg` becomes
#                                `photos/Google Photos/<album>/x.jpg`
#   .state/takeout-manifest.tsv  one line per ingested archive:
#                                sha256 <TAB> size <TAB> path (relative to
#                                $NAS_ROOT) <TAB> ingested-at (ISO 8601)
#
# Takeout is configured for monthly INCREMENTAL exports (first full, then
# diffs), so extraction is purely additive: nothing already under photos/ is
# ever deleted, an archive is extracted with `tar --keep-newer-files`, and an
# archive already in the manifest is skipped (same relative path + size → no
# rehash; otherwise by sha256, so a moved archive is not extracted twice).
# Archives are found by scanning the whole mirror for takeout-*.tgz / .zip:
# Drive holds three folders literally named `Takeout` (rclone: "Duplicate
# directory found in source - ignoring"), so no fixed folder path is assumed.
#
# Steps: marker → free-space guard (CLOUD_MIRROR_MIN_FREE_GIB, 20) → flock →
# rclone sync (--exclude-from cloud-mirror.excludes next to this script,
# --max-depth 40 as a loop guard, no --fast-list; exit 0 or 9 ok; a nonzero
# exit whose only ERROR lines are duplicate-directory notices is ok; anything
# else fails) → shortcut-loop detector (a path nesting the same name 5+ times
# → ntfy WARNING, not a failure) → prune .versions → ingest (gzip -t /
# unzip -t, extract, manifest; a corrupt archive fails that archive and the
# run continues) → status file → ntfy on any failure → exit 1.
#
# Status: $HOME/.archon/pipeline-health-state/cloud-mirror-status (last_run,
# last_run_status, last_run_failed, last_ok, newest_takeout_epoch = mtime of the
# newest archive seen in the mirror, 0 if none). pipeline-health-cron.sh
# (check_cloud_mirror) alerts when last_ok is older than 48h, and daily when
# newest_takeout_epoch is older than 45 days (the monthly export stopped, or
# the 12-month schedule ran out and needs re-arming at takeout.google.com).
#
# Flags: --dry-run (rclone --dry-run, no extraction, prints what it would
# ingest, status file not written), --takeout-only (skip the rclone sync).
# Overrides (tests): NAS_ROOT, CLOUD_MIRROR_STATE_DIR, CLOUD_MIRROR_MIN_FREE_GIB,
# CLOUD_MIRROR_REMOTE, ARCHON_CRON_SECRETS, ARCHON_CRON_LOG_DIR.
#
# Crontab: 30 3 * * * cloud-mirror.sh >> ~/.local/state/archon-cron/logs/cloud-mirror.log 2>&1
# Never run this against a remote other than gdrive-full: (drive.readonly).

set -euo pipefail

DRY_RUN=0
TAKEOUT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --takeout-only) TAKEOUT_ONLY=1 ;;
        *) echo "usage: $0 [--dry-run] [--takeout-only]" >&2; exit 2 ;;
    esac
done

# cron's PATH is /usr/bin:/bin.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# Secrets: NTFY_TOPIC, optional NAS_ROOT override. chmod 600, outside the repo.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"

CRON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_ROOT="${NAS_ROOT:-/mnt/ext-fast/nas}"
RCLONE_REMOTE="${CLOUD_MIRROR_REMOTE:-gdrive-full:}"
# rclone --exclude-from: Drive's backups/ (this machine's own uploads) and the
# known self-referencing shortcut loops. One pattern per line, see the file.
EXCLUDES_FILE="${CLOUD_MIRROR_EXCLUDES:-$CRON_DIR/cloud-mirror.excludes}"
# Loop guard: a Drive shortcut pointing at its own parent makes the walk
# infinite; rclone stops descending here, and the nesting detector below
# names the loop so it can be removed in Drive.
MAX_DEPTH=40
NESTING_MIN_REPEATS=5
MIRROR_DIR="$NAS_ROOT/gdrive"
VERSIONS_DIR="$NAS_ROOT/.versions/gdrive"
PHOTOS_DIR="$NAS_ROOT/photos"
MANIFEST="$NAS_ROOT/.state/takeout-manifest.tsv"
MIN_FREE_GIB="${CLOUD_MIRROR_MIN_FREE_GIB:-20}"
VERSIONS_KEEP_DAYS=30
LOG_TAG="[cloud-mirror]"
LOG_DIR="${ARCHON_CRON_LOG_DIR:-$HOME/.local/state/archon-cron/logs}"
# Shared with pipeline-health-cron.sh (check_cloud_mirror).
STATE_DIR="${CLOUD_MIRROR_STATE_DIR:-$HOME/.archon/pipeline-health-state}"
STATUS_FILE="$STATE_DIR/cloud-mirror-status"
LOCK_FILE="$STATE_DIR/cloud-mirror.lock"
TODAY=$(date +%Y%m%d)

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

FAILED=()          # short tokens for the status file / ntfy title
INGESTED=()
SKIPPED=0
ARCHIVES_SEEN=0
NEWEST_TAKEOUT=""  # empty = mirror not scanned this run; keep the previous value
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cloud-mirror.XXXXXX")
STAGING=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    rm -rf "$SCRATCH"
    [ -n "$STAGING" ] && rm -rf "$STAGING"
    return 0
}
trap cleanup EXIT

fail() { FAILED+=("$1"); log "ERROR: $2"; }

# --- Status for pipeline-health-cron.sh + ntfy + exit code -------------------
# finish is the only exit path after the argument check; it preserves last_ok
# and newest_takeout_epoch from the previous status when this run did not get
# far enough to refresh them.
finish() {
    local now last_ok prev_newest run_status failed_csv
    now=$(date +%s)
    failed_csv=$(IFS=,; echo "${FAILED[*]-}")
    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run: status file $STATUS_FILE not written"
    else
        mkdir -p "$STATE_DIR"
        last_ok=$(grep -s '^last_ok=' "$STATUS_FILE" | cut -d= -f2 || true)
        prev_newest=$(grep -s '^newest_takeout_epoch=' "$STATUS_FILE" | cut -d= -f2 || true)
        [[ "${prev_newest:-}" =~ ^[0-9]+$ ]] || prev_newest=0
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
            echo "newest_takeout_epoch=${NEWEST_TAKEOUT:-$prev_newest}"
            echo "archives_seen=$ARCHIVES_SEEN"
            echo "ingested=${#INGESTED[@]}"
        } > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
    fi

    if [ ${#FAILED[@]} -gt 0 ]; then
        log "ERROR: cloud mirror FAILED: $failed_csv (ingested: ${INGESTED[*]-none}; skipped: $SKIPPED)"
        notify "Cloud mirror FAILED" \
            "cloud-mirror.sh: $failed_csv. NAS_ROOT=$NAS_ROOT. See $LOG_DIR/cloud-mirror.log on $(hostname)." \
            high floppy_disk
        exit 1
    fi
    log "Cloud mirror complete (ingested: ${INGESTED[*]-none}; skipped: $SKIPPED; archives seen: $ARCHIVES_SEEN)"
    exit 0
}

# --- 1. Marker ---------------------------------------------------------------
if [ ! -f "$NAS_ROOT/.nas-root" ]; then
    fail "nas-root-missing" "$NAS_ROOT/.nas-root is missing — is the NAS drive mounted at $NAS_ROOT? Refusing to write into an unmarked directory (touch it by hand only after checking the mount)."
    finish
fi

# --- 2. Free-space guard -----------------------------------------------------
free_kib=$(df -Pk "$NAS_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || true)
min_kib=$(( MIN_FREE_GIB * 1024 * 1024 ))
if ! [[ "$free_kib" =~ ^[0-9]+$ ]]; then
    fail "df-failed" "cannot read free space on $NAS_ROOT (df output: '${free_kib:-}')"
    finish
fi
if [ "$free_kib" -lt "$min_kib" ]; then
    fail "low-disk" "only $(( free_kib / 1024 / 1024 )) GiB free on $NAS_ROOT (minimum ${MIN_FREE_GIB} GiB) — refusing to start"
    finish
fi

# --- 3. One run at a time ----------------------------------------------------
mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "another cloud-mirror run holds $LOCK_FILE — skipping this run"
    exit 0
fi

mode=""
[ "$DRY_RUN" -eq 1 ] && mode="$mode, dry-run"
[ "$TAKEOUT_ONLY" -eq 1 ] && mode="$mode, takeout-only"
log "=== cloud mirror start (NAS_ROOT=$NAS_ROOT, $(( free_kib / 1024 / 1024 )) GiB free$mode) ==="
mkdir -p "$MIRROR_DIR" "$VERSIONS_DIR" "$PHOTOS_DIR" "$(dirname "$MANIFEST")"

# --- 4. rclone sync ----------------------------------------------------------
# rclone exit codes: 0 ok; 9 "successful, but no files transferred" ok. Drive's
# duplicate `Takeout` folders make rclone log duplicate-directory notices; a
# nonzero exit is still ok when every ERROR line is one of those.
rclone_ok() {  # rc outfile
    case "$1" in
        0|9) return 0 ;;
    esac
    if grep -q 'Duplicate directory found' "$2" \
        && ! grep -v 'Duplicate directory found' "$2" | grep -q 'ERROR'; then
        log "WARNING: rclone exited $1 but the only errors are duplicate-directory notices — treating as ok"
        return 0
    fi
    return 1
}

# The mirror's directory tree, one relative path per line, with any path whose
# basename repeats NESTING_MIN_REPEATS+ times in a row (a/a/a/a/a): the
# footprint of a Drive shortcut pointing at its own parent, which rclone
# follows until --max-depth. Only the shortest path of each loop is printed,
# and loops already listed in the excludes file (anchored `/dir/**` lines)
# are left out, since those stay on disk until removed by hand.
detect_nesting_loops() {
    local hit skip prefix
    find "$MIRROR_DIR" -mindepth 1 -type d 2>/dev/null \
        | awk -v root="$MIRROR_DIR/" -v min="$NESTING_MIN_REPEATS" '
            { rel = substr($0, length(root) + 1); n = split(rel, p, "/"); run = 1
              for (i = 2; i <= n; i++) {
                  if (p[i] == p[i-1]) { run++; if (run >= min) { print n "\t" rel; break } }
                  else run = 1
              } }' \
        | sort -n | cut -f2- \
        | while IFS= read -r hit; do
            skip=0
            for prefix in "${NESTED_SEEN[@]-}"; do
                [ -n "$prefix" ] || continue
                case "$hit" in "$prefix"|"$prefix"/*) skip=1; break ;; esac
            done
            [ "$skip" -eq 1 ] && continue
            NESTED_SEEN+=("$hit")
            echo "$hit"
        done
}
NESTED_SEEN=()
[ -r "$EXCLUDES_FILE" ] && while IFS= read -r line; do
    case "$line" in
        /*/\*\*) line="${line#/}"; NESTED_SEEN+=("${line%/\*\*}") ;;
    esac
done < "$EXCLUDES_FILE"

if [ "$TAKEOUT_ONLY" -eq 1 ]; then
    log "takeout-only: skipping rclone sync"
elif [ ! -r "$EXCLUDES_FILE" ]; then
    fail "excludes-missing" "exclude file $EXCLUDES_FILE is missing or unreadable — refusing to sync without it (it keeps Drive's backups/ and the known shortcut loops out of the mirror)"
else
    # No --fast-list: on this Drive a shortcut inside `Choir` points back at
    # `Choir` itself, and the recursive listing --fast-list does up front never
    # ends (17 minutes, zero transfers, nothing in the log). Without it the
    # walk still loops, but transfers start at once and the loop is visible
    # in the log, stops at --max-depth and is named by detect_nesting_loops.
    rclone_args=(sync "$RCLONE_REMOTE" "$MIRROR_DIR"
        --backup-dir "$VERSIONS_DIR/$TODAY"
        --exclude-from "$EXCLUDES_FILE"
        --drive-acknowledge-abuse --drive-skip-dangling-shortcuts
        --max-depth "$MAX_DEPTH"
        --transfers 8 --checkers 16 --create-empty-src-dirs
        --stats 5m --stats-one-line --stats-log-level NOTICE --log-level INFO)
    [ "$DRY_RUN" -eq 1 ] && rclone_args+=(--dry-run)
    log "rclone ${rclone_args[*]}"
    sync_start=$(date +%s)
    set +e
    rclone "${rclone_args[@]}" 2>&1 | tee "$SCRATCH/rclone.out"
    rc=${PIPESTATUS[0]}
    set -e
    if rclone_ok "$rc" "$SCRATCH/rclone.out"; then
        log "OK: rclone sync finished (exit $rc) in $(( $(date +%s) - sync_start ))s"
    else
        fail "rclone-sync" "rclone sync exited $rc after $(( $(date +%s) - sync_start ))s: $(grep 'ERROR' "$SCRATCH/rclone.out" | tail -3 | tr '\n' ' ')"
    fi

    # --- 4b. Shortcut-loop detector (warning, not a failure) ------------------
    loops=$(detect_nesting_loops | head -5 || true)
    if [ -n "$loops" ]; then
        log "WARNING: self-referencing folder nesting in the mirror (a Drive shortcut pointing at its own parent?): $(echo "$loops" | tr '\n' ' ')"
        notify "Cloud mirror WARNING: folder loop in the mirror" \
            "Directories nested ${NESTING_MIN_REPEATS}+ levels deep under their own name in $MIRROR_DIR: $(echo "$loops" | tr '\n' ' '). Delete the self-referencing shortcut in Drive (right-click the nested folder inside its parent → Remove) or add /<path>/** to $EXCLUDES_FILE, then rm -rf the leftover tree under $MIRROR_DIR by hand." \
            default warning
    fi
fi

# --- 5. Prune .versions older than 30 days (by directory name, YYYYMMDD) ------
cutoff=$(date -d "$VERSIONS_KEEP_DAYS days ago" +%Y%m%d)
pruned=0
for dir in "$VERSIONS_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -d "$dir" ] || continue
    day="${dir##*/}"
    [ "$day" -lt "$cutoff" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run: would prune $dir"
    elif rm -rf "$dir"; then
        pruned=$(( pruned + 1 ))
    else
        fail "prune-versions" "could not remove $dir"
    fi
done
[ "$pruned" -gt 0 ] && log "Pruned $pruned .versions day(s) older than ${VERSIONS_KEEP_DAYS} days (before $cutoff)"

# --- 6. Takeout ingest -------------------------------------------------------
[ -f "$MANIFEST" ] || : > "$MANIFEST"

manifest_has_path_size() {  # relpath size → 0 if a line with both exists
    awk -F'\t' -v p="$1" -v s="$2" '$3 == p && $2 == s { found=1 } END { exit !found }' "$MANIFEST"
}
manifest_has_sha() { cut -f1 "$MANIFEST" | grep -qx "$1"; }

# Additive extraction: --keep-newer-files never removes anything, replaces an
# older local copy with the archive's and leaves a newer local copy alone, so
# the same archive twice is a no-op. GNU tar 1.35 exits 2 in that mode for
# every directory that already exists ("Unexpected inconsistency when making
# directory") and for every file it keeps, although both are exactly the
# wanted behaviour — so tar runs under LC_ALL=C and a nonzero exit counts as
# success only when every stderr line is one of those notices. Anything else
# (Cannot open, Wrote only, Unexpected EOF, ...) is a real failure.
TAR_BENIGN='Unexpected inconsistency when making directory|is newer or same age|Exiting with failure status due to previous errors'
tar_extract() {  # tar-args... ; stderr collected in $SCRATCH/tar.err
    local rc=0
    LC_ALL=C tar "$@" --keep-newer-files --warning=no-timestamp 2>>"$SCRATCH/tar.err" || rc=$?
    if [ "$rc" -ne 0 ] && [ -s "$SCRATCH/tar.err" ] \
        && ! grep -Ev "$TAR_BENIGN" "$SCRATCH/tar.err" | grep -q .; then
        rc=0
    fi
    return "$rc"
}

# extract_archive PATH → 0 on success. `Takeout/` is stripped so photos/
# holds `Google Photos/...`.
extract_archive() {
    local archive="$1" rc=0
    : > "$SCRATCH/tar.err"
    case "$archive" in
        *.tgz)
            tar_extract -xzf "$archive" -C "$PHOTOS_DIR" --strip-components=1 || rc=$?
            ;;
        *.zip)
            # unzip cannot strip a leading component; stage on the same
            # filesystem and stream through tar for identical semantics.
            STAGING=$(mktemp -d "$PHOTOS_DIR/.staging.XXXXXX")
            if unzip -qq -o "$archive" -d "$STAGING" 2>>"$SCRATCH/tar.err"; then
                # entries are ./Takeout/... → strip 2
                set +o pipefail
                tar -cf - -C "$STAGING" . | tar_extract -xf - -C "$PHOTOS_DIR" --strip-components=2 || rc=$?
                set -o pipefail
            else
                rc=1
            fi
            rm -rf "$STAGING"; STAGING=""
            ;;
    esac
    if [ "$rc" -ne 0 ]; then
        log "extract stderr: $(grep -Ev "$TAR_BENIGN" "$SCRATCH/tar.err" | head -3 | tr '\n' ' ')"
    fi
    return "$rc"
}

ingest_start=$(date +%s)
NEWEST_TAKEOUT=0
while IFS= read -r -d '' archive; do
    ARCHIVES_SEEN=$(( ARCHIVES_SEEN + 1 ))
    rel="${archive#"$NAS_ROOT"/}"
    size=$(stat -c %s "$archive")
    mtime=$(stat -c %Y "$archive")
    [ "$mtime" -gt "$NEWEST_TAKEOUT" ] && NEWEST_TAKEOUT="$mtime"

    if manifest_has_path_size "$rel" "$size"; then
        SKIPPED=$(( SKIPPED + 1 ))
        continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run: would ingest $rel ($(( size / 1024 / 1024 )) MB)"
        continue
    fi

    log "Ingesting $rel ($(( size / 1024 / 1024 )) MB) — hashing"
    if ! sha=$(sha256sum "$archive" | cut -d' ' -f1) || [ -z "$sha" ]; then
        fail "hash:${rel##*/}" "sha256sum failed on $rel — unreadable archive, not ingested"
        continue
    fi
    if manifest_has_sha "$sha"; then
        log "SKIP: $rel already ingested under another path (sha256 $sha)"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
    fi

    case "$archive" in
        *.tgz) verify=(gzip -t "$archive") ;;
        *.zip) verify=(unzip -tqq "$archive") ;;
    esac
    if ! "${verify[@]}" 2>"$SCRATCH/verify.err"; then
        fail "corrupt:${rel##*/}" "$rel failed ${verify[0]} -t — corrupt or truncated archive, not ingested: $(head -2 "$SCRATCH/verify.err" | tr '\n' ' ')"
        continue
    fi

    if ! extract_archive "$archive"; then
        fail "extract:${rel##*/}" "extraction of $rel into $PHOTOS_DIR failed — not recorded in the manifest, will be retried next run"
        continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$sha" "$size" "$rel" "$(date -Is)" >> "$MANIFEST"
    INGESTED+=("${rel##*/}")
    log "OK: ingested $rel into $PHOTOS_DIR (sha256 $sha)"
done < <(find "$MIRROR_DIR" -type f \( -name 'takeout-*.tgz' -o -name 'takeout-*.zip' \) -print0 | sort -z)

if [ "$ARCHIVES_SEEN" -eq 0 ]; then
    log "WARNING: no takeout-*.tgz / takeout-*.zip anywhere under $MIRROR_DIR"
else
    log "Takeout: $ARCHIVES_SEEN archive(s) in the mirror, newest $(date -d "@$NEWEST_TAKEOUT" -Is), ${#INGESTED[@]} ingested, $SKIPPED already in manifest, $(( $(date +%s) - ingest_start ))s"
fi

finish
