#!/usr/bin/env bash
# Deadlines for parked factory work, and a per-repo stall detector.
#
# Why: on 2026-10-26, 15 finished, CI-green PRs had sat for 3-6 days.
# pr-maintenance logged "needs a human" about 130 times for each, nobody read
# the log, and pipeline-status showed green. Parked work now has a clock: the
# crons that see it mark it every tick, and pipeline-health escalates what
# stays parked.
#
#   source "$SCRIPT_DIR/lib/deadlines.sh"
#   deadline_mark <kind> <project> <number> <sha> <branch> <reason>   # seen this tick
#   deadline_escalate          # pipeline-health: ntfy after 12h, salvage after 24h
#   stall_check <project>      # pipeline-health: 0 merged PRs in 24h with open work
#   stall_note <project>       # pipeline-status: "" or the repo's stall line
#
# Kinds (who marks them):
#   failed-run    pr-maintenance: a PR left by a failed archon run that is out
#                 of review retries or not retryable (not review-stage, worktree
#                 gone).
#   ops-merge     pr-maintenance: a CLEAN PR on a protected repo that touches
#                 ops/ or .github/, so it needs a human merge.
#   untrusted     pr-maintenance: a PR with a stranger's comment or review.
#   needs-author  pipeline-health: a trusted issue labelled needs-author.
#
# One file per item in DEADLINE_STATE_DIR, "<kind>--<project>--<number>", of
# key=value lines: first_seen, last_seen (epochs), sha, branch, reason,
# notified (epoch of the last ntfy) and salvaged (the sha it was last salvaged
# or commented at). Written via tmp+mv; two crons write here. A mark keeps
# first_seen, notified and salvaged, so a salvage that pushes a new head does
# not restart the clock. An item is current while last_seen is within
# DEADLINE_FRESH_SECONDS (both crons tick every 30 min under the throttle);
# only current items are escalated, so a PR that merged is never chased. An
# item unseen for DEADLINE_GONE_SECONDS is resolved and removed.
#
# Escalation (deadline_escalate, needs notify_checked and log from the caller):
#   >= DEADLINE_NOTIFY_SECONDS (12h): one batched ntfy for every such item,
#     at most once per item per day.
#   >= DEADLINE_SALVAGE_SECONDS (24h): failed-run PRs and needs-author issues
#     get one archon-assist salvage per item per head sha (issues: once),
#     gated on quota_may_launch and gh_factory_may_launch, at most
#     DEADLINE_SALVAGE_MAX per tick, and never on a protected repo
#     (ARCHON_RUNAS_PROTECTED_REPOS: the ntfy is enough there). Comments are
#     re-checked right before the launch: an untrusted thread is never handed
#     to an agent. ops-merge PRs get one comment per head sha instead.
#     untrusted items get the ntfy only.

[ -n "${_ARCHON_DEADLINES_SH:-}" ] && return 0
_ARCHON_DEADLINES_SH=1

DEADLINE_STATE_DIR="${DEADLINE_STATE_DIR:-$HOME/.archon/state/deadlines}"
DEADLINE_NOTIFY_SECONDS="${DEADLINE_NOTIFY_SECONDS:-43200}"
DEADLINE_SALVAGE_SECONDS="${DEADLINE_SALVAGE_SECONDS:-86400}"
DEADLINE_RENOTIFY_SECONDS="${DEADLINE_RENOTIFY_SECONDS:-86400}"
DEADLINE_FRESH_SECONDS="${DEADLINE_FRESH_SECONDS:-3600}"
DEADLINE_GONE_SECONDS="${DEADLINE_GONE_SECONDS:-21600}"
DEADLINE_SALVAGE_MAX="${DEADLINE_SALVAGE_MAX:-2}"
DEADLINE_OWNER="${DEADLINE_OWNER:-alexsiri7}"
# Per-repo stall markers, read by ops/bin/pipeline-status.
STALL_STATE_DIR="${STALL_STATE_DIR:-$HOME/.archon/state/stalled}"
STALL_WINDOW_SECONDS="${STALL_WINDOW_SECONDS:-86400}"
# Open PRs carrying these labels are parked on purpose and are not "work".
STALL_IGNORE_LABELS="${STALL_IGNORE_LABELS:-hold needs-owner-review}"

# deadline_now — the clock (DEADLINE_NOW overrides it for tests).
deadline_now() { echo "${DEADLINE_NOW:-$(date +%s)}"; }

