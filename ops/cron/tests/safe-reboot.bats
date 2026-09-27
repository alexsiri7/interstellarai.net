#!/usr/bin/env bats
# ops/host/safe-reboot/safe-reboot, run as a normal user against stubs
# (SAFE_REBOOT_TEST=1 skips the root check; every path is a SAFE_REBOOT_*
# override): the window, the busy checks (hold file, maintenance jobs, archon
# runs, active Claude transcripts), the drain/record/reboot sequence, the
# 72h deadline with its warning, and the restore after boot.
#
# Run: bunx bats ops/cron/tests/safe-reboot.bats

setup() {
    export T="$BATS_TMPDIR/safe-reboot-$$"
    rm -rf "$T"
    mkdir -p "$T/bin" "$T/state" "$T/home/.claude/projects/p" "$T/home/.claude/sessions" \
             "$T/home/.config/archon-cron" "$T/home/.config/systemd/user" "$T/work"
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../host/safe-reboot" && pwd)/safe-reboot"
    export PATH="$T/bin:$PATH"
    export SAFE_REBOOT_TEST=1
    export SAFE_REBOOT_OWNER="$(id -un)"
    export SAFE_REBOOT_OWNER_HOME="$T/home"
    export SAFE_REBOOT_HOMES="$T/home"
    export SAFE_REBOOT_REQUIRED="$T/reboot-required"
    export SAFE_REBOOT_STATE_DIR="$T/state"
    export SAFE_REBOOT_BOOT_ID_FILE="$T/boot_id"
    export SAFE_REBOOT_BUN="$T/bin/bun"
    export SAFE_REBOOT_REBOOT_CMD="$T/bin/reboot-stub"
    export SAFE_REBOOT_WAIT_S=2
    export SAFE_REBOOT_NOW="$(date -d 'today 03:00' +%s)"
    FLAG="$T/home/.config/archon-cron/run-as"
    printf '# Written by ops/host/archon-user/install.sh — read by ops/cron/lib/run-as.sh\nARCHON_RUN_AS=asiri\n' > "$FLAG"
    chmod 600 "$FLAG"
    echo boot-1 > "$T/boot_id"
    echo "NTFY_TOPIC=test-topic" > "$T/home/.config/archon-cron/secrets.env"
    echo 0 > "$T/runs.running"; echo 0 > "$T/runs.paused"; echo 0 > "$T/bun.calls"
    # An old transcript: nobody is working.
    touch -d '3 hours ago' "$T/home/.claude/projects/p/old.jsonl"

    # bun (archon CLI as the owner): runs from $T/runs.<status>; after
    # $T/bun.busy-after calls, one running run appears (the drain race).
    cat > "$T/bin/bun" <<STUB
#!/usr/bin/env bash
n=\$(( \$(cat "$T/bun.calls") + 1 )); echo \$n > "$T/bun.calls"
[ -e "$T/bun.fail" ] && exit 1
st=""; while [ \$# -gt 0 ]; do [ "\$1" = --status ] && st=\$2; shift; done
c=\$(cat "$T/runs.\$st")
if [ -e "$T/bun.busy-after" ] && [ "\$n" -gt "\$(cat "$T/bun.busy-after")" ] && [ "\$st" = running ]; then c=1; fi
printf '{"runs": ['; for ((i = 0; i < c; i++)); do [ \$i -gt 0 ] && printf ,; printf '{"id":"r%s"}' \$i; done; printf ']}'
STUB
    cat > "$T/bin/pgrep" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *backup-dbs*) cat "$T/pgrep.jobs" 2>/dev/null ;;
    *dpkg*) cat "$T/pgrep.apt" 2>/dev/null ;;
    *"workflow run"*) cat "$T/pgrep.runs" 2>/dev/null || echo 0 ;;
esac
exit 0
STUB
    # curl: ntfy posts are logged; anything else is archon-serve answering 200.
    cat > "$T/bin/curl" <<STUB
#!/usr/bin/env bash
title=""; body=""; prio=""
while [ \$# -gt 0 ]; do
    case "\$1" in -H) case "\$2" in Title:*) title=\${2#Title: } ;; Priority:*) prio=\${2#Priority: } ;; esac; shift ;;
                  -d) body=\$2; shift ;; -w) printf 200 ;; esac
    shift
