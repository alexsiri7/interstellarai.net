#!/usr/bin/env bash
# sweep-audits.sh — nightly codebase audit, the one Lachesis plans.
#
# Asks Lachesis which audit is due (next_issue's `audit` offer: repo, kind,
# capability, model, already checked against its pace and budget), runs the
# archon workflow for that kind in the repo's clone, and reports the run with
# report_audit_run: outcome (clean, findings when it filed an issue or opened
# a PR, failed), the issues it filed and its tokens. A failed run is reported
# too, so Lachesis keeps it due. Nothing offered: nothing runs.
#
# Only four kinds have a workflow (audit_workflow_for). When the offer is
# another kind, the sweep runs the oldest due workflow-backed audit from
# read_audit_history instead, in a repo with no open audit issue, so an
# unrunnable kind never stalls it. An audit Lachesis names a non-Claude model
# for is not run: every audit workflow's nodes are pinned to Claude.
#
# Before the workflow runs, a Claude account (CLAUDE_ACCOUNTS, alternating by
# day) is probed with a real request; a failing account is reported through
# lib/claude-auth.sh and the next one is tried. Every sweep that gets as far as
# an audit to run records its outcome in $STATE_DIR/last-sweep for
# ops/bin/pipeline-status.
#
# Ported from archon/scripts/poll-sweep.sh. Matches the style of the other
# ops/cron scripts (log/notify helpers, lib/secrets.sh, SCRIPT_DIR, STATE_DIR).
#
# Crontab:
#   0 2 * * * <repo>/ops/cron/sweep-audits.sh >> ~/.local/state/archon-cron/logs/sweep-audits.log 2>&1

set -uo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-as.sh
source "$SCRIPT_DIR/lib/run-as.sh"
# shellcheck source=lib/lachesis.sh
source "$SCRIPT_DIR/lib/lachesis.sh"
# shellcheck source=lib/gh-factory.sh
source "$SCRIPT_DIR/lib/gh-factory.sh"
# shellcheck source=lib/throttle.sh
source "$SCRIPT_DIR/lib/throttle.sh"
should_tick "sweep-audits" || exit 0
runas_may_launch "sweep-audits" || exit 0
# shellcheck source=lib/ship-breaker.sh
source "$SCRIPT_DIR/lib/ship-breaker.sh"
# shellcheck source=lib/quota-pause.sh
source "$SCRIPT_DIR/lib/quota-pause.sh"
# Every sweep is an archon run: none while the Claude account is rate limited.
quota_may_launch "sweep-audits" || exit 0
# shellcheck source=lib/claude-auth.sh
source "$SCRIPT_DIR/lib/claude-auth.sh"
BASE_DIR="/mnt/ext-fast"
STATE_DIR="$HOME/.archon/sweep-state"
LOG_DIR="$HOME/.archon/logs/sweep"

# NTFY_TOPIC from Doppler (lib/secrets.sh). Fail loud if unset. CLAUDE_ACCOUNTS
# there overrides lib/claude-auth.sh's default.
# shellcheck source=lib/secrets.sh
source "$SCRIPT_DIR/lib/secrets.sh"
secrets_load NTFY_TOPIC CLAUDE_ACCOUNTS
: "${NTFY_TOPIC:?NTFY_TOPIC not set — add it to Doppler factory/prd}"
LOG_PREFIX="[sweep-audits]"

export ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1

mkdir -p "$STATE_DIR" "$LOG_DIR"

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

notify() {
  local title="$1" msg="$2" priority="${3:-default}" tags="${4:-robot}"
  curl -s -o /dev/null \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
    -d "$msg" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
}

# Args: outcome (ok|failed), reason (empty when ok), account dir.
record_sweep() {
  printf 'last_run=%s\noutcome=%s\nreason=%s\nsweep=%s\nrepo=%s\naccount=%s\n' \
    "$(date +%s)" "$1" "$2" "$sweep_name" "$repo_name" "$3" > "$STATE_DIR/last-sweep"
  log "summary: outcome=$1${2:+ ($2)} sweep=$sweep_name repo=$repo_name account=${3:-none}"
}

# audit_workflow_for <kind> — the archon workflow for a Lachesis audit kind,
# empty for a kind no workflow runs.
audit_workflow_for() {
  case "$1" in
    architecture) echo archon-architect ;;
    security) echo archon-security-audit ;;
    tests) echo archon-test-audit ;;
    requirements) echo archon-requirements-audit ;;
  esac
}

