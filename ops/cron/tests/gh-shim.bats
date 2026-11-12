#!/usr/bin/env bats
# ops/host/archon-user/gh-shim/gh: the factory's gh wrapper stamps
# <!-- lachesis:automated --> on every issue/PR comment an archon session posts
# (#298) and passes every other call through unchanged.
#
# Run: bunx bats ops/cron/tests/gh-shim.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    SHIM="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../host/archon-user/gh-shim" && pwd)"
    mkdir -p "$T/real"
    # The real gh: its argv one per line in $T/argv, its stdin in $T/stdin when
    # an argument is `-`; prints real-gh-out and exits $STUB_RC.
    cat > "$T/real/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$T/argv"
for a in "$@"; do [ "$a" = - ] && { cat > "$T/stdin"; break; }; done
echo real-gh-out
exit "${STUB_RC:-0}"
STUB
    chmod +x "$T/real/gh"
    export PATH="$SHIM:$T/real:$PATH"
    MARKER='<!-- lachesis:automated -->'
    cd "$T"
}

argv_is() { diff <(printf '%s\n' "$@") "$T/argv"; }
stdin_is() { diff <(printf '%s' "$1") "$T/stdin"; }

@test "issue comment --body: the body goes to --body-file - and ends with the marker" {
    run gh issue comment 5 -R a/b --body "hi"
    [ "$status" -eq 0 ]
    argv_is issue comment 5 -R a/b --body-file -
    stdin_is "hi"$'\n\n'"$MARKER"
}

@test "pr comment --body-file <file> and issue comment -F - from a pipe are stamped" {
    printf 'from a file\n' > f.md
    run gh pr comment 7 --body-file f.md
    [ "$status" -eq 0 ]
    argv_is pr comment 7 --body-file -
    stdin_is "from a file"$'\n\n'"$MARKER"

    printf 'from a pipe' | gh issue comment 7 -F -
    argv_is issue comment 7 --body-file -
    stdin_is "from a pipe"$'\n\n'"$MARKER"
}

@test "a body that already ends with the marker is not stamped twice" {
    run gh issue comment 5 -b "done"$'\n\n'"$MARKER"$'\n'
    [ "$status" -eq 0 ]
    [ "$(grep -c 'lachesis:automated' "$T/stdin")" -eq 1 ]
    stdin_is "done"$'\n\n'"$MARKER"
}

@test "a -- before the issue number stays after the rewritten body flag" {
    run gh issue comment -b "hi" -- 5
    [ "$status" -eq 0 ]
    argv_is issue comment --body-file - -- 5
    stdin_is "hi"$'\n\n'"$MARKER"
}

@test "issue|pr close -c/--comment: the comment value is stamped, other args kept in order" {
    run gh issue close 3 -c "done" --reason completed
    [ "$status" -eq 0 ]
    argv_is issue close 3 -c "done"$'\n\n'"$MARKER" --reason completed

    run gh pr close 3 --comment=done
    [ "$status" -eq 0 ]
    argv_is pr close 3 "--comment=done"$'\n\n'"$MARKER"
}

@test "api -f body= and -F body=@file to an issue-comments endpoint are stamped" {
    run gh api repos/a/b/issues/4/comments -f body=x
    [ "$status" -eq 0 ]
    argv_is api repos/a/b/issues/4/comments -f "body=x"$'\n\n'"$MARKER"

    printf 'edited\n' > f.md
    run gh api -X PATCH 'repos/{owner}/{repo}/issues/comments/9' -F body=@f.md
    [ "$status" -eq 0 ]
    argv_is api -X PATCH 'repos/{owner}/{repo}/issues/comments/9' -f "body=edited"$'\n\n'"$MARKER"
}

@test "api --input JSON to an issue-comments endpoint: .body stamped, other keys kept" {
    printf '{"body":"hello","extra":1}' > in.json
    run gh api repos/a/b/issues/4/comments --input in.json
    [ "$status" -eq 0 ]
    argv_is api repos/a/b/issues/4/comments --input -
    [ "$(jq -r .body "$T/stdin")" = "hello"$'\n\n'"$MARKER" ]
    [ "$(jq -r .extra "$T/stdin")" = 1 ]
}

@test "api --input - that jq cannot parse reaches the real gh with its bytes intact" {
    printf 'not json {{{' | gh api -X POST repos/a/b/issues/4/comments --input -
    argv_is api -X POST repos/a/b/issues/4/comments --input -
    stdin_is 'not json {{{'
}

@test "api PATCH of an issue or PR body with the endpoint after the flags is untouched" {
    run gh api -X PATCH -f body=x repos/a/b/pulls/4
    [ "$status" -eq 0 ]
    argv_is api -X PATCH -f body=x repos/a/b/pulls/4
    run gh api -X PATCH -f body=x repos/a/b/issues/4
    [ "$status" -eq 0 ]
    argv_is api -X PATCH -f body=x repos/a/b/issues/4
    run gh api -f body=x repos/a/b/issues/4/comments -X GET
    argv_is api -f body=x repos/a/b/issues/4/comments -X GET
}

@test "a GraphQL addComment is refused before the real gh runs" {
    run gh api graphql -f query='mutation { addComment(input: {subjectId: "x", body: "y"}) { clientMutationId } }'
    [ "$status" -eq 2 ]
    [[ "$output" == *"gh issue comment"* ]]
    [ ! -e "$T/argv" ]
}

@test "a GraphQL comment mutation from --input or -F query=@- is refused too" {
    printf '{"query":"mutation { updateIssueComment(input: {id: \\"x\\", body: \\"y\\"}) { clientMutationId } }"}' > q.json
    run gh api graphql --input q.json
    [ "$status" -eq 2 ]
    [ ! -e "$T/argv" ]

    run bash -c 'echo "mutation { addComment(input: {subjectId: \"x\", body: \"y\"}) { clientMutationId } }" | gh api graphql -F query=@-'
    [ "$status" -eq 2 ]
    [ ! -e "$T/argv" ]
}

@test "a GraphQL query read from a pipe or --input - reaches the real gh intact" {
    run gh api graphql -F query=@<(echo 'query { viewer { login } }') -F n=1
    [ "$status" -eq 0 ]
    argv_is api graphql -f 'query=query { viewer { login } }' -F n=1

    printf '{"query":"query { viewer { login } }"}' | gh api graphql --input -
    argv_is api graphql --input -
    stdin_is '{"query":"query { viewer { login } }"}'
}

@test "any other call passes through: same argv, the real gh's output and exit code" {
    STUB_RC=3 run gh pr list --json number
    [ "$status" -eq 3 ]
    [ "$output" = real-gh-out ]
    argv_is pr list --json number
}

@test "an unreadable --body-file goes to the real gh unchanged" {
    run gh issue comment 5 --body-file nofile
    argv_is issue comment 5 --body-file nofile
}
