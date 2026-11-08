#!/usr/bin/env bash
# The closes the factory takes without asking the owner, beyond the two the
# SDLC pack's default triage policy allows (#259). Sourced by
# lib/settle-ship-outcome.sh, which decides when each applies, and by
# pipeline-health-cron.sh, which labels the alerts it closes on recovery.
#
# The owner's rule (2026-11-08): the factory may close any issue when it can
# say why, and the closing comment gives the reason and the evidence. It asks
# the owner only when closing would change what the project should be (a spec
# decision) or when the run cannot give a reason. Every such close carries the
# label FACTORY_CLOSED_LABEL, so the morning briefing can list them and the
# owner can reopen any that are wrong.
#
# Each reason here pairs a cue in the run's verdict (free prose, the pack's
# default triage policy still makes the run call these closes a maintainer's)
# with a fact this file looks up on GitHub. Prose alone never closes (#103):
#
#   self-resolved  a pipeline-health alert whose condition is false now:
#                  main's push CI is green at HEAD, or prod deployed the
#                  alert's SHA or HEAD successfully. No cue needed.
#   owner-decided  the verdict says the owner already decided, and the
#                  owner's latest own comment on the issue (not one the
#                  factory posted under the owner's token) says to close it.
#   precedent      the verdict calls the issue a false positive, duplicate or
#                  superseded and names closed same-repo issues (checked by
#                  settle) as the precedent.
#   spec           the verdict says the spec already decides it, citing a
#                  spec file that exists on the default branch.
#   feedback       in-app feedback whose text describes no defect, which the
#                  verdict calls praise or no defect.
#
# The caller vetoes precedent, spec and feedback on a tier-3 outcome
# (lib/severity.sh) and on a verdict that leaves a spec decision to the owner
# (FC_SPEC_DECISION_RE).

[ -n "${_FACTORY_CLOSE_SH:-}" ] && return 0
_FACTORY_CLOSE_SH=1

FACTORY_CLOSED_LABEL="${FACTORY_CLOSED_LABEL:-factory-closed}"

# Verdict cues, matched case-insensitively (grep -iE).
# shellcheck disable=SC2034  # the cues are read by lib/settle-ship-outcome.sh
FC_PRECEDENT_RE='false[- ]positive|false premise|premise (is|was) false|not a (real )?bug|duplicat|same (as|issue|report|claim|false positive)|precedent|supersed|supersession'
# shellcheck disable=SC2034
FC_PRECEDENT_NEG_RE='not (a |an )?(false[- ]positive|duplicate)|is ?n.t (a |an )?(false[- ]positive|duplicate)'
# shellcheck disable=SC2034
FC_OWNER_CUE_RE='(owner|maintainer|author)[^.]{0,120}(decided|said|asked|answered|confirmed|agreed|wrote|stated|instructed|directed|ruled)'
# shellcheck disable=SC2034
FC_SPEC_CUE_RE='spec[^ ]*[^.]{0,160}(already )?(decides|decided|states|says|requires|affirms|specifies|rules)|(by design|on purpose|deliberate(ly)?|as specified|per (the )?spec)'
# shellcheck disable=SC2034
FC_FEEDBACK_CUE_RE='praise|compliment|thank|positive feedback|no defect|not a bug report|nothing to fix|no (bug|defect|problem|fault) (is )?(described|reported)'
# A verdict that leaves what the project should be to the owner. None of the
# judgment closes above is taken on it.
# shellcheck disable=SC2034
FC_SPEC_DECISION_RE='(revise|change|amend|update|rewrite|reopen) (the |its |this )?spec|spec (change|decision|revision)|whether to (revise|change|reaffirm|keep)|product decision|owner-level (product )?decision'

# What an owner comment must say to settle the issue, and what turns it into
# its opposite ("rather than closing it", "can't be auto-closed", "keep it open").
FC_CLOSE_INTENT_RE='(^|[^a-z])(close|closing|closed)([^a-z]|$)|out of (this repo.?s |this repository.?s |)scope|won.?t ?fix|not planned|no ([a-z-]+ )?change (is )?needed|nothing (to do|is needed)'
FC_CLOSE_NEG_RE='(do not|don.t|not|never|n.t|rather than|instead of|before|until)( be)? (auto-)?clos|keep (it |this )?open|leave (it |this )?open|leaving it|reopen'