_deadline_clean() { local v="${1//[$'\n\r']/ }"; printf '%s' "$v"; }

# deadline_get <file> <key> — one value ("" when absent). Always exits 0: the
# callers run under set -e.
deadline_get() {
  [ -r "$1" ] || return 0
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null || true
}

# _deadline_write <file> <key=value lines...> — atomic replace.
_deadline_write() {
  local f="$1" tmp; shift
  tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$@" > "$tmp" && mv -f "$tmp" "$f"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# deadline_mark <kind> <project> <number> <sha> <branch> <reason> — record that
# the item is parked this tick. Never fails the caller.
deadline_mark() {
  local kind="$1" project="$2" num="$3" sha="${4:--}" branch="${5:-}" reason
  reason=$(_deadline_clean "${6:-}")
  case "$kind" in failed-run|ops-merge|untrusted|needs-author) ;; *) return 0 ;; esac
  [[ "$num" =~ ^[0-9]+$ && "$project" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  mkdir -p "$DEADLINE_STATE_DIR" 2>/dev/null || return 0
  local f="$DEADLINE_STATE_DIR/$kind--$project--$num" now first notified salvaged
  now=$(deadline_now)
  first=$(deadline_get "$f" first_seen); [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
  notified=$(deadline_get "$f" notified); [[ "$notified" =~ ^[0-9]+$ ]] || notified=0
  salvaged=$(deadline_get "$f" salvaged)
  _deadline_write "$f" "kind=$kind" "project=$project" "number=$num" \
    "first_seen=$first" "last_seen=$now" "sha=$(_deadline_clean "$sha")" \
    "branch=$(_deadline_clean "$branch")" "reason=$reason" \
    "notified=$notified" "salvaged=$(_deadline_clean "$salvaged")" 2>/dev/null || true
  return 0
}

# _deadline_set <file> <key> <value> — rewrite one key, keeping the rest.
_deadline_set() {
  local f="$1" k="$2" v line
  local -a lines=()
  v=$(_deadline_clean "$3")
  while IFS= read -r line; do
    case "$line" in "$k="*) ;; *) lines+=("$line") ;; esac
  done < "$f"
  lines+=("$k=$v")
  _deadline_write "$f" "${lines[@]}"
}

_deadline_url() { # <project> <kind> <number>
  local path=pull; [ "$2" = needs-author ] && path=issues
  echo "https://github.com/$DEADLINE_OWNER/$1/$path/$3"
}

_deadline_protected() { # <project> — a repo whose PRs need a human merge
  case " ${ARCHON_RUNAS_PROTECTED_REPOS:-interstellarai.net} " in *" $1 "*) return 0 ;; esac
  return 1
}

# deadline_prompt <kind> <project> <number> <reason> — the salvage prompt.
deadline_prompt() {
  local kind="$1" project="$2" num="$3" reason="$4" what
  if [ "$kind" = needs-author ]; then
    what="Issue #$num on $DEADLINE_OWNER/$project has waited over 24 hours for an answer from its author (label needs-author). Review the issue, its open question and any linked PR. If you can settle it from the repo, the issue and its specs, do the work, open a PR, and merge it only if your own review of it passes and every check is green."
  else
    what="PR #$num on $DEADLINE_OWNER/$project has been parked for over 24 hours: $reason. Review the PR: its diff, its linked issue and its CI. If it is sound, fix what it needs, push, and merge it only if your own review of it passes and every check is green."
  fi
  printf '%s %s' "$what" "Otherwise leave one clear comment on it saying what is wrong and the exact decision a human must make, and change nothing else. Never write to, migrate or delete production data. Do not touch ops/ or .github/."
}

# _deadline_launch <project> <prompt> <logfile> — archon-assist in the
# project's clone, detached (the same launch check_pr_ci_retry makes).
_deadline_launch() {
  local repo_dir="$BASE_DIR/$1"
  (
    cd "$repo_dir" || exit 1
    CLAUDECODE=0 nohup archon workflow run archon-assist "$2" > "$3" 2>&1 &
    disown
  )
}

