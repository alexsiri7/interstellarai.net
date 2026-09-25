#!/usr/bin/env bash
# settle-ship-outcome.sh <project> <issue> <run-log>
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
# same-repo issue closed as completed (closed as its duplicate) or a merged PR.
# It never closes on the model's prose alone, and "No delivery started" (an
# undecided investigate/plan stop) never closes. Anything else, or any gh
# failure on the way, parks the issue as archon:skipped with the verdict as a
# comment, so a human decides and bug-bankruptcy ages it out.
#
# Exit 0 when a verdict was found and recorded, 1 when the log carries none
# (crash, rate limit, delivered PR) so the caller keeps its existing handling.
set -uo pipefail

project="$1"; issue="$2"; run_log="$3"
[ -r "$run_log" ] || exit 1

# The two ship outcome reports that end without a PR (see the ship workflow's
# outcome script), printed verbatim by the outcome node: the verdict line, whose
# triage summary may run onto further lines, then "Report: <path>".
verdict=$(grep -m1 -E '^No delivery (needed|started): ' "$run_log" || true)
[ -n "$verdict" ] || exit 1

repo="alexsiri7/$project"

# Closes the issue as archon:done and exits; returns 1 if the close failed.
close_as_done() {
  local evidence="$1"; shift
  gh issue close "$issue" --repo "$repo" "$@" --comment "archon-ship finished without a PR: ${verdict}

Closed as archon:done: ${evidence}. Reopen and add archon:queued to run it again. Run log: \`${run_log}\`" >/dev/null 2>&1 || return 1
  gh issue edit "$issue" --repo "$repo" \
    --remove-label "archon:in-progress" --add-label "archon:done" >/dev/null 2>&1 \
    || echo "$(date -Is) [issue-pickup] $project: #$issue — closed, but could not relabel archon:done"
  echo "$(date -Is) [issue-pickup] $project: #$issue settled as archon:done (${evidence})"
  exit 0
}

if [[ "$verdict" == "No delivery needed: "* ]]; then
  read -r sub_total sub_open < <(gh api "repos/$repo/issues/$issue/sub_issues?per_page=100" \
    --jq '[length, ([.[] | select(.state == "open")] | length)] | @tsv' 2>/dev/null)
  if [[ "${sub_total:-}" =~ ^[0-9]+$ && "${sub_open:-}" =~ ^[0-9]+$ ]] \
      && [ "$sub_total" -ge 1 ] && [ "$sub_open" -eq 0 ]; then
    close_as_done "all $sub_total sub-issues are closed" --reason completed
  fi

  # Bare same-repo refs only ("owner/repo#N" is excluded), self dropped, the
  # first five checked to bound the API calls.
  mapfile -t refs < <(
    awk '/^No delivery needed: /{p=1} p && /^Report: /{exit} p' "$run_log" \
      | grep -oE '(^|[^A-Za-z0-9/_.-])#[0-9]+' | grep -oE '[0-9]+$' \
      | awk -v self="$issue" '$0 != self && !seen[$0]++' | head -5)
  declare -A kind=()
  for ref in "${refs[@]}"; do
    kind[$ref]=$(gh api "repos/$repo/issues/$ref" --jq '
      if .pull_request then (if .pull_request.merged_at then "merged-pr" else "pr" end)
      elif .state == "closed" and .state_reason == "completed" then "completed-issue"
      else "other" end' 2>/dev/null)
  done
  # A named closed issue is the more exact record than the PR that fixed it.
  for ref in "${refs[@]}"; do
    [ "${kind[$ref]}" = "completed-issue" ] \
      && close_as_done "duplicate of #$ref, closed as completed" --duplicate-of "$ref"
  done
  for ref in "${refs[@]}"; do
    [ "${kind[$ref]}" = "merged-pr" ] \
      && close_as_done "already fixed by merged PR #$ref" --reason completed
  done
fi

if ! gh issue edit "$issue" --repo "$repo" \
    --remove-label "archon:in-progress" --add-label "archon:skipped" >/dev/null 2>&1; then
  echo "$(date -Is) [issue-pickup] $project: #$issue — could not park as archon:skipped"
  exit 1
fi
gh issue comment "$issue" --repo "$repo" --body "archon-ship finished without a PR: ${verdict}

Parked as archon:skipped. Remove the label and add archon:queued to run it again. Run log: \`${run_log}\`" >/dev/null 2>&1 || true
echo "$(date -Is) [issue-pickup] $project: #$issue settled as archon:skipped (${verdict:0:120})"
