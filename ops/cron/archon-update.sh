#!/usr/bin/env bash
# archon-update.sh — weekly Archon engine upgrade, run from cron:
#   0 3 * * 0 <repo>/ops/cron/archon-update.sh >> ~/.local/state/archon-cron/logs/archon-update.log 2>&1
#
# The engine is the fork checkout at $ARCHON_LIVE_DIR (/mnt/ext-fast/archon,
# branch upstream-sync-<version>: the upstream release tag plus the factory's
# own commits — model pins, fork-safe --repo pins, bundled workflow tweaks).
# `archon` on PATH is a symlink into that checkout and archon-serve.service
# runs the server out of it, so "upgrading" is: merge the newest upstream
# release tag into the fork branch, prove the merge, then point the live
# checkout at it and restart the service. Every step of that is what the
# 0.10.1 cutover did by hand (ops/cron/ARCHON-0.10-CUTOVER.md), done weekly.
#
#   1. decide: `git describe --tags --abbrev=0` in the live checkout is the
#      base release; `git ls-remote --tags upstream` (semver-sorted, final
#      releases only, no pre-releases) is the newest one. No fetch, nothing
#      written anywhere, so a no-op week touches the live repo not at all.
#      Nothing newer → log "current vX", status ok/noop, exit 0.
#   2. guard: exit 0 (status deferred, last_ok left alone so a permanent
#      deferral goes stale in check_archon_update) while any archon run is
#      `running` (lib/archon-active-runs.sh, plus a pgrep for the CLI) or the
#      run listing cannot be read. Paused runs are durable waits the server
#      resumes on its own after a restart, so they do not block.
#   3. worktree: the one fetch into the live repo is the release tag itself
#      (`git fetch --no-tags upstream refs/tags/<tag>:refs/tags/<tag>`: one ref
#      plus its objects, no working file changes). Then
#      `git worktree add -b upstream-sync-<version> $ARCHON_WORKTREE_BASE/archon-update-<tag> <live branch>`
#      and `git merge --no-edit <tag>`. Conflicts → merge aborted, worktree and
#      branch removed, ntfy with the file list, one GitHub issue per tag on
#      $ARCHON_UPDATE_ISSUE_REPO (marker archon-update-issue-<tag>), status failed.
#   4. prove it, in the worktree: `bun install` (bun.lock committed if the
#      merge left it stale), `bun run type-check`, the test suite, bundled
#      defaults regenerated and committed (`bun run generate:bundled`, the
#      follow-up the last merge needed by hand), then `validate workflows`
#      with the WORKTREE's CLI (`bun <worktree>/packages/cli/src/cli.ts`) for
#      the archon repo itself and every project in archon-projects.txt.
#      Validation is judged against a baseline taken with the LIVE CLI on the
#      same directories, because one pre-existing error is known
#      (archon-smart-pr-review's missing .archon/mcp/ntfy.json): only a
#      workflow that errors under the new engine and not under the old one
#      fails the run. Any failure → ntfy + issue as in 3, the worktree is KEPT
#      for inspection (the message says where), status failed.
#      The test suite is `bun --filter '*' test && bun test ./scripts/`, the
#      serial form of package.json's `test` script: `bun run test` adds
#      --parallel, which on this box turns 5 s per-test timeouts into red
#      (2026-09-19: 5 fail parallel, 8766 pass / 0 fail serial, 1m40 + 2s).
#      Type-check is another minute. The whole run is well under ten minutes.
#   5. swap: push the branch to $ARCHON_UPDATE_ORIGIN_REMOTE (the fork), drop
#      the worktree (git refuses to check out a branch that is checked out
#      elsewhere; the branch and its commits stay), record the live branch and
#      sha in archon-update-previous, then in the live checkout:
#      `git checkout upstream-sync-<version>`, `bun install --frozen-lockfile`,
#      `systemctl --user restart archon-serve.service`, and up to
#      ARCHON_UPDATE_HEALTH_TIMEOUT s for GET $ARCHON_UPDATE_HEALTH_URL → 200
#      and `archon --version` naming the new tag. Health failing → roll back:
#      checkout the recorded branch, `bun install --frozen-lockfile`, restart,
#      re-check; ntfy "rolled back", status failed. The pushed branch is left
#      on the fork for a human, and the next run refuses to re-push over it.
#      Success → ntfy "Archon updated vX → vY", status ok/updated.
#      Naming: the fork's sync branches are upstream-sync-<version without v>
#      (upstream-sync-0.10 was hand-made; this script makes upstream-sync-0.11.0
#      etc.). Live is never fast-forwarded in place: the old branch stays as
#      the rollback target and the new one is what `git branch --show-current`
#      reports, so `git describe` and the branch name agree.
#
# Status: $STATE_DIR/archon-update-status in the system-maintenance-status
# shape (last_run, last_run_status=ok|failed, last_run_failed=<step>, last_ok)
# plus outcome=noop|deferred|updated|failed, current=, latest=, worktree=.
# pipeline-health-cron.sh (check_archon_update) ntfys once when it reads
# `failed` or no ok run in 8 days. One flock so two ticks cannot overlap.
#
# Overrides (tests): ARCHON_LIVE_DIR, ARCHON_WORKTREE_BASE,
# ARCHON_UPDATE_STATE_DIR, ARCHON_UPDATE_UPSTREAM_REMOTE (upstream),
# ARCHON_UPDATE_ORIGIN_REMOTE (origin), ARCHON_UPDATE_ISSUE_REPO,
# ARCHON_UPDATE_SERVICE, ARCHON_UPDATE_HEALTH_URL, ARCHON_UPDATE_HEALTH_TIMEOUT,
# ARCHON_UPDATE_VALIDATE_DIRS (space-separated; default: every existing
# $ARCHON_UPDATE_PROJECT_ROOT/<project> from archon-projects.txt),
# ARCHON_UPDATE_PROJECT_ROOT (/mnt/ext-fast), ARCHON_CRON_LOG_DIR,
# ARCHON_CRON_SECRETS.

