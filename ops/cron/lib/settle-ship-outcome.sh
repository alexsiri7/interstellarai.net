#!/usr/bin/env bash
# settle-ship-outcome.sh [--recheck] <project> <issue> <run-log|verdict-file>
#
# Records a "nothing to deliver" verdict from an archon-ship run on its issue.
#
# archon-ship can end legitimately without a PR: triage routes to no_action
# (already delivered, false positive, not a code change) or investigate finds
# no safe fix boundary. Its terminal report is the run's only channel for that
# verdict; the issue itself stays archon:in-progress with no PR, which is exactly
# the shape unstick_stale treats as a crashed run. Left alone the pipeline
# re-queues the issue every STUCK_AGE_SECONDS and pays for the same triage again
# (2026-09-08: word-coach-annie #1088 three times in one night, #1105 twice,
# reli #1402 as the 26th identical false-positive alert).
#
# A "No delivery needed" verdict closes the issue as archon:done, but only when
# GitHub confirms it (#103): every sub-issue is closed, or the verdict names a
# merged PR, or else exactly one same-repo issue that is still open (closed as
# its duplicate, #212) while every other ref it names was looked up. A named
# closed issue never closes it here: that is a maintainer's call (with pickup
# on, a question whose default is to close it; see the tiers below).
# It never closes on the model's prose alone, and "No delivery started" (an
# undecided investigate/plan stop) never closes. Anything else, or any gh
# failure on the way, parks the issue as archon:skipped with the verdict as a
# comment, so a human decides and bug-bankruptcy ages it out.
#
# A verdict that defers to a PR ("No delivery needed", "Not done: blocked on")
# is not parked behind one that cannot merge (#211): when every PR it names
# answers 404 (hidden, as every PR of the flagged factory account was from
# 2026-10-13, or deleted), is closed (or merged, when blocked on it), or is by
# an author the factory cannot act for, the issue is released to run again,
# once per PR. Any lookup failure, or a named open issue or trusted open PR,
# parks.
#
# Issues pipeline-health-cron.sh files (Main CI red, Prod deploy failed/lagging)
# are never closed (#107): they track live CI/deploy state, and a PR their
# verdict names is usually what broke it, not a fix (un-reminder #450 cites
# merged PR #449, the cause of the red). They are always parked for a human.
#
# With Lachesis pickup on, what none of that settles is sorted by severity tier
# (lib/severity.sh, #237): the verdict's suggested action (close, record its
# blocker as a dependency, run it again) is taken at once on tier 1, offered as
# a question's default taken after two days on tier 2, and dropped on tier 3,
# where the question waits. A tier comes from the outcome JSON's "tier" (none
# today, so tier 2) raised by a keyword floor; a pipeline-health issue is tier
# 3. Each action is taken or offered once per issue (a comment marker). With
# pickup off nothing here changes.
#
# Exit 0 when a verdict was found and recorded, 1 when the log carries none
# (crash, rate limit, delivered PR) so the caller keeps its existing handling.
# A verdict whose reason is a placeholder (lib/ship-verdict.sh, #209) counts as
# none: it is the shape of a degenerate triage, not a decision to record.
#
# --recheck: issue-pickup's settle_parked passes the verdict parked on an
# archon:skipped issue, so one GitHub could not confirm at run time (or parked
# before #104) still closes once it can. It closes on the same confirmation and
# removes archon:skipped; when nothing confirms it exits 1 without touching the
# issue, because it runs every tick.
set -uo pipefail

recheck=0
[ "${1:-}" = "--recheck" ] && { recheck=1; shift; }
project="$1"; issue="$2"; run_log="$3"
if [ "$recheck" = 1 ]; then
  from_label="archon:skipped"
  close_note="Re-checked by issue-pickup from the verdict parked on this issue."
else
  from_label="archon:in-progress"
  close_note="Run log: \`${run_log}\`"
fi
[ -r "$run_log" ] || exit 1

