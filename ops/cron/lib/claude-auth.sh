#!/usr/bin/env bash
# Claude account health for the cron scripts that spend Claude tokens.
# Usage:
#   source "$SCRIPT_DIR/lib/claude-auth.sh"
#   claude_auth_check "$dir"    # probe one config dir, alert/recover, 0 = usable
#
# `claude auth status` still reports loggedIn: true for a config dir whose
# OAuth token the API rejects (401 on ~/.claude-secondary from 2026-09-11 lost
# seven nightly sweeps before anyone noticed), so the probe is a real,
# minimal request.
#
# A failing account gets one ntfy per day and one open HUMAN_NEEDED_LABEL issue
# on CLAUDE_AUTH_ISSUE_REPO naming the re-login command, commented on once a
# day while it keeps failing and closed by the first probe that passes again.
# That label is one of HUMAN_LABELS, so issue-pickup-cron.sh never feeds the
# issue back into archon. Per-account state lives in
# CLAUDE_AUTH_STATE_DIR, shared by every caller so they do not alert twice.
#
# Callers provide log() and notify().

[ -n "${_ARCHON_CLAUDE_AUTH_SH:-}" ] && return 0
_ARCHON_CLAUDE_AUTH_SH=1

# shellcheck source=lib/human-labels.sh
source "$(dirname "${BASH_SOURCE[0]}")/human-labels.sh"

# Colon-separated config dirs; secrets.env may override (it is sourced later).
CLAUDE_ACCOUNTS="${CLAUDE_ACCOUNTS:-$HOME/.claude:$HOME/.claude-secondary}"
CLAUDE_AUTH_STATE_DIR="${CLAUDE_AUTH_STATE_DIR:-$HOME/.archon/pipeline-health-state/claude-auth}"
CLAUDE_AUTH_ISSUE_REPO="alexsiri7/interstellarai.net"
CLAUDE_AUTH_PROBE_TIMEOUT="${CLAUDE_AUTH_PROBE_TIMEOUT:-90}"

# Echoes the probe's last output line (the API error on failure).
# The account "archon" (lib/run-as.sh, ARCHON_RUN_AS=archon) is the factory
# user's own credential, probed as that user through the wrapper.
claude_auth_probe() {
  local dir="$1" out rc
  if [ "$dir" = archon ]; then
    out=$(timeout "$((CLAUDE_AUTH_PROBE_TIMEOUT + 15))" \
      sudo -n -u "${ARCHON_AS_USER:-archon}" "${ARCHON_AS_WRAPPER:-/usr/local/bin/archon-as-archon}" \
      claude-probe "$CLAUDE_AUTH_PROBE_TIMEOUT" </dev/null 2>&1)
  else
    out=$(CLAUDE_CONFIG_DIR="$dir" CLAUDECODE=0 \
      timeout "$CLAUDE_AUTH_PROBE_TIMEOUT" claude -p --model haiku "ok" </dev/null 2>&1)
  fi
  rc=$?
  [ "$rc" -eq 124 ] && out="probe timed out after ${CLAUDE_AUTH_PROBE_TIMEOUT}s"
  printf '%s\n' "$out" | tail -1
  return "$rc"
}

claude_auth_issue_title() { echo "Claude account auth failing: $1"; }

# The command that fixes a failing account.
claude_auth_login_cmd() {
  if [ "$1" = archon ]; then
    echo "claude setup-token   # then: sudo /mnt/ext-fast/interstellarai.net/ops/host/archon-user/install.sh --set-claude-token"
  else
    echo "CLAUDE_CONFIG_DIR=$1 claude auth login"
  fi
}

# Echoes the open tracking issue number for $1 (empty if none); non-zero when
# gh itself failed, so a flaky listing never reads as "no issue yet".
claude_auth_find_issue() {
  local title list
  title=$(claude_auth_issue_title "$1")
  list=$(gh issue list --repo "$CLAUDE_AUTH_ISSUE_REPO" --state open --label "$HUMAN_NEEDED_LABEL" \
    --limit 100 --json number,title 2>/dev/null) || return 1
  jq -r --arg t "$title" 'map(select(.title == $t)) | .[0].number // empty' <<<"$list"
}

