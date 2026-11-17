#!/usr/bin/env bats
# Tests for check_failure_signatures in pipeline-health-cron.sh (#319): one
# factory-gap escalation when several ship runs fail with the same error.
#
# Run: bats ops/cron/tests/pipeline-health-failure-signatures.bats

setup() {
    T="$BATS_TMPDIR/failure-signatures-$$"
    export BASE_DIR="$T/base"
    REPOS=(reli filmduel annie)
    for p in "${REPOS[@]}"; do mkdir -p "$BASE_DIR/$p/.archon-logs"; done
    FAILURE_SIGNATURE_REPO=alexsiri7/interstellarai.net
    FAILURE_SIGNATURE_MIN_RUNS=3 FAILURE_SIGNATURE_WINDOW_MINUTES=1440
    echo '[]' > "$T/issues.json"
    : > "$T/log"; : > "$T/gh-calls"

    log() { echo "$*" >> "$T/log"; }
    # gh against $T/issues.json: list, create, view, comment.
    gh() {
        echo "$*" >> "$T/gh-calls"
        local body="" title="" n
        case "$1 $2" in
            "issue list") [ -z "${GH_LIST_FAIL:-}" ] || return 1; cat "$T/issues.json" ;;
            "issue create")
                while [ $# -gt 0 ]; do
                    case "$1" in --body) body="$2"; shift ;; --title) title="$2"; shift ;; esac
                    shift
                done
                n=$(( $(jq length "$T/issues.json") + 100 ))
                jq --argjson n "$n" --arg t "$title" --arg b "$body" \
                    '. + [{number: $n, state: "OPEN", title: $t, body: $b, closedAt: null, comments: []}]' \
                    "$T/issues.json" > "$T/i" && mv "$T/i" "$T/issues.json"
                echo "https://github.com/$FAILURE_SIGNATURE_REPO/issues/$n" ;;
            "issue view")
                jq --argjson n "$3" '.[] | select(.number == $n) | {body, comments}' "$T/issues.json" ;;
            "issue comment")
                n="$3"
                while [ $# -gt 0 ]; do [ "$1" = --body ] && body="$2"; shift; done
                jq --argjson n "$n" --arg b "$body" \
                    'map(if .number == $n then .comments += [{body: $b}] else . end)' \
                    "$T/issues.json" > "$T/i" && mv "$T/i" "$T/issues.json" ;;
        esac
    }

    D="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    # shellcheck disable=SC1090
    source <(awk '/^ship_breaker_redact\(\)/{p=1} p{print} p && /^}$/{p=0}' "$D/lib/ship-breaker.sh")
    # shellcheck disable=SC1090
    source <(awk '/^(run_failure_signature|node_failure_error|check_failure_signatures|escalate_failure_signature)\(\)/{p=1}
                  p{print} p && /^}$/{p=0}' "$D/pipeline-health-cron.sh")
}

teardown() {
    rm -rf "$T"
}

failed_run() {  # <project> <issue> <error>
    printf '%s\n' "[outcome] Failed" \
        "❌ DAG workflow 'archon-ship' completed with failures: 'review__publish': $3" \
        > "$BASE_DIR/$1/.archon-logs/cron-issue-$2-20261114-101010.log"
}

publish_error() {  # <comment id>
    echo "Script node 'review__publish' failed [exit 1]: publish-review: comment $1 does not read back as written; it may need reconciling"
}

issues() { jq length "$T/issues.json"; }
comments() { jq '[.[].comments | length] | add // 0' "$T/issues.json"; }

