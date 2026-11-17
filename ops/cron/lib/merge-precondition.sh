#!/usr/bin/env bash
# Does a PR's (or its issue's) text state a precondition to meet before it
# merges? (alexsiri7/interstellarai.net#325: reli#1840 said "do not merge until
# both environment secrets exist", merged anyway, and every deploy after it
# failed.)
#
#   source "$SCRIPT_DIR/lib/merge-precondition.sh"
#   lines=$(merge_precondition_lines <<<"$body")   # 0 on a hit, 1 otherwise
#   found=$(merge_precondition_find <repo> "$view")  # 0 hit, 1 none, 2 unread
#   issues=$(linked_issue_numbers <<<"$view")
#
# A line counts, outside fenced code blocks and case-insensitively, when it is
#   - a markdown heading naming "before (this|the|it) merg…", "pre-merge",
#     "prerequisite" or "precondition" (## Before merging, ## Prerequisites);
#   - a bold label line naming one of those (**Before merging:** …);
#   - anywhere, "do not / don't / must not / should not / not to merge
#     [this|it] [PR|pull request] until / before / without".
# The factory can never confirm such a precondition is met, so every hit is
# the owner's. Prose that only mentions one ("this has a precondition") and
# "do not merge from here" do not count.

[ -n "${_ARCHON_MERGE_PRECONDITION_SH:-}" ] && return 0
_ARCHON_MERGE_PRECONDITION_SH=1

MERGE_PRECONDITION_TERMS='before (this |the |it )?merg|pre-?merge|prerequisite|precondition'
MERGE_PRECONDITION_RE="^ {0,3}#{1,6}[[:space:]].*($MERGE_PRECONDITION_TERMS)|^[[:space:]]*\*\*[^*]*($MERGE_PRECONDITION_TERMS)[^*]*\*\*|(do not|don'?t|must not|should not|not to) merge( (this|it))?( (pr|pull request))? (until|before|without)([^[:alnum:]]|$)"

# merge_precondition_lines — read text on stdin; print up to 3 of its matching
# lines, heading markers, bold, backticks and surrounding blanks dropped and
# each cut to 200 characters. Exit 0 on a hit, 1 when there is none. Every
# stage reads its input to the end, so no writer dies of SIGPIPE under
# pipefail.
merge_precondition_lines() {
  awk '/^[[:space:]]*(```|~~~)/{f=!f; next} !f' | tr -d '\r' \
    | { grep -iE "$MERGE_PRECONDITION_RE" || true; } | awk 'NR <= 3' \
    | sed -E 's/^[[:space:]]*#+[[:space:]]*//; s/[*`]//g; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | cut -c1-200 | grep .
}

# linked_issue_numbers — read a PR's `gh pr view --json
# body,closingIssuesReferences` on stdin; print the issues it links, closing
# references first, then "close/fix/resolve/refs #N" in its body, deduped and
# at most 3, one per line.
linked_issue_numbers() {
  local view
  view=$(cat)
  { printf '%s' "$view" | jq -r '.closingIssuesReferences[]?.number' 2>/dev/null
    printf '%s' "$view" | jq -r '.body // ""' 2>/dev/null \
      | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?|refs?) #[0-9]+' | grep -oE '[0-9]+$'
  } | awk '/^[0-9]+$/ && !seen[$0]++ && ++n <= 3' || true
}

# merge_precondition_find <repo> <view-json> — does the PR (its `gh pr view
# --json body,closingIssuesReferences`) or one of its linked issues state a
# merge precondition? Each text is checked on its own and as filed, never a
# restatement: one issue's unclosed fence must not hide the next. On a hit
# print where ("this PR's description" or "linked issue #N") and, for the
# description, its matching lines; exit 0. Exit 1 on no hit. Exit 2, printing
# "it" or "linked issue #N", when the PR or a linked issue cannot be read.
merge_precondition_find() {
  local repo="$1" view="$2" body hits n iview
  body=$(printf '%s' "$view" | jq -er '.body // ""' 2>/dev/null) || { echo it; return 2; }
  if hits=$(printf '%s\n' "$body" | merge_precondition_lines); then
    printf "this PR's description\n%s\n" "$hits"
    return 0
  fi
  for n in $(printf '%s' "$view" | linked_issue_numbers); do
    if ! iview=$(gh issue view "$n" --repo "$repo" --json body 2>/dev/null) \
       || ! iview=$(printf '%s' "$iview" | jq -er '.body // ""' 2>/dev/null); then
      echo "linked issue #$n"
      return 2
    fi
    if printf '%s\n' "$iview" | merge_precondition_lines >/dev/null; then
      echo "linked issue #$n"
      return 0
    fi
  done
  return 1
}
