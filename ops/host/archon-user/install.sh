#!/usr/bin/env bash
# ops/host/archon-user/install.sh — run the Archon factory's agent sessions as
# the unprivileged user `archon` instead of the owner (asiri). See README.md.
#
#   sudo ops/host/archon-user/install.sh                   # 1. prepare (idempotent; safe while the factory runs)
#   ops/host/archon-user/install.sh --dry-run              #    preview step 1 as any user
#   sudo ops/host/archon-user/install.sh --set-gh-token    # 2. fine-grained PAT for archon (stdin)
#   sudo ops/host/archon-user/install.sh --set-claude-token# 3. `claude setup-token` output for archon (stdin)
#   sudo ops/host/archon-user/install.sh --drain           # 4. stop new launches, let runs finish
#   sudo ops/host/archon-user/install.sh --cutover [--force]  # 5. switch (refuses while runs are live)
#   sudo ops/host/archon-user/install.sh --rollback        #    one-step way back to running as asiri
#   ops/host/archon-user/install.sh --status               #    where things stand (any user)
#
# Prepare (no behaviour change for the running factory; nothing is started):
#   1. user + group `archon` (system, nologin, home /mnt/ext-fast/archon-home 0750);
#      asiri joins group archon (to read the factory's logs), never the reverse
#   2. owner secrets: home 0750, secret dirs 0700, secret files 0600
#   3. ACL deny for archon (u:archon:---) on every top-level entry of
#      /mnt/ext-fast except the engine and archon's home, on /mnt/nas and on
#      /home/*; /mnt/ext-fast itself becomes traverse-only for archon
#   4. the NTFS mounts (/mnt/steam-*: DB backups) lose umask=000 in /etc/fstab
#      (-> umask=077) and are remounted when idle
#   5. archon's home: ~/.archon (config.yaml, .env, workflows), ~/.gitconfig,
#      ~/.claude/settings.json, tmp, repos
#   6. toolchains copied into archon's home (bun, claude, gh, shellcheck, uv,
#      JDK, Android SDK, Playwright browsers, rustup/cargo, Flutter SDK)
#   7. /etc/archon-user/projects, /usr/local/lib/archon-user/bin/archon,
#      /usr/local/bin/archon-as-archon, /etc/sudoers.d/archon-user (visudo
#      checked, rolled back on failure), /etc/systemd/system/archon-serve.service
#      (installed, not enabled)
#
# Test hook (ops/cron/tests/archon-user-install.bats): ARCHON_USER_INSTALL_SANDBOX=<dir>
# runs step 7's sudoers logic against <dir> with a stubbed visudo, as any user.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ARCHON_USER=archon
OWNER=asiri
AH=/mnt/ext-fast/archon-home
BASE=/mnt/ext-fast
ENGINE=/mnt/ext-fast/archon
UNIT=archon-serve.service
UNIT_DST=/etc/systemd/system/$UNIT
WRAPPER_DST=/usr/local/bin/archon-as-archon
LIBDIR=/usr/local/lib/archon-user
ETC=/etc/archon-user
SANDBOX="${ARCHON_USER_INSTALL_SANDBOX:-}"
SUDOERS_D="${SANDBOX:+$SANDBOX/sudoers.d}"; SUDOERS_D="${SUDOERS_D:-/etc/sudoers.d}"
SUDOERS_DST="$SUDOERS_D/archon-user"
HEALTH_URL=http://127.0.0.1:3090/
# Top-level entries of $BASE archon may reach; everything else gets u:archon:---.
BASE_ALLOW=(archon archon-home lost+found)

OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6); OWNER_HOME=${OWNER_HOME:-/home/$OWNER}
OWNER_UID=$(id -u "$OWNER" 2>/dev/null || echo 1000)
FLAG_FILE="$OWNER_HOME/.config/archon-cron/run-as"
LINK="$OWNER_HOME/.bun/bin/archon"
LINK_PREV="$OWNER_HOME/.config/archon-cron/archon-link.prev"
SHIM="$REPO_DIR/ops/cron/lib/archon-shim/archon"
PROJECTS_SRC="$REPO_DIR/ops/cron/archon-projects.txt"

MODE=prepare DRY=0 FORCE=0
for a in "$@"; do
    case "$a" in
        --dry-run|-n) DRY=1 ;;
        --force) FORCE=1 ;;
        --set-gh-token) MODE=gh-token ;;
        --set-claude-token) MODE=claude-token ;;
        --drain) MODE=drain ;;
        --cutover) MODE=cutover ;;
        --rollback) MODE=rollback ;;
        --status) MODE=status ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "unknown argument: $a (see --help)" >&2; exit 2 ;;
    esac
