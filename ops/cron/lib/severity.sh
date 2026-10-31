#!/usr/bin/env bash
# The severity tier of an archon-ship outcome that ended without a PR, which
# decides what lib/settle-ship-outcome.sh does with it (#237).
#
#   source "$SCRIPT_DIR/lib/severity.sh"
#   tier=$(severity_tier "$declared" "$verdict_and_title")   # 1, 2 or 3
#
# The owner's policy of 2026-10-27:
#   1 act      reversible, low blast radius (close, add a dependency, run it
#              again with the verdict as direction): no question, a note.
#   2 default  reversible but visible: ask, with the verdict's own suggested
#              action as the default taken after two days.
#   3 wait     prod data deletion or migration, history rewrites, repo
#              visibility, legal/GDPR, money or accounts, secret rotation, store
#              publishing: ask with no default.
# An outcome that declares no tier is tier 2. The keyword floor below reads the
# verdict and the issue title, never the body, and only ever raises a tier: a
# false positive costs a question with no default (the factory's behaviour
# before #237), a false negative lets a tier-3 outcome close itself.

[ -n "${_SEVERITY_SH:-}" ] && return 0
_SEVERITY_SH=1

# Whole words, case-insensitive. Bare "migration", "truncate", "visibility" and
# "account" are left out: ordinary code issues use them (a schema migration,
# truncating a log line, a button's visibility, a Claude account).
SEVERITY_TIER3_WORDS=(
  # prod data deletion or migration
  '(prod|production) (data|database|db)' 'data (loss|deletion|migration)'
  'drop (table|column|database|schema)' 'truncate (the )?table' 'backfill'
  'migrate (the )?(prod|production)'
  # history rewrites
  'force[- ]push(ed|ing)?' 'rewrit(e|es|ing) (the )?(git )?history'
  'history rewrite' 'filter-(repo|branch)'
  # repo visibility
  '(repo|repository) visibility' 'make (it|the repo|the repository) (public|private)'
  '(public|private) (repo|repository)'
  # legal / GDPR
  'gdpr' 'ccpa' 'legal' 'lawyer' 'terms of (service|use)' 'data processing agreement'
  'right to (erasure|be forgotten)' 'copyright' 'trademark' 'licen[cs]e[sd]?'
  # money / accounts
  'billing' 'payments?' 'invoices?' 'refunds?' 'stripe' 'paypal' 'pricing'
  'subscriptions?' 'in-app purchases?' 'credit cards?'
  '(delete|close|cancel|transfer) (the |an |a |my |user )?accounts?'
  # secret rotation
  'rotat(e|es|ed|ing|ion) (of )?(the |a |an |all )?([a-z_-]+ )?(secrets?|keys?|tokens?|credentials?|passwords?)'
  'secret rotation' 'revok(e|es|ed|ing)'
  'leaked ([a-z_-]+ )?(secrets?|keys?|tokens?|credentials?|passwords?)' 'keystore' 'signing key'
  # store publishing
  'play store' 'google play' 'app store' 'testflight' 'store listing' 'production track'
)
SEVERITY_TIER3_RE=$(IFS='|'; echo "${SEVERITY_TIER3_WORDS[*]}")

# The default actions settle offers (lib/settle-ship-outcome.sh
# suggested_action) that pickup carries out when Lachesis takes them
# (issue-pickup-cron.sh settle_defaulted). proceed is not among them: a taken
# proceed default needs only the launch that follows.
# shellcheck disable=SC2034  # read by issue-pickup-cron.sh settle_defaulted
SETTLE_DEFAULT_ACTION_RE='close-completed|close-not-planned|depend-[0-9]+'

# severity_tier <declared> <text> — <declared> when it is 1, 2 or 3, else 2;
# 3 whenever <text> matches the tier-3 floor.
severity_tier() {
  local tier=2
  [[ "$1" =~ ^[123]$ ]] && tier="$1"
  grep -qiwE "$SEVERITY_TIER3_RE" <<<"$2" && tier=3
  echo "$tier"
}
