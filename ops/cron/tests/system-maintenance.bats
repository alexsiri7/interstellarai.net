#!/usr/bin/env bats
# End-to-end tests for ops/cron/system-maintenance.sh with stubbed sudo,
# apt-get, apt, snap, journalctl, smartctl, lsblk and curl.
#
# Run: bunx bats ops/cron/tests/system-maintenance.bats

setup() {
    export T="$BATS_TMPDIR/system-maintenance-$$"
    mkdir -p "$T/bin" "$T/state"
    CRON_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$CRON_DIR/system-maintenance.sh"
    export PATH="$T/bin:$PATH"
    export HOME="$T"
    export SYSTEM_MAINT_STATE_DIR="$T/state"
    export SYSTEM_MAINT_REBOOT_REQUIRED="$T/reboot-required"
    export ARCHON_CRON_SECRETS="$T/secrets.env"
    echo 'NTFY_TOPIC=test-topic' > "$T/secrets.env"
    export STUB_ARGV="$T/argv"        # every privileged command, one per line
    export NTFY_LOG="$T/ntfy"         # one line per ntfy: "<title> | <body>"
    export STUB_SMART_FAIL=""         # device names whose smartctl -H is not PASSED
    export STUB_SUDO_REFUSE=0         # 1: sudo -n behaves as if no sudoers entry matched

    # sudo: the script calls full paths (/usr/bin/apt-get ...). Re-dispatch on
    # the basename so the stubs on PATH answer, and log the exact argv.
    cat > "$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-n" ] && shift
if [ "${STUB_SUDO_REFUSE:-0}" = "1" ]; then echo "sudo: a password is required" >&2; exit 1; fi
printf '%s\n' "$*" >> "$STUB_ARGV"
cmd=$(basename "$1"); shift
exec "$cmd" "$@"
STUB
    cat > "$T/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *upgrade*) touch "$T/upgraded" ;;
esac
exit "${STUB_APT_RC:-0}"
STUB
    cat > "$T/bin/apt" <<'STUB'
#!/usr/bin/env bash
echo "Listing..."
if [ ! -f "$T/upgraded" ]; then
    echo "libc6/noble-updates 2.39-0ubuntu8.6 amd64 [upgradable from: 2.39-0ubuntu8.4]"
    echo "nodejs/nodistro 22.20.0-1nodesource1 amd64 [upgradable from: 20.20.2-1nodesource1]"
    echo "vim/noble-updates 2:9.1.0016-1ubuntu7.9 amd64 [upgradable from: 2:9.1.0016-1ubuntu7.8]"
fi
STUB
    cat > "$T/bin/snap" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
cat <<'LIST'
Name       Version   Rev    Tracking       Publisher    Notes
astral-uv  0.12.6    1682   latest/stable  lengau       classic
astral-uv  0.12.3    1662   latest/stable  lengau       disabled,classic
core22     20260410  2437   latest/stable  canonical**  base
core22     20260225  2411   latest/stable  canonical**  base,disabled
LIST
fi
exit 0
STUB
    cat > "$T/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--disk-usage" ] && echo "Archived and active journals take up 2.5G in the file system."
exit 0
STUB
    cat > "$T/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
printf 'loop0 loop\nsda disk\nsdb disk\nnvme0n1 disk\n'
STUB
    cat > "$T/bin/smartctl" <<'STUB'
#!/usr/bin/env bash
dev="${2##/dev/}"
case " $STUB_SMART_FAIL " in
    *" $dev "*) echo "SMART overall-health self-assessment test result: FAILED!"; echo "Drive failure expected in less than 24 hours. SAVE ALL DATA."; exit 8 ;;
esac
echo "SMART overall-health self-assessment test result: PASSED"
STUB
    cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
title=""; body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -H) case "$2" in Title:*) title="${2#Title: }" ;; esac; shift ;;
        -d) body="$2"; shift ;;
    esac
    shift
