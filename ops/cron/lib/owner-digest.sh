#!/usr/bin/env bash
# The owner's weekly question: every PR the factory's reviewers leave for the
# owner, in one Lachesis question a week that blocks nothing else (#267).
#
# held-pr-review.sh and ops-pr-review.sh add a PR here when only the owner may
# merge it: it weakens the factory's own checks or grants access, it is too
# large to review automatically, or (held-pr-review.sh) it cannot be reviewed
# while it stays held. Neither tells the owner per PR any more.
#
#   source "$SCRIPT_DIR/lib/owner-digest.sh"
#   owner_digest_add <project> <pr> <sha> <title> <verdict>
#   owner_digest_send      # end of every held-pr-review.sh run
#
# owner_digest_send, once per ISO week (OWNER_DIGEST_WEEK overrides it in
# tests), re-reads every pending PR and drops the ones that closed or whose
# head moved (a new head is reviewed again). What is left goes into one issue
# in OWNER_DIGEST_REPO, labelled human-needed and owner-digest, one line per
# PR; the previous week's issue is closed as superseded. One lachesis_ask on
# that issue, which blocks only that issue, and one ntfy. A PR stays pending
# until it closes or moves, so one that still waits is listed every week.
# A week with nothing pending sends nothing and closes the last issue.
#
# State in OWNER_DIGEST_STATE:
#   pending/<project>-<pr>  {project, pr, sha, title, verdict}, one JSON line
#   filed                   "<week> <issue>": the newest digest issue, written
#                           right after it is filed, so a retry never files twice
#   asked                   "<week>": the week whose question is recorded

[ -n "${_OWNER_DIGEST_SH:-}" ] && return 0
_OWNER_DIGEST_SH=1

# shellcheck source=trust.sh
source "$(dirname "${BASH_SOURCE[0]}")/trust.sh"
# shellcheck source=lachesis.sh
source "$(dirname "${BASH_SOURCE[0]}")/lachesis.sh"

OWNER_DIGEST_STATE="${OWNER_DIGEST_STATE:-$HOME/.local/state/archon-cron/owner-digest}"
OWNER_DIGEST_REPO="${OWNER_DIGEST_REPO:-alexsiri7/interstellarai.net}"
OWNER_DIGEST_LABEL="owner-digest"

_owner_digest_log() { echo "$(date -Is) [owner-digest] $*"; }

# _owner_digest_write <file> <content> — tmp+mv: two crons write here.
_owner_digest_write() {
  mkdir -p "$(dirname "$1")" 2>/dev/null &&
    printf '%s\n' "$2" > "$1.tmp" 2>/dev/null &&
    mv "$1.tmp" "$1" 2>/dev/null
}

owner_digest_add() {
  local entry
  entry=$(jq -nc --arg p "$1" --argjson n "$2" --arg s "$3" --arg t "$4" --arg v "$5" \
    '{project: $p, pr: $n, sha: $s, title: $t, verdict: $v}') || return 1
  _owner_digest_write "$OWNER_DIGEST_STATE/pending/$1-$2" "$entry"
}

