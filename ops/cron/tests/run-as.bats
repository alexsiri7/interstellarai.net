#!/usr/bin/env bats
# Tests for ops/cron/lib/run-as.sh (the ARCHON_RUN_AS flag), the archon shim
# and ops/cron/ops-self-update.sh.
#
# Run: bunx bats ops/cron/tests/run-as.bats

bats_require_minimum_version 1.5.0

setup() {
    export T="$BATS_TEST_TMPDIR"
    LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../lib" && pwd)"
    CRON="$(cd "$LIB/.." && pwd)"
    SHIM="$LIB/archon-shim/archon"
    mkdir -p "$T/bin" "$T/home"
    export HOME="$T/home"
    # Stubs record their argv.
    for c in sudo systemctl gh curl; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/argv"\n' "$c" "$T" > "$T/bin/$c"
        chmod +x "$T/bin/$c"
    done
    export PATH="$T/bin:$PATH"
    unset ARCHON_RUN_AS ARCHON_RUNS_SNAPSHOT
}

load_lib() { unset _ARCHON_RUN_AS_SH; source "$LIB/run-as.sh"; }

@test "default: asiri mode, PATH untouched, no snapshot move" {
    before="$PATH"
    load_lib
    [ "$ARCHON_RUN_AS" = asiri ]
    [ "$PATH" = "$before" ]
    [ -z "${ARCHON_RUNS_SNAPSHOT:-}" ]
    runas_may_launch x
    ! runas_archon
}

@test "asiri mode: the server restart is the owner's user unit, exactly as before" {
    load_lib
    runas_serve_restart archon-serve.service
    [ "$(cat "$T/argv")" = "systemctl --user restart archon-serve.service" ]
}

@test "asiri mode: CLAUDE_ACCOUNTS passes through unchanged" {
    load_lib
    CLAUDE_ACCOUNTS="/a:/b"
    [ "$(runas_claude_accounts)" = "/a:/b" ]
}

@test "asiri mode: no merge is ever blocked, and gh is not even asked" {
    load_lib
    ! runas_merge_blocked interstellarai.net 5
    [ ! -e "$T/argv" ]
}

@test "under bats the host's flag file is ignored" {
    mkdir -p "$HOME/.config/archon-cron"
    echo "ARCHON_RUN_AS=archon" > "$HOME/.config/archon-cron/run-as"
    load_lib
    [ "$ARCHON_RUN_AS" = asiri ]
}

@test "outside bats the flag file is read (and junk reads as asiri)" {
    mkdir -p "$HOME/.config/archon-cron"
    echo "ARCHON_RUN_AS=archon  # cut over 2026-09-27" > "$HOME/.config/archon-cron/run-as"
    run env -u BATS_TEST_FILENAME bash -c "source '$LIB/run-as.sh'; echo \$ARCHON_RUN_AS"
    [ "$output" = archon ]
    echo "ARCHON_RUN_AS=root" > "$HOME/.config/archon-cron/run-as"
    run env -u BATS_TEST_FILENAME bash -c "source '$LIB/run-as.sh'; echo \$ARCHON_RUN_AS"
    [ "$output" = asiri ]
}

@test "archon mode: the shim is first on PATH and the run snapshot leaves /tmp" {
    export ARCHON_RUN_AS=archon
    load_lib
    [ "$(command -v archon)" = "$SHIM" ]
    [[ "$ARCHON_RUNS_SNAPSHOT" == "$HOME/.local/state/archon-cron/.archon-active-runs."* ]]
}

@test "archon mode: restart goes through the one sudo shape, accounts are archon's" {
    export ARCHON_RUN_AS=archon
    load_lib
    runas_serve_restart archon-serve.service
    [ "$(cat "$T/argv")" = "sudo -n /usr/bin/systemctl restart archon-serve.service" ]
    CLAUDE_ACCOUNTS="/a:/b"
    [ "$(runas_claude_accounts)" = archon ]
}

@test "archon mode: ops repo PRs touching ops/ or .github/ are held for a human" {
    export ARCHON_RUN_AS=archon
    load_lib
    printf '#!/usr/bin/env bash\nprintf "README.md\\nops/cron/issue-pickup-cron.sh\\n"\n' > "$T/bin/gh"
    run runas_merge_blocked interstellarai.net 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"ops/cron/issue-pickup-cron.sh"* ]]
    printf '#!/usr/bin/env bash\nprintf ".github/workflows/ci.yml\\n"\n' > "$T/bin/gh"
    run runas_merge_blocked interstellarai.net 5
    [ "$status" -eq 0 ]
    printf '#!/usr/bin/env bash\nprintf "src/pages/index.astro\\nworkers/feedback/src/index.ts\\n"\n' > "$T/bin/gh"
    run runas_merge_blocked interstellarai.net 5
    [ "$status" -eq 1 ]
    printf '#!/usr/bin/env bash\nprintf "ops/x\\n"\n' > "$T/bin/gh"
    run runas_merge_blocked reli 5       # other repos: their ops/ is not the cron's
    [ "$status" -eq 1 ]
    printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/gh"
    run runas_merge_blocked interstellarai.net 5   # cannot read the files -> fail closed
    [ "$status" -eq 0 ]
}

