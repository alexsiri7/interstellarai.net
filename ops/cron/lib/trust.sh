#!/usr/bin/env bash
# Shared trust gate: which GitHub issues, PRs and comments the factory may act
# on. Several factory repos are public, and every archon run is a Claude
# session on this workstation (which holds every secret), so an issue, PR or
# comment from anyone else is untrusted input: it is never triaged, queued,
# reviewed, maintained, merged or handed to archon. See README "Trust model".
#
# Usage:
#   source "$SCRIPT_DIR/lib/trust.sh"
#   trust_issue_ok "<author login>"                 # issue author trusted?
#   trust_pr_level "<author login>" "<isCrossRepository>"   # full|merge|none
#   trust_filter_issues <project> <<<"$issues_json" # trusted issues only
#   trust_filter_prs <project> full|merge <<<"$prs_json"
#   trust_comments_ok <project> issue|pr <number>   # no untrusted commenter?
#
# Author lists (space-separated logins; GitHub Apps as `<slug>[bot]`), set in
# the environment or in $ARCHON_CRON_TRUST_FILE (default
# ~/.config/archon-cron/trust.env, sourced when present; values there win):
#   TRUSTED_AUTHORS            full trust: issues, PRs, comments.
#   TRUSTED_ISSUE_BOTS         issues and comments only (bots that file issues
#                              the pipeline works: Sentry, repo workflows).
#   TRUSTED_MERGE_ONLY_AUTHORS PRs merged by pr-maintenance when CLEAN, but no
#                              archon run ever reads them (their bodies embed
#                              third-party text, e.g. upstream release notes).
# An empty list trusts nobody. Logins compare case-insensitively; gh's `--json
# author` form `app/<slug>` is the same identity as REST's `<slug>[bot]`.
#
# Issues filed by a bridge (a service that files issues under the owner's
# token with a caller's text: Sentry, the feedback workers, Muse & Mingle's
# public forms) need the owner's `archon:approved` label; see bridge_source.
#
# Untrusted items get one log line and one ntfy per (project, kind, number),
# marker in $TRUST_STATE_DIR (default ~/.archon/state/untrusted). Everything
# here fails closed: an empty or unknown login, a missing isCrossRepository,
# or a comment listing that cannot be read all count as untrusted.

[ -n "${_ARCHON_TRUST_SH:-}" ] && return 0
_ARCHON_TRUST_SH=1

: "${TRUSTED_AUTHORS=alexsiri7}"
: "${TRUSTED_ISSUE_BOTS=sentry[bot] github-actions[bot]}"
: "${TRUSTED_MERGE_ONLY_AUTHORS=dependabot[bot] github-actions[bot]}"
TRUST_FILE="${ARCHON_CRON_TRUST_FILE:-$HOME/.config/archon-cron/trust.env}"
if [ -r "$TRUST_FILE" ]; then
  # shellcheck source=/dev/null
  . "$TRUST_FILE"
fi
TRUST_STATE_DIR="${TRUST_STATE_DIR:-$HOME/.archon/state/untrusted}"
TRUST_OWNER="${TRUST_OWNER:-alexsiri7}"

