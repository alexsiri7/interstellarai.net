#!/usr/bin/env bash
# Which projects daily-release-cron.sh releases, and a flag for the ones it
# missed.
#
# Why (#248): the cron hardcoded the 7 original projects, so every repo
# onboarded later (catscape-watchface, zoomies, punland, ...) was never
# released and nothing said so. The cron now releases every project in
# archon-projects.txt except those this lib excludes, and pipeline-health
# flags a project whose main has gone unreleased for 48h by the same rules,
# so a missing clone or a broken cron surfaces as well.
#
#   source "$SCRIPT_DIR/lib/releases.sh"
#   release_opted_out <project>      # listed in DAILY_RELEASE_OPT_OUT
#                                    # (env or DAILY_RELEASE_OPT_OUT_FILE)
#   release_classify <project>       # 0 + "push <path>": a release*.yml runs
#                                    # on push to main; 2: read failed; 3: no
#                                    # release*.yml at all; else 1, and how a
#                                    # non-push release*.yml wants releasing:
#                                    # rc 1 echoes "tag <path> <pattern>" (its
#                                    # push trigger has a tags pattern),
#                                    # "dispatch <path>" (a workflow_dispatch
#                                    # trigger instead), or "none <path>"
#                                    # (neither, e.g. a pull_request-only
#                                    # workflow)
#   release_latest_tag_by_name        # <tag...> on stdin -> the newest by name
#   release_tag_for_pattern <pattern> # a new tag matching <pattern> for today
#   release_lag_check <project>      # pipeline-health: ntfy once per episode
#   release_lag_note <project>       # pipeline-status: "" or the repo's line
#
# A repo's release workflow is a file on main named
# .github/workflows/release*.yml|yaml. daily-release-cron.sh reads its
# trigger shape (#248): a `push: tags` pattern means create a tag matching
# it; a `workflow_dispatch` trigger means dispatch the workflow with its
# defaults; neither — including a workflow that only runs on a bare push to
# main, which produces no release-* tag or GitHub release on its own — means
# fall back to its own dated release-* tag, the same fallback tag used when
# there is no release*.yml at all. Below, a project with a tag-pattern or
# dispatch release*.yml is tracked by real release evidence (the newest tag
# matching its pattern, or its newest successful dispatch run) instead of
# that tag; one with neither, or no release*.yml at all, is tracked by that
# fallback release-* tag.
#
# One marker per lagging project in RELEASE_LAG_STATE_DIR/<project>, key=value
# lines (since, tag, ahead, oldest, notified), cleared once main is released
# again or the project stops being the cron's to release. A read that fails
# changes nothing immediately, except that a project whose release workflow
# stays unreadable for over RELEASE_LAG_SECONDS gets one "Release workflow
# unreadable" ntfy per episode and a marker in
# RELEASE_LAG_STATE_DIR/<project>.unreadable, cleared on the first good read
# or on opt-out.

[ -n "${_ARCHON_RELEASES_SH:-}" ] && return 0
_ARCHON_RELEASES_SH=1

# shellcheck source=lib/deadlines.sh
source "$(dirname "${BASH_SOURCE[0]}")/deadlines.sh"

RELEASE_OWNER="${RELEASE_OWNER:-alexsiri7}"
# Space-separated slugs daily-release-cron.sh must never release, from the
# environment or $DAILY_RELEASE_OPT_OUT_FILE (default
# ~/.config/archon-cron/daily-release.env, sourced when present, values there
# win — same shape as lib/trust.sh's trust.env). The scheduled cron starts
# with none of an interactive shell's exported variables, so an opt-out only
# ever exported by hand never reaches the 08:00 run; the file does.
DAILY_RELEASE_OPT_OUT="${DAILY_RELEASE_OPT_OUT:-}"
DAILY_RELEASE_OPT_OUT_FILE="${DAILY_RELEASE_OPT_OUT_FILE:-$HOME/.config/archon-cron/daily-release.env}"
if [ -r "$DAILY_RELEASE_OPT_OUT_FILE" ]; then
  # shellcheck source=/dev/null
  . "$DAILY_RELEASE_OPT_OUT_FILE"
fi
RELEASE_LAG_STATE_DIR="${RELEASE_LAG_STATE_DIR:-$HOME/.archon/state/unreleased}"
RELEASE_LAG_SECONDS="${RELEASE_LAG_SECONDS:-172800}"

