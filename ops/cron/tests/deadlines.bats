#!/usr/bin/env bats
# Tests for lib/deadlines.sh: the clock on parked factory work (marks, the 12h
# batched ntfy, the 24h archon-assist salvage and its gates) and the per-repo
# stall detector that ops/bin/pipeline-status shows in red.
#
# The library is sourced directly with its collaborators stubbed as shell
# functions (log, notify_checked, gh, the quota / factory-identity / trust /
# run-snapshot gates); `archon` is an executable stub, since the salvage
# launches it under nohup. DEADLINE_NOW drives the clock.
#
# Run: npx bats@1.13.0 ops/cron/tests/deadlines.bats

bats_require_minimum_version 1.5.0

setup() {
    T="$BATS_TMPDIR/deadlines-$$"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    mkdir -p "$T/bin" "$T/base/proj/.git" "$T/base/other/.git" "$T/base/interstellarai.net/.git" "$T/logs"
    export DEADLINE_STATE_DIR="$T/deadlines" STALL_STATE_DIR="$T/stalled"
    export BASE_DIR="$T/base" LOG_DIR="$T/logs"
    unset _ARCHON_DEADLINES_SH DEADLINE_NOW ARCHON_RUNAS_PROTECTED_REPOS DEADLINE_SALVAGE_MAX
    : > "$T/log"; : > "$T/notified"; : > "$T/gh-calls"
    export ARCHON_ARGV="$T/archon-argv"; : > "$ARCHON_ARGV"
    cat > "$T/bin/archon" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARCHON_ARGV"
STUB
    chmod +x "$T/bin/archon"
    export PATH="$T/bin:$PATH"

    log() { echo "$*" >> "$T/log"; }
    notify_checked() { printf '%s|%s\n' "$1" "$2" >> "$T/notified"; return "${NOTIFY_RC:-0}"; }
    quota_may_launch() { return "${QUOTA_RC:-0}"; }
    gh_factory_may_launch() { return "${FACTORY_RC:-0}"; }
    trust_comments_ok() { return "${TRUST_RC:-0}"; }
    archon_runs_known() { return "${RUNS_KNOWN_RC:-0}"; }
    archon_branch_running_run() { [ -n "${RUNNING_BRANCH:-}" ] && [ "$1" = "$RUNNING_BRANCH" ] && echo live-1; }
    trust_filter_prs() { cat; }
    # gh pr list --state merged → $T/merged (a count); --state open → $T/open.json;
    # gh pr comment → recorded.
    gh() {
        echo "$*" >> "$T/gh-calls"
        case "$*" in
            *"--state merged"*) [ -n "${GH_FAIL:-}" ] && return 1; cat "$T/merged" ;;
            *"--state open"*) [ -n "${GH_FAIL:-}" ] && return 1; cat "$T/open.json" ;;
            "pr comment"*) return "${GH_COMMENT_RC:-0}" ;;
        esac
    }
    # shellcheck source=../lib/deadlines.sh
    source "$CRON_DIR/lib/deadlines.sh"
    H=3600
    T0=1800000000
}

teardown() {
    rm -rf "$T"
}

at() { export DEADLINE_NOW=$((T0 + $1)); }        # at <seconds after T0>
item() { echo "$DEADLINE_STATE_DIR/$1"; }
field() { deadline_get "$(item "$1")" "$2"; }
salvages() { grep -c 'workflow run archon-assist' "$ARCHON_ARGV" || true; }
ntfys() { grep -c '' "$T/notified" || true; }
# keep <kind> <project> <num> <sha> <branch> <reason> <until-hours>: mark it every 30 min up to then
keep() {
    local h="${7}" s=0
    while [ "$s" -le $((h * H)) ]; do at "$s"; deadline_mark "$1" "$2" "$3" "$4" "$5" "$6"; s=$((s + 1800)); done
}

# ── marks ────────────────────────────────────────────────────────────────────

