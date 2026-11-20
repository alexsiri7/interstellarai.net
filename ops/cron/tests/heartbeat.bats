#!/usr/bin/env bats
# Unit tests for ops/cron/lib/heartbeat.sh
#
# Run: bats ops/cron/tests/heartbeat.bats

setup() {
    T="$BATS_TMPDIR/heartbeat-$$"
    mkdir -p "$T"
    export HOME="$T/home"
    export HEARTBEAT_STAMP_DIR="$T/stamps"
    export HEARTBEAT_STATE_DIR="$T/state"
    export ARCHON_THROTTLE_CONF="$T/throttle.conf"
    mkdir -p "$HOME" "$HEARTBEAT_STAMP_DIR"
    echo "TICK_INTERVAL_MINUTES=59" > "$ARCHON_THROTTLE_CONF"
    export NTFY_TOPIC="test-topic"
    export CURL_ARGV="$T/curl-argv"
    curl() { printf '%s\n' "$*" >> "$CURL_ARGV"; return "${CURL_RC:-0}"; }
    export -f curl

    unset _ARCHON_THROTTLE_SH _ARCHON_HEARTBEAT_SH
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$SCRIPT_DIR/lib/heartbeat.sh"
}

teardown() {
    rm -rf "$T"
}

# stamp <name> <age in seconds>
stamp() { echo $(( $(date +%s) - $2 )) > "$HEARTBEAT_STAMP_DIR/$1.last_run"; }

curl_calls() { [ -f "$CURL_ARGV" ] && wc -l < "$CURL_ARGV" || echo 0; }

# ── expected cadence ─────────────────────────────────────────────────

@test "expected minutes follow the throttle: T=59 gives 60 for 15- and 30-minute crons" {
    [ "$(heartbeat_expected_minutes 15)" = 60 ]
    [ "$(heartbeat_expected_minutes 30)" = 60 ]
}

@test "expected minutes: T=14 on a 15-minute cron is every slot; T=60 on 30 is 60" {
    echo "TICK_INTERVAL_MINUTES=14" > "$ARCHON_THROTTLE_CONF"
    [ "$(heartbeat_expected_minutes 15)" = 15 ]
    echo "TICK_INTERVAL_MINUTES=60" > "$ARCHON_THROTTLE_CONF"
    [ "$(heartbeat_expected_minutes 30)" = 60 ]
}

@test "expected minutes use the 60-minute default when the conf is missing" {
    export ARCHON_THROTTLE_CONF="$T/nonexistent.conf"
    [ "$(heartbeat_expected_minutes 15)" = 60 ]
}

# ── staleness ────────────────────────────────────────────────────────

@test "a fresh stamp raises nothing" {
    stamp issue-pickup $(( 30 * 60 ))
    run heartbeat_watch issue-pickup 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 0 ]
    [ ! -f "$HEARTBEAT_STATE_DIR/issue-pickup-alerted" ]
}

@test "one missed tick is not enough to alert" {
    # T=59, P=15: E=60, limit 2E+P = 135 min.
    stamp pr-maintenance $(( 135 * 60 - 60 ))
    run heartbeat_watch pr-maintenance 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 0 ]
    [ ! -f "$HEARTBEAT_STATE_DIR/pr-maintenance-alerted" ]
}

@test "two missed ticks alert once, naming the cron" {
    stamp pr-maintenance $(( 135 * 60 + 60 ))
    run heartbeat_watch pr-maintenance 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 1 ]
    grep -q "Factory cron silent: pr-maintenance" "$CURL_ARGV"
    grep -qF "heartbeat $HEARTBEAT_STAMP_DIR/pr-maintenance.last_run" "$CURL_ARGV"
    grep -q "ntfy.sh/test-topic" "$CURL_ARGV"
    [ -f "$HEARTBEAT_STATE_DIR/pr-maintenance-alerted" ]

    run heartbeat_watch pr-maintenance 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 1 ]
}

@test "a missing stamp alerts as never ticked" {
    run heartbeat_watch pipeline-health 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"pipeline-health has never ticked"* ]]
    [ "$(curl_calls)" -eq 1 ]
    [ -f "$HEARTBEAT_STATE_DIR/pipeline-health-alerted" ]
}

@test "a failed ntfy leaves no marker and is retried on the next watch" {
    stamp issue-pickup $(( 4 * 3600 ))
    CURL_RC=22 run heartbeat_watch issue-pickup 15
    [ "$status" -eq 0 ]
    [[ "$output" == *"ntfy failed, retrying next tick"* ]]
    [ ! -f "$HEARTBEAT_STATE_DIR/issue-pickup-alerted" ]

    run heartbeat_watch issue-pickup 15
    [ "$(curl_calls)" -eq 2 ]
    [ -f "$HEARTBEAT_STATE_DIR/issue-pickup-alerted" ]
}

