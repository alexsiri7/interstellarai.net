#!/usr/bin/env bats
# Tests for ops/cron/daily-release-cron.sh: it releases every project in
# archon-projects.txt, except one opted out, one whose workflows cannot be
# read, and one with nothing new since its last release-* tag. A project
# whose own release workflow runs on push to main is still released through
# the dated fallback, since the push trigger alone produces neither a
# release-* tag nor a GitHub release (#248 R1).
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
    export GH_CALLS="$TEST_TMP/gh-calls" WORKFLOWS="$TEST_TMP/workflows" DISPATCH_RUNS="$TEST_TMP/dispatch-runs"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
    unset DAILY_RELEASE_OPT_OUT _ARCHON_RELEASES_SH _ARCHON_DEADLINES_SH
    mkdir -p "$HOME/.local/bin" "$BASE_DIR" "$WORKFLOWS"
    : > "$GH_CALLS"
    TODAY="$(date +%Y-%m-%d)"

    cat > "$HOME/.local/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
url=""; filter=""; prev=""
for a in "$@"; do
  case "$a" in repos/*) url="$a" ;; esac
  [ "$prev" = --jq ] && filter="$a"
  prev="$a"
done
p="${url#repos/alexsiri7/}"; p="${p%%/*}"
case "$1 $url" in
  "api "*/git/trees/main*) cat "$WORKFLOWS/$p/tree" 2>/dev/null ;;
  "api "*/contents/*) f="${url#*/contents/}"; base64 "$WORKFLOWS/$p/files/${f%%\?*}" 2>/dev/null ;;
  # Raw /actions/workflows/.../runs JSON; the real --jq filter runs against
  # it here, not a pre-filtered fixture (#248 / seam R5). RUNS_FAIL=<slug>
  # simulates a failed read for that one project (#248 / seam R2).
  "api "*/actions/workflows/*/runs*)
    [ -n "${RUNS_FAIL:-}" ] && [ "$p" = "$RUNS_FAIL" ] && exit 1
    f="$DISPATCH_RUNS/$p"
    [ -f "$f" ] || f=<(echo '{"workflow_runs": []}')
    jq -r "$filter" "$f" 2>/dev/null
    true
    ;;
  "workflow "*) exit 0 ;;
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
# tagged <slug> <glob> — origin carries a tag matching <glob> (e.g. 'v*').
tagged() { git -C "$TEST_TMP/origins/$1.git" tag -l "$2" | grep -q .; }
# dispatch_ran <slug> <iso> — the slug's release workflow last succeeded
# then, as raw /actions/workflows/.../runs JSON (#248 / seam R5).
dispatch_ran() {
  mkdir -p "$DISPATCH_RUNS"
  jq -n --arg d "$2" \
    '{workflow_runs: [{status: "completed", conclusion: "success", created_at: $d}]}' \
    > "$DISPATCH_RUNS/$1"
}
# reject_pushes <slug> — a pre-receive hook on the slug's bare origin that
# rejects every push (fetch and clone still work).
reject_pushes() {
  local hook="$TEST_TMP/origins/$1.git/hooks/pre-receive"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$hook"
  chmod +x "$hook"
}

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
    # catscape-watchface's own release.yml wants a tag matching 'v*', not
    # today's generic release-YYYY-MM-DD (#248).
    ! released catscape-watchface || false
    tagged catscape-watchface 'v*'
}

@test "a project in DAILY_RELEASE_OPT_OUT is not released" {
    project reli; project zoomies
    DAILY_RELEASE_OPT_OUT="zoomies" run "$SCRIPT"
    [ "$status" -eq 0 ]
    released reli
    ! released zoomies || false
    [[ "$output" == *"zoomies: opted out (DAILY_RELEASE_OPT_OUT), skipping"* ]]
}

@test "a push trigger combining branches: [main] with a tags pattern is given the dated fallback, not tagged (#248 R1)" {
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
    # The block already self-releases on every push to main, at whatever
    # track its own workflow picks — a tags pattern in the same block must
    # not be read as "push a tag and trigger a separate, unattended
    # production rollout" (#248 R1).
    [[ "$output" == *"un-reminder: .github/workflows/release.yml runs on push to main, but that alone produces no release-* tag or dated release — falling back"* ]]
    released un-reminder
    ! tagged un-reminder 'v*' || false
}

@test "a bare push-to-main release workflow with no tags pattern still gets the dated fallback release" {
    project reli; project un-reminder
    workflow un-reminder .github/workflows/release.yml <<'YML'
on:
  push:
    branches: [main]
YML
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    released reli
    # A bare push to main only runs un-reminder's own workflow, never a
    # tag-triggered release job, so the cron's dated fallback is still the
    # only thing that produces a release-* tag or GitHub release here.
    released un-reminder
    [[ "$output" == *"un-reminder: .github/workflows/release.yml runs on push to main, but that alone produces no release-* tag or dated release — falling back"* ]]
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
}

@test "a project with a release.yml that has neither a tag nor a dispatch trigger still gets the plain fallback release" {
    project reli
    workflow reli .github/workflows/release.yml <<'YML'
on:
  pull_request:
YML
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    released reli
}

@test "a dispatch-only release workflow is dispatched, not released as a GitHub release" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    ! released punland || false
    grep -qx "workflow run release.yml --repo alexsiri7/punland --ref main" "$GH_CALLS"
}

@test "a tag-pattern release workflow with nothing new since its last matching tag is not tagged again" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    git -C "$TEST_TMP/work/punland" tag v2026.1.1
    git -C "$TEST_TMP/work/punland" push -q "$TEST_TMP/origins/punland.git" v2026.1.1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"punland: no new commits since v2026.1.1 (v*), skipping"* ]]
    [ "$(git -C "$TEST_TMP/origins/punland.git" tag -l 'v*' | wc -l)" -eq 1 ]
}

@test "a git rev-list failure in tag mode logs rev-list failed, not no new commits, and tags nothing (#248 R4)" {
    project reli
    workflow reli .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    local real_git
    real_git="$(command -v git)"
    cat > "$HOME/.local/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = rev-list ]; then
  echo "fatal: bad revision" >&2
  exit 128
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$HOME/.local/bin/git"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"reli: git rev-list failed: fatal: bad revision, skipping"* ]]
    ! tagged reli 'v*' || false
}

@test "a git rev-list failure in dispatch mode logs rev-list failed, not no new commits, and dispatches nothing (#248 R4)" {
    project reli
    workflow reli .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    local real_git
    real_git="$(command -v git)"
    cat > "$HOME/.local/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = rev-list ]; then
  echo "fatal: bad revision" >&2
  exit 128
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$HOME/.local/bin/git"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"reli: git rev-list failed: fatal: bad revision, skipping"* ]]
    ! grep -qx "workflow run release.yml --repo alexsiri7/reli --ref main" "$GH_CALLS" || false
}

@test "a satisfiable bracket-class tag pattern gets its own matching tag, not the dated fallback (#248 / seam R2)" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v[0-9]*']
YML
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"punland: tagging v$(date -u +%Y.%-m.%-d) to match v[0-9]*"* ]]
    tagged punland 'v[0-9]*'
    ! released punland || false
}

@test "a tag pattern no concrete candidate can satisfy falls back to the dated release instead of never releasing (#248 / seam R3)" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v?.0']
YML
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"punland: unsupported tag pattern v?.0, falling back to release-$TODAY"* ]]
    released punland
}

@test "a failed tag push rolls back the local tag, and a later successful push creates it (#248 / seam R6)" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    reject_pushes punland
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"punland: tag push failed"* ]]
    [ -z "$(git -C "$BASE_DIR/punland" tag -l 'v*')" ]
    ! tagged punland 'v*' || false

    rm "$TEST_TMP/origins/punland.git/hooks/pre-receive"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    tagged punland 'v*'
    [ "$(git -C "$TEST_TMP/origins/punland.git" tag -l 'v*' | wc -l)" -eq 1 ]
}

@test "a dispatch-only release workflow with nothing new since its last successful run is not dispatched again" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    dispatch_ran punland "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"punland: no new commits since "*"(.github/workflows/release.yml), skipping"* ]]
    ! grep -q "^workflow run" "$GH_CALLS" || false
}

@test "a dispatch-only release workflow is not dispatched when its runs read fails (#248 / seam R2)" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    RUNS_FAIL=punland run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"punland: could not read .github/workflows/release.yml's runs, skipping"* ]]
    ! grep -q "^workflow run" "$GH_CALLS" || false
}

@test "a tag-pattern release workflow with a real prior tag tags again once new commits land (#248 R2)" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
YML
    git -C "$TEST_TMP/work/punland" tag v2026.1.1
    git -C "$TEST_TMP/work/punland" push -q "$TEST_TMP/origins/punland.git" v2026.1.1
    git -C "$TEST_TMP/work/punland" commit -q --allow-empty -m "second"
    git -C "$TEST_TMP/work/punland" push -q "$TEST_TMP/origins/punland.git" main
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    new_tag="v$(date -u +%Y.%-m.%-d)"
    [[ "$output" == *"punland: tagging $new_tag to match v* (1 commits since v2026.1.1)"* ]]
    tagged punland "$new_tag"
    # v2026.1.1 is untouched, and today's tag is a second, distinct tag — not
    # a re-tag or the dated fallback.
    [ "$(git -C "$TEST_TMP/origins/punland.git" tag -l 'v*' | wc -l)" -eq 2 ]
    tagged punland v2026.1.1
    ! released punland || false
}

@test "a dispatch-only release workflow dispatches again once new commits land after a real past successful run (#248 R3)" {
    project punland
    workflow punland .github/workflows/release.yml <<'YML'
on:
  workflow_dispatch:
YML
    dispatch_ran punland "$(date -u -d '-2 hours' '+%Y-%m-%dT%H:%M:%SZ')"
    git -C "$TEST_TMP/work/punland" commit -q --allow-empty -m "second"
    git -C "$TEST_TMP/work/punland" push -q "$TEST_TMP/origins/punland.git" main
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"punland: dispatching .github/workflows/release.yml ("*" commits since "* ]]
    grep -qx "workflow run release.yml --repo alexsiri7/punland --ref main" "$GH_CALLS"
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
