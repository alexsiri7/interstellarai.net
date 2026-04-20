# ops/cron

Scheduled scripts that run the archon pipeline on this machine:
- pick up new GitHub issues and dispatch archon
- keep PRs merging (rebase/fix/auto-merge)
- review PRs via archon-smart-pr-review
- watch pipeline health (CI red, zombie runs, disk pressure)
- daily release tags
- Supabase DB backups
- APK auto-sync to connected Android devices

## Secrets

Secrets are **never** committed here. Scripts load them from:

```
$ARCHON_CRON_SECRETS   (default: ~/.config/archon-cron/secrets.env, chmod 600)
```

Required keys (see individual scripts for which ones each uses):

- `ANNIE_DB_URL`, `RELI_DB_URL`, `FILMDUEL_DB_URL` — Supabase connection strings used by `backup-dbs.sh`.
- `NTFY_TOPIC` — private ntfy.sh topic for notifications. No fallback default; scripts fail loud if missing.

Set perms: `chmod 600 ~/.config/archon-cron/secrets.env`.

## Install the crontab

The file `crontab` in this directory is a committed reference. To install:

```
crontab ops/cron/crontab
```

It installs with absolute paths pointing at `/mnt/ext-fast/interstellarai.net/ops/cron/...`. Adjust paths there if this repo lives elsewhere on your machine.

## Script index

| Script | Cadence | What it does |
|---|---|---|
| `issue-pickup-cron.sh` | every 15 min | auto-label new issues, fire `archon-fix-github-issue` on oldest queued. Dep-aware: an issue is blocked if it has any open `blocked_by` dep OR any open sub-issue child (so PRDs park themselves until all phases close, then unblock for finalization). |
| `pr-maintenance-cron.sh` | every 15 min | zero-AI PR janitor: promotes green drafts, squash-merges CLEAN, fires `archon-pr-maintenance` on one dirty/behind PR per project |
| `pr-review-cron.sh` | every 5 min | fire `archon-smart-pr-review` on open non-draft PRs, once per (repo, pr, sha) |
| `pipeline-health-cron.sh` | every 30 min | main-CI-red detection, prod-deploy health (status API + HTTP probe), zombie-run reaping, disk pressure, stall detection, PR-CI retry (fires `archon-assist` on open archon PRs with failed CI). Both main-CI and PR-CI remediation are scoped to the current head SHA with an attempt counter: a new SHA resets the budget, same SHA retries up to 3 times, then ntfys "factory stuck" and backs off. Also sweeps stale `archon:in-progress` labels off closed issues (→ `archon:done`), and fires shipped-PR ntfys for merged PRs that closed issues. |
| `sweep-audits.sh` | 02:00 daily | rotating codebase audit (12-slot day-of-year rotation: `archon-architect` / `archon-security-audit` / `archon-test-audit` × filmduel / word-coach-annie / reli / cosmic-match) |
| `backup-dbs.sh` | every 3h (at :17) | Supabase → local + rclone to Google Drive |
| `daily-release-cron.sh` | 08:00 daily | tag + release per repo if main moved since last release |
| `auto-apk-sync.sh` | every 5 min | pull latest signed APK from CI, install to any connected device |
| `apk-autosync-daemon.sh` | systemd user service | event-driven counterpart to `auto-apk-sync.sh` |
| `fetch-apks.sh` / `install-apks.sh` | manual | helper CLIs for APK ops |
| `generate-android-keystore.sh` | manual, one-off per project | generate release keystore + upload to GH Actions secrets |
| `lib/archon-projects.sh` | sourced by others | loads project list from `archon-projects.txt` |
| `archon-projects.txt` | data | canonical list of managed project slugs under `alexsiri7/` |

