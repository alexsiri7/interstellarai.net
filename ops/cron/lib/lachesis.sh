#!/usr/bin/env bash
# Lachesis, the planner, from the cron scripts: its switches and one MCP call.
#
#   source "$SCRIPT_DIR/lib/lachesis.sh"
#   lachesis_pickup_enabled && json=$(lachesis_call next_issue '{}')
#
# Switches, off unless the owner turns them on, outside this repo so archon
# cannot (same shape as lib/main-account.sh's ARCHON_MAIN_ACCOUNT):
#   $LACHESIS_PICKUP_FLAG (default ~/.config/archon-cron/lachesis-pickup), one line
#   LACHESIS_PICKUP=on
# With it on, issue-pickup takes its work from Lachesis next_issue instead of
# the archon:queued label scan, and every wait for the author is a Lachesis
# question (interstellarai.net #157). Off, or under bats without
# LACHESIS_FLAG_TEST, nothing here changes what the factory does.
#
# lachesis_call runs lib/lachesis_call.py with the factory token
# (LACHESIS_FACTORY_TOKEN, read from secrets.env on its own: the rest of
# secrets.env never reaches the environment of the archon runs these scripts
# start). LACHESIS_CALL_CMD replaces it in tests.

[ -n "${_LACHESIS_SH:-}" ] && return 0
_LACHESIS_SH=1

LACHESIS_PICKUP_FLAG="${LACHESIS_PICKUP_FLAG:-$HOME/.config/archon-cron/lachesis-pickup}"
LACHESIS_STATE_DIR="${LACHESIS_STATE_DIR:-$HOME/.local/state/archon-cron/lachesis}"

# lachesis_flag_on <file> <VAR> — true when <file>'s last VAR= line says on.
# Under bats the host's files are ignored unless the test sets LACHESIS_FLAG_TEST.
lachesis_flag_on() {
  [ -n "${BATS_TEST_FILENAME:-}" ] && [ -z "${LACHESIS_FLAG_TEST:-}" ] && return 1
  [ -r "$1" ] || return 1
  [ "$(sed -nE "s/^[[:space:]]*$2=[\"']?([a-z]+)[\"']?[[:space:]]*(#.*)?\$/\\1/p" "$1" | tail -n 1)" = on ]
}

lachesis_pickup_enabled() { lachesis_flag_on "$LACHESIS_PICKUP_FLAG" LACHESIS_PICKUP; }

# lachesis_token — LACHESIS_FACTORY_TOKEN from the environment or secrets.env.
lachesis_token() {
  if [ -n "${LACHESIS_FACTORY_TOKEN:-}" ]; then
    printf '%s' "$LACHESIS_FACTORY_TOKEN"
    return 0
  fi
  local secrets="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
  [ -r "$secrets" ] || return 0
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?LACHESIS_FACTORY_TOKEN=["'\'']?([^"'\''[:space:]#]*).*/\2/p' "$secrets" | tail -n 1
}

# lachesis_call <tool> [json-arguments] — the tool's JSON on stdout. Exit 0 when
# it answered, 1 when it refused, 2 when Lachesis could not be reached (the
# reason on stderr either way).
lachesis_call() {
  if [ -n "${LACHESIS_CALL_CMD:-}" ]; then
    $LACHESIS_CALL_CMD "$@"
    return
  fi
  LACHESIS_FACTORY_TOKEN="$(lachesis_token)" \
    python3 -B "$(dirname "${BASH_SOURCE[0]}")/lachesis_call.py" "$@"
}

# lachesis_ask <project> <issue> <question> [context] — record a question for
# the author blocking alexsiri7/<project>#<issue> (ask_question, kind
# clarification): Lachesis posts it, with the context, as a comment on the
# issue and labels it needs-author, so next_issue passes over the issue until
# the author answers. True when the question was recorded.
lachesis_ask() {
  local project="$1" issue="$2" question="$3" context="${4:-}" args
  args=$(jq -nc --arg repo "alexsiri7/$project" --argjson n "$issue" \
    --arg q "$question" --arg c "$context" \
    '{repo: $repo, question: $q, kind: "clarification", asker: "factory",
      blocks: [$n], issue: $n, context: $c}') || return 1
  lachesis_call ask_question "$args" >/dev/null
}

# lachesis_ask_once <project> <issue> <key> <question> [context] — lachesis_ask,
# once per (project, issue, key): a marker in LACHESIS_STATE_DIR keeps a
# question whose cause outlives its answer (a stranger's comment left in
# place) from being asked again every tick. True when it is (or already was)
# recorded.
lachesis_ask_once() {
  local marker="$LACHESIS_STATE_DIR/asked-$1-$2-$3"
  [ -e "$marker" ] && return 0
  lachesis_ask "$1" "$2" "$4" "${5:-}" || return 1
  mkdir -p "$LACHESIS_STATE_DIR" 2>/dev/null && : > "$marker"
  return 0
}