@test "a cron that ticks again clears the marker and logs recovered" {
    mkdir -p "$HEARTBEAT_STATE_DIR"
    touch "$HEARTBEAT_STATE_DIR/issue-pickup-alerted"
    stamp issue-pickup 120
    run heartbeat_watch issue-pickup 15
    [ "$status" -eq 0 ]
    [[ "$output" == *"issue-pickup recovered"* ]]
    [ ! -f "$HEARTBEAT_STATE_DIR/issue-pickup-alerted" ]
    [ "$(curl_calls)" -eq 0 ]
}

@test "without NTFY_TOPIC the alert is logged only and marked" {
    export NTFY_TOPIC=""
    run heartbeat_watch pr-maintenance 15
    [ "$status" -eq 0 ]
    [[ "$output" == *"NTFY_TOPIC not set — logged only"* ]]
    [ "$(curl_calls)" -eq 0 ]
    [ -f "$HEARTBEAT_STATE_DIR/pr-maintenance-alerted" ]
}

@test "without an override the watch reads the stamp should_tick writes" {
    unset HEARTBEAT_STAMP_DIR _ARCHON_HEARTBEAT_SH
    source "$SCRIPT_DIR/lib/heartbeat.sh"
    should_tick issue-pickup
    run heartbeat_watch issue-pickup 15
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 0 ]
}

# ── heartbeat by mtime ───────────────────────────────────────────────

# touch_aged <file> <age in seconds>
touch_aged() { touch -d "@$(( $(date +%s) - $2 ))" "$1"; }

@test "mtime: a file written within two missed ticks raises nothing" {
    # P=30: E=P, limit 2E+P = 90 min.
    touch_aged "$T/ops-pr-review.log" $(( 90 * 60 - 60 ))
    run heartbeat_watch_mtime ops-pr-review 30 "$T/ops-pr-review.log"
    [ "$status" -eq 0 ]
    [ "$(curl_calls)" -eq 0 ]
    [ ! -f "$HEARTBEAT_STATE_DIR/ops-pr-review-alerted" ]
}

@test "mtime: a file older than two missed ticks alerts once, naming the cron" {
    touch_aged "$T/ops-pr-review.log" $(( 90 * 60 + 60 ))
    run heartbeat_watch_mtime ops-pr-review 30 "$T/ops-pr-review.log"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ops-pr-review last ticked 91 min ago; expected every 30 min, alert after 90"* ]]
    [ "$(curl_calls)" -eq 1 ]
    grep -q "Factory cron silent: ops-pr-review" "$CURL_ARGV"

    run heartbeat_watch_mtime ops-pr-review 30 "$T/ops-pr-review.log"
    [ "$(curl_calls)" -eq 1 ]
}

@test "mtime: a missing file alerts as never ticked, and a fresh write recovers" {
    run heartbeat_watch_mtime morning-pass 1440 "$T/morning-pass.log"
    [[ "$output" == *"morning-pass has never ticked (no $T/morning-pass.log)"* ]]
    [ -f "$HEARTBEAT_STATE_DIR/morning-pass-alerted" ]

    echo tick >> "$T/morning-pass.log"
    run heartbeat_watch_mtime morning-pass 1440 "$T/morning-pass.log"
    [[ "$output" == *"morning-pass recovered"* ]]
    [ ! -f "$HEARTBEAT_STATE_DIR/morning-pass-alerted" ]
    [ "$(curl_calls)" -eq 1 ]
}

# ── wiring into the work-loop crons ──────────────────────────────────

