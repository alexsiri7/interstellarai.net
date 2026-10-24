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
# closed issue never closes it: that is a maintainer's call.
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
verdict=$(grep -m1 -E "$VERDICT_RE" "$outcome_text" || true)
[ -n "$verdict" ] || exit 1
if verdict_is_placeholder "$verdict"; then
  [ "$recheck" = 1 ] \
    || echo "$(date -Is) [issue-pickup] $project: #$issue — placeholder verdict (${verdict:0:120}), not settled: left archon:in-progress for unstick_stale (#209). Run log: ${run_log}"
  exit 1
fi

repo="alexsiri7/$project"

# Closes the issue as archon:done and exits; returns 1 if the close failed.
close_as_done() {
  local evidence="$1"; shift
  gh issue close "$issue" --repo "$repo" "$@" --comment "archon-ship finished without a PR: ${verdict}

Closed as archon:done: ${evidence}. Reopen and add archon:queued to run it again. ${close_note}

<!-- lachesis:automated -->" >/dev/null 2>&1 || {
    [ "$recheck" = 1 ] \
      && echo "$(date -Is) [issue-pickup] $project: #$issue — GitHub confirms ${evidence}, but the close failed"
    return 1
  }
  gh issue edit "$issue" --repo "$repo" \
    --remove-label "$from_label" --add-label "archon:done" >/dev/null 2>&1 \
    || echo "$(date -Is) [issue-pickup] $project: #$issue — closed, but could not relabel archon:done"
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

health_filed=0
closed_refs=""
if [ "$defers" = 1 ]; then
  # Keyed on the marker every pipeline-health issue body carries. A failed
  # lookup counts as health-filed, since any gh failure parks (and releases
  # nothing).
  health_filed=1
  if body=$(gh issue view "$issue" --repo "$repo" --json body --jq '.body' 2>/dev/null); then
    # shellcheck disable=SC2016  # the backticks are issue markdown, not shell
    [[ "$body" == *'Auto-filed by `pipeline-health-cron.sh`'* ]] || health_filed=0
  fi
fi
# Bare same-repo refs only ("owner/repo#N" is excluded), self dropped, the
# first five checked to bound the API calls; a sixth marks the rest unchecked.
mapfile -t refs < <(
  awk -v re="$VERDICT_RE" '$0 ~ re {p=1} p && /^(Report: |Parked as archon:skipped)/{exit} p' "$outcome_text" \
    | grep -oE '(^|[^A-Za-z0-9/_.-])#[0-9]+' | grep -oE '[0-9]+$' \
    | awk -v self="$issue" '$0 != self && !seen[$0]++' | head -6)
all_refs_known=1
[ "${#refs[@]}" -gt 5 ] && { all_refs_known=0; refs=("${refs[@]:0:5}"); }

if [ "$health_filed" = 0 ] && [[ "$verdict" == "No delivery needed: "* ]]; then
  read -r sub_total sub_open < <(gh api "repos/$repo/issues/$issue/sub_issues?per_page=100" \
    --jq '[length, ([.[] | select(.state == "open")] | length)] | @tsv' 2>/dev/null)
  if [[ "${sub_total:-}" =~ ^[0-9]+$ && "${sub_open:-}" =~ ^[0-9]+$ ]] \
      && [ "$sub_total" -ge 1 ] && [ "$sub_open" -eq 0 ]; then
    close_as_done "all $sub_total sub-issues are closed" --reason completed
  fi

  declare -A kind=()
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
  && question="archon-ship finished on #$issue without a PR. Its verdict names closed issue ${closed_refs}: if #$issue duplicates it, close #$issue as a duplicate (a maintainer's call, so not closed automatically); otherwise answer this question to let the factory run it again."
if lachesis_pickup_enabled; then
  if ! lachesis_ask "$project" "$issue" "$question" \
      "The run's verdict: ${verdict:0:600}"; then
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
echo "$(date -Is) [issue-pickup] $project: #$issue settled as archon:skipped (${verdict:0:120})"
