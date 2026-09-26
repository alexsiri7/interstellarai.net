#!/usr/bin/env bash
# lib/tool-update.sh — the `--apply` half of tool-freshness.sh: upgrade the
# user-level tools the freshness check found behind. Sourced by
# tool-freshness.sh, never run on its own; it uses the caller's log/notify/
# version_lt and the INSTALLED/LATEST/LATEST_TAG/STATE maps the checks fill.
#
#   bun         `bun upgrade`, then archon-serve.service is restarted and its
#               web root health-checked. There is no rollback for bun; an
#               unhealthy server is ntfy'd urgent. Skipped (retried next week)
#               while an archon run is live: the server and every running
#               workflow are bun processes, and the restart would kill them.
#   gh          cli/cli release tarball + gh_<v>_checksums.txt, `sha256sum -c`,
#               `install -m 0755` over ~/.local/bin/gh. The previous binary is
#               put back when `gh --version` or `gh auth status` fail after.
#   ShellCheck  koalaman/shellcheck linux.x86_64 .tar.xz, same install pattern.
#               The project publishes no checksum file (the sha512 sums of
#               older releases are gone), so the expected sha256 is the release
#               asset's `digest` from the GitHub API — the same origin a
#               checksums file would have, fetched over the authenticated API.
#   pg_dump     theseus-rs/postgresql-binaries tarball + .sha256, unpacked to
#               ~/.local/opt/postgresql-<major>.new; pgvector is rebuilt into
#               it (the README recipe, same version the current tree carries);
#               the tree is proven with a throwaway cluster (initdb, pg_ctl
#               start, CREATE EXTENSION vector, stop) before it is swapped in.
#               The old tree stays as postgresql-<major>.prev for one cycle
#               (removed by the next weekly run, >= 6 days later), the two
#               ~/.local/bin symlinks are re-pointed and `pg_dump --version`
#               must agree; otherwise the old tree is put back. The check only
#               ever proposes the installed major line, and this refuses
#               anything else: a major bump is manual (README, pg_dump section).
#   uv, node    never touched (snap auto-refreshes; node is apt/NodeSource and
#               a major bump goes through ops/host/install.sh NODE_MAJOR).
#               archon likewise. They stay in the "still behind (manual)" line.
#
# Overrides (tests): TOOL_UPDATE_BIN_DIR, TOOL_UPDATE_OPT_DIR,
# TOOL_UPDATE_SCRATCH_ROOT, TOOL_UPDATE_RELEASES (download host),
# TOOL_UPDATE_SERVICE, TOOL_UPDATE_HEALTH_URL, TOOL_UPDATE_HEALTH_TRIES,
# TOOL_UPDATE_HEALTH_INTERVAL, TOOL_UPDATE_PGVECTOR_REPO,
# TOOL_UPDATE_PGVECTOR_VERSION, TOOL_UPDATE_PG_PREV_MIN_DAYS.

TU_BIN_DIR="${TOOL_UPDATE_BIN_DIR:-$HOME/.local/bin}"
TU_OPT_DIR="${TOOL_UPDATE_OPT_DIR:-$HOME/.local/opt}"
# Downloads and the throwaway cluster. Directly under /tmp by default: the
# cluster's unix-socket path is capped at 107 bytes.
TU_SCRATCH_ROOT="${TOOL_UPDATE_SCRATCH_ROOT:-/tmp}"
TU_RELEASES="${TOOL_UPDATE_RELEASES:-https://github.com}"
TU_SERVICE="${TOOL_UPDATE_SERVICE:-archon-serve.service}"
TU_HEALTH_URL="${TOOL_UPDATE_HEALTH_URL:-http://127.0.0.1:3090/}"
TU_HEALTH_TRIES="${TOOL_UPDATE_HEALTH_TRIES:-15}"
TU_HEALTH_INTERVAL="${TOOL_UPDATE_HEALTH_INTERVAL:-2}"
TU_PGVECTOR_REPO="${TOOL_UPDATE_PGVECTOR_REPO:-https://github.com/pgvector/pgvector.git}"
# Empty: the version the current tree's vector.control declares (0.8.1 today).
TU_PGVECTOR_VERSION="${TOOL_UPDATE_PGVECTOR_VERSION:-}"
# A .prev tree younger than this many days is left alone by the prune.
TU_PG_PREV_MIN_DAYS="${TOOL_UPDATE_PG_PREV_MIN_DAYS:-6}"
TU_ARCH="$(uname -m)"