@test "a mark keeps first_seen, notified and salvaged, and moves last_seen and sha" {
    at 0; deadline_mark failed-run proj 7 sha1 archon/task-a "left by failed run r1"
    at $((2 * H)); deadline_mark failed-run proj 7 sha2 archon/task-a "left by failed run r1"
    [ "$(field failed-run--proj--7 first_seen)" = "$T0" ]
    [ "$(field failed-run--proj--7 last_seen)" = $((T0 + 2 * H)) ]
    [ "$(field failed-run--proj--7 sha)" = sha2 ]
    [ "$(field failed-run--proj--7 notified)" = 0 ]
}

@test "unknown kinds and malformed numbers or projects are not marked" {
    at 0
    deadline_mark bogus proj 7 s b r
    deadline_mark failed-run proj abc s b r
    deadline_mark failed-run 'p/../x' 7 s b r
    [ -z "$(ls -A "$DEADLINE_STATE_DIR" 2>/dev/null)" ]
}

@test "a reason with newlines stays one line" {
    at 0; deadline_mark untrusted proj 7 s b $'two\nlines'
    [ "$(field untrusted--proj--7 reason)" = "two lines" ]
}

# ── 12h ntfy ─────────────────────────────────────────────────────────────────

@test "nothing is sent before 12h" {
    keep failed-run proj 7 s1 b "r" 11
    deadline_escalate
    [ "$(ntfys)" -eq 0 ]
}

@test "after 12h one batched ntfy names every parked item, at most once a day" {
    keep failed-run proj 7 s1 archon/task-a "left by failed archon run r1" 13
    keep untrusted other 9 s2 feat/x "untrusted comments or reviews" 13
    deadline_escalate
    [ "$(ntfys)" -eq 2 ]   # one title|body record, body is two lines
    grep -q '^Factory: 2 item(s) parked over 12h|' "$T/notified"
    grep -q 'proj failed-run #7, 13h: left by failed archon run r1 https://github.com/alexsiri7/proj/pull/7' "$T/notified"
    grep -q 'other untrusted #9, 13h: untrusted comments or reviews https://github.com/alexsiri7/other/pull/9' "$T/notified"
    : > "$T/notified"
    at $((20 * H)); deadline_mark failed-run proj 7 s1 archon/task-a r; deadline_mark untrusted other 9 s2 feat/x r
    deadline_escalate
    [ "$(ntfys)" -eq 0 ]
    keep failed-run proj 7 s1 archon/task-a r 37
    deadline_escalate
    grep -q '^Factory: 1 item(s) parked over 12h|' "$T/notified"
}

@test "a failed ntfy is retried next tick" {
    keep needs-author proj 3 - "" "waiting on its author: x" 12
    NOTIFY_RC=1 deadline_escalate
    [ "$(field needs-author--proj--3 notified)" = 0 ]
    : > "$T/notified"
    deadline_escalate
    grep -q 'proj needs-author #3, 12h: waiting on its author: x https://github.com/alexsiri7/proj/issues/3' "$T/notified"
    [ "$(field needs-author--proj--3 notified)" = "$DEADLINE_NOW" ]
}

@test "an item no cron saw this past hour is not chased, and is pruned after 6h" {
    keep failed-run proj 7 s1 b r 13
    at $((15 * H)); deadline_escalate
    [ "$(ntfys)" -eq 0 ]
    [ -f "$(item failed-run--proj--7)" ]
    at $((20 * H)); deadline_escalate
    [ ! -e "$(item failed-run--proj--7)" ]
    grep -q 'deadline: failed-run proj #7 not seen for 7h — resolved' "$T/log"
}

# ── 24h salvage ──────────────────────────────────────────────────────────────

