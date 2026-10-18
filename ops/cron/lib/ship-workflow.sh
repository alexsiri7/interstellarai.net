#!/usr/bin/env bash
# ship-workflow.sh — which sdlc ship workflow the unattended crons launch.
#
# From Archon v0.12.0, `archon-ship` pauses as an attention item whenever it ends
# where only a person can take it forward (a delivery that ended not ready, a
# triage or planning question, an unrooted cause), with no timeout. A paused ship
# run holds its project's ship slot (issue-pickup's parked-run guard) and freezes
# its PR (pr-maintenance's pr_owned_by_live_run) until someone answers it in
# Archon's attention queue. Its graph without that pause is `archon-ship-block`,
# which upstream names as the one for callers that own what follows the ending:
# here, settle-ship-outcome.sh, ship-breaker and unstick_stale. v0.11.1 has no
# `archon-ship-block` and its `archon-ship` never pauses.
#
#   ship_workflow    archon-ship-block when the engine ships it, else archon-ship.
#                    Read from the engine checkout ($ARCHON_LIVE_DIR, the one
#                    archon-update.sh swaps), so the switch happens with the swap
#                    and a rollback switches it back. ARCHON_SHIP_WORKFLOW
#                    overrides it (tests; an emergency pin).
#   SHIP_WF_ALT      the regex alternation of every name a ship run can carry in
#                    the run DB and in `ps` (runs started before the swap keep
#                    the old name): use it inside ^archon-(...)$ matchers.
#
# Usage: source "$SCRIPT_DIR/lib/ship-workflow.sh"; wf=$(ship_workflow)
[ -n "${_SHIP_WORKFLOW_SH:-}" ] && return 0
_SHIP_WORKFLOW_SH=1

# shellcheck disable=SC2034  # consumed by the sourcing scripts
SHIP_WF_ALT='ship-block|ship'

ship_workflow() {
  if [ -n "${ARCHON_SHIP_WORKFLOW:-}" ]; then
    printf '%s\n' "$ARCHON_SHIP_WORKFLOW"
  elif [ -f "${ARCHON_LIVE_DIR:-/mnt/ext-fast/archon}/.archon/workflows/sdlc/ship/archon-ship-block.yaml" ]; then
    echo archon-ship-block
  else
    echo archon-ship
  fi
}