# deadline_escalate — prune, ntfy, salvage. Call once per pipeline-health tick,
# after archon_runs_snapshot.
deadline_escalate() {
  [ -d "$DEADLINE_STATE_DIR" ] || return 0
  local now f kind project num first last sha branch reason notified salvaged age
  local -a batch=() batch_files=()
  local launched=0 gate="" ckind rc logf   # gate: "" unchecked, ok, or why launches are held
  now=$(deadline_now)
  for f in "$DEADLINE_STATE_DIR"/*--*--*; do
    [ -f "$f" ] || continue
    # Item files only, not a writer's half-done mktemp file.
    [[ "${f##*/}" =~ ^[a-z-]+--[A-Za-z0-9._-]+--[0-9]+$ ]] || continue
    kind=$(deadline_get "$f" kind); project=$(deadline_get "$f" project)
    num=$(deadline_get "$f" number)
    first=$(deadline_get "$f" first_seen); last=$(deadline_get "$f" last_seen)
    [[ "$first" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ && "$num" =~ ^[0-9]+$ ]] || { rm -f "$f"; continue; }
    if [ $((now - last)) -ge "$DEADLINE_GONE_SECONDS" ]; then
      log "deadline: $kind $project #$num not seen for $(( (now - last) / 3600 ))h — resolved"
      rm -f "$f"; continue
    fi
    [ $((now - last)) -le "$DEADLINE_FRESH_SECONDS" ] || continue
    age=$((now - first))
    [ "$age" -ge "$DEADLINE_NOTIFY_SECONDS" ] || continue
    sha=$(deadline_get "$f" sha); branch=$(deadline_get "$f" branch)
    reason=$(deadline_get "$f" reason)
    notified=$(deadline_get "$f" notified); [[ "$notified" =~ ^[0-9]+$ ]] || notified=0
    salvaged=$(deadline_get "$f" salvaged)

    if [ $((now - notified)) -ge "$DEADLINE_RENOTIFY_SECONDS" ]; then
      batch+=("$project $kind #$num, $((age / 3600))h: $reason $(_deadline_url "$project" "$kind" "$num")")
      batch_files+=("$f")
    fi

    [ "$age" -ge "$DEADLINE_SALVAGE_SECONDS" ] || continue
    [ "$salvaged" = "$sha" ] && continue
    case "$kind" in
      untrusted) continue ;;
      ops-merge)
        if gh pr comment "$num" --repo "$DEADLINE_OWNER/$project" --body "This PR has waited over 24 hours for a human merge: $reason. The factory does not merge ops/ or .github/ changes on its own. Review and merge it, or close it." >/dev/null 2>&1; then
          _deadline_set "$f" salvaged "$sha"
          log "deadline: $project PR #$num — commented that it needs a human merge"
        else
          log "deadline: $project PR #$num — could not comment, retrying next tick"
        fi
        continue ;;
      failed-run|needs-author) ;;
      *) continue ;;
    esac
    if _deadline_protected "$project"; then
      continue
    fi
    if [ "$launched" -ge "$DEADLINE_SALVAGE_MAX" ]; then
      log "deadline: $kind $project #$num due for salvage — $DEADLINE_SALVAGE_MAX already launched this tick"
      continue
    fi
    if [ -z "$gate" ]; then
      gate=ok
      if ! quota_may_launch "pipeline-health"; then gate="Claude rate limit in effect"
      elif ! gh_factory_may_launch "pipeline-health"; then gate="factory GitHub identity blocked"
      fi
    fi
    if [ "$gate" != ok ]; then
      log "deadline: $kind $project #$num due for salvage — held: $gate"
      continue
    fi
    if ! archon_runs_known; then
      log "deadline: $kind $project #$num due for salvage — no archon run snapshot this tick"
      continue
    fi
    if [ -n "$branch" ] && archon_branch_running_run "$branch" >/dev/null; then
      log "deadline: $kind $project #$num due for salvage — a running archon run holds $branch"
      continue
    fi
    ckind="pr"; rc=0; [ "$kind" = needs-author ] && ckind="issue"
    trust_comments_ok "$project" "$ckind" "$num" || rc=$?
    if [ "$rc" != 0 ]; then
      log "deadline: $kind $project #$num due for salvage — comments untrusted or unreadable, ntfy only"
      continue
    fi
    if ! _deadline_set "$f" salvaged "$sha"; then
      log "deadline: $kind $project #$num — could not record the salvage, not launching"
      continue
    fi
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    logf="$LOG_DIR/deadline-salvage-$project-$num-$(date +%Y%m%d-%H%M%S).log"
    log "deadline: $kind $project #$num parked $((age / 3600))h — firing archon-assist salvage (log $logf)"
    _deadline_launch "$project" "$(deadline_prompt "$kind" "$project" "$num" "$reason")" "$logf"
    launched=$((launched + 1))
  done

  [ "${#batch[@]}" -gt 0 ] || return 0
  local body
  body=$(printf '%s\n' "${batch[@]}")
  if notify_checked "Factory: ${#batch[@]} item(s) parked over 12h" "$body" high warning; then
    for f in "${batch_files[@]}"; do _deadline_set "$f" notified "$now" || true; done
    log "deadline: ntfy sent for ${#batch[@]} parked item(s)"
  else
    log "deadline: ntfy for ${#batch[@]} parked item(s) failed, retrying next tick"
  fi
}

