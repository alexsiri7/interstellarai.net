#!/usr/bin/env bats
# Tests for ops/cron/daily-release-cron.sh: it releases every project in
# archon-projects.txt, except one opted out, one whose own release workflow
# runs on push to main, one whose workflows cannot be read, and one with
# nothing new since its last release-* tag.
#
# Runs the real script under a throwaway HOME, against local clones whose
# origin is a local bare repo. Stubs live in $HOME/.local/bin, which the script
# puts first on PATH. The gh stub answers the workflow tree and contents from
# $TEST_TMP/workflows/<project>/ (paths already filtered: the filter itself is
# tested in releases.bats) and records every call.
#
# Run: npx bats@1.13.0 ops/cron/tests/daily-release-cron.bats

SCRIPT="$BATS_TEST_DIRNAME/../daily-release-cron.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"
    export BASE_DIR="$TEST_TMP/base"
    export ARCHON_PROJECTS_FILE="$TEST_TMP/projects.txt"
    export GH_CALLS="$TEST_TMP/gh-calls" WORKFLOWS="$TEST_TMP/workflows"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
    unset DAILY_RELEASE_OPT_OUT _ARCHON_RELEASES_SH _ARCHON_DEADLINES_SH
    mkdir -p "$HOME/.local/bin" "$BASE_DIR" "$WORKFLOWS"
    : > "$GH_CALLS"
    TODAY="$(date +%Y-%m-%d)"

    cat > "$HOME/.local/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
url=""; for a in "$@"; do case "$a" in repos/*) url="$a" ;; esac; done
p="${url#repos/alexsiri7/}"; p="${p%%/*}"
case "$1 $url" in
  "api "*/git/trees/main*) cat "$WORKFLOWS/$p/tree" 2>/dev/null ;;
  "api "*/contents/*) f="${url#*/contents/}"; base64 "$WORKFLOWS/$p/files/${f%%\?*}" 2>/dev/null ;;
  "release "*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
    printf '#!/usr/bin/env bash\nexit 1\n' > "$HOME/.local/bin/gemini"
    chmod +x "$HOME/.local/bin/"*
}

teardown() {
    rm -rf "$TEST_TMP"
}

# project <slug> — a bare origin with one commit on main, a clone of it in
# BASE_DIR, no release workflows, and the slug listed in archon-projects.txt.
project() {
    local origin="$TEST_TMP/origins/$1.git" work="$TEST_TMP/work/$1"
    git init -q --bare -b main "$origin"
    git init -q -b main "$work"
    git -C "$work" commit -q --allow-empty -m "first"
    git -C "$work" push -q "$origin" main
    git clone -q "$origin" "$BASE_DIR/$1"
    mkdir -p "$WORKFLOWS/$1"; : > "$WORKFLOWS/$1/tree"
    echo "$1  # comment" >> "$ARCHON_PROJECTS_FILE"
}

# workflow <slug> <path> — the workflow body on stdin.
workflow() {
    mkdir -p "$WORKFLOWS/$1/files/$(dirname "$2")"
    cat > "$WORKFLOWS/$1/files/$2"
    echo "$2" >> "$WORKFLOWS/$1/tree"
}

released() { grep -q "^release create release-$TODAY --repo alexsiri7/$1 " "$GH_CALLS"; }

@test "every project in archon-projects.txt is released, including ones the old list lacked" {
    project reli; project zoomies; project catscape-watchface
    workflow catscape-watchface .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
  push:
    tags: ['v*']
YML
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    released reli
    released zoomies
    released catscape-watchface
}

@test "a project in DAILY_RELEASE_OPT_OUT is not released" {
    project reli; project zoomies
    DAILY_RELEASE_OPT_OUT="zoomies" run "$SCRIPT"
    [ "$status" -eq 0 ]
    released reli
    ! released zoomies || false
    [[ "$output" == *"zoomies: opted out (DAILY_RELEASE_OPT_OUT), skipping"* ]]
}

@test "a project whose release workflow runs on push to main is not released" {
    project reli; project un-reminder
    workflow un-reminder .github/workflows/release.yml <<'YML'
on:
  push:
    branches: [main]
    tags: ['v*']
YML
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    released reli
    ! released un-reminder || false
    [[ "$output" == *"un-reminder: .github/workflows/release.yml already releases on push to main, skipping"* ]]
}

@test "a project whose workflows cannot be read is not released" {
    project reli; project zoomies
    rm "$WORKFLOWS/zoomies/tree"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    released reli
    ! released zoomies || false
    [[ "$output" == *"zoomies: could not read release workflows, skipping"* ]]
}

@test "a project with no commits since its last release-* tag is not released" {
    project reli; project zoomies
    git -C "$TEST_TMP/work/zoomies" tag release-2026-01-01
    git -C "$TEST_TMP/work/zoomies" push -q "$TEST_TMP/origins/zoomies.git" release-2026-01-01
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    released reli
    ! released zoomies || false
    [[ "$output" == *"zoomies: no new commits since release-2026-01-01, skipping"* ]]
    ! grep -q "alexsiri7/zoomies/git/trees" "$GH_CALLS" || false
}

@test "the last release is the newest release-* tag by name, not the last one created" {
    project zoomies
    local work="$TEST_TMP/work/zoomies" origin="$TEST_TMP/origins/zoomies.git"
    git -C "$work" commit -q --allow-empty -m "second"
    GIT_COMMITTER_DATE="2026-02-01T08:00:00Z" git -C "$work" tag -a -m r release-2026-02-01
    GIT_COMMITTER_DATE="2026-03-01T08:00:00Z" git -C "$work" tag -a -m r release-2026-01-01 HEAD~1
    git -C "$work" push -q "$origin" main release-2026-02-01 release-2026-01-01
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    ! released zoomies || false
    [[ "$output" == *"zoomies: no new commits since release-2026-02-01, skipping"* ]]
}