@test "drain mode: launching scripts skip the tick" {
    export ARCHON_RUN_AS=drain
    load_lib
    run runas_may_launch issue-pickup
    [ "$status" -eq 1 ]
    [[ "$output" == *"draining"* ]]
}

@test "shim, archon mode: exec sudo -n -u archon <wrapper> with the argv untouched" {
    ARCHON_RUN_AS=archon run "$SHIM" workflow run archon-ship "fix #12"
    [ "$status" -eq 0 ]
    [ "$(cat "$T/argv")" = "sudo -n -u archon /usr/local/bin/archon-as-archon workflow run archon-ship fix #12" ]
}

@test "shim, drain mode: workflow run is refused, listing goes to the real CLI" {
    printf '#!/usr/bin/env bash\necho "real $*"\n' > "$T/real"; chmod +x "$T/real"
    ARCHON_RUN_AS=drain ARCHON_REAL_BIN="$T/real" run "$SHIM" workflow run archon-ship "fix #1"
    [ "$status" -eq 75 ]
    ARCHON_RUN_AS=drain ARCHON_REAL_BIN="$T/real" run "$SHIM" workflow runs --all --json
    [ "$status" -eq 0 ]
    [ "$output" = "real workflow runs --all --json" ]
}

@test "shim reads the flag file when the environment does not say (manual use)" {
    mkdir -p "$HOME/.config/archon-cron"
    echo "ARCHON_RUN_AS=archon" > "$HOME/.config/archon-cron/run-as"
    run "$SHIM" --version
    [ "$(cat "$T/argv")" = "sudo -n -u archon /usr/local/bin/archon-as-archon --version" ]
}

# ---------------------------------------------------------------- self-update
mk_repos() {
    git init -q -b main "$T/origin.git" --bare
    git clone -q "$T/origin.git" "$T/work" 2>/dev/null
    git -C "$T/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    mkdir -p "$T/work/ops/cron" "$T/work/src"
    git -C "$T/work" push -q origin main
    git clone -q "$T/origin.git" "$T/live"
}
commit_file() {  # commit_file <path>
    echo "$RANDOM" > "$T/work/$1"
    git -C "$T/work" add "$1"
    git -C "$T/work" -c user.email=t@t -c user.name=t commit -q -m "change $1"
    git -C "$T/work" push -q origin main
}

@test "self-update, asiri mode: a plain ff-only pull, ops changes included" {
    mk_repos
    commit_file ops/cron/x.sh
    OPS_CHECKOUT="$T/live" run "$CRON/ops-self-update.sh"
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/live" rev-parse HEAD)" = "$(git -C "$T/work" rev-parse HEAD)" ]
}

@test "self-update, archon mode: non-ops changes fast-forward" {
    mk_repos
    commit_file src/page.astro
    ARCHON_RUN_AS=archon OPS_CHECKOUT="$T/live" run "$CRON/ops-self-update.sh"
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/live" rev-parse HEAD)" = "$(git -C "$T/work" rev-parse HEAD)" ]
}

@test "self-update, archon mode: ops changes are held (one ntfy) until approved" {
    mk_repos
    mkdir -p "$HOME/.config/archon-cron"
    echo "NTFY_TOPIC=test-topic" > "$HOME/.config/archon-cron/secrets.env"
    before=$(git -C "$T/live" rev-parse HEAD)
    commit_file ops/cron/evil.sh
    target=$(git -C "$T/work" rev-parse HEAD)
    ARCHON_RUN_AS=archon OPS_CHECKOUT="$T/live" run "$CRON/ops-self-update.sh"
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/live" rev-parse HEAD)" = "$before" ]
    [[ "$output" == *"holding origin/main $target"* ]]
    [ "$(grep -c '^curl' "$T/argv")" -eq 1 ]
    ARCHON_RUN_AS=archon OPS_CHECKOUT="$T/live" run "$CRON/ops-self-update.sh"
    [ "$(grep -c '^curl' "$T/argv")" -eq 1 ]            # not twice for the same commit
    # the owner approves at the console
    ARCHON_RUN_AS=archon OPS_CHECKOUT="$T/live" run bash -c "echo y | '$CRON/ops-self-update.sh' --approve"
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/live" rev-parse HEAD)" = "$target" ]
    grep -qx "$target" "$HOME/.config/archon-cron/ops-approved"
}

@test "self-update, archon mode: an approval does not carry over to a newer ops commit" {
    mk_repos
    commit_file ops/cron/a.sh
    first=$(git -C "$T/work" rev-parse HEAD)
    mkdir -p "$HOME/.config/archon-cron"; echo "$first" > "$HOME/.config/archon-cron/ops-approved"
    commit_file ops/cron/b.sh
    before=$(git -C "$T/live" rev-parse HEAD)
    ARCHON_RUN_AS=archon OPS_CHECKOUT="$T/live" run "$CRON/ops-self-update.sh"
    [ "$(git -C "$T/live" rev-parse HEAD)" = "$before" ]
}
