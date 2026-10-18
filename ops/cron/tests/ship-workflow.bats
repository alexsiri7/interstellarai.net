#!/usr/bin/env bats
# Tests for ops/cron/lib/ship-workflow.sh: which ship workflow the crons launch.
#
# Run: bunx bats ops/cron/tests/ship-workflow.bats

setup() {
    export T="$BATS_TMPDIR/ship-workflow-$$"
    mkdir -p "$T/engine/.archon/workflows/sdlc/ship"
    unset ARCHON_SHIP_WORKFLOW _SHIP_WORKFLOW_SH
    export ARCHON_LIVE_DIR="$T/engine"
    LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib/ship-workflow.sh"
}

teardown() { rm -rf "$T"; }

@test "an engine without archon-ship-block (v0.11) launches archon-ship" {
    source "$LIB"
    [ "$(ship_workflow)" = archon-ship ]
}

@test "an engine that ships archon-ship-block (v0.12+) launches it, and a rollback switches back" {
    source "$LIB"
    touch "$T/engine/.archon/workflows/sdlc/ship/archon-ship-block.yaml"
    [ "$(ship_workflow)" = archon-ship-block ]
    rm "$T/engine/.archon/workflows/sdlc/ship/archon-ship-block.yaml"
    [ "$(ship_workflow)" = archon-ship ]
}

@test "ARCHON_SHIP_WORKFLOW pins the name" {
    source "$LIB"
    touch "$T/engine/.archon/workflows/sdlc/ship/archon-ship-block.yaml"
    ARCHON_SHIP_WORKFLOW=archon-ship run ship_workflow
    [ "$output" = archon-ship ]
}

@test "SHIP_WF_ALT matches both names, anchored, and nothing longer" {
    source "$LIB"
    re="^archon-($SHIP_WF_ALT|fix-github-issue)\$"
    [[ archon-ship =~ $re ]]
    [[ archon-ship-block =~ $re ]]
    [[ archon-fix-github-issue =~ $re ]]
    ! [[ archon-ship-blocker =~ $re ]]
    ! [[ archon-shipped =~ $re ]]
}
