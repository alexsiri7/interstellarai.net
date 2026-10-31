#!/usr/bin/env bash
# Which projects daily-release-cron.sh releases, and a flag for the ones it
# missed.
#
# Why (#248): the cron hardcoded the 7 original projects, so every repo
# onboarded later (catscape-watchface, zoomies, punland, ...) was never
# released and nothing said so. The cron now releases every project in
# archon-projects.txt except those this lib excludes, and pipeline-health
# flags a project whose main has gone unreleased for 48h by the same rules,
# so a missing clone or a broken cron surfaces as well.
#
#   source "$SCRIPT_DIR/lib/releases.sh"
#   release_opted_out <project>      # listed in DAILY_RELEASE_OPT_OUT
#   release_push_workflow <project>  # 0 + path: its release*.yml runs on push
#                                    # to main; 1: none does; 2: read failed
#   release_lag_check <project>      # pipeline-health: ntfy once per episode
#   release_lag_note <project>       # pipeline-status: "" or the repo's line
#
# A repo's release workflow is a file on main named
# .github/workflows/release*.yml|yaml. One that runs on a push to main means
# the repo releases itself, so the cron leaves it alone. A trigger shape the
# parser does not read counts as "not on push": the cost is one extra
# release-* tag, never a missed release.
#
# One marker per lagging project in RELEASE_LAG_STATE_DIR/<project>, key=value
# lines (since, tag, ahead, oldest, notified), cleared once main is released
# again or the project stops being the cron's to release. A read that fails
# changes nothing.

[ -n "${_ARCHON_RELEASES_SH:-}" ] && return 0
_ARCHON_RELEASES_SH=1

# shellcheck source=lib/deadlines.sh
source "$(dirname "${BASH_SOURCE[0]}")/deadlines.sh"

RELEASE_OWNER="${RELEASE_OWNER:-alexsiri7}"
# Space-separated slugs daily-release-cron.sh must never release.
DAILY_RELEASE_OPT_OUT="${DAILY_RELEASE_OPT_OUT:-}"
RELEASE_LAG_STATE_DIR="${RELEASE_LAG_STATE_DIR:-$HOME/.archon/state/unreleased}"
RELEASE_LAG_SECONDS="${RELEASE_LAG_SECONDS:-172800}"

# release_now — the clock (RELEASE_NOW overrides it for tests).
release_now() { echo "${RELEASE_NOW:-$(date +%s)}"; }

release_opted_out() {
  case " $DAILY_RELEASE_OPT_OUT " in *" $1 "*) return 0 ;; esac
  return 1
}

# _release_on_push_main — exit 0 when the workflow on stdin runs on a push to
# main: `on:` names push with no branch filter (a tags-only push does not
# count), or branches lists main, * or **, or branches-ignore leaves main out.
_release_on_push_main() {
  python3 -c '
import re, sys

Q = chr(34) + chr(39)
lines = [re.sub(r"\s+#.*$", "", l.rstrip()) for l in sys.stdin.read().splitlines()]
lines = [l for l in lines if l.strip() and not l.lstrip().startswith("#")]

def ind(l):
    return len(l) - len(l.lstrip())

def items(v):
    v = v.strip()
    if v.startswith("["):
        v = v.strip("[]")
    return [x.strip().strip(Q) for x in v.split(",") if x.strip()]

def children(start, base):
    out = []
    for l in lines[start:]:
        if ind(l) <= base:
            break
        out.append(l)
    return out

def push_hits_main(filt):
    if "branches" in filt:
        return any(p in ("main", "*", "**") for p in filt["branches"])
    if "branches-ignore" in filt:
        return "main" not in filt["branches-ignore"]
    return "tags" not in filt

on_re = re.compile(r"^(on|[\x22\x27]on[\x22\x27]|true)\s*:\s*(.*)$")
for i, l in enumerate(lines):
    m = on_re.match(l) if ind(l) == 0 else None
    if not m:
        continue
    val = m.group(2)
    if val:
        sys.exit(0 if not val.startswith("{") and "push" in items(val) else 1)
    body = children(i + 1, 0)
    if not body:
        sys.exit(1)
    kid = ind(body[0])
    for j, b in enumerate(body):
        if ind(b) != kid:
            continue
        key, _, v = b.strip().partition(":")
        if key.strip(Q) != "push":
            continue
        v, filt = v.strip(), {}
        if v.startswith("{"):
            for k in ("branches-ignore", "branches", "tags"):
                mm = re.search(r"(^|[{,\s])" + k + r"\s*:\s*\[([^\]]*)\]", v)
                if mm:
                    filt[k] = items(mm.group(2))
                    v = v.replace(mm.group(0), mm.group(1))
        else:
            sub, cur = [], None
            for r in body[j + 1:]:
                if ind(r) <= kid:
                    break
                sub.append(r)
            ck = ind(sub[0]) if sub else 0
            for c in sub:
                s = c.strip()
                if s.startswith("- ") and cur:
                    filt[cur].append(s[2:].strip().strip(Q))
                elif ind(c) == ck:
                    k, _, cv = s.partition(":")
                    cur = k.strip(Q)
                    filt[cur] = items(cv) if cv.strip() else []
        sys.exit(0 if push_hits_main(filt) else 1)
    sys.exit(1)
sys.exit(1)
'
}

