#!/usr/bin/env bats
# Unit tests for check_system_maintenance in ops/cron/pipeline-health-cron.sh:
# alert once per new failure when the weekly system-maintenance.sh failed or has
# not run, and escalate it (manual-review issue + Lachesis question) until a run
# succeeds.
#
# Run: bunx bats ops/cron/tests/pipeline-health-system-maintenance.bats

setup() {
    export STATE_DIR="$BATS_TMPDIR/system-maintenance-state-$$"
    mkdir -p "$STATE_DIR"
    export NTFY_SENTINEL="$STATE_DIR/ntfy-called"
    export GH_ARGV="$STATE_DIR/gh-argv"     # one line per gh call
    export ASKED="$STATE_DIR/asked"         # one line per lachesis_ask_once call
    export STUB_GH_FAIL=0 STUB_GH_CLOSE_FAIL=0 STUB_ASK_FAIL=0 STUB_TOKEN=t
    export LOG_DIR="/logs"
    SYSTEM_MAINT_REPO="alexsiri7/interstellarai.net"

    log() { echo "$*"; }
    export -f log
    notify() { echo "$1 | $2" > "$NTFY_SENTINEL"; }
    export -f notify
    lachesis_token() { printf '%s' "$STUB_TOKEN"; }
    lachesis_ask_once() {
        [ "$STUB_ASK_FAIL" = 1 ] && return 1
        printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$ASKED"
    }
    gh() {
        printf '%s\n' "$*" >> "$GH_ARGV"
        case "$1 $2" in
            "issue create") [ "$STUB_GH_FAIL" = 1 ] && return 1
                            echo "https://github.com/alexsiri7/interstellarai.net/issues/901" ;;
            "issue close") [ "$STUB_GH_CLOSE_FAIL" = 1 ] && return 1 ;;
        esac
        return 0
    }

    SCRIPT_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pipeline-health-cron.sh"
    local fn
    for fn in check_system_maintenance escalate_system_maintenance close_escalation; do
        # shellcheck disable=SC1090
        source <(awk -v f="$fn" '$0 ~ "^" f "\\(\\)" {p=1} p{print} p && /^}$/{p=0}' "$SCRIPT_FILE")
    done
}

teardown() {
    rm -rf "$STATE_DIR"
}

write_status() {  # last_run_age_seconds status failed_csv last_ok_age_seconds
    local now; now=$(date +%s)
    printf 'last_run=%s\nlast_run_status=%s\nlast_run_failed=%s\nlast_ok=%s\n' \
        "$(( now - $1 ))" "$2" "$3" "$(( now - $4 ))" > "$STATE_DIR/system-maintenance-status"
}

@test "fresh successful run: no alert, no marker" {
    write_status 86400 ok "" 86400
    run check_system_maintenance
    [ "$status" -eq 0 ]
    [ ! -f "$NTFY_SENTINEL" ]
    [ ! -f "$STATE_DIR/system-maintenance-alerted" ]
}

@test "last run failed alerts once and names the failed steps" {
    write_status 3600 failed "apt,smart:/dev/sdb" $((8 * 86400))
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
    grep -q 'apt,smart:/dev/sdb' "$NTFY_SENTINEL"
    grep -q 'install.sh' "$NTFY_SENTINEL"
    [ -f "$STATE_DIR/system-maintenance-alerted" ]
    rm -f "$NTFY_SENTINEL"
    run check_system_maintenance
    [[ "$output" == *"system-maintenance:"* ]]
    [ ! -f "$NTFY_SENTINEL" ]           # marker suppresses the repeat
    [ "$(grep -c '^issue create' "$GH_ARGV")" -eq 1 ]
    [ "$(wc -l < "$ASKED")" -eq 2 ]     # the stub has no once-marker: the key decides
    [ "$(cut -d'|' -f3 "$ASKED" | sort -u)" = "sysmaint-apt+smart__dev_sdb" ]
}

@test "no successful run for longer than 8 days alerts" {
    write_status $((9 * 86400)) ok "" $((9 * 86400))
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
    [[ "$output" == *"9d ago (limit 8d)"* ]]
}

@test "a successful run 7 days ago is within the limit" {
    write_status $((7 * 86400)) ok "" $((7 * 86400))
    run check_system_maintenance
    [ ! -f "$NTFY_SENTINEL" ]
}

@test "missing status file (never run) alerts" {
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
    [[ "$output" == *"no successful system-maintenance run recorded"* ]]
}