# The two ship outcome reports that end without a PR (see the ship workflow's
# outcome script): the verdict line, whose triage summary may run onto further
# lines, then "Report: <path>". Archon before 0.11 printed the report verbatim.
# Since the 0.11.1 sync (2026-10-09) the outcome node prints it as one JSON line,
#   {"delivered":false,"summary":"No delivery needed: ...\nReport: <path>"}
# and grepping for the plain line found nothing: every such run fell through to
# unstick_stale, which released the issue to be triaged again (101 runs by
# 2026-10-11). When the log carries that JSON line it is the authority: its
# decoded summary is the report, and delivered:true (a PR) settles nothing.
# Otherwise the plain report is read, as from --recheck's parked verdict.
#
# VERDICT_RE, the no-PR verdict line, lives in lib/ship-verdict.sh.
# shellcheck source=lib/ship-verdict.sh
source "$(dirname "${BASH_SOURCE[0]}")/ship-verdict.sh"
# shellcheck source=lib/severity.sh
source "$(dirname "${BASH_SOURCE[0]}")/severity.sh"
outcome_text="$run_log"
outcome_json=$(grep -E '^\{.*"delivered" *:' "$run_log" \
  | jq -cR 'fromjson? | select(type == "object" and (.delivered | type) == "boolean")' 2>/dev/null \
  | tail -n 1)
if [ -n "$outcome_json" ]; then
  outcome_text=$(mktemp) || exit 1
  trap 'rm -f "$outcome_text"' EXIT
  jq -r --arg re "$VERDICT_RE" 'select(.delivered == false and (.summary | type) == "string"
           and (.summary | test($re))) | .summary' \
    <<<"$outcome_json" > "$outcome_text" 2>/dev/null || exit 1
fi
declared_tier=""
[ -n "$outcome_json" ] && declared_tier=$(jq -r '.tier // empty' <<<"$outcome_json" 2>/dev/null)
verdict=$(grep -m1 -E "$VERDICT_RE" "$outcome_text" || true)
[ -n "$verdict" ] || exit 1
if verdict_is_placeholder "$verdict"; then
  [ "$recheck" = 1 ] \
    || echo "$(date -Is) [issue-pickup] $project: #$issue — placeholder verdict (${verdict:0:120}), not settled: left archon:in-progress for unstick_stale (#209). Run log: ${run_log}"
  exit 1
fi

repo="alexsiri7/$project"

# Closes the issue as archon:done and exits; returns 1 if the close failed.
# A tier-1 close (settle_act) sets act_marker, carried in the close comment,
# and act_note, recorded in Lachesis once the close holds.
act_marker="" act_note=""
close_as_done() {
  local evidence="$1"; shift
  gh issue close "$issue" --repo "$repo" "$@" --comment "archon-ship finished without a PR: ${verdict}

Closed as archon:done: ${evidence}. Reopen and add archon:queued to run it again. ${close_note}
${act_marker:+
$act_marker}
<!-- lachesis:automated -->" >/dev/null 2>&1 || {
    [ "$recheck" = 1 ] \
      && echo "$(date -Is) [issue-pickup] $project: #$issue — GitHub confirms ${evidence}, but the close failed"
    return 1
  }
  gh issue edit "$issue" --repo "$repo" \
    --remove-label "$from_label" --add-label "archon:done" >/dev/null 2>&1 \
    || echo "$(date -Is) [issue-pickup] $project: #$issue — closed, but could not relabel archon:done"
  [ -n "$act_note" ] && ! lachesis_note "$project" "$issue" "$act_note" \
    && echo "$(date -Is) [issue-pickup] $project: #$issue — closed, but could not record the note in Lachesis"
  echo "$(date -Is) [issue-pickup] $project: #$issue settled as archon:done (${evidence})"
  exit 0
}

