#!/usr/bin/env bash
# auto-apk-sync.sh — every tick: pull the latest signed APK per project from
# the repo's CI, and install it on any connected Android device that's still
# running an older build.
#
# Installs use `adb install -r -d` — preserves app data; only works if
# signatures match (which they do, because CI uses our real keystore).
#
# Per-(project, device) state lives in ~/.apk-sync-state/<serial>-<project>.sha
# so the same APK is installed at most once per device.
#
# Crontab:
#   */5 * * * * <repo>/ops/cron/auto-apk-sync.sh >> /tmp/apk-sync.log 2>&1

set -uo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

# Projects to sync: project-name → "owner/repo:workflow:artifact-pattern"
# Artifact-pattern matches the real-keystore APK artifact name prefix.
declare -A PROJECTS
PROJECTS[un-reminder]="alexsiri7/un-reminder:Release:app-release-"
PROJECTS[cosmic-match]="alexsiri7/cosmic-match:CI:release-apk"

APK_DIR="$HOME/apks"
STATE_DIR="$HOME/.apk-sync-state"
LOG_PREFIX="[apk-sync]"

mkdir -p "$APK_DIR" "$STATE_DIR"

log() { echo "$(date -Is) $LOG_PREFIX $*"; }

# Fetch latest successful APK on main for one project. Writes to
# $APK_DIR/<project>-<sha>.apk and updates $APK_DIR/<project>-latest.apk.
# Returns 0 on change, 1 on no-op, 2 on error.
fetch_one() {
  local project="$1" repo="$2" workflow="$3" artifact_prefix="$4"
  local run_info run_id sha
  run_info=$(gh run list --repo "$repo" --workflow "$workflow" \
    --branch main --status success --limit 1 \
    --json databaseId,headSha 2>/dev/null) || return 2
  run_id=$(echo "$run_info" | jq -r '.[0].databaseId // empty')
  sha=$(echo "$run_info"   | jq -r '.[0].headSha // empty' | cut -c1-7)
  [ -z "$run_id" ] && return 2

  local dst="$APK_DIR/${project}-${sha}.apk"
  local link="$APK_DIR/${project}-latest.apk"
  # Fast path: same SHA already pointed to → no download.
  if [ -e "$link" ] && [ "$(readlink "$link")" = "$(basename "$dst")" ] && [ -s "$dst" ]; then
    return 1
  fi

  local artifacts artifact_name
  artifacts=$(gh api "repos/$repo/actions/runs/$run_id/artifacts" \
    --jq '.artifacts[] | select(.expired == false) | .name' 2>/dev/null) || return 2
  artifact_name=$(echo "$artifacts" | grep -E "^${artifact_prefix}" | grep -v "ci-throwaway" | head -n1)
  [ -z "$artifact_name" ] && return 2

  local tmpdir
  tmpdir=$(mktemp -d)
  if ! gh run download "$run_id" --repo "$repo" --name "$artifact_name" --dir "$tmpdir" >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    return 2
  fi
  local src_apk
  src_apk=$(find "$tmpdir" -name '*.apk' -print -quit)
  if [ -z "$src_apk" ]; then
    rm -rf "$tmpdir"
    return 2
  fi
  mv -f "$src_apk" "$dst"
  ln -sf "$(basename "$dst")" "$link"
  rm -rf "$tmpdir"
  log "$project: fetched $sha (run $run_id)"
  return 0
}

# Locate an aapt binary (prefers highest build-tools version). Empty if none.
find_aapt() {
  local sdk="${ANDROID_HOME:-$HOME/Android/Sdk}"
  local bt="$sdk/build-tools"
  [ -d "$bt" ] || { command -v aapt 2>/dev/null; return; }
  local latest
  latest=$(ls -1 "$bt" 2>/dev/null | sort -V | tail -n1)
  [ -n "$latest" ] || return
  if [ -x "$bt/$latest/aapt" ]; then
    echo "$bt/$latest/aapt"
  elif [ -x "$bt/$latest/aapt2" ]; then
    echo "$bt/$latest/aapt2"
  else
    command -v aapt 2>/dev/null
  fi
}

# Extract the android package name from an APK. Echoes the name or empty.
get_pkg_name() {
  local apk="$1" aapt pkg
  aapt=$(find_aapt)
  [ -z "$aapt" ] && return 1
  pkg=$("$aapt" dump badging "$apk" 2>/dev/null | awk -F"'" '/^package: name=/{print $2; exit}')
  [ -n "$pkg" ] && echo "$pkg"
}

