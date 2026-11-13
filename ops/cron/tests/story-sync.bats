#!/usr/bin/env bats
# Tests for ops/cron/story-sync.sh: export Annie read-only, skip when it is
# unchanged, run archon-story-sync when it changed, and remember the export
# only after a successful run.
#
# Run: bunx bats ops/cron/tests/story-sync.bats

SCRIPT="$BATS_TEST_DIRNAME/../story-sync.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    export HOME="$TEST_TMP/home"
    export ARCHON_CRON_FORCE_TICK=1
    export ARCHON_CRON_SECRETS="$TEST_TMP/secrets.env"
    printf 'NTFY_TOPIC=test-topic\nANNIE_DB_URL=postgres://annie@db/annie\n' > "$ARCHON_CRON_SECRETS"
    export STORY_SYNC_CONFIG="$TEST_TMP/story-sync.txt"
    printf '# comment\nproj1 alexsiri7/game\n' > "$STORY_SYNC_CONFIG"
    export STORY_SYNC_BASE_DIR="$TEST_TMP/clones"
    export TMPDIR="$TEST_TMP"
    mkdir -p "$STORY_SYNC_BASE_DIR/game/.git" "$HOME/.local/bin"
    export STORY_JSON="$TEST_TMP/story.json"
    echo '{"objects":[{"id":"a","type":"CHARACTER","name":"The Cat","description":"A cat.","notes":"","role":"protagonist","tags":""}],"relationships":[],"nodes":[]}' > "$STORY_JSON"
    local bin="$HOME/.local/bin"
    cat > "$bin/psql" <<'STUB'
#!/usr/bin/env bash
echo "PGOPTIONS=$PGOPTIONS $*" >> "$HOME/psql-calls"
cat > /dev/null
cat "$STORY_JSON"
STUB
    cat > "$bin/archon" <<'STUB'
#!/usr/bin/env bash
echo "$PWD $*" >> "$HOME/archon-calls"
cat "$4/README.md" > /dev/null || exit 9
cp -r "$4" "$HOME/last-export"
echo "STORY_SYNC_PR: https://github.com/alexsiri7/game/pull/1"
exit "${ARCHON_EXIT:-0}"
STUB
    cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HOME/curl-calls"
STUB
    chmod +x "$bin"/*
}

teardown() { rm -rf "$TEST_TMP"; }

@test "a changed story runs archon-story-sync in the clone with the export, read-only" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q 'default_transaction_read_only=on' "$HOME/psql-calls"
    grep -q "^$STORY_SYNC_BASE_DIR/game workflow run archon-story-sync $TEST_TMP/story-sync-game-.*/annie$" "$HOME/archon-calls"
    [ -s "$HOME/.archon/story-sync-state/game.sha" ]
    ! ls -d "$TEST_TMP"/story-sync-game-* 2>/dev/null
}

@test "an unchanged story runs nothing" {
    run "$SCRIPT"
    rm "$HOME/archon-calls"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/archon-calls" ]
    grep -q 'Annie unchanged' <<<"$output"
}

@test "a failed run is not remembered, so the next day retries it" {
    export ARCHON_EXIT=1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -f "$HOME/.archon/story-sync-state/game.sha" ]
    grep -q 'Story sync failed' "$HOME/curl-calls"
}

@test "an export Annie will not give is a failure with an ntfy, and nothing runs" {
    printf '#!/usr/bin/env bash\nexit 2\n' > "$HOME/.local/bin/psql"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -f "$HOME/archon-calls" ]
    grep -q 'Could not read Annie project proj1' "$HOME/curl-calls"
}

@test "a project id that is not a plain id is refused before any query" {
    printf 'x%%27;drop alexsiri7/game\n' > "$STORY_SYNC_CONFIG"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -f "$HOME/psql-calls" ]
}

@test "the crontab schedule for story-sync.sh matches the script's header comment" {
    local line schedule
    line=$(grep -E '^[^#].*/story-sync\.sh ' "$BATS_TEST_DIRNAME/../crontab")
    [ "$(grep -c . <<<"$line")" -eq 1 ]
    schedule=$(awk '{print $1, $2, $3, $4, $5}' <<<"$line")
    grep -qF "$schedule" "$SCRIPT"
}

@test "beats in a scene are exported as one line each, even when they contain >" {
    echo '{"objects":[],"relationships":[],"nodes":[{"id":"n1","parentId":null,"type":"SCENE","title":"The lesson","synopsis":"","status":"DRAFT","orderIndex":0,"content":"<!-- beat: CUTSCENE: The lesson --><!-- beat: > The cat sits. --><!-- beat: CAT: A song! -->"}]}' > "$STORY_JSON"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    f="$HOME/last-export/outline/001-the-lesson.md"
    grep -qx 'CUTSCENE: The lesson' "$f"
    grep -qx '> The cat sits.' "$f"
    grep -qx 'CAT: A song!' "$f"
    ! grep -q -- '-->' "$f"
}
