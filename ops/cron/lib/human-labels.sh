#!/usr/bin/env bash
# Labels that signal human-only intent — issue-pickup-cron.sh's triage must
# not reclassify these and its auto_queue must not ingest them.
# requirements-gap issues are filed by the requirements-audit sweep and vetted
# by a human before ingest (#72). HUMAN_NEEDED_LABEL is what the cron scripts
# file their own human-only issues under.
# Usage:
#   source "$SCRIPT_DIR/lib/human-labels.sh"

HUMAN_NEEDED_LABEL="human-needed"
# shellcheck disable=SC2034  # consumed by the sourcing scripts
HUMAN_LABELS=("manual-review" "factory-gap" "$HUMAN_NEEDED_LABEL" "wontfix" "duplicate" "question" "requirements-gap")
