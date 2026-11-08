#!/usr/bin/env bats
# One "factory stuck" escalation per PR, not per head SHA (#260): Word Coach
# Annie PR #1292, held by its unsafe-change gate, got a new issue (and so a new
# archon-ship run and a new Lachesis author question) at each of seven SHAs.
#
# Run: bats ops/cron/tests/pipeline-health-pr-escalation.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/pr-escalation-$$"
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR"
    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"

    log() { printf '%s\n' "$*" >> "$STATE_DIR/log"; }
    sleep() { :; }
    add_to_project() { :; }
    notify() { :; }
    archon() { :; }
    nohup() { :; }
    disown() { :; }

    # The fake GitHub: open issues in issues.json, comments in comments.json,
    # one {"issue": N, "body": B} per comment.
    echo '[]' > "$STATE_DIR/issues.json"
    echo '[]' > "$STATE_DIR/comments.json"
    stub_gh

    load_fn file_stuck_issue
    load_fn find_pr_escalation
    load_fn pr_escalation_comment
}

teardown() {
    rm -rf "$STATE_DIR"
}

load_fn() {
    # shellcheck disable=SC1090
    source <(awk -v fn="^$1\\(\\)" '$0 ~ fn {p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
}

# arg <flag> <argv...>: the value after <flag>.
arg() {
    local flag="$1"; shift
    while [ $# -gt 1 ]; do
        [ "$1" = "$flag" ] && { printf '%s' "$2"; return; }
        shift
    done
}

stub_gh() {
    gh() {
        printf '%s\n' "$1 $2" >> "$STATE_DIR/gh-calls"
        case "$1 $2" in
            "label create") ;;
            "issue list")
                [ -z "${GH_LIST_FAILS:-}" ] || return 1
                # main-ci's title search, read through --jq: no SHA-titled issue.
                case "$*" in *--search*) return 0 ;; esac
                cat "$STATE_DIR/issues.json" ;;
            "issue create")
                local n
                n=$(jq '[.[].number] | (max // 99) + 1' "$STATE_DIR/issues.json")
                jq --argjson n "$n" --arg t "$(arg --title "$@")" --arg b "$(arg --body "$@")" \
                    '. + [{number: $n, title: $t, body: $b, labels: [{name: "manual-review"}]}]' \
                    "$STATE_DIR/issues.json" > "$STATE_DIR/tmp" && mv "$STATE_DIR/tmp" "$STATE_DIR/issues.json"
                echo "https://github.com/alexsiri7/test-project/issues/$n" ;;
            "issue view")
                jq -n --argjson n "$3" --slurpfile i "$STATE_DIR/issues.json" --slurpfile c "$STATE_DIR/comments.json" \
                    '{body: ($i[0][] | select(.number == $n) | .body),
                      comments: [$c[0][] | select(.issue == $n) | {body}]}' ;;
            "issue comment")
                jq --argjson n "$3" --arg b "$(arg --body "$@")" '. + [{issue: $n, body: $b}]' \
                    "$STATE_DIR/comments.json" > "$STATE_DIR/tmp" && mv "$STATE_DIR/tmp" "$STATE_DIR/comments.json" ;;
            "pr list") echo "$PR_LIST_FIXTURE" ;;
            "pr view") echo "{\"number\":$3,\"author\":{\"login\":\"alexsiri7\"},\"isCrossRepository\":false}" ;;
            *) echo "" ;;
        esac
    }
}

issues() { jq 'length' "$STATE_DIR/issues.json"; }
comments() { jq 'length' "$STATE_DIR/comments.json"; }

escalate() {
    file_stuck_issue "alexsiri7/test-project" "${2:-stuck-pr}" "$1" \
        "test-project PR #1 stuck (UNSTABLE)" \
        "https://github.com/alexsiri7/test-project/pull/1" 3 "/repo/.archon-logs/"
}

