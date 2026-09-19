# ops/cron

Scheduled scripts that run the archon pipeline on this machine:
- pick up new GitHub issues and dispatch archon
- keep PRs merging (rebase/fix/auto-merge)
- review PRs via archon-smart-pr-review
- watch pipeline health (CI red, zombie runs, disk pressure)
- daily release tags
- Supabase DB backups
- weekly light cache trim and weekly tool-freshness report

## Secrets

Secrets are **never** committed here. Scripts load them from:

```
$ARCHON_CRON_SECRETS   (default: ~/.config/archon-cron/secrets.env, chmod 600)
```

Required keys (see individual scripts for which ones each uses):

- `ANNIE_DB_URL`, `RELI_DB_URL`, `FILMDUEL_DB_URL`, `KINDRED_DB_URL`, `LACHESIS_DB_URL` — Supabase connection strings used by `backup-dbs.sh`. Missing entries cause that DB to be skipped (not a hard failure). The URL is parsed into the libpq `PG*` environment (`lib/pg-backup.sh`) so it never appears on a command line.
- `NTFY_TOPIC` — private ntfy.sh topic for notifications. No fallback default; scripts fail loud if missing.

Set perms: `chmod 600 ~/.config/archon-cron/secrets.env`.

### pg_dump version (server is pg17, no docker)

`backup-dbs.sh` reads the server's major version first and refuses to dump with a `pg_dump` whose major version is older — `pg_dump` aborts on a version mismatch and, before #64, that abort was silently written out as a 20-byte empty archive. The Supabase servers are PostgreSQL 17; the distro's `postgresql-client` is v16, and docker (which used to supply a `postgres:17-alpine` client) is no longer installed on the host. The v17 client is a user-level install, no sudo needed:

```
~/.local/opt/postgresql-17/          # portable build from theseus-rs/postgresql-binaries
~/.local/bin/pg_dump    -> ../opt/postgresql-17/bin/pg_dump
~/.local/bin/pg_restore -> ../opt/postgresql-17/bin/pg_restore
```

Only `pg_dump` and `pg_restore` are linked; `psql` stays the system one (any psql can `SHOW server_version` and `count(*)`). cron's PATH is `/usr/bin:/bin`, so the script prepends `~/.local/bin` itself; a v16 `pg_dump` earlier on the inherited PATH loses (tested). The `OK:` log line names the binary actually used (`pg_dump v17 from /home/<user>/.local/bin/pg_dump, server v17`).

