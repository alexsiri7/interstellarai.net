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
# Settles by parking the issue as archon:skipped with the verdict as a comment,
# so a human decides and bug-bankruptcy ages it out; it does not close the
# issue on the model's word alone.
#
# Exit 0 when a verdict was found and recorded, 1 when the log carries none
# (crash, rate limit, delivered PR) so the caller keeps its existing handling.
set -uo pipefail

project="$1"; issue="$2"; run_log="$3"
[ -r "$run_log" ] || exit 1

# The two ship outcome reports that end without a PR (see the ship workflow's
# outcome script). One line each, printed verbatim by the outcome node.
verdict=$(grep -m1 -E '^No delivery (needed|started): ' "$run_log" || true)
[ -n "$verdict" ] || exit 1

repo="alexsiri7/$project"
if ! gh issue edit "$issue" --repo "$repo" \
    --remove-label "archon:in-progress" --add-label "archon:skipped" >/dev/null 2>&1; then
  echo "$(date -Is) [issue-pickup] $project: #$issue — could not park as archon:skipped"
  exit 1
fi
gh issue comment "$issue" --repo "$repo" --body "archon-ship finished without a PR: ${verdict}

Parked as archon:skipped. Remove the label and add archon:queued to run it again. Run log: \`${run_log}\`" >/dev/null 2>&1 || true
echo "$(date -Is) [issue-pickup] $project: #$issue settled as archon:skipped (${verdict:0:120})"
