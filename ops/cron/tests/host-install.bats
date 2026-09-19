#!/usr/bin/env bats
# Step 1 (sudoers drop-in) of ops/host/install.sh, exercised as a normal user
# through the HOST_INSTALL_SUDOERS_D test hook with visudo and install stubbed:
# a pre-existing sudoers problem is reported (and the offending file named)
# without installing anything; a post-install failure still rolls back; the
# happy path installs at 0440; --dry-run writes nothing.
#
# Run: bunx bats ops/cron/tests/host-install.bats

setup() {
    export T="$BATS_TMPDIR/host-install-$$"
    rm -rf "$T"
    mkdir -p "$T/bin" "$T/sudoers.d"
    HOST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../host" && pwd)"
    SCRIPT="$HOST_DIR/install.sh"
    export PATH="$T/bin:$PATH"
    export HOST_INSTALL_SUDOERS_D="$T/sudoers.d"
    export INSTALL_ARGV="$T/install-argv"     # every `install` call, one per line
    export STUB_VISUDO_REJECT_ARCHON=0        # 1: the combined set fails once archon-cron is present

    # visudo -c: reject any drop-in that is not 0440 (as the real one does, and
    # the reason the 2026-09-19 install blamed its own file); with
    # STUB_VISUDO_REJECT_ARCHON=1 also fail once archon-cron has landed, which
    # is "the combined set broke after install" without a real sudo.
    cat > "$T/bin/visudo" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "-q" ] && [ "$3" = "-f" ]; then
    [ -r "$4" ]; exit
fi
rc=0
echo "/etc/sudoers: parsed OK"
for f in "$HOST_INSTALL_SUDOERS_D"/*; do
    [ -f "$f" ] || continue
    mode=$(stat -c %a "$f")
    if [ "$mode" != 440 ]; then
        echo "$f: bad permissions, should be mode 0440" >&2
        rc=1
    elif [ "${STUB_VISUDO_REJECT_ARCHON:-0}" = 1 ] && [ "$(basename "$f")" = archon-cron ]; then
        echo "$f: syntax error near line 1" >&2
        rc=1
    else
        echo "$f: parsed OK"
    fi
done
exit $rc
STUB
    # install: the script passes -o root -g root, which a normal user cannot do;
    # drop those and defer to the real install for the copy and chmod.
    cat > "$T/bin/install" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INSTALL_ARGV"
args=()
while [ $# -gt 0 ]; do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
STUB
    chmod +x "$T/bin/visudo" "$T/bin/install"
}

teardown() { rm -rf "$T"; }

@test "baseline visudo -c fails: nothing installed, visudo output shown, offending file named" {
    echo "asiri ALL=(root) NOPASSWD: /usr/bin/true" > "$T/sudoers.d/gc-resize"
    chmod 0644 "$T/sudoers.d/gc-resize"
    echo "ok" > "$T/sudoers.d/well-behaved"
    chmod 0440 "$T/sudoers.d/well-behaved"

    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -e "$T/sudoers.d/archon-cron" ]
    [ ! -e "$INSTALL_ARGV" ]                                  # install never attempted
    [[ "$output" == *"| $T/sudoers.d/gc-resize: bad permissions, should be mode 0440"* ]]   # captured visudo output
    [[ "$output" == *"files in $T/sudoers.d that are not mode 0440"* ]]
    [[ "$output" == *"644 $(id -un):"*"$T/sudoers.d/gc-resize"* ]]
    offenders=$(sed -n '/not mode 0440/,/ERROR/p' <<< "$output")   # the listing, not visudo's own "parsed OK" lines
    [[ "$offenders" != *"well-behaved"* ]]                          # 0440 and ours: not an offender
    [[ "$output" == *"pre-existing sudoers problem"* ]]
    [[ "$output" == *"chmod 0440 $T/sudoers.d/<file>"* ]]
    [[ "$output" == *"re-run"* ]]
    [[ "$output" != *"combined sudoers failed visudo -c after install"* ]]
    [[ "$output" == *"FAILED steps: sudoers"* ]]
}

@test "baseline ok, combined set fails after install: file rolled back, visudo output shown" {
    export STUB_VISUDO_REJECT_ARCHON=1

    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"visudo -c: existing sudoers set parses"* ]]
    grep -q "^-m 0440 -o root -g root .*archon-cron$" "$INSTALL_ARGV"
    [[ "$output" == *"installed $T/sudoers.d/archon-cron (0440)"* ]]
    [[ "$output" == *"| $T/sudoers.d/archon-cron: syntax error"* ]]
    [[ "$output" == *"combined sudoers failed visudo -c after install — $T/sudoers.d/archon-cron removed"* ]]
    [ ! -e "$T/sudoers.d/archon-cron" ]
    [[ "$output" != *"pre-existing sudoers problem"* ]]
}

@test "clean host: drop-in installed at 0440 and identical to the repo file; second run is already done" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$T/sudoers.d/archon-cron")" = 440 ]
    cmp -s "$HOST_DIR/sudoers-archon-cron" "$T/sudoers.d/archon-cron"
    [[ "$output" != *ERROR* ]]

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$T/sudoers.d/archon-cron already done"* ]]
    [ "$(wc -l < "$INSTALL_ARGV")" -eq 1 ]
}

@test "--dry-run: still reports a pre-existing problem; otherwise prints the install command and writes nothing" {
    echo "x" > "$T/sudoers.d/gc-resize"
    chmod 0644 "$T/sudoers.d/gc-resize"

    run "$SCRIPT" --dry-run
    [ "$status" -eq 1 ]     # the baseline visudo -c runs in dry-run too (as root on the host; always under the hook)
    [ ! -e "$T/sudoers.d/archon-cron" ]
    [ ! -e "$INSTALL_ARGV" ]
    [[ "$output" == *"pre-existing sudoers problem"* ]]

    chmod 0440 "$T/sudoers.d/gc-resize"
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: would run: install -m 0440 -o root -g root"*"archon-cron"* ]]
    [[ "$output" == *"dry-run complete — nothing was changed"* ]]
    [ ! -e "$T/sudoers.d/archon-cron" ]
    [ ! -e "$INSTALL_ARGV" ]
}