# NTFY_TOPIC only — never source secrets.env here: its DB URLs would land in
# the environment of every archon run these scripts start.
if [ -z "${NTFY_TOPIC:-}" ]; then
  _trust_secrets="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
  if [ -r "$_trust_secrets" ]; then
    NTFY_TOPIC=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?NTFY_TOPIC=["'\'']?([^"'\''[:space:]#]*).*/\2/p' "$_trust_secrets" | tail -1)
  fi
  unset _trust_secrets
fi

_trust_log() { echo "$(date -Is) [trust] $*" >&2; }

# trust_canon_login <login> — lowercase; `app/<slug>` → `<slug>[bot]`.
trust_canon_login() {
  local l="${1,,}"
  case "$l" in app/*) l="${l#app/}[bot]" ;; esac
  printf '%s' "$l"
}

# _trust_in_list <login> <space-separated list...> — exact membership; an
# empty login never matches. Split with read -a, not word splitting, so a
# `[bot]` entry is never treated as a glob.
_trust_in_list() {
  local who; who=$(trust_canon_login "$1"); shift
  case "$who" in ''|ghost|null) return 1 ;; esac
  local list e
  local -a entries
  for list in "$@"; do
    read -r -a entries <<<"$list"
    for e in "${entries[@]}"; do
      [ -n "$e" ] && [ "$who" = "$(trust_canon_login "$e")" ] && return 0
    done
  done
  return 1
}

trust_issue_ok() { _trust_in_list "${1:-}" "$TRUSTED_AUTHORS" "$TRUSTED_ISSUE_BOTS"; }
trust_commenter_ok() { trust_issue_ok "$@"; }

# trust_pr_level <author> <isCrossRepository> — prints full, merge or none.
# A PR whose head lives in another repository (a fork) is never trusted,
# whatever the login says.
trust_pr_level() {
  local author="${1:-}" cross="${2:-}"
  if [ "$cross" != "false" ]; then echo none; return; fi
  if _trust_in_list "$author" "$TRUSTED_AUTHORS"; then echo full
  elif _trust_in_list "$author" "$TRUSTED_MERGE_ONLY_AUTHORS"; then echo merge
  else echo none; fi
}

# trust_notify_once <project> <kind> <number> <message> — log + ntfy the owner
# once per (project, kind, number). The marker is written only once the ntfy
# went out (or there is no topic to send to), so a failed push is retried.
trust_notify_once() {
  local project="$1" kind="$2" num="$3" msg="$4"
  local marker="$TRUST_STATE_DIR/$project-$kind-$num"
  [ -f "$marker" ] && return 0
  mkdir -p "$TRUST_STATE_DIR" 2>/dev/null || true
  _trust_log "$project: $msg"
  if [ -z "${NTFY_TOPIC:-}" ]; then
    _trust_log "$project: NTFY_TOPIC not set — logged only"
    touch "$marker" 2>/dev/null || true
    return 0
  fi
  if curl -s --fail -o /dev/null -H "Title: Untrusted $kind on $project" \
       -H "Priority: default" -H "Tags: shield" \
       -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null; then
    touch "$marker" 2>/dev/null || true
  else
    _trust_log "$project: ntfy failed, retrying next tick"
  fi
}

# Bridges: services that file issues under the owner's token (so an author
# check passes them) with text chosen by whoever called them. An issue from one
# is untrusted until the owner adds $TRUST_APPROVED_LABEL. One jq expression,
# evaluated per issue, names the bridge or yields "". Detection keys on what the
# bridge itself sets and the caller cannot remove: its labels, its title
# prefix, its body marker, the Sentry App as author.
#   sentry-app        author app/sentry (Sentry's GitHub integration)
#   sentry-bridge     label `sentry`, title "[Sentry] …" or a body that
#                     starts "Automatically created from Sentry"
#                     (interstellarai.net workers/sentry-bridge; events can be
#                     forged with the public DSN)
#   feedback          label `feedback`, or title "Bug: …" / "Feature: …"
#                     (workers/feedback — unauthenticated — and word-coach-annie
#                     /api/feedback; the caller picks bug/feature/other)
#   content-report    label `content-report` (word-coach-annie report route)
#   musenmingle-suggestion  body "Suggested via `POST /v1/suggestions`" or
#                     "_Filed automatically by musenmingle-api._" (the public
#                     suggest form/API; archon then scrapes that URL). Not the
#                     `new-scraper` label: the owner files those too.
#   musenmingle-health      body "_Filed automatically by musenmingle-ingest._"
#                     or label `scraper-broken` (body carries scraper error
#                     text from third-party sites)
# venue-request (musenmingle contact form) and content-report (annie) are
# human-only (lib/human-labels.sh): operational requests, never built.
TRUST_APPROVED_LABEL="${TRUST_APPROVED_LABEL:-archon:approved}"
# Set by lib/screen.sh: passed automated screening / held for the owner.
TRUST_SCREENED_LABEL="${TRUST_SCREENED_LABEL:-archon:auto-approved}"
TRUST_HELD_LABEL="${TRUST_HELD_LABEL:-needs-owner-review}"
# shellcheck disable=SC2016  # jq program, not shell
_TRUST_SOURCE_JQ='
  def bridge_source:
    ([.labels[]?.name]) as $l | (.title // "") as $t | (.body // "") as $b
    | ((.author.login // "") | ascii_downcase) as $a
    | if $a == "app/sentry" or $a == "sentry[bot]" then "sentry-app"
      elif ($l | index("sentry")) or ($t | startswith("[Sentry] "))
           or ($b | startswith("Automatically created from Sentry")) then "sentry-bridge"
      elif ($l | index("feedback")) or ($t | test("^(Bug|Feature): ")) then "feedback"
      elif ($l | index("content-report")) then "content-report"
      elif ($b | test("Suggested via `POST /v1/suggestions`|_Filed automatically by musenmingle-api\\._")) then "musenmingle-suggestion"
      elif ($l | index("venue-request")) or ($b | test("Sent with the contact form on the site")) then "musenmingle-contact"
      elif ($l | index("scraper-broken")) or ($b | test("_Filed automatically by musenmingle-ingest\\._")) then "musenmingle-health"
      else "" end;'

# _trust_rows <json> — one row per item, fields separated by US (0x1f, not a
# tab: read collapses runs of whitespace IFS, which would shift an empty field
# into the next): number, author, isCrossRepository ("missing" when absent),
# bridge source ("" = none), approval (owner = archon:approved, held =
# needs-owner-review, screened = archon:auto-approved, else no), createdAt,
# title (one line, 80 chars).
_trust_rows() {
  jq -r --arg approved "$TRUST_APPROVED_LABEL" --arg screened "$TRUST_SCREENED_LABEL" --arg held "$TRUST_HELD_LABEL" "$_TRUST_SOURCE_JQ"'
    .[]? | [(.number|tostring), (.author.login // ""),
            (if .isCrossRepository == null then "missing" else (.isCrossRepository|tostring) end),
            bridge_source,
            ([.labels[]?.name] | if index($approved) then "owner"
                                 elif index($held) then "held"
                                 elif index($screened) then "screened" else "no" end),
            (.createdAt // ""),
            ((.title // "") | gsub("[[:cntrl:]]"; " ") | .[0:80])]
    | join("\u001f")' <<<"$1" 2>/dev/null
}

_trust_keep() {
  jq -c --arg keep "$1" '[.[]? | select(.number|tostring|IN($keep|split(" ")[]))]' <<<"$2" 2>/dev/null || echo '[]'
}

# trust_filter_issues <project> — stdin: a `gh issue list --json` array that
# includes author, and labels,title,body for the bridge check; stdout: the
# same array holding only issues the factory may act on. An issue passes when
# the owner labelled it $TRUST_APPROVED_LABEL, or its author is trusted AND
# either no bridge filed it or automated screening passed it
# ($TRUST_SCREENED_LABEL without $TRUST_HELD_LABEL). Each rejected issue is notified once, unless TRUST_QUIET is
# set (closed-issue listings, counts). TRUST_AUTHOR_ONLY=1 skips the bridge
# check, for paths that start no archon run and only act on the bridges' own
# issues (dedupe_sentry). Unparseable input yields [].
trust_filter_issues() {
  local project="$1" json keep="" num author _cross source approved _created _title
  json=$(cat)
  while IFS=$'\x1f' read -r num author _cross source approved _created _title; do
    [ -n "$num" ] || continue
    [ -n "${TRUST_AUTHOR_ONLY:-}" ] && source=""
    if [ "$approved" = "owner" ] || { trust_issue_ok "$author" && { [ -z "$source" ] || [ "$approved" = "screened" ]; }; }; then
      keep="$keep $num"
    elif [ -n "${TRUST_QUIET:-}" ]; then
      :
    elif ! trust_issue_ok "$author"; then
      trust_notify_once "$project" issue "$num" \
        "External issue #$num on $project by ${author:-unknown} — not touched by the factory. https://github.com/$TRUST_OWNER/$project/issues/$num"
    fi
    # A bridge issue not yet screened (or held by screening) is silent here:
    # lib/screen.sh screens it and tells the owner when it holds one.
  done < <(_trust_rows "$json")
  _trust_keep "$keep" "$json"
}

# Dependabot PRs are merge-only (never read by archon), and even then only
# once the release has aged TRUST_DEPENDABOT_MIN_AGE_H hours (a hijacked
# upstream release is usually yanked within days) and only when the title's
# "from X to Y" keeps the major version. Grouped or major bumps wait for the
# owner. A missing or unparseable title/createdAt fails closed.
TRUST_DEPENDABOT_MIN_AGE_H="${TRUST_DEPENDABOT_MIN_AGE_H:-72}"
trust_dependabot_merge_ok() {
  local title="$1" created="$2" created_s now_s from to
  created_s=$(date -d "$created" +%s 2>/dev/null) || return 1
  now_s=$(date +%s)
  [ $(( now_s - created_s )) -ge $(( TRUST_DEPENDABOT_MIN_AGE_H * 3600 )) ] || return 1
  [[ "$title" =~ from[[:space:]]+[^0-9]*([0-9]+)[^[:space:]]*[[:space:]]+to[[:space:]]+[^0-9]*([0-9]+) ]] || return 1
  from="${BASH_REMATCH[1]}"; to="${BASH_REMATCH[2]}"
  [ "$from" = "$to" ]
}

# trust_filter_prs <project> full|merge — stdin: `gh pr list --json
# …,author,isCrossRepository` array (plus title,createdAt where merge-only
# bots' PRs may be merged); stdout: only PRs at the given level (merge also
# admits full). Untrusted PRs are notified once; merge-only PRs dropped by a
# `full` filter, and dependabot PRs still inside their cooldown, are expected
# and only logged (once).
trust_filter_prs() {
  local project="$1" need="$2" json keep="" num author cross _source _approved created title level
  json=$(cat)
  while IFS=$'\x1f' read -r num author cross _source _approved created title; do
    [ -n "$num" ] || continue
    level=$(trust_pr_level "$author" "$cross")
    case "$need:$level" in
      full:full|merge:full) keep="$keep $num" ;;
      merge:merge)
        if [ "$(trust_canon_login "$author")" = "dependabot[bot]" ] \
           && ! trust_dependabot_merge_ok "$title" "$created"; then
          local held="$TRUST_STATE_DIR/$project-dependabot-held-$num"
          if [[ "$title" =~ from[[:space:]]+[^0-9]*([0-9]+)[^[:space:]]*[[:space:]]+to[[:space:]]+[^0-9]*([0-9]+) ]] \
             && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; then
            # Same major, still cooling down: clears by itself, log once.
            if [ ! -f "$held" ]; then
              _trust_log "$project: dependabot PR #$num (\"$title\") waits until ${TRUST_DEPENDABOT_MIN_AGE_H}h old before auto-merge"
              mkdir -p "$TRUST_STATE_DIR" 2>/dev/null && touch "$held" 2>/dev/null
            fi
          else
            # Major, grouped or unparseable: never auto-merged; tell the owner.
            trust_notify_once "$project" dependabot "$num" \
              "Dependabot PR #$num on $project (\"$title\") is a major or grouped bump — not auto-merged, needs the owner. https://github.com/$TRUST_OWNER/$project/pull/$num"
          fi
        else
          keep="$keep $num"
        fi
        ;;
      full:merge) ;;
      *)
        local what="PR"
        [ "$cross" = "true" ] && what="fork PR"
        trust_notify_once "$project" pr "$num" \
          "External $what #$num on $project by ${author:-unknown} — not touched by the factory. https://github.com/$TRUST_OWNER/$project/pull/$num"
        ;;
    esac
  done < <(_trust_rows "$json")
  _trust_keep "$keep" "$json"
}

# trust_comments_ok <project> issue|pr <number> — true when every comment (and
# for a PR every review and review comment) is by a trusted author. Call right
# before an archon run that reads the thread. Fails closed: a listing that
# cannot be read counts as untrusted for this tick. A stranger's comment blocks
# the item until the owner deletes it (hiding it does not: the API still
# returns it).
trust_comments_ok() {
  local project="$1" kind="$2" num="$3" repo="$TRUST_OWNER/$1" logins l bad=""
  local -a eps=("repos/$repo/issues/$num/comments")
  [ "$kind" = "pr" ] && eps+=("repos/$repo/pulls/$num/reviews" "repos/$repo/pulls/$num/comments")
  local ep
  for ep in "${eps[@]}"; do
    if ! logins=$(gh api --paginate "$ep" --jq '.[].user.login // ""' 2>/dev/null); then
      _trust_log "$project: $kind #$num — could not list $ep, not starting archon this tick"
      return 1
    fi
    [ -n "$logins" ] || continue
    while IFS= read -r l; do
      [ -n "$l" ] || { bad="$bad unknown"; continue; }
      trust_commenter_ok "$l" || bad="$bad $l"
    done <<<"$logins"
  done
  [ -z "$bad" ] && return 0
  local path=issues; [ "$kind" = "pr" ] && path=pull
  trust_notify_once "$project" "$kind-comment" "$num" \
    "$kind #$num on $project has comments by untrusted authors (${bad# }) — the factory will not run archon on it until they are deleted. https://github.com/$TRUST_OWNER/$project/$path/$num"
  return 1
}
