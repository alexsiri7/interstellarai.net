#!/usr/bin/env bats
# Tests for pr-maintenance-cron.sh's correction phase and owner notices
# (interstellarai.net#173): a CLEAN archon PR whose review at its head says
# action: correct gets one archon-deliver run adopting its branch's run per head
# SHA, a correction that cannot converge is escalated to the owner once, and an
# ops/ PR whose review says ready is put on the owner's list once.
#
# Same harness as pr-maintenance-failed-run.bats: the real script end to end
# under a temp HOME, with stubs in $HOME/.local/bin. It runs the live scenario:
# ARCHON_RUN_AS=archon on interstellarai.net, where a PR touching ops/ is never
# merged, so the archon shim execs the sudo stub, which drops `-n -u <user>`
# and runs the archon stub as the wrapper. The gh stub answers `pr view
# --json comments` with $GH_PR_COMMENTS; the archon stub answers `workflow
# runs` with $ARCHON_OPEN_RUNS (--open), $ARCHON_COMPLETED_RUNS (--status
# completed) and $ARCHON_LIVE_RUNS (--status running). Lachesis is
# LACHESIS_CALL_CMD, a stub exiting $LACHESIS_RC.
#
# Run: bunx bats ops/cron/tests/pr-maintenance-correction.bats

bats_require_minimum_version 1.5.0

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
SHA3=3333333333333333333333333333333333333333

setup() {
    export T="$BATS_TEST_TMPDIR"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

    export HOME="$T/home"
    STUB_BIN="$HOME/.local/bin"
    mkdir -p "$STUB_BIN" "$T/base/interstellarai.net/.git"
    export BASE_DIR="$T/base"
    export ARCHON_RUNS_SNAPSHOT="$T/snapshot"
    export ARCHON_PROJECTS_FILE="$T/projects.txt"
    echo "interstellarai.net" > "$ARCHON_PROJECTS_FILE"
    export ARCHON_CRON_FORCE_TICK=1
    export ARCHON_RUN_AS=archon ARCHON_AS_WRAPPER="$STUB_BIN/archon"
    export QUOTA_LEDGER="$T/ledger.tsv"
    unset NTFY_TOPIC PR_CORRECTION_MAX_RUNS

    export STUB_GH_ARGV="$T/gh-argv" STUB_ARCHON_ARGV="$T/archon-argv"
    export LACHESIS_ARGV="$T/lachesis-argv" STUB_CURL_ARGV="$T/curl-argv"
    : > "$STUB_GH_ARGV"; : > "$STUB_ARCHON_ARGV"; : > "$LACHESIS_ARGV"; : > "$STUB_CURL_ARGV"
    export GH_PR_LIST="[]" GH_PR_COMMENTS='{"comments": []}' GH_PR_DIFF="ops/cron/x.sh"
    export ARCHON_OPEN_RUNS='{"runs": [], "total": 0}' ARCHON_LIVE_RUNS='{"runs": [], "total": 0}'
    export ARCHON_COMPLETED_RUNS="$(completed_run ship-run-7 archon/task-archon-ship-7)"

    cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGV"
if [ "$1 $2" = "pr list" ]; then
  jqf="" prev=""
  for a in "$@"; do [ "$prev" = "--jq" ] && jqf="$a"; prev="$a"; done
  if [ -n "$jqf" ]; then printf '%s' "$GH_PR_LIST" | jq -r "$jqf"; else printf '%s' "$GH_PR_LIST"; fi
fi
if [ "$1 $2" = "pr view" ]; then
  case " $* " in
    *" comments "*) printf '%s' "$GH_PR_COMMENTS" ;;
    *) printf '{"title":"t","body":"b"}' ;;
  esac
fi
[ "$1 $2" = "pr diff" ] && printf '%s\n' "$GH_PR_DIFF"
[ "$1 $2" = "issue view" ] && printf '{"labels":[]}'
exit 0
STUB
    cat > "$STUB_BIN/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARCHON_ARGV"
if [ "$1 $2" = "workflow runs" ]; then
  case " $* " in
    *" --open "*) printf '%s' "$ARCHON_OPEN_RUNS" ;;
    *" --status completed "*) printf '%s' "$ARCHON_COMPLETED_RUNS" ;;
    *" --status running "*) printf '%s' "$ARCHON_LIVE_RUNS" ;;
    *) printf '{"runs": [], "total": 0}' ;;
  esac
fi
exit 0
STUB
    cat > "$STUB_BIN/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -n ] && shift