# A watch whose period or name drifts from the watched cron pages falsely, or
# never: the period must be the cron's own crontab period and the name its
# should_tick key.
@test "each work-loop cron is watched exactly once, with its crontab period and throttle name" {
    local name calls period
    for name in issue-pickup pr-maintenance pipeline-health; do
        calls=$(grep -hE "^[[:space:]]*heartbeat_watch $name [0-9]+$" "$SCRIPT_DIR"/*.sh)
        [ "$(grep -c . <<<"$calls")" -eq 1 ]
        period=$(awk -v s="/$name-cron.sh" '$7 == ">>" && substr($6, length($6) - length(s) + 1) == s { sub(/^\*\//, "", $1); print $1 }' "$SCRIPT_DIR/crontab")
        [[ "$period" =~ ^[0-9]+$ ]]
        [ "${calls##* }" = "$period" ]
        grep -qE "^[[:space:]]*should_tick \"$name\" \|\| exit 0$" "$SCRIPT_DIR/$name-cron.sh"
    done
}

# Top-level, unindented lines run on every real tick; an indented one sits
# inside a branch or function and may not.
@test "the watch calls run unconditionally on every real tick" {
    [ "$(grep -cx 'heartbeat_watch pipeline-health [0-9]*' "$SCRIPT_DIR/issue-pickup-cron.sh")" -eq 1 ]
    [ "$(grep -cx 'check_cron_heartbeats' "$SCRIPT_DIR/pipeline-health-cron.sh")" -eq 1 ]
}

# cron_period <minute> <hour> <dom> <month> <dow> — minutes between firings.
cron_period() {
    if [ "$5" != "*" ]; then echo 10080
    elif [[ "$2" == \*/* ]]; then echo $(( ${2#*/} * 60 ))
    elif [ "$2" != "*" ]; then echo 1440
    elif [[ "$1" == \*/* ]]; then echo "${1#*/}"
    else echo $(( 60 / $(tr , '\n' <<<"$1" | grep -c .) ))
    fi
}

# A scheduled cron nothing watches can stop without anyone noticing. The four
# crons with a status file are watched by pipeline-health's check_db_backup,
# check_restore_test, check_system_maintenance and check_archon_update.
@test "every scheduled cron is watched, the unthrottled ones by their crontab period" {
    local m h dom mon dow rest name calls n=0
    while read -r m h dom mon dow rest; do
        name=$(sed -E 's|.* >> [^ ]+/logs/([^ ]+)\.log .*|\1|' <<<"$rest")
        case "$name" in
            issue-pickup|pr-maintenance|pipeline-health) continue ;;
            db-backup|restore-test|system-maintenance|archon-update) continue ;;
        esac
        calls=$(grep -hE "^[[:space:]]*heartbeat_watch_mtime $name [0-9]+ " "$SCRIPT_DIR"/*.sh)
        [ "$(grep -c . <<<"$calls")" -eq 1 ] || { echo "$name: not watched exactly once"; return 1; }
        read -r _ _ period _ <<<"$calls"
        [ "$period" = "$(cron_period "$m" "$h" "$dom" "$mon" "$dow")" ] || { echo "$name: watched at $period"; return 1; }
        n=$((n + 1))
    done < <(grep -E '^[^#@].* >> [^ ]+/logs/[^ ]+\.log ' "$SCRIPT_DIR/crontab")
    [ "$n" -eq 10 ]
}

@test "each mtime watch reads the log its crontab line writes" {
    local name file
    while read -r _ name _ file; do
        [ "$name" = ops-self-update ] && continue
        [ "$file" = "\"\$LOG_DIR/$name.log\"" ]
        grep -qE ">> [^ ]+/logs/$name\.log " "$SCRIPT_DIR/crontab"
    done < <(grep -hE '^[[:space:]]*heartbeat_watch_mtime ' "$SCRIPT_DIR/pipeline-health-cron.sh")
}

@test "an ops-self-update cron tick touches the file its watch reads; other invocations do not" {
    local watched
    watched=$(sed -nE 's/^[[:space:]]*heartbeat_watch_mtime ops-self-update [0-9]+ "\$HOME(.*)"$/\1/p' \
        "$SCRIPT_DIR/pipeline-health-cron.sh")
    [ -n "$watched" ]
    watched="$HOME$watched"
    mkdir -p "$T/checkout"
    unset OPS_SELF_UPDATE_STATE
    export ARCHON_RUN_AS=asiri OPS_CHECKOUT="$T/checkout"

    run "$SCRIPT_DIR/ops-self-update.sh" --dry-run
    [ ! -e "$watched" ]

    run "$SCRIPT_DIR/ops-self-update.sh"
    [ -f "$watched" ]
}

@test "the morning pass's heartbeat periods are the ones its crons are watched at" {
    local name period n=0
    while read -r name period; do
        grep -qE "\[$name\]=$period[ )]" "$SCRIPT_DIR/morning-pass.sh"
        n=$((n + 1))
    done < <(grep -hE '^[[:space:]]*heartbeat_watch [a-z-]+ [0-9]+$' \
        "$SCRIPT_DIR/pipeline-health-cron.sh" "$SCRIPT_DIR/issue-pickup-cron.sh" | awk '{print $2, $3}')
    [ "$n" -eq 3 ]
}

@test "the alert limit is heartbeat_watch's: T=59 gives 135 for 15-minute crons, 150 for 30" {
    [ "$(heartbeat_limit_minutes 15)" = 135 ]
    [ "$(heartbeat_limit_minutes 30)" = 150 ]
    stamp pr-maintenance $(( 135 * 60 + 60 ))
    run heartbeat_watch pr-maintenance 15
    [[ "$output" == *"alert after 135 "* ]]
}
