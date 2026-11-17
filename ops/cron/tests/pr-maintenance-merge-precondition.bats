#!/usr/bin/env bats
# End-to-end tests for pr-maintenance-cron.sh's merge-precondition gate (#325):
# a fully trusted author's PR whose description or linked issue states a
# precondition to meet before it merges is labelled `hold` for the owner, not
# promoted or merged, and goes through once the owner removes the label.
#
# The real script against a temp project tree, with `gh` and `archon` stubbed
# in $HOME/.local/bin (see pr-hold-label.bats for why there). The gh stub
# answers `pr list` with $GH_PR_LIST, `pr view <n>` with $T/view-<n>.json
# (failing when it is missing), `issue view <n>` with $T/issue-<n>.json (no
# labels and an empty body when it is missing), and records every invocation.
#
# Run: npx bats@1.13.0 ops/cron/tests/pr-maintenance-merge-precondition.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export HOME="$T/home"
    STUB_BIN="$HOME/.local/bin"
    mkdir -p "$STUB_BIN" "$T/base/proj/.git"
    export BASE_DIR="$T/base"
    export ARCHON_RUNS_SNAPSHOT="$T/snapshot"
    export ARCHON_PROJECTS_FILE="$T/projects.txt"
    echo "proj" > "$ARCHON_PROJECTS_FILE"
    unset _ARCHON_TRUST_SH TRUSTED_AUTHORS TRUSTED_ISSUE_BOTS TRUSTED_MERGE_ONLY_AUTHORS TRUSTED_COMMENT_BOTS
    export ARCHON_CRON_TRUST_FILE="$T/no-trust.env"
    export TRUST_STATE_DIR="$T/trust"
    export NTFY_TOPIC=""
    export STUB_GH_ARGV="$T/gh-argv"
    : > "$STUB_GH_ARGV"

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
case "$1 $2" in
  "pr list")
    jqf="" prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
    if [ -n "$jqf" ]; then printf '%s' "$GH_PR_LIST" | jq -r "$jqf"; else printf '%s' "$GH_PR_LIST"; fi ;;
  "pr view")
    case "$*" in
      *"--json state"*) printf '{"state":"OPEN"}' ;;
      *) cat "$T/view-$3.json" 2>/dev/null || exit 1 ;;
    esac ;;
  "issue view") cat "$T/issue-$3.json" 2>/dev/null || printf '{"labels":[],"body":""}' ;;
  "pr comment")
    while [ $# -gt 0 ]; do [ "$1" = --body ] && printf '%s\n' "$2" >> "$T/comments"; shift; done ;;
esac
exit 0
STUB
    cat > "$STUB_BIN/archon" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "workflow runs" ] && printf '{"runs": []}'
exit 0
STUB
    chmod +x "$STUB_BIN/gh" "$STUB_BIN/archon"
    export PATH="$STUB_BIN:$PATH"
}

MARKER_DIR() { echo "$HOME/.archon/state/pr-maintenance"; }

# pr <number> <draft> [author] [labels-json] — a CLEAN same-repo PR row.
pr() {
    jq -nc --argjson n "$1" --argjson d "$2" --arg a "${3:-alexsiri7}" --argjson l "${4:-[]}" \
      '{number: $n, isDraft: $d, mergeStateStatus: "CLEAN", headRefName: "feat/x-\($n)", headRefOid: "abc\($n)",
        body: "", labels: $l, author: {login: $a}, isCrossRepository: false, title: "t", createdAt: "2026-01-01T00:00:00Z"}'
}

# view <number> <body> [closing-issue...] — what `gh pr view <n>` answers.
view() {
    local n="$1" body="$2"
    shift 2
    jq -nc --arg b "$body" --args '{title: "Split the token", body: $b, statusCheckRollup: [],
        closingIssuesReferences: [$ARGS.positional[] | {number: tonumber}]}' "$@" > "$T/view-$n.json"
}

PRECONDITION_BODY='Splits the deploy token per environment.

**Draft on purpose: do not merge until both environment secrets exist.**

## Before merging
1. Create `RAILWAY_PROJECT_TOKEN` in each GitHub environment.'

gh_called() { grep -qE "$1" "$STUB_GH_ARGV"; }

