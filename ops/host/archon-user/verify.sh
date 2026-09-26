#!/usr/bin/env bash
# ops/host/archon-user/verify.sh — prove the factory runs as `archon`, that
# `archon` cannot reach the owner's secrets, and that a factory run still works.
# Run as the owner (asiri), no sudo; `install.sh --cutover` runs it at the end.
#
#   ops/host/archon-user/verify.sh           # everything below; exit 1 on any FAIL
#   ops/host/archon-user/verify.sh --live    # also one real (tiny) Claude run through the factory path
#
# Before the cutover (flag not yet archon) the server/flag checks report WARN,
# so this doubles as a readiness check after `install.sh`, --set-gh-token and
# --set-claude-token.
#
#   1. host: flag, server unit + its user, owner unit stopped, health, links, crontab
#   2. owner side: home and secret-file modes as asiri sees them
#   3. archon side (archon-as-archon selftest, as archon): identity, no sudo,
#      named secrets unreachable, sweep of /home /mnt /media /srv /var/backups
#      plus every top-level entry of the mounts (archon cannot list them itself),
#      /tmp leftovers (WARN), write boundaries, process environments free of
#      secrets, toolchains, no claude.ai connectors
#   4. credentials: a real Claude request as archon; gh token fine-grained with
#      push to every factory repo and none to the Archon fork
#   5. factory path: archon doctor; the cron's own `archon` (lib/run-as.sh +
#      shim) lists runs from archon's DB; a --dry-run of archon-assist through
#      the wrapper (no provider call); with --live a real one-line run
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WRAPPER=/usr/local/bin/archon-as-archon
UNIT=archon-serve.service
BASE=/mnt/ext-fast
LIVE=0
case "${1:-}" in --live) LIVE=1 ;; "") ;; -h|--help) sed -n '2,26p' "$0"; exit 0 ;; *) echo "usage: $0 [--live]" >&2; exit 2 ;; esac

FAILS=0 WARNS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
warn() { echo "WARN $*"; WARNS=$((WARNS + 1)); }
wr()   { sudo -n -u archon "$WRAPPER" "$@"; }

# shellcheck source=../../cron/lib/run-as.sh
source "$REPO_DIR/ops/cron/lib/run-as.sh"
MODE="$ARCHON_RUN_AS"
cut() { [ "$MODE" = archon ]; }
cutcheck() { if cut; then fail "$@"; else warn "$* (not cut over yet)"; fi; }

echo "== 1. host (ARCHON_RUN_AS=$MODE)"
if cut; then pass "flag: ARCHON_RUN_AS=archon"; else warn "flag: ARCHON_RUN_AS=$MODE (not cut over yet)"; fi
if systemctl is-active -q "$UNIT"; then
    pid=$(systemctl show -p MainPID --value "$UNIT"); u=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ "$u" = archon ]; then pass "system $UNIT active, main pid $pid runs as archon"; else fail "system $UNIT main pid $pid runs as '${u:-?}'"; fi
else
    cutcheck "system $UNIT not active"
fi
if systemctl --user is-active -q "$UNIT" 2>/dev/null; then cutcheck "owner's user $UNIT still active"
else pass "owner's user $UNIT not active"; fi
code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' http://127.0.0.1:3090/ 2>/dev/null || echo 000)
if [ "$code" = 200 ]; then pass "server answers 200 on 127.0.0.1:3090"; else fail "server answers $code on 127.0.0.1:3090"; fi
link=$(readlink "$HOME/.bun/bin/archon" 2>/dev/null || true)
if [ "$link" = "$REPO_DIR/ops/cron/lib/archon-shim/archon" ]; then pass "$HOME/.bun/bin/archon -> shim (manual runs go to archon too)"
else cutcheck "$HOME/.bun/bin/archon -> ${link:-?} (manual 'archon' runs would start a stale factory as asiri)"; fi
if crontab -l 2>/dev/null | grep -q 'ops/cron/ops-self-update.sh'; then pass "crontab self-update goes through ops-self-update.sh"
else cutcheck "crontab self-update is still a bare git pull (ops/** changes would reach cron unreviewed)"; fi
if sudo -n -u archon "$WRAPPER" --version >/dev/null 2>&1; then pass "sudoers: asiri may run the wrapper as archon"
else fail "sudo -n -u archon $WRAPPER --version failed (sudoers/wrapper not installed?)"; fi
if sudo -n -u archon /bin/true 2>/dev/null; then fail "sudoers lets asiri run arbitrary commands as archon"; else pass "sudoers: nothing else as archon"; fi

