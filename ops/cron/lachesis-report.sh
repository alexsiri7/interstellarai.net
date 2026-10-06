#!/usr/bin/env bash
# lachesis-report.sh — report the factory's fuel and run usage to Lachesis
# (crontab, */15). Closes the loop of #146 (fuel) and #147 (usage/outcome):
# see lib/lachesis_report.py for what is read and reported.
#
# Secrets (~/.config/archon-cron/secrets.env): LACHESIS_FACTORY_TOKEN, a factory
# token created in Lachesis with create_factory_token. Without it nothing is
# reported (logged, exit 1).
#
# Usage: lachesis-report.sh [--dry-run]

set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
export LACHESIS_FACTORY_TOKEN="${LACHESIS_FACTORY_TOKEN:-}"

CRON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$CRON_DIR/lib/lachesis_report.py" "$@"