# The fallback release-tag pattern, for a project with no push:tags or
# workflow_dispatch release*.yml (mode "none"/"push"): daily-release-cron.sh
# creates these and reads them back locally; release_lag_check reads them
# back remotely via the GitHub API. One shared constant so both sides can
# never drift apart (#248 R2).
RELEASE_FALLBACK_TAG_PATTERN="release-*"

# release_now — the clock (RELEASE_NOW overrides it for tests).
release_now() { echo "${RELEASE_NOW:-$(date +%s)}"; }

release_opted_out() {
  case " $DAILY_RELEASE_OPT_OUT " in *" $1 "*) return 0 ;; esac
  return 1
}

# _release_trigger_shape — the workflow on stdin's release-relevant trigger
# shape, one line on stdout: "push" (runs on a push to main: `on:` names push
# with no branch filter, or branches has a glob matching main, or
# branches-ignore has no glob matching main), "tag:<pattern>" (a push trigger
# with a tags pattern that does not hit main), "dispatch" (a
# workflow_dispatch trigger, no main-hitting or tags-pattern push), or "none"
# (neither).
_release_trigger_shape() {
  python3 -c '
import fnmatch, re, sys

Q = chr(34) + chr(39)
PUSH_FILTER_KEYS = ("branches-ignore", "branches", "tags", "tags-ignore")
lines = [re.sub(r"\s+#.*$", "", l.rstrip()) for l in sys.stdin.read().splitlines()]
lines = [l for l in lines if l.strip() and not l.lstrip().startswith("#")]

def ind(l):
    return len(l) - len(l.lstrip())

def items(v):
    v = v.strip()
    if v.startswith("["):
        v = v.strip("[]")
    return [x.strip().strip(Q) for x in v.split(",") if x.strip()]

def children(start, base):
    out = []
    for l in lines[start:]:
        if ind(l) <= base:
            break
        out.append(l)
    return out

def push_hits_main(filt):
    if "branches" in filt:
        return any(fnmatch.fnmatch("main", p) for p in filt["branches"])
    if "branches-ignore" in filt:
        return not any(fnmatch.fnmatch("main", p) for p in filt["branches-ignore"])
    return "tags" not in filt and "tags-ignore" not in filt

def split_top(s):
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts

def consume_flow(first, rest):
    def delta(s):
        d = 0
        for ch in s:
            if ch in "{[":
                d += 1
            elif ch in "}]":
                d -= 1
        return d
    buf, depth, consumed = first, delta(first), 0
    for nxt in rest:
        if depth <= 0:
            break
        buf += " " + nxt.strip()
        depth += delta(nxt)
        consumed += 1
    return buf, consumed

def decide(push_filt, has_dispatch):
    if push_filt is not None and push_hits_main(push_filt):
        return "push"
    if push_filt is not None and push_filt.get("tags"):
        return "tag:" + push_filt["tags"][0]
    if has_dispatch:
        return "dispatch"
    return "none"

on_re = re.compile(r"^(on|[\x22\x27]on[\x22\x27]|true)\s*:\s*(.*)$")
for i, l in enumerate(lines):
    m = on_re.match(l) if ind(l) == 0 else None
    if not m:
        continue
    val = m.group(2)
    if val:
        if val.startswith("{"):
            joined, _ = consume_flow(val.strip(), lines[i + 1:])
            inner = joined.strip()
            inner = inner[1:-1] if inner.endswith("}") else inner[1:]
            push_filt, has_dispatch = None, False
            for part in split_top(inner):
                key, _, v = part.strip().partition(":")
                key = key.strip(Q)
                if key == "workflow_dispatch":
                    has_dispatch = True
                    continue
                if key != "push":
                    continue
                v, filt = v.strip(), {}
                if v.startswith("{"):
                    for k in PUSH_FILTER_KEYS:
                        mm = re.search(r"(^|[{,\s])" + k + r"\s*:\s*(\[[^\]]*\]|[^,}]+)", v)
                        if mm:
                            filt[k] = items(mm.group(2))
                push_filt = filt
            print(decide(push_filt, has_dispatch))
        else:
            vals = items(val)
            if "push" in vals:
                print("push")
            elif "workflow_dispatch" in vals:
                print("dispatch")
            else:
                print("none")
        sys.exit(0)
    body = children(i + 1, 0)
    if not body:
        print("none")
        sys.exit(0)
    kid = ind(body[0])
    push_filt = None
    has_dispatch = False
    skip_until = -1
    for j, b in enumerate(body):
        if j <= skip_until:
            continue
        if ind(b) != kid:
            continue
        s = b.strip()
        if s.startswith("- "):
            s = s[2:].strip()
        key, _, v = s.partition(":")
        key = key.strip(Q)
        if key == "workflow_dispatch":
            has_dispatch = True
            continue
        if key != "push":
            continue
        v, filt = v.strip(), {}
        if v.startswith("{"):
            joined, consumed = consume_flow(v, body[j + 1:])
            skip_until = j + consumed
            for k in PUSH_FILTER_KEYS:
                mm = re.search(r"(^|[{,\s])" + k + r"\s*:\s*(\[[^\]]*\]|[^,}]+)", joined)
                if mm:
                    filt[k] = items(mm.group(2))
                    joined = joined.replace(mm.group(0), mm.group(1))
        else:
            sub, cur = [], None
            for r in body[j + 1:]:
                if ind(r) <= kid:
                    break
                sub.append(r)
            ck = ind(sub[0]) if sub else 0
            for c in sub:
                s = c.strip()
                if s.startswith("- ") and cur:
                    filt[cur].append(s[2:].strip().strip(Q))
                elif ind(c) == ck:
                    k, _, cv = s.partition(":")
                    cur = k.strip(Q)
                    filt[cur] = items(cv) if cv.strip() else []
        push_filt = filt
    print(decide(push_filt, has_dispatch))
    sys.exit(0)
print("none")
sys.exit(0)
'
}

