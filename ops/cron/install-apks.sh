#!/usr/bin/env bash
# install-apks.sh — install fetched APKs to a connected Android phone via adb.
#
# Usage:
#   install-apks.sh                     # install all *-latest.apk in ~/apks
#   install-apks.sh un-reminder         # just this one
#   install-apks.sh /path/to/file.apk   # install a specific file

set -uo pipefail

APK_DIR="$HOME/apks"

if ! command -v adb >/dev/null; then
  echo "adb not installed. On Debian/Ubuntu: sudo apt install android-tools-adb" >&2
  exit 1
fi

# Enumerate connected devices (skip 'unauthorized' and 'offline').
mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')

if [ "${#DEVICES[@]}" -eq 0 ]; then
  echo "No authorized Android device connected." >&2
  echo "Checklist:" >&2
  echo "  1. Plug the phone in via USB." >&2
  echo "  2. Enable Developer options → USB debugging on the phone." >&2
  echo "  3. Accept the RSA fingerprint prompt on the phone when adb attaches." >&2
  echo "  4. Confirm with: adb devices" >&2
  exit 1
fi

echo "Connected device(s): ${DEVICES[*]}"

TARGETS=()
if [ $# -eq 0 ]; then
  # Install all -latest.apk files
  shopt -s nullglob
  for f in "$APK_DIR"/*-latest.apk; do TARGETS+=("$f"); done
  shopt -u nullglob
else
  for arg in "$@"; do
    if [ -f "$arg" ]; then
      TARGETS+=("$arg")
    elif [ -f "$APK_DIR/${arg}-latest.apk" ]; then
      TARGETS+=("$APK_DIR/${arg}-latest.apk")
    else
      echo "Not found: $arg (neither a path nor a project name in $APK_DIR)" >&2
      exit 1
    fi
  done
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "No APKs to install. Run fetch-apks.sh first." >&2
  exit 1
fi

FAILED=0
for apk in "${TARGETS[@]}"; do
  # Resolve symlinks for display clarity.
  real=$(readlink -f "$apk" 2>/dev/null || echo "$apk")
  echo
  echo ">>> Installing $(basename "$apk") ($(basename "$real"))"
  for dev in "${DEVICES[@]}"; do
    echo "    → device $dev"
    # -r: reinstall keeping data. -d: allow version downgrade.
    if ! adb -s "$dev" install -r -d "$apk"; then
      echo "    install failed on $dev (signature mismatch? uninstall first with: adb -s $dev uninstall <package>)" >&2
      FAILED=$((FAILED + 1))
    fi
  done
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All installed."
else
  echo "$FAILED install(s) failed."
  exit 1
fi
