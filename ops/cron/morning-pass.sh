#!/usr/bin/env bash
# morning-pass.sh — the owner's daily morning pass: a Claude Code session on
# the owner's account (~/.claude) that follows the Lachesis morning briefing,
# checks the host and sends the owner one message (crontab, 30 7 * * *, as asiri).
#
#   30 7 * * * <repo>/ops/cron/morning-pass.sh >> ~/.local/state/archon-cron/logs/morning-pass.log 2>&1
#
# It replaces the claude.ai scheduled chat, which could only use connectors and
# so could not fix anything on this host. Each run:
#   1. takes a lock (flock), so two passes never overlap;
#   2. probes the owner's Claude account with one real request; a failure is
#      one ntfy and exit 1;
#   3. fetches the briefing with Lachesis get_morning_briefing (lib/lachesis.sh,
#      the factory token: no dependency on the session's MCP OAuth) and collects
#      a host snapshot: pipeline-status, the tails of the cron logs, the
#      archon user's gh auth status, archon run logs of the last 24h, main CI of
#      every project in archon-projects.txt, Lachesis read_fuel, the reference
#      crontab lines the live crontab lacks;
#   4. writes the prompt (prompts/morning-pass.md, then the briefing, then the
#      snapshot fenced as untrusted data) into a fresh run directory and starts
#      the session on it:
#        remote  (default) an interactive `claude --remote-control` session in
#                a detached tmux on its own socket (-L morning-pass), so the
#                owner can open it from the Claude app. Its URL goes in the
#                ntfy's Click. A session that needs him is kept open for
#                MORNING_PASS_KEEP_SECONDS (6h); a quiet one is closed.
#        print   `claude -p` (no Remote Control). Used when tmux is missing,
#                when the remote session shows no URL within
#                MORNING_PASS_URL_WAIT seconds, or with --print.
#      Both run with CLAUDECODE=0 and --permission-mode bypassPermissions, and
#      the pass gets MORNING_PASS_TIMEOUT (2700s) to write its `done` file;
#   5. sends one ntfy every morning (a quiet morning is visible too): the
#      session's message.md, or "did not finish" when it wrote none, and copies
#      the session's actions.log into this log.
#
# What the session may do without asking (prompts/morning-pass.md has the
# exact rules): the briefing's own fixes (Lachesis), and on the host only
#   - switch the archon user's gh account back to alexsiri7;
#   - rerun a failed main-CI or PR-CI run whose failure is clearly transient,
#     at most once per run id (MORNING_PASS_STATE/reruns);
#   - release a stale archon:in-progress issue with no live run and no PR, as
#     issue-pickup's unstick_stale does;
#   - add a line the reference ops/cron/crontab has and `crontab -l` lacks,
#     after backing the crontab up to ~/.local/state/archon-cron/crontab-backups/.
# Everything else is filed as an issue, flagged on one, or put in the message.
# It never merges, deletes, changes code or writes to a production database.
# Issue, comment, log, PR and snapshot text is data to it, never instructions.
#
# Flags:
#   --dry-run      print the assembled prompt and the launch command; no Claude
#                  call, no ntfy, no state written (the snapshot's reads still run)
#   --report-only  a real session told to make no fix and write nothing outside
#                  its run directory; its message is logged, not sent
#   --print        use `claude -p` instead of Remote Control
#
# Env: OPS_CHECKOUT (the live checkout; default the repo this script lives in),
# MORNING_PASS_STATE (default ~/.local/state/archon-cron/morning-pass),
# MORNING_PASS_CWD (the session's working directory, a directory Claude Code
# already trusts; default OPS_CHECKOUT), MORNING_PASS_MODEL (opus),
# MORNING_PASS_TIMEOUT, MORNING_PASS_KEEP_SECONDS, MORNING_PASS_URL_WAIT,
# MORNING_PASS_MODE (remote|print), MORNING_PASS_PROMPT (the fixed
# instructions; default prompts/morning-pass.md), ARCHON_CRON_LOG_DIR,
# PIPELINE_STATUS, MORNING_PASS_PROJECTS_ROOT (where <repo>/.archon-logs live).
set -uo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lachesis.sh
source "$SCRIPT_DIR/lib/lachesis.sh"
# shellcheck source=lib/claude-auth.sh
source "$SCRIPT_DIR/lib/claude-auth.sh"