done
echo "$title | $body" >> "$NTFY_LOG"
STUB
    chmod +x "$T"/bin/*
}

teardown() {
    rm -rf "$T"
}

status_field() { grep "^$1=" "$T/state/system-maintenance-status" | cut -d= -f2-; }

@test "all good: every step runs through sudo -n, status ok, no ntfy" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_LOG" ]
    [ "$(status_field last_run_status)" = "ok" ]
    [ "$(status_field last_run_failed)" = "" ]
    [ "$(status_field last_ok)" = "$(status_field last_run)" ]
    [[ "$output" == *"apt: 3 package(s) upgradable before"* ]]
    [[ "$output" == *"apt: 0 package(s) upgradable after (was 3)"* ]]
    grep -qx '/usr/bin/apt-get update' "$STUB_ARGV"
    grep -qx '/usr/bin/apt-get -y -o Dpkg::Options::=--force-confold upgrade' "$STUB_ARGV"
    grep -qx '/usr/bin/apt-get -y autoremove' "$STUB_ARGV"
    grep -qx '/usr/bin/snap remove --revision=1662 astral-uv' "$STUB_ARGV"
    grep -qx '/usr/bin/snap remove --revision=2411 core22' "$STUB_ARGV"
    [ "$(grep -c '/usr/bin/snap remove' "$STUB_ARGV")" -eq 2 ]
    grep -qx '/usr/bin/journalctl --vacuum-size=500M' "$STUB_ARGV"
    grep -qx '/usr/sbin/smartctl -H /dev/sda' "$STUB_ARGV"
    grep -qx '/usr/sbin/smartctl -H /dev/sdb' "$STUB_ARGV"
    grep -qx '/usr/sbin/smartctl -H /dev/nvme0n1' "$STUB_ARGV"
    ! grep -q 'loop0' "$STUB_ARGV"
    [[ "$output" == *"smart: checked 3 disk(s)"* ]]
    ! grep -qv '^/usr/' "$STUB_ARGV"        # nothing privileged ran without a full path
}

@test "SMART FAILED on one disk: urgent ntfy naming the device, run marked failed" {
    export STUB_SMART_FAIL="sdb"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -q '^SMART: /dev/sdb not PASSED' "$NTFY_LOG"
    grep -q 'FAILED' "$NTFY_LOG"
    ! grep -q '/dev/sda' "$NTFY_LOG"
    [ "$(status_field last_run_status)" = "failed" ]
    [[ "$(status_field last_run_failed)" == *"smart:/dev/sdb"* ]]
    [[ "$output" == *"smart: /dev/sda PASSED"* ]]
    [[ "$output" == *"smart: /dev/nvme0n1 PASSED"* ]]
}

@test "sudo -n refusing (no sudoers entry): fails loud, status failed, ntfy names the fix" {
    export STUB_SUDO_REFUSE=1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo -n refused"* ]]
    [[ "$output" == *"ops/host/install.sh"* ]]
    [ "$(status_field last_run_status)" = "failed" ]
    [ "$(status_field last_ok)" = "0" ]
    failed=$(status_field last_run_failed)
    [[ "$failed" == *"apt"* ]]
    [[ "$failed" == *"snap"* ]]
    [[ "$failed" == *"journal"* ]]
    [[ "$failed" == *"smart:/dev/sda"* ]]
    grep -q '^System maintenance FAILED' "$NTFY_LOG"
    # apt update refused → upgrade/autoremove are not attempted
    [ ! -f "$T/upgraded" ]
}

@test "a failed run keeps the previous last_ok" {
    printf 'last_run=100\nlast_run_status=ok\nlast_run_failed=\nlast_ok=100\n' > "$T/state/system-maintenance-status"
    export STUB_APT_RC=100
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$(status_field last_run_status)" = "failed" ]
    [ "$(status_field last_ok)" = "100" ]
    [[ "$(status_field last_run_failed)" == "apt"* ]]
}

@test "reboot-required: one ntfy, second run on the same kernel is silent, cleared when it goes away" {
    touch "$T/reboot-required"
    echo linux-image-7.0.0-32-generic > "$T/reboot-required.pkgs"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^Reboot pending' "$NTFY_LOG")" -eq 1 ]
    grep -q 'reboot pending; auto-reboot at 04:30' "$NTFY_LOG"
    grep -q 'linux-image-7.0.0-32-generic' "$NTFY_LOG"
    [ "$(cat "$T/state/system-maintenance-reboot-notified")" = "$(uname -r)" ]

    rm -f "$NTFY_LOG"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_LOG" ]
    [[ "$output" == *"already notified for running kernel"* ]]

    # a different kernel was running when the marker was written → notify again
    echo "0.0.0-previous" > "$T/state/system-maintenance-reboot-notified"
    run "$SCRIPT"
    [ "$(grep -c '^Reboot pending' "$NTFY_LOG")" -eq 1 ]

    rm -f "$NTFY_LOG" "$T/reboot-required"
    run "$SCRIPT"
    [ ! -f "$NTFY_LOG" ]
    [ ! -f "$T/state/system-maintenance-reboot-notified" ]
    [[ "$output" == *"marker cleared"* ]]
}

@test "SYSTEM_MAINT_SMART_SKIP leaves a disk out of the SMART check" {
    export SYSTEM_MAINT_SMART_SKIP="sda"
    export STUB_SMART_FAIL="sda"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_LOG" ]
    ! grep -q '/dev/sda' "$STUB_ARGV"
    [[ "$output" == *"smart: /dev/sda skipped"* ]]
}

@test "missing NTFY_TOPIC fails before doing anything" {
    : > "$T/secrets.env"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -f "$STUB_ARGV" ]
}