set -uo pipefail

# cron's PATH is /usr/bin:/bin; bun, gh and the archon symlink are user-level
# installs under $HOME. /usr/local/bin (a second archon lives there) goes
# last, so a test harness that redirects HOME and prepends its stubs wins.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH:/usr/local/bin"
# Workflows hang silently from inside Claude Code without CLAUDECODE=0.
export CLAUDECODE=0 ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1

LOG_TAG="[archon-update]"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${ARCHON_UPDATE_STATE_DIR:-$HOME/.archon/pipeline-health-state}"
LOG_DIR="${ARCHON_CRON_LOG_DIR:-$HOME/.local/state/archon-cron/logs}"
STATUS_FILE="$STATE_DIR/archon-update-status"
PREVIOUS_FILE="$STATE_DIR/archon-update-previous"
LOCK_FILE="$STATE_DIR/archon-update.lock"

LIVE_DIR="${ARCHON_LIVE_DIR:-/mnt/ext-fast/archon}"
WORKTREE_BASE="${ARCHON_WORKTREE_BASE:-/mnt/ext-fast/archon-playground}"
UPSTREAM="${ARCHON_UPDATE_UPSTREAM_REMOTE:-upstream}"
ORIGIN="${ARCHON_UPDATE_ORIGIN_REMOTE:-origin}"
ISSUE_REPO="${ARCHON_UPDATE_ISSUE_REPO:-alexsiri7/Archon}"
SERVICE="${ARCHON_UPDATE_SERVICE:-archon-serve.service}"
HEALTH_URL="${ARCHON_UPDATE_HEALTH_URL:-http://127.0.0.1:3090/}"
HEALTH_TIMEOUT="${ARCHON_UPDATE_HEALTH_TIMEOUT:-60}"
PROJECT_ROOT="${ARCHON_UPDATE_PROJECT_ROOT:-/mnt/ext-fast}"
RUNBOOK="ops/cron/ARCHON-0.10-CUTOVER.md and the 'Archon auto-update' section of ops/cron/README.md (interstellarai.net)"

SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
: "${NTFY_TOPIC:?NTFY_TOPIC not set — populate $SECRETS_FILE}"

# shellcheck source=lib/archon-projects.sh
source "$SCRIPT_DIR/lib/archon-projects.sh"
# shellcheck source=lib/archon-active-runs.sh
source "$SCRIPT_DIR/lib/archon-active-runs.sh"