APPLIED=()            # "tool outcome detail", in the order things happened
# shellcheck disable=SC2034  # read by tool-freshness.sh for apply_status
declare -A OUTCOME    # tool → upgraded|failed|skipped
TU_REASON=""          # set by the verify_* helpers on failure
TU_SCRATCH=""
TU_CLUSTER_TREE=""    # tree whose pg_ctl started the throwaway cluster, while it runs

record_apply() {  # tool outcome detail
  # shellcheck disable=SC2034  # read by tool-freshness.sh for apply_status
  OUTCOME[$1]="$2"
  APPLIED+=("$1 $2 $3")
  case "$2" in
    upgraded) log "UPGRADED $1 $3" ;;
    failed)   log "FAILED   $1 $3" ;;
    *)        log "skipped  $1 $3" ;;
  esac
}

tu_cleanup() {
  if [ -n "$TU_CLUSTER_TREE" ] && [ -d "$TU_SCRATCH/pgdata" ]; then
    "$TU_CLUSTER_TREE/bin/pg_ctl" -D "$TU_SCRATCH/pgdata" -m immediate -s stop >/dev/null 2>&1 || true
  fi
  [ -n "$TU_SCRATCH" ] && rm -rf "$TU_SCRATCH"
}

# tu_scratch_init — create the run's scratch directory (removed on exit, the
# throwaway cluster stopped first). Called once, outside any subshell, so the
# path and the trap stick.
tu_scratch_init() {
  TU_SCRATCH=$(mktemp -d "$TU_SCRATCH_ROOT/tool-update.XXXXXX") || return 1
  trap tu_cleanup EXIT
}

tu_scratch() { printf '%s' "$TU_SCRATCH"; }

# tu_scratch_dir <name> — print a fresh <scratch>/<name>, created.
tu_scratch_dir() {
  local d="$TU_SCRATCH/$1"
  [ -n "$TU_SCRATCH" ] && rm -rf "$d" && mkdir -p "$d" && printf '%s' "$d"
}

# fetch <url> <dest>
fetch() {
  log "fetch $1"
  curl -fsSL --max-time 600 -o "$2" "$1" 2>/dev/null
}

# verify_sha256 <dir> <file> <hex> — `sha256sum -c` against the one expected line.
verify_sha256() {
  local dir="$1" file="$2" hex="$3"
  [ -n "$hex" ] || return 1
  (cd "$dir" && printf '%s  %s\n' "$hex" "$file" | sha256sum -c --quiet - >/dev/null 2>&1)
}

# install_binary <tool> <src> <dest> <verify-fn> [args...] — install over dest,
# run the verifier, put the previous binary back when it fails.
install_binary() {
  local tool="$1" src="$2" dest="$3"; shift 3
  local prev="$dest.prev"
  rm -f "$prev"
  [ -e "$dest" ] && cp -p "$dest" "$prev"
  if ! install -m 0755 "$src" "$dest"; then
    [ -e "$prev" ] && mv -f "$prev" "$dest"
    record_apply "$tool" failed "install to $dest failed"
    return 1
  fi
  TU_REASON=""
  if ! "$@"; then
    log "$tool: post-install check failed ($TU_REASON) — restoring the previous binary"
    [ -e "$prev" ] && mv -f "$prev" "$dest"
    record_apply "$tool" failed "$TU_REASON (previous binary restored)"
    return 1
  fi
  rm -f "$prev"
}

