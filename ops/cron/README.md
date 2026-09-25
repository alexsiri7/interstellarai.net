# ops/cron

Scheduled scripts that run the archon pipeline on this machine:
- pick up new GitHub issues and dispatch archon
- keep PRs merging (rebase/fix/auto-merge)
- review PRs via archon-smart-pr-review
- watch pipeline health (CI red, zombie runs, disk pressure)
- daily release tags
- Supabase DB backups
- weekly light cache trim and weekly tool-freshness check + upgrade of the user-level tools
- weekly Archon engine update to the newest upstream release

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

Minor updates on the installed major line (17.11 → 17.12) are applied by `tool-freshness.sh --apply` every Monday (see Tool freshness below: verified download, pgvector rebuilt, throwaway-cluster self-test, atomic swap with the old tree kept as `postgresql-17.prev` for a week). The block below is the manual path — a first install, a recovery, or a major bump (pick the newest 17.x tag from <https://github.com/theseus-rs/postgresql-binaries/releases>; the same steps apply to an 18.x tag if the servers move to 18 — then use `postgresql-18` as the directory name and re-point the symlinks; the weekly job never crosses a major):

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

Every project is dumped `--schema=public` (all five keep their tables there; the schema is verified on the server before dumping). An archive only counts when it is >= 1 KB compressed (`PG_BACKUP_MIN_BYTES`), contains a `CREATE TABLE` for the project's sanity table (`annie."Project"`, `reli.things`, `filmduel.users`, `kindred.entries`, `lachesis.lachesis_backlog`) and a `count(*)` on that table succeeds. Otherwise the artifact is deleted, the project is logged as `ERROR: <project> backup FAILED — <reason>`, the script exits 1 and ntfys (if `NTFY_TOPIC` is set). The run is summarised in `~/.archon/pipeline-health-state/db-backup-status`; `pipeline-health-cron.sh` (`check_db_backup`) ntfys once when no verified backup has landed for `DB_BACKUP_MAX_AGE_H` (7) hours. Retention (7 days local, `rclone copy --max-age 2d` to Google Drive) is unchanged. Whether the archives actually restore is checked weekly — next section.

### Restore test (weekly): the backups must restore, not just exist

`restore-test.sh` (cron, Sunday 04:30 — 73 minutes after the 03:17 backup) proves the newest archive of every project restores. Per project it picks the newest `<project>-*.sql.gz` under `/mnt/steam-slow/backups/<project>/` by mtime, fails if there is none or it is older than `RESTORE_TEST_MAX_ARCHIVE_AGE_H` (6) hours, runs the same `pg_validate_archive` check as the backup, then restores it into a throwaway cluster: `initdb -A trust` in a temp dir directly under `/tmp` (unix-socket paths are capped at 107 bytes), `pg_ctl start -w` with `listen_addresses=''`, `-k <tmpdir>` and a random port, so nothing is reachable over TCP; one `restore_<project>` database per project from `template0`; `psql -v ON_ERROR_STOP=1` over the gunzipped SQL. It then requires that the schema exists, the sanity table exists, and `count(*)` on it equals the count backup-dbs.sh recorded for that archive. The cluster is stopped and the temp dir removed on every exit path (trap). It never connects to the real databases: `secrets.env` is read only for `NTFY_TOPIC` and to skip projects whose `<PROJECT>_DB_URL` is unset, exactly as `backup-dbs.sh` skips them. The run takes about two seconds for all five projects.

The recorded count comes from the `<archive>.meta` sidecar `backup-dbs.sh` writes next to every verified archive (`rows=<n>`, `table=<schema.table>`; rotated and rclone'd with the archive). For archives made before the sidecar existed it falls back to the `OK: <project> backed up: <archive> (..., <n> rows in <table>, ...)` line in `DB_BACKUP_LOG` (default `$ARCHON_CRON_LOG_DIR/db-backup.log`, i.e. `~/.local/state/archon-cron/logs/db-backup.log`); with neither, the project fails ("no recorded row count") rather than guessing.

The archives are `pg_dump --schema=public` from Supabase, so they mention two things a bare cluster lacks and which are not part of the backup. Both are handled with the smallest possible shim, applied before the archive and logged:

- the Supabase-managed `auth` and `extensions` schemas: the shim drops the template's `public` (the dump recreates it), creates `auth` with a `users(id uuid)` table and stub `auth.uid()`/`auth.role()`/`auth.jwt()` (RLS policies reference them; `check_function_bodies = false` in the dump keeps function bodies unparsed), and an empty `extensions` schema. Foreign keys whose target is in `auth`/`extensions` (kindred's `REFERENCES auth.users(id)`) are added `NOT VALID`, since the auth users are not in the archive; the number rewritten appears in the `OK:` line. Nothing else in the archive is touched, and a reference to any other external schema fails the restore loud — extend the shim knowingly.
- pgvector (kindred: `extensions.vector(1536)`, `hnsw` index): the real extension, created only when the archive mentions `extensions.vector`; if it is missing the project fails naming this section. It is built once into the user-level tree (no sudo), and must be rebuilt after the PostgreSQL 17 tree is replaced by the manual upgrade block above (`tool-freshness.sh --apply` rebuilds it into the new tree itself, at the version the old tree's `vector.control` declares, before swapping):

```bash
git clone --depth 1 --branch v0.8.1 https://github.com/pgvector/pgvector.git "$(mktemp -d)/pgvector" && cd "$_"
make PG_CONFIG=~/.local/opt/postgresql-17/bin/pg_config && make install PG_CONFIG=~/.local/opt/postgresql-17/bin/pg_config
ls ~/.local/opt/postgresql-17/lib/vector.so ~/.local/opt/postgresql-17/share/extension/vector.control
```

Each project logs `OK: <project> restored: <archive> (<n> rows in <schema.table> = backup count, <t> tables in <schema>, <ms>ms)` or `ERROR: <project> restore FAILED — <reason>`; any failure exits 1 and ntfys (`NTFY_TOPIC`). The run is summarised in `~/.archon/pipeline-health-state/restore-test-status` in the style of `db-backup-status` (`last_run`, `last_run_status`, `last_run_failed`, `last_ok`, then one `<project>=ok|failed|skipped ...` line each); `pipeline-health-cron.sh` (`check_restore_test`) ntfys once when the last run failed or no successful run landed within `RESTORE_TEST_MAX_AGE_D` (8) days. To run it by hand: `ops/cron/restore-test.sh` (`PG_BIN`, `BACKUP_ROOT`, `DB_BACKUP_STATE_DIR`, `RESTORE_TEST_TMP_ROOT` override the defaults). Note what the test does *not* prove: the Supabase `auth` schema (user accounts) is outside the `--schema=public` dumps, so a real disaster recovery of kindred also needs the auth users back before its foreign keys can be validated.

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

Stale archon worktrees are task dirs (`task-archon-*`) whose `archon/<dir>` branch has no open PR and that nothing has touched for 4h, in both layouts: the 0.10 one under `~/.archon/workspaces/{ext-fast,alexsiri7}/<project>/worktrees/archon` and the pre-0.10 one under `/mnt/ext-fast/.archon/worktrees/ext-fast/<project>/archon` (what `~/.archon/worktrees` links to), which held 509 dirs / 148 GB by 2026-09-21 because only the first was scanned. A project whose `gh pr list` fails is skipped rather than read as "no open PRs". `ops/cron/pipeline-health-cron.sh --list-stale-worktrees` is the dry run: it logs each worktree the step would remove with its size and a total, and removes nothing.

## Tool freshness

`tool-freshness.sh --apply` (Mondays 09:00) compares installed vs latest for bun, gh, shellcheck, uv, node, the Archon checkout and the pinned `pg_dump`, upgrades the user-level ones that are behind, checks again and sends **one ntfy only when something was upgraded, failed, was skipped or remains behind**; a run where everything is current is silent. Without `--apply` it only reports (one `tool installed → latest` line per tool when something is behind). Lookups use `gh api` for GitHub releases (uv excepted: it is the `astral-uv` snap tracking `latest/stable`, and the store channel lags GitHub by weeks, so its "latest" is the tracked channel's version from `snap info astral-uv` — it is only behind when a refresh is actually pending, i.e. `snap refresh --list` would show it) and `curl` for nodejs.org's `index.json` (newest LTS line) and the nodejs/Release `schedule.json` (the installed major's end-of-life date — past EOL is behind even when nothing newer is LTS yet). Archon is the checkout at `/mnt/ext-fast/archon`: its `upstream` remote (the project, not the operator's fork on `origin`) is fetched — remote-tracking refs only, nothing in that repo is modified — and the checkout is behind when the project's latest release tag is not in HEAD's history; the commit gap to the remote's default branch (`dev`, always ahead) is reported as context, not as a trigger (`TOOL_FRESHNESS_ARCHON_TRACK=branch` flips that). `pg_dump` is compared on its own major line against theseus-rs/postgresql-binaries, so an 18.x release never nags a 17.x install. A lookup that fails is logged as unknown and never ntfy'd by itself.

What `--apply` (`lib/tool-update.sh`) does, in this order, only for tools the check found behind:

- **bun** — `bun upgrade`, then `systemctl --user restart archon-serve.service` and a poll of `http://127.0.0.1:3090/` for a 200 (15 tries, 2 s apart). The server and every running workflow are bun processes, so bun is **skipped** — logged, retried next week — while an `archon workflow run` process is live or the run DB lists a `running` run (`lib/archon-active-runs.sh`; paused runs are durable waits the restarted server resumes on its own, and are only logged). If the run listing itself fails the upgrade is skipped rather than restarting the server blind. bun has no rollback: a server that does not answer 200 after the restart is ntfy'd `urgent` and recorded as failed.
- **gh** — `gh_<v>_linux_amd64.tar.gz` + `gh_<v>_checksums.txt` from the cli/cli release into a scratch dir, `sha256sum -c`, `install -m 0755` over `~/.local/bin/gh`, then `gh --version` must say `<v>` and `gh auth status` must still pass; otherwise the previous binary is put back.
- **shellcheck** — `shellcheck-v<v>.linux.x86_64.tar.xz` from the koalaman/shellcheck release, same install pattern into `~/.local/bin/shellcheck`. The project ships no checksum file any more (the sha512 sums of older releases are gone), so the expected sha256 is the asset's `digest` from the GitHub release API — the same origin a checksums file would have.
- **pg_dump** — the newest tag on the installed major line of theseus-rs/postgresql-binaries: tarball + `.sha256` verified, unpacked to `~/.local/opt/postgresql-17.new`, pgvector cloned at the version the current tree's `vector.control` declares and built into the new tree with the recipe above, then the new tree must pass a self-test (`ldd` clean, `initdb`, `pg_ctl start` socket-only on a random port, `CREATE EXTENSION vector`, `pg_ctl stop`) before anything moves. Then `postgresql-17` → `postgresql-17.prev`, `postgresql-17.new` → `postgresql-17`, the `pg_dump`/`pg_restore` symlinks are re-pointed and `pg_dump --version` must report the new version — if not, the old tree is moved back. `.prev` is kept for one cycle and removed by the next weekly run once it is at least 6 days old (`.tool-update-swapped-at` marker; a `.prev` without it is never touched). A major bump is never automatic.
- **uv** (snap, auto-refreshes; flagged only when the store channel is ahead of the installed revision), **node** (apt/NodeSource; a major bump is `NODE_MAJOR` in `ops/host/install.sh`) and **archon** are never touched and stay in the `still behind (manual):` line.

The ntfy body is `upgraded: bun 1.4.2 → 1.4.3, gh …` / `failed: …` / `skipped: …` / `still behind (manual): node …`, one line per non-empty group; the title is `Tool update FAILED: …` (priority high) when anything failed, `Tools upgraded: …` when something was, else `Tools behind: …`. The full result lands in `~/.archon/pipeline-health-state/tool-freshness` every run: `status=behind|current`, `apply_status=ok|failed`, `apply_count`, one `apply: <tool> upgraded|failed|skipped <detail>` line per attempted tool, then one `behind:`/`current:`/`unknown:` line per tool. `tool-freshness.lock` in the same directory (`flock -n`) makes an overlapping run exit at once. To run by hand: `ops/cron/tool-freshness.sh` (report only) or `ops/cron/tool-freshness.sh --apply`; scratch (downloads, the throwaway cluster) lives under `/tmp/tool-update.XXXXXX` and is removed on exit.

## Archon auto-update

`archon-update.sh` (Sundays 03:00, an hour before `system-maintenance.sh`) keeps the engine on the newest upstream **release**. The engine is the fork checkout at `/mnt/ext-fast/archon` (`ARCHON_LIVE_DIR`), branch `upstream-sync-<version>`: the upstream tag plus the factory's own commits (model pins, fork-safe `--repo` pins, bundled workflow tweaks). `~/.bun/bin/archon` is a symlink into that checkout and `archon-serve.service` runs the server out of it, so the upgrade is the 0.10.1 cutover ([`ARCHON-0.10-CUTOVER.md`](ARCHON-0.10-CUTOVER.md)) made repeatable:

1. **Decide.** `git describe --tags --abbrev=0` in the live checkout is the base release; `git ls-remote --tags upstream` (final `vX.Y.Z` tags only, semver-sorted — `upstream/dev` is always ahead and is not tracked) is the newest. That is the whole no-op path: no fetch, nothing written in the live repo; it logs `current vX.Y.Z — nothing to do` and writes status `ok`/`noop`.
2. **Guard.** Deferred (exit 0, status `deferred`) while any archon run is `running` per `lib/archon-active-runs.sh` or a `archon workflow run` process is alive, or when the run listing cannot be read. Paused runs are durable waits the restarted server resumes on its own, so they do not block. One `flock` keeps two ticks from overlapping.
3. **Merge in a worktree.** The only fetch into the live repo is the tag itself (`git fetch --no-tags upstream refs/tags/<tag>:refs/tags/<tag>`). Then `git worktree add -b upstream-sync-<version> /mnt/ext-fast/archon-playground/archon-update-<tag> <live branch>` (`ARCHON_WORKTREE_BASE`) and `git merge --no-edit <tag>`. Conflicts: merge aborted, worktree and branch removed, ntfy naming the files, one GitHub issue per tag on `alexsiri7/Archon` ("Upstream <tag> merge conflicts", marker `archon-update-issue-<tag>` in the state dir, so a second week does not file a second one), status `failed`. Resolve by hand the way the 0.10.1 merge was done (the issue body has the commands).
4. **Prove it**, in the worktree: `bun install` (a refreshed `bun.lock` is committed), `bun run type-check`, `bun --filter '*' test && bun test ./scripts/` — the serial form of package.json's `test` script, because `--parallel` turns 5 s per-test timeouts red on this box (2026-09-19: 5 fail parallel, 8766 pass / 0 fail serial in 1m40) — then `bun run generate:bundled` committed as `post-merge: regenerate bundled defaults for <tag>` (the follow-up the last merge needed by hand), then `validate workflows` with the **worktree's** CLI (`bun <worktree>/packages/cli/src/cli.ts validate workflows --cwd <dir>`) for the worktree itself and every `/mnt/ext-fast/<project>` in `archon-projects.txt`. Validation is judged against the live CLI on the same directories, since one error is pre-existing (`archon-smart-pr-review`'s missing `.archon/mcp/ntfy.json`): only a workflow that errors under the new engine and not under the old one is a regression. Any failure: ntfy + issue as above, the worktree is **kept** for inspection (the ntfy and the status file say where), status `failed`. Step output goes to `archon-update-<tag>-<step>.log` next to the main log. The whole proof takes about four minutes.
5. **Swap.** Push the branch to `origin` (the fork), remove the worktree (git will not check out a branch that is checked out elsewhere; the branch stays), record the live branch and sha in `~/.archon/pipeline-health-state/archon-update-previous`, then in the live checkout `git checkout upstream-sync-<version>`, `bun install --frozen-lockfile`, `systemctl --user restart archon-serve.service`, and wait up to 60 s (`ARCHON_UPDATE_HEALTH_TIMEOUT`) for `GET http://127.0.0.1:3090/` → 200 **and** `archon --version` naming the tag. Not healthy: roll back — checkout the recorded branch, `bun install --frozen-lockfile`, restart, re-check — ntfy "Archon update rolled back", issue, status `failed`; the pushed branch stays on the fork for a human, and the next run refuses to push over it (`push` failure) until it is deleted there or the upgrade is finished by hand. Healthy: ntfy `Archon updated vX → vY`, status `ok`/`updated`. The live checkout is never fast-forwarded in place: the previous `upstream-sync-*` branch is the rollback target and the new branch name matches `git describe`. `upstream-sync-0.10` was hand-made; the script makes `upstream-sync-0.11.0` and so on.

Status lives in `~/.archon/pipeline-health-state/archon-update-status` (`last_run`, `last_run_status`, `last_run_failed=<step>`, `last_ok`, `outcome=noop|deferred|updated|failed`, `current`, `latest`, `worktree`); `pipeline-health-cron.sh` (`check_archon_update`) ntfys once when the last run failed or no ok run (a no-op counts, a deferral does not) landed within `ARCHON_UPDATE_MAX_AGE_D` (8) days. Run it by hand with `ops/cron/archon-update.sh`; the tests override every path (`ARCHON_LIVE_DIR`, `ARCHON_WORKTREE_BASE`, `ARCHON_UPDATE_STATE_DIR`, `ARCHON_UPDATE_VALIDATE_DIRS`, `ARCHON_UPDATE_HEALTH_URL`, ...; the header of the script lists them). It never runs a workflow and never touches `~/.archon/config.yaml`: a release that needs a new tier or alias (as 0.10.1 needed `ai tier set large`) still needs that one command by hand — read the release notes when the "Archon updated" ntfy arrives.

## Script index

| Script | Cadence | What it does |
|---|---|---|
| `issue-pickup-cron.sh` | every 15 min | auto-label new issues, fire `archon-fix-github-issue` on oldest queued. Dep-aware: an issue is blocked if it has any open `blocked_by` dep OR any open sub-issue child (so PRDs park themselves until all phases close, then unblock for finalization). Issues carrying a human-intent label (`HUMAN_LABELS`, including `requirements-gap`) are never triaged or queued. Labels a dead run left behind are recovered after `STUCK_AGE_SECONDS`: a stale `archon:in-progress` issue is re-queued, or parked as `archon:skipped` when a human owns it, and a stale `archon:triage-in-progress` label is dropped so triage runs again. Before queueing, duplicate Sentry issues (Sentry's GitHub app and `workers/sentry-bridge` both filing one crash) are grouped by the `sentry.io/issues/<id>` link in their bodies across open and the last 100 closed-as-completed issues; the survivor is a closed one, else an in-progress one, else the bridge's, else the lowest number, and the other open ones are closed `--duplicate-of` it (never in-progress or human-owned ones). A ship run that ends without a PR is settled by `lib/settle-ship-outcome.sh`: `No delivery needed` closes the issue as `archon:done` only when GitHub confirms it (all sub-issues closed, or the verdict names a closed-as-completed issue or a merged PR); everything else is parked as `archon:skipped`. Issues `pipeline-health-cron.sh` filed (their body carries the "Auto-filed by `pipeline-health-cron.sh`" line) are never closed this way, since the PR such a verdict names is usually what broke CI or the deploy; they are always parked. Every tick also re-checks open `archon:skipped` issues whose last comment is that parked `No delivery needed` verdict (`--recheck`), closing them as `archon:done` once GitHub confirms it; a human comment after the verdict opts the issue out. |
| `pr-maintenance-cron.sh` | every 15 min | zero-AI PR janitor: promotes green drafts, squash-merges CLEAN, fires `archon-pr-maintenance` on one dirty/behind PR per project. Every squash merge carries an explicit subject and body built from the PR's own title and body with CI-skip tokens removed (`lib/ci-skip.sh`), so a snapshot commit on the branch cannot skip CI on `main`; a PR whose title/body cannot be read is left for the next tick rather than merged bare |
| `pr-review-cron.sh` | every 5 min | fire `archon-smart-pr-review` on open non-draft PRs, once per (repo, pr, sha) |
| `pipeline-health-cron.sh` | every 30 min | main-CI-red detection (only `push`-triggered workflows count as CI, judged on the newest run of each workflow at the current main HEAD, so a red scheduled workflow no longer reads as CI red, and a red `CI` is not masked by a `Release` that finished after it — a push-triggered deploy workflow, like `un-reminder`'s `Deploy CF Worker`, still counts as CI). Also detects a `main` HEAD older than 10 minutes that produced zero `push` workflow runs: ntfy only when the cause is ambiguous, and when the HEAD commit message carries a CI-skip token, auto-opens an empty-commit `ci/retrigger-<sha8>` PR (one marker per SHA once it has actually been acted on, so a GitHub write that fails is retried on the next tick instead of being treated as handled, plus a 2h per-project cooldown on opening a PR), prod-deploy health (status API + HTTP probe; the archon-ship runs it fires on "Main CI red" and "Prod deploy failed" issues are settled by `lib/settle-ship-outcome.sh` when they exit, so one that ends without a PR parks its issue `archon:skipped` instead of leaving it `archon:in-progress`), zombie-run reaping, disk pressure, stall detection, PR-CI retry (fires `archon-assist` on open archon PRs with failed CI). Both main-CI and PR-CI remediation are scoped to the current head SHA with an attempt counter: a new SHA resets the budget, same SHA retries up to 3 times, then ntfys "factory stuck" and backs off. Main-CI issue filing additionally carries a 2h per-project cooldown (cleared whenever main goes green, so a fresh red still fires at once) and is suppressed while any open "Main CI" issue carries an `archon:*` state or a human-intent label — a human relabelling one `human-needed` used to make the cron refile it every tick. If that open issue is in a terminal `archon:*` state with nobody on it, the operator gets one ntfy instead of a duplicate issue. Red `schedule`-triggered workflows on main get an operator ntfy only — no issue, no archon, since a missing secret is not something a commit can fix (dedup per project+workflow in `scheduled-health/`, cleared on recovery). On disk pressure (>=85%) runs an autoclean before ntfying and only ntfys if still over — on `/mnt/ext-fast`, where the worktrees live, only the stale-worktree step (see "Weekly light trim"); on `/` the full set: go/bun/npm/uv/pip caches (bun is run from a throwaway dir holding an empty `package.json`, since `bun pm cache rm` refuses to run without one and cron's cwd is `$HOME`), user-journal vacuum, `~/.cache/puccinialin` and `~/.gradle/caches/<version>` dirs with no file written in 30 days (`modules-2`, `jars-*`, `journal-1` and anything inside a live version are never touched), `~/apks` builds older than 30 days that no `*-latest.*` symlink points at, stale archon worktrees, and `/tmp`: the known artifact patterns after 1 day plus any top-level user-owned *directory* idle for 3 days except `claude-*`/`tmux-*`/`ssh-*`/`pulse-*`/`dbus-*`/`systemd-*`/`snap-*` and dotdirs — regular files there (cron logs, `.archon-active-runs.*`, `.pr-review-fire.*`) are never removed. Every step logs its result and MB freed, and a failing step logs its exit code instead of being swallowed. `PIPELINE_HEALTH_TMP_ROOT`, `PIPELINE_HEALTH_GRADLE_CACHES` and `PIPELINE_HEALTH_APK_DIR` override the targets for tests. Files files `manual-review`-labeled GH issue on 3-strike CI escalation (not re-ingested by `issue-pickup-cron.sh`). Also sweeps stale `archon:in-progress` labels off closed issues (→ `archon:done`), fires shipped-PR ntfys for merged PRs that closed issues, and ntfys when `backup-dbs.sh` has not recorded a verified backup in 7h. Watches paused archon runs (`check_parked_runs`): one `workflow resume` when a run drifts `PARKED_WAIT_MAX_SECONDS` (1800) past the resume deadline it recorded for itself, or sits at one wait for 4x that, or carries an already-resolved approval gate the engine never resumed — then one ntfy if that does not take. A run parked on an unresolved approval gate, or on a pause nothing describes, gets the ntfy straight away and never an answer. Once a day (first tick after midnight, `check_claude_auth`) probes every Claude config dir in `CLAUDE_ACCOUNTS` with a real request (see `lib/claude-auth.sh`), so an expired OAuth token surfaces within a day rather than on its next sweep slot. |
| `sweep-audits.sh` | 02:00 daily | rotating codebase audit (12-slot day-of-year rotation: `archon-architect` / `archon-security-audit` / `archon-test-audit` × filmduel / word-coach-annie / reli / cosmic-match). Before the workflow it probes the slot's Claude account (`CLAUDE_ACCOUNTS`, alternating per slot; default `~/.claude:~/.claude-secondary`) with a real request and falls back through the others; only when every account fails is the sweep skipped. Each run records `outcome=ok\|failed`, `reason=auth\|workflow\|no-clone` and the account used in `~/.archon/sweep-state/last-sweep`, which `ops/bin/pipeline-status` prints as `last sweep: OK / FAILED (auth)` |
| `system-maintenance.sh` | 04:00 Sundays | host upkeep as `asiri` through `sudo -n` and the fixed sudoers shapes in `ops/host/sudoers-archon-cron`: apt update/full-upgrade/autoremove (upgradable count logged before and after; packages still kept back are named in the log and in `last_run_kept_back=` of the status file), disabled snap revisions removed, `journalctl --vacuum-size=500M`, `smartctl -H` on every disk (ntfy on anything not PASSED), one ntfy per running kernel while `/var/run/reboot-required` exists. Writes `system-maintenance-status`; `pipeline-health-cron.sh` (`check_system_maintenance`) ntfys once when it reads `failed` or no successful run in 8 days. One-time host setup (sudoers, journald cap, unattended-upgrades, smartd, Node 24): see [`../host/README.md`](../host/README.md) |
| `archon-update.sh` | 03:00 Sundays | merges the newest upstream release tag into the fork's `upstream-sync-*` branch in a worktree, proves it (`bun install`, `type-check`, the serial test suite, `generate:bundled`, `validate workflows` against the live CLI as baseline), pushes it to the fork, swaps `/mnt/ext-fast/archon` onto it and restarts `archon-serve.service`; rolls back on a failed health check; ntfy + one GitHub issue per tag on any failure, ntfy on success; no-op when current. Deferred while any archon run is running. Writes `archon-update-status`; `pipeline-health-cron.sh` (`check_archon_update`) ntfys once when it reads `failed` or no ok run in 8 days. See "Archon auto-update" |
| `backup-dbs.sh` | every 3h (at :17) | Supabase → local + rclone to Google Drive. Verified dumps only: pinned pg17 client, schema check, min size, sanity-table row count; fails loud (exit 1 + ntfy) and deletes empty artifacts; writes a `<archive>.meta` sidecar with the verified row count |
| `restore-test.sh` | Sunday 04:30 | restores the newest archive of every project into a throwaway socket-only PostgreSQL 17 cluster (`psql -v ON_ERROR_STOP=1`) and checks schema, sanity table and row count against the backup's `.meta`; fails loud (exit 1 + ntfy), status in `restore-test-status` for `pipeline-health-cron.sh` |
| `daily-release-cron.sh` | 08:00 daily | tag + release per repo if main moved since last release |
| `pipeline-health-cron.sh --trim` | 05:00 Sunday | the light autoclean only (see "Weekly light trim"): uv/pip prune, idle Gradle caches, old APKs, stale worktrees, stale `/tmp` entries; never the hot-cache steps |
| `tool-freshness.sh --apply` | 09:00 Monday | installed vs latest for bun, gh, shellcheck, uv, node (newest LTS + EOL), Archon checkout, pg_dump; upgrades bun (not while an archon run is live; restarts archon-serve), gh, shellcheck and the postgresql-17 tree (checksums verified, self-tested, rolled back on failure; `lib/tool-update.sh`); one ntfy only when something was upgraded, failed, skipped or is still behind; result in `~/.archon/pipeline-health-state/tool-freshness` |
| `fetch-apks.sh` / `install-apks.sh` | manual only | download signed APKs from CI into `~/apks` / sideload them over adb. Not scheduled: Android distribution goes through Google Play now, and the `auto-apk-sync.sh` cron + `apk-autosync-daemon.sh` that used to drive them were removed. `pipeline-health-cron.sh` still prunes `~/apks` builds older than 30d |
| `generate-android-keystore.sh` | manual, one-off per project | generate release keystore + upload to GH Actions secrets |
| `logrotate.conf` | hourly via `/usr/sbin/logrotate` | rotation for every cron log under `~/.local/state/archon-cron/logs` |
| `lib/archon-projects.sh` | sourced by others | loads project list from `archon-projects.txt` |
| `lib/claude-auth.sh` | sourced by `sweep-audits.sh`, `pipeline-health-cron.sh` | `claude_auth_check <dir>`: a real `claude -p --model haiku` request against a config dir (`claude auth status` says `loggedIn: true` for a token the API rejects with 401). A failing account gets one ntfy per day and one open `human-needed` issue on interstellarai.net (`Claude account auth failing: <dir>`, with the `claude auth login` command), commented on once a day while it keeps failing and closed by the first passing probe. State in `~/.archon/pipeline-health-state/claude-auth/` (`CLAUDE_AUTH_STATE_DIR`) |
| `lib/human-labels.sh` | sourced by `issue-pickup-cron.sh`, `lib/claude-auth.sh` | `HUMAN_LABELS`, the human-intent labels issue-pickup never triages or ingests, and `HUMAN_NEEDED_LABEL`, the one of them the cron scripts file their own human-only issues under |
| `lib/ci-skip.sh` | sourced by `pr-maintenance-cron.sh`, `pipeline-health-cron.sh` | the CI-skip tokens GitHub honours: detect one, strip them from a subject or a body |
| `lib/pg-backup.sh` | sourced by `backup-dbs.sh`, `restore-test.sh` | the project list (`PG_BACKUP_PROJECTS`), URL → `PG*` env, pg client/server version selection, archive validation |
| `archon-projects.txt` | data | canonical list of managed project slugs under `alexsiri7/` |

## Tests

Bats tests live in `tests/`. Run them all with:

```
bunx bats ops/cron/tests/
```