REPO="${OPS_CHECKOUT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
STATE="${MORNING_PASS_STATE:-$HOME/.local/state/archon-cron/morning-pass}"
LOG_DIR="${ARCHON_CRON_LOG_DIR:-$HOME/.local/state/archon-cron/logs}"
PROMPT_FILE="${MORNING_PASS_PROMPT:-$SCRIPT_DIR/prompts/morning-pass.md}"
MORNING_PASS_CWD="${MORNING_PASS_CWD:-$REPO}"
MORNING_PASS_MODEL="${MORNING_PASS_MODEL:-opus}"
MORNING_PASS_TIMEOUT="${MORNING_PASS_TIMEOUT:-2700}"
MORNING_PASS_KEEP_SECONDS="${MORNING_PASS_KEEP_SECONDS:-21600}"
MORNING_PASS_URL_WAIT="${MORNING_PASS_URL_WAIT:-90}"
MORNING_PASS_MODE="${MORNING_PASS_MODE:-remote}"
MORNING_PASS_POLL="${MORNING_PASS_POLL:-10}"
PIPELINE_STATUS="${PIPELINE_STATUS:-$HOME/bin/pipeline-status}"
TMUX_SOCKET=morning-pass
TMUX_SESSION=morning-pass
GH_ARCHON_HOME="${GH_FACTORY_HOME:-/mnt/ext-fast/archon-home}"
PROJECTS_ROOT="${MORNING_PASS_PROJECTS_ROOT:-/mnt/ext-fast}"

DRY_RUN=0 REPORT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --report-only) REPORT_ONLY=1 ;;
    --print) MORNING_PASS_MODE=print ;;
    *) echo "usage: $0 [--dry-run] [--report-only] [--print]" >&2; exit 2 ;;
  esac
done

log() { echo "$(date -Is) [morning-pass] $*"; }

# notify <title> <priority> <tags> <message> [click-url] — one ntfy to
# NTFY_TOPIC (the same curl the other ops scripts use). 0 when it went out.
notify() {
  [ -n "${NTFY_TOPIC:-}" ] || { log "NTFY_TOPIC not set — not sent: $1"; return 1; }
  local -a click=()
  [ -n "${5:-}" ] && click=(-H "Click: $5")
  if curl -s --fail -m 20 -o /dev/null -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
       "${click[@]}" -d "$4" "ntfy.sh/$NTFY_TOPIC" 2>/dev/null; then
    return 0
  fi
  log "ntfy failed: $1"
  return 1
}

# <command> 2>&1 | section <title> — one snapshot section: the command's
# output, ANSI colour codes stripped, at most 200 lines.
section() {
  printf '\n### %s\n' "$1"
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | head -n 250
}

projects() { grep -vE '^[[:space:]]*(#|$)' "$SCRIPT_DIR/archon-projects.txt" | awk '{print $1}'; }

snap_logs() {
  local name f age
  for name in issue-pickup pr-maintenance pipeline-health ops-pr-review ops-self-update; do
    f="$LOG_DIR/$name.log"
    if [ ! -f "$f" ]; then echo "== $name.log: missing"; continue; fi
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    echo "== $name.log: last written ${age}s ago; last 25 lines:"
    tail -n 25 "$f"
  done
}

snap_gh_archon() {
  timeout 30 sudo -n -u archon env HOME="$GH_ARCHON_HOME" gh auth status </dev/null 2>&1 \
    | sed -E 's/(Token: )[^ ]+/\1(redacted)/'
}