done

if [ "$DRY" -eq 0 ] && [ "$MODE" != status ] && [ -z "$SANDBOX" ] && [ "$(id -u)" -ne 0 ]; then
    echo "run as root: sudo $0 $*   (or $0 --dry-run to preview)" >&2
    exit 1
fi

# ---------------------------------------------------------------- helpers ---
say()   { printf '==> %s\n' "$*"; }
done_() { printf '    %s\n' "$*"; }
FAILED=()
fail()  { printf '    ERROR: %s\n' "$2" >&2; FAILED+=("$1"); }
run() {
    if [ "$DRY" -eq 1 ]; then printf '    DRY-RUN:'; printf ' %q' "$@"; printf '\n'; return 0; fi
    "$@"
}
as_archon() { run runuser -u "$ARCHON_USER" -- "$@"; }
# write_file <path> <mode> <owner:group> <content> — atomic; no-op when identical.
write_file() {
    local path="$1" mode="$2" own="$3" content="$4"
    if [ -r "$path" ] && cmp -s "$path" <(printf '%s' "$content"); then
        run chmod "$mode" "$path"; run chown "$own" "$path"; done_ "$path already done"; return 0
    fi
    if [ "$DRY" -eq 1 ]; then
        printf '    DRY-RUN: would write %s (%s %s):\n' "$path" "$mode" "$own"
        printf '%s' "$content" | sed 's/^/        | /'; return 0
    fi
    local tmp; tmp=$(mktemp "${path}.XXXXXX") || return 1
    if ! { printf '%s' "$content" > "$tmp" && chmod "$mode" "$tmp" && chown "$own" "$tmp" && mv -f "$tmp" "$path"; }; then
        rm -f "$tmp"; return 1
    fi
    done_ "wrote $path"
}
finish() {
    echo
    if [ "${#FAILED[@]}" -gt 0 ]; then echo "FAILED steps: ${FAILED[*]} — fix and re-run (safe to repeat)." >&2; exit 1; fi
    [ "$DRY" -eq 1 ] && echo "dry-run complete — nothing was changed."
    exit 0
}
user_exists() { getent passwd "$ARCHON_USER" >/dev/null; }
flag_now() { sed -nE 's/^ARCHON_RUN_AS=([a-z]+).*/\1/p' "$FLAG_FILE" 2>/dev/null | tail -n 1; }
set_flag() {  # set_flag asiri|drain|archon
    run mkdir -p "$(dirname "$FLAG_FILE")"
    write_file "$FLAG_FILE" 0600 "$OWNER:$OWNER" "# Written by ops/host/archon-user/install.sh — read by ops/cron/lib/run-as.sh
ARCHON_RUN_AS=$1
" && done_ "flag: ARCHON_RUN_AS=$1 ($FLAG_FILE)"
}
serve_healthy() {  # serve_healthy <tries>
    local i
    for ((i = 1; i <= $1; i++)); do
        [ "$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$HEALTH_URL" 2>/dev/null)" = 200 ] && return 0
        sleep 2
    done
    return 1
}
owner_systemctl() { run systemctl --user -M "$OWNER@" "$@"; }
# read_secret <prompt> — one line from stdin, not echoed on a terminal.
read_secret() {
    local v
    if [ -t 0 ]; then read -r -s -p "$1: " v; echo >&2; else read -r v; fi
    printf '%s' "$v"
}

# ---------------------------------------------------------------- sudoers ---
install_sudoers() {
    local src="$SCRIPT_DIR/sudoers-archon-user"
    if ! visudo -c -q -f "$src"; then fail sudoers "$src does not parse (visudo -c) — not installed"; return; fi
    if [ -r "$SUDOERS_DST" ] && cmp -s "$src" "$SUDOERS_DST"; then done_ "$SUDOERS_DST already done"; return; fi
    if [ "$DRY" -eq 0 ] && [ -z "$SANDBOX" ] && ! out=$(visudo -c 2>&1); then
        printf '%s\n' "$out" | sed 's/^/        | /'
        fail sudoers "pre-existing sudoers problem (visudo -c fails before $SUDOERS_DST is installed) — not installed; see ops/host/README.md Troubleshooting"
        return
    fi
    local own=root grp=root
    [ -n "$SANDBOX" ] && { own=$(id -un); grp=$(id -gn); }
    run install -m 0440 -o "$own" -g "$grp" "$src" "$SUDOERS_DST" && done_ "installed $SUDOERS_DST (0440)"
    if [ "$DRY" -eq 0 ] && ! out=$(visudo -c 2>&1); then
        rm -f "$SUDOERS_DST"
        printf '%s\n' "$out" | sed 's/^/        | /'
        fail sudoers "combined sudoers failed visudo -c after install — $SUDOERS_DST removed"
    fi
}
if [ -n "$SANDBOX" ]; then   # test hook: the sudoers step only
    install_sudoers; finish