# ref_hold_state <ref> — what a ref a deferring verdict names means for
# parking behind it: hold (an open issue, or an open PR the factory can merge),
# neutral (a closed issue), merged (a merged PR), unknown (a lookup failed), or
# "stale<TAB><why>" (nothing there can merge). issues/N comes first: pulls/N answers 404 for an
# ordinary issue too, while issues/N answers 404 only when nothing visible to
# this account exists at that number.
ref_hold_state() {
  local ref="$1" out kind state merged cross login
  if ! out=$(gh api "repos/$repo/issues/$ref" \
      --jq '[(if .pull_request then "pr" else "issue" end), .state] | @tsv' 2>&1); then
    if [[ "$out" == *"HTTP 404"* ]]; then
      printf 'stale\tdoes not resolve (GitHub answers 404: hidden or deleted)\n'
    else
      echo unknown
    fi
    return
  fi
  IFS=$'\t' read -r kind state <<<"$out"
  case "$kind/$state" in
    issue/open) echo hold; return ;;
    issue/closed) echo neutral; return ;;
    pr/open|pr/closed) ;;
    *) echo unknown; return ;;
  esac
  # login last: an empty one must not shift the other fields.
  out=$(gh api "repos/$repo/pulls/$ref" \
    --jq '[.state, (.merged_at != null), ((.head.repo.full_name // "") != .base.repo.full_name), (.user.login // "")] | @tsv' \
    2>/dev/null) || { echo unknown; return; }
  IFS=$'\t' read -r state merged cross login <<<"$out"
  case "$state/$merged" in
    closed/true) echo merged ;;
    closed/false) printf 'stale\tis closed without merging\n' ;;
    open/false)
      # shellcheck source=lib/trust.sh
      source "$(dirname "${BASH_SOURCE[0]}")/trust.sh"
      case "$(trust_pr_level "$login" "$cross")" in
        full|merge) echo hold ;;
        *) if [ "$cross" = true ]; then printf 'stale\tcomes from a fork\n'
           else printf 'stale\tis by %s, not an account the factory can act for\n' "$login"; fi ;;
      esac ;;
    *) echo unknown ;;
  esac
}

# release_if_stale — exits 0 having released the issue to run again when every
# ref the deferring verdict names is stale or neutral and at least one is
# stale (#211). The release comment's marker bounds this to once per PR: a run
# that defers to an already-released PR again sets stale_note and parks, as
# does any hold, unknown, or a comment listing that cannot be read.
release_if_stale() {
  local ref state stale_lines="" prior
  local -a stale=() again=() relabel=(--remove-label "archon:in-progress")
  for ref in "${refs[@]}"; do
    state=$(ref_hold_state "$ref")
    case "$state" in
      stale$'\t'*) stale+=("$ref"); stale_lines+=$'\n'"- #$ref ${state#stale$'\t'}" ;;
      neutral) ;;
      # What "No delivery needed" claims, so only a failed close got here.
      merged) [[ "$verdict" == "No delivery needed: "* ]] && return
              stale+=("$ref"); stale_lines+=$'\n'"- #$ref is already merged" ;;
      *) return ;;
    esac
  done
  [ "${#stale[@]}" -gt 0 ] || return
  prior=$(gh api --paginate "repos/$repo/issues/$issue/comments" --jq '.[].body' 2>/dev/null) || return
  for ref in "${stale[@]}"; do
    grep -qE "<!-- archon-settle-stale-refs:( [0-9]+)* $ref( [0-9]+)* -->" <<<"$prior" && again+=("#$ref")
  done
  if [ "${#again[@]}" -gt 0 ]; then
    stale_note=" Not released again: the run deferred again to ${again[*]}, which an earlier settle already released once."
    return
  fi

  local requeue_note="Lachesis next_issue decides when it runs again."
  if ! lachesis_pickup_enabled; then
    relabel+=(--add-label "archon:queued")
    requeue_note="Re-queued as archon:queued."
  fi
  if ! gh issue edit "$issue" --repo "$repo" "${relabel[@]}" >/dev/null 2>&1; then
    echo "$(date -Is) [issue-pickup] $project: #$issue — could not release to run again"
    exit 1
  fi
  gh issue comment "$issue" --repo "$repo" --body "archon-ship finished without a PR: ${verdict}