# _owner_digest_lines — the "- <link> — <title>: <verdict>" line of every
# pending PR still open at its recorded head; the others are dropped. A PR
# that cannot be read is kept.
_owner_digest_lines() {
  local f entry project pr sha view
  for f in "$OWNER_DIGEST_STATE"/pending/*; do
    [ -f "$f" ] || continue
    entry=$(jq -ce 'select(.project and .pr and .sha)' "$f" 2>/dev/null) || { rm -f "$f"; continue; }
    project=$(printf '%s' "$entry" | jq -r .project)
    pr=$(printf '%s' "$entry" | jq -r .pr)
    sha=$(printf '%s' "$entry" | jq -r .sha)
    if view=$(gh pr view "$pr" --repo "$TRUST_OWNER/$project" --json state,headRefOid 2>/dev/null) \
       && ! printf '%s' "$view" | jq -e --arg s "$sha" '.state == "OPEN" and .headRefOid == $s' >/dev/null 2>&1; then
      rm -f "$f"
      continue
    fi
    printf '%s' "$entry" | jq -r --arg o "$TRUST_OWNER" '
      def line: gsub("[[:cntrl:]]"; " ") | .[0:300];
      "- \($o)/\(.project)#\(.pr) — \(.title | line): \(.verdict | line)"'
  done
}

owner_digest_send() {
  local week filed_week issue prev lines n body asked=1
  week="${OWNER_DIGEST_WEEK:-$(date -u +%G-W%V)}"
  [ "$(cat "$OWNER_DIGEST_STATE/asked" 2>/dev/null)" = "$week" ] && return 0
  read -r filed_week issue 2>/dev/null < "$OWNER_DIGEST_STATE/filed" || true
  if [ "${filed_week:-}" != "$week" ]; then
    lines=$(_owner_digest_lines)
    prev="${issue:-}"
    if [ -z "$lines" ]; then
      if [ -n "$prev" ] && gh issue close "$prev" --repo "$OWNER_DIGEST_REPO" \
           --comment "No pull request waits for the owner any more."$'\n\n<!-- lachesis:automated -->' >/dev/null 2>&1; then
        rm -f "$OWNER_DIGEST_STATE/filed"
      fi
      return 0
    fi
    n=$(printf '%s\n' "$lines" | grep -c '')
    body="The factory's reviewers left these pull requests for the owner: each weakens the factory's own checks, grants access, was too large to review automatically, or cannot be reviewed while it is held. Only these wait; the factory keeps working on everything else.

$lines

Merge or close each one by hand. Next week's question lists whatever still waits, and replaces this issue.

<!-- lachesis:automated -->"
    gh label create "$OWNER_DIGEST_LABEL" --repo "$OWNER_DIGEST_REPO" --color "5319E7" \
      --description "The owner's weekly review of PRs only the owner may merge" >/dev/null 2>&1 || true
    gh label create human-needed --repo "$OWNER_DIGEST_REPO" --color "B60205" \
      --description "Needs a human" >/dev/null 2>&1 || true
    issue=$(gh issue create --repo "$OWNER_DIGEST_REPO" --title "Owner review: $n PRs waiting ($week)" \
      --label human-needed --label "$OWNER_DIGEST_LABEL" --body "$body" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
    if [ -z "$issue" ]; then
      _owner_digest_log "could not file the $week digest issue — retrying next run"
      return 0
    fi
    _owner_digest_write "$OWNER_DIGEST_STATE/filed" "$week $issue" \
      || { _owner_digest_log "filed $OWNER_DIGEST_REPO#$issue but could not record it"; return 0; }
    _owner_digest_log "filed $OWNER_DIGEST_REPO#$issue: $n PRs for the owner ($week)"
    if [ -n "$prev" ]; then
      gh issue close "$prev" --repo "$OWNER_DIGEST_REPO" \
        --comment "Superseded by #$issue."$'\n\n<!-- lachesis:automated -->' >/dev/null 2>&1 \
        || _owner_digest_log "could not close last week's digest #$prev"
    fi
  fi
  if [ -n "$(lachesis_token)" ]; then
    if ! lachesis_ask "${OWNER_DIGEST_REPO#*/}" "$issue" \
         "Pull requests wait for your review ($week): see the list on this issue. Merge or close each one by hand." \
         "Filed by the owner's weekly digest (lib/owner-digest.sh, #267). It blocks only this issue."; then
      _owner_digest_log "could not record the $week question in Lachesis — retrying next run"
      asked=""
    fi
  else
    _owner_digest_log "no LACHESIS_FACTORY_TOKEN — the $week question is not recorded"
  fi
  trust_notify_once owner-digest week "$week" \
    "Pull requests wait for your review ($week): https://github.com/$OWNER_DIGEST_REPO/issues/$issue" \
    "Owner's weekly review"
  [ -z "$asked" ] || _owner_digest_write "$OWNER_DIGEST_STATE/asked" "$week" || true
}