@test "a PR stuck across 3 head SHAs is 1 escalation issue and 2 comments, however often each SHA is escalated" {
    escalate sha1; escalate sha1
    escalate sha2; escalate sha2
    escalate sha3; escalate sha3; escalate sha2

    [ "$(issues)" -eq 1 ]
    [ "$(comments)" -eq 2 ]
    # The issue names its PR in the marker, and no SHA in the title.
    jq -e '.[0].body | contains("<!-- pipeline-health-escalation: alexsiri7/test-project#1 -->")' "$STATE_DIR/issues.json"
    jq -e '.[0].body | contains("**SHA**: `sha1`")' "$STATE_DIR/issues.json"
    [ "$(jq -r '.[0].title' "$STATE_DIR/issues.json")" = "factory stuck: test-project PR #1 stuck (UNSTABLE) after 3 attempts" ]
    # One comment per later SHA, each marked as automation, so Lachesis does
    # not take it for the author's answer and the issue asks no second question.
    [ "$(jq -r '[.[].body | capture("pipeline-health-escalation-sha: (?<s>\\S+) -->").s] | join(" ")' "$STATE_DIR/comments.json")" = "sha2 sha3" ]
    [ "$(jq '[.[] | select(.body | endswith("\n<!-- lachesis:automated -->"))] | length' "$STATE_DIR/comments.json")" -eq 2 ]
    [ "$(jq '[.[] | select(.issue == 100)] | length' "$STATE_DIR/comments.json")" -eq 2 ]
}

@test "the PR's pr-ci and stuck-pr escalations share its one issue" {
    escalate sha1 stuck-pr
    escalate sha2 pr-ci

    [ "$(issues)" -eq 1 ]
    [ "$(comments)" -eq 1 ]
    jq -e '.[0].body | contains("**Kind**: pr-ci")' "$STATE_DIR/comments.json"
}

@test "another PR of the repo, and the same PR number on another repo, get their own issue" {
    escalate sha1
    file_stuck_issue "alexsiri7/test-project" stuck-pr sha9 "test-project PR #12 stuck (DIRTY)" \
        "https://github.com/alexsiri7/test-project/pull/12" 3 /x
    file_stuck_issue "alexsiri7/other" stuck-pr sha1 "other PR #1 stuck (DIRTY)" \
        "https://github.com/alexsiri7/other/pull/1" 3 /x

    [ "$(issues)" -eq 3 ]
    [ "$(comments)" -eq 0 ]
}

@test "an escalation filed before the marker is found by its Kind and Evidence lines" {
    cat > "$STATE_DIR/issues.json" <<'JSON'
[{"number":1403,"title":"factory stuck: test-project PR #1 stuck (UNSTABLE) after 3 attempts (SHA old)","body":"**Kind**: stuck-pr\n**SHA**: `old`\n**Evidence**: https://github.com/alexsiri7/test-project/pull/1\n\nAuto-filed by `pipeline-health-cron.sh` after `sha_attempt_decide` exhausted the remediation budget for this SHA.","labels":[{"name":"manual-review"}]},
 {"number":1416,"title":"factory stuck: test-project PR #1 stuck (UNSTABLE) after 3 attempts (SHA older)","body":"**Kind**: stuck-pr\n**SHA**: `older`\n**Evidence**: https://github.com/alexsiri7/test-project/pull/1\n\nAuto-filed by `pipeline-health-cron.sh` after it gave up.","labels":[{"name":"manual-review"}]},
 {"number":1500,"title":"factory stuck: test-project PR #10 stuck (DIRTY) after 3 attempts (SHA x)","body":"**Kind**: stuck-pr\n**Evidence**: https://github.com/alexsiri7/test-project/pull/10\n\nAuto-filed by `pipeline-health-cron.sh`.","labels":[{"name":"manual-review"}]}]
JSON

    escalate new; escalate new

    [ "$(issues)" -eq 3 ]
    # The newest of the PR's pre-#260 issues takes the comment; PR #10's does not.
    [ "$(jq -r '[.[].issue] | join(" ")' "$STATE_DIR/comments.json")" = "1416" ]
}

@test "an escalation filed before the marker is found by its title when its body lacks the Evidence line" {
    echo '[{"number":7,"title":"factory stuck: test-project PR #1 CI red after 3 attempts (SHA old)","body":"Auto-filed by `pipeline-health-cron.sh`.","labels":[{"name":"manual-review"}]}]' \
        > "$STATE_DIR/issues.json"

    escalate new

    [ "$(issues)" -eq 1 ]
    [ "$(jq -r '.[0].issue' "$STATE_DIR/comments.json")" = "7" ]
}

