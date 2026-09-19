#!/usr/bin/env bash
# tool-freshness.sh — weekly installed-vs-latest report for the tools the
# pipeline depends on. One ntfy, only when something is behind:
#
#   bun      `bun --version`            vs GitHub oven-sh/bun latest release
#   gh       `gh --version`             vs cli/cli latest release
#   uv       `uv --version`             vs astral-sh/uv latest release
#   node     `node --version`           vs the newest LTS line in nodejs.org/dist/index.json;
#                                       also flagged when the installed major is past its
#                                       end-of-life date in nodejs/Release schedule.json
#   archon   `git describe` of the checkout at $ARCHON_DIR vs the upstream project's
#                                       latest release (see check_archon for the branch gap)
#   pg_dump  `~/.local/bin/pg_dump --version` vs the newest release on the same major line
#                                       of theseus-rs/postgresql-binaries (the portable
#                                       build ops/cron/README.md installs from)
#
# GitHub lookups go through `gh api` (already authenticated). The full result —
# behind, current and could-not-check — is written to
# ~/.archon/pipeline-health-state/tool-freshness every run. Lookups that fail
# are logged and recorded as unknown, never ntfy'd: a flaky endpoint is not a
# stale tool. Nothing here upgrades anything; see README.md for how to.
#
# Crontab:
#   0 9 * * 1 <repo>/ops/cron/tool-freshness.sh >> ~/.local/state/archon-cron/logs/tool-freshness.log 2>&1
#
# Overrides (tests): TOOL_FRESHNESS_STATE_DIR, TOOL_FRESHNESS_ARCHON_DIR,
# TOOL_FRESHNESS_ARCHON_REMOTE, TOOL_FRESHNESS_ARCHON_TRACK (release|branch),
# TOOL_FRESHNESS_PG_DUMP, TOOL_FRESHNESS_NODE_INDEX_URL,
# TOOL_FRESHNESS_NODE_SCHEDULE_URL, TOOL_FRESHNESS_TODAY (YYYY-MM-DD).

set -uo pipefail

# cron's PATH is /usr/bin:/bin; bun, gh and pg_dump are user-level installs and
# uv is a snap.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/snap/bin:$PATH"

# NTFY_TOPIC loaded from secrets.env. Fail loud if unset.
SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set — populate $SECRETS_FILE}"
LOG_PREFIX="[tool-freshness]"

STATE_DIR="${TOOL_FRESHNESS_STATE_DIR:-$HOME/.archon/pipeline-health-state}"
STATUS_FILE="$STATE_DIR/tool-freshness"
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

BEHIND=()    # "tool installed → latest[ (note)]"
CURRENT=()   # "tool installed[ (note)]"
UNKNOWN=()   # "tool: reason"

record_behind() {  # tool installed latest [note]
  local line="$1 $2 → $3"; [ -n "${4:-}" ] && line="$line ($4)"
  BEHIND+=("$line"); log "BEHIND  $line"
}
record_current() {  # tool installed [note]
  local line="$1 $2"; [ -n "${3:-}" ] && line="$line ($3)"
  CURRENT+=("$line"); log "current $line"
}
record_unknown() {  # tool reason
  UNKNOWN+=("$1: $2"); log "unknown $1: $2"
}

# version_lt <a> <b> — 0 when a sorts strictly before b (sort -V: 1.9 < 1.10).
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# strip_tag <tag> — release tag → bare version: v2.101.0 → 2.101.0, bun-v1.4.2 → 1.4.2.
strip_tag() { local v="$1"; v="${v#bun-}"; v="${v#v}"; printf '%s' "$v"; }

# gh_latest_release <owner/repo> — bare version of the latest release, "" on failure.
gh_latest_release() {
  local tag
  tag=$(gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null) || tag=""
  strip_tag "$tag"
}

# compare <tool> <installed> <latest> [note] — files the tool under one bucket.
compare() {
  local tool="$1" installed="$2" latest="$3" note="${4:-}"
  if [ -z "$installed" ]; then record_unknown "$tool" "not installed or --version unreadable"
  elif [ -z "$latest" ]; then record_unknown "$tool" "could not look up the latest release (installed $installed)"
  elif version_lt "$installed" "$latest"; then record_behind "$tool" "$installed" "$latest" "$note"
  else record_current "$tool" "$installed" "$note"
  fi
}

check_bun() {
  local installed; installed=$(bun --version 2>/dev/null | head -n1)
  compare bun "$installed" "$(gh_latest_release oven-sh/bun)"
}

check_gh() {
  local installed; installed=$(gh --version 2>/dev/null | awk 'NR==1 { print $3 }')
  compare gh "$installed" "$(gh_latest_release cli/cli)"
}

check_uv() {
  local installed; installed=$(uv --version 2>/dev/null | awk 'NR==1 { print $2 }')
  compare uv "$installed" "$(gh_latest_release astral-sh/uv)"
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
  local major="${installed%%.*}" latest=""
  if [ -n "$major" ]; then
    latest=$(gh api "repos/theseus-rs/postgresql-binaries/releases?per_page=100" --jq '.[].tag_name' 2>/dev/null \
      | grep -E "^${major}\.[0-9]+\.[0-9]+$" | sort -V | tail -n1) || latest=""
    latest="${latest%.*}"
  fi
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

# ----------------------------------------------------------------------------
log "=== tool freshness ==="
check_bun
check_gh
check_uv
check_node
check_archon
check_pg_dump

mkdir -p "$STATE_DIR"
{
  echo "checked_at=$(date -Is)"
  if [ "${#BEHIND[@]}" -gt 0 ]; then echo "status=behind"; else echo "status=current"; fi
  echo "behind_count=${#BEHIND[@]}"
  echo "unknown_count=${#UNKNOWN[@]}"
  for l in "${BEHIND[@]}";  do echo "behind: $l"; done
  for l in "${CURRENT[@]}"; do echo "current: $l"; done
  for l in "${UNKNOWN[@]}"; do echo "unknown: $l"; done
} > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"

if [ "${#BEHIND[@]}" -gt 0 ]; then
  names=""
  for l in "${BEHIND[@]}"; do names="${names:+$names, }${l%% *}"; done
  body=$(printf '%s\n' "${BEHIND[@]}")
  [ "${#UNKNOWN[@]}" -gt 0 ] && body="$body"$'\n'"(could not check: $(printf '%s, ' "${UNKNOWN[@]%%:*}" | sed 's/, $//'))"
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