@test "three runs sharing a signature file one escalation, and the next tick nothing new" {
    failed_run reli 11 "$(publish_error 3412345)"
    failed_run filmduel 22 "$(publish_error 98)"
    failed_run annie 33 "$(publish_error 7)"
    oldest=$(( $(date +%s) - 20 * 3600 ))
    touch -d "@$(( oldest + 19 * 3600 ))" "$BASE_DIR/reli/.archon-logs/cron-issue-11-20261114-101010.log"
    touch -d "@$oldest" "$BASE_DIR/filmduel/.archon-logs/cron-issue-22-20261114-101010.log"
    touch -d "@$(( oldest + 10 * 3600 ))" "$BASE_DIR/annie/.archon-logs/cron-issue-33-20261114-101010.log"

    check_failure_signatures

    [ "$(issues)" -eq 1 ]
    body=$(jq -r '.[0].body' "$T/issues.json")
    [[ "$(jq -r '.[0].title' "$T/issues.json")" == "factory-gap: 3 runs failed at review__publish with the same error" ]]
    [[ "$body" == *"'review__publish': Script node 'review__publish' failed [exit <id>]: publish-review: comment <id> does not read back"* ]]
    [[ "$body" == *"cron-issue-11-20261114-101010.log"* ]]
    [[ "$body" == *"cron-issue-22-20261114-101010.log"* ]]
    [[ "$body" == *"cron-issue-33-20261114-101010.log"* ]]
    [[ "$body" == *"**First seen**: $(date -u -d "@$oldest" '+%Y-%m-%d %H:%M UTC')"* ]]
    [ "$(grep -o 'cron-issue-[0-9]*' <<<"$body" | tr '\n' ' ')" = "cron-issue-22 cron-issue-33 cron-issue-11 " ]
    [ "$(tail -n1 <<<"$body")" = "<!-- lachesis:automated -->" ]
    grep -q -- '^issue list .*--label factory-gap' "$T/gh-calls"
    grep -q -- '^issue create .*--label factory-gap' "$T/gh-calls"

    check_failure_signatures

    [ "$(issues)" -eq 1 ]
    [ "$(comments)" -eq 0 ]
    grep -q 'escalation #100 already lists every run failing at review__publish' "$T/log"
}

@test "a later run with the same signature is one comment on the open escalation" {
    failed_run reli 11 "$(publish_error 1)"
    failed_run filmduel 22 "$(publish_error 2)"
    failed_run annie 33 "$(publish_error 3)"
    check_failure_signatures
    failed_run reli 44 "$(publish_error 4)"

    check_failure_signatures
    check_failure_signatures

    [ "$(issues)" -eq 1 ]
    [ "$(comments)" -eq 1 ]
    comment=$(jq -r '.[0].comments[0].body' "$T/issues.json")
    [[ "$comment" == *"cron-issue-44-20261114-101010.log"* ]]
    [[ "$comment" != *"cron-issue-11-"* ]]
    [ "$(tail -n1 <<<"$comment")" = "<!-- lachesis:automated -->" ]
}

first_node_failed() {  # <project> <issue> <node> <dag_node_failed fields>
    printf '%s\n' \
        '{"level":50,"time":1794743233050,"nodeId":"'"$3"'",'"$4"',"msg":"dag_node_failed"}' \
        "❌ DAG workflow 'archon-ship-block' failed: nodes $3, deliver failed. 3$2 downstream nodes were skipped." \
        > "$BASE_DIR/$1/.archon-logs/cron-issue-$2-20261114-101010.log"
}

@test "runs where no node completed are signed by the failing node's own error" {
    first_node_failed reli 1 forge '"exitCode":1,"stderrTail":"gh: not authenticated (run 12)"'
    first_node_failed filmduel 2 forge '"exitCode":1,"stderrTail":"gh: not authenticated (run 34)"'
    first_node_failed annie 3 forge '"exitCode":1,"stderrTail":"gh: not authenticated\n(run 56)"'

    check_failure_signatures

    [ "$(issues)" -eq 1 ]
    [ "$(jq -r '.[0].title' "$T/issues.json")" = "factory-gap: 3 runs failed at forge with the same error" ]
    [[ "$(jq -r '.[0].body' "$T/issues.json")" == *"'forge': gh: not authenticated (run <id>)"* ]]
}

