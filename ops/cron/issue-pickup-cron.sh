#!/usr/bin/env bash
# issue-pickup-cron.sh — run every 15 minutes from cron.
# Autonomous pipeline: auto-labels new issues, then picks up one per repo
# per tick and fires archon-ship on the oldest queued one — or, with the
# owner's LACHESIS_PICKUP switch on, on the issue Lachesis next_issue offers
# (lachesis_pick; ops/cron/README.md "Lachesis pickup").
#
# Crontab:
#   */15 * * * * <repo>/ops/cron/issue-pickup-cron.sh >> ~/.local/state/archon-cron/logs/issue-pickup.log 2>&1

set -uo pipefail

# Cron has a minimal PATH; prepend where archon / gh / bun live.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-as.sh
source "$SCRIPT_DIR/lib/run-as.sh"
# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
load_archon_projects DEFAULT_PROJECTS
# shellcheck source=lib/throttle.sh
source "$SCRIPT_DIR/lib/throttle.sh"
should_tick "issue-pickup" || exit 0
runas_may_launch "issue-pickup" || exit 0
# shellcheck source=lib/archon-active-runs.sh
source "$SCRIPT_DIR/lib/archon-active-runs.sh"
archon_runs_snapshot
# shellcheck source=lib/ship-breaker.sh
source "$SCRIPT_DIR/lib/ship-breaker.sh"
# shellcheck source=lib/quota-pause.sh
source "$SCRIPT_DIR/lib/quota-pause.sh"
# Checked once per tick: while the Claude account is rate limited no phase
# below launches archon (label hygiene still runs). See lib/quota-pause.sh.
QUOTA_HELD=0
quota_may_launch "issue-pickup" || QUOTA_HELD=1

# Age (seconds) after which an issue labeled archon:in-progress with no
# corresponding live archon process and no open PR is considered stuck and
# re-queued. Archon workflows usually finish in under an hour; 2h gives
# plenty of margin for slow CI and rate-limit backoff.
STUCK_AGE_SECONDS=7200
BASE_DIR="/mnt/ext-fast"
LOG_PREFIX="[issue-pickup]"

# Labels that make an issue a candidate for autonomous processing.
INGEST_LABELS=("enhancement" "bug")

# Labels archon already manages — presence of any of these means "don't re-queue".
ARCHON_LABELS=("archon:queued" "archon:in-progress" "archon:triage-in-progress" "archon:done" "archon:failed" "archon:skipped" "archon:blocked")

# shellcheck source=lib/human-labels.sh
source "$SCRIPT_DIR/lib/human-labels.sh"
# Every issue list below is passed through trust_filter_issues: an issue whose
# author is not trusted is never triaged, labelled, queued, re-queued, deduped
# or handed to archon, and the owner gets one ntfy about it. Before any archon
# run the thread's comments must be trusted too (trust_comments_ok).
# shellcheck source=lib/trust.sh
source "$SCRIPT_DIR/lib/trust.sh"
# shellcheck source=lib/heartbeat.sh
source "$SCRIPT_DIR/lib/heartbeat.sh"
# Bridge-filed issues are screened (heuristics + classifier) before any of the
# phases below may act on them; see lib/screen.sh.
# shellcheck source=lib/screen.sh
source "$SCRIPT_DIR/lib/screen.sh"
# Lachesis pickup (owner's switch, off by default): the issue to work comes from
# Lachesis next_issue, not the archon:queued label scan, and labels record run
# state only. See lib/lachesis.sh and lachesis_pick below.
# shellcheck source=lib/lachesis.sh
source "$SCRIPT_DIR/lib/lachesis.sh"
LACHESIS_PICKUP_ON=0
lachesis_pickup_enabled && LACHESIS_PICKUP_ON=1