log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $*"; }

notify() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-robot}"
    if ! curl -s --fail -o /dev/null --max-time 20 \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
        -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null; then
        log "WARNING: ntfy undelivered: $title"
    fi
}

# --- state -----------------------------------------------------------------
CURRENT=""; LATEST=""; TAG=""; BRANCH=""; WORKTREE=""; LIVE_BRANCH=""; LIVE_SHA=""
WORKTREE_KEPT=""   # set when a failed run leaves the worktree for inspection

# write_status <ok|failed> <outcome> [failed_step]
# `last_ok` moves only on ok/noop/updated: a deferred run did nothing, so a
# week of deferrals goes stale in check_archon_update like a missing run.
write_status() {
    local run_status="$1" outcome="$2" failed_step="${3:-}"
    local now last_ok
    now=$(date +%s)
    last_ok=$(grep -s '^last_ok=' "$STATUS_FILE" | cut -d= -f2 || true)
    if [ "$run_status" = ok ] && [ "$outcome" != deferred ]; then last_ok="$now"; fi
    {
        echo "last_run=$now"
        echo "last_run_status=$run_status"
        echo "last_run_failed=$failed_step"
        echo "last_ok=${last_ok:-0}"
        echo "outcome=$outcome"
        echo "current=$CURRENT"
        echo "latest=$LATEST"
        echo "worktree=$WORKTREE_KEPT"
    } > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

# file_issue <title> <body>: one issue per tag; the marker holds its URL.
file_issue() {
    local title="$1" body="$2" marker="$STATE_DIR/archon-update-issue-$TAG" url
    if [ -f "$marker" ]; then
        log "issue for $TAG already filed: $(cat "$marker")"
        return 0
    fi
    if url=$(gh issue create --repo "$ISSUE_REPO" --title "$title" --body "$body" 2>&1); then
        printf '%s\n' "$url" > "$marker"
        log "filed $url"
    else
        log "WARNING: gh issue create failed: $url"
    fi
}

# fail_run <step> <summary> <detail>: log, status, ntfy, issue, exit 1.
fail_run() {
    local step="$1" summary="$2" detail="$3" where=""
    log "ERROR: $step — $summary"
    write_status failed failed "$step"
    [ -n "$WORKTREE_KEPT" ] && where=" Worktree kept for inspection: $WORKTREE_KEPT (branch $BRANCH)."
    notify "Archon update FAILED: $step" \
        "$summary.$where See $LOG_DIR/archon-update.log on $(hostname)." \
        high warning
    file_issue "Upstream $TAG $summary" \
        "$(printf '%s\n\n%s\n\n%s\n\nRunbook: %s\nLog: %s/archon-update.log on %s\n' \
            "archon-update.sh could not bring $LIVE_DIR from $CURRENT to $TAG: $summary." \
            "$detail" \
            "${WORKTREE_KEPT:+Worktree kept: $WORKTREE_KEPT (branch $BRANCH).}" \
            "$RUNBOOK" "$LOG_DIR" "$(hostname)")"
    log "=== archon update FAILED: $step ==="
    exit 1
}

# run_step <name> <dir> <cmd...>: run one command with its output in
# $LOG_DIR/archon-update-<tag>-<name>.log; log rc and duration, and on failure
# the last lines of that output.
STEP_LOG=""
run_step() {
    local name="$1" dir="$2"; shift 2
    local t0 rc
    STEP_LOG="$LOG_DIR/archon-update-${TAG}-${name}.log"
    log "+ [$name] $* (in $dir)"
    t0=$(date +%s)
    (cd "$dir" && "$@") > "$STEP_LOG" 2>&1; rc=$?
    log "  [$name] exit $rc after $(( $(date +%s) - t0 ))s — $STEP_LOG"
    if [ "$rc" -ne 0 ]; then tail -n 20 "$STEP_LOG" | sed 's/^/    /'; fi
    return "$rc"
}

step_tail() { tail -n 30 "$STEP_LOG" 2>/dev/null | sed 's/^/    /'; }

# Newest final release tag on the upstream remote: vX.Y.Z only, semver order.
latest_release_tag() {
    git -C "$LIVE_DIR" ls-remote --tags "$UPSTREAM" 2>/dev/null \
        | sed -n 's|.*[[:space:]]refs/tags/||p' | grep -v '\^{}$' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1
}

# validate_errors <cli...> -- <dir>: names of workflows `validate workflows`
# reports with ERRORS, one per line; the line "!no-results" when the CLI
# produced no Results: line at all (crashed, unknown flag, ...).
validate_errors() {
    local -a cli=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do cli+=("$1"); shift; done
    shift
    local dir="$1" out
    out=$(cd "$dir" && LOG_LEVEL=silent "${cli[@]}" validate workflows --cwd "$dir" 2>&1)
    printf '%s\n' "$out" | grep -q '^Results: ' || { echo '!no-results'; printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2; }
    printf '%s\n' "$out" | sed -nE 's/^  ([^ ]+) +ERRORS$/\1/p' | sort -u
}

validate_dirs() {
    if [ -n "${ARCHON_UPDATE_VALIDATE_DIRS:-}" ]; then
        printf '%s\n' "$ARCHON_UPDATE_VALIDATE_DIRS" | tr ' ' '\n'
        return
    fi
    local -a projects=()
    load_archon_projects projects
    local p
    for p in "${projects[@]}"; do
        [ -d "$PROJECT_ROOT/$p/.git" ] && echo "$PROJECT_ROOT/$p"
    done
}

health_ok() {  # <expected tag>: HTTP 200 on the server and the CLI naming the tag
    local code version
    code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$HEALTH_URL" 2>/dev/null) || code="000"
    [ "$code" = "200" ] || return 1
    version=$(archon --version 2>/dev/null | head -n 1) || version=""
    case "$version" in *"$1"*) return 0 ;; esac
    return 1
}