Not parked: the verdict defers to work that cannot merge as GitHub shows it to the factory:${stale_lines}
Released to run again; the next run must not defer to these. ${requeue_note} Run log: \`${run_log}\`

<!-- archon-settle-stale-refs: ${stale[*]} -->" >/dev/null 2>&1 || true
  echo "$(date -Is) [issue-pickup] $project: #$issue released to run again (stale PR refs: ${stale[*]/#/#})"
  exit 0
}

defers=0
[[ "$verdict" == "No delivery needed: "* || "$verdict" == "Not done: blocked on "* ]] && defers=1

# Keyed on the marker every pipeline-health issue body carries. A failed
# lookup counts as health-filed, since any gh failure parks (and releases or
# closes nothing).
health_filed=1
title=""
if view=$(gh issue view "$issue" --repo "$repo" --json title,body 2>/dev/null) \
    && body=$(jq -r '.body // ""' <<<"$view" 2>/dev/null); then
  title=$(jq -r '.title // ""' <<<"$view")
  # shellcheck disable=SC2016  # the backticks are issue markdown, not shell
  [[ "$body" == *'Auto-filed by `pipeline-health-cron.sh`'* ]] || health_filed=0
fi
closed_refs=""
sub_open=""
# The verdict, past its first line but not past the report path or the park.
verdict_block=$(awk -v re="$VERDICT_RE" '$0 ~ re {p=1} p && /^(Report: |Parked as archon:skipped)/{exit} p' "$outcome_text")
# Bare same-repo refs only ("owner/repo#N" is excluded), self dropped, the
# first five checked to bound the API calls; a sixth marks the rest unchecked.
mapfile -t refs < <(
  printf '%s\n' "$verdict_block" \
    | grep -oE '(^|[^A-Za-z0-9/_.-])#[0-9]+' | grep -oE '[0-9]+$' \
    | awk -v self="$issue" '$0 != self && !seen[$0]++' | head -6)
all_refs_known=1
[ "${#refs[@]}" -gt 5 ] && { all_refs_known=0; refs=("${refs[@]:0:5}"); }

declare -A kind=()
if [ "$health_filed" = 0 ] && [[ "$verdict" == "No delivery needed: "* ]]; then
  read -r sub_total sub_open < <(gh api "repos/$repo/issues/$issue/sub_issues?per_page=100" \
    --jq '[length, ([.[] | select(.state == "open")] | length)] | @tsv' 2>/dev/null)
  if [[ "${sub_total:-}" =~ ^[0-9]+$ && "${sub_open:-}" =~ ^[0-9]+$ ]] \
      && [ "$sub_total" -ge 1 ] && [ "$sub_open" -eq 0 ]; then
    close_as_done "all $sub_total sub-issues are closed" --reason completed
  fi

  for ref in "${refs[@]}"; do
    kind[$ref]=$(gh api "repos/$repo/issues/$ref" --jq '
      if .pull_request then (if .pull_request.merged_at then "merged-pr" else "pr" end)
      elif .state == "open" then "open-issue"
      else "closed-issue" end' 2>/dev/null)
    [ -n "${kind[$ref]}" ] || all_refs_known=0
    [ "${kind[$ref]}" = "closed-issue" ] && closed_refs+="${closed_refs:+, }#$ref"
  done
  # The triage policy's two closes without a person: an outcome a merged change
  # already delivered, and a duplicate of an issue that is still open. The
  # verdict's refs are free prose, so a lone open issue is read as the original
  # and several are a maintainer's call, as is a ref left unchecked or whose
  # lookup failed, since it may be a second open issue. A duplicate of a closed
  # issue is too, so it is parked with that issue named (below).
  open_refs=()
  for ref in "${refs[@]}"; do
    [ "${kind[$ref]}" = "merged-pr" ] \
      && close_as_done "already fixed by merged PR #$ref" --reason completed
    [ "${kind[$ref]}" = "open-issue" ] && open_refs+=("$ref")
  done
  [ "${#open_refs[@]}" -eq 1 ] && [ "$all_refs_known" = 1 ] \
    && close_as_done "duplicate of #${open_refs[0]}, which is still open" --duplicate-of "${open_refs[0]}"
fi
[ "$recheck" = 1 ] && exit 1

# shellcheck source=lib/lachesis.sh
source "$(dirname "${BASH_SOURCE[0]}")/lachesis.sh"
stale_note=""
[ "$health_filed" = 0 ] && [ "$defers" = 1 ] && [ "${#refs[@]}" -gt 0 ] && release_if_stale

# ── Severity tiers (#237), with Lachesis pickup on ──────────────────────────
# Reached only once the confirmed closes above and release_if_stale have
# passed, and never under --recheck. The verdict's suggested action is taken
# at once on tier 1, offered as the question's default on tier 2 and dropped on
# tier 3. Each action is taken or offered once per issue: its marker on any
# comment (the act's own, or the question Lachesis posts with the default)
# turns a later run's suggestion into a plain question, so "run it again" runs
# at most once and an ignored default is not offered again.
SETTLE_DEFAULT_WAIT_DAYS=2

# suggested_action — what the verdict asks for: close-completed,
# close-not-planned, depend-<M>, proceed, or wait (nothing the factory can do
# on its own: a named open PR may still land, an open sub-issue, a blocker it
# cannot record).
suggested_action() {
  local ref
  case "$verdict" in
    "No delivery needed: "*)
      [[ "$sub_open" =~ ^[0-9]+$ ]] && [ "$sub_open" -eq 0 ] && [ "$all_refs_known" = 1 ] \
        || { echo wait; return; }
      for ref in "${refs[@]}"; do
        [ "${kind[$ref]:-}" = pr ] && { echo wait; return; }
      done
      echo close-completed ;;
    "No work owed in this repository: "*) echo close-not-planned ;;
    "Not done: blocked on "*)
      if [ "${#refs[@]}" -eq 1 ] && [ "$all_refs_known" = 1 ] \
          && [ "$(gh api "repos/$repo/issues/${refs[0]}" \
                --jq 'if .pull_request then "pr" else .state end' 2>/dev/null)" = open ]; then
        echo "depend-${refs[0]}"
      else
        echo wait
      fi ;;
    *) echo proceed ;;
  esac
}

# settle_marked <action> — true when <action> was already taken or offered on
# the issue, or when its comments cannot be read.
settle_marked() {
  local bodies
  bodies=$(gh api --paginate "repos/$repo/issues/$issue/comments" --jq '.[].body' 2>/dev/null) || return 0
  grep -qE "<!-- archon-settle-(act|default): $1 -->" <<<"$bodies"
}

# default_text <action> — the action as a question's answer.
default_text() {
  case "$1" in
    close-completed) echo "Close #$issue as completed: the run found nothing left to deliver." ;;
    close-not-planned) echo "Close #$issue as not planned: the run found no work owed in this repository." ;;
    depend-*) echo "Record #${1#depend-} as blocking #$issue; the factory runs #$issue again once #${1#depend-} closes." ;;
    proceed) echo "Run #$issue once more, with this verdict as direction." ;;
  esac
}

# settle_act <action> — takes a tier-1 action and exits 0; returns 1 when it
# could not be taken, so the caller asks instead.
settle_act() {
  local action="$1" marker="<!-- archon-settle-act: $1 -->" note what
  note="$(default_text "$action") Taken without asking (tier 1, #237). The run's verdict: ${verdict:0:300}"
  case "$action" in
    close-*)
      act_marker="$marker" act_note="$note"
      local reason=completed
      [ "$action" = close-not-planned ] && reason="not planned"
      close_as_done "the verdict is a tier-1 outcome, acted on without asking (#237)" --reason "$reason"
      act_marker="" act_note=""
      return 1 ;;
    depend-*)
      lachesis_depend "$project" "$issue" "${action#depend-}" || return 1
      what="Recorded #${action#depend-} as blocking this issue (a tier-1 outcome, #237); the factory runs it again once #${action#depend-} closes." ;;
    proceed)
      what="Released to run again (a tier-1 outcome, #237): the next run takes this verdict as direction. Lachesis next_issue decides when it runs; if that run also stops without a PR, the factory asks." ;;
  esac
  if ! gh issue edit "$issue" --repo "$repo" --remove-label "archon:in-progress" >/dev/null 2>&1; then
    echo "$(date -Is) [issue-pickup] $project: #$issue — took tier-1 action $action, but could not release archon:in-progress"
    exit 1
  fi
  gh issue comment "$issue" --repo "$repo" --body "archon-ship finished without a PR: ${verdict}

${what} Run log: \`${run_log}\`

${marker}
<!-- lachesis:automated -->" >/dev/null 2>&1 || true
  lachesis_note "$project" "$issue" "$note" \
    || echo "$(date -Is) [issue-pickup] $project: #$issue — could not record the note in Lachesis"
  echo "$(date -Is) [issue-pickup] $project: #$issue settled by tier-1 action $action"
  exit 0
}

action=wait tier_log=""
ask_defaults=()
if lachesis_pickup_enabled; then
  tier=$(severity_tier "$declared_tier" "$verdict_block"$'\n'"$title")
  [ "$health_filed" = 1 ] && tier=3
  [ "$tier" = 3 ] || action=$(suggested_action)
  [ "$action" != wait ] && settle_marked "$action" && action="wait"
  [ "$action" != wait ] && [ "$tier" = 1 ] && ! settle_act "$action" && action="wait"
  tier_log=", tier $tier, default none"
  if [ "$action" != wait ]; then
    tier_log=", tier $tier, default $action"
    ask_defaults=(
      "$(default_text "$action") <!-- archon-settle-default: $action -->"
      "$SETTLE_DEFAULT_WAIT_DAYS"
      "$(default_text "$action")"
      "Answer with what the next run should do differently.")
    [[ "$action" == close-* ]] || ask_defaults+=("Close #$issue.")
  fi
fi

# With Lachesis pickup on (lib/lachesis.sh) archon:skipped gates nothing:
# next_issue would offer the issue again and pay for the same triage. The park
# is a question for the author, which labels it needs-author; archon:skipped
# stays as the record settle_parked re-checks. Asked before the park comment,
# so that comment stays the last one settle_parked reads. A question that could
# not be recorded leaves archon:in-progress in place, so unstick_stale settles
# it again on a later tick.
rerun_note="Remove the label and add archon:queued to run it again."
question="archon-ship finished on #$issue without a PR, and GitHub does not confirm that nothing is needed. Close the issue, or answer this question to let the factory run it again."
[ -n "$closed_refs" ] \
  && question="archon-ship finished on #$issue without a PR. Its verdict names closed issue ${closed_refs}: if #$issue duplicates it, close #$issue as a duplicate; otherwise answer this question to let the factory run it again."
if lachesis_pickup_enabled; then
  if ! lachesis_ask "$project" "$issue" "$question" \
      "The run's verdict: ${verdict:0:600}" "${ask_defaults[@]}"; then
    echo "$(date -Is) [issue-pickup] $project: #$issue — could not record a question in Lachesis; left archon:in-progress, settled again later"
    exit 0
  fi
  rerun_note="Waiting on the author's answer to the question above (Lachesis)."
fi

if ! gh issue edit "$issue" --repo "$repo" \
    --remove-label "archon:in-progress" --add-label "archon:skipped" >/dev/null 2>&1; then
  echo "$(date -Is) [issue-pickup] $project: #$issue — could not park as archon:skipped"
  exit 1
fi
park_note=""
[ "$health_filed" = 1 ] \
  && park_note=" Not auto-closed: the issue was filed by pipeline-health-cron.sh (CI/deploy state), or its body could not be read, so a human decides."
[ -n "$closed_refs" ] \
  && park_note=" Not auto-closed: the verdict names closed issue ${closed_refs}, and a duplicate of a closed issue is a maintainer's call. Close this as its duplicate if it is one."
gh issue comment "$issue" --repo "$repo" --body "archon-ship finished without a PR: ${verdict}

Parked as archon:skipped. ${rerun_note}${park_note}${stale_note} Run log: \`${run_log}\`

<!-- lachesis:automated -->" >/dev/null 2>&1 || true
echo "$(date -Is) [issue-pickup] $project: #$issue settled as archon:skipped (${verdict:0:120})${tier_log}"