@test "an issue this script did not file is not taken for the PR's escalation" {
    echo '[{"number":7,"title":"factory stuck: test-project PR #1 looks odd","body":"<!-- pipeline-health-escalation: alexsiri7/test-project#1 -->\n**Kind**: stuck-pr\n**Evidence**: https://github.com/alexsiri7/test-project/pull/1","labels":[]}]' \
        > "$STATE_DIR/issues.json"

    escalate new

    [ "$(issues)" -eq 2 ]
    [ "$(comments)" -eq 0 ]
}

@test "a failed issue listing files nothing and fails, so the caller retries" {
    escalate sha1
    GH_LIST_FAILS=1

    run escalate sha2

    [ "$status" -eq 1 ]
    [ "$(issues)" -eq 1 ]
    [ "$(comments)" -eq 0 ]
}

@test "main-ci escalations stay one per SHA" {
    file_stuck_issue "alexsiri7/test-project" main-ci m1 "test-project main CI red" \
        "https://github.com/alexsiri7/test-project/actions/runs/5" 3 /x

    [ "$(jq -r '.[0].title' "$STATE_DIR/issues.json")" = "factory stuck: test-project main CI red after 3 attempts (SHA m1)" ]
    jq -e '.[0].body | contains("pipeline-health-escalation:") | not' "$STATE_DIR/issues.json"
}

# End to end through check_stuck_prs: the attempt budget per SHA, the
# once-per-SHA ntfy marker, and the per-PR issue together.
@test "check_stuck_prs ticking on a PR stuck at 3 SHAs files 1 issue and 2 comments, and repeat ticks add nothing" {
    BASE_DIR="$STATE_DIR/repos"
    mkdir -p "$BASE_DIR/test-project/.git" "$STATE_DIR/escalated"
    MAX_ATTEMPTS=3
    export TRUST_STATE_DIR="$STATE_DIR/trust"
    export ARCHON_CRON_TRUST_FILE="$STATE_DIR/no-trust.env"
    export ARCHON_CRON_SECRETS="$STATE_DIR/no-secrets.env"
    curl() { :; }
    unset _ARCHON_TRUST_SH TRUSTED_AUTHORS TRUSTED_ISSUE_BOTS TRUSTED_MERGE_ONLY_AUTHORS
    # shellcheck source=../lib/trust.sh
    source "$(dirname "$SCRIPT_FILE")/lib/trust.sh"
    load_fn sha_attempt_decide
    load_fn check_stuck_prs

    local sha tick
    for sha in s1 s2 s3; do
        PR_LIST_FIXTURE='[{"number":1,"title":"stuck","headRefName":"archon/a","headRefOid":"'"$sha"'","isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","mergeStateStatus":"UNSTABLE"}]'
        # 3 attempts, the escalation, then ticks that back off.
        for tick in 1 2 3 4 5 6; do check_stuck_prs "test-project"; done
    done
    [ "$(issues)" -eq 1 ]
    [ "$(comments)" -eq 2 ]

    # Local state lost (a reboot's /tmp, a cleared escalated/ dir): the next
    # ticks at s3 escalate again, and GitHub already has it.
    rm -f "$STATE_DIR/escalated/"*
    for tick in 1 2; do check_stuck_prs "test-project"; done
    [ "$(issues)" -eq 1 ]
    [ "$(comments)" -eq 2 ]
}

@test "check_stuck_prs retries an escalation whose issue listing failed" {
    BASE_DIR="$STATE_DIR/repos"
    mkdir -p "$BASE_DIR/test-project/.git" "$STATE_DIR/escalated" "$STATE_DIR/stuck-pr"
    MAX_ATTEMPTS=3
    trust_filter_prs() { cat; }
    trust_comments_ok() { return 0; }
    load_fn sha_attempt_decide
    load_fn check_stuck_prs
    PR_LIST_FIXTURE='[{"number":1,"title":"stuck","headRefName":"archon/a","headRefOid":"s1","isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","mergeStateStatus":"UNSTABLE"}]'
    echo "s1:3" > "$STATE_DIR/stuck-pr/test-project-pr1"

    GH_LIST_FAILS=1 check_stuck_prs "test-project"
    [ "$(issues)" -eq 0 ]
    [ ! -e "$STATE_DIR/escalated/stuck-test-project-pr1-s1" ]

    check_stuck_prs "test-project"
    [ "$(issues)" -eq 1 ]
}