wait_healthy() {  # <expected tag>: poll up to HEALTH_TIMEOUT s
    local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    while :; do
        health_ok "$1" && return 0
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 2
    done
}

# swap_live <branch-or-sha> <expected tag>: checkout, install, restart, health.
swap_live() {
    local target="$1" expect="$2"
    if ! run_step "checkout-${expect}" "$LIVE_DIR" git checkout -q "$target"; then return 1; fi
    if ! run_step "install-live-${expect}" "$LIVE_DIR" bun install --frozen-lockfile; then return 1; fi
    log "+ systemctl --user restart $SERVICE"
    if ! systemctl --user restart "$SERVICE"; then log "  restart failed"; return 1; fi
    if wait_healthy "$expect"; then
        log "  healthy: $HEALTH_URL → 200, $(archon --version 2>/dev/null | head -n 1)"
        return 0
    fi
    log "  not healthy after ${HEALTH_TIMEOUT}s: HTTP $(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo 000), $(archon --version 2>/dev/null | head -n 1 || echo 'archon --version failed')"
    return 1
}

# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR" "$LOG_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "another archon-update run holds $LOCK_FILE — exiting"
    exit 0
fi
log "=== archon update start ==="

if [ ! -d "$LIVE_DIR/.git" ] || ! git -C "$LIVE_DIR" remote get-url "$UPSTREAM" >/dev/null 2>&1; then
    log "ERROR: $LIVE_DIR is not a git checkout with a '$UPSTREAM' remote"
    write_status failed failed live-checkout
    notify "Archon update FAILED: live-checkout" "$LIVE_DIR is not a git checkout with a '$UPSTREAM' remote. See $LOG_DIR/archon-update.log." high warning
    exit 1
fi