# release_classify <project> — scans every release*.yml|yaml on main and
# reports the best trigger shape found, ranked tag > push > dispatch > none
# (#248 R1: a file's push-to-main trigger no longer stops the scan, so a tag
# pattern in another file still wins). Within a single file, a tags pattern
# in the same push block as a main-hitting branch filter does not count as
# "tag" — that block already self-releases on every push to main, at
# whatever track its own workflow picks, so it is "push", not an unattended
# tag-triggered rollout (#248 R1). On stdout: "tag <path> <pattern>" (rc 1, a
# push:tags pattern whose push trigger does not also hit main — preferred,
# per #248), else "push <path>" (rc 0, a push-to-main trigger and no
# tag-pattern file that doesn't also hit main — produces no release-* tag or
# dated release on its own), else "dispatch <path>" (rc 1, a
# workflow_dispatch trigger and no tag or push-to-main file), else "none
# <path>" (rc 1, release*.yml exists but no file's trigger is usable). rc 2:
# a read failed. rc 3: no release*.yml at all.
release_classify() {
  local project="$1" paths path content shape pattern first_path=""
  local best_mode="none" best_path="" best_pattern=""
  paths=$(gh api "repos/$RELEASE_OWNER/$project/git/trees/main?recursive=1" \
    --jq '.tree[] | select(.type == "blob") | .path | select(test("^\\.github/workflows/release[^/]*\\.ya?ml$"; "i"))' \
    2>/dev/null) || return 2
  [ -z "$paths" ] && return 3
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -z "$first_path" ] && first_path="$path"
    content=$(gh api "repos/$RELEASE_OWNER/$project/contents/$path?ref=main" --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null) || return 2
    [ -n "$content" ] || return 2
    shape=$(printf '%s\n' "$content" | _release_trigger_shape) || return 2
    case "$shape" in
      tag:*)
        if [ "$best_mode" != tag ]; then
          best_mode=tag; best_path="$path"; best_pattern="${shape#tag:}"
        fi
        ;;
      push)
        case "$best_mode" in
          tag | push) ;;
          *) best_mode=push; best_path="$path" ;;
        esac
        ;;
      dispatch)
        [ "$best_mode" = none ] && { best_mode=dispatch; best_path="$path"; }
        ;;
    esac
    # tag is the top rank (#248 R3): once found, no later file's shape —
    # readable or not — can change the answer, so stop scanning rather than
    # let a later file's transient read failure abort a classification that
    # is already settled.
    [ "$best_mode" = tag ] && break
  done <<< "$paths"
  case "$best_mode" in
    tag) echo "tag $best_path $best_pattern"; return 1 ;;
    dispatch) echo "dispatch $best_path"; return 1 ;;
    push) echo "push $best_path"; return 0 ;;
    *) echo "none $first_path"; return 1 ;;
  esac
}