done
[ -n "\$title" ] && printf '%s|%s|%s\n' "\$prio" "\$title" "\$body" >> "$T/ntfy.log"
exit 0
STUB
    # systemctl --user: running units from $T/units.running, properties from $T/unit.<name>.<prop>.
    cat > "$T/bin/systemctl" <<STUB
#!/usr/bin/env bash
echo "systemctl \$*" >> "$T/systemctl.log"
args=(); for a in "\$@"; do case "\$a" in --user|--no-block|-q|--quiet|--no-legend|--plain|--value) ;; -M) ;; *@) ;; *) args+=("\$a") ;; esac; done
case "\${args[0]}" in
    list-units) case "\$*" in *running,activating*) cat "$T/units.running" 2>/dev/null ;; esac ;;
    show) u=\${args[1]}; p=\${args[3]}; cat "$T/unit.\$u.\$p" 2>/dev/null ;;
    is-system-running) echo running ;;
    is-active) exit 1 ;;
esac
exit 0
STUB
    cat > "$T/bin/tmux" <<STUB
#!/usr/bin/env bash
echo "tmux \$*" >> "$T/tmux.log"
case "\$1" in
    list-panes) printf '%%5\tmain\t2\twork\n' ;;
    has-session) [ -e "$T/tmux.up" ] ;;
    list-windows) printf '0 work\n' ;;
esac
STUB
    cat > "$T/bin/systemd-run" <<STUB
