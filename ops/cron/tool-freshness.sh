#!/usr/bin/env bash
# tool-freshness.sh — weekly installed-vs-latest check for the tools the
# pipeline depends on, and (with --apply) the upgrade of the user-level ones.
#
#   bun        `bun --version`             vs GitHub oven-sh/bun latest release
#   gh         `gh --version`              vs cli/cli latest release
#   ShellCheck `shellcheck --version`      vs koalaman/shellcheck latest release
#   uv         `uv --version`              vs the version the tracked channel of the astral-uv
#                                          snap offers (`snap info astral-uv`) — the store lags
#                                          GitHub by weeks, so a GitHub compare would flag it
#                                          every week with nothing to do; this only flags a
#                                          refresh that is actually pending
#   node       `node --version`            vs the newest LTS line in nodejs.org/dist/index.json;
#                                          also flagged when the installed major is past its
#                                          end-of-life date in nodejs/Release schedule.json
#   archon     `git describe` of the checkout at $ARCHON_DIR vs the upstream project's
#                                          latest release (see check_archon for the branch gap)
#   pg_dump    `~/.local/bin/pg_dump --version` vs the newest release on the same major line
#                                          of theseus-rs/postgresql-binaries (the portable
#                                          build ops/cron/README.md installs from)
#
# GitHub lookups go through `gh api` (already authenticated). The full result —
# behind, current and could-not-check — is written to
# ~/.archon/pipeline-health-state/tool-freshness every run. Lookups that fail
# are logged and recorded as unknown, never ntfy'd: a flaky endpoint is not a
# stale tool.
#
# Without --apply nothing is upgraded: one ntfy, only when something is behind.
# With --apply the tools that are behind AND user-level — bun, gh, shellcheck,
# pg_dump (the postgresql-17 tree), in that order — are upgraded by
# lib/tool-update.sh (checksums verified, each install checked, the previous
# binary/tree restored when a check fails; bun is skipped while an archon run
# is live because archon-serve must be restarted afterwards). uv (snap), node
# (apt) and archon are never touched. The check then runs again and one ntfy
# summarises `upgraded: …`, `failed: …`, `skipped: …` and `still behind
# (manual): …` — silent when everything is current and nothing happened.
# Every apply outcome lands in the status file as an `apply:` line. A lock
# file keeps overlapping runs apart.
#
# Crontab:
#   0 9 * * 1 <repo>/ops/cron/tool-freshness.sh --apply >> ~/.local/state/archon-cron/logs/tool-freshness.log 2>&1
#
# Overrides (tests): TOOL_FRESHNESS_STATE_DIR, TOOL_FRESHNESS_LOCK,
# TOOL_FRESHNESS_ARCHON_DIR, TOOL_FRESHNESS_ARCHON_REMOTE,
# TOOL_FRESHNESS_ARCHON_TRACK (release|branch), TOOL_FRESHNESS_PG_DUMP, TOOL_FRESHNESS_UV_SNAP,
# TOOL_FRESHNESS_NODE_INDEX_URL, TOOL_FRESHNESS_NODE_SCHEDULE_URL,
# TOOL_FRESHNESS_TODAY (YYYY-MM-DD); the TOOL_UPDATE_* ones in lib/tool-update.sh.

set -uo pipefail

# cron's PATH is /usr/bin:/bin; bun, gh, shellcheck and pg_dump are user-level
# installs and uv is a snap.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/snap/bin:$PATH"

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
  esac
done