To install or upgrade (pick the newest 17.x tag from <https://github.com/theseus-rs/postgresql-binaries/releases>; the same steps apply to an 18.x tag if the servers move to 18 — then use `postgresql-18` as the directory name and re-point the symlinks):

```bash
V=17.11.0
A="postgresql-$V-x86_64-unknown-linux-gnu.tar.gz"
U="https://github.com/theseus-rs/postgresql-binaries/releases/download/$V/$A"
cd "$(mktemp -d)" && curl -fsSLO "$U" && curl -fsSLO "$U.sha256"
sha256sum -c <(awk '{print $1"  '"$A"'"}' "$A.sha256")     # must say OK
rm -rf ~/.local/opt/postgresql-17 && mkdir -p ~/.local/opt/postgresql-17
tar xzf "$A" -C ~/.local/opt/postgresql-17 --strip-components=1
ln -sfn ../opt/postgresql-17/bin/pg_dump    ~/.local/bin/pg_dump
ln -sfn ../opt/postgresql-17/bin/pg_restore ~/.local/bin/pg_restore
env -i HOME=$HOME PATH=$HOME/.local/bin:/usr/bin:/bin pg_dump --version   # 17.x, as cron sees it
```

The tarball bundles its own `libpq` (RUNPATH `$ORIGIN/../lib`); everything else it links (`libssl`, `libcrypto`, `libz`, `libzstd`, `liblz4`, krb5) comes from the system. `ldd ~/.local/opt/postgresql-17/bin/pg_dump` must show nothing "not found". When the guard trips it logs `no usable pg_dump for a v<N> server: ... local pg_dump is v<M>, server is v<N> ... upgrade ~/.local/opt/postgresql-17` for every project, exits 1 and ntfys — the fix is the block above.

### What counts as a backup

Every project is dumped `--schema=public` (all five keep their tables there; the schema is verified on the server before dumping). An archive only counts when it is >= 1 KB compressed (`PG_BACKUP_MIN_BYTES`), contains a `CREATE TABLE` for the project's sanity table (`annie."Project"`, `reli.things`, `filmduel.users`, `kindred.entries`, `lachesis.lachesis_backlog`) and a `count(*)` on that table succeeds. Otherwise the artifact is deleted, the project is logged as `ERROR: <project> backup FAILED — <reason>`, the script exits 1 and ntfys (if `NTFY_TOPIC` is set). The run is summarised in `~/.archon/pipeline-health-state/db-backup-status`; `pipeline-health-cron.sh` (`check_db_backup`) ntfys once when no verified backup has landed for `DB_BACKUP_MAX_AGE_H` (7) hours. Retention (7 days local, `rclone copy --max-age 2d` to Google Drive) is unchanged.

## Host maintenance

The weekly `system-maintenance.sh` needs root for apt, snap, journald and smartctl. It never asks: every privileged call is `sudo -n` against the exact command shapes in `ops/host/sudoers-archon-cron`, installed once (with the journald cap, unattended-upgrades, smartd and Node 24 changes) by `sudo ops/host/install.sh`. Preview with `ops/host/install.sh --dry-run`; revoke by deleting `/etc/sudoers.d/archon-cron`. Details in [`ops/host/README.md`](../host/README.md).

## Parking a PR: the `hold` label

Add the `hold` label to any open PR that must stay open and unmerged (for example an asset-upload PR whose head branch another workflow fetches from). `pr-maintenance-cron.sh` skips held PRs in every phase — no draft-to-ready flip, no auto-merge, no `archon-pr-maintenance` — and `pr-review-cron.sh` fires no review at them; each tick logs `<project>: PR #N is on hold — skipping`. Remove the label to hand the PR back to the automation. `pr-maintenance-cron.sh` creates the label (`#5319E7`, "Do not auto-merge, auto-review or auto-maintain") on every repo in `archon-projects.txt` each tick, so it is always available.

## Landing a commit without CI

The cron cannot do it. `pr-maintenance-cron.sh` strips every CI-skip token GitHub honours out of the squash subject and body it composes, and `pipeline-health-cron.sh` opens a re-trigger PR against any `main` HEAD that carries one and produced no workflow run. A commit that genuinely must land on `main` without CI has to be merged by hand.

## Throttle and manual nudges

`throttle.conf` sets `TICK_INTERVAL_MINUTES` (30). Each script calls `should_tick <name>` from `lib/throttle.sh`, which skips the run unless that many minutes have passed since the stamp in `~/.config/archon-cron/state/<name>.last_run`, then rewrites the stamp. To run a script by hand for one project without disturbing the schedule, set `ARCHON_CRON_FORCE_TICK=1`:

```
ARCHON_CRON_FORCE_TICK=1 ops/cron/pr-maintenance-cron.sh reli
```

Do not delete the stamp to force a run. The script rewrites it, so a nudge loop that repeats faster than the interval keeps the system cron skipping for every project the nudge did not name; a 20-minute loop did exactly that for 15 hours on 2026-09-11.

## Reading a paused run

`archon workflow resume` and the run's own log print `Workflow paused — waiting for approval.` for **every** pause, including the designed 5-minute CI wait in `archon-ship`'s deliver tail (`deliver__await-checks` / `ci-pause`). It does not mean a human gate is open — the sdlc workflow pack declares no approval node at all, and its header says so: the human gate is PR review and merge on GitHub, outside the run.

Check the run itself before acting:

```
archon workflow get <run-id> --json
```

`metadata.wait` with a `resumeAt` is a durable wait the server resumes on its own — leave it alone; resuming by hand just re-probes CI and parks again. `metadata.approval` without `resolved` is the only shape genuinely owed a response — with one exception: `type: child_workflow` means the run is blocked on a sub-run, and the child's own termination resumes the parent. An approval already `resolved` (`approved`/`rejected`) is owed a `workflow resume`, not an answer: the approver's auto-resume is a single synchronous attempt, and the server's continuation scan only ever looks at `metadata.wait`. Anything paused with none of these shapes is wedged. `check_parked_runs` resumes the two machine-owed shapes once and ntfys about the rest.

## Install the crontab

The file `crontab` in this directory is a committed reference. To install:

```
crontab ops/cron/crontab
```

It installs with absolute paths pointing at `/mnt/ext-fast/interstellarai.net/ops/cron/...`. Adjust paths there if this repo lives elsewhere on your machine.

The crontab also keeps that checkout current: every 10 minutes it runs `git -C /mnt/ext-fast/interstellarai.net pull --ff-only -q origin main >> ~/.local/state/archon-cron/logs/ops-self-update.log`. Cron runs the scripts straight out of this checkout, so before this line a merged fix to any cron script did nothing until someone pulled by hand. `--ff-only` means a dirty or diverged checkout (a session left mid-edit on `main`, say) makes the pull fail harmlessly — nothing is overwritten — and the failure shows in that log; `-q` keeps a successful fast-forward silent, so it only ever holds problems.

## Logs and logrotate

Every crontab line appends to `~/.local/state/archon-cron/logs/<name>.log` (written out as `/home/asiri/...` because cron expands no `~`). They used to live in `/tmp`, which Ubuntu's tmpfiles rule (`D /tmp 1777 root root 30d`) empties on every boot. The `@reboot mkdir -p` line recreates the directory after a boot; when installing the crontab for the first time create it by hand, since the shell opens the `>>` redirect before the script starts and a missing directory means the script never runs:

```
mkdir -p ~/.local/state/archon-cron/logs
crontab ops/cron/crontab
```

The two per-tick scratch files stay in `/tmp` on purpose: `/tmp/.archon-active-runs.<script>` is rewritten from scratch by `archon_runs_snapshot` at the start of every tick (`lib/archon-active-runs.sh`), and `/tmp/.pr-review-fire.<pid>` lives for one `pr-review-cron.sh` invocation. Neither is read across ticks, so losing them at boot costs nothing. `pr-maintenance-cron.sh` appends `gh pr ready` stderr to `pr-maintenance-errors.log` and `pipeline-health-cron.sh` parks its archon-assist diagnostic output as `pipeline-health-diagnostic-<ts>.log`, both in the same directory. `ARCHON_CRON_LOG_DIR` overrides the directory the scripts name in their messages (the crontab redirects are literal).

Rotation is the committed `logrotate.conf` in this directory (size 10M, keep 3, compressed, `copytruncate` because cron holds the files open): the crontab runs `/usr/sbin/logrotate --state ~/.logrotate.state <checkout>/ops/cron/logrotate.conf` hourly. Add a line there when you add a crontab entry. The state file is outside the repo and keeps entries for the old `/tmp/*.log` paths; they are harmless (`missingok`) and can be left alone or trimmed with `sed -i '\#"/tmp/#d' ~/.logrotate.state`. The previous, unversioned config at `~/.config/logrotate/archon-pipeline.conf` is no longer referenced and can be deleted.

## Weekly light trim

`pipeline-health-cron.sh --trim` (Sundays 05:00) runs only the always-safe subset of the disk autoclean, regardless of disk usage: `uv cache prune`, `pip cache purge`, idle `~/.gradle/caches/<version>` dirs, `~/apks` builds older than 30 days that no `*-latest.*` symlink points at, stale archon worktrees, and the `/tmp` rules described in the script index. It never runs `go clean -cache`, `bun pm cache rm`, `npm cache clean` or the journal vacuum — those wipe caches that are hot on a healthy box and stay behind the >=85% gate in `check_disk`. It skips the throttle gate and every health check and logs one `trim done — freed <N>MB on /` line measured at the filesystem. Run it by hand with `ops/cron/pipeline-health-cron.sh --trim`.

## Tool freshness

`tool-freshness.sh` (Mondays 09:00) compares installed vs latest for bun, gh, uv, node, the Archon checkout and the pinned `pg_dump`, and sends **one ntfy only when something is behind**, one `tool installed → latest` line per tool; a run where everything is current is silent. Lookups use `gh api` for GitHub releases and `curl` for nodejs.org's `index.json` (newest LTS line) and the nodejs/Release `schedule.json` (the installed major's end-of-life date — past EOL is behind even when nothing newer is LTS yet). Archon is the checkout at `/mnt/ext-fast/archon`: its `upstream` remote (the project, not the operator's fork on `origin`) is fetched — remote-tracking refs only, nothing in that repo is modified — and the checkout is behind when the project's latest release tag is not in HEAD's history; the commit gap to the remote's default branch (`dev`, always ahead) is reported as context, not as a trigger (`TOOL_FRESHNESS_ARCHON_TRACK=branch` flips that). `pg_dump` is compared on its own major line against theseus-rs/postgresql-binaries, so an 18.x release never nags a 17.x install; the upgrade block is in the pg_dump section above. A lookup that fails is logged as unknown and never ntfy'd by itself. The full result lands in `~/.archon/pipeline-health-state/tool-freshness` every run (`status=behind|current`, one `behind:`/`current:`/`unknown:` line per tool). Nothing is upgraded automatically.

## Script index

| Script | Cadence | What it does |
|---|---|---|
| `issue-pickup-cron.sh` | every 15 min | auto-label new issues, fire `archon-fix-github-issue` on oldest queued. Dep-aware: an issue is blocked if it has any open `blocked_by` dep OR any open sub-issue child (so PRDs park themselves until all phases close, then unblock for finalization). Issues carrying a human-intent label (`HUMAN_LABELS`, including `requirements-gap`) are never triaged or queued. Labels a dead run left behind are recovered after `STUCK_AGE_SECONDS`: a stale `archon:in-progress` issue is re-queued, or parked as `archon:skipped` when a human owns it, and a stale `archon:triage-in-progress` label is dropped so triage runs again. |
| `pr-maintenance-cron.sh` | every 15 min | zero-AI PR janitor: promotes green drafts, squash-merges CLEAN, fires `archon-pr-maintenance` on one dirty/behind PR per project. Every squash merge carries an explicit subject and body built from the PR's own title and body with CI-skip tokens removed (`lib/ci-skip.sh`), so a snapshot commit on the branch cannot skip CI on `main`; a PR whose title/body cannot be read is left for the next tick rather than merged bare |
| `pr-review-cron.sh` | every 5 min | fire `archon-smart-pr-review` on open non-draft PRs, once per (repo, pr, sha) |
| `pipeline-health-cron.sh` | every 30 min | main-CI-red detection (only `push`-triggered workflows count as CI, judged on the newest run of each workflow at the current main HEAD, so a red scheduled workflow no longer reads as CI red, and a red `CI` is not masked by a `Release` that finished after it — a push-triggered deploy workflow, like `un-reminder`'s `Deploy CF Worker`, still counts as CI). Also detects a `main` HEAD older than 10 minutes that produced zero `push` workflow runs: ntfy only when the cause is ambiguous, and when the HEAD commit message carries a CI-skip token, auto-opens an empty-commit `ci/retrigger-<sha8>` PR (one marker per SHA once it has actually been acted on, so a GitHub write that fails is retried on the next tick instead of being treated as handled, plus a 2h per-project cooldown on opening a PR), prod-deploy health (status API + HTTP probe), zombie-run reaping, disk pressure, stall detection, PR-CI retry (fires `archon-assist` on open archon PRs with failed CI). Both main-CI and PR-CI remediation are scoped to the current head SHA with an attempt counter: a new SHA resets the budget, same SHA retries up to 3 times, then ntfys "factory stuck" and backs off. Main-CI issue filing additionally carries a 2h per-project cooldown (cleared whenever main goes green, so a fresh red still fires at once) and is suppressed while any open "Main CI" issue carries an `archon:*` state or a human-intent label — a human relabelling one `human-needed` used to make the cron refile it every tick. If that open issue is in a terminal `archon:*` state with nobody on it, the operator gets one ntfy instead of a duplicate issue. Red `schedule`-triggered workflows on main get an operator ntfy only — no issue, no archon, since a missing secret is not something a commit can fix (dedup per project+workflow in `scheduled-health/`, cleared on recovery). On `/` disk pressure (>=85%) runs an autoclean before ntfying and only ntfys if still over: go/bun/npm/uv/pip caches (bun is run from a throwaway dir holding an empty `package.json`, since `bun pm cache rm` refuses to run without one and cron's cwd is `$HOME`), user-journal vacuum, `~/.cache/puccinialin` and `~/.gradle/caches/<version>` dirs with no file written in 30 days (`modules-2`, `jars-*`, `journal-1` and anything inside a live version are never touched), `~/apks` builds older than 30 days that no `*-latest.*` symlink points at, stale archon worktrees, and `/tmp`: the known artifact patterns after 1 day plus any top-level user-owned *directory* idle for 3 days except `claude-*`/`tmux-*`/`ssh-*`/`pulse-*`/`dbus-*`/`systemd-*`/`snap-*` and dotdirs — regular files there (cron logs, `.archon-active-runs.*`, `.pr-review-fire.*`) are never removed. Every step logs its result and MB freed, and a failing step logs its exit code instead of being swallowed. `PIPELINE_HEALTH_TMP_ROOT`, `PIPELINE_HEALTH_GRADLE_CACHES` and `PIPELINE_HEALTH_APK_DIR` override the targets for tests. Files files `manual-review`-labeled GH issue on 3-strike CI escalation (not re-ingested by `issue-pickup-cron.sh`). Also sweeps stale `archon:in-progress` labels off closed issues (→ `archon:done`), fires shipped-PR ntfys for merged PRs that closed issues, and ntfys when `backup-dbs.sh` has not recorded a verified backup in 7h. Watches paused archon runs (`check_parked_runs`): one `workflow resume` when a run drifts `PARKED_WAIT_MAX_SECONDS` (1800) past the resume deadline it recorded for itself, or sits at one wait for 4x that, or carries an already-resolved approval gate the engine never resumed — then one ntfy if that does not take. A run parked on an unresolved approval gate, or on a pause nothing describes, gets the ntfy straight away and never an answer. |
| `sweep-audits.sh` | 02:00 daily | rotating codebase audit (12-slot day-of-year rotation: `archon-architect` / `archon-security-audit` / `archon-test-audit` × filmduel / word-coach-annie / reli / cosmic-match) |
| `system-maintenance.sh` | 04:00 Sundays | host upkeep as `asiri` through `sudo -n` and the fixed sudoers shapes in `ops/host/sudoers-archon-cron`: apt update/upgrade/autoremove (upgradable count logged before and after), disabled snap revisions removed, `journalctl --vacuum-size=500M`, `smartctl -H` on every disk (ntfy on anything not PASSED), one ntfy per running kernel while `/var/run/reboot-required` exists. Writes `system-maintenance-status`; `pipeline-health-cron.sh` (`check_system_maintenance`) ntfys once when it reads `failed` or no successful run in 8 days. One-time host setup (sudoers, journald cap, unattended-upgrades, smartd, Node 24): see [`../host/README.md`](../host/README.md) |
| `backup-dbs.sh` | every 3h (at :17) | Supabase → local + rclone to Google Drive. Verified dumps only: pinned pg17 client, schema check, min size, sanity-table row count; fails loud (exit 1 + ntfy) and deletes empty artifacts |
| `daily-release-cron.sh` | 08:00 daily | tag + release per repo if main moved since last release |
| `pipeline-health-cron.sh --trim` | 05:00 Sunday | the light autoclean only (see "Weekly light trim"): uv/pip prune, idle Gradle caches, old APKs, stale worktrees, stale `/tmp` entries; never the hot-cache steps |
| `tool-freshness.sh` | 09:00 Monday | installed vs latest for bun, gh, uv, node (newest LTS + EOL), Archon checkout, pg_dump; one ntfy only when something is behind; result in `~/.archon/pipeline-health-state/tool-freshness` |
| `fetch-apks.sh` / `install-apks.sh` | manual only | download signed APKs from CI into `~/apks` / sideload them over adb. Not scheduled: Android distribution goes through Google Play now, and the `auto-apk-sync.sh` cron + `apk-autosync-daemon.sh` that used to drive them were removed. `pipeline-health-cron.sh` still prunes `~/apks` builds older than 30d |
| `generate-android-keystore.sh` | manual, one-off per project | generate release keystore + upload to GH Actions secrets |
| `logrotate.conf` | hourly via `/usr/sbin/logrotate` | rotation for every cron log under `~/.local/state/archon-cron/logs` |
| `lib/archon-projects.sh` | sourced by others | loads project list from `archon-projects.txt` |
| `lib/ci-skip.sh` | sourced by `pr-maintenance-cron.sh`, `pipeline-health-cron.sh` | the CI-skip tokens GitHub honours: detect one, strip them from a subject or a body |
| `lib/pg-backup.sh` | sourced by `backup-dbs.sh` | URL → `PG*` env, pg client/server version selection, archive validation |
| `archon-projects.txt` | data | canonical list of managed project slugs under `alexsiri7/` |

## Tests

Bats tests live in `tests/`. Run them all with:

```
bunx bats ops/cron/tests/
```