#!/usr/bin/env bash
echo "systemd-run \$*" >> "$T/systemd-run.log"; touch "$T/tmux.up"
STUB
    printf '#!/usr/bin/env bash\necho reboot >> "%s/reboot.log"\nexit "${STUB_REBOOT_RC:-0}"\n' "$T" > "$T/bin/reboot-stub"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sync"
    chmod +x "$T"/bin/*
}

teardown() { rm -rf "$T"; }

flag() { sed -n 's/^ARCHON_RUN_AS=//p' "$FLAG"; }
pending() { touch "$T/reboot-required"; }
at() { export SAFE_REBOOT_NOW="$(date -d "$1" +%s)"; }

# A live interactive claude session (this test's own shell stands in for it)
# in tmux pane %5, plus one factory (sdk-ts) session that must be ignored.
add_sessions() {
    local start; start=$(awk '{print $22}' "/proc/$$/stat")
    printf '{"pid":%s,"sessionId":"11111111-2222-3333-4444-555555555555","cwd":"%s","procStart":"%s","kind":"interactive","entrypoint":"cli","tmux":"main:@1.%%5"}' \
        "$$" "$T/work" "$start" > "$T/home/.claude/sessions/$$.json"
    printf '{"pid":%s,"sessionId":"99999999-0000-0000-0000-000000000000","cwd":"/x","procStart":"%s","kind":"interactive","entrypoint":"sdk-ts"}' \
        "$$" "$start" > "$T/home/.claude/sessions/1.json"
}
# A transient unit (the NAS first run) whose ExecStart matches a persistent one.
add_units() {
    echo "cloud-mirror-firstrun.service loaded active running x" > "$T/units.running"
    echo "archon-serve.service loaded active running x" >> "$T/units.running"
    echo "/run/user/1000/systemd/transient/cloud-mirror-firstrun.service" > "$T/unit.cloud-mirror-firstrun.service.FragmentPath"
    echo transient > "$T/unit.cloud-mirror-firstrun.service.UnitFileState"
    echo "{ path=/opt/cm.sh ; argv[]=/opt/cm.sh ; ignore_errors=no }" > "$T/unit.cloud-mirror-firstrun.service.ExecStart"
    touch "$T/home/.config/systemd/user/cloud-mirror.service"
    echo "{ path=/opt/cm.sh ; argv[]=/opt/cm.sh ; ignore_errors=no }" > "$T/unit.cloud-mirror.service.ExecStart"
}

@test "no reboot pending: nothing happens" {
    run "$SCRIPT" gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"no reboot pending"* ]]
    [ ! -e "$T/reboot.log" ]
    [ "$(flag)" = asiri ]
}

@test "pending but outside the window: no reboot; one daily ntfy from 07:00" {
    pending
    at 'today 01:00'
    run "$SCRIPT" gate
    [[ "$output" == *"outside the window"* ]]
    [ ! -e "$T/reboot.log" ]
    [ ! -e "$T/ntfy.log" ]
    at 'today 09:00'
    run "$SCRIPT" gate
    [ "$(grep -c 'Reboot pending on' "$T/ntfy.log")" -eq 1 ]
    run "$SCRIPT" gate
    [ "$(grep -c 'Reboot pending on' "$T/ntfy.log")" -eq 1 ]
}

@test "idle in the window: drain, record, ntfy, reboot" {
    pending; add_sessions; add_units
    run "$SCRIPT" gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"decision: reboot now"* ]]
    [ "$(cat "$T/reboot.log")" = reboot ]
    [ "$(flag)" = drain ]
    grep -q safe-reboot "$FLAG"
    [ "$(stat -c %a "$FLAG")" = 600 ]
    grep -qx 'flag_prev=asiri' "$T/state/restore/meta"
    grep -qx 'flag_written=1' "$T/state/restore/meta"
    # transient NAS run -> its persistent twin; archon-serve is handled separately
    [ "$(cat "$T/state/restore/services.tsv")" = "$(printf 'cloud-mirror-firstrun.service\tstart\tcloud-mirror.service')" ]
    # the cli session with its tmux place; the sdk-ts one is not recorded
    [ "$(wc -l < "$T/state/restore/sessions.tsv")" -eq 1 ]
    IFS=$'\t' read -r _ sid cwd ts widx wname _ < "$T/state/restore/sessions.tsv"
    [ "$sid" = 11111111-2222-3333-4444-555555555555 ]
    [ "$cwd" = "$T/work" ] && [ "$ts" = main ] && [ "$widx" = 2 ] && [ "$wname" = work ]
    grep -q '^default|Rebooting' "$T/ntfy.log"
}

@test "the hold file blocks, even past the deadline" {
    pending; mkdir -p "$T/home/.config/safe-reboot"; echo "demo tomorrow" > "$T/home/.config/safe-reboot/hold"
    printf '%s boot-1\n' "$(( SAFE_REBOOT_NOW - 100 * 3600 ))" > "$T/state/pending-since"
    run "$SCRIPT" gate
    [[ "$output" == *"hold file"*"demo tomorrow"* ]]
    [[ "$output" == *"hard blocker"* ]]
    [ ! -e "$T/reboot.log" ]
    [ "$(flag)" = asiri ]
}

@test "a DB backup or apt run blocks, even past the deadline" {
    pending
    printf '%s boot-1\n' "$(( SAFE_REBOOT_NOW - 100 * 3600 ))" > "$T/state/pending-since"
    echo "123 /bin/bash /mnt/ext-fast/interstellarai.net/ops/cron/backup-dbs.sh" > "$T/pgrep.jobs"
    run "$SCRIPT" gate
    [[ "$output" == *"maintenance job running"*"backup-dbs.sh"* ]]
    [ ! -e "$T/reboot.log" ]
    rm "$T/pgrep.jobs"; echo "456 /usr/bin/dpkg --configure -a" > "$T/pgrep.apt"
    run "$SCRIPT" gate
    [[ "$output" == *"apt/dpkg running"* ]]
    [ ! -e "$T/reboot.log" ]
}

@test "soft blockers: an active transcript, a paused archon run, an unreadable run list" {
    pending
    touch "$T/home/.claude/projects/p/now.jsonl"
    run "$SCRIPT" gate
    [[ "$output" == *"Claude session active"*"now.jsonl"* ]]
    [[ "$output" == *"busy, not overdue"* ]]
    rm "$T/home/.claude/projects/p/now.jsonl"
    echo 1 > "$T/runs.paused"
    run "$SCRIPT" gate
    [[ "$output" == *"archon: 1 paused run(s)"* ]]
    echo 0 > "$T/runs.paused"; touch "$T/bun.fail"
    run "$SCRIPT" gate
    [[ "$output" == *"query failed"* ]]
    [ ! -e "$T/reboot.log" ]
    [ "$(flag)" = asiri ]
}

@test "a drain someone else set is left alone and restored as drain" {
    pending
    printf '# Written by ops/host/archon-user/install.sh — read by ops/cron/lib/run-as.sh\nARCHON_RUN_AS=drain\n' > "$FLAG"
    cp "$FLAG" "$T/flag.before"
    run "$SCRIPT" gate
    [ -e "$T/reboot.log" ]
    cmp "$FLAG" "$T/flag.before"
    grep -qx 'flag_written=0' "$T/state/restore/meta"
    echo boot-2 > "$T/boot_id"
    run "$SCRIPT" restore
    cmp "$FLAG" "$T/flag.before"
}

@test "archon run launched between the check and the drain: flag put back, no reboot" {
    pending
    echo 2 > "$T/bun.busy-after"          # the two pre-drain queries are idle
    run "$SCRIPT" gate
    [[ "$output" == *"archon became busy after the drain"* ]]
    [ ! -e "$T/reboot.log" ]
    [ "$(flag)" = asiri ]
    [ ! -e "$T/state/restore" ]
}

@test "reboot command fails: flag put back, ntfy" {
    pending
    STUB_REBOOT_RC=1 run "$SCRIPT" gate
    [ "$(flag)" = asiri ]
    grep -q 'Reboot FAILED' "$T/ntfy.log"
}

@test "deadline: warn first, wait the grace period, then force through soft blockers" {
    pending
    printf '%s boot-1\n' "$(( SAFE_REBOOT_NOW - 73 * 3600 ))" > "$T/state/pending-since"
    touch "$T/home/.claude/projects/p/now.jsonl"
    run "$SCRIPT" gate
    [[ "$output" == *"warning now"* ]]
    grep -q '^urgent|Forcing reboot' "$T/ntfy.log"
    [ ! -e "$T/reboot.log" ]
    export SAFE_REBOOT_NOW=$(( SAFE_REBOOT_NOW + 300 ))
    run "$SCRIPT" gate
    [[ "$output" == *"grace period"* ]]
    [ ! -e "$T/reboot.log" ]
    export SAFE_REBOOT_NOW=$(( SAFE_REBOOT_NOW + 600 ))
    run "$SCRIPT" gate
    [[ "$output" == *"forcing the reboot"* ]]
    [ -e "$T/reboot.log" ]
    grep -qx 'forced=1' "$T/state/restore/meta"
}

@test "restore after boot: flag back, services and sessions restarted, health ntfy" {
    pending; add_sessions; add_units
    run "$SCRIPT" gate
    [ "$(flag)" = drain ]
    echo boot-2 > "$T/boot_id"; rm -f "$T/systemctl.log" "$T/ntfy.log"
    run "$SCRIPT" restore
    [ "$status" -eq 0 ]
    [ "$(flag)" = asiri ]
    grep -q 'start archon-serve.service' "$T/systemctl.log"
    grep -q 'start --no-block cloud-mirror.service' "$T/systemctl.log"
    grep -q 'Type=forking /usr/bin/tmux new-session -d -s main -n work -c '"$T/work" "$T/systemd-run.log"
    grep -q 'send-keys -t =main:0 unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SSE_PORT; claude --resume 11111111-2222-3333-4444-555555555555 Enter' "$T/tmux.log"
    grep -q 'back up after reboot|Back up after reboot. flag back to asiri; restored services: cloud-mirror.service; Claude sessions: main:work' "$T/ntfy.log"
    [ ! -e "$T/state/restore" ] && [ -d "$T/state/restored.last" ]
    # consumed: a second run (or an unplanned boot) replays nothing
    rm -f "$T/tmux.log"
    run "$SCRIPT" restore
    [[ "$output" == *"nothing recorded"* ]]
    [ ! -e "$T/tmux.log" ]
}

@test "restore leaves a flag the owner changed by hand" {
    pending
    run "$SCRIPT" gate
    printf 'ARCHON_RUN_AS=archon\n' > "$FLAG"
    echo boot-2 > "$T/boot_id"
    run "$SCRIPT" restore
    [ "$(flag)" = archon ]
    [[ "$output" == *"changed by hand"* ]]
}

@test "a recorded reboot that never happened undoes the drain on the next tick" {
    pending
    STUB_REBOOT_RC=0 run "$SCRIPT" gate
    [ "$(flag)" = drain ]
    touch -d '30 minutes ago' "$T/state/restore/meta"
    export SAFE_REBOOT_NOW=$(date +%s)
    run "$SCRIPT" gate
    [ "$(flag)" = asiri ]
    grep -q 'Reboot did not happen' "$T/ntfy.log"
}

@test "status changes nothing and sends nothing" {
    pending; add_sessions
    run "$SCRIPT" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"decision: reboot now"* ]]
    [[ "$output" == *"would resume Claude sessions"*"11111111-2222-3333-4444-555555555555"* ]]
    [ ! -e "$T/reboot.log" ] && [ ! -e "$T/ntfy.log" ]
    [ "$(flag)" = asiri ]
    [ -z "$(ls -A "$T/state")" ]
}
