#!/usr/bin/env bats
# Unit tests for ops/cron/lib/ci-skip.sh — the CI-skip tokens GitHub honours
# must be recognised exactly, stripped cleanly, and nothing else touched.
#
# Run: bunx bats ops/cron/tests/ci-skip.bats

setup() {
    unset _ARCHON_CI_SKIP_SH
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$SCRIPT_DIR/lib/ci-skip.sh"
}

# ── has_ci_skip_token ────────────────────────────────────────────────────────

@test "has_ci_skip_token recognises all six documented forms" {
    for tok in '[skip ci]' '[ci skip]' '[no ci]' '[skip actions]' '[actions skip]' '***NO_CI***'; do
        has_ci_skip_token "chore: thing $tok"
    done
}

@test "has_ci_skip_token is case-insensitive" {
    has_ci_skip_token 'fix: x [SKIP CI]'
    has_ci_skip_token 'fix: x [Ci Skip]'
    has_ci_skip_token 'fix: x ***no_ci***'
}

@test "has_ci_skip_token rejects forms GitHub does not honour" {
    ! has_ci_skip_token 'chore: thing [skip-ci]'
    ! has_ci_skip_token 'chore: thing skip ci'
    ! has_ci_skip_token 'chore: wire up ci'
    ! has_ci_skip_token 'chore: thing [skipci]'
}

# ── strip_ci_skip_tokens ─────────────────────────────────────────────────────

@test "strip_ci_skip_tokens removes every form in upper, lower and mixed case" {
    for tok in '[skip ci]' '[CI SKIP]' '[No Ci]' '[skip actions]' '[ACTIONS skip]' '***no_ci***'; do
        [ "$(strip_ci_skip_tokens "chore: thing $tok")" = "chore: thing" ]
    done
}

@test "strip_ci_skip_tokens leaves token-free text byte-identical" {
    local text
    text="$(printf 'title\n\n    indented   \n\n```\n  code  \n```\n')"
    [ "$(strip_ci_skip_tokens "$text")" = "$text" ]
}

@test "strip_ci_skip_tokens preserves newlines, indentation and fenced code" {
    local body expected
    body="$(printf 'closes #12 [skip ci]\n\n    indented note\n\n```sh\n  echo hi\n```\n')"
    expected="$(printf 'closes #12\n\n    indented note\n\n```sh\n  echo hi\n```\n')"
    [ "$(strip_ci_skip_tokens "$body")" = "$expected" ]
}

@test "strip_ci_skip_tokens removes several tokens from one body" {
    local body
    body="$(printf 'one [skip ci]\ntwo ***NO_CI***\nthree [no ci]\n')"
    [ "$(strip_ci_skip_tokens "$body")" = "$(printf 'one\ntwo\nthree\n')" ]
}

# ── ci_skip_clean_line ───────────────────────────────────────────────────────

@test "ci_skip_clean_line cleans a token at the end of a subject" {
    [ "$(ci_skip_clean_line 'chore: update snapshots [skip ci]')" = "chore: update snapshots" ]
}

@test "ci_skip_clean_line cleans a token in the middle of a subject" {
    [ "$(ci_skip_clean_line 'chore: [ci skip] update snapshots')" = "chore: update snapshots" ]
}

@test "ci_skip_clean_line collapses the whitespace a stripped token leaves behind" {
    [ "$(ci_skip_clean_line '  chore:   bump   [no ci]   deps  ')" = "chore: bump deps" ]
}

@test "ci_skip_clean_line returns empty for a subject that is only a token" {
    [ -z "$(ci_skip_clean_line '[skip ci]')" ]
}