@test "a failed-run PR parked 24h gets one archon-assist salvage per head sha, recorded first" {
    keep failed-run proj 7 s1 archon/task-a "left by failed archon run r1, out of review retries (2/2)" 24
    deadline_escalate
    [ "$(salvages)" -eq 1 ]
    [ "$(field failed-run--proj--7 salvaged)" = s1 ]
    grep -q 'PR #7 on alexsiri7/proj has been parked for over 24 hours: left by failed archon run r1, out of review retries (2/2)' "$ARCHON_ARGV"
    grep -q 'merge it only if your own review of it passes' "$ARCHON_ARGV"
    grep -q 'leave one clear comment' "$ARCHON_ARGV"
    grep -q 'Never write to, migrate or delete production data' "$ARCHON_ARGV"
    at $((25 * H)); deadline_mark failed-run proj 7 s1 archon/task-a r; deadline_escalate
    [ "$(salvages)" -eq 1 ]
    # The salvage pushed: the new head waits 24h from the last salvage (the
    # first may still be running), on the same clock.
    at $((26 * H)); deadline_mark failed-run proj 7 s2 archon/task-a r; deadline_escalate
    [ "$(salvages)" -eq 1 ]
    grep -q 'salvaged 2h ago, next one no sooner than 24h after it' "$T/log"
    at $((48 * H)); deadline_mark failed-run proj 7 s2 archon/task-a r; deadline_escalate
    [ "$(salvages)" -eq 2 ]
    [ "$(field failed-run--proj--7 salvaged)" = s2 ]
    [ "$(field failed-run--proj--7 first_seen)" = "$T0" ]
}

@test "a trusted needs-author issue is salvaged once, with the issue prompt" {
    keep needs-author proj 3 - "" "waiting on its author: x" 24
    deadline_escalate
    at $((30 * H)); deadline_mark needs-author proj 3 - "" r; deadline_escalate
    [ "$(salvages)" -eq 1 ]
    grep -q 'Issue #3 on alexsiri7/proj has waited over 24 hours for an answer from its author' "$ARCHON_ARGV"
}

@test "untrusted items get the ntfy only, never a salvage or a comment" {
    keep untrusted proj 7 s1 b "untrusted comments or reviews" 30
    deadline_escalate
    [ "$(salvages)" -eq 0 ]
    ! grep -q 'pr comment' "$T/gh-calls"
    grep -q 'untrusted #7' "$T/notified"
}

@test "an ops PR gets one comment per head sha, never a salvage" {
    keep ops-merge interstellarai.net 215 s1 feat/x "touches ops/cron/x.sh — needs a human merge" 24
    deadline_escalate
    deadline_escalate
    [ "$(grep -c '^pr comment 215 --repo alexsiri7/interstellarai.net' "$T/gh-calls")" -eq 1 ]
    [ "$(salvages)" -eq 0 ]
}

@test "a failed comment on an ops PR is retried" {
    keep ops-merge interstellarai.net 215 s1 feat/x r 24
    GH_COMMENT_RC=1 deadline_escalate
    [ -z "$(field ops-merge--interstellarai.net--215 salvaged)" ]
    deadline_escalate
    [ "$(field ops-merge--interstellarai.net--215 salvaged)" = s1 ]
}

@test "a failed-run PR on a protected repo is never salvaged" {
    keep failed-run interstellarai.net 9 s1 archon/task-a r 30
    deadline_escalate
    [ "$(salvages)" -eq 0 ]
    grep -q 'failed-run #9' "$T/notified"
}

@test "the quota hold, a blocked factory identity, a missing snapshot or a live run hold the salvage and spend nothing" {
    keep failed-run proj 7 s1 archon/task-a r 24
    QUOTA_RC=1 deadline_escalate
    grep -q 'due for salvage — held: Claude rate limit in effect' "$T/log"
    FACTORY_RC=1 deadline_escalate
    grep -q 'due for salvage — held: factory GitHub identity blocked' "$T/log"
    RUNS_KNOWN_RC=1 deadline_escalate
    grep -q 'due for salvage — no archon run snapshot this tick' "$T/log"
    RUNNING_BRANCH=archon/task-a deadline_escalate
    grep -q 'due for salvage — a running archon run holds archon/task-a' "$T/log"
    [ "$(salvages)" -eq 0 ]
    [ -z "$(field failed-run--proj--7 salvaged)" ]
}