# NTFY_TOPIC loaded from secrets.env. Fail loud if unset.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set — populate $SECRETS_FILE}"
LOG_PREFIX="[tool-freshness]"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-as.sh
source "$SCRIPT_DIR/lib/run-as.sh"
STATE_DIR="${TOOL_FRESHNESS_STATE_DIR:-$HOME/.archon/pipeline-health-state}"
STATUS_FILE="$STATE_DIR/tool-freshness"
LOCK_FILE="${TOOL_FRESHNESS_LOCK:-$STATE_DIR/tool-freshness.lock}"
ARCHON_DIR="${TOOL_FRESHNESS_ARCHON_DIR:-/mnt/ext-fast/archon}"
# Which remote is "the project": that checkout is a fork (origin = the
# operator's own GitHub fork, upstream = coleam00/archon), so by default the
# upstream remote is used when there is one.
ARCHON_REMOTE="${TOOL_FRESHNESS_ARCHON_REMOTE:-}"
# release: behind when the project's latest release tag is not in HEAD (default).
# branch:  behind when the remote's default branch has commits HEAD lacks —
#          upstream's default branch is `dev`, so this fires every week.
ARCHON_TRACK="${TOOL_FRESHNESS_ARCHON_TRACK:-release}"
PG_DUMP_BIN="${TOOL_FRESHNESS_PG_DUMP:-$HOME/.local/bin/pg_dump}"
UV_SNAP="${TOOL_FRESHNESS_UV_SNAP:-astral-uv}"
NODE_INDEX_URL="${TOOL_FRESHNESS_NODE_INDEX_URL:-https://nodejs.org/dist/index.json}"
NODE_SCHEDULE_URL="${TOOL_FRESHNESS_NODE_SCHEDULE_URL:-https://raw.githubusercontent.com/nodejs/Release/main/schedule.json}"
TODAY="${TOOL_FRESHNESS_TODAY:-$(date +%F)}"

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

# Same ntfy convention as pipeline-health-cron.sh: --fail so a 5xx counts as
# undelivered and shows up in the log.
notify_checked() {
  local title="$1" msg="$2" priority="${3:-default}" tags="${4:-robot}"
  curl -s --fail -o /dev/null \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
    -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null
}
notify() { notify_checked "$@" || true; }

# One run at a time: an --apply run swaps binaries and restarts the server,
# and a second one overlapping it (a hand run during the cron one) must not.
mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another tool-freshness run holds $LOCK_FILE — exiting"
  exit 0
fi

BEHIND=()    # "tool installed → latest[ (note)]"
CURRENT=()   # "tool installed[ (note)]"
UNKNOWN=()   # "tool: reason"
# Per tool, read by lib/tool-update.sh under --apply.
# shellcheck disable=SC2034
declare -A STATE INSTALLED LATEST LATEST_TAG

reset_results() {
  BEHIND=(); CURRENT=(); UNKNOWN=()
  STATE=(); INSTALLED=(); LATEST=(); LATEST_TAG=()
}

record_behind() {  # tool installed latest [note]
  local line="$1 $2 → $3"; [ -n "${4:-}" ] && line="$line ($4)"
  BEHIND+=("$line"); STATE[$1]=behind; log "BEHIND  $line"
}
record_current() {  # tool installed [note]
  local line="$1 $2"; [ -n "${3:-}" ] && line="$line ($3)"
  CURRENT+=("$line"); STATE[$1]=current; log "current $line"
}
record_unknown() {  # tool reason
  UNKNOWN+=("$1: $2"); STATE[$1]=unknown; log "unknown $1: $2"
}

# version_lt <a> <b> — 0 when a sorts strictly before b (sort -V: 1.9 < 1.10).
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# strip_tag <tag> — release tag → bare version: v2.101.0 → 2.101.0, bun-v1.4.2 → 1.4.2.
strip_tag() { local v="$1"; v="${v#bun-}"; v="${v#v}"; printf '%s' "$v"; }

# gh_latest_tag <owner/repo> — tag name of the latest release, "" on failure.
gh_latest_tag() {
  gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null || true
}

# compare <tool> <installed> <latest> [note] — files the tool under one bucket.
compare() {
  local tool="$1" installed="$2" latest="$3" note="${4:-}"
  INSTALLED[$tool]="$installed"; LATEST[$tool]="$latest"
  if [ -z "$installed" ]; then record_unknown "$tool" "not installed or --version unreadable"
  elif [ -z "$latest" ]; then record_unknown "$tool" "could not look up the latest release (installed $installed)"
  elif version_lt "$installed" "$latest"; then record_behind "$tool" "$installed" "$latest" "$note"
  else record_current "$tool" "$installed" "$note"
  fi
}

# compare_release <tool> <installed> <owner/repo> — compare against the repo's
# latest release, remembering the raw tag for the download URL.
compare_release() {
  local tag; tag=$(gh_latest_tag "$3")
  LATEST_TAG[$1]="$tag"
  compare "$1" "$2" "$(strip_tag "$tag")"
}