echo "== 2. owner side"
mode_ok() {  # mode_ok <path> <max-octal-mask-of-forbidden-bits> <label>
    [ -e "$1" ] || return 0
    local m; m=$(stat -c %a "$1")
    if [ $(( 8#$m & 8#$2 )) -eq 0 ]; then pass "$3 $1 ($m)"; else fail "$3 $1 is $m"; fi
}
mode_ok "$HOME" 007 "home not world-accessible:"
for d in .config/archon-cron .config/personal-ops .config/gh .config/opencode .config/rclone .railway .ssh .claude .archon backups; do
    mode_ok "$HOME/$d" 077 "private dir:"
done
for f in .config/archon-cron/secrets.env .config/archon-cron/consolidated-db.env .railway/config.json .claude/.credentials.json .archon/credential-key; do
    mode_ok "$HOME/$f" 077 "private file:"
done
if id -nG | tr ' ' '\n' | grep -qx archon; then pass "asiri is in group archon (reads factory logs)"; else warn "asiri not (yet) in group archon — log in again after install.sh"; fi
if git config --global --get-all safe.directory 2>/dev/null | grep -qx '\*'; then
    warn "$HOME/.gitconfig has safe.directory = * — git as asiri would honour a repo config archon wrote; remove it (git config --global --unset-all safe.directory '\\*') and never run git as asiri in $BASE/archon-home"
else pass "no safe.directory = * for asiri"; fi

echo "== 3. archon side (selftest as archon)"
shopt -s dotglob nullglob
probe=("$BASE"/* /mnt/nas/* /mnt/steam-slow/* /mnt/steam-fast/* /home/* "$BASE"/nas/* "$BASE"/personal-ops/*)
shopt -u dotglob nullglob
if out=$(wr selftest "${probe[@]}" 2>&1); then pass "selftest (details below)"; else fail "selftest reported failures (below)"; fi
printf '%s\n' "$out" | sed 's/^/    /'
FAILS=$((FAILS + $(grep -c '^FAIL' <<<"$out")))

echo "== 4. credentials"
if out=$(wr claude-probe 90 2>&1); then pass "claude as archon: $(tail -n 1 <<<"$out" | cut -c1-80)"
else fail "claude as archon: $(tail -n 1 <<<"$out" | cut -c1-160) — install.sh --set-claude-token"; fi
out=$(wr gh-probe 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
if [ "$rc" -eq 0 ]; then pass "gh token for archon"; else fail "gh token for archon (see above) — README step (a)"; fi

echo "== 5. factory path"
if out=$(wr doctor 2>&1); then pass "archon doctor"; else warn "archon doctor: $(tail -n 3 <<<"$out" | tr '\n' ' ' | cut -c1-200)"; fi
if runs=$(ARCHON_RUN_AS=archon PATH="$REPO_DIR/ops/cron/lib/archon-shim:$PATH" archon workflow runs --all --limit 1 --json 2>&1) \
        && python3 -c 'import json,sys; json.load(sys.stdin)["runs"]' <<<"$runs" 2>/dev/null; then
    pass "cron path: shim -> wrapper -> archon's DB lists runs"
else
    fail "cron path: 'archon workflow runs' via the shim failed: $(tail -n 1 <<<"$runs")"
fi
first=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' /etc/archon-user/projects 2>/dev/null | head -n 1)
if [ -n "$first" ]; then
    if out=$(wr workflow run archon-assist --dry-run --default-stubs --cwd "$BASE/$first" "verify.sh dry run" 2>&1) \
            && grep -q 'Outcome: completed' <<<"$out"; then
        pass "dry run of archon-assist as archon in $first (no provider call)"
    else
        fail "dry run of archon-assist as archon in $first: $(tail -n 3 <<<"$out" | tr '\n' ' ' | cut -c1-200)"
    fi
    if [ "$LIVE" = 1 ]; then
        if out=$(wr workflow run archon-assist --no-worktree --cwd "$BASE/$first" \
                "verify.sh live check: reply with exactly the word FACTORY-OK and do nothing else. Do not use any tools." 2>&1) \
                && grep -q 'FACTORY-OK' <<<"$out"; then
            pass "live run of archon-assist as archon in $first"
        else
            fail "live run of archon-assist as archon in $first: $(tail -n 3 <<<"$out" | tr '\n' ' ' | cut -c1-200)"
        fi
    fi
else
    fail "/etc/archon-user/projects missing or empty"
fi

echo
echo "verify: $FAILS failure(s), $WARNS warning(s)"
[ "$FAILS" -eq 0 ]