fi

# ================================================================ status ====
if [ "$MODE" = status ]; then
    echo "flag:          ARCHON_RUN_AS=$(flag_now 2>/dev/null || true) ($FLAG_FILE)"
    echo "user:          $(getent passwd "$ARCHON_USER" || echo 'not created')"
    echo "wrapper:       $(ls -l "$WRAPPER_DST" 2>/dev/null || echo missing)"
    echo "sudoers:       $(ls -l "$SUDOERS_DST" 2>/dev/null || echo 'missing (or unreadable without root)')"
    echo "system unit:   $(systemctl is-enabled "$UNIT" 2>/dev/null || true) / $(systemctl is-active "$UNIT" 2>/dev/null || true)"
    echo "owner unit:    $(systemctl --user -M "$OWNER@" is-enabled "$UNIT" 2>/dev/null || true) / $(systemctl --user -M "$OWNER@" is-active "$UNIT" 2>/dev/null || true)"
    echo "server:        $(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo down) on $HEALTH_URL"
    echo "archon link:   $LINK -> $(readlink "$LINK" 2>/dev/null || echo '?')"
    exit 0
fi

# ================================================================ tokens ====
if [ "$MODE" = gh-token ]; then
    user_exists || { echo "user $ARCHON_USER missing — run: sudo $0" >&2; exit 1; }
    say "GitHub fine-grained PAT for $ARCHON_USER"
    [ -t 0 ] && echo "    Paste the token (github_pat_...), then Enter. It is not echoed." >&2
    tok=$(read_secret "token")
    [[ "$tok" =~ ^github_pat_[A-Za-z0-9_]{20,}$ ]] || { echo "    not a fine-grained PAT (want github_pat_...); refusing — see README step (a)" >&2; exit 1; }
    ghbin="$AH/.local/bin/gh"
    [ -x "$ghbin" ] || { echo "    $ghbin missing — run: sudo $0" >&2; exit 1; }
    if printf '%s\n' "$tok" | runuser -u "$ARCHON_USER" -- env -i HOME="$AH" PATH="$AH/.local/bin:/usr/bin:/bin" \
            "$ghbin" auth login --hostname github.com --git-protocol https --with-token; then
        done_ "gh auth login done for $ARCHON_USER"
    else
        echo "    gh auth login failed" >&2; exit 1
    fi
    unset tok
    runuser -u "$ARCHON_USER" -- "$WRAPPER_DST" gh-probe
    exit $?
fi

if [ "$MODE" = claude-token ]; then
    user_exists || { echo "user $ARCHON_USER missing — run: sudo $0" >&2; exit 1; }
    say "Claude credential for $ARCHON_USER (output of \`claude setup-token\`)"
    [ -t 0 ] && echo "    Paste the token printed by 'claude setup-token' (sk-ant-oat...), then Enter. It is not echoed." >&2
    tok=$(read_secret "token")
    [[ "$tok" =~ ^sk-ant-[A-Za-z0-9._~+/=-]{20,}$ ]] || { echo "    does not look like a Claude OAuth token (sk-ant-...); refusing" >&2; exit 1; }
    dir="$AH/.config/archon-user"
    install -d -m 0700 -o "$ARCHON_USER" -g "$ARCHON_USER" "$AH/.config" "$dir"
    write_file "$dir/claude.env" 0600 "$ARCHON_USER:$ARCHON_USER" "CLAUDE_CODE_OAUTH_TOKEN=$tok
" || { echo "    could not write $dir/claude.env" >&2; exit 1; }
    unset tok
    if out=$(runuser -u "$ARCHON_USER" -- "$WRAPPER_DST" claude-probe 90 2>&1); then
        done_ "probe OK: $(tail -n 1 <<<"$out")"
    else
        echo "    probe FAILED: $(tail -n 1 <<<"$out")" >&2; exit 1
    fi
    systemctl is-active -q "$UNIT" 2>/dev/null && run systemctl restart "$UNIT" && done_ "restarted $UNIT (new credential)"
    exit 0
fi

# ================================================================ drain =====
if [ "$MODE" = drain ]; then
    say "drain: no new archon launches; running and paused runs finish as $OWNER"
    set_flag drain
    done_ "watch: ARCHON_RUN_AS=asiri archon workflow runs --all --status running  (and --status paused)"
    done_ "then:  sudo $0 --cutover"
    finish
fi