# Defect words that mean a feedback note reports a problem, not praise.
FC_DEFECT_RE='crash|error|bug|broken|break|fail|doesn.?t|does not|didn.?t|can.?t|cannot|won.?t|unable|freez|stuck|wrong|problem|slow|lag|glitch|issue|missing|not work|please fix|should'

# fc_ensure_label <repo> — creates FACTORY_CLOSED_LABEL; an existing label (or
# any failure) is fine: the label is then added in its own edit, so a missing
# label never costs the archon:done relabel.
fc_ensure_label() {
  gh label create "$FACTORY_CLOSED_LABEL" --repo "$1" --color 5319e7 \
    --description "Closed by the factory with a cited reason (#259); reopen if wrong" \
    >/dev/null 2>&1 || true
}

# fc_main_head <repo> — main's HEAD SHA, or fails.
fc_main_head() {
  local sha
  sha=$(gh api "repos/$1/commits/main" --jq '.sha' 2>/dev/null) || return 1
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  echo "$sha"
}

# fc_prod_deployed <repo> <sha> — 0 when a production run or deployment
# succeeded at <sha>, judged as pipeline-health's check_prod_deploy does: the
# newest "Production" workflow run at the SHA, else the newest production
# deployment at the SHA and its latest status.
fc_prod_deployed() {
  local repo="$1" sha="$2" runs conclusion dep_id state
  runs=$(gh run list --repo "$repo" --branch main --commit "$sha" --limit 20 \
    --json name,conclusion,createdAt 2>/dev/null) || runs=""
  conclusion=$(jq -r '[.[]? | select(.name | test("Production"; "i"))] | sort_by(.createdAt) | last | .conclusion // empty' \
    <<<"$runs" 2>/dev/null)
  if [ -n "$conclusion" ]; then
    [ "$conclusion" = success ]
    return
  fi
  dep_id=$(gh api "repos/$repo/deployments?sha=$sha&per_page=10" 2>/dev/null \
    | jq -r '[.[]? | select(.environment | test("production"; "i"))] | .[0].id // empty' 2>/dev/null)
  [ -n "$dep_id" ] || return 1
  state=$(gh api "repos/$repo/deployments/$dep_id/statuses?per_page=1" --jq '.[0].state // empty' 2>/dev/null)
  [ "$state" = success ]
}

# fc_alert_resolved <repo> <title> <body> — echoes the evidence and returns 0
# when the condition a pipeline-health alert reports is false now. Main CI
# red: every failing workflow the body names has a newest push run at main's
# HEAD that succeeded. Prod deploy lagging/failed: prod deployed the alert's
# SHA or HEAD successfully. Any other alert, or any lookup that fails, is not
# verified.
fc_alert_resolved() {
  local repo="$1" title="$2" body="$3" head sha wfs wf runs c checked=""
  head=$(fc_main_head "$repo") || return 1
  case "$title" in
    "Main CI red"*)
      wfs=$(sed -nE 's/^\*\*Failing workflows at this SHA\*\*: *//p' <<<"$body" | head -1)
      [ -n "$wfs" ] || wfs=$(sed -nE 's/^\*\*Workflow\*\*: *//p' <<<"$body" | head -1)
      [ -n "$wfs" ] || return 1
      runs=$(gh run list --repo "$repo" --branch main --commit "$head" --event push --limit 50 \
        --json name,status,conclusion,createdAt 2>/dev/null) || return 1
      while IFS= read -r wf; do
        wf=$(sed -E 's/^ +| +$//g' <<<"$wf")
        [ -n "$wf" ] || continue
        c=$(jq -r --arg wf "$wf" '[.[]? | select(.name == $wf)] | sort_by(.createdAt) | last
              | if . == null then "" else "\(.status)/\(.conclusion // "")" end' <<<"$runs" 2>/dev/null)
        [ "$c" = completed/success ] || return 1
        checked+="${checked:+, }$wf"
      done < <(tr ',' '\n' <<<"$wfs")
      [ -n "$checked" ] || return 1
      echo "main's push CI ($checked) is green now at HEAD ${head:0:10}" ;;
    "Prod deploy lagging main"*|"Prod deploy failed"*)
      # shellcheck disable=SC2016  # the backticks are issue markdown
      sha=$(grep -oE '^\*\*(main HEAD|SHA)\*\*: `[0-9a-f]{7,40}`' <<<"$body" | head -1 | grep -oE '[0-9a-f]{7,40}')
      if [ -n "$sha" ] && fc_prod_deployed "$repo" "$sha"; then
        echo "prod deployed the alert's SHA ${sha:0:10} successfully"
      elif fc_prod_deployed "$repo" "$head"; then
        echo "prod deployed main's HEAD ${head:0:10} successfully"
      else
        return 1
      fi ;;
    *) return 1 ;;
  esac
}

