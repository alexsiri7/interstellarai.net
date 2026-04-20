#!/usr/bin/env bash
# generate-android-keystore.sh — generate an Android release keystore and
# upload it + its passwords as GitHub Actions secrets on the given repo.
#
# IMPORTANT: the keystore you create here is forever. Any future version of
# the app that installs over an existing one MUST be signed with this same
# keystore. Losing it means you can never update installed copies.
#
# Usage:
#   generate-android-keystore.sh <github-repo>
#
# Example:
#   generate-android-keystore.sh alexsiri7/cosmic-match
#
# Secret names written (matches cosmic-match/ci.yml expectations):
#   KEYSTORE_BASE64           — base64 of the .jks file
#   KEYSTORE_STORE_PASSWORD   — store password
#   KEYSTORE_KEY_PASSWORD     — key password
#   KEYSTORE_KEY_ALIAS        — key alias
#
# Outputs written locally (chmod 600):
#   ~/keystores/<project>-release.jks
#   ~/keystores/<project>-release.creds.txt  (passwords, alias, SHA256 fingerprint)

set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ] || [[ "$REPO" != */* ]]; then
  echo "Usage: $(basename "$0") <owner/repo>" >&2
  echo "  e.g. $(basename "$0") alexsiri7/cosmic-match" >&2
  exit 2
fi

PROJECT="${REPO##*/}"
KEYSTORE_DIR="$HOME/keystores"
KEYSTORE_PATH="$KEYSTORE_DIR/${PROJECT}-release.jks"
CREDS_PATH="$KEYSTORE_DIR/${PROJECT}-release.creds.txt"
ALIAS="$PROJECT"
VALIDITY_DAYS=10000  # ~27 years; Play Store requires ≥25

for cmd in keytool gh openssl base64; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }
done

gh auth status >/dev/null 2>&1 || { echo "gh not authenticated" >&2; exit 1; }
gh repo view "$REPO" >/dev/null 2>&1 || { echo "cannot access $REPO via gh" >&2; exit 1; }

if [ -e "$KEYSTORE_PATH" ]; then
  echo "Refusing to overwrite existing keystore: $KEYSTORE_PATH" >&2
  echo "If you really want to rotate the key, move it aside first." >&2
  exit 1
fi

echo ">>> This will generate a new release keystore for $REPO"
echo "    Keystore path : $KEYSTORE_PATH"
echo "    Alias         : $ALIAS"
echo "    Validity      : $VALIDITY_DAYS days"
echo
echo "    The generated keystore becomes the single source of app identity."
echo "    Lose it = can never update installed apps."
read -r -p "Proceed? [y/N] " reply
case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "aborted"; exit 1;; esac

mkdir -p "$KEYSTORE_DIR"
chmod 700 "$KEYSTORE_DIR"

STORE_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
# PKCS12 keystores ignore a separate -keypass; the key password is silently
# forced equal to the store password. Use the same value for both so secrets
# agree with reality.
KEY_PASSWORD="$STORE_PASSWORD"

echo ">>> Generating keystore…"
keytool -genkeypair \
  -keystore "$KEYSTORE_PATH" \
  -storetype PKCS12 \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 \
  -validity "$VALIDITY_DAYS" \
  -storepass "$STORE_PASSWORD" -keypass "$KEY_PASSWORD" \
  -dname "CN=$PROJECT, O=alexsiri7, L=Unknown, S=Unknown, C=US" \
  >/dev/null 2>&1

chmod 600 "$KEYSTORE_PATH"

FINGERPRINT=$(keytool -list -v -keystore "$KEYSTORE_PATH" -storepass "$STORE_PASSWORD" -alias "$ALIAS" 2>/dev/null | awk '/SHA256:/ {print $2; exit}')

cat > "$CREDS_PATH" <<EOF
# Android release keystore credentials — KEEP SECRET
# Generated: $(date -Is)
# Repo: $REPO

KEYSTORE_PATH=$KEYSTORE_PATH
KEYSTORE_STORE_PASSWORD=$STORE_PASSWORD
KEYSTORE_KEY_PASSWORD=$KEY_PASSWORD
KEYSTORE_KEY_ALIAS=$ALIAS
SHA256_FINGERPRINT=$FINGERPRINT
EOF
chmod 600 "$CREDS_PATH"

echo ">>> Uploading secrets to $REPO…"
KEYSTORE_B64=$(base64 -w0 < "$KEYSTORE_PATH")
printf '%s' "$KEYSTORE_B64"          | gh secret set KEYSTORE_BASE64         --repo "$REPO"
printf '%s' "$STORE_PASSWORD"        | gh secret set KEYSTORE_STORE_PASSWORD --repo "$REPO"
printf '%s' "$KEY_PASSWORD"          | gh secret set KEYSTORE_KEY_PASSWORD   --repo "$REPO"
printf '%s' "$ALIAS"                 | gh secret set KEYSTORE_KEY_ALIAS      --repo "$REPO"
unset KEYSTORE_B64

cat <<EOF

>>> Done.

Keystore : $KEYSTORE_PATH
Creds    : $CREDS_PATH
SHA256   : $FINGERPRINT

Secrets uploaded to $REPO:
  KEYSTORE_BASE64
  KEYSTORE_STORE_PASSWORD
  KEYSTORE_KEY_PASSWORD
  KEYSTORE_KEY_ALIAS

Back up both files above. If you ever lose them you cannot update users'
installed apps — a new keystore forces uninstall+reinstall.
EOF