# ================================================================ rollback ==
if [ "$MODE" = rollback ]; then
    say "rollback: agent sessions run as $OWNER again"
    set_flag asiri
    prev=$(cat "$LINK_PREV" 2>/dev/null || true); prev=${prev:-$ENGINE/packages/cli/src/cli.ts}
    if [ "$(readlink "$LINK" 2>/dev/null)" = "$SHIM" ]; then
        run ln -sfn "$prev" "$LINK" && run chown -h "$OWNER:$OWNER" "$LINK" && done_ "$LINK -> $prev"
    else
        done_ "$LINK -> $(readlink "$LINK" 2>/dev/null || echo '?') (left alone)"
    fi
    if systemctl is-active -q "$UNIT" 2>/dev/null || systemctl is-enabled -q "$UNIT" 2>/dev/null; then
        run systemctl disable --now "$UNIT" && done_ "stopped and disabled system $UNIT"
    fi
    owner_systemctl enable --now "$UNIT" && done_ "enabled and started $OWNER's user $UNIT"
    if [ "$DRY" -eq 0 ]; then
        if serve_healthy 30; then done_ "server healthy on $HEALTH_URL (as $OWNER)"
        else fail serve "$HEALTH_URL does not answer 200 — check: systemctl --user status $UNIT (as $OWNER)"; fi
        if user_exists && [ -x "$WRAPPER_DST" ]; then
            live=$(runuser -u "$ARCHON_USER" -- "$WRAPPER_DST" workflow runs --all --status running --json 2>/dev/null \
                   | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("runs",[])))' 2>/dev/null || echo '?')
            done_ "runs still running as $ARCHON_USER: $live (they finish there; their records stay in $AH/.archon)"
        fi
    fi
    done_ "left in place (harmless for asiri mode): user $ARCHON_USER, its home, sudoers, ACLs, file modes, fstab"
    finish
fi

