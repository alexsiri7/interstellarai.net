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
# venue-request (musenmingle contact form) and content-report (annie report
# route) are operational requests filed by public forms, never code work.
# (needs-owner-review, where screening parks a bridge issue, is enforced by
# lib/trust.sh instead, so the owner's archon:approved alone releases it.)
HUMAN_LABELS=("manual-review" "factory-gap" "$HUMAN_NEEDED_LABEL" "wontfix" "duplicate" "question" "requirements-gap" "venue-request" "content-report")