# release_mode <project> — the shared decode of release_classify's rc/stdout
# protocol (#248 / seam R5): sets mode ("push", "tag", "dispatch" or "none"),
# path (the release*.yml that won, or "" when rc is 2 or 3) and pattern (its
# push:tags pattern, mode "tag" only) in the caller's scope — the caller must
# declare them `local` first — and returns release_classify's rc unchanged.
release_mode() {
  local project="$1" line rc=0
  line=$(release_classify "$project") || rc=$?
  mode=none; path=""; pattern=""
  case "$rc" in
    0) mode=push; path="${line#push }" ;;
    1) read -r mode path pattern <<< "$line" ;;
  esac
  return "$rc"
}

# release_latest_tag_by_name <tag...> on stdin, one per line — the newest by
# name (version sort, so "v2026.11.10" outranks "v2026.11.9" the same way
# zero-padded "release-2026-11-10" outranks "release-2026-11-09"). The one
# shared rule daily-release-cron.sh and release_lag_check both need to agree
# on which tag is "the last release" (#248 / seam R4).
release_latest_tag_by_name() {
  sort -V | tail -n1
}

# _release_glob_prefix <pattern> — the literal text before <pattern>'s first
# glob metacharacter ("*", "?" or "[..]"), for the matching-refs prefix search
# (e.g. "v*" -> "v", "v[0-9].0" -> "v").
_release_glob_prefix() {
  local p="$1"
  printf '%s' "${p%%[*?[]*}"
}

# release_tag_for_pattern <pattern> — a new tag matching <pattern> for today
# (e.g. "v*" -> "v2026.11.1", "v*.*.*" -> "v2026.11.1"): each "*" in <pattern>
# spliced with the matching dotted component of today's date, in order (year,
# month, day), except the last "*" gets any date components the earlier ones
# didn't consume (so one or two "*" still produce a tag unique to the day,
# e.g. "v*.*" -> "v2026.11.1"); a pattern with more than three "*" repeats the
# day for the rest. A pattern with no "*" is used as-is (daily-release-cron.sh
# then skips it once it exists, like any other already-released tag).
#
# When that primary candidate uses glob syntax no git ref can contain ("?",
# "[...]"), falls back to <pattern>'s literal prefix (_release_glob_prefix)
# plus today's full date, accepted only if it still satisfies <pattern> under
# the same glob rules release_lag_check matches tags with — e.g. "v[0-9]*" ->
# "v2026.11.1" (the splice "v[0-9]2026.11.1" is rejected by git, but the
# prefix candidate both is a valid ref and matches the pattern). Prints
# nothing and returns 1 when neither candidate satisfies <pattern>: the
# caller falls back to the dated release-YYYY-MM-DD path.
release_tag_for_pattern() {
  local pattern="$1" out
  case "$pattern" in
    *'*'*)
      local rest="$pattern" rest2="$pattern" seg n=0
      while [[ "$rest2" == *'*'* ]]; do n=$((n + 1)); rest2="${rest2#*\*}"; done
      local -a date_parts
      IFS=. read -r -a date_parts <<< "$(date -u +%Y.%-m.%-d)"
      local total=${#date_parts[@]} i j joined
      local -a assign=()
      for ((i = 0; i < n; i++)); do
        if [ "$n" -le "$total" ] && [ "$i" -eq "$((n - 1))" ]; then
          joined=""
          for ((j = i; j < total; j++)); do
            [ "$j" -gt "$i" ] && joined+="."
            joined+="${date_parts[j]}"
          done
          assign[i]="$joined"
        elif [ "$i" -lt "$((total - 1))" ]; then
          assign[i]="${date_parts[i]}"
        else
          assign[i]="${date_parts[$((total - 1))]}"
        fi
      done
      i=0
      out=""
      while [[ "$rest" == *'*'* ]]; do
        seg="${rest%%\**}"
        # Two "*" with no literal text between them (adjacent wildcards)
        # would otherwise splice their date components back to back with no
        # separator, letting sort -V compare the wrong digit runs across a
        # year boundary (#248 R2) — insert one so each spliced value stays
        # its own digit run.
        [ "$i" -gt 0 ] && [ -z "$seg" ] && out+="."
        out+="$seg${assign[i]}"
        i=$((i + 1))
        rest="${rest#*\*}"
      done
      out+="$rest"
      ;;
    *) out="$pattern" ;;
  esac
  if git check-ref-format "refs/tags/$out" 2>/dev/null; then
    printf '%s' "$out"
    return 0
  fi
  local fallback
  fallback="$(_release_glob_prefix "$pattern")$(date -u +%Y.%-m.%-d)"
  git check-ref-format "refs/tags/$fallback" 2>/dev/null || return 1
  # shellcheck disable=SC2254  # $pattern is a glob here, matched the same
  # way git's own "git tag -l" matches it (#248 / seam R2)
  case "$fallback" in
    $pattern) printf '%s' "$fallback" ;;
    *) return 1 ;;
  esac
}

