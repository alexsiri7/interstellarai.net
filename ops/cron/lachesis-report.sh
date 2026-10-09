#!/usr/bin/env bash
# lachesis-report.sh — report the factory's fuel and run usage to Lachesis
# (crontab, */15). Closes the loop of #146 (fuel) and #147 (usage/outcome):
# see lib/lachesis_report.py for what is read and reported.
#
# Secrets (~/.config/archon-cron/secrets.env): LACHESIS_FACTORY_TOKEN, a factory
# token created in Lachesis with create_factory_token. Without it nothing is
# reported (logged, exit 1). NTFY_TOPIC: where an account with no current fuel
# reading is escalated, once per stale episode.
#
# Fuel older than 25 minutes is refreshed first with `archon-as-archon
# [--account main] fuel-probe` (#165), through the same sudo rule as the shim;
# main only while the owner's flag says ARCHON_MAIN_ACCOUNT=on (lib/main-account.sh).
#
# Usage: lachesis-report.sh [--dry-run]

set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

SECRETS_FILE="${ARCHON_CRON_SECRETS:-$HOME/.config/archon-cron/secrets.env}"
# shellcheck source=/dev/null
[ -r "$SECRETS_FILE" ] && . "$SECRETS_FILE"
export LACHESIS_FACTORY_TOKEN="${LACHESIS_FACTORY_TOKEN:-}"
export NTFY_TOPIC="${NTFY_TOPIC:-}"

CRON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/main-account.sh
. "$CRON_DIR/lib/main-account.sh"
ARCHON_MAIN_ACCOUNT=off
main_account_enabled && ARCHON_MAIN_ACCOUNT=on
export ARCHON_MAIN_ACCOUNT
exec python3 "$CRON_DIR/lib/lachesis_report.py" "$@"
