#!/usr/bin/env bash
# daily-release-cron.sh — run daily at 08:00 from cron.
# For each project in archon-projects.txt, releases it the way its own
# release*.yml (lib/releases.sh, release_classify) wants (#248):
#   - a release*.yml that already runs on push to main: skipped, it releases
#     itself.
#   - one with a push:tags pattern: tag origin/main to match it (e.g. "v*" ->
#     "v2026.11.1"), if there are new commits since the newest tag already
#     matching that pattern.
#   - one that is workflow_dispatch-only: dispatch it with its defaults, if
#     there are new commits since its newest successful run.
#   - neither (including no release*.yml at all): keep the original
#     release-YYYY-MM-DD GitHub release with auto-generated notes, if there
#     are new commits since the newest release-* tag.
# Also skipped: projects listed in DAILY_RELEASE_OPT_OUT.
#
# Crontab:
#   0 8 * * * <repo>/ops/cron/daily-release-cron.sh >> ~/.local/state/archon-cron/logs/daily-release.log 2>&1

set -uo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
# shellcheck source=lib/releases.sh
source "$SCRIPT_DIR/lib/releases.sh"

load_archon_projects PROJECTS
BASE_DIR="${BASE_DIR:-/mnt/ext-fast}"
LOG_PREFIX="[daily-release]"
TODAY="$(date +%Y-%m-%d)"

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