PROJECTS=("${DEFAULT_PROJECTS[@]}")
[ $# -gt 0 ] && PROJECTS=("$@")

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

# Per-tick, per-project summary state. Reset at the start of each project
# iteration, populated by the phases, emitted after pick_and_fire.
SUMMARY_IN_PROGRESS=0
SUMMARY_STALE=0
SUMMARY_QUEUED=0
SUMMARY_BLOCKED=0
SUMMARY_PROMOTED=0
SUMMARY_DEDUPED=0
SUMMARY_SETTLED=0
SUMMARY_ACTION="none"
SUMMARY_NOTE=""
# Issue numbers this tick flipped to archon:queued, for pick_and_fire to
# union with its own search — see the comment there. auto_queue owns
# QUEUED_ISSUES, promote_unblocked owns PROMOTED_ISSUES.
QUEUED_ISSUES=()
PROMOTED_ISSUES=()

ensure_labels() {
  local repo="$1"
  for label in archon:queued archon:in-progress archon:triage-in-progress archon:done archon:failed archon:skipped archon:blocked; do
    gh label create "$label" --repo "alexsiri7/$repo" \
      --color "c2e0c6" --description "Archon pipeline state" 2>/dev/null || true
  done
  # The ship circuit breaker parks with it (lib/ship-breaker.sh); a missing
  # label fails its whole `gh issue edit`.
  gh label create "manual-review" --repo "alexsiri7/$repo" \
    --color "d93f0b" --description "Needs a human before the factory touches it" 2>/dev/null || true
  gh label create "$TRUST_APPROVED_LABEL" --repo "alexsiri7/$repo" \
    --color "0e8a16" --description "Owner vetted: the factory may work this bridge-filed issue" 2>/dev/null || true
  gh label create "$SCREEN_AUTO_LABEL" --repo "alexsiri7/$repo" \
    --color "c2e0c6" --description "Passed automated screening: the factory may work this bridge-filed issue" 2>/dev/null || true
  gh label create "$SCREEN_HOLD_LABEL" --repo "alexsiri7/$repo" \
    --color "d93f0b" --description "Held by the factory for the owner" 2>/dev/null || true
}

# Returns 0 (blocked) if the issue has at least one open "blocker" — defined
# as either an explicit `blocked_by` dependency OR an open sub-issue (child).
# Returns 1 (clear) otherwise.
#
# The child rule lets PRD/epic issues naturally park themselves while their
# phase children are in flight — no archon:skipped hygiene needed. When the
# last child closes, the PRD unblocks and gets picked up, which triggers a
# finalization archon run over the completed work.
#
# On API error, defaults to "clear" — we'd rather let a candidate run than
# freeze the pipeline on a transient failure; worst case is a phase runs
# slightly out of order.
has_open_blockers() {
  local project="$1" issue_num="$2"
  local blockers children
  blockers=$(gh api "repos/alexsiri7/$project/issues/$issue_num/dependencies/blocked_by" \
    --jq '[.[] | select(.state == "open")] | length' 2>/dev/null || echo 0)
  if [ "${blockers:-0}" -gt 0 ]; then
    return 0
  fi
  children=$(gh api "repos/alexsiri7/$project/issues/$issue_num/sub_issues" \
    --jq '[.[] | select(.state == "open")] | length' 2>/dev/null || echo 0)
  [ "${children:-0}" -gt 0 ]
}

has_archon_label() {
  local labels="$1"
  for al in "${ARCHON_LABELS[@]}"; do
    echo "$labels" | grep -q "\"$al\"" && return 0
  done
  return 1
}

has_human_label() {
  local labels="$1"
  for hl in "${HUMAN_LABELS[@]}"; do
    echo "$labels" | grep -q "\"$hl\"" && return 0
  done
  return 1
}

# --- Phase 0.5: auto-triage one issue that has no ingest label ---
# Picks the oldest untriaged issue (no archon:* and no bug/enhancement label,
# no human-intent label) and fires archon-triage-issue as a background workflow.
# One issue per tick, matching the pick_and_fire pattern for fixes. Blocked
# candidates are parked as archon:blocked on the way past, without a triage run.
# Only called when no fix workflow is already running for this repo (gated in
# the main loop by checking SUMMARY_ACTION after pick_and_fire).
auto_triage() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"

  if [ ! -d "$repo_dir/.git" ]; then
    return
  fi
  [ "$QUOTA_HELD" = 1 ] && return

  # Don't stack — skip if any archon workflow is already running for this repo.
  if pgrep -fa "archon workflow run.*--cwd.*$repo_dir" >/dev/null 2>&1; then
    return
  fi
  if pgrep -fa "archon workflow run" 2>/dev/null \
      | grep -qE "(^|[[:space:]=/])$project([[:space:]/]|\$)"; then
    return
  fi
  # Parked-run guard: sdlc runs suspended at a wait: node have no process.
  if archon_run_active "$repo_dir" "$project" '^archon-(ship|fix-github-issue|triage-issue)$'; then
    return
  fi

  local issues
  issues=$(gh issue list --repo "alexsiri7/$project" --state open --limit 100 \
    --json number,labels,createdAt,author,title,body 2>/dev/null || echo "[]")
  issues=$(trust_filter_issues "$project" <<<"$issues")

  local now_sec; now_sec=$(date +%s)
  local triage_issue=""

  # archon-triage-issue is the only thing that removes archon:triage-in-progress,
  # so a run that died before classifying (2026-09-11: the weekly rate limit
  # killed extract-issue-number in 20s) leaves a label nothing revisits and
  # pipeline-health counts as pending work forever. The guards above proved no
  # triage run is live or parked for this repo; once the label is older than
  # STUCK_AGE_SECONDS, drop it and let this tick's scan classify the issue.
  local stale_num
  while IFS= read -r stale_num; do
    [ -n "$stale_num" ] || continue
    local labeled_at labeled_sec label_age
    # --paginate: the API lists events oldest first, 30 to a page, so on a long
    # thread page one ends days before the label was last added (see
    # unstick_stale). Each page prints its matches; the last line is the newest.
    labeled_at=$(gh api --paginate "repos/alexsiri7/$project/issues/$stale_num/events" \
      --jq '.[] | select(.event=="labeled" and .label.name=="archon:triage-in-progress") | .created_at' 2>/dev/null | tail -n 1)
    [ -z "$labeled_at" ] || [ "$labeled_at" = "null" ] && continue
    labeled_sec=$(date -d "$labeled_at" +%s 2>/dev/null || echo 0)
    label_age=$((now_sec - labeled_sec))
    [ "$label_age" -lt "$STUCK_AGE_SECONDS" ] && continue
    log "$project: #$stale_num — triage-in-progress for ${label_age}s with no run, retrying triage"
    if gh issue edit "$stale_num" --repo "alexsiri7/$project" \
        --remove-label "archon:triage-in-progress" 2>/dev/null; then
      issues=$(echo "$issues" | jq --argjson n "$stale_num" \
        'map(if .number == $n then .labels |= map(select(.name != "archon:triage-in-progress")) else . end)')
    else
      log "$project: #$stale_num — could not remove archon:triage-in-progress"
    fi
  done < <(echo "$issues" | jq -r '.[] | select(.labels | map(.name) | index("archon:triage-in-progress")) | .number' 2>/dev/null)

  while IFS= read -r row; do
    local num labels_json created created_sec age
    num=$(echo "$row" | jq -r '.number')
    labels_json=$(echo "$row" | jq -c '[.labels[].name]')
    created=$(echo "$row" | jq -r '.createdAt')
    created_sec=$(date -d "$created" +%s 2>/dev/null || echo 0)
    age=$((now_sec - created_sec))

    [ "$age" -lt 300 ] && continue
    has_archon_label "$labels_json" && continue
    echo "$labels_json" | grep -q '"archon:triage-in-progress"' && continue

    local has_ingest=0
    for il in "${INGEST_LABELS[@]}"; do
      echo "$labels_json" | grep -q "\"$il\"" && has_ingest=1 && break
    done
    [ "$has_ingest" = "1" ] && continue

    has_human_label "$labels_json" && continue

    # An untriaged issue with open blockers cannot be picked up until they
    # close, so classifying it now buys nothing. Park it directly and keep
    # scanning — otherwise a freshly-filed blocked_by chain spends every tick's
    # one triage run on leaves and the root waits for the whole chain. Fixes #63.
    if has_open_blockers "$project" "$num"; then
      log "$project: labeling #$num archon:blocked (untriaged, open blockers)"
      if gh issue edit "$num" --repo "alexsiri7/$project" \
          --add-label "archon:blocked" 2>/dev/null; then
        SUMMARY_BLOCKED=$((SUMMARY_BLOCKED + 1))
      else
        log "$project: #$num — could not add archon:blocked label"
      fi
      continue
    fi

    # archon-triage-issue reads the thread; a stranger's comment on a trusted
    # issue is untrusted input all the same. Skip it (owner ntfy'd once).
    trust_comments_ok "$project" issue "$num" || continue

    triage_issue="$num"
    break
  done < <(echo "$issues" | jq -c 'sort_by(.createdAt)[]' 2>/dev/null)

  [ -z "$triage_issue" ] && return

  gh issue edit "$triage_issue" --repo "alexsiri7/$project" \
    --add-label "archon:triage-in-progress" 2>/dev/null || true

  cd "$repo_dir"
  mkdir -p .archon-logs
  local logf=".archon-logs/cron-triage-$triage_issue-$(date +%Y%m%d-%H%M%S).log"
  CLAUDECODE=0 nohup archon workflow run archon-triage-issue \
    "triage #$triage_issue" --no-worktree >"$logf" 2>&1 &
  disown
  log "$project: triage launched for #$triage_issue (pid=$!, log=$logf)"
  SUMMARY_ACTION="triage #$triage_issue"
}