@test "runs where no node completed, failing for different reasons or quoting none, file nothing" {
    first_node_failed reli 1 forge '"exitCode":1,"stderrTail":"gh: not authenticated"'
    first_node_failed filmduel 2 forge '"exitCode":128,"stderrTail":"fatal: could not read from remote"'
    first_node_failed annie 3 forge '"err":{"type":"Error","message":"Claude Code process exited with code 1"}'
    first_node_failed reli 4 forge '"exitCode":1,"stderrTail":""'
    printf '%s\n' "❌ DAG workflow 'archon-ship-block' failed: node forge failed. 7 downstream nodes were skipped." \
        > "$BASE_DIR/filmduel/.archon-logs/cron-issue-5-20261114-101010.log"
    for i in 6 7 8; do
        printf '%s\n' "❌ DAG workflow 'archon-ship-block' completed with no successful nodes. Check node conditions, trigger rules, and upstream failures." \
            > "$BASE_DIR/annie/.archon-logs/cron-issue-$i-20261114-101010.log"
    done

    check_failure_signatures

    [ "$(issues)" -eq 0 ]
    [ ! -s "$T/gh-calls" ]
}

@test "different messages, or fewer than three matches, file nothing" {
    failed_run reli 11 "$(publish_error 1)"
    failed_run filmduel 22 "$(publish_error 2)"
    failed_run annie 33 "Script node 'review__publish' failed [exit 1]: publish-review: no review document"

    check_failure_signatures

    [ "$(issues)" -eq 0 ]
    [ ! -s "$T/gh-calls" ]
}

@test "the same error at a different node is a different signature" {
    failed_run reli 11 "$(publish_error 1)"
    failed_run filmduel 22 "$(publish_error 2)"
    printf '%s\n' "❌ DAG workflow 'archon-ship' completed with failures: 'deliver': $(publish_error 3)" \
        > "$BASE_DIR/annie/.archon-logs/cron-issue-33-20261114-101010.log"

    check_failure_signatures

    [ "$(issues)" -eq 0 ]
}

@test "rate-limit failures, old logs and other logs are not counted" {
    failed_run reli 11 "$(publish_error 1)"
    failed_run filmduel 22 "$(publish_error 2)"
    failed_run annie 33 "$(publish_error 3)"
    touch -d '2 days ago' "$BASE_DIR/annie/.archon-logs/cron-issue-33-20261114-101010.log"
    printf '%s\n' "❌ DAG workflow 'archon-ship' completed with failures: 'review__publish': $(publish_error 4)" \
        > "$BASE_DIR/annie/.archon-logs/pr-maint-44-20261114-101010.log"
    for i in 5 6 7; do
        failed_run annie "$i" "Claude Code returned an error result: rate_limit_error (request $i)"
    done
    for i in 8 9 10; do
        failed_run reli "$i" "API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}"
        failed_run filmduel "$i" "API Error: 429 quota exceeded"
    done

    check_failure_signatures

    [ "$(issues)" -eq 0 ]
}

@test "runs older than the signature's closed escalation are not filed again" {
    failed_run reli 11 "$(publish_error 1)"
    failed_run filmduel 22 "$(publish_error 2)"
    failed_run annie 33 "$(publish_error 3)"
    check_failure_signatures
    jq --arg at "$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)" \
        'map(.state = "CLOSED" | .closedAt = $at)' "$T/issues.json" > "$T/i" && mv "$T/i" "$T/issues.json"

    check_failure_signatures

    [ "$(issues)" -eq 1 ]
    [ "$(comments)" -eq 0 ]
}

@test "secrets in the error are redacted before they are quoted" {
    for i in 1 2 3; do
        failed_run reli "$i" "Script node 'review__publish' failed [exit 1]: push to https://x-access-token:ghs_abcdefghijklmnopqrstu@github.com/a/b refused"
    done

    check_failure_signatures

    body=$(jq -r '.[0].body' "$T/issues.json")
    [[ "$body" == *"https://[redacted]@github.com"* ]]
    [[ "$body" != *ghs_abc* ]]
}

@test "a failed listing files nothing" {
    failed_run reli 11 "$(publish_error 1)"
    failed_run filmduel 22 "$(publish_error 2)"
    failed_run annie 33 "$(publish_error 3)"
    GH_LIST_FAIL=1

    check_failure_signatures

    [ "$(issues)" -eq 0 ]
    grep -q 'could not list factory-gap issues' "$T/log"
}