@test "recovery clears the marker" {
    touch "$STATE_DIR/system-maintenance-alerted"
    write_status 60 ok "" 60
    run check_system_maintenance
    [[ "$output" == *"recovered"* ]]
    [ ! -f "$STATE_DIR/system-maintenance-alerted" ]
}

@test "a different failure alerts again; the same set stays quiet" {
    write_status 3600 failed "smart:/dev/sdd" 60
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
    rm -f "$NTFY_SENTINEL"
    write_status 3600 failed "apt,smart:/dev/sdd" 60
    run check_system_maintenance
    grep -q 'apt,smart:/dev/sdd' "$NTFY_SENTINEL"
    rm -f "$NTFY_SENTINEL"
    run check_system_maintenance
    [ ! -f "$NTFY_SENTINEL" ]
}

@test "a step that recovers and fails again alerts again" {
    write_status 3600 failed "apt" 60
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]; rm -f "$NTFY_SENTINEL"
    write_status 3600 failed "smart:/dev/sdb" 60
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]; rm -f "$NTFY_SENTINEL"
    write_status 3600 failed "apt" 60
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
}

@test "a pre-#176 empty marker holds no tokens: the ongoing failure alerts once more" {
    touch "$STATE_DIR/system-maintenance-alerted"
    write_status 3600 failed "smart:/dev/sdd" 60
    run check_system_maintenance
    [ -f "$NTFY_SENTINEL" ]
    [ "$(cat "$STATE_DIR/system-maintenance-alerted")" = "smart:/dev/sdd" ]
    [ -s "$ASKED" ]
}

@test "the first alert files a manual-review issue and asks about it in Lachesis" {
    write_status 3600 failed "smart:/dev/sdb" 60
    run check_system_maintenance
    grep -q '^label create --repo alexsiri7/interstellarai.net manual-review' "$GH_ARGV"
    grep -q '^issue create --repo alexsiri7/interstellarai.net --title host maintenance failing on .* --label manual-review' "$GH_ARGV"
    grep -qF '**Kind**: system-maintenance' "$GH_ARGV"
    grep -qF 'Auto-filed by `pipeline-health-cron.sh`' "$GH_ARGV"
    [ "$(cat "$STATE_DIR/system-maintenance-issue")" = "901" ]
    [ "$(cut -d'|' -f1-3 "$ASKED")" = "interstellarai.net|901|sysmaint-smart__dev_sdb" ]
    grep -q 'smart:/dev/sdb' "$ASKED"
    : > "$GH_ARGV"
    run check_system_maintenance
    ! grep -q '^issue create' "$GH_ARGV"
}

@test "a failed issue create is retried next tick, and nothing is asked meanwhile" {
    write_status 3600 failed "apt" 60
    STUB_GH_FAIL=1 run check_system_maintenance
    [[ "$output" == *"retrying next tick"* ]]
    [ ! -f "$STATE_DIR/system-maintenance-issue" ]
    [ ! -f "$ASKED" ]
    run check_system_maintenance
    [ "$(cat "$STATE_DIR/system-maintenance-issue")" = "901" ]
    [ -s "$ASKED" ]
}

@test "a failed Lachesis question is logged for the next tick" {
    write_status 3600 failed "apt" 60
    STUB_ASK_FAIL=1 run check_system_maintenance
    [[ "$output" == *"could not record the question in Lachesis"* ]]
    [ "$(cat "$STATE_DIR/system-maintenance-issue")" = "901" ]
}

@test "no Lachesis token: the issue is still filed, no question asked" {
    write_status 3600 failed "apt" 60
    STUB_TOKEN="" run check_system_maintenance
    [[ "$output" == *"no LACHESIS_FACTORY_TOKEN"* ]]
    [ "$(cat "$STATE_DIR/system-maintenance-issue")" = "901" ]
    [ ! -f "$ASKED" ]
}

@test "recovery closes the escalation issue, and keeps it for a retry when the close fails" {
    echo 901 > "$STATE_DIR/system-maintenance-issue"
    write_status 60 ok "" 60
    STUB_GH_CLOSE_FAIL=1 run check_system_maintenance
    [ -f "$STATE_DIR/system-maintenance-issue" ]
    run check_system_maintenance
    grep -q '^issue close 901 --repo alexsiri7/interstellarai.net' "$GH_ARGV"
    [ ! -f "$STATE_DIR/system-maintenance-issue" ]
}