# --- Phase -1: close duplicate Sentry issues ---
# Every Sentry crash is filed twice about a second apart: once by Sentry's own
# GitHub app (Alert Rule action, body "Sentry Issue: [X](…/issues/<id>/)") and
# once by workers/sentry-bridge (body carries "**Sentry issue ID:** <id>" and the
# same link). Without this both get worked (#103: un-reminder #431/#432). The
# `sentry` label is no key — the app's issues do not carry it — so issues are
# grouped by the sentry.io/issues/<id> link in their body, across open issues and
# the 100 most recently closed-completed ones. Issues closed any other way
# (including by this phase) never survive, or tick N+1 would close tick N's
# survivor as a duplicate of the issue tick N closed.
#
# Survivor, first match wins: a closed issue (already worked), an in-progress
# one (never kill a live run), the bridge's (it is queued at filing time and
# carries the sentry label), the lowest number. Every other open member is closed
# as its duplicate, except in-progress and human-owned ones. Only the two filed
# shapes are ever closed: a hand-written issue that pastes the link (say, a
# regression report) must not be closed against the old fixed issue.
dedupe_sentry() {
  local project="$1"
  local open_json closed_json
  # Trusted authors only, open and closed: a stranger can file a Sentry-shaped
  # body and close it as completed, which would make it the survivor the real
  # Sentry issues get closed against.
  open_json=$(gh issue list --repo "alexsiri7/$project" --state open --limit 100 \
    --json number,body,labels,author 2>/dev/null || echo "[]")
  # Author only: this phase starts no archon run, and the issues it dedupes
  # are the Sentry bridges' own, which the bridge check would drop.
  open_json=$(TRUST_AUTHOR_ONLY=1 trust_filter_issues "$project" <<<"$open_json")
  closed_json=$(gh issue list --repo "alexsiri7/$project" --state closed --limit 100 \
    --json number,body,stateReason,author 2>/dev/null || echo "[]")
  closed_json=$(TRUST_AUTHOR_ONLY=1 TRUST_QUIET=1 trust_filter_issues "$project" <<<"$closed_json")

  local num survivor sentry_id labels_json
  while IFS=$'\t' read -r num survivor sentry_id labels_json; do
    [ -n "$num" ] || continue
    if echo "$labels_json" | grep -q '"archon:in-progress"'; then
      log "$project: #$num duplicates #$survivor (Sentry $sentry_id) but is in progress, leaving it"
      continue
    fi
    if has_human_label "$labels_json"; then
      log "$project: #$num duplicates #$survivor (Sentry $sentry_id) but is human-owned, leaving it"
      continue
    fi
    if gh issue close "$num" --repo "alexsiri7/$project" --duplicate-of "$survivor" \
        --comment "Duplicate of #$survivor: both carry Sentry issue $sentry_id. Closed by issue-pickup's Sentry dedupe." >/dev/null 2>&1; then
      log "$project: #$num closed as duplicate of #$survivor (Sentry $sentry_id)"
      SUMMARY_DEDUPED=$((SUMMARY_DEDUPED + 1))
    else
      log "$project: #$num — could not close as duplicate of #$survivor"
    fi
  done < <(printf '%s\n%s\n' "$open_json" "$closed_json" | jq -rs '
    def sentry_id: [(.body // "") | capture("sentry\\.io/issues/(?<id>[0-9]+)")][0].id;
    (.[0] | map({number, open: true, labels: [.labels[].name],
                 bridge: ((.body // "") | test("\\*\\*Sentry issue ID:\\*\\*")),
                 app: ((.body // "") | test("^Sentry Issue: \\[")),
                 id: sentry_id})) as $open
    | (.[1] | map(select(.stateReason == "COMPLETED")
                  | {number, open: false, labels: [], bridge: false, id: sentry_id})) as $closed
    | $open + $closed | map(select(.id != null)) | group_by(.id)[]
    | select(length > 1 and any(.open))
    | ((map(select(.open | not)) | min_by(.number))
       // (map(select(.labels | index("archon:in-progress"))) | min_by(.number))
       // (map(select(.bridge)) | min_by(.number))
       // min_by(.number)) as $survivor
    | .[] | select(.open and (.bridge or .app) and .number != $survivor.number)
    | [.number, $survivor.number, .id, (.labels | tojson)] | @tsv' 2>/dev/null)
}

# --- Phase -1b: re-check parked "No delivery needed" verdicts ---
# settle-ship-outcome.sh parks a verdict GitHub cannot confirm when the run ends
# (the PR it names is not merged yet, an epic still has an open sub-issue), and
# everything parked before #104 was parked unconfirmed. Nothing else ever looks
# at them again (#103), so every tick re-runs the same confirmation (--recheck)
# on each open archon:skipped issue whose last comment is that parked verdict.
# A human comment after the verdict opts the issue out; so does the close
# comment on a reopened issue, which lacks the park marker. Human-intent labels
# do not: they keep autonomous work from starting, and this starts none — the
# run-time settle already closes such issues on the same evidence.
settle_parked() {
  local project="$1"
  local issues nums num verdict_file
  issues=$(gh issue list --repo "alexsiri7/$project" --state open --label "archon:skipped" \
    --limit 100 --json number,comments,author 2>/dev/null || echo "[]")
  # Author only: a re-check starts no archon run; it closes or leaves the issue.
  issues=$(TRUST_AUTHOR_ONLY=1 trust_filter_issues "$project" <<<"$issues")
  # issue list returns at most the oldest 100 comments of each issue, so on a
  # longer thread [-1] is not the last comment and could hide a human's reply.
  nums=$(echo "$issues" | jq -r '.[]
    | select((.comments // []) | length < 100)
    | ((.comments // [])[-1].body // "") as $b
    | select(($b | startswith("archon-ship finished without a PR: No delivery needed: "))
             and ($b | contains("\n\nParked as archon:skipped.")))
    | .number' 2>/dev/null)
  [ -n "$nums" ] || return 0

  verdict_file=$(mktemp)
  for num in $nums; do
    # The verdict is posted under the owner's token. Anyone can post a comment
    # that reads like one, so only a trusted author's verdict is re-checked.
    local by
    by=$(echo "$issues" | jq -r --argjson n "$num" '.[] | select(.number == $n) | .comments[-1].author.login // ""')
    trust_commenter_ok "$by" || continue
    echo "$issues" | jq -r --argjson n "$num" '.[] | select(.number == $n)
      | .comments[-1].body | sub("^archon-ship finished without a PR: "; "")' > "$verdict_file"
    if "$SCRIPT_DIR/lib/settle-ship-outcome.sh" --recheck "$project" "$num" "$verdict_file"; then
      SUMMARY_SETTLED=$((SUMMARY_SETTLED + 1))
    fi
  done
  rm -f "$verdict_file"
}

# --- Phase 0: un-stick stale archon:in-progress issues ---
# If an issue has been archon:in-progress for a long time and there's no
# running archon process for it and no open PR that references it, treat it
# as stuck (e.g. previous run died from rate-limit or crash) and re-queue.
# Uses the issue events API to find when the in-progress label was last added.
unstick_stale() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"
  local issues
  issues=$(gh issue list --repo "alexsiri7/$project" --state open \
    --label "archon:in-progress" --limit 50 --json number,author,labels,title,body 2>/dev/null || echo "[]")
  issues=$(trust_filter_issues "$project" <<<"$issues")

  local nums
  nums=$(echo "$issues" | jq -r '.[].number' 2>/dev/null)
  SUMMARY_IN_PROGRESS=$(echo "$issues" | jq 'length' 2>/dev/null || echo 0)
  [ -z "$nums" ] && return

  local now_sec; now_sec=$(date +%s)

  local num
  for num in $nums; do
    # Skip if a live archon process is working on this issue's repo and
    # references this issue number. Best-effort — we match on the archon
    # command line which includes the issue number in "fix #N".
    # Anchor project match to $repo_dir so e.g. `reli` does not substring-match
    # a worktree path containing `reliability`.
    if pgrep -fa "archon workflow run archon-(ship|fix-github-issue).*#$num\\b" >/dev/null 2>&1 \
        && pgrep -fa "archon workflow run archon-(ship|fix-github-issue)" | grep -qE "(^|[[:space:]=/])$project([[:space:]/]|\$)"; then
      continue
    fi

    # Parked-run guard: an archon-ship run waiting durably on CI has status
    # paused and no live process — it is working, not stuck. Never re-queue it.
    if archon_run_active "$repo_dir" "$project" '^archon-(ship|fix-github-issue)$' "#$num([^0-9]|$)"; then
      continue
    fi

    # Skip if any open PR body/title references this issue (GH auto-links
    # "Fixes #N" / "Closes #N", and archon's PRs include "Closes #N").
    local linked_prs
    linked_prs=$(gh pr list --repo "alexsiri7/$project" --state open --search "#$num in:body,title" --json number --jq 'length' 2>/dev/null || echo 0)
    if [ "${linked_prs:-0}" -gt 0 ]; then
      continue
    fi

    # Find when archon:in-progress was last added via issue events (the
    # /events API: labels, assignments — not the much longer /timeline, #50).
    # It must be paginated: events come oldest first, 30 to a page, and an issue
    # the pipeline has cycled has hundreds (lachesis #174: 249). Unpaginated,
    # `last` read a days-old label, every stale check passed the moment a run
    # ended, and the issue was relaunched every tick (2026-10-02/03: 52 runs).
    local labeled_at
    labeled_at=$(gh api --paginate "repos/alexsiri7/$project/issues/$num/events" \
      --jq '.[] | select(.event=="labeled" and .label.name=="archon:in-progress") | .created_at' 2>/dev/null | tail -n 1)
    [ -z "$labeled_at" ] || [ "$labeled_at" = "null" ] && continue

    local labeled_sec; labeled_sec=$(date -d "$labeled_at" +%s 2>/dev/null || echo 0)
    local age=$((now_sec - labeled_sec))
    if [ "$age" -lt "$STUCK_AGE_SECONDS" ]; then
      continue
    fi

    # A run that ended with a "nothing to deliver" verdict is not stuck: settle
    # it (close or park) instead of paying for the same triage again. Reads the
    # newest run log for this issue, pick_and_fire's or pipeline-health's; see
    # lib/settle-ship-outcome.sh.
    local last_log
    last_log=$(ls -t "$repo_dir"/.archon-logs/cron-issue-"$num"-*.log \
      "$repo_dir"/.archon-logs/health-*-issue-"$num"-*.log 2>/dev/null | head -1)
    if [ -n "$last_log" ] && "$SCRIPT_DIR/lib/settle-ship-outcome.sh" "$project" "$num" "$last_log"; then
      SUMMARY_STALE=$((SUMMARY_STALE + 1))
      continue
    fi

    # Lachesis pickup: no queue label to go back to. Releasing archon:in-progress
    # is enough for next_issue to offer the issue again in its computed place.
    if [ "${LACHESIS_PICKUP_ON:-0}" = 1 ]; then
      log "$project: #$num is stuck (in-progress for ${age}s, no live or parked run, no PR) — releasing it to Lachesis"
      gh issue edit "$num" --repo "alexsiri7/$project" \
        --remove-label "archon:in-progress" 2>/dev/null || {
          log "$project: #$num — could not remove archon:in-progress"
          continue
        }
      SUMMARY_STALE=$((SUMMARY_STALE + 1))
      gh issue comment "$num" --repo "alexsiri7/$project" \
        --body "archon was labeled in-progress ${age}s ago but no live or parked (paused) run and no linked PR were found. Released archon:in-progress: Lachesis next_issue decides when it runs again." 2>/dev/null || true
      continue
    fi

    # A human-owned issue (manual-review etc.) must not go back in the queue,
    # but leaving it archon:in-progress with no run behind it is worse: it
    # reads as permanent pending work, so pipeline-health fires its
    # no-progress diagnostic every 2h for nothing (2026-09-14: #71-#74, three
    # days after their ship runs died on the weekly rate limit). Park it.
    local issue_labels
    issue_labels=$(gh issue view "$num" --repo "alexsiri7/$project" --json labels \
      --jq '.labels | map(.name) | @json' 2>/dev/null || echo "[]")
    if has_human_label "$issue_labels"; then
      log "$project: #$num — stale in-progress with human-intent label, parking as archon:skipped"
      gh issue edit "$num" --repo "alexsiri7/$project" \
        --remove-label "archon:in-progress" --add-label "archon:skipped" 2>/dev/null || {
          log "$project: #$num — could not park as archon:skipped"
          continue
        }
      SUMMARY_STALE=$((SUMMARY_STALE + 1))
      gh issue comment "$num" --repo "alexsiri7/$project" \
        --body "archon was labeled in-progress ${age}s ago but no live or parked (paused) run and no linked PR were found. This issue carries a human-intent label, so it was parked as archon:skipped instead of re-queued. Remove the label and add archon:queued to run it again." 2>/dev/null || true
      continue
    fi

    log "$project: #$num is stuck (in-progress for ${age}s, no live or parked run, no PR) — re-queuing"
    gh issue edit "$num" --repo "alexsiri7/$project" \
      --remove-label "archon:in-progress" --add-label "archon:queued" 2>/dev/null || {
        log "$project: #$num — could not swap labels"
        continue
      }
    SUMMARY_STALE=$((SUMMARY_STALE + 1))
    gh issue comment "$num" --repo "alexsiri7/$project" \
      --body "archon was labeled in-progress ${age}s ago but no live or parked (paused) run and no linked PR were found. Re-queued for another attempt." 2>/dev/null || true
  done
}

# --- Phase 1: auto-queue discovered issues ---
# Find issues labeled with any INGEST_LABEL that have NO archon:* label yet,
# add archon:queued to them. Only for issues older than 5 minutes to let
# humans explicitly skip via archon:skipped if they want to.
auto_queue() {
  local project="$1"
  local issues
  issues=$(gh issue list --repo "alexsiri7/$project" --state open --limit 100 \
    --json number,labels,createdAt,author,title,body 2>/dev/null || echo "[]")
  issues=$(trust_filter_issues "$project" <<<"$issues")

  local now_sec; now_sec=$(date +%s)
  QUEUED_ISSUES=()
  # Process substitution, not a pipe: a piped `while` runs in a subshell and
  # its QUEUED_ISSUES appends would vanish before pick_and_fire reads them.
  local row
  while read -r row; do
    local num created has_ingest
    num=$(echo "$row" | jq -r '.number')
    created=$(echo "$row" | jq -r '.createdAt')
    local labels_json
    labels_json=$(echo "$row" | jq -c '[.labels[].name]')

    if has_archon_label "$labels_json"; then
      continue
    fi

    # Human-owned issues stay out of the queue even with an ingest label:
    # triage may have added `bug` before a human parked the issue, and
    # requirements-gap issues are vetted before ingest. Same rule as
    # auto_triage; auto_queue used to check only the ingest label (#72).
    if has_human_label "$labels_json"; then
      continue
    fi

    # Must have at least one ingest label
    has_ingest=0
    for il in "${INGEST_LABELS[@]}"; do
      echo "$labels_json" | grep -q "\"$il\"" && has_ingest=1 && break
    done
    [ "$has_ingest" = "1" ] || continue

    # Age check: must be > 5 min old
    local created_sec; created_sec=$(date -d "$created" +%s 2>/dev/null || echo 0)
    local age=$((now_sec - created_sec))
    [ "$age" -lt 300 ] && continue

    # Dep-aware: if the issue has open blockers, park it in archon:blocked
    # instead of archon:queued. promote_unblocked will flip it later.
    local initial_label="archon:queued"
    if has_open_blockers "$project" "$num"; then
      initial_label="archon:blocked"
      log "$project: auto-labeling #$num archon:blocked (open blockers)"
    else
      log "$project: auto-queuing #$num (age ${age}s)"
    fi
    if gh issue edit "$num" --repo "alexsiri7/$project" --add-label "$initial_label" 2>/dev/null; then
      if [ "$initial_label" = "archon:queued" ]; then
        QUEUED_ISSUES+=("$num")
      fi
    else
      log "$project: #$num — could not add $initial_label label"
    fi
  done < <(echo "$issues" | jq -c '.[]' 2>/dev/null)
}

# --- Phase 1.5: promote archon:blocked issues whose blockers are all closed ---
# Runs after auto_queue so newly-filed sub-issues that happen to be unblocked
# get picked up on the same tick.
promote_unblocked() {
  local project="$1"
  PROMOTED_ISSUES=()
  local blocked_json
  blocked_json=$(gh issue list --repo "alexsiri7/$project" --state open \
    --label "archon:blocked" --limit 100 --json number,author,labels,title,body 2>/dev/null || echo "[]")
  blocked_json=$(trust_filter_issues "$project" <<<"$blocked_json")
  SUMMARY_BLOCKED=$(echo "$blocked_json" | jq 'length' 2>/dev/null || echo 0)

  local nums
  nums=$(echo "$blocked_json" | jq -r '.[].number' 2>/dev/null)
  [ -z "$nums" ] && return

  local num
  for num in $nums; do
    if has_open_blockers "$project" "$num"; then
      continue
    fi
    log "$project: #$num unblocked — promoting archon:blocked → archon:queued"
    if gh issue edit "$num" --repo "alexsiri7/$project" \
        --remove-label "archon:blocked" --add-label "archon:queued" 2>/dev/null; then
      PROMOTED_ISSUES+=("$num")
      SUMMARY_PROMOTED=$((SUMMARY_PROMOTED + 1))
      SUMMARY_BLOCKED=$((SUMMARY_BLOCKED - 1))
    else
      log "$project: #$num — could not swap blocked→queued"
    fi
  done
}

# ship_slot_busy <project> — true (with SUMMARY_ACTION/NOTE set) when no
# archon-ship may start on <project> this tick: no clone, a run already live or
# parked on the repo (never stack two), or the Claude rate limit holds.
ship_slot_busy() {
  local project="$1"
  local repo_dir="$BASE_DIR/$project"

  if [ ! -d "$repo_dir/.git" ]; then
    log "$project: no repo at $repo_dir, skipping"
    SUMMARY_ACTION="skip"
    SUMMARY_NOTE="repo missing"
    return 0
  fi

  # Don't stack — if an archon run is already in flight for this repo, skip.
  # Capture the issue number from the cmdline ("fix #N") for the summary note.
  local running_for
  running_for=$(pgrep -fa "archon workflow run archon-(ship|fix-github-issue).*--cwd.*$repo_dir" 2>/dev/null \
    | grep -oE 'fix #[0-9]+' | head -1 | tr -d '#')
  if [ -n "$running_for" ]; then
    log "$project: archon already running, skipping"
    SUMMARY_ACTION="skip-running"
    SUMMARY_NOTE="archon already running for #$running_for"
    return 0
  fi
  # Fallback detector: look for runs started via direct cd (no --cwd).
  # Anchor project match so e.g. `reli` does not false-positive on
  # `reliability` or another slug containing the substring.
  running_for=$(pgrep -fa "archon workflow run archon-(ship|fix-github-issue)" 2>/dev/null \
    | grep -E "(^|[[:space:]=/])$project([[:space:]/]|\$)" | grep -oE 'fix #[0-9]+' | head -1 | tr -d '#')
  if [ -n "$running_for" ]; then
    log "$project: archon already running (cwd match), skipping"
    SUMMARY_ACTION="skip-running"
    SUMMARY_NOTE="archon already running for #$running_for"
    return 0
  fi
  # Parked-run guard: an archon-ship run suspended at a durable wait (CI pause)
  # has no process but is still active — do not stack a second run on the repo.
  running_for=$(archon_run_active_msg "$repo_dir" "$project" '^archon-(ship|fix-github-issue)$' \
    | grep -oE 'fix #[0-9]+' | head -1 | tr -d '#')
  if [ -n "$running_for" ]; then
    log "$project: archon run active in DB (running or parked), skipping"
    SUMMARY_ACTION="skip-running"
    SUMMARY_NOTE="archon run active (possibly parked) for #$running_for"
    return 0
  fi

  if [ "$QUOTA_HELD" = 1 ]; then
    SUMMARY_ACTION="skip-quota"
    SUMMARY_NOTE="Claude rate limit in effect"
    return 0
  fi

  return 1
}

# fire_ship <project> <issue> — mark <issue> archon:in-progress and launch
# archon-ship on it in the background.
fire_ship() {
  local project="$1" issue="$2"
  local repo_dir="$BASE_DIR/$project"

  log "$project: picking up issue #$issue"
  # Lachesis pickup: no queue label to remove, and archon:in-progress is what
  # next_issue passes over, so it must not ride on a removal that can fail.
  local -a relabel=(--add-label "archon:in-progress")
  [ "${LACHESIS_PICKUP_ON:-0}" = 1 ] || relabel=(--remove-label "archon:queued" "${relabel[@]}")
  gh issue edit "$issue" --repo "alexsiri7/$project" "${relabel[@]}" 2>/dev/null || true
  SUMMARY_ACTION="pickup #$issue"

  cd "$repo_dir"
  mkdir -p .archon-logs
  local logf=".archon-logs/cron-issue-$issue-$(date +%Y%m%d-%H%M%S).log"
  # The wrapper settles a no-PR verdict on the issue as soon as the run exits
  # (lib/settle-ship-outcome.sh); its own output lands in this cron's log.
  # Only the archon child may look like a live run to the pgrep guards: the
  # wrapper's command line carries the literal "fix #$1", never "#<issue>",
  # and the helper path and project travel in the environment so no path
  # substring can match another project's anchor.
  CLAUDECODE=0 SETTLE_SCRIPT="$SCRIPT_DIR/lib/settle-ship-outcome.sh" SETTLE_PROJECT="$project" \
    nohup bash -c '
      archon workflow run archon-ship "fix #$1" >"$2" 2>&1
      "$SETTLE_SCRIPT" "$SETTLE_PROJECT" "$1" "$2"' \
    ship-wrapper "$issue" "$logf" 2>/dev/null &
  disown
  log "$project: archon launched for #$issue (pid=$!, log=$logf)"
}

# --- Phase 2: pick up oldest queued issue per repo and fire archon ---
pick_and_fire() {
  local project="$1"

  # Fetch queued list once, reuse for count + pick.
  # Order among queued siblings is NOT a contract — if issue A must run before
  # issue B, declare A as a `blocked_by` dep of B. Don't rely on filing order,
  # issue number, or gh's list sort.
  local queued_json
  queued_json=$(gh issue list --repo "alexsiri7/$project" --state open \
    --label "archon:queued" --limit 50 --json number,author,labels,title,body 2>/dev/null || echo "[]")
  queued_json=$(trust_filter_issues "$project" <<<"$queued_json")

  local -a candidates=()
  local num
  while IFS= read -r num; do
    [ -n "$num" ] && candidates+=("$num")
  done < <(echo "$queued_json" | jq -r '.[].number' 2>/dev/null)

  # GitHub's search index lags label writes, so an issue auto_queue or
  # promote_unblocked just flipped to archon:queued can still be missing from
  # the list above. Union in what this tick queued or the issue idles until the
  # next one (reli #1506 lost a 30-minute tick that way on 2026-09-14).
  for num in "${QUEUED_ISSUES[@]}" "${PROMOTED_ISSUES[@]}"; do
    printf '%s\n' "${candidates[@]}" | grep -qx "$num" || candidates+=("$num")
  done
  SUMMARY_QUEUED=${#candidates[@]}

  ship_slot_busy "$project" && return

  # First candidate whose thread is trusted end to end. Skip, never stop: an
  # issue a stranger commented on stays queued (owner ntfy'd once) without
  # wedging the rest of the queue behind it. The same for the ship circuit
  # breaker (lib/ship-breaker.sh): an issue whose recent runs keep failing is
  # parked for a human instead of relaunched, and the next candidate is tried.
  local issue="" cand rc
  for cand in "${candidates[@]}"; do
    if ! trust_comments_ok "$project" issue "$cand"; then
      log "$project: #$cand has comments by untrusted authors (or they could not be read) — not starting archon on it"
      continue
    fi
    rc=0; ship_breaker_check "$project" "$cand" || rc=$?
    if [ "$rc" = 1 ]; then
      log "$project: #$cand — parked by the ship circuit breaker, not relaunching"
      continue
    elif [ "$rc" != 0 ]; then
      log "$project: #$cand — could not read its run history from the archon DB ($(ship_breaker_db)); not launching blind"
      continue
    fi
    issue="$cand"
    break
  done

  if [ -z "$issue" ]; then
    return  # nothing queued; SUMMARY_ACTION stays "none"
  fi

  fire_ship "$project" "$issue"
}

# --- Phase 2 (Lachesis pickup): launch the issue Lachesis orders first ---
# Replaces auto_queue, promote_unblocked and pick_and_fire while the owner's
# LACHESIS_PICKUP switch is on (lib/lachesis.sh). next_issue is asked once per
# tick, across every registered repo: it returns the issue to work first and,
# under also_eligible, the best issue of each other repo, in backlog order
# (interrupt, security, focus, active milestone, age), already filtered for
# readiness, open blockers, in-progress, needs-author, sprint budget and pace.
# Each repo whose slot is free launches its own entry; a repo with a live or
# parked run keeps the no-stacking guards. Labels gate nothing here. Every wait
# for the author is a Lachesis question, which labels the issue needs-author so
# next_issue passes over it: a stranger's issue or comment (prompt-injection
# gate, lib/trust.sh) and a ship circuit-breaker park.
LACHESIS_NEXT_JSON=""
LACHESIS_NEXT_STATE=""   # "" not asked yet this tick, ok, failed

# lachesis_next_fetch — next_issue into LACHESIS_NEXT_JSON, once per tick.
lachesis_next_fetch() {
  case "$LACHESIS_NEXT_STATE" in
    ok) return 0 ;;
    failed) return 1 ;;
  esac
  if LACHESIS_NEXT_JSON=$(lachesis_call next_issue '{}') \
      && jq -e 'has("reason")' <<<"$LACHESIS_NEXT_JSON" >/dev/null 2>&1; then
    LACHESIS_NEXT_STATE=ok
    log "Lachesis next_issue: $(jq -r '.explanation // .reason' <<<"$LACHESIS_NEXT_JSON")"
    return 0
  fi
  LACHESIS_NEXT_STATE=failed
  log "Lachesis next_issue could not be read — no pickup this tick"
  return 1
}

# lachesis_issue_for <project> — the issue next_issue offers on <project>, if any.
lachesis_issue_for() {
  jq -r --arg repo "$TRUST_OWNER/$1" '
    ([.issue // empty] + (.also_eligible // []))
    | map(select((.repo // "" | ascii_downcase) == ($repo | ascii_downcase)))
    | .[0].number // empty' <<<"$LACHESIS_NEXT_JSON" 2>/dev/null
}

lachesis_pick() {
  local project="$1" issue view rc

  ship_slot_busy "$project" && return
  if ! lachesis_next_fetch; then
    SUMMARY_NOTE="Lachesis unavailable"
    return
  fi
  issue=$(lachesis_issue_for "$project")
  if [ -z "$issue" ]; then
    SUMMARY_NOTE="Lachesis offers nothing here: $(jq -r '.reason' <<<"$LACHESIS_NEXT_JSON")"
    return
  fi
  SUMMARY_QUEUED=1

  # The issue itself: a stranger's, or a bridge's held by screening, waits for
  # the owner to vet it (archon:approved releases it); a bridge issue not yet
  # screened waits for lib/screen.sh, which runs every tick.
  if ! view=$(gh issue view "$issue" --repo "alexsiri7/$project" \
      --json number,author,labels,title,body 2>/dev/null); then
    log "$project: #$issue — could not read the issue; not starting archon this tick"
    return
  fi
  if [ "$(jq -s '.' <<<"$view" | trust_filter_issues "$project" | jq 'length' 2>/dev/null)" != 1 ]; then
    if ! trust_issue_ok "$(jq -r '.author.login // ""' <<<"$view")" \
        || jq -e --arg held "$TRUST_HELD_LABEL" '[.labels[]?.name] | index($held)' <<<"$view" >/dev/null 2>&1; then
      if lachesis_ask_once "$project" "$issue" untrusted-issue \
          "The factory will not start archon on #$issue: it was filed by an author outside the trusted list, or held by screening. Vet it, label it archon:approved if it is safe to work, or close it; then answer this question." \
          "Untrusted text is never handed to archon (prompt injection), whatever Lachesis's order says."; then
        log "$project: #$issue — untrusted or held issue, waiting on the author in Lachesis"
      else
        log "$project: #$issue — untrusted or held issue; could not record the question in Lachesis"
      fi
    else
      log "$project: #$issue — waiting for screening before archon may start on it"
    fi
    return
  fi

  rc=0; trust_comments_ok "$project" issue "$issue" || rc=$?
  if [ "$rc" = 1 ]; then
    if lachesis_ask_once "$project" "$issue" untrusted-comment \
        "The factory will not start archon on #$issue: its thread has comments by authors outside the trusted list. Delete them if they should not steer the work, then answer this question." \
        "Untrusted text is never handed to archon (prompt injection). Hiding a comment is not enough: the API still returns it."; then
      log "$project: #$issue — comments by untrusted authors, waiting on the author in Lachesis"
    else
      log "$project: #$issue — comments by untrusted authors; could not record the question in Lachesis"
    fi
    return
  elif [ "$rc" != 0 ]; then
    log "$project: #$issue — could not read its comments; not starting archon this tick"
    return
  fi

  rc=0; SHIP_BREAKER_ASK=lachesis_ask ship_breaker_check "$project" "$issue" || rc=$?
  if [ "$rc" = 1 ]; then
    log "$project: #$issue — parked by the ship circuit breaker, not relaunching"
    return
  elif [ "$rc" != 0 ]; then
    log "$project: #$issue — could not read its run history from the archon DB ($(ship_breaker_db)); not launching blind"
    return
  fi

  fire_ship "$project" "$issue"
}

# lachesis_may_triage — with Lachesis pickup on, triage spends the allowance
# too: only when next_issue answered and holds no work for budget or pace.
lachesis_may_triage() {
  [ "$LACHESIS_PICKUP_ON" = 1 ] || return 0
  lachesis_next_fetch || return 1
  case "$(jq -r '.reason' <<<"$LACHESIS_NEXT_JSON")" in
    budget_spent|over_pace) return 1 ;;
  esac
  return 0
}

# pipeline-health watches this script and pr-maintenance; this watches it back.
# 30: its cron period in minutes, keep in sync with ops/cron/crontab.
heartbeat_watch pipeline-health 30

for PROJECT in "${PROJECTS[@]}"; do
  SUMMARY_IN_PROGRESS=0
  SUMMARY_STALE=0
  SUMMARY_QUEUED=0
  SUMMARY_DEDUPED=0
  SUMMARY_SETTLED=0
  SUMMARY_ACTION="none"
  SUMMARY_NOTE=""

  ensure_labels "$PROJECT"
  dedupe_sentry "$PROJECT"
  settle_parked "$PROJECT"
  screen_bridge_issues "$PROJECT"
  unstick_stale "$PROJECT"
  if [ "$LACHESIS_PICKUP_ON" = 1 ]; then
    lachesis_pick "$PROJECT"
  else
    auto_queue "$PROJECT"
    promote_unblocked "$PROJECT"
    pick_and_fire "$PROJECT"
  fi
  # Triage only runs when the fix queue is idle — it fills otherwise-empty ticks.
  [ "$SUMMARY_ACTION" = "none" ] && lachesis_may_triage && auto_triage "$PROJECT"

  summary="$PROJECT: queued=$SUMMARY_QUEUED blocked=$SUMMARY_BLOCKED in-progress=$SUMMARY_IN_PROGRESS stale=$SUMMARY_STALE promoted=$SUMMARY_PROMOTED deduped=$SUMMARY_DEDUPED settled=$SUMMARY_SETTLED action=$SUMMARY_ACTION"
  [ -n "$SUMMARY_NOTE" ] && summary="$summary ($SUMMARY_NOTE)"
  log "$summary"
done

log "Done"