# --- 1. decide --------------------------------------------------------------
CURRENT=$(git -C "$LIVE_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null) || CURRENT=""
LIVE_SHA=$(git -C "$LIVE_DIR" rev-parse HEAD 2>/dev/null)
LIVE_BRANCH=$(git -C "$LIVE_DIR" branch --show-current 2>/dev/null)
if [ -z "$CURRENT" ]; then
    log "ERROR: no release tag in the history of $LIVE_DIR HEAD ($LIVE_SHA)"
    write_status failed failed current-tag
    notify "Archon update FAILED: current-tag" "git describe found no vX.Y.Z tag in $LIVE_DIR's history. See $LOG_DIR/archon-update.log." high warning
    exit 1
fi
LATEST=$(latest_release_tag)
if [ -z "$LATEST" ]; then
    log "ERROR: could not list release tags on $UPSTREAM ($(git -C "$LIVE_DIR" remote get-url "$UPSTREAM"))"
    write_status failed failed upstream-tags
    notify "Archon update FAILED: upstream-tags" "git ls-remote --tags $UPSTREAM returned no vX.Y.Z tags. See $LOG_DIR/archon-update.log." high warning
    exit 1
fi
log "live: $LIVE_DIR at $LIVE_SHA (${LIVE_BRANCH:-detached}), base release $CURRENT; upstream newest release $LATEST"
if [ "$(printf '%s\n%s\n' "$CURRENT" "$LATEST" | sort -V | tail -n 1)" = "$CURRENT" ]; then
    log "current $CURRENT — nothing to do"
    write_status ok noop
    log "=== archon update done (no-op) ==="
    exit 0
fi
TAG="$LATEST"
BRANCH="upstream-sync-${TAG#v}"
WORKTREE="$WORKTREE_BASE/archon-update-$TAG"
log "update available: $CURRENT → $TAG (branch $BRANCH, worktree $WORKTREE)"

# --- 2. guard ---------------------------------------------------------------
archon_runs_snapshot
if ! archon_runs_known; then
    log "cannot list archon runs this tick — deferring the update"
    write_status ok deferred
    exit 0
fi
running=$(awk -F'\t' '$2 == "running" { print $1 " (" $3 ")" }' "$ARCHON_RUNS_SNAPSHOT" | tr '\n' ' ')
paused=$(awk -F'\t' '$2 == "paused"' "$ARCHON_RUNS_SNAPSHOT" | grep -c '' || true)
if [ -n "$running" ]; then
    log "archon run(s) active: $running— deferring the update"
    write_status ok deferred
    exit 0
fi
if pgrep -f 'archon workflow run|cli\.ts workflow run' >/dev/null 2>&1; then
    log "an 'archon workflow run' process is alive — deferring the update"
    write_status ok deferred
    exit 0
fi
[ "${paused:-0}" -gt 0 ] && log "$paused paused run(s) — durable waits, the restarted server resumes them"

# --- 3. worktree + merge -------------------------------------------------------
if [ -z "$LIVE_BRANCH" ]; then
    log "ERROR: $LIVE_DIR is detached at $LIVE_SHA — refusing to branch from it"
    write_status failed failed live-detached
    notify "Archon update FAILED: live-detached" "$LIVE_DIR is detached at $LIVE_SHA; put it back on its upstream-sync-* branch. See $LOG_DIR/archon-update.log." high warning
    exit 1
fi
if [ "$LIVE_BRANCH" = "$BRANCH" ]; then
    log "ERROR: $LIVE_DIR is on $BRANCH but describes as $CURRENT — a previous swap did not finish?"
    write_status failed failed live-branch
    notify "Archon update FAILED: live-branch" "$LIVE_DIR is already on $BRANCH but its base release is $CURRENT. See $LOG_DIR/archon-update.log." high warning
    exit 1
fi
log "+ git fetch --no-tags $UPSTREAM refs/tags/$TAG:refs/tags/$TAG"
if ! git -C "$LIVE_DIR" fetch -q --no-tags "$UPSTREAM" "refs/tags/$TAG:refs/tags/$TAG" 2>&1 | sed 's/^/    /'; then
    fail_run fetch-tag "could not fetch tag $TAG from $UPSTREAM" "git fetch --no-tags $UPSTREAM refs/tags/$TAG:refs/tags/$TAG failed in $LIVE_DIR."
fi
# Leftovers of an earlier attempt at the same tag (a kept worktree, or the
# branch after a rollback): start clean, the branch is machine-made.
if [ -d "$WORKTREE" ]; then
    log "removing leftover worktree $WORKTREE from an earlier attempt"
    git -C "$LIVE_DIR" worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
fi
git -C "$LIVE_DIR" worktree prune 2>/dev/null || true
if git -C "$LIVE_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    log "deleting leftover local branch $BRANCH from an earlier attempt"
    git -C "$LIVE_DIR" branch -q -D "$BRANCH" 2>&1 | sed 's/^/    /'
fi
mkdir -p "$WORKTREE_BASE"
log "+ git worktree add -b $BRANCH $WORKTREE $LIVE_BRANCH"
if ! git -C "$LIVE_DIR" worktree add -q -b "$BRANCH" "$WORKTREE" "$LIVE_BRANCH" 2>&1 | sed 's/^/    /'; then
    fail_run worktree "could not create worktree $WORKTREE" "git worktree add -b $BRANCH $WORKTREE $LIVE_BRANCH failed."
fi

log "+ git merge --no-edit $TAG (in $WORKTREE)"
if ! git -C "$WORKTREE" merge --no-edit "$TAG" > "$LOG_DIR/archon-update-$TAG-merge.log" 2>&1; then
    conflicts=$(git -C "$WORKTREE" diff --name-only --diff-filter=U 2>/dev/null)
    tail -n 20 "$LOG_DIR/archon-update-$TAG-merge.log" | sed 's/^/    /'
    git -C "$WORKTREE" merge --abort 2>/dev/null || true
    git -C "$LIVE_DIR" worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
    git -C "$LIVE_DIR" branch -q -D "$BRANCH" 2>/dev/null || true
    log "conflicting files: $(printf '%s' "$conflicts" | tr '\n' ' ')"
    # shellcheck disable=SC2016  # the ``` fences are issue markdown, not shell
    fail_run merge "merge conflicts" \
        "$(printf 'Conflicting files:\n\n```\n%s\n```\n\nResolve by hand as the 0.10.1 merge was done:\n\n```\ncd %s && git worktree add -b %s %s %s\ncd %s && git merge %s   # resolve, then bun install && bun run generate:bundled && commit\n```' \
            "${conflicts:-(none listed — see the merge log)}" "$LIVE_DIR" "$BRANCH" "$WORKTREE" "$LIVE_BRANCH" "$WORKTREE" "$TAG")"
fi
log "merged $TAG into $BRANCH: $(git -C "$WORKTREE" rev-parse --short HEAD)"

# --- 4. prove it ---------------------------------------------------------------
WORKTREE_KEPT="$WORKTREE"
if ! run_step install "$WORKTREE" bun install; then
    fail_run bun-install "bun install failed after the merge" "$(step_tail)"
fi
if [ -n "$(git -C "$WORKTREE" status --porcelain -- bun.lock 2>/dev/null)" ]; then
    git -C "$WORKTREE" add bun.lock
    git -C "$WORKTREE" commit -q -m "chore: refresh bun.lock after merging $TAG" 2>&1 | sed 's/^/    /'
    log "bun.lock changed by bun install — committed"
fi
if ! run_step type-check "$WORKTREE" bun run type-check; then
    fail_run type-check "bun run type-check failed" "$(step_tail)"
fi
if ! run_step test "$WORKTREE" bun --filter '*' test; then
    fail_run test "package tests failed" "$(grep -E '\(fail\)' "$STEP_LOG" | sort -u | head -n 40 | sed 's/^/    /'; step_tail)"
fi
if ! run_step test-scripts "$WORKTREE" bun test ./scripts/; then
    fail_run test-scripts "scripts/ tests failed" "$(grep -E '\(fail\)' "$STEP_LOG" | sort -u | head -n 40 | sed 's/^/    /'; step_tail)"
fi
if grep -q '"generate:bundled"' "$WORKTREE/package.json" 2>/dev/null; then
    if ! run_step generate-bundled "$WORKTREE" bun run generate:bundled; then
        fail_run generate-bundled "bun run generate:bundled failed" "$(step_tail)"
    fi
    # -u: tracked files only; the test suite leaves untracked scratch behind.
    if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        git -C "$WORKTREE" add -u
        git -C "$WORKTREE" commit -q -m "post-merge: regenerate bundled defaults for $TAG" 2>&1 | sed 's/^/    /'
        log "bundled defaults changed — committed $(git -C "$WORKTREE" rev-parse --short HEAD)"
    else
        log "bundled defaults unchanged"
    fi
else
    log "no generate:bundled script in package.json — skipped"
fi

new_cli=(bun "$WORKTREE/packages/cli/src/cli.ts")
regressions=""
while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    before=$(validate_errors archon -- "$dir" 2>/dev/null)
    after=$(validate_errors "${new_cli[@]}" -- "$dir")
    newly=$(comm -13 <(printf '%s\n' "$before" | sort -u) <(printf '%s\n' "$after" | sort -u) | grep -v '^$' || true)
    log "validate $dir: errors before [$(printf '%s' "$before" | tr '\n' ' ')] after [$(printf '%s' "$after" | tr '\n' ' ')]"
    [ -n "$newly" ] && regressions="$regressions$dir: $(printf '%s' "$newly" | tr '\n' ' ')"$'\n'
done < <(validate_dirs; echo "$WORKTREE")
if [ -n "$regressions" ]; then
    printf '%s' "$regressions" | sed 's/^/    /'
    # shellcheck disable=SC2016
    fail_run validate "workflow validation regressed under $TAG" "$(printf 'Workflows that validate under the live CLI but error under %s:\n\n```\n%s```' "$TAG" "$regressions")"
fi
log "validation: no new errors under $TAG"

# --- 5. swap ------------------------------------------------------------------
if ! run_step push "$WORKTREE" git push -q -u "$ORIGIN" "$BRANCH"; then
    fail_run push "could not push $BRANCH to $ORIGIN (a diverged $BRANCH already there from an earlier attempt?)" "$(step_tail)"
fi
log "pushed $BRANCH to $ORIGIN"
WORKTREE_KEPT=""
git -C "$LIVE_DIR" worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
git -C "$LIVE_DIR" worktree prune 2>/dev/null || true
printf 'previous_sha=%s\nprevious_branch=%s\nnew_branch=%s\nrecorded=%s\n' \
    "$LIVE_SHA" "$LIVE_BRANCH" "$BRANCH" "$(date +%s)" > "$PREVIOUS_FILE"
log "swapping $LIVE_DIR: $LIVE_BRANCH ($LIVE_SHA) → $BRANCH (rollback record: $PREVIOUS_FILE)"
if swap_live "$BRANCH" "$TAG"; then
    write_status ok updated
    notify "Archon updated $CURRENT → $TAG" \
        "$LIVE_DIR is on $BRANCH ($(git -C "$LIVE_DIR" rev-parse --short HEAD)), $SERVICE healthy. Previous: $LIVE_BRANCH @ ${LIVE_SHA:0:12} ($PREVIOUS_FILE)." \
        default rocket
    log "=== archon update done ($CURRENT → $TAG) ==="
    exit 0
fi

log "ERROR: $BRANCH is not healthy — rolling back to $LIVE_BRANCH ($LIVE_SHA)"
if swap_live "$LIVE_BRANCH" "$CURRENT" || swap_live "$LIVE_SHA" "$CURRENT"; then
    write_status failed failed health-rolled-back
    notify "Archon update rolled back" \
        "$TAG failed the health check after the swap; $LIVE_DIR is back on $LIVE_BRANCH @ ${LIVE_SHA:0:12} and healthy. Branch $BRANCH stays on $ORIGIN. See $LOG_DIR/archon-update.log." \
        high rewind
    file_issue "Upstream $TAG: unhealthy after swap, rolled back" \
        "$(printf '%s\n\n%s\n\nRunbook: %s\nLog: %s/archon-update.log on %s\n' \
            "archon-update.sh swapped $LIVE_DIR to $BRANCH ($TAG) but $SERVICE did not answer 200 on $HEALTH_URL with \`archon --version\` naming $TAG within ${HEALTH_TIMEOUT}s." \
            "Rolled back to $LIVE_BRANCH @ $LIVE_SHA (healthy). The merged branch is pushed to $ORIGIN as $BRANCH for inspection; delete it there before the next automatic attempt, or finish the upgrade by hand." \
            "$RUNBOOK" "$LOG_DIR" "$(hostname)")"
    log "=== archon update FAILED: rolled back to $LIVE_BRANCH ==="
    exit 1
fi
write_status failed failed health-rollback-failed
notify "Archon DOWN: update rollback failed" \
    "$TAG was unhealthy and rolling $LIVE_DIR back to $LIVE_BRANCH @ ${LIVE_SHA:0:12} did not come back healthy either. $SERVICE needs a human now. See $LOG_DIR/archon-update.log." \
    urgent rotating_light
log "=== archon update FAILED: rollback did not restore health ==="
exit 1
