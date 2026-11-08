#!/usr/bin/env bash
# The paths only the owner may approve a change to, for both reviewers that
# merge without the owner (#267): ops-pr-review.sh on the factory's own ops
# PRs, and held-pr-review.sh on held PRs in every repo. One list, so a gate
# one of them protects is never open through the other.
#
#   source "$SCRIPT_DIR/lib/owner-paths.sh"
#   owner_only_path <path> [factory]
#
# Prints the category and returns 0 when only the owner may approve <path>:
# secrets and credentials in any repo; with `factory`, on the factory's own
# repo, its host install, trust and screening, the archon-user sandbox and
# its merge and approval gates.

[ -n "${_OWNER_PATHS_SH:-}" ] && return 0
_OWNER_PATHS_SH=1

owner_only_path() {
  local path="$1" lower base
  local re_trust='^ops/cron/lib/(trust|screen|claude-auth)\.sh$'
  local re_sandbox='^ops/cron/lib/run-as\.sh$|^ops/cron/lib/archon-shim/|^ops/cron/archon-projects\.txt$'
  local re_gates='^ops/cron/(pr-maintenance-cron|ops-pr-review|held-pr-review|ops-self-update)\.sh$|^ops/cron/lib/(held-review|owner-digest|owner-paths)\.sh$|^\.github/unsafe-change\.yml$'
  lower="${path,,}"
  base="${lower##*/}"
  if [[ "$base" == .env* || "$base" == *secret* || "$base" == *credential* || "$base" == *doppler* ]]; then
    echo "secrets or credentials"; return 0
  fi
  [ "${2:-}" = factory ] || return 1
  if [[ "$path" == ops/host/* ]]; then echo "host install and sandboxing"
  elif [[ "$lower" == *sudoers* ]]; then echo "sudoers"
  elif [[ "$path" =~ $re_trust ]]; then echo "trust, screening or Claude auth"
  elif [ "$path" = ops/cron/crontab ]; then echo "crontab install"
  elif [[ "$path" =~ $re_sandbox ]]; then echo "archon-user sandboxing"
  elif [[ "$path" =~ $re_gates ]]; then echo "the merge and approval gates"
  else return 1
  fi
}