# Sanity-check the adb channel for a device; retries once after a short sleep.
adb_channel_ready() {
  local serial="$1"
  if adb -s "$serial" shell echo ready >/dev/null 2>&1; then
    return 0
  fi
  sleep 2
  adb -s "$serial" shell echo ready >/dev/null 2>&1
}

# Classify adb install stderr: echoes one of sig_mismatch|parse|transient.
classify_install_err() {
  local out="$1"
  if [[ "$out" == *INSTALL_FAILED_UPDATE_INCOMPATIBLE* ]]; then
    echo "sig_mismatch"
  elif [[ "$out" == *INSTALL_PARSE_FAILED* || "$out" == *INSTALL_FAILED_INVALID_APK* ]]; then
    echo "parse"
  else
    echo "transient"
  fi
}

# Compare local "latest" symlink against recorded install state per device;
# if different, adb install -r. Retries transient failures; auto-uninstalls
# on signature mismatch.
install_if_new() {
  local project="$1" serial="$2"
  local link="$APK_DIR/${project}-latest.apk"
  [ -e "$link" ] || return 0
  local cur
  cur=$(readlink "$link")
  local state_file="$STATE_DIR/${serial}-${project}.sha"
  local prev=""
  [ -f "$state_file" ] && prev=$(cat "$state_file")
  if [ "$cur" = "$prev" ]; then
    return 0
  fi

  # Stabilisation: brief sleep + adb channel recheck.
  sleep 1
  if ! adb_channel_ready "$serial"; then
    log "$project: adb channel not ready on $serial — skipping this tick"
    return 1
  fi

  # Emit the canonical "installing" line (daemon regex depends on this exact shape).
  log "$project: installing $cur on $serial (prev=$prev)"

  local max_attempts=3 attempt=1 out cls rc=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if [ "$attempt" -gt 1 ]; then
      adb -s "$serial" wait-for-device >/dev/null 2>&1 &
      local wpid=$!
      ( sleep 5; kill "$wpid" 2>/dev/null ) >/dev/null 2>&1 &
      wait "$wpid" 2>/dev/null
      log "$project: installing (retry $attempt/$max_attempts) $cur on $serial"
    fi

    if out=$(adb -s "$serial" install -r -d "$link" 2>&1); then
      echo "$cur" > "$state_file"
      log "$project: installed $cur on $serial"
      return 0
    fi

    cls=$(classify_install_err "$out")
    case "$cls" in
      sig_mismatch)
        local pkg=""
        pkg=$(get_pkg_name "$link" || true)
        if [ -z "$pkg" ]; then
          log "$project: sig mismatch on $serial but could not derive package name — aborting"
          log "$project: install failed on $serial — $out"
          return 1
        fi
        log "$project: sig mismatch on $serial — uninstalling $pkg and retrying"
        adb -s "$serial" uninstall "$pkg" >/dev/null 2>&1 || true
        if out=$(adb -s "$serial" install -r -d "$link" 2>&1); then
          echo "$cur" > "$state_file"
          log "$project: installed $cur on $serial"
          return 0
        fi
        log "$project: install failed on $serial — $out"
        return 1
        ;;
      parse)
        log "$project: install failed on $serial — $out"
        return 1
        ;;
      transient)
        if [ "$attempt" -ge "$max_attempts" ]; then
          log "$project: install failed on $serial — $out"
          return 1
        fi
        # Backoff: 2s before retry 2, 5s before retry 3.
        if [ "$attempt" -eq 1 ]; then sleep 2; else sleep 5; fi
        ;;
    esac
    attempt=$((attempt + 1))
  done
  return $rc
}

# ----------------------------------------------------------------------------
# 1. Fetch latest APKs for every project.
for project in "${!PROJECTS[@]}"; do
  IFS=':' read -r repo workflow artifact_prefix <<<"${PROJECTS[$project]}"
  fetch_one "$project" "$repo" "$workflow" "$artifact_prefix"
done

# 2. Install to any connected devices.
mapfile -t DEVICES < <(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')
if [ "${#DEVICES[@]}" -eq 0 ]; then
  exit 0
fi

for serial in "${DEVICES[@]}"; do
  for project in "${!PROJECTS[@]}"; do
    install_if_new "$project" "$serial"
  done
done