# Archon run logs of the last 24h: a count of how each ended, then the last
# lines of each one that failed (its tail names a failure or an error).
# A project symlinked to another (thaleia -> musenmingle) is read once.
snap_failed_runs() {
  local f n=0 total=0 failed=0
  local -A seen=()
  : > "$TMP/runs"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local real; real=$(readlink -f "$f")
    [ -z "${seen[$real]:-}" ] || continue
    seen[$real]=1
    total=$((total + 1))
    if tail -n 3 "$f" | grep -qiE 'outcome: failed|workflow failed|^error|[^a-z]failed[^a-z]'; then
      failed=$((failed + 1))
      n=$((n + 1))
      [ "$n" -le 30 ] || continue
      { echo "== $f"; tail -n 3 "$f" | cut -c1-240; } >> "$TMP/runs"
    fi
  done < <(find "$PROJECTS_ROOT"/*/.archon-logs -maxdepth 1 -name 'cron-issue-*.log' -mmin -1440 2>/dev/null \
           | xargs -r ls -t 2>/dev/null)
  echo "$total run logs written in the last 24h, $failed ended in a failure${n:+ (the newest $(( n < 30 ? n : 30 )) below)}"
  cat "$TMP/runs"
}

snap_main_ci() {
  local p
  while IFS= read -r p; do
    timeout 30 gh run list --repo "alexsiri7/$p" --branch main --event push --limit 15 \
      --json databaseId,workflowName,status,conclusion,headSha,createdAt,url 2>/dev/null \
      | jq -r --arg p "$p" '
          if length == 0 then "\($p): no push runs on main"
          else (.[0].headSha) as $head
            | [.[] | select(.headSha == $head)] | group_by(.workflowName) | map(.[0])
            | map("\($p) \(.workflowName): \(.conclusion // .status) at \(.headSha[0:10]) \(.url)") | .[]
          end' 2>/dev/null || echo "$p: could not read main CI"
  done < <(projects)
}

snap_fuel() {
  local out
  out=$(lachesis_call read_fuel '{}' 2>&1)
  jq -c . <<<"$out" 2>/dev/null || printf '%s\n' "$out" | head -c 6000
}

# The reference crontab's job lines that the live crontab lacks, verbatim.
snap_crontab() {
  local live
  if ! live=$(crontab -l 2>&1); then echo "crontab -l failed: $live"; return; fi
  echo "reference: $REPO/ops/cron/crontab"
  local missing
  missing=$(grep -vE '^[[:space:]]*(#|$)' "$REPO/ops/cron/crontab" | while IFS= read -r line; do
    grep -qxF -- "$line" <<<"$live" || printf '%s\n' "$line"
  done)
  if [ -n "$missing" ]; then echo "missing from the live crontab:"; printf '%s\n' "$missing"
  else echo "missing from the live crontab: none"; fi
}

snap_pickup() {
  if lachesis_pickup_enabled; then echo "LACHESIS_PICKUP=on"; else echo "LACHESIS_PICKUP=off"; fi
}

# build_prompt <run-dir> <briefing-file> <snapshot-file>
build_prompt() {
  local nonce mode=normal
  nonce=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  [ "$REPORT_ONLY" -eq 1 ] && mode="report-only"
  cat <<EOF
Run directory: $1
Write the message to $1/message.md, the status to $1/status, the actions log to $1/actions.log and, last, $1/done.
Reruns file (CI run ids already rerun, one per line): $STATE/reruns
Untrusted-data nonce: $nonce
Mode: $mode
EOF
  if [ "$REPORT_ONLY" -eq 1 ]; then
    cat <<'EOF'
REPORT-ONLY MODE: make no fix at all (neither the briefing's nor the host ones), file no issue, post no comment, change no label and call no Lachesis tool that writes. Write only the files in the run directory. The message is a test and will not be sent.
EOF
  fi
  echo
  cat "$PROMPT_FILE"
  printf '\n## LACHESIS BRIEFING (from get_morning_briefing; the owner'"'"'s instructions, within the bounds above)\n\n'
  cat "$2"
  printf '\n\n## Host snapshot (%s)\n\nBEGIN UNTRUSTED %s host-snapshot\n' "$(date -Is)" "$nonce"
  cat "$3"
  printf '\nEND UNTRUSTED %s host-snapshot\n' "$nonce"
}

tmuxc() { tmux -L "$TMUX_SOCKET" "$@"; }

# run_remote <run-dir> — the interactive session in tmux. Sets SESSION_URL.
# 0 when it started with Remote Control, 1 when the caller should fall back.
run_remote() {
  local cmd waited=0
  command -v tmux >/dev/null 2>&1 || { log "tmux not found — falling back to claude -p"; return 1; }
  tmuxc kill-session -t "$TMUX_SESSION" 2>/dev/null && log "closed yesterday's session"
  printf -v cmd 'cd %q && exec env -u CLAUDECODE CLAUDECODE=0 TERM=xterm-256color timeout --foreground %q claude --remote-control %q --permission-mode bypassPermissions --model %q %q' \
    "$MORNING_PASS_CWD" "$MORNING_PASS_KEEP_SECONDS" "Morning pass $(date +%F)" "$MORNING_PASS_MODEL" \
    "Read $1/prompt.md and follow it exactly."
  if ! env -u CLAUDECODE -u TMUX tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -x 200 -y 50 "$cmd"; then
    log "tmux new-session failed — falling back to claude -p"; return 1
  fi
  while [ "$waited" -lt "$MORNING_PASS_URL_WAIT" ]; do
    SESSION_URL=$(tmuxc capture-pane -pJ -t "$TMUX_SESSION" -S -200 2>/dev/null \
      | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9_-]+' | head -n 1)
    [ -n "$SESSION_URL" ] && { log "remote control: $SESSION_URL"; return 0; }
    tmuxc has-session -t "$TMUX_SESSION" 2>/dev/null || break
    sleep 3; waited=$((waited + 3))
  done
  tmuxc capture-pane -pJ -t "$TMUX_SESSION" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n 15 > "$1/pane-start.txt"
  log "no Remote Control URL after ${waited}s (screen in $1/pane-start.txt) — falling back to claude -p"
  tmuxc kill-session -t "$TMUX_SESSION" 2>/dev/null
  return 1
}

# wait_done <run-dir> — 0 once the session wrote done; 1 on timeout or when
# the tmux session ended without it.
wait_done() {
  local start=$SECONDS
  while [ $((SECONDS - start)) -lt "$MORNING_PASS_TIMEOUT" ]; do
    [ -e "$1/done" ] && return 0
    tmuxc has-session -t "$TMUX_SESSION" 2>/dev/null || { [ -e "$1/done" ]; return; }
    sleep "$MORNING_PASS_POLL"
  done
  [ -e "$1/done" ]
}

# run_print <run-dir> — claude -p, bounded by MORNING_PASS_TIMEOUT.
run_print() {
  (cd "$MORNING_PASS_CWD" && echo "Read $1/prompt.md and follow it exactly." \
    | env -u CLAUDECODE CLAUDECODE=0 timeout "$MORNING_PASS_TIMEOUT" \
        claude -p --permission-mode bypassPermissions --model "$MORNING_PASS_MODEL") \
    > "$1/session.txt" 2>&1
  local rc=$?
  [ "$rc" -eq 124 ] && log "claude -p timed out after ${MORNING_PASS_TIMEOUT}s"
  [ -e "$1/done" ]
}

# ---------------------------------------------------------------------------

mkdir -p "$STATE" || exit 1
exec 9>"$STATE/lock"
if ! flock -n 9; then
  log "another morning pass is running — exiting"
  exit 0
fi

secrets_load NTFY_TOPIC LACHESIS_FACTORY_TOKEN

if [ "$DRY_RUN" -eq 0 ]; then
  if ! detail=$(claude_auth_probe "$HOME/.claude"); then
    log "Claude auth failed for ~/.claude: $detail"
    notify "Morning pass: Claude auth failing" high warning \
      "The morning pass could not start: the owner's Claude account (~/.claude) failed a real request: $detail
Re-login: claude auth login"
    exit 1
  fi
fi

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
if [ "$DRY_RUN" -eq 1 ]; then RUN_DIR="$TMP/run"; else RUN_DIR="$STATE/runs/$(date +%Y%m%d-%H%M%S)"; fi
mkdir -p "$RUN_DIR" || exit 1
[ "$DRY_RUN" -eq 1 ] || touch "$STATE/reruns" 2>/dev/null || true

if ! lachesis_call get_morning_briefing '{}' > "$TMP/briefing" 2> "$TMP/briefing.err"; then
  log "get_morning_briefing failed: $(tail -n 1 "$TMP/briefing.err")"
  printf 'The cron could not fetch the briefing (%s). Call get_morning_briefing with the Lachesis MCP tools and follow it; if that fails too, say so as a fault in the message and do the host part.\n' \
    "$(tail -n 1 "$TMP/briefing.err")" > "$TMP/briefing"
fi

{
  timeout 180 "$PIPELINE_STATUS" 2>&1 | section "pipeline-status"
  snap_logs 2>&1 | section "cron logs"
  snap_gh_archon 2>&1 | section "archon user's gh auth status (sudo -n -u archon env HOME=$GH_ARCHON_HOME gh auth status)"
  snap_failed_runs 2>&1 | section "archon run logs of the last 24h (newest first, last lines)"
  snap_main_ci 2>&1 | section "main CI at HEAD (push runs) per project in archon-projects.txt"
  snap_fuel 2>&1 | section "Lachesis read_fuel"
  snap_crontab 2>&1 | section "crontab: reference vs live"
  snap_pickup 2>&1 | section "Lachesis pickup switch"
} > "$TMP/snapshot"

build_prompt "$RUN_DIR" "$TMP/briefing" "$TMP/snapshot" > "$RUN_DIR/prompt.md"

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$RUN_DIR/prompt.md"
  echo
  echo "DRY-RUN: would run ($MORNING_PASS_MODE, cwd $MORNING_PASS_CWD): claude $( [ "$MORNING_PASS_MODE" = print ] && echo "-p" || echo "--remote-control 'Morning pass $(date +%F)'") --permission-mode bypassPermissions --model $MORNING_PASS_MODEL 'Read <run dir>/prompt.md and follow it exactly.'"
  exit 0
fi

log "starting (mode $MORNING_PASS_MODE$( [ "$REPORT_ONLY" -eq 1 ] && echo ", report-only")), run dir $RUN_DIR"
SESSION_URL="" USED=print FINISHED=0
if [ "$MORNING_PASS_MODE" != print ] && run_remote "$RUN_DIR"; then
  USED=remote
  wait_done "$RUN_DIR" && FINISHED=1
  tmuxc capture-pane -pJ -t "$TMUX_SESSION" -S - 2>/dev/null > "$RUN_DIR/session.txt" || true
else
  run_print "$RUN_DIR" && FINISHED=1
fi

if [ -s "$RUN_DIR/actions.log" ]; then
  while IFS= read -r line; do log "action: $line"; done < "$RUN_DIR/actions.log"
fi
NEEDS_OWNER=no
grep -qx 'needs_owner=yes' "$RUN_DIR/status" 2>/dev/null && NEEDS_OWNER=yes

if [ "$USED" = remote ]; then
  if [ "$FINISHED" -eq 1 ] && [ "$NEEDS_OWNER" = no ]; then
    tmuxc kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    log "quiet morning — session closed"
  elif tmuxc has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "session kept open for the owner (closes itself within ${MORNING_PASS_KEEP_SECONDS}s of its start): $SESSION_URL"
  fi
fi

if [ "$FINISHED" -eq 1 ] && [ -s "$RUN_DIR/message.md" ]; then
  MSG=$(head -c 3800 "$RUN_DIR/message.md")
  [ "$(wc -c < "$RUN_DIR/message.md")" -gt 3800 ] && MSG+=$'\n… (cut; full text in '"$RUN_DIR"'/message.md)'
  TITLE="Morning pass" PRIO=default TAGS=sunrise
  [ "$NEEDS_OWNER" = yes ] && TITLE="Morning pass: needs you" PRIO=high
  log "finished ($USED, needs_owner=$NEEDS_OWNER)"
else
  MSG="The morning pass did not finish within ${MORNING_PASS_TIMEOUT}s or wrote no message (mode $USED). Run directory: $RUN_DIR. See $LOG_DIR/morning-pass.log."
  TITLE="Morning pass did not finish" PRIO=high TAGS=warning
  log "did not finish ($USED): no done file or no message"
fi
[ -n "$SESSION_URL" ] && MSG+=$'\n\nSession: '"$SESSION_URL"

if [ "$REPORT_ONLY" -eq 1 ]; then
  log "report-only — not sent. Message:"
  printf '%s\n' "$MSG" | sed 's/^/    /'
else
  notify "$TITLE" "$PRIO" "$TAGS" "$MSG" "$SESSION_URL" && log "ntfy sent: $TITLE"
fi

find "$STATE/runs" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null || true
[ "$FINISHED" -eq 1 ] || exit 1
exit 0