release_push_workflow() {
  local project="$1" paths path content
  paths=$(gh api "repos/$RELEASE_OWNER/$project/git/trees/main?recursive=1" \
    --jq '.tree[] | select(.type == "blob") | .path | select(test("^\\.github/workflows/release[^/]*\\.ya?ml$"; "i"))' \
    2>/dev/null) || return 2
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    content=$(gh api "repos/$RELEASE_OWNER/$project/contents/$path?ref=main" --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null) || return 2
    [ -n "$content" ] || return 2
    if printf '%s\n' "$content" | _release_on_push_main; then
      echo "$path"
      return 0
    fi
  done <<< "$paths"
  return 1
}

# release_lag_check <project> — commits on main not in the newest release-*
# tag, the oldest of them committed over RELEASE_LAG_SECONDS ago (a repo with
# no tag: any commit that old), on a project the cron would release. Needs
# log and notify_checked from the caller.
release_lag_check() {
  local project="$1" now cutoff refs tag="" out ahead oldest f
  now=$(release_now)
  cutoff=$(date -u -d "@$((now - RELEASE_LAG_SECONDS))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 0
  f="$RELEASE_LAG_STATE_DIR/$project"
  if ! refs=$(gh api --paginate "repos/$RELEASE_OWNER/$project/git/matching-refs/tags/release-" \
        --jq '.[].ref' 2>/dev/null); then
    log "release-lag: $project — could not list release tags, skipping"
    return 0
  fi
  tag=$(printf '%s\n' "$refs" | sed -n 's#^refs/tags/##p' | sort | tail -n1)
  if [ -n "$tag" ]; then
    out=$(gh api "repos/$RELEASE_OWNER/$project/compare/$tag...main" \
      --jq '"\(.ahead_by) \([.commits[].commit.committer.date] | min // "")"' 2>/dev/null) || out=""
    ahead="${out%% *}"; oldest="${out#* }"
    if ! [[ "$ahead" =~ ^[0-9]+$ ]]; then
      log "release-lag: $project — could not compare $tag with main, skipping"
      return 0
    fi
    if [ "$ahead" -eq 0 ] || [[ -z "$oldest" || "$oldest" > "$cutoff" ]]; then
      ahead=0
    fi
  else
    out=$(gh api "repos/$RELEASE_OWNER/$project/commits?sha=main&until=$cutoff&per_page=1" \
      --jq 'length' 2>/dev/null) || out=""
    if ! [[ "$out" =~ ^[0-9]+$ ]]; then
      log "release-lag: $project — could not list main commits, skipping"
      return 0
    fi
    ahead=all; oldest="before $cutoff"
    [ "$out" -eq 0 ] && ahead=0
  fi

  if [ "$ahead" = 0 ]; then
    _release_lag_clear "$project" "released again"
    return 0
  fi
  if release_opted_out "$project"; then
    _release_lag_clear "$project" "opted out of the daily release"
    return 0
  fi
  local rc=0 wf
  wf=$(release_push_workflow "$project") || rc=$?
  case "$rc" in
    0) _release_lag_clear "$project" "$wf releases on push to main"; return 0 ;;
    2) log "release-lag: $project — could not read release workflows, skipping"; return 0 ;;
  esac

  mkdir -p "$RELEASE_LAG_STATE_DIR" 2>/dev/null || return 0
  local since notified
  since=$(deadline_get "$f" since); [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
  notified=$(deadline_get "$f" notified); [[ "$notified" =~ ^[0-9]+$ ]] || notified=0
  if [ "$notified" = 0 ]; then
    if notify_checked "Unreleased: $project" \
         "$project: ${ahead} commit(s) on main not released since ${tag:-the repo started}, oldest ${oldest}. daily-release-cron.sh releases at 08:00; check ~/.local/state/archon-cron/logs/daily-release.log. https://github.com/$RELEASE_OWNER/$project/releases" \
         high warning; then
      notified="$now"
    fi
  fi
  _deadline_write "$f" "since=$since" "tag=$tag" "ahead=$ahead" "oldest=$oldest" "notified=$notified" 2>/dev/null || true
  log "release-lag: $project — $ahead unreleased commit(s), oldest $oldest"
}

_release_lag_clear() { # <project> <why>
  local f="$RELEASE_LAG_STATE_DIR/$1"
  [ -f "$f" ] || return 0
  rm -f "$f"
  log "release-lag: $1 — $2"
}

# release_lag_note <project> — "" when main is released, else a short line for
# pipeline-status.
release_lag_note() {
  local f="$RELEASE_LAG_STATE_DIR/$1" tag
  [ -f "$f" ] || return 0
  tag=$(deadline_get "$f" tag)
  printf 'UNRELEASED: %s commit(s) since %s, oldest %s' "$(deadline_get "$f" ahead)" \
    "${tag:-start}" "$(deadline_get "$f" oldest)"
}