[ "$1" = -u ] && shift 2
exec "$@"
STUB
    cat > "$STUB_BIN/lachesis" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${2:-}" >> "$LACHESIS_ARGV"
exit "${LACHESIS_RC:-0}"
STUB
    cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CURL_ARGV"
exit 0
STUB
    chmod +x "$STUB_BIN"/*
    export LACHESIS_CALL_CMD="$STUB_BIN/lachesis"
    export PATH="$STUB_BIN:$PATH"
}

pr() { # pr <number> <headRefOid> [headRefName] — a CLEAN, non-draft owner PR
    printf '{"number": %s, "isDraft": false, "mergeStateStatus": "CLEAN", "headRefName": "%s", "headRefOid": "%s", "body": "Fixes #74", "labels": [], "author": {"login": "alexsiri7"}, "isCrossRepository": false}' \
        "$1" "${3:-archon/task-archon-ship-7}" "$2"
}

report() { # report <ready> <action> <sha> [author] — comments JSON with one canonical review
    local body
    body=$(printf '<!-- archon-review-report -->\n# Review Report\n\n## 1. Verdict\n\n**ready: %s** — **action: %s**\n\nFindings.\n\n## 3. Reviewed head SHA\n\n`%s`\n' "$1" "$2" "$3")
    jq -nc --arg b "$body" --arg a "${4:-alexsiri7-factory}" \
        '{comments: [{author: {login: "alexsiri7"}, body: "looks good"}, {author: {login: $a}, body: $b}]}'
}

completed_run() { # completed_run <id> <branch>
    printf '{"runs": [{"id": "%s", "workflow_name": "archon-ship", "status": "completed", "completed_at": "2026-10-09T10:00:00Z", "working_path": "/w/worktrees/%s"}], "total": 1}' "$1" "$2"
}

tick() { run "$CRON_DIR/pr-maintenance-cron.sh"; [ "$status" -eq 0 ]; }

launches() { grep -c '^workflow run archon-deliver' "$STUB_ARCHON_ARGV" || true; }

marker() { cat "$HOME/.archon/state/pr-maintenance/interstellarai.net-$1.correction"; }

asked() { grep -c '^ask_question' "$LACHESIS_ARGV" || true; }

@test "a CLEAN ops PR whose review at its head says correct gets one archon-deliver run per head" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    tick
    [[ "$output" == *"PR #7 is CLEAN but not auto-merged: touches ops/cron/x.sh"* ]]
    [[ "$output" == *"PR #7 needs correction (review at 1111111 says action: correct) — launching archon-deliver adopting run ship-run-7"* ]]
    grep -q "^workflow run archon-deliver --cwd $T/base/interstellarai.net --adopt ship-run-7 Correct PR #7: its latest review report .*reviewed at $SHA1" "$STUB_ARCHON_ARGV"
    [ "$(marker 7)" = "$SHA1 1" ]
    tick; tick
    [ "$(launches)" -eq 1 ]
    ! grep -q '^pr merge' "$STUB_GH_ARGV"
}

@test "a new head still reviewed correct re-arms; past the cap the owner is told once" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    tick
    export GH_PR_LIST="[$(pr 7 $SHA2)]" GH_PR_COMMENTS="$(report false correct $SHA2)"
    tick
    [ "$(launches)" -eq 2 ]
    [ "$(marker 7)" = "$SHA2 2" ]
    export GH_PR_LIST="[$(pr 7 $SHA3)]" GH_PR_COMMENTS="$(report false correct $SHA3)"
    tick
    [ "$(launches)" -eq 2 ]
    [[ "$output" == *"PR #7 still needs correction, not correcting it again: 2 correction runs"* ]]
    [ "$(asked)" -eq 1 ]
    grep -q 'PR #7 on interstellarai.net is CLEAN .*stopped correcting it' "$LACHESIS_ARGV"
    tick
    [ "$(asked)" -eq 1 ]
}

@test "a correction that pushed nothing escalates once and does not relaunch" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    mkdir -p "$HOME/.archon/state/pr-maintenance"
    echo "$SHA1 1" > "$HOME/.archon/state/pr-maintenance/interstellarai.net-7.correction"
    tick
    [ "$(launches)" -eq 0 ]
    [[ "$output" == *"the correction run at 1111111 ended without a new commit"* ]]
    tick
    [ "$(asked)" -eq 1 ]
}

@test "a failed correction run escalates; a failed original run is left to the owner as before" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    export ARCHON_OPEN_RUNS='{"runs": [{"id": "deliver-run-9", "working_path": "/w/worktrees/archon/task-archon-ship-7"}], "total": 1}'
    tick
    [ "$(launches)" -eq 0 ]
    [ "$(asked)" -eq 0 ]
    [[ "$output" == *"PR #7 (archon/task-archon-ship-7) was left by failed archon run deliver-run-9"* ]]
    echo "$SHA1 1" > "$HOME/.archon/state/pr-maintenance/interstellarai.net-7.correction"
    tick
    [ "$(launches)" -eq 0 ]
    [[ "$output" == *"not correcting it again: correction run deliver-run-9 failed"* ]]
    [ "$(asked)" -eq 1 ]
}

@test "an empty correction marker counts as no launch yet" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    mkdir -p "$HOME/.archon/state/pr-maintenance"
    : > "$HOME/.archon/state/pr-maintenance/interstellarai.net-7.correction"
    tick
    [ "$(launches)" -eq 1 ]
    [ "$(marker 7)" = "$SHA1 1" ]
}

@test "a review of an older head waits for the re-review" {
    export GH_PR_LIST="[$(pr 7 $SHA2)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    tick
    [ "$(launches)" -eq 0 ]
    [[ "$output" == *"PR #7's latest review is for 1111111, head is 2222222 — waiting for a re-review"* ]]
}

@test "a report by an untrusted author is not a verdict" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1 stranger)"
    tick
    [ "$(launches)" -eq 0 ]
    [[ "$output" == *"no CLEAN PRs need correction"* ]]
}

@test "the newest trusted report wins over an older one" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]"
    export GH_PR_COMMENTS="$(jq -c --argjson new "$(report true none $SHA1)" '.comments += $new.comments' <<<"$(report false correct $SHA1)")"
    tick
    [ "$(launches)" -eq 0 ]
    export GH_PR_COMMENTS="$(jq -c --argjson new "$(report false correct $SHA1)" '.comments += $new.comments' <<<"$(report true none $SHA1)")"
    tick
    [ "$(launches)" -eq 1 ]
}

@test "an unreadable newest trusted report is not a verdict, even over a readable older one" {
    local older=$(report false correct $SHA1) newer
    export GH_PR_LIST="[$(pr 7 $SHA1)]"
    for newer in \
        "$(printf '<!-- archon-review-report -->\n## 1. Verdict\n\n**ready: true** — **action: correct**\n\n## 3. Reviewed head SHA\n\n`%s`\n' $SHA1)" \
        "$(printf '<!-- archon-review-report -->\n## 1. Verdict\n\n**ready: false** — **action: correct**\n\n## 3. Reviewed head SHA\n\nunknown\n')"; do
        export GH_PR_COMMENTS="$(jq -c --arg b "$newer" '.comments += [{author: {login: "alexsiri7-factory"}, body: $b}]' <<<"$older")"
        tick
        [ "$(launches)" -eq 0 ]
        [[ "$output" == *"no CLEAN PRs need correction"* ]]
    done
}

@test "a verdict rendered as a list item rather than a heading is read" {
    local body
    body=$(printf '<!-- archon-review-report -->\n# Review Report\n\n1. **Verdict:** **ready: false**, `action: correct`. Findings remain.\n2. **Findings:** R1.\n3. **Reviewed head SHA:** `%s`\n' $SHA1)
    export GH_PR_LIST="[$(pr 7 $SHA1)]"
    export GH_PR_COMMENTS="$(jq -nc --arg b "$body" '{comments: [{author: {login: "alexsiri7-factory"}, body: $b}]}')"
    tick
    [ "$(launches)" -eq 1 ]
}

@test "a live correction run owns the PR: no second launch, no merge" {
    export GH_PR_LIST="[$(pr 7 $SHA1 archon/task-archon-deliver-9)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    export GH_PR_DIFF="README.md"
    export ARCHON_LIVE_RUNS='{"runs": [{"id": "d1", "workflow_name": "archon-deliver", "status": "running", "user_message": "Correct PR #7: its latest review", "working_path": "/w/x", "metadata": {"workflow_source": {"origin": "'"$T"'/base/interstellarai.net"}}}], "total": 1}'
    tick
    [ "$(launches)" -eq 0 ]
    ! grep -q '^pr merge' "$STUB_GH_ARGV"
    [[ "$output" == *"PR #7 (archon/task-archon-deliver-9) is owned by a live archon run — merging after it exits"* ]]
    [[ "$output" == *"PR #7 (archon/task-archon-deliver-9) is CLEAN but owned by a live archon run — leaving it to the run"* ]]
}

@test "no completed run to adopt: not corrected, no marker" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    export ARCHON_COMPLETED_RUNS="$(completed_run other archon/task-archon-ship-77)"
    tick
    [ "$(launches)" -eq 0 ]
    [[ "$output" == *"PR #7 (archon/task-archon-ship-7) needs correction but no completed archon run owns its branch to adopt — not correcting it"* ]]
    [ ! -e "$HOME/.archon/state/pr-maintenance/interstellarai.net-7.correction" ]
}

@test "quota held: no launch and no marker; the next free tick launches" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    export ARCHON_DB="$T/archon.db"
    local spec; spec=$(TZ=Europe/London date -d '+2 hours' '+%-I%P')
    sqlite3 "$ARCHON_DB" "CREATE TABLE remote_agent_workflow_events (id INTEGER PRIMARY KEY,
        workflow_run_id TEXT, event_type TEXT, data TEXT, created_at TEXT DEFAULT (datetime('now')));
      INSERT INTO remote_agent_workflow_events (workflow_run_id, event_type, data)
        VALUES ('r1', 'node_failed', '{\"error\":\"You have hit your weekly limit · resets $spec (Europe/London)\"}');"
    tick
    [[ "$output" == *"PR #7 needs correction — held, Claude rate limit in effect"* ]]
    [ "$(launches)" -eq 0 ]
    [ ! -e "$HOME/.archon/state/pr-maintenance/interstellarai.net-7.correction" ]
    export ARCHON_DB="$T/missing.db"
    tick
    [ "$(launches)" -eq 1 ]
}

@test "a human branch is never corrected" {
    export GH_PR_LIST="[$(pr 7 $SHA1 feat/human)]" GH_PR_COMMENTS="$(report false correct $SHA1)"
    tick
    [ "$(launches)" -eq 0 ]
    [[ "$output" == *"no CLEAN PRs need correction"* ]]
}

@test "a PR this tick tried to merge is not corrected" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report false correct $SHA1)" GH_PR_DIFF="README.md"
    tick
    grep -q '^pr merge 7 ' "$STUB_GH_ARGV"
    [ "$(launches)" -eq 0 ]
}

@test "an ops PR reviewed ready at its head is put to the owner once" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report true none $SHA1)"
    tick
    ! grep -q '^pr merge' "$STUB_GH_ARGV"
    [ "$(launches)" -eq 0 ]
    [ "$(asked)" -eq 1 ]
    args=$(sed -E 's/^ask_question //' "$LACHESIS_ARGV")
    [ "$(jq -c '[.repo, .kind, .asker, .blocks, has("issue")]' <<<"$args")" = '["alexsiri7/interstellarai.net","clarification","factory",[],false]' ]
    [[ "$(jq -r .question <<<"$args")" == "PR #7 on interstellarai.net is ready (its review at 1111111 says ready: true) but touches ops/ or .github/"* ]]
    [[ "$output" == *"asked the owner in Lachesis"* ]]
    tick
    [ "$(asked)" -eq 1 ]
}

@test "the approval notice falls back to one ntfy when Lachesis cannot take it" {
    export GH_PR_LIST="[$(pr 7 $SHA1)]" GH_PR_COMMENTS="$(report true none $SHA1)"
    export LACHESIS_RC=2 NTFY_TOPIC=t
    tick
    [ "$(grep -c 'ntfy.sh/t$' "$STUB_CURL_ARGV")" -eq 1 ]
    grep -q 'Title: PR ready for your merge on interstellarai.net' "$STUB_CURL_ARGV"
    [[ "$output" == *"Lachesis did not take the question; ntfy sent"* ]]
    tick
    [ "$(grep -c 'ntfy.sh/t$' "$STUB_CURL_ARGV")" -eq 1 ]
}

@test "no approval notice for a stale review or one that says correct" {
    export GH_PR_LIST="[$(pr 7 $SHA2)]" GH_PR_COMMENTS="$(report true none $SHA1)"
    tick
    export GH_PR_COMMENTS="$(report false correct $SHA2)" ARCHON_COMPLETED_RUNS='{"runs": [], "total": 0}'
    tick
    ! grep -q 'ready for your merge\|is ready (its review' "$LACHESIS_ARGV"
}
