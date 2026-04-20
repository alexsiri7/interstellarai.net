#!/usr/bin/env bash
# daily-release-cron.sh — run daily at 08:00 from cron.
# For each project, if origin/main has new commits since the last
# release-* tag, create a date tag `release-YYYY-MM-DD` and a GitHub
# release with auto-generated notes.
#
# Crontab:
#   0 8 * * * <repo>/ops/cron/daily-release-cron.sh >> /tmp/daily-release.log 2>&1

set -uo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

PROJECTS=(reli word-coach-annie filmduel cosmic-match un-reminder interstellarai.net)
BASE_DIR="/mnt/ext-fast"
OWNER="alexsiri7"
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

release_one() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  local tag="release-$TODAY"

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

  # Idempotent: if today's tag already exists on the remote, skip.
  if git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null | grep -q "$tag"; then
    log "$project: tag $tag already exists, skipping"
    return
  fi

  # Find previous release-* tag, if any.
  local prev_tag
  prev_tag=$(git tag -l 'release-*' --sort=-creatordate | head -n1)

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
        --repo "$OWNER/$project" \
        --target "$head_sha" \
        --title "$tag" \
        --generate-notes 2>&1 | sed "s/^/    /"; then
    log "$project: gh release create failed"
    return
  fi

  log "$project: released $tag — generating summary"

  local body summary new_body
  body=$(gh release view "$tag" --repo "$OWNER/$project" --json body --jq '.body' 2>/dev/null) || body=""
  if [ -n "$body" ] && summary=$(summarize_release "$project" "$body"); then
    new_body="## Highlights

$summary

---

$body"
    if gh release edit "$tag" --repo "$OWNER/$project" --notes "$new_body" >/dev/null 2>&1; then
      log "$project: summary attached to $tag"
    else
      log "$project: summary generated but gh release edit failed"
    fi
  else
    log "$project: summary unavailable — keeping plain auto-generated notes"
  fi
}

for PROJECT in "${PROJECTS[@]}"; do
  release_one "$PROJECT"
done

log "Done"