# ================================================================ cutover ===
if [ "$MODE" = cutover ]; then
    say "cutover preflight"
    ok=1
    user_exists || { fail preflight "user $ARCHON_USER missing — run: sudo $0"; ok=0; }
    [ -x "$WRAPPER_DST" ] || { fail preflight "$WRAPPER_DST missing — run: sudo $0"; ok=0; }
    [ -r "$SUDOERS_DST" ] || { fail preflight "$SUDOERS_DST missing — run: sudo $0"; ok=0; }
    [ -r "$UNIT_DST" ] || { fail preflight "$UNIT_DST missing — run: sudo $0"; ok=0; }
    if [ -s "$AH/.config/archon-user/claude.env" ] || [ -s "$AH/.claude/.credentials.json" ]; then done_ "Claude credential present"
    else fail preflight "no Claude credential for $ARCHON_USER — README step (c)"; ok=0; fi
    for m in /mnt/steam-slow /mnt/steam-fast; do
        mountpoint -q "$m" || continue
        if [ $(( 8#$(stat -c %a "$m") & 8#007 )) -ne 0 ]; then
            fail preflight "$m is still world-accessible (mode $(stat -c %a "$m")) — unmount/mount it (fstab now has umask=077) or reboot; it holds the DB backups"; ok=0
        fi
    done
    [ "$ok" -eq 1 ] || finish
    if [ "$DRY" -eq 0 ]; then
        if out=$(runuser -u "$ARCHON_USER" -- "$WRAPPER_DST" gh-probe 2>&1); then done_ "gh: $(grep -c '^PASS' <<<"$out") checks pass"
        else printf '%s\n' "$out" | sed 's/^/        | /'; fail preflight "archon's GitHub token is not right — README step (b)"; finish; fi
    fi

    say "drain check (runs as $OWNER must be finished: their records stay in $OWNER_HOME/.archon)"
    if [ "$(flag_now)" != drain ] && [ "$FORCE" -eq 0 ]; then
        fail drain "flag is '$(flag_now)', not drain — run: sudo $0 --drain, wait for the runs to finish, then --cutover"; finish
    fi
    busy=""
    if [ "$DRY" -eq 0 ]; then
        for st in running paused; do
            n=$(runuser -u "$OWNER" -- env -i HOME="$OWNER_HOME" PATH="$OWNER_HOME/.bun/bin:/usr/bin:/bin" CLAUDECODE=0 \
                ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 "$OWNER_HOME/.bun/bin/bun" "$ENGINE/packages/cli/src/cli.ts" \
                workflow runs --all --status "$st" --limit 100 --json --cwd "$REPO_DIR" 2>/dev/null \
                | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("runs",[])))' 2>/dev/null || echo unknown)
            done_ "$OWNER's DB: $st runs: $n"
            [ "$n" = 0 ] || busy="$busy $st=$n"
        done
        p=$(pgrep -u "$OWNER" -fc 'archon workflow run|cli\.ts workflow run' || true)
        done_ "'archon workflow run' processes as $OWNER: ${p:-0}"
        [ "${p:-0}" = 0 ] || busy="$busy processes=$p"
    fi
    if [ -n "$busy" ] && [ "$FORCE" -eq 0 ]; then
        fail drain "not drained:$busy — wait (paused runs are CI waits the server resumes), or --force to leave them behind"; finish
    fi
    [ -n "$busy" ] && done_ "--force: leaving$busy behind (paused runs will not resume; their issues are re-queued by issue-pickup's stuck check)"

    say "factory clones"
    as_archon "$WRAPPER_DST" ensure-clones || { fail clones "ensure-clones failed (see above)"; finish; }

    say "switch the server to $ARCHON_USER"
    owner_systemctl disable --now "$UNIT" && done_ "stopped and disabled $OWNER's user $UNIT"
    run systemctl enable --now "$UNIT" && done_ "enabled and started system $UNIT (User=$ARCHON_USER)"
    if [ "$DRY" -eq 0 ] && ! serve_healthy 30; then
        fail serve "system $UNIT not healthy on $HEALTH_URL — rolling the server back (journalctl -u $UNIT)"
        systemctl disable --now "$UNIT"; owner_systemctl enable --now "$UNIT"
        finish
    fi

    say "switch the cron jobs"
    cur=$(readlink "$LINK" 2>/dev/null || true)
    if [ "$cur" != "$SHIM" ]; then
        [ -n "$cur" ] && write_file "$LINK_PREV" 0600 "$OWNER:$OWNER" "$cur"
        run ln -sfn "$SHIM" "$LINK" && run chown -h "$OWNER:$OWNER" "$LINK" && done_ "$LINK -> $SHIM (was ${cur:-none})"
    else
        done_ "$LINK already -> $SHIM"
    fi
    if crontab -u "$OWNER" -l 2>/dev/null | grep -q "git -C $REPO_DIR pull --ff-only -q origin main"; then
        if [ "$DRY" -eq 1 ]; then done_ "DRY-RUN: would point the crontab's self-update line at ops/cron/ops-self-update.sh"
        else
            crontab -u "$OWNER" -l | sed "s#git -C $REPO_DIR pull --ff-only -q origin main#$REPO_DIR/ops/cron/ops-self-update.sh#" \
                | crontab -u "$OWNER" - && done_ "crontab: self-update now runs ops/cron/ops-self-update.sh (holds ops/** changes for --approve)"
        fi
    else
        done_ "crontab self-update line already switched (or absent)"
    fi
    set_flag archon

    say "verify"
    if [ "$DRY" -eq 0 ]; then
        runuser -u "$OWNER" -- "$SCRIPT_DIR/verify.sh" || fail verify "verify.sh reported failures (above) — fix, or roll back: sudo $0 --rollback"
    fi
    finish
fi

# ================================================================ prepare ===
[ "$DRY" -eq 1 ] && [ "$(id -u)" -ne 0 ] && echo "(dry-run as $(id -un): checks that need root are skipped)"

# ------------------------------------------------------------ 1. user -------
say "1. user $ARCHON_USER"
if user_exists; then
    done_ "user $ARCHON_USER already exists ($(getent passwd "$ARCHON_USER" | cut -d: -f6))"
else
    getent group "$ARCHON_USER" >/dev/null || run groupadd --system "$ARCHON_USER"
    run useradd --system --gid "$ARCHON_USER" --home-dir "$AH" --create-home --shell /usr/sbin/nologin \
        --comment "Archon factory agent sessions" "$ARCHON_USER" && done_ "created user $ARCHON_USER"
fi
run chown "$ARCHON_USER:$ARCHON_USER" "$AH"; run chmod 0750 "$AH"
if id -nG "$OWNER" 2>/dev/null | tr ' ' '\n' | grep -qx "$ARCHON_USER"; then done_ "$OWNER already in group $ARCHON_USER"
else run usermod -aG "$ARCHON_USER" "$OWNER" && done_ "$OWNER added to group $ARCHON_USER (read the factory's logs/artifacts)"; fi
if user_exists; then
    extra=$(id -nG "$ARCHON_USER" | tr ' ' '\n' | grep -vx "$ARCHON_USER" | tr '\n' ' ')
    [ -z "$extra" ] || fail user "$ARCHON_USER is in extra groups: $extra — remove them (gpasswd -d $ARCHON_USER <group>)"
fi

# ------------------------------------------------------------ 2. owner perms -
say "2. owner secrets: home 0750, secret dirs 0700, secret files 0600"
run chmod 0750 "$OWNER_HOME"
for d in .config .config/archon-cron .config/archon-cron/state .config/personal-ops .config/gh .config/opencode \
         .config/rclone .config/gcloud .config/.wrangler .wrangler .railway .ssh .gnupg .aws .docker .kube \
         .claude .claude-secondary .archon backups .local/share/keyrings .sdkman/tmp; do
    [ -d "$OWNER_HOME/$d" ] && [ ! -L "$OWNER_HOME/$d" ] && run chmod 0700 "$OWNER_HOME/$d"
done
for f in .railway/config.json .config/.wrangler/config/default.toml .claude.json .claude/settings.json \
         .archon/credential-key .archon/.env .bash_history .pgpass .netrc .git-credentials; do
    [ -f "$OWNER_HOME/$f" ] && [ ! -L "$OWNER_HOME/$f" ] && run chmod 0600 "$OWNER_HOME/$f"
done
for f in "$OWNER_HOME"/.claude.json.tmp.* "$OWNER_HOME"/.claude.json.backup*; do
    [ -f "$f" ] && run chmod 0600 "$f"
done
done_ "done (the whole home is 0750 and group $OWNER has only $OWNER in it; these are belt and braces)"

# ------------------------------------------------------------ 3. ACLs -------
say "3. ACL: $ARCHON_USER denied everything on the mounts except the engine and its home"
if ! command -v setfacl >/dev/null; then
    fail acl "setfacl missing (apt-get install acl)"
elif ! user_exists && [ "$DRY" -eq 0 ]; then
    fail acl "user $ARCHON_USER missing"
else
    deny() { run setfacl -m "u:$ARCHON_USER:---" "$1"; }
    run setfacl -m "u:$ARCHON_USER:--x" "$BASE"      # traverse to its home and the engine, never list
    n=0
    shopt -s dotglob nullglob
    for e in "$BASE"/*; do
        name=$(basename "$e")
        skip=0; for a in "${BASE_ALLOW[@]}"; do [ "$name" = "$a" ] && skip=1; done
        [ "$skip" -eq 1 ] && continue
        [ -L "$e" ] && continue               # a symlink's target is covered as its own entry
        deny "$e" && n=$((n + 1))
    done
    for e in /home/*; do [ "$e" = "$AH" ] || deny "$e"; done
    for e in /mnt/*; do
        [ "$e" = "$BASE" ] && continue
        [ -d "$e" ] || continue
        case "$(stat -f -c %T "$e" 2>/dev/null)" in fuseblk|fuse*) continue ;; esac   # NTFS: no ACLs, see step 4
        deny "$e"
    done
    shopt -u dotglob nullglob
    done_ "denied $n entries under $BASE, /home/*, /mnt/* (ext4); a directory added later is NOT covered — re-run this script (verify.sh flags it)"
fi

# ------------------------------------------------------------ 4. NTFS -------
say "4. NTFS mounts: umask=000 -> umask=077 (they hold the DB backups)"
if grep -qE '^[^#].*[[:space:]]ntfs(-3g)?[[:space:]].*umask=000' /etc/fstab; then
    run cp -a /etc/fstab "/etc/fstab.bak-archon-user-$(date +%Y%m%d%H%M%S)"
    run sed -i -E '/^[^#].*[[:space:]]ntfs(-3g)?[[:space:]]/ s/umask=000/umask=077/' /etc/fstab && done_ "fstab: umask=077 on the ntfs lines (backup alongside)"
else
    done_ "fstab has no ntfs line with umask=000 — already done"
fi
for m in /mnt/steam-slow /mnt/steam-fast; do
    mountpoint -q "$m" 2>/dev/null || continue
    mode=$(stat -c %a "$m")
    if [ $(( 8#$mode & 8#007 )) -eq 0 ]; then done_ "$m already private (mode $mode)"; continue; fi
    if [ "$DRY" -eq 1 ]; then done_ "DRY-RUN: would umount + mount $m (mode now $mode)"; continue; fi
    if umount "$m" 2>/dev/null && mount "$m"; then done_ "$m remounted (mode now $(stat -c %a "$m"))"
    else done_ "WARNING: $m busy — remount it when idle (sudo umount $m && sudo mount $m) or reboot; --cutover refuses until then"; fi
done

# ------------------------------------------------------------ 5. home -------
say "5. $ARCHON_USER's home: ~/.archon, ~/.gitconfig, ~/.claude, repos, tmp"
for d in .archon .config .config/archon-user .claude .local .local/bin .local/opt .local/share .bun .bun/bin .cache repos tmp; do
    run install -d -m 0750 -o "$ARCHON_USER" -g "$ARCHON_USER" "$AH/$d"
done
run chmod 0700 "$AH/.config/archon-user"
cfg=""
[ -r "$OWNER_HOME/.archon/config.yaml" ] && cfg=$(sed -e "s#$OWNER_HOME/.local/bin/claude#$AH/.local/bin/claude#g" \
                                                    -e "s#/mnt/ext-fast/.archon/worktrees#$AH/.archon/worktrees#g" \
                                                    -e "s#$OWNER_HOME#$AH#g" "$OWNER_HOME/.archon/config.yaml")
[ -n "$cfg" ] || cfg="{assistants: {claude: {claudeBinaryPath: $AH/.local/bin/claude}}}"
cfg="${cfg%$'\n'}"$'\n'
write_file "$AH/.archon/config.yaml" 0640 "$ARCHON_USER:$ARCHON_USER" "$cfg"
write_file "$AH/.archon/.env" 0600 "$ARCHON_USER:$ARCHON_USER" "CLAUDE_USE_GLOBAL_AUTH=true
DEFAULT_AI_ASSISTANT=claude
CLAUDE_BIN_PATH=$AH/.local/bin/claude
"
# Global workflow overrides: owned by the owner (who edits them without sudo),
# readable by archon, not writable by it.
run install -d -m 0755 -o "$OWNER" -g "$ARCHON_USER" "$AH/.archon/workflows"
for w in "$OWNER_HOME"/.archon/workflows/*.yaml; do
    [ -f "$w" ] || continue
    dst="$AH/.archon/workflows/$(basename "$w")"
    if [ -f "$dst" ]; then done_ "$dst exists — kept (edit it there; the owner's copy is no longer read)"
    else run install -m 0644 -o "$OWNER" -g "$ARCHON_USER" "$w" "$dst" && done_ "copied workflow $(basename "$w")"; fi
done
owner_git() { if [ "$(id -u)" = "$OWNER_UID" ]; then git config --global "$1"; else runuser -u "$OWNER" -- git config --global "$1"; fi; }
gname=$(owner_git user.name 2>/dev/null || echo "Archon factory")
gmail=$(owner_git user.email 2>/dev/null || echo "archon@localhost")
write_file "$AH/.gitconfig" 0640 "$ARCHON_USER:$ARCHON_USER" "[user]
	name = $gname
	email = $gmail
[init]
	defaultBranch = main
[credential \"https://github.com\"]
	helper =
	helper = !$AH/.local/bin/gh auth git-credential
[credential \"https://gist.github.com\"]
	helper =
	helper = !$AH/.local/bin/gh auth git-credential
[safe]
	# the engine checkout is the owner's; archon only reads it
	directory = $ENGINE
"
if [ -f "$AH/.claude/settings.json" ]; then done_ "$AH/.claude/settings.json exists — kept"
else write_file "$AH/.claude/settings.json" 0640 "$ARCHON_USER:$ARCHON_USER" '{
  "disableClaudeAiConnectors": true,
  "env": { "ENABLE_CLAUDEAI_MCP_SERVERS": "false" }
}
'; fi

# ------------------------------------------------------------ 6. toolchains -
say "6. toolchains for $ARCHON_USER (copied from $OWNER's installs; re-run to resync)"
copy_bin() {  # copy_bin <src> <dst>
    local src="$1" dst="$2"
    [ -e "$src" ] || { done_ "skip $(basename "$dst"): $src missing"; return 0; }
    src=$(readlink -f "$src")
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then done_ "$(basename "$dst") already current"; return 0; fi
    run install -m 0755 -o "$ARCHON_USER" -g "$ARCHON_USER" "$src" "$dst" && done_ "$(basename "$dst") <- $src"
}
sync_tree() {  # sync_tree <src-dir> <dst-dir> [rsync excludes...]
    local src="$1" dst="$2"; shift 2
    [ -d "$src" ] || { done_ "skip $dst: $src missing"; return 0; }
    src=$(readlink -f "$src")
    run install -d -m 0750 -o "$ARCHON_USER" -g "$ARCHON_USER" "$(dirname "$dst")"
    if run rsync -a --delete --chown="$ARCHON_USER:$ARCHON_USER" "$@" "$src/" "$dst/"; then done_ "$dst <- $src"
    else fail toolchain "rsync $src -> $dst failed"; fi
}
copy_bin "$OWNER_HOME/.bun/bin/bun" "$AH/.bun/bin/bun"
run ln -sfn bun "$AH/.bun/bin/bunx"
# archon's own `archon` on its PATH (the one its agents may call) -> the engine checkout
run ln -sfn "$ENGINE/packages/cli/src/cli.ts" "$AH/.bun/bin/archon"
cl=$(readlink -f "$OWNER_HOME/.local/bin/claude" 2>/dev/null || true)
if [ -n "$cl" ] && [ -f "$cl" ]; then
    v=$(basename "$cl")
    run install -d -m 0750 -o "$ARCHON_USER" -g "$ARCHON_USER" "$AH/.local/share/claude" "$AH/.local/share/claude/versions"
    copy_bin "$cl" "$AH/.local/share/claude/versions/$v"
    if [ -e "$AH/.local/bin/claude" ] && [ "$(readlink "$AH/.local/bin/claude")" != "$AH/.local/share/claude/versions/$v" ]; then
        done_ "claude: keeping archon's own (self-updated) $(readlink "$AH/.local/bin/claude")"
    else
        run ln -sfn "$AH/.local/share/claude/versions/$v" "$AH/.local/bin/claude"
    fi
else
    fail toolchain "claude binary not found at $OWNER_HOME/.local/bin/claude"
fi
copy_bin "$OWNER_HOME/.local/bin/gh" "$AH/.local/bin/gh"
copy_bin "$OWNER_HOME/.local/bin/shellcheck" "$AH/.local/bin/shellcheck"
copy_bin /snap/astral-uv/current/bin/uv "$AH/.local/bin/uv"
copy_bin /snap/astral-uv/current/bin/uvx "$AH/.local/bin/uvx"
sync_tree "$OWNER_HOME/.sdkman/candidates/java/current" "$AH/.local/opt/jdk"
sync_tree "$OWNER_HOME/.rustup" "$AH/.rustup" --exclude 'tmp/' --exclude 'downloads/'
sync_tree "$OWNER_HOME/.cargo/bin" "$AH/.cargo/bin"
sync_tree "$OWNER_HOME/snap/flutter/common/flutter" "$AH/.local/opt/flutter"
sync_tree "$OWNER_HOME/.cache/ms-playwright" "$AH/.cache/ms-playwright"
sync_tree "$OWNER_HOME/Android/Sdk" "$AH/Android/Sdk"
run chown -h "$ARCHON_USER:$ARCHON_USER" "$AH/.bun/bin/bunx" "$AH/.bun/bin/archon" "$AH/.local/bin/claude" 2>/dev/null
[ -d "$AH/.local/opt/flutter" ] && as_archon git config --global --add safe.directory "$AH/.local/opt/flutter" 2>/dev/null
true

# ------------------------------------------------------------ 7. system ----
say "7. wrapper, project list, sudoers, systemd unit"
run install -d -m 0755 -o root -g root "$ETC" "$LIBDIR" "$LIBDIR/bin"
if [ -r "$PROJECTS_SRC" ]; then
    write_file "$ETC/projects" 0644 root:root "# Factory projects archon may work on (from ops/cron/archon-projects.txt at install time).
# Adding a project: edit archon-projects.txt, add the repo to archon's PAT, re-run install.sh.
$(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$PROJECTS_SRC")
" || fail projects "could not write $ETC/projects"
else
    fail projects "$PROJECTS_SRC missing"
fi
run ln -sfn "$ENGINE/packages/cli/src/cli.ts" "$LIBDIR/bin/archon"
if [ -r "$WRAPPER_DST" ] && cmp -s "$SCRIPT_DIR/archon-as-archon" "$WRAPPER_DST"; then done_ "$WRAPPER_DST already done"
else run install -m 0755 -o root -g root "$SCRIPT_DIR/archon-as-archon" "$WRAPPER_DST" && done_ "installed $WRAPPER_DST"; fi
install_sudoers
if [ -r "$UNIT_DST" ] && cmp -s "$SCRIPT_DIR/$UNIT" "$UNIT_DST"; then done_ "$UNIT_DST already done"
else
    run install -m 0644 -o root -g root "$SCRIPT_DIR/$UNIT" "$UNIT_DST" && run systemctl daemon-reload \
        && done_ "installed $UNIT_DST (not enabled: --cutover starts it)"
    systemctl is-active -q "$UNIT" 2>/dev/null && run systemctl restart "$UNIT" && done_ "restarted running $UNIT"
fi

# ------------------------------------------------------------ summary -------
say "next"
done_ "(a) GitHub: create the fine-grained PAT (README step a), then: sudo $0 --set-gh-token"
done_ "(b) Claude: claude setup-token   then: sudo $0 --set-claude-token"
done_ "(c) sudo $0 --drain   … wait for runs to finish …   sudo $0 --cutover"
finish