# _release_unreadable_check <project> <now> — rc 2 (release_mode could not
# read the project's release workflows) persisting for over
# RELEASE_LAG_SECONDS gets one ntfy per episode, the same since/notified
# bookkeeping release_lag_check itself uses, in its own marker file so a
# transient read failure never clobbers a real, already-flagged lag (#248 R1).
_release_unreadable_check() {
  local project="$1" now="$2" f since notified
  f="$RELEASE_LAG_STATE_DIR/$project.unreadable"
  mkdir -p "$RELEASE_LAG_STATE_DIR" 2>/dev/null || return 0
  since=$(deadline_get "$f" since); [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
  notified=$(deadline_get "$f" notified); [[ "$notified" =~ ^[0-9]+$ ]] || notified=0
  if [ "$notified" = 0 ] && [ "$((now - since))" -ge "$RELEASE_LAG_SECONDS" ]; then
    if notify_checked "Release workflow unreadable: $project" \
         "$project: could not read its release workflow(s) on GitHub for over $((RELEASE_LAG_SECONDS / 3600))h (since $(date -u -d "@$since" '+%Y-%m-%dT%H:%M:%SZ')). daily-release-cron.sh cannot release it and release_lag_check cannot tell whether it is current. Check: the project's slug in archon-projects.txt, gh auth, and whether the repo was renamed or removed. https://github.com/$RELEASE_OWNER/$project" \
         high warning; then
      notified="$now"
    fi
  fi
  _deadline_write "$f" "since=$since" "notified=$notified" 2>/dev/null || true
}

_release_unreadable_clear() { # <project>
  local f="$RELEASE_LAG_STATE_DIR/$1.unreadable"
  [ -f "$f" ] || return 0
  rm -f "$f"
  log "release-lag: $1 — release workflow read recovered"
}

# _release_lag_evidence_unreadable_check <project> <now> — the same
# since/notified, one-ntfy-per-episode tracking as _release_unreadable_check
# above, but for a persistent failure to read release_lag_check's own lag
# evidence (a tag listing, a workflow's runs, or a commit comparison/count)
# once the release workflow itself was read fine — as opposed to rc 2, which
# is a failure to even classify the release workflow. A separate marker, so
# the two failure classes track independently and neither's episode clobbers
# the other's (#248 R2).
_release_lag_evidence_unreadable_check() {
  local project="$1" now="$2" f since notified
  f="$RELEASE_LAG_STATE_DIR/$project.evidence-unreadable"
  mkdir -p "$RELEASE_LAG_STATE_DIR" 2>/dev/null || return 0
  since=$(deadline_get "$f" since); [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
  notified=$(deadline_get "$f" notified); [[ "$notified" =~ ^[0-9]+$ ]] || notified=0
  if [ "$notified" = 0 ] && [ "$((now - since))" -ge "$RELEASE_LAG_SECONDS" ]; then
    if notify_checked "Release lag evidence unreadable: $project" \
         "$project: could not read the GitHub evidence release_lag_check needs (a tag listing, a workflow's runs, or a commit comparison/count) for over $((RELEASE_LAG_SECONDS / 3600))h (since $(date -u -d "@$since" '+%Y-%m-%dT%H:%M:%SZ')). release_lag_check cannot tell whether $project is current. Check: gh auth and GitHub's API status. https://github.com/$RELEASE_OWNER/$project" \
         high warning; then
      notified="$now"
    fi
  fi
  _deadline_write "$f" "since=$since" "notified=$notified" 2>/dev/null || true
}

_release_lag_evidence_unreadable_clear() { # <project>
  local f="$RELEASE_LAG_STATE_DIR/$1.evidence-unreadable"
  [ -f "$f" ] || return 0
  rm -f "$f"
  log "release-lag: $1 — lag evidence read recovered"
}

# _release_dispatch_evidence <project> <path> — the newest successful
# workflow_dispatch run's created_at for release*.yml at <path> in <project>,
# or "" if none; rc nonzero when the read itself fails. The one query for "is
# this workflow's dispatch trigger already current?", shared by
# release_one_dispatch, release_lag_check's dispatch case, and both the tag
# mode's and release_one_tag's no-matching-tag-yet fallback — a tag-pattern
# project not yet tagged by the cron may already be current via a hand or
# dispatch run (#248 R1, R2/R3).
_release_dispatch_evidence() {
  local project="$1" path="$2"
  gh api "repos/$RELEASE_OWNER/$project/actions/workflows/${path##*/}/runs?event=workflow_dispatch" \
    --jq '[.workflow_runs[] | select(.status=="completed" and .conclusion=="success")][0].created_at // ""' 2>/dev/null
}

# release_lag_check <project> — commits on main not yet covered by real
# release evidence, the oldest of them committed over RELEASE_LAG_SECONDS ago,
# on a project the cron would release. The evidence depends on release_classify:
#   tag       newest tag matching the workflow's own push:tags pattern, or —
#             when no such tag exists yet (the project is released by hand or
#             dispatch rather than by the cron's own tag push) — the
#             workflow's newest successful workflow_dispatch run, the same
#             evidence dispatch mode uses (#248 R2, R3)
#   dispatch  the workflow's newest successful workflow_dispatch run
#   none      no usable trigger at all (no release*.yml, one with neither a
#             tag-pattern nor a dispatch trigger, or one that only runs on
#             push to main — that alone produces no release-* tag or dated
#             release either): the newest release-* tag daily-release-cron.sh
#             itself creates (a repo with no tag: any commit that old)
# A persistent read failure — rc 2 (release_mode couldn't classify the
# workflow) or any later failure reading this function's own lag evidence —
# does not return silently: a project whose reads start failing (renamed
# repo, revoked token scope, a typo'd slug, a GitHub API outage) would
# otherwise both stop being released and stop being flagged, indistinguishable
# from a healthy one (#248 R1, R2). Tracked the same way the lag itself is —
# since/notified in a marker, one ntfy per episode — via
# _release_unreadable_check/_release_unreadable_clear for rc 2, and
# _release_lag_evidence_unreadable_check/_clear for every later read.
# Needs log and notify_checked from the caller.
release_lag_check() {
  local project="$1" now cutoff refs tag="" out ahead oldest f rc=0 mode path pattern
  now=$(release_now)
  cutoff=$(date -u -d "@$((now - RELEASE_LAG_SECONDS))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 0
  f="$RELEASE_LAG_STATE_DIR/$project"

  if release_opted_out "$project"; then
    _release_lag_clear "$project" "opted out of the daily release"
    _release_unreadable_clear "$project"
    _release_lag_evidence_unreadable_clear "$project"
    return 0
  fi

  release_mode "$project" || rc=$?
  case "$rc" in
    2) log "release-lag: $project — could not read release workflows, skipping"
       _release_unreadable_check "$project" "$now"
       return 0 ;;
  esac
  _release_unreadable_clear "$project"

  case "$mode" in
    push) mode=none ;;
  esac

  case "$mode" in
    tag)
      if ! refs=$(gh api --paginate "repos/$RELEASE_OWNER/$project/git/matching-refs/tags/$(_release_glob_prefix "$pattern")" \
            --jq '.[].ref' 2>/dev/null); then
        log "release-lag: $project — could not list $pattern tags, skipping"
        _release_lag_evidence_unreadable_check "$project" "$now"
        return 0
      fi
      tag=$(printf '%s\n' "$refs" | sed -n 's#^refs/tags/##p' | while IFS= read -r t; do
              # shellcheck disable=SC2254  # $pattern is a glob here, matched
              # the same way git's own "git tag -l" matches it (#248 / seam R4)
              case "$t" in $pattern) printf '%s\n' "$t" ;; esac
            done | release_latest_tag_by_name)
      if [ -z "$tag" ]; then
        # No tag matching the pattern exists yet — the project may still be
        # released by hand or workflow_dispatch rather than by the cron's own
        # tag push. Fall back to the same run evidence dispatch mode uses
        # instead of treating this as unreleased since the repo started
        # (#248 R2).
        if ! tag=$(_release_dispatch_evidence "$project" "$path"); then
          log "release-lag: $project — could not read $path's runs, skipping"
          _release_lag_evidence_unreadable_check "$project" "$now"
          return 0
        fi
        [ -n "$tag" ] && mode=dispatch
      fi
      ;;
    dispatch)
      if ! tag=$(_release_dispatch_evidence "$project" "$path"); then
        log "release-lag: $project — could not read $path's runs, skipping"
        _release_lag_evidence_unreadable_check "$project" "$now"
        return 0
      fi
      ;;
    none)
      if ! refs=$(gh api --paginate "repos/$RELEASE_OWNER/$project/git/matching-refs/tags/$(_release_glob_prefix "$RELEASE_FALLBACK_TAG_PATTERN")" \
            --jq '.[].ref' 2>/dev/null); then
        log "release-lag: $project — could not list release tags, skipping"
        _release_lag_evidence_unreadable_check "$project" "$now"
        return 0
      fi
      tag=$(printf '%s\n' "$refs" | sed -n 's#^refs/tags/##p' | release_latest_tag_by_name)
      ;;
  esac
  if [ -n "$tag" ]; then
    if [ "$mode" = dispatch ]; then
      local raw
      if raw=$(gh api --paginate --slurp "repos/$RELEASE_OWNER/$project/commits?sha=main&since=$tag" 2>/dev/null); then
        out=$(printf '%s' "$raw" \
          | jq -r '[.[][].commit.committer.date] as $d | "\($d|length) \($d|min // "")"' 2>/dev/null) || out=""
      else
        out=""
      fi
    else
      out=$(gh api "repos/$RELEASE_OWNER/$project/compare/$tag...main" \
        --jq '"\(.ahead_by) \([.commits[].commit.committer.date] | min // "")"' 2>/dev/null) || out=""
    fi
    ahead="${out%% *}"; oldest="${out#* }"
    if ! [[ "$ahead" =~ ^[0-9]+$ ]]; then
      log "release-lag: $project — could not compare $tag with main, skipping"
      _release_lag_evidence_unreadable_check "$project" "$now"
      return 0
    fi
    if [ "$ahead" -eq 0 ] || [[ -z "$oldest" || "$oldest" > "$cutoff" ]]; then
      ahead=0
    fi
  else
    out=$(gh api "repos/$RELEASE_OWNER/$project/commits?sha=main&until=$cutoff&per_page=1" \
      --jq 'length' 2>/dev/null) || out=""
    if ! [[ "$out" =~ ^[0-9]+$ ]]; then
      log "release-lag: $project — could not list main commits, skipping"
      _release_lag_evidence_unreadable_check "$project" "$now"
      return 0
    fi
    ahead=all; oldest="before $cutoff"
    [ "$out" -eq 0 ] && ahead=0
  fi

  _release_lag_evidence_unreadable_clear "$project"

  if [ "$ahead" = 0 ]; then
    _release_lag_clear "$project" "released again"
    return 0
  fi

  mkdir -p "$RELEASE_LAG_STATE_DIR" 2>/dev/null || return 0
  local since notified
  since=$(deadline_get "$f" since); [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
  notified=$(deadline_get "$f" notified); [[ "$notified" =~ ^[0-9]+$ ]] || notified=0
  if [ "$notified" = 0 ]; then
    if notify_checked "Unreleased: $project" \
         "$project: ${ahead} commit(s) on main not released since ${tag:-the repo started}, oldest ${oldest}. daily-release-cron.sh releases at 08:00; check ~/.local/state/archon-cron/logs/daily-release.log. https://github.com/$RELEASE_OWNER/$project/releases" \
         high warning; then
      notified="$now"
    fi
  fi
  _deadline_write "$f" "since=$since" "tag=$tag" "ahead=$ahead" "oldest=$oldest" "notified=$notified" 2>/dev/null || true
  log "release-lag: $project — $ahead unreleased commit(s), oldest $oldest"
}

_release_lag_clear() { # <project> <why>
  local f="$RELEASE_LAG_STATE_DIR/$1"
  [ -f "$f" ] || return 0
  rm -f "$f"
  log "release-lag: $1 — $2"
}

# release_lag_note <project> — "" when main is released, else a short line for
# pipeline-status.
release_lag_note() {
  local f="$RELEASE_LAG_STATE_DIR/$1" tag
  [ -f "$f" ] || return 0
  tag=$(deadline_get "$f" tag)
  printf 'UNRELEASED: %s commit(s) since %s, oldest %s' "$(deadline_get "$f" ahead)" \
    "${tag:-start}" "$(deadline_get "$f" oldest)"
}