# ---------------------------------------------------------------------------
# bun
# ---------------------------------------------------------------------------

# bun_blocked — exit 0, with why in TU_REASON, when bun must not be replaced
# right now. Live = an `archon workflow run` process (the pgrep guard the other
# cron scripts keep) or a run the server lists as running. Paused runs (durable
# waits) hold no process and are resumed by the server's continuation scan
# after the restart, so they only get logged.
bun_blocked() {
  TU_REASON=""
  if pgrep -f "archon workflow run" >/dev/null 2>&1; then
    TU_REASON="an 'archon workflow run' process is live"; return 0
  fi
  archon_runs_snapshot
  if ! archon_runs_known; then
    TU_REASON="could not list archon runs — not restarting the server blind"; return 0
  fi
  local running paused
  running=$(awk -F'\t' '$2 == "running"' "$ARCHON_RUNS_SNAPSHOT" | wc -l)
  paused=$(awk -F'\t' '$2 == "paused"' "$ARCHON_RUNS_SNAPSHOT" | wc -l)
  [ "$paused" -gt 0 ] && log "bun: $paused paused archon run(s) — durable waits, resumed by the server after restart"
  if [ "$running" -gt 0 ]; then
    TU_REASON="$running running archon run(s)"; return 0
  fi
  return 1
}

serve_healthy() {  # exit 0 when the health URL answers 200 within the poll window; prints the last code
  local i code=""
  for ((i = 1; i <= TU_HEALTH_TRIES; i++)); do
    code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$TU_HEALTH_URL" 2>/dev/null)
    [ "$code" = 200 ] && { echo 200; return 0; }
    sleep "$TU_HEALTH_INTERVAL"
  done
  echo "${code:-no answer}"
  return 1
}