@test "a CLEAN PR whose description states a merge precondition is held for the owner, not merged" {
    export GH_PR_LIST="[$(pr 300 false)]"
    view 300 "$PRECONDITION_BODY"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    ! gh_called '^pr merge'
    gh_called '^pr edit 300 --add-label hold$'
    [ -f "$(MARKER_DIR)/proj-300.precondition-held" ]
    grep -qF "Holding this PR for the owner: this PR's description states a precondition to meet before it merges." "$T/comments"
    grep -qxF '> Draft on purpose: do not merge until both environment secrets exist.' "$T/comments"
    grep -qxF '> Before merging' "$T/comments"
    grep -qF 'Remove the `hold` label once it is' "$T/comments"
    grep -qxF '<!-- lachesis:automated -->' "$T/comments"
    [[ "$output" == *"proj: PR #300 — this PR's description states a precondition to meet before it merges; labelled hold for the owner"* ]]
    [ -f "$TRUST_STATE_DIR/proj-merge-precondition-300" ]
}

@test "once the owner removes hold from a PR the gate held, it merges" {
    mkdir -p "$(MARKER_DIR)"
    touch "$(MARKER_DIR)/proj-300.precondition-held"
    export GH_PR_LIST="[$(pr 300 false)]"
    view 300 "$PRECONDITION_BODY"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    gh_called '^pr merge 300 '
    ! gh_called '^pr edit 300'
    [ ! -f "$T/comments" ]
}

@test "a PR held-pr-review left to the owner merges once the owner removes its label" {
    local sha
    sha=$(printf '3%.0s' {1..40})
    mkdir -p "$HOME/.archon/state/held-review"
    echo "$sha owner hold" > "$HOME/.archon/state/held-review/proj-300"
    export GH_PR_LIST="[$(pr 300 false | jq -c --arg s "$sha" '.headRefOid = $s')]"
    view 300 "$PRECONDITION_BODY"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    gh_called '^pr merge 300 '
    ! gh_called '^pr edit 300'
}

@test "a CLEAN draft that states a merge precondition stays a draft and is held" {
    export GH_PR_LIST="[$(pr 301 true)]"
    view 301 "$PRECONDITION_BODY"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    ! gh_called '^pr ready'
    gh_called '^pr edit 301 --add-label hold$'
    [ -f "$(MARKER_DIR)/proj-301.precondition-held" ]
}

@test "a PR whose linked issue states the precondition is held, the issue named but not quoted" {
    export GH_PR_LIST="[$(pr 302 false), $(pr 303 false)]"
    view 302 "Refs #8" 7
    echo '{"labels":[],"body":"## Prerequisites\nThe owner sets SECRET_X first."}' > "$T/issue-8.json"
    view 303 "Fixes #9"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    ! gh_called '^pr merge 302'
    gh_called '^pr edit 302 --add-label hold$'
    grep -qF "Holding this PR for the owner: linked issue #8 states a precondition to meet before it merges." "$T/comments"
    ! grep -q 'SECRET_X\|Prerequisites' "$T/comments"
    gh_called '^issue view 7 --json body$'
    gh_called '^pr merge 303 '
}

@test "a merge-only bot's PR is never read for a precondition and merges as usual" {
    export GH_PR_LIST="[$(pr 304 false 'github-actions[bot]')]"
    view 304 "$PRECONDITION_BODY"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    gh_called '^pr merge 304 '
    ! gh_called '^pr edit 304'
}

@test "an unreadable PR or linked issue is neither merged nor labelled this tick" {
    export GH_PR_LIST="[$(pr 305 true), $(pr 306 false)]"
    view 306 "Closes #11"
    echo 'not json' > "$T/issue-11.json"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    ! gh_called '^pr ready'
    ! gh_called '^pr merge'
    ! gh_called '^pr edit'
    [[ "$output" == *"proj: PR #305 — could not read it for a merge precondition, not promoting or merging it this tick"* ]]
    [[ "$output" == *"proj: PR #306 — could not read linked issue #11 for a merge precondition, not promoting or merging it this tick"* ]]
}

@test "a hold label that cannot be added leaves no marker, so the next tick retries" {
    export GH_PR_LIST="[$(pr 300 false)]"
    view 300 "$PRECONDITION_BODY"
    sed -i 's/^case "\$1 \$2" in$/[ "$1 $2" = "pr edit" ] \&\& exit 1\n&/' "$STUB_BIN/gh"
    run "$CRON_DIR/pr-maintenance-cron.sh"
    [ "$status" -eq 0 ]
    ! gh_called '^pr merge'
    [ ! -f "$(MARKER_DIR)/proj-300.precondition-held" ]
    [ ! -f "$T/comments" ]
    [[ "$output" == *"could not add hold; retrying next tick"* ]]
}