audit_prompt_for() {
  case "$1" in
    architecture) echo "Analyze the codebase architecture — identify complexity hotspots, unnecessary abstractions, and opportunities for simplification" ;;
    security) echo "Perform a deep security and privacy audit of the entire codebase — check OWASP top 10, auth, data privacy, dependencies, and business logic" ;;
    tests) echo "Audit test coverage and stability — fix flaky tests, add tests for critical uncovered code paths, improve test quality" ;;
    requirements) echo "Audit requirements-to-code traceability — verify each requirement in requirements/requirements.yaml is implemented and tested, regenerate requirements/coverage.yaml, and file requirements-gap issues for uncovered or stale requirements and orphaned behavior" ;;
  esac
}

# choose_audit — the audit to run as one JSON object {repo, kind, capability,
# model, source: offered|fallback}. Returns 0 with one chosen, 3 when there is
# nothing to run, 2 when Lachesis could not be read (the reason logged).
choose_audit() {
  local offer kind history
  if ! offer=$(lachesis_call next_issue '{}'); then
    log "Lachesis next_issue could not be read" >&2
    return 2
  fi
  if ! jq -e '.audit | type == "object"' <<<"$offer" >/dev/null 2>&1; then
    log "nothing offered ($(jq -r '.reason // "no audit in the offer"' <<<"$offer" 2>/dev/null))" >&2
    return 3
  fi
  kind=$(jq -r '.audit.kind // ""' <<<"$offer")
  if [ -n "$(audit_workflow_for "$kind")" ]; then
    jq -c '.audit | {repo, kind, capability, model, source: "offered"}' <<<"$offer"
    return 0
  fi
  log "Lachesis offers a $kind audit, which no workflow here runs — falling back to the oldest due one that does" >&2
  if ! history=$(lachesis_call read_audit_history '{}'); then
    log "Lachesis read_audit_history could not be read" >&2
    return 2
  fi
  jq -ec '
    def backed: ["architecture", "security", "tests", "requirements"];
    [ .model as $m | .repos[] | select(.open_audit == null) | .repo as $repo
      | .audits[] | select(.due and (.kind as $k | backed | index($k)))
      | {repo: $repo, kind, capability, model: $m, source: "fallback",
         last: (.last_run.finished_at // "")} ]
    | sort_by(.last) | first // empty | del(.last)' <<<"$history" && return 0
  log "no due audit has a workflow here — nothing to run" >&2
  return 3
}

rc=0; audit=$(choose_audit) || rc=$?
case "$rc" in
  0) ;;
  3) exit 0 ;;
  *)
    sweep_name=- repo_name=-
    notify "Sweep failed" "Lachesis could not be read — no audit run tonight" high x
    record_sweep failed lachesis ""
    exit 1 ;;
esac
repo=$(jq -r .repo <<<"$audit")
kind=$(jq -r .kind <<<"$audit")
capability=$(jq -r '.capability // ""' <<<"$audit")
model=$(jq -r '.model // ""' <<<"$audit")
repo_name=$(basename "$repo")
workflow=$(audit_workflow_for "$kind")
sweep_name="${workflow#archon-}"
prompt=$(audit_prompt_for "$kind")
[ -n "$capability" ] && prompt+=" Focus this audit on the $capability capability (specs/$capability/)."

log "=== nightly sweep: $sweep_name on $repo_name (Lachesis: $kind${capability:+/$capability}, model $model, $(jq -r .source <<<"$audit")) ==="

if [[ "${model,,}" != *claude* ]]; then
  log "Lachesis names ${model:-no model} for audits; no workflow here runs it — not run"
  exit 0
fi

