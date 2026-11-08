#!/usr/bin/env bash
# The held-PR reviewer's verdict, pinned to the head it reviewed (#267).
#
# held-pr-review.sh reviews a PR held by `hold` or needs-owner-review and,
# before it hands the PR back to the factory, records what it decided at which
# head. pr-maintenance Phase 1 merges a handed-back PR only at the head an
# `approve` names (held_review_merge_gate), and re-holds one that moved since;
# pr-review-cron.sh fires no archon-review at a head that has a record, so its
# report never lands over this reviewer's. The records live in the owner's
# ~/.archon/state, which the sandboxed archon user cannot write: a label an
# agent adds approves nothing.
#
#   source "$SCRIPT_DIR/lib/held-review.sh"
#   held_review_get <project> <pr>                 # "<sha> <verdict> <label>"
#   held_review_set <project> <pr> <sha> <verdict> <label>
#   held_review_forget <project> <pr>
#   held_review_at_head <project> <pr> <sha>       # a valid record at <sha>?
#
# One file per PR in HELD_REVIEW_STATE, "<project>-<pr>", holding one line:
# a 40-hex head sha; the verdict, approve, block or owner; and the label the
# PR was held by, `hold` or $TRUST_HELD_LABEL, which Phase 1 puts back when the
# head moves. Anything else in the file is no record.

[ -n "${_HELD_REVIEW_SH:-}" ] && return 0
_HELD_REVIEW_SH=1

HELD_REVIEW_STATE="${HELD_REVIEW_STATE:-$HOME/.archon/state/held-review}"

held_review_get() {
  local sha verdict label extra
  read -r sha verdict label extra < "$HELD_REVIEW_STATE/$1-$2" 2>/dev/null || return 1
  [ -z "${extra:-}" ] && [[ "${sha:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "${verdict:-}" in approve|block|owner) ;; *) return 1 ;; esac
  case "${label:-}" in hold|"${TRUST_HELD_LABEL:-needs-owner-review}") ;; *) return 1 ;; esac
  echo "$sha $verdict $label"
}

held_review_set() {
  local f="$HELD_REVIEW_STATE/$1-$2"
  mkdir -p "$HELD_REVIEW_STATE" 2>/dev/null &&
    echo "$3 $4 $5" > "$f.tmp" 2>/dev/null &&
    mv "$f.tmp" "$f" 2>/dev/null
}

held_review_forget() { rm -f "$HELD_REVIEW_STATE/$1-$2"; }

held_review_at_head() {
  local rec
  rec=$(held_review_get "$1" "$2") || return 1
  [ "${rec%% *}" = "$3" ]
}