# stall_check <project> — merged PRs in the last STALL_WINDOW_SECONDS, against
# open work: trusted (merge-level) PRs older than the window that carry none of
# STALL_IGNORE_LABELS. Merged PRs, not commits: release and requirement bumps
# land on main directly. Open work and none merged: write
# $STALL_STATE_DIR/<project> ("since=", "open=", "notified=") and ntfy once
# per episode (retried until delivered); otherwise clear it. A read that fails
# changes nothing.
stall_check() {
  local project="$1" now since merged open f json
  now=$(deadline_now)
  since=$(date -u -d "@$((now - STALL_WINDOW_SECONDS))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 0
  if ! merged=$(gh pr list --repo "$DEADLINE_OWNER/$project" --state merged \
        --search "merged:>=$since" --limit 100 --json number --jq 'length' 2>/dev/null) \
     || ! [[ "$merged" =~ ^[0-9]+$ ]]; then
    log "stall: $project — could not count merged PRs, skipping"
    return 0
  fi
  if ! json=$(gh pr list --repo "$DEADLINE_OWNER/$project" --state open --limit 100 \
        --json number,labels,createdAt,author,isCrossRepository,headRefName,title,body 2>/dev/null); then
    log "stall: $project — could not list open PRs, skipping"
    return 0
  fi
  open=$(printf '%s' "$json" | TRUST_QUIET=1 trust_filter_prs "$project" merge 2>/dev/null \
    | jq --arg since "$since" --arg ignore "$STALL_IGNORE_LABELS" '
        ($ignore | split(" ") | map(select(. != ""))) as $ig
        | [.[] | select(.createdAt < $since)
               | select(any((.labels // [])[].name; . as $l | $ig | any(.[]; . == $l)) | not)]
        | length' 2>/dev/null)
  [[ "$open" =~ ^[0-9]+$ ]] || { log "stall: $project — could not read open PRs, skipping"; return 0; }
  f="$STALL_STATE_DIR/$project"
  if [ "$merged" -gt 0 ] || [ "$open" -eq 0 ]; then
    if [ -f "$f" ]; then
      log "stall: $project — moving again ($merged merged in 24h, $open open)"
      rm -f "$f"
    fi
    return 0
  fi
  mkdir -p "$STALL_STATE_DIR" 2>/dev/null || return 0
  local first notified
  first=$(deadline_get "$f" since); [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
  notified=$(deadline_get "$f" notified); [[ "$notified" =~ ^[0-9]+$ ]] || notified=0
  if [ "$notified" = 0 ]; then
    if notify_checked "Factory stalled: $project" \
         "$project: $open open PR(s) older than 24h and none merged in 24h. https://github.com/$DEADLINE_OWNER/$project/pulls" \
         high warning; then
      notified="$now"
    fi
  fi
  _deadline_write "$f" "since=$first" "open=$open" "notified=$notified" 2>/dev/null || true
  log "stall: $project — $open open PR(s) older than 24h, 0 merged in 24h"
}

# stall_note <project> — "" when the repo is not stalled, else a short line
# for pipeline-status.
stall_note() {
  local f="$STALL_STATE_DIR/$1" since open
  [ -f "$f" ] || return 0
  since=$(deadline_get "$f" since); open=$(deadline_get "$f" open)
  [[ "$since" =~ ^[0-9]+$ ]] || since=""
  printf 'STALLED: %s open PR(s), 0 merged in 24h%s' "${open:-?}" \
    "${since:+ (since $(date -d "@$since" '+%F %H:%M' 2>/dev/null || echo "?"))}"
}