# fc_owner_decision <repo> <issue> — echoes "<url><TAB><quote>" for the
# owner's latest own comment on the issue when it says to close it. Every
# factory comment is posted under the owner's token, so login and association
# cannot tell them apart; the factory's comments carry <!-- lachesis:automated -->
# or an <!-- archon… --> marker, and a comment with either is not the owner's.
# A latest own comment that does not say close (or says not to) decides
# nothing, even when an older one did.
fc_owner_decision() {
  local repo="$1" issue="$2" owner="${1%%/*}" last url text
  local jqf=".[] | select(.user.login == \"$owner\" and .author_association == \"OWNER\")"
  jqf+=" | select((.body // \"\") | (contains(\"<!-- lachesis:automated -->\") or contains(\"<!-- archon\")) | not)"
  jqf+=" | [.html_url // \"\", .body] | @json"
  last=$(gh api --paginate "repos/$repo/issues/$issue/comments" --jq "$jqf" 2>/dev/null | tail -n 1) || return 1
  [ -n "$last" ] || return 1
  url=$(jq -r '.[0]' <<<"$last" 2>/dev/null) text=$(jq -r '.[1]' <<<"$last" 2>/dev/null) || return 1
  grep -qiE "$FC_CLOSE_INTENT_RE" <<<"$text" || return 1
  grep -qiE "$FC_CLOSE_NEG_RE" <<<"$text" && return 1
  text=$(tr '\n' ' ' <<<"$text" | sed -E 's/ +/ /g; s/^ //; s/ $//')
  [ "${#text}" -gt 300 ] && text="${text:0:300}…"
  printf '%s\t%s\n' "$url" "$text"
}

# fc_spec_paths <repo> <verdict text> — echoes the spec files the verdict
# cites (path[:line], at most three checked) that exist on the default branch.
# A spec file is one whose path names a spec or requirements document.
fc_spec_paths() {
  local repo="$1" cite path found=""
  while IFS= read -r cite; do
    path="${cite%%:*}"
    [[ "$path" =~ (^|/)(open)?specs?(/|\.|-)|(^|/)requirements(/|\.)|(^|/)SPEC ]] || continue
    [ "$(gh api "repos/$repo/contents/$path" --jq '.type' 2>/dev/null)" = file ] || continue
    found+="${found:+, }\`$cite\`"
  done < <(grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.(md|ya?ml)(:[0-9]+)?' <<<"$2" \
             | grep -vE '^(triage|investigation|plan)\.md' | awk '!seen[$0]++' | head -3)
  [ -n "$found" ] || return 1
  echo "$found"
}

# fc_feedback_text <title> <body> — echoes the sender's note when the issue is
# in-app feedback (workers/feedback: title "Bug: …"/"Feature: …", or the
# **App version:** context block) whose note is short and names no defect.
# The note is a stranger's text going into a comment under the owner's token,
# so it is echoed through screening's restatement charset (lib/screen.sh): no
# #refs, @mentions, links, backticks, markup or HTML comments survive.
fc_feedback_text() {
  local title="$1" body="$2" note
  [[ "$title" =~ ^(Bug|Feature):\  || "$body" == *"**App version:**"* ]] || return 1
  note=$(awk '/^---[ \t]*$/ || /^### Context/ {exit} {print}' <<<"$body" | tr '\n' ' ' \
    | sed -E 's/ +/ /g; s/^ //; s/ $//')
  [ -n "$note" ] || note="${title#*: }"
  [ "${#note}" -le 300 ] || return 1
  grep -qiE "$FC_DEFECT_RE" <<<"$note" && return 1
  note=$(tr -cd "A-Za-z0-9 .,:;_/=+'-" <<<"$note" | sed -E 's#://##g; s/ +/ /g; s/^ //; s/ $//')
  [ -n "$note" ] || return 1
  echo "$note"
}