# report_audit ok|failed — report the run that just finished with
# report_audit_run. Sets outcome and issue_list ("#12 #13") for the ntfy.
# The issues are the ones the factory login opened in the repo since the
# launch; a PR among them makes the outcome findings but is not listed.
report_audit() {
  local since_iso login listing="[]" issues="[]" prs=0 tokens args
  since_iso=$(date -u -d "@$since_epoch" +%FT%TZ)
  outcome=failed issue_list=""
  if [ "$1" = ok ]; then
    login=$(gh_factory_gh api user --jq .login 2>/dev/null) || login=""
    if [ -z "$login" ]; then
      log "could not read the factory GitHub login — reporting no issues"
    elif ! listing=$(gh_factory_gh api "repos/$repo/issues?creator=$login&state=all&since=$since_iso&per_page=100" 2>/dev/null) \
        || ! listing=$(jq -c --arg s "$since_iso" '[.[] | select(.created_at >= $s)]' <<<"$listing" 2>/dev/null); then
      log "could not list the issues $login opened in $repo — reporting no issues"
      listing="[]"
    fi
    issues=$(jq -c '[.[] | select(has("pull_request") | not) | .number]' <<<"$listing")
    prs=$(jq '[.[] | select(has("pull_request"))] | length' <<<"$listing")
    outcome=clean
    [ "$issues" != "[]" ] || [ "$prs" -gt 0 ] && outcome=findings
    issue_list=$(jq -r 'map("#\(.)") | join(" ")' <<<"$issues")
  fi
  tokens=$(python3 -B "$SCRIPT_DIR/lib/archon_run_tokens.py" "$workflow" "$repo" \
    "$(date -u -d "@$since_epoch" '+%F %T')" 2>/dev/null)
  jq -e 'has("tokens_in")' <<<"$tokens" >/dev/null 2>&1 || tokens='{"tokens_in":0,"tokens_out":0}'
  args=$(jq -nc --arg repo "$repo" --arg kind "$kind" --arg outcome "$outcome" \
    --arg at "$(date -u -Iseconds)" --arg model "$model" --arg cap "$capability" \
    --argjson issues "$issues" --argjson t "$tokens" \
    '{repo: $repo, kind: $kind, outcome: $outcome, finished_at: $at, model: $model,
      issues: $issues, tokens_in: $t.tokens_in, tokens_out: $t.tokens_out}
     + (if $cap == "" then {} else {capability: $cap} end)')
  if lachesis_call report_audit_run "$args" >/dev/null; then
    log "reported: outcome=$outcome issues=${issue_list:-none} tokens=$(jq -r '"\(.tokens_in) in / \(.tokens_out) out"' <<<"$tokens")"
  else
    log "report_audit_run failed for $sweep_name on $repo_name"
    notify "Sweep not reported: $repo_name" "$sweep_name ($outcome) could not be reported to Lachesis; Lachesis keeps it due and will offer it again" default warning
  fi
}

# Skip if a sweep is already running for this repo (lock TTL: 2h)
lock_file="$STATE_DIR/${repo_name}.lock"
if [ -f "$lock_file" ]; then
  lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_file") ))
  if [ "$lock_age" -lt 7200 ]; then
    log "$repo_name: sweep still running (${lock_age}s), skipping"
    exit 0
  else
    log "$repo_name: stale lock (${lock_age}s), removing"
    rm -f "$lock_file"
  fi
fi

# Find local clone
local_path=""
for candidate in \
  "$HOME/.archon/workspaces/${repo}/source" \
  "$BASE_DIR/$repo_name" \
  "$HOME/$repo_name"; do
  if [ -d "$candidate/.git" ]; then
    local_path="$candidate"
    break
  fi
done

if [ -z "$local_path" ]; then
  log "ERROR: no local clone found for $repo"
  notify "Sweep: $repo_name" "No local clone found" high warning
  record_sweep failed no-clone ""
  exit 1
fi

# Alternate Claude accounts by day, falling back through the rest in order.
IFS=':' read -ra accounts <<< "$(runas_claude_accounts)"
account_dir=""
start=$(( 10#$(date +%j) % ${#accounts[@]} ))
for (( i = 0; i < ${#accounts[@]}; i++ )); do
  candidate="${accounts[$(( (start + i) % ${#accounts[@]} ))]}"
  if claude_auth_check "$candidate"; then
    account_dir="$candidate"
    break
  fi
done
if [ -z "$account_dir" ]; then
  log "$repo_name: $sweep_name sweep not run — no Claude account in CLAUDE_ACCOUNTS passes the probe"
  notify "Sweep failed: $repo_name" "$sweep_name not run — every Claude account failed auth" high x
  record_sweep failed auth ""
  exit 1
fi
export CLAUDE_CONFIG_DIR="$account_dir"

log "repo: $local_path"
log "workflow: $workflow"
log "account: $(basename "$account_dir")"
touch "$lock_file"

logfile="$LOG_DIR/${repo_name}-${sweep_name}-$(date +%Y%m%d).log"

cd "$local_path" || { rm -f "$lock_file"; exit 1; }
since_epoch=$(date +%s)
if CLAUDECODE=0 archon workflow run "$workflow" "$prompt" > "$logfile" 2>&1; then
  report_audit ok
  log "$repo_name: $sweep_name sweep complete"
  notify "Sweep done: $repo_name" "$sweep_name complete — $outcome${issue_list:+, issues $issue_list}" default mag
  record_sweep ok "" "$account_dir"
else
  report_audit failed
  log "$repo_name: $sweep_name sweep failed (see $logfile)"
  notify "Sweep failed: $repo_name" "$sweep_name failed — check $logfile" high x
  record_sweep failed workflow "$account_dir"
fi

rm -f "$lock_file"
log "=== nightly sweep complete ==="
