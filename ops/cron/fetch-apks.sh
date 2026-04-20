#!/usr/bin/env bash
# fetch-apks.sh — download the latest signed APKs from GitHub Actions for
# our Android apps. Writes to ~/apks/<project>-<sha>.apk and symlinks
# ~/apks/<project>-latest.apk to the most recent one.
#
# Usage:
#   fetch-apks.sh                         # fetch all supported repos
#   fetch-apks.sh un-reminder             # just this one
#   fetch-apks.sh un-reminder cosmic-match

set -uo pipefail

OWNER="alexsiri7"
APK_DIR="$HOME/apks"
mkdir -p "$APK_DIR"

# repo:workflow:artifact-name
REPOS=(
  "un-reminder:Release:app-release-"       # artifact name starts with this
  "cosmic-match:CI:release-apk"
)

if [ $# -gt 0 ]; then
  WANT=("$@")
else
  WANT=()
  for entry in "${REPOS[@]}"; do WANT+=("${entry%%:*}"); done
fi

fetch_one() {
  local project="$1" workflow="$2" artifact_pattern="$3"
  local repo="$OWNER/$project"

  echo ">>> $project ($repo)"

  # Latest successful run on main for this workflow.
  local run_info
  run_info=$(gh run list --repo "$repo" --workflow "$workflow" \
    --branch main --status success --limit 1 \
    --json databaseId,headSha,createdAt 2>/dev/null)
  local run_id sha created
  run_id=$(echo "$run_info" | jq -r '.[0].databaseId // empty')
  sha=$(echo "$run_info"    | jq -r '.[0].headSha // empty' | cut -c1-7)
  created=$(echo "$run_info"| jq -r '.[0].createdAt // empty')

  if [ -z "$run_id" ]; then
    echo "  no successful $workflow run on main — skipping"
    return 1
  fi
  echo "  run $run_id, sha $sha, $created"

  # Find an artifact whose name matches our pattern and is not a CI throwaway.
  local artifacts artifact_name
  artifacts=$(gh api "repos/$repo/actions/runs/$run_id/artifacts" \
    --jq '.artifacts[] | select(.expired == false) | .name' 2>/dev/null)
  artifact_name=$(echo "$artifacts" | grep -E "^${artifact_pattern}" | grep -v "ci-throwaway" | head -n1)

  if [ -z "$artifact_name" ]; then
    echo "  no matching signed-APK artifact in run $run_id"
    echo "  available: $(echo "$artifacts" | tr '\n' ' ')"
    return 1
  fi
  echo "  artifact: $artifact_name"

  # Download to a temp dir, then move the .apk out.
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  if ! gh run download "$run_id" --repo "$repo" --name "$artifact_name" --dir "$tmpdir" >/dev/null 2>&1; then
    echo "  gh run download failed"
    return 1
  fi

  local src_apk
  src_apk=$(find "$tmpdir" -name '*.apk' -print -quit)
  if [ -z "$src_apk" ]; then
    echo "  artifact contained no .apk file"
    return 1
  fi

  local dst="$APK_DIR/${project}-${sha}.apk"
  mv -f "$src_apk" "$dst"
  ln -sf "$(basename "$dst")" "$APK_DIR/${project}-latest.apk"
  echo "  saved → $dst"
  echo "  symlink → $APK_DIR/${project}-latest.apk"
}

failed=0
for project in "${WANT[@]}"; do
  match=""
  for entry in "${REPOS[@]}"; do
    if [ "${entry%%:*}" = "$project" ]; then match="$entry"; break; fi
  done
  if [ -z "$match" ]; then
    echo ">>> $project: not a known Android repo, skipping"
    continue
  fi
  # shellcheck disable=SC2162
  IFS=':' read name workflow artifact <<<"$match"
  fetch_one "$name" "$workflow" "$artifact" || failed=$((failed + 1))
done

echo
if [ "$failed" -eq 0 ]; then
  echo "All fetched. APKs in $APK_DIR:"
else
  echo "$failed project(s) had problems. APKs in $APK_DIR:"
fi
ls -la "$APK_DIR"/*-latest.apk 2>/dev/null || true
