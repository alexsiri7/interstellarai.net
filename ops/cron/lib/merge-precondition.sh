#!/usr/bin/env bash
# Does a PR's (or its issue's) text state a precondition to meet before it
# merges? (alexsiri7/interstellarai.net#325: reli#1840 said "do not merge until
# both environment secrets exist", merged anyway, and every deploy after it
# failed.)
#
#   source "$SCRIPT_DIR/lib/merge-precondition.sh"
#   lines=$(merge_precondition_lines <<<"$body")   # 0 on a hit, 1 otherwise
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
