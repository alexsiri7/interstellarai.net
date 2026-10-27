#!/usr/bin/env bash
# Close archon-review / archon-smart-pr-review runs whose PR has merged.
#
# Merge-on-green (#71) never waits on a review, so a PR can merge — by a
# human, a ship run, or pr-maintenance — while its review is still running or
# parked. Such a run would keep spending model budget, post to a merged PR,
# and page the owner at an attention pause with nothing left to decide (#227).
# Closing it is `archon workflow abandon`: the run goes `cancelled`, which is
# neither active nor in the failed-run inbox.
#
# Usage:
#   source "$SCRIPT_DIR/lib/archon-active-runs.sh"; archon_runs_snapshot
#   source "$SCRIPT_DIR/lib/merged-reviews.sh"   # the caller defines log()
#   abandon_reviews "$repo_dir" "$project" 42      # after merging PR #42
#   abandon_review "$project" 42 "$run_id"         # one run of merged PR #42
#   pr=$(review_pr_merged "$project" "$user_message") && ...
#   close_merged_reviews "$repo_dir" "$project"    # sweep this tick's snapshot

[ -n "${_MERGED_REVIEWS_SH:-}" ] && return 0
_MERGED_REVIEWS_SH=1

ARCHON_REVIEW_WORKFLOWS_RE='^archon-(review|smart-pr-review)$'

# abandon_reviews <repo_dir> <project> <pr> — cancel every running or paused
# review run on a PR that has merged. pr-review-cron.sh fires one at any newly
# ready PR, so one can land minutes before the merge and would otherwise spend
# 5-10 minutes of model budget reviewing a merged PR (2026-09-10: reli #1438,
# un-reminder #307, each killed by hand). The merge has already happened, so a
# partial snapshot still abandons every review it can see, and says so: an
# empty match then does not mean no review is running. Returns 1 when any
# matched run could not be abandoned.
abandon_reviews() {
  local repo_dir="$1" project="$2" pr="$3" id rc=0
  if ! archon_runs_known; then
    log "$project: PR #$pr — no complete archon run snapshot this tick, a review run on the merged PR may be left running"
  fi
  while read -r id; do
    [ -n "$id" ] || continue
    abandon_review "$project" "$pr" "$id" || rc=1
  done < <(archon_run_active_ids "$repo_dir" "$project" "$ARCHON_REVIEW_WORKFLOWS_RE" "#${pr}([^0-9]|$)")
  return "$rc"
}

# abandon_review <project> <pr> <run_id> — cancel the one review run <run_id>
# of merged PR <pr>. Returns 1 when it could not be abandoned.
abandon_review() {
  local project="$1" pr="$2" id="$3"
  if CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 \
      archon workflow abandon "$id" --cwd "$ARCHON_RUNS_CWD" >/dev/null 2>&1; then
    log "$project: PR #$pr — abandoned review run $id on the merged PR"
  else
    log "$project: PR #$pr — could not abandon review run $id on the merged PR"
    return 1
  fi
}

# review_pr_merged <project> <user_message> — print the PR number the review's
# message names and exit 0 only when GitHub reads that PR as MERGED. A message
# naming no #N, any other state, or a gh failure exits 1: the run is left as it
# is.
review_pr_merged() {
  local project="$1" msg="$2" n state
  [[ "$msg" =~ \#([0-9]+) ]] || return 1
  n="${BASH_REMATCH[1]}"
  state=$(gh pr view "$n" --repo "alexsiri7/$project" --json state --jq .state 2>/dev/null) || return 1
  [ "$state" = MERGED ] || return 1
  echo "$n"
}

# close_merged_reviews <repo_dir> <project> — abandon every running or paused
# review run in this tick's snapshot whose PR has merged, asking GitHub once
# per distinct run message. Always returns 0.
close_merged_reviews() {
  local repo_dir="$1" project="$2" msg pr done_prs=" "
  while IFS= read -r msg; do
    pr=$(review_pr_merged "$project" "$msg") || continue
    case "$done_prs" in *" $pr "*) continue ;; esac
    done_prs="$done_prs$pr "
    log "$project: PR #$pr has merged while a review of it is running or parked — closing the review"
    abandon_reviews "$repo_dir" "$project" "$pr" || :
  done < <(archon_run_active_msgs "$repo_dir" "$project" "$ARCHON_REVIEW_WORKFLOWS_RE" | sort -u)
  return 0
}