upgrade_bun() {
  local from="${INSTALLED[bun]}" to="${LATEST[bun]}"
  if bun_blocked; then
    record_apply bun skipped "$from → $to: $TU_REASON — retry next week"
    return
  fi
  log "bun: upgrading $from → $to (bun upgrade)"
  local out rc now
  out=$(bun upgrade 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'
  now=$(bun --version 2>/dev/null | head -n1)
  if [ "$rc" -ne 0 ] || [ -z "$now" ] || version_lt "$now" "$to"; then
    record_apply bun failed "bun upgrade exit $rc, bun --version now '${now:-?}' (expected $to)"
    return
  fi
  # ARCHON_RUN_AS=archon (lib/run-as.sh): the server and every run use the
  # factory user's own bun, so upgrade that one too before the restart.
  if declare -F runas_archon >/dev/null && runas_archon; then
    local aout
    if ! aout=$(runas_wrapper bun-upgrade 2>&1); then
      record_apply bun failed "upgraded $from → $now for asiri, but archon's bun upgrade failed: $(tail -n 1 <<<"$aout")"
      return
    fi
    log "bun: archon's bun upgraded too"
  fi
  log "bun: now $now — restarting $TU_SERVICE"
  if ! { if declare -F runas_serve_restart >/dev/null; then runas_serve_restart "$TU_SERVICE"; else systemctl --user restart "$TU_SERVICE"; fi; } >/dev/null 2>&1; then
    record_apply bun failed "upgraded $from → $now but 'systemctl --user restart $TU_SERVICE' failed"
    notify "archon-serve restart FAILED after bun upgrade" \
      "bun $from → $now installed; systemctl --user restart $TU_SERVICE failed. Check: systemctl --user status $TU_SERVICE" \
      urgent rotating_light
    return
  fi
  local code
  if code=$(serve_healthy); then
    record_apply bun upgraded "$from → $now ($TU_SERVICE restarted, $TU_HEALTH_URL 200)"
  else
    record_apply bun failed "upgraded $from → $now but $TU_HEALTH_URL answered $code after restarting $TU_SERVICE"
    notify "archon-serve unhealthy after bun upgrade" \
      "bun $from → $now; $TU_SERVICE restarted but $TU_HEALTH_URL answered $code. Check: journalctl --user -u $TU_SERVICE -n 50" \
      urgent rotating_light
  fi
}

# ---------------------------------------------------------------------------
# gh
# ---------------------------------------------------------------------------

verify_gh() {  # <expected version>
  local v
  v=$("$TU_BIN_DIR/gh" --version 2>/dev/null | awk 'NR==1 { print $3 }')
  [ "$v" = "$1" ] || { TU_REASON="gh --version says '${v:-?}', expected $1"; return 1; }
  "$TU_BIN_DIR/gh" auth status >/dev/null 2>&1 || { TU_REASON="gh auth status failed with gh $v"; return 1; }
}

upgrade_gh() {
  local from="${INSTALLED[gh]}" to="${LATEST[gh]}" tag="${LATEST_TAG[gh]}"
  [ "$TU_ARCH" = x86_64 ] || { record_apply gh skipped "no linux_amd64 build for $TU_ARCH"; return; }
  local asset="gh_${to}_linux_amd64.tar.gz" base="$TU_RELEASES/cli/cli/releases/download/$tag" dir
  if ! dir=$(tu_scratch_dir gh); then record_apply gh failed "could not create a scratch dir under $TU_SCRATCH_ROOT"; return; fi
  log "gh: upgrading $from → $to"
  fetch "$base/$asset" "$dir/$asset" || { record_apply gh failed "download failed: $base/$asset"; return; }
  fetch "$base/gh_${to}_checksums.txt" "$dir/checksums.txt" || { record_apply gh failed "download failed: $base/gh_${to}_checksums.txt"; return; }
  local hex; hex=$(awk -v f="$asset" '$2 == f { print $1; exit }' "$dir/checksums.txt")
  if ! verify_sha256 "$dir" "$asset" "$hex"; then
    record_apply gh failed "sha256 mismatch for $asset against gh_${to}_checksums.txt — not installed"
    return
  fi
  log "gh: sha256 OK"
  tar xzf "$dir/$asset" -C "$dir" 2>/dev/null || { record_apply gh failed "could not unpack $asset"; return; }
  install_binary gh "$dir/gh_${to}_linux_amd64/bin/gh" "$TU_BIN_DIR/gh" verify_gh "$to" \
    && record_apply gh upgraded "$from → $to"
}

# ---------------------------------------------------------------------------
# ShellCheck
# ---------------------------------------------------------------------------

verify_shellcheck() {  # <expected version>
  local v
  v=$("$TU_BIN_DIR/shellcheck" --version 2>/dev/null | awk '$1 == "version:" { print $2; exit }')
  [ "$v" = "$1" ] || { TU_REASON="shellcheck --version says '${v:-?}', expected $1"; return 1; }
}

upgrade_shellcheck() {
  local from="${INSTALLED[shellcheck]}" to="${LATEST[shellcheck]}" tag="${LATEST_TAG[shellcheck]}"
  [ "$TU_ARCH" = x86_64 ] || { record_apply shellcheck skipped "no linux.x86_64 build for $TU_ARCH"; return; }
  local asset="shellcheck-$tag.linux.x86_64.tar.xz" base="$TU_RELEASES/koalaman/shellcheck/releases/download/$tag" dir
  if ! dir=$(tu_scratch_dir shellcheck); then record_apply shellcheck failed "could not create a scratch dir under $TU_SCRATCH_ROOT"; return; fi
  log "shellcheck: upgrading $from → $to"
  local hex
  hex=$(gh api "repos/koalaman/shellcheck/releases/tags/$tag" \
    --jq ".assets[] | select(.name == \"$asset\") | .digest" 2>/dev/null | sed -n 's/^sha256://p' | head -n1)
  if [ -z "$hex" ]; then
    record_apply shellcheck failed "the $tag release lists no sha256 digest for $asset — not installed"
    return
  fi
  fetch "$base/$asset" "$dir/$asset" || { record_apply shellcheck failed "download failed: $base/$asset"; return; }
  if ! verify_sha256 "$dir" "$asset" "$hex"; then
    record_apply shellcheck failed "sha256 mismatch for $asset against the release asset digest — not installed"
    return
  fi
  log "shellcheck: sha256 OK"
  tar xJf "$dir/$asset" -C "$dir" 2>/dev/null || { record_apply shellcheck failed "could not unpack $asset"; return; }
  install_binary shellcheck "$dir/shellcheck-$tag/shellcheck" "$TU_BIN_DIR/shellcheck" verify_shellcheck "$to" \
    && record_apply shellcheck upgraded "$from → $to"
}

# ---------------------------------------------------------------------------
# PostgreSQL client+server tree (pg_dump / pg_restore)
# ---------------------------------------------------------------------------

# pg_prune_prev — drop postgresql-*.prev trees this script parked at least
# TU_PG_PREV_MIN_DAYS ago (the marker file is written at swap time). A .prev
# without the marker is not ours and is left alone.
pg_prune_prev() {
  local prev marker
  for prev in "$TU_OPT_DIR"/postgresql-*.prev; do
    [ -d "$prev" ] || continue
    marker="$prev/.tool-update-swapped-at"
    if [ ! -f "$marker" ]; then
      log "leaving $prev alone (no swap marker — not written by this script)"
    elif [ -n "$(find "$marker" -mtime +"$((TU_PG_PREV_MIN_DAYS - 1))" 2>/dev/null)" ]; then
      rm -rf "$prev" && log "removed $prev (previous PostgreSQL tree, kept one cycle)"
    else
      log "keeping $prev (swapped in $(date -r "$marker" +%F), removed after $TU_PG_PREV_MIN_DAYS days)"
    fi
  done
}

# pg_build_pgvector <new tree> <current tree> — the README recipe, into the
# new tree, at the version the current tree's vector.control declares.
pg_build_pgvector() {
  local tree="$1" current="$2" pgv="$TU_PGVECTOR_VERSION" src
  [ -n "$pgv" ] || pgv=$(sed -n "s/^default_version = '\([^']*\)'.*/\1/p" "$current/share/extension/vector.control" 2>/dev/null | head -n1)
  [ -n "$pgv" ] || pgv=0.8.1
  src="$(tu_scratch)/pgvector"
  log "pg: building pgvector v$pgv into $tree"
  rm -rf "$src"
  if ! git clone -q --depth 1 --branch "v$pgv" "$TU_PGVECTOR_REPO" "$src" 2>/dev/null; then
    TU_REASON="git clone of pgvector v$pgv failed"; return 1
  fi
  if ! make -s -C "$src" PG_CONFIG="$tree/bin/pg_config" > "$src/build.log" 2>&1 \
     || ! make -s -C "$src" install PG_CONFIG="$tree/bin/pg_config" >> "$src/build.log" 2>&1; then
    TU_REASON="pgvector v$pgv build failed: $(tail -n 3 "$src/build.log" | tr '\n' ' ')"; return 1
  fi
  if [ ! -f "$tree/lib/vector.so" ] || [ ! -f "$tree/share/extension/vector.control" ]; then
    TU_REASON="pgvector v$pgv build left no lib/vector.so + share/extension/vector.control in $tree"; return 1
  fi
  PG_PGVECTOR_BUILT="$pgv"
}

# pg_selftest <tree> — the tree must link, initdb, start (socket only),
# CREATE EXTENSION vector and stop. Reason in TU_REASON on failure.
pg_selftest() {
  local tree="$1" b scratch
  for b in initdb pg_ctl psql pg_dump pg_restore pg_config; do
    [ -x "$tree/bin/$b" ] || { TU_REASON="$tree/bin/$b missing or not executable"; return 1; }
  done
  if command -v ldd >/dev/null 2>&1 && ldd "$tree/bin/pg_dump" 2>/dev/null | grep -q 'not found'; then
    TU_REASON="ldd $tree/bin/pg_dump: $(ldd "$tree/bin/pg_dump" 2>/dev/null | grep 'not found' | tr -s '[:space:]' ' ')"; return 1
  fi
  scratch=$(tu_scratch)
  if [ "${#scratch}" -gt 90 ]; then
    TU_REASON="$scratch is too long for a unix socket path — set TOOL_UPDATE_SCRATCH_ROOT to a short directory"; return 1
  fi
  local data="$scratch/pgdata" port=$(( 20000 + RANDOM % 40000 ))
  rm -rf "$data"
  if ! "$tree/bin/initdb" -D "$data" -A trust -U postgres -E UTF8 --locale=C --no-sync > "$scratch/initdb.log" 2>&1; then
    TU_REASON="initdb failed: $(tail -n 3 "$scratch/initdb.log" | tr '\n' ' ')"; return 1
  fi
  TU_CLUSTER_TREE="$tree"
  if ! "$tree/bin/pg_ctl" -D "$data" -w -s -l "$scratch/postgres.log" \
      -o "-k $scratch -c listen_addresses='' -p $port -c fsync=off -c synchronous_commit=off -c full_page_writes=off" \
      start > "$scratch/pg_ctl.log" 2>&1; then
    TU_REASON="pg_ctl start failed: $(tail -n 3 "$scratch/postgres.log" 2>/dev/null | tr '\n' ' ')"
    TU_CLUSTER_TREE=""; return 1
  fi
  local rc=0
  if ! "$tree/bin/psql" -X -q -v ON_ERROR_STOP=1 -h "$scratch" -p "$port" -U postgres -d postgres \
      -c 'CREATE EXTENSION vector' -c "SELECT '[1,2,3]'::vector" > "$scratch/psql.log" 2>&1; then
    TU_REASON="CREATE EXTENSION vector failed on the new tree: $(tail -n 3 "$scratch/psql.log" | tr '\n' ' ')"; rc=1
  fi
  "$tree/bin/pg_ctl" -D "$data" -m immediate -s stop >/dev/null 2>&1 || { [ "$rc" -eq 0 ] && { TU_REASON="pg_ctl stop failed"; rc=1; }; }
  TU_CLUSTER_TREE=""
  rm -rf "$data"
  return "$rc"
}

# pg_link <name> <tree> — ~/.local/bin/<name> → the tree's bin/<name>; relative
# (as the README installs them) when the bin and opt dirs are siblings.
pg_link() {
  local target="$2/bin/$1"
  [ "$TU_OPT_DIR" = "$(dirname "$TU_BIN_DIR")/opt" ] && target="../opt/$(basename "$2")/bin/$1"
  ln -sfn "$target" "$TU_BIN_DIR/$1"
}

upgrade_pg() {
  local from="${INSTALLED[pg_dump]}" to="${LATEST[pg_dump]}" tag="${LATEST_TAG[pg_dump]}"
  local major="${from%%.*}"
  if [ "${to%%.*}" != "$major" ]; then
    record_apply pg_dump skipped "$from → $to crosses a major — manual (README, pg_dump section)"
    return
  fi
  [ "$TU_ARCH" = x86_64 ] || { record_apply pg_dump skipped "no x86_64-unknown-linux-gnu build for $TU_ARCH"; return; }
  local tree="$TU_OPT_DIR/postgresql-$major" new="$TU_OPT_DIR/postgresql-$major.new" prev="$TU_OPT_DIR/postgresql-$major.prev"
  if [ ! -d "$tree" ]; then
    record_apply pg_dump failed "$tree is not a directory — the layout the README describes is missing"
    return
  fi
  local asset="postgresql-$tag-x86_64-unknown-linux-gnu.tar.gz" base="$TU_RELEASES/theseus-rs/postgresql-binaries/releases/download/$tag" dir
  if ! dir=$(tu_scratch_dir pg); then record_apply pg_dump failed "could not create a scratch dir under $TU_SCRATCH_ROOT"; return; fi
  log "pg_dump: upgrading $from → $to ($tree)"
  fetch "$base/$asset" "$dir/$asset" || { record_apply pg_dump failed "download failed: $base/$asset"; return; }
  fetch "$base/$asset.sha256" "$dir/$asset.sha256" || { record_apply pg_dump failed "download failed: $base/$asset.sha256"; return; }
  local hex; hex=$(awk 'NR == 1 { print $1 }' "$dir/$asset.sha256")
  if ! verify_sha256 "$dir" "$asset" "$hex"; then
    record_apply pg_dump failed "sha256 mismatch for $asset against $asset.sha256 — not installed"
    return
  fi
  log "pg_dump: sha256 OK — unpacking to $new"
  rm -rf "$new"
  if ! mkdir -p "$new" || ! tar xzf "$dir/$asset" -C "$new" --strip-components=1 2>/dev/null; then
    rm -rf "$new"; record_apply pg_dump failed "could not unpack $asset into $new"; return
  fi
  PG_PGVECTOR_BUILT=""
  if ! pg_build_pgvector "$new" "$tree"; then
    rm -rf "$new"; record_apply pg_dump failed "$TU_REASON — $tree untouched"; return
  fi
  if ! pg_selftest "$new"; then
    rm -rf "$new"; record_apply pg_dump failed "new tree failed its self-test: $TU_REASON — $tree untouched"; return
  fi
  log "pg_dump: new tree passed (initdb, start, CREATE EXTENSION vector, stop) — swapping"
  rm -rf "$prev"
  if ! mv "$tree" "$prev"; then
    rm -rf "$new"; record_apply pg_dump failed "could not move $tree aside — untouched"; return
  fi
  if ! mv "$new" "$tree"; then
    mv "$prev" "$tree"; rm -rf "$new"
    record_apply pg_dump failed "could not move $new into place — previous tree restored"; return
  fi
  pg_link pg_dump "$tree"; pg_link pg_restore "$tree"
  local v
  v=$("$TU_BIN_DIR/pg_dump" --version 2>/dev/null | awk 'NR == 1 { print $NF }')
  if [ "$v" != "$to" ] || ! "$TU_BIN_DIR/pg_restore" --version >/dev/null 2>&1; then
    log "pg_dump: post-swap check failed (pg_dump --version says '${v:-?}', expected $to) — restoring the previous tree"
    rm -rf "$new"; mv "$tree" "$new"; mv "$prev" "$tree"; rm -rf "$new"
    pg_link pg_dump "$tree"; pg_link pg_restore "$tree"
    record_apply pg_dump failed "pg_dump --version said '${v:-?}' after the swap, expected $to — previous tree restored"
    return
  fi
  date -Is > "$prev/.tool-update-swapped-at"
  record_apply pg_dump upgraded "$from → $to (pgvector v$PG_PGVECTOR_BUILT rebuilt; old tree kept as $(basename "$prev") for one cycle)"
}

# ---------------------------------------------------------------------------

# apply_updates — upgrade, in this order, every tool the check found behind.
apply_updates() {
  pg_prune_prev
  local tool scratch_ok=1
  tu_scratch_init || scratch_ok=0
  for tool in bun gh shellcheck pg_dump; do
    [ "${STATE[$tool]:-}" = behind ] || continue
    if [ "$scratch_ok" = 0 ]; then
      record_apply "$tool" failed "could not create a scratch directory under $TU_SCRATCH_ROOT"
      continue
    fi
    case "$tool" in
      bun)        upgrade_bun ;;
      gh)         upgrade_gh ;;
      shellcheck) upgrade_shellcheck ;;
      pg_dump)    upgrade_pg ;;
    esac
  done
}