check_bun() {
  compare_release bun "$(bun --version 2>/dev/null | head -n1)" oven-sh/bun
}

check_gh() {
  compare_release gh "$(gh --version 2>/dev/null | awk 'NR==1 { print $3 }')" cli/cli
}

check_shellcheck() {
  compare_release shellcheck "$(shellcheck --version 2>/dev/null | awk '$1 == "version:" { print $2; exit }')" koalaman/shellcheck
}

# uv: the snap's tracked channel (`tracking: latest/stable`), then that
# channel's version from the same listing. `snap` itself keeps it current;
# behind here means a refresh is pending (snap refresh --list would show it).
check_uv() {
  local installed; installed=$(uv --version 2>/dev/null | awk 'NR==1 { print $2 }')
  local info channel latest=""
  info=$(snap info "$UV_SNAP" 2>/dev/null) || info=""
  channel=$(printf '%s\n' "$info" | awk '$1 == "tracking:" { print $2; exit }')
  [ -n "$channel" ] || channel=latest/stable
  latest=$(printf '%s\n' "$info" | awk -v ch="$channel:" '$1 == ch && $2 != "--" { print $2; exit }')
  compare uv "$installed" "$latest" "${latest:+snap $UV_SNAP $channel}"
}

# Newest LTS line from index.json (entries are newest-first; `lts` is the
# codename for LTS releases and false otherwise), and the installed major's
# end-of-life date from the release schedule. Past-EOL is behind even when the
# installed line is newer than the LTS one (a Current line that aged out).
check_node() {
  local installed; installed=$(node --version 2>/dev/null | head -n1)
  local lts latest codename
  lts=$(curl -fsS --max-time 30 "$NODE_INDEX_URL" 2>/dev/null | python3 -c '
import json, sys
try:
    entries = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
lts = [e for e in entries if isinstance(e, dict) and e.get("lts")]
if lts:
    print(lts[0]["version"], lts[0]["lts"])
' 2>/dev/null) || lts=""
  latest="${lts%% *}"; codename="${lts#* }"
  local note="" eol=""
  if [ -n "$installed" ]; then
    local major="${installed%%.*}"
    eol=$(curl -fsS --max-time 30 "$NODE_SCHEDULE_URL" 2>/dev/null | python3 -c '
import json, sys
try:
    sched = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
print(sched.get(sys.argv[1], {}).get("end", ""))
' "$major" 2>/dev/null) || eol=""
    if [ -n "$eol" ] && [[ "$eol" < "$TODAY" ]]; then
      note="$major EOL since $eol"
    fi
  fi
  [ -n "$latest" ] && [ -n "$codename" ] && note="LTS $codename${note:+; $note}"
  if [ -n "$installed" ] && [ -n "$note" ] && [[ "$note" == *EOL* ]] && ! version_lt "$installed" "${latest:-$installed}"; then
    INSTALLED[node]="$installed"; LATEST[node]="$latest"
    record_behind node "$installed" "${latest:-?}" "$note"
    return
  fi
  compare node "$installed" "$latest" "$note"
}

# pg_dump: the pinned user-level build. Compared on the installed major line
# (17.x today, 18.x once the servers move), on major.minor: the binaries repo
# tags 17.11.0 for PostgreSQL 17.11, and `pg_dump --version` prints 17.11.
check_pg_dump() {
  local installed; installed=$("$PG_DUMP_BIN" --version 2>/dev/null | awk 'NR==1 { print $NF }')
  local major="${installed%%.*}" tag="" latest=""
  if [ -n "$major" ]; then
    tag=$(gh api "repos/theseus-rs/postgresql-binaries/releases?per_page=100" --jq '.[].tag_name' 2>/dev/null \
      | grep -E "^${major}\.[0-9]+\.[0-9]+$" | sort -V | tail -n1) || tag=""
    latest="${tag%.*}"
  fi
  LATEST_TAG[pg_dump]="$tag"
  compare pg_dump "$installed" "$latest" "${latest:+theseus-rs/postgresql-binaries $major.x}"
}

# archon: the checkout at $ARCHON_DIR. `git fetch` only updates remote-tracking
# refs; the working tree, branches and index are never touched.
check_archon() {
  if [ ! -d "$ARCHON_DIR/.git" ]; then
    record_unknown archon "no git checkout at $ARCHON_DIR"; return
  fi
  local remote="$ARCHON_REMOTE"
  if [ -z "$remote" ]; then
    if git -C "$ARCHON_DIR" remote 2>/dev/null | grep -qx upstream; then remote=upstream; else remote=origin; fi
  fi
  local installed; installed=$(git -C "$ARCHON_DIR" describe --tags --always 2>/dev/null)
  if ! git -C "$ARCHON_DIR" fetch -q "$remote" 2>/dev/null; then
    record_unknown archon "git fetch $remote failed (installed ${installed:-?})"; return
  fi
  local branch
  branch=$(git -C "$ARCHON_DIR" ls-remote --symref "$remote" HEAD 2>/dev/null \
    | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')
  local behind=""
  if [ -n "$branch" ]; then
    behind=$(git -C "$ARCHON_DIR" rev-list --count "HEAD..$remote/$branch" 2>/dev/null) || behind=""
  fi
  local gap=""
  [ -n "$behind" ] && gap="$remote/$branch is $behind commit(s) ahead of HEAD"

  # owner/repo from the remote URL, for the release lookup.
  local url slug tag
  url=$(git -C "$ARCHON_DIR" remote get-url "$remote" 2>/dev/null)
  slug=$(printf '%s' "$url" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##; s#/$##')
  tag=$(gh api "repos/$slug/releases/latest" --jq .tag_name 2>/dev/null) || tag=""

  case "$ARCHON_TRACK" in
    branch)
      if [ -z "$behind" ]; then record_unknown archon "could not read $remote's default branch (installed ${installed:-?})"
      elif [ "$behind" -gt 0 ]; then record_behind archon "$installed" "$remote/$branch" "$behind commit(s) behind"
      else record_current archon "$installed" "$remote/$branch"
      fi ;;
    *)
      if [ -z "$tag" ]; then record_unknown archon "could not look up the latest release of $slug (installed ${installed:-?}${gap:+; $gap})"; return; fi
      # The release is "installed" when its commit is in HEAD's history.
      local tag_sha
      tag_sha=$(git -C "$ARCHON_DIR" ls-remote "$remote" "refs/tags/$tag^{}" "refs/tags/$tag" 2>/dev/null | awk 'NR==1 { print $1 }')
      if [ -n "$tag_sha" ] && git -C "$ARCHON_DIR" merge-base --is-ancestor "$tag_sha" HEAD 2>/dev/null; then
        record_current archon "$installed" "$tag${gap:+; $gap}"
      else
        record_behind archon "$installed" "$tag" "$gap"
      fi ;;
  esac
}

run_checks() {
  reset_results
  check_bun
  check_gh
  check_shellcheck
  check_uv
  check_node
  check_archon
  check_pg_dump
}

# join <sep> <items...>
join() { local sep="$1" out="" x; shift; for x in "$@"; do out="${out:+$out$sep}$x"; done; printf '%s' "$out"; }

# ----------------------------------------------------------------------------
if [ "$APPLY" = 1 ]; then log "=== tool freshness (apply) ==="; else log "=== tool freshness ==="; fi
run_checks

APPLIED=()
declare -A OUTCOME
if [ "$APPLY" = 1 ]; then
  # shellcheck source=lib/archon-active-runs.sh
  . "$SCRIPT_DIR/lib/archon-active-runs.sh"
  # shellcheck source=lib/tool-update.sh
  . "$SCRIPT_DIR/lib/tool-update.sh"
  apply_updates
  if [ "${#APPLIED[@]}" -gt 0 ]; then
    log "=== re-checking after apply ==="
    run_checks
  fi
fi

{
  echo "checked_at=$(date -Is)"
  if [ "${#BEHIND[@]}" -gt 0 ]; then echo "status=behind"; else echo "status=current"; fi
  echo "behind_count=${#BEHIND[@]}"
  echo "unknown_count=${#UNKNOWN[@]}"
  if [ "$APPLY" = 1 ]; then
    apply_status=ok
    for t in "${!OUTCOME[@]}"; do [ "${OUTCOME[$t]}" = failed ] && apply_status=failed; done
    echo "apply_status=$apply_status"
    echo "apply_count=${#APPLIED[@]}"
    for l in "${APPLIED[@]}"; do echo "apply: $l"; done
  fi
  for l in "${BEHIND[@]}";  do echo "behind: $l"; done
  for l in "${CURRENT[@]}"; do echo "current: $l"; done
  for l in "${UNKNOWN[@]}"; do echo "unknown: $l"; done
} > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"

could_not_check=""
[ "${#UNKNOWN[@]}" -gt 0 ] && could_not_check="(could not check: $(join ', ' "${UNKNOWN[@]%%:*}"))"

if [ "$APPLY" = 1 ]; then
  upgraded=(); failed=(); skipped=()
  for l in "${APPLIED[@]}"; do
    t="${l%% *}"; rest="${l#* }"; outcome="${rest%% *}"; detail="${rest#* }"
    case "$outcome" in
      upgraded) upgraded+=("$t ${detail%% (*}") ;;
      failed)   failed+=("$t ($detail)") ;;
      *)        skipped+=("$t ($detail)") ;;
    esac
  done
  if [ "${#APPLIED[@]}" -eq 0 ] && [ "${#BEHIND[@]}" -eq 0 ]; then
    log "everything current (${#CURRENT[@]} checked, ${#UNKNOWN[@]} unknown), nothing to apply — no ntfy"
  else
    body=""
    [ "${#upgraded[@]}" -gt 0 ] && body="upgraded: $(join ', ' "${upgraded[@]}")"
    [ "${#failed[@]}" -gt 0 ]   && body="${body:+$body$'\n'}failed: $(join ', ' "${failed[@]}")"
    [ "${#skipped[@]}" -gt 0 ]  && body="${body:+$body$'\n'}skipped: $(join ', ' "${skipped[@]}")"
    [ "${#BEHIND[@]}" -gt 0 ]   && body="${body:+$body$'\n'}still behind (manual): $(join ', ' "${BEHIND[@]}")"
    [ -n "$could_not_check" ]   && body="${body:+$body$'\n'}$could_not_check"
    if [ "${#failed[@]}" -gt 0 ]; then
      title="Tool update FAILED: $(join ', ' "${failed[@]%% *}")"; priority=high; tags=warning
    elif [ "${#upgraded[@]}" -gt 0 ]; then
      title="Tools upgraded: $(join ', ' "${upgraded[@]%% *}")"; priority=default; tags=package
    else
      behind_names=()
      for l in "${BEHIND[@]}" "${skipped[@]}"; do
        case " ${behind_names[*]-} " in *" ${l%% *} "*) ;; *) behind_names+=("${l%% *}") ;; esac
      done
      title="Tools behind: $(join ', ' "${behind_names[@]}")"; priority=default; tags=package
    fi
    log "${#upgraded[@]} upgraded, ${#failed[@]} failed, ${#skipped[@]} skipped, ${#BEHIND[@]} still behind — ntfying"
    if notify_checked "$title" "$body" "$priority" "$tags"; then
      log "ntfy delivered"
    else
      log "ntfy FAILED (curl exit $?) — see $STATUS_FILE"
    fi
  fi
elif [ "${#BEHIND[@]}" -gt 0 ]; then
  names=""
  for l in "${BEHIND[@]}"; do names="${names:+$names, }${l%% *}"; done
  body=$(printf '%s\n' "${BEHIND[@]}")
  [ -n "$could_not_check" ] && body="$body"$'\n'"$could_not_check"
  log "${#BEHIND[@]} tool(s) behind — ntfying: $names"
  if notify_checked "Tools behind: $names" "$body" default package; then
    log "ntfy delivered"
  else
    log "ntfy FAILED (curl exit $?) — see $STATUS_FILE"
  fi
else
  log "everything current (${#CURRENT[@]} checked, ${#UNKNOWN[@]} unknown) — no ntfy"
fi
log "=== done ==="