# Ask Gemini to write a 2-3 sentence human-readable highlight summary from
# the auto-generated release body. Run from /tmp so per-project gemini MCP
# configs don't break. Strip known noise prefix. Empty output on failure
# (caller falls back to the plain auto-generated notes).
summarize_release() {
  local project="$1"
  local body="$2"

  # Condense the auto-generated body to just "- PR title" lines. Drops author
  # suffixes, URLs, the contributors section, and the changelog footer — gemini
  # only needs titles to summarize, and large bodies (30KB+) make it crawl or
  # hang despite the timeout.
  local titles
  titles=$(echo "$body" | awk '
    /^## New Contributors/ { skip=1 }
    /^## What.?s Changed/ { section=1; next }
    skip { next }
    section && /^\* / {
      sub(/^\* /, "")
      sub(/ by @[^ ]+ in https.*$/, "")
      print "- " $0
    }')

  [ -z "$titles" ] && return 1

  # Cap at 80 most recent titles — huge first-time releases (200+ PRs) make
  # gemini crawl, and a good summary doesn't need every entry. Daily releases
  # going forward will be well under this.
  titles=$(echo "$titles" | tail -n 80)

  local prompt="Write 2-3 sentences of release-notes highlights for the project '${project}' based on this list of merged PR titles. Plain prose. No markdown headers, no preamble, no 'this release' filler.

${titles}"

  # -k 10: if gemini doesn't exit within 10s of the 120s SIGTERM, send SIGKILL.
  # Plain `timeout 120 gemini ...` can leave gemini running because it catches
  # SIGTERM and doesn't propagate to its node children.
  local out
  out=$(cd /tmp && timeout -k 10 120 gemini -p "$prompt" 2>/dev/null) || return 1
  out="${out#MCP issues detected. Run /mcp list for status.}"
  out=$(echo "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$out" ] && return 1
  printf '%s' "$out"
}

# release_one_tag <project> <head_sha> <pattern> — a project whose own
# release*.yml wants a tag matching <pattern> (#248): tag main to match it,
# unless nothing's new since the last tag that already matches. <pattern>'s
# glob syntax ("?", "[...]") can produce a pattern no concrete git ref can
# satisfy; release_tag_for_pattern fails in that case, and this falls back to
# the dated release-YYYY-MM-DD path instead of never releasing the project.
release_one_tag() {
  local project="$1" head_sha="$2" pattern="$3" prev_tag commit_count new_tag
  prev_tag=$(git tag -l "$pattern" | release_latest_tag_by_name)
  if [ -n "$prev_tag" ]; then
    commit_count=$(git rev-list --count "$prev_tag..$head_sha" 2>/dev/null || echo 0)
  else
    commit_count=$(git rev-list --count "$head_sha" 2>/dev/null || echo 0)
  fi
  if [ "$commit_count" -eq 0 ]; then
    log "$project: no new commits since ${prev_tag:-repo start} ($pattern), skipping"
    return
  fi

  if ! new_tag=$(release_tag_for_pattern "$pattern"); then
    log "$project: unsupported tag pattern $pattern, falling back to release-$TODAY"
    release_one_fallback "$project" "$head_sha" "release-$TODAY"
    return
  fi
  if git ls-remote --tags origin "refs/tags/$new_tag" 2>/dev/null | grep -q "$new_tag"; then
    log "$project: tag $new_tag already exists, skipping"
    return
  fi

  log "$project: tagging $new_tag to match $pattern ($commit_count commits since ${prev_tag:-repo start})"
  if ! git tag "$new_tag" "$head_sha" 2>&1 | sed "s/^/    /"; then
    log "$project: git tag failed"
    return
  fi
  if ! git push --quiet origin "refs/tags/$new_tag" 2>&1 | sed "s/^/    /"; then
    log "$project: tag push failed"
    git tag -d "$new_tag" >/dev/null 2>&1
    return
  fi
  log "$project: pushed $new_tag"
}

# release_one_dispatch <project> <head_sha> <path> — a project whose own
# release*.yml is workflow_dispatch-only (#248): dispatch it with its
# defaults, unless nothing's new since its newest successful run.
release_one_dispatch() {
  local project="$1" head_sha="$2" path="$3" since commit_count
  if ! since=$(gh api "repos/$RELEASE_OWNER/$project/actions/workflows/${path##*/}/runs?event=workflow_dispatch" \
        --jq '[.workflow_runs[] | select(.status=="completed" and .conclusion=="success")][0].created_at // ""' 2>/dev/null); then
    log "$project: could not read $path's runs, skipping"
    return
  fi
  if [ -n "$since" ]; then
    commit_count=$(git rev-list --count --since="$since" "$head_sha" 2>/dev/null || echo 0)
  else
    commit_count=$(git rev-list --count "$head_sha" 2>/dev/null || echo 0)
  fi
  if [ "$commit_count" -eq 0 ]; then
    log "$project: no new commits since ${since:-repo start} ($path), skipping"
    return
  fi

  log "$project: dispatching $path ($commit_count commits since ${since:-repo start})"
  if ! gh workflow run "${path##*/}" --repo "$RELEASE_OWNER/$project" --ref main 2>&1 | sed "s/^/    /"; then
    log "$project: workflow dispatch failed"
    return
  fi
  log "$project: dispatched $path"
}

# release_one_fallback <project> <head_sha> <tag> — no release*.yml tells us
# how this project wants releasing: keep today's release-YYYY-MM-DD GitHub
# release, as before #248.
release_one_fallback() {
  local project="$1" head_sha="$2" tag="$3"

  # Idempotent: if today's tag already exists on the remote, skip.
  if git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null | grep -q "$tag"; then
    log "$project: tag $tag already exists, skipping"
    return
  fi

  # Find previous release-* tag, if any: newest by name, as release_lag_check
  # picks it.
  local prev_tag
  prev_tag=$(git tag -l 'release-*' | release_latest_tag_by_name)

  local commit_count
  if [ -n "$prev_tag" ]; then
    commit_count=$(git rev-list --count "$prev_tag..$head_sha" 2>/dev/null || echo 0)
  else
    commit_count=$(git rev-list --count "$head_sha" 2>/dev/null || echo 0)
  fi

  if [ "$commit_count" -eq 0 ]; then
    log "$project: no new commits since ${prev_tag:-repo start}, skipping"
    return
  fi

  log "$project: releasing $tag ($commit_count commits since ${prev_tag:-repo start})"

  if ! gh release create "$tag" \
        --repo "$RELEASE_OWNER/$project" \
        --target "$head_sha" \
        --title "$tag" \
        --generate-notes 2>&1 | sed "s/^/    /"; then
    log "$project: gh release create failed"
    return
  fi

  log "$project: released $tag — generating summary"

  local body summary new_body
  body=$(gh release view "$tag" --repo "$RELEASE_OWNER/$project" --json body --jq '.body' 2>/dev/null) || body=""
  if [ -n "$body" ] && summary=$(summarize_release "$project" "$body"); then
    new_body="## Highlights

$summary

---

$body"
    if gh release edit "$tag" --repo "$RELEASE_OWNER/$project" --notes "$new_body" >/dev/null 2>&1; then
      log "$project: summary attached to $tag"
    else
      log "$project: summary generated but gh release edit failed"
    fi
  else
    log "$project: summary unavailable — keeping plain auto-generated notes"
  fi
}

release_one() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  local tag="release-$TODAY"

  if release_opted_out "$project"; then
    log "$project: opted out (DAILY_RELEASE_OPT_OUT), skipping"
    return
  fi

  if [ ! -d "$repo_dir/.git" ]; then
    log "$project: no repo at $repo_dir, skipping"
    return
  fi

  cd "$repo_dir" || return

  if ! git fetch --tags --quiet origin main 2>/dev/null; then
    log "$project: git fetch failed, skipping"
    return
  fi

  local head_sha
  head_sha=$(git rev-parse origin/main 2>/dev/null) || {
    log "$project: cannot resolve origin/main, skipping"
    return
  }

  local rc=0 mode path pattern
  release_mode "$project" || rc=$?
  case "$rc" in
    0) log "$project: $path already releases on push to main, skipping"; return ;;
    2) log "$project: could not read release workflows, skipping"; return ;;
  esac

  case "$mode" in
    tag) release_one_tag "$project" "$head_sha" "$pattern"; return ;;
    dispatch) release_one_dispatch "$project" "$head_sha" "$path"; return ;;
  esac

  release_one_fallback "$project" "$head_sha" "$tag"
}

for PROJECT in "${PROJECTS[@]}"; do
  release_one "$PROJECT"
done

log "Done"