@test "untrusted or unreadable comments at launch time mean ntfy only" {
    keep failed-run proj 7 s1 b r 24
    keep needs-author proj 3 - "" r 24
    TRUST_RC=1 deadline_escalate
    TRUST_RC=2 deadline_escalate
    [ "$(salvages)" -eq 0 ]
    [ "$(grep -c 'comments untrusted or unreadable, ntfy only' "$T/log")" -eq 4 ]
}

@test "at most DEADLINE_SALVAGE_MAX salvages per tick" {
    keep failed-run proj 1 s b1 r 24
    keep failed-run proj 2 s b2 r 24
    keep failed-run proj 3 s b3 r 24
    deadline_escalate
    [ "$(salvages)" -eq 2 ]
    grep -q 'already launched this tick' "$T/log"
    deadline_escalate
    [ "$(salvages)" -eq 3 ]
}

# ── stall detector ───────────────────────────────────────────────────────────

open_pr() { # open_pr <number> <createdAt> [label]
    jq -nc --argjson n "$1" --arg c "$2" --arg l "${3:-}" \
      '{number: $n, createdAt: $c, labels: (if $l == "" then [] else [{name: $l}] end)}'
}

@test "open work older than 24h and nothing merged in 24h is a stall, ntfy once, cleared on recovery" {
    at 0
    echo 0 > "$T/merged"
    echo "[$(open_pr 5 2020-01-01T00:00:00Z)]" > "$T/open.json"
    stall_check proj
    [ -f "$STALL_STATE_DIR/proj" ]
    grep -q '^Factory stalled: proj|proj: 1 open PR(s) older than 24h and none merged in 24h' "$T/notified"
    grep -q 'merged:>=' "$T/gh-calls"
    stall_check proj
    [ "$(ntfys)" -eq 1 ]
    [[ "$(stall_note proj)" == "STALLED: 1 open PR(s), 0 merged in 24h (since "* ]]
    echo 1 > "$T/merged"
    stall_check proj
    [ ! -e "$STALL_STATE_DIR/proj" ]
    [ -z "$(stall_note proj)" ]
}

@test "hold, needs-owner-review and young PRs are not open work" {
    at 0
    echo 0 > "$T/merged"
    local young; young=$(date -u -d "@$((T0 - 3600))" '+%Y-%m-%dT%H:%M:%SZ')
    echo "[$(open_pr 5 2020-01-01T00:00:00Z hold), $(open_pr 6 2020-01-01T00:00:00Z needs-owner-review), $(open_pr 7 "$young")]" > "$T/open.json"
    stall_check proj
    [ ! -e "$STALL_STATE_DIR/proj" ]
    [ "$(ntfys)" -eq 0 ]
}

@test "a stall ntfy that fails is retried, and the marker is written anyway" {
    at 0
    echo 0 > "$T/merged"
    echo "[$(open_pr 5 2020-01-01T00:00:00Z)]" > "$T/open.json"
    NOTIFY_RC=1 stall_check proj
    [ -f "$STALL_STATE_DIR/proj" ]
    [ "$(deadline_get "$STALL_STATE_DIR/proj" notified)" = 0 ]
    stall_check proj
    [ "$(deadline_get "$STALL_STATE_DIR/proj" notified)" = "$DEADLINE_NOW" ]
}

@test "a GitHub read that fails changes nothing" {
    at 0
    mkdir -p "$STALL_STATE_DIR"; printf 'since=1\nopen=2\nnotified=1\n' > "$STALL_STATE_DIR/proj"
    GH_FAIL=1 stall_check proj
    [ -f "$STALL_STATE_DIR/proj" ]
    grep -q 'stall: proj — could not count merged PRs, skipping' "$T/log"
}

@test "pipeline-status shows a stalled repo in red" {
    grep -q 'source "$SCRIPT_DIR/../cron/lib/deadlines.sh"' "$CRON_DIR/../bin/pipeline-status"
    grep -q 'stall=$(stall_note "$REPO")' "$CRON_DIR/../bin/pipeline-status"
}