claude_auth_failed() {
  local dir="$1" detail="$2"
  local key="${dir//\//_}" today issue
  local failing="$CLAUDE_AUTH_STATE_DIR/$key.failing" alerted="$CLAUDE_AUTH_STATE_DIR/$key.alerted"
  today=$(date +%F)
  mkdir -p "$CLAUDE_AUTH_STATE_DIR"
  touch "$failing"
  log "claude-auth: $dir failed the probe: $detail"

  local first_today=1
  [ "$(cat "$alerted" 2>/dev/null)" = "$today" ] && first_today=0

  if issue=$(claude_auth_find_issue "$dir"); then
    if [ -z "$issue" ]; then
      gh label create --repo "$CLAUDE_AUTH_ISSUE_REPO" "$HUMAN_NEEDED_LABEL" \
        --color D93F0B --description "Needs a human — not picked up by archon" >/dev/null 2>&1 || true
      if gh issue create --repo "$CLAUDE_AUTH_ISSUE_REPO" --label "$HUMAN_NEEDED_LABEL" \
          --title "$(claude_auth_issue_title "$dir")" --body "$(cat <<EOF
The Claude account in \`$dir\` fails a real request, so cron jobs that use it (the nightly sweep-audits rotation) cannot run on it:

\`\`\`
$detail
\`\`\`

Log in again:

\`\`\`
$(claude_auth_login_cmd "$dir")
\`\`\`

Auto-filed by \`ops/cron/lib/claude-auth.sh\`; \`sweep-audits.sh\` falls back to another account in \`CLAUDE_ACCOUNTS\` meanwhile. This issue is closed automatically once the probe passes again.
EOF
)" >/dev/null 2>&1; then
        log "claude-auth: opened tracking issue for $dir"
      else
        log "claude-auth: WARNING: could not open tracking issue for $dir"
      fi
    elif [ "$first_today" -eq 1 ]; then
      gh issue comment "$issue" --repo "$CLAUDE_AUTH_ISSUE_REPO" \
        --body "Still failing on $today: \`$detail\`" >/dev/null 2>&1 || true
    fi
  else
    log "claude-auth: WARNING: could not list issues on $CLAUDE_AUTH_ISSUE_REPO"
  fi

  [ "$first_today" -eq 1 ] || return 0
  notify "Claude account auth failing: ${dir##*/}" \
    "$dir: $detail
Re-login: $(claude_auth_login_cmd "$dir")" \
    high key
  echo "$today" > "$alerted"
}

claude_auth_recovered() {
  local dir="$1"
  local key="${dir//\//_}" issue
  local failing="$CLAUDE_AUTH_STATE_DIR/$key.failing"
  [ -f "$failing" ] || return 0
  if ! issue=$(claude_auth_find_issue "$dir"); then
    log "claude-auth: WARNING: could not list issues on $CLAUDE_AUTH_ISSUE_REPO (recovery check for $dir)"
    return 0
  fi
  if [ -n "$issue" ] && ! gh issue close "$issue" --repo "$CLAUDE_AUTH_ISSUE_REPO" \
      --comment "The probe passes again on $(date +%F); closing." >/dev/null 2>&1; then
    log "claude-auth: WARNING: could not close tracking issue #$issue for $dir"
    return 0
  fi
  rm -f "$failing" "$CLAUDE_AUTH_STATE_DIR/$key.alerted"
  log "claude-auth: $dir recovered${issue:+ — closed #$issue}"
}

claude_auth_check() {
  local dir="$1" detail
  if detail=$(claude_auth_probe "$dir"); then
    claude_auth_recovered "$dir"
    return 0
  fi
  claude_auth_failed "$dir" "$detail"
  return 1
}
