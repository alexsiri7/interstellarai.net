# ops/host/archon-user — the factory's agents run as `archon`, not as the owner

Every Archon run is a Claude session with `bypassPermissions`. Until now each one ran as
`asiri`, the user that holds every secret on this host: `secrets.env` (prod DB URLs,
Cloudflare, Sentry, ntfy), the owner's classic `gh` token, Railway, rclone, `~/.ssh`,
`~/.claude`. A prompt injection that reached an agent could read and send any of it
(infra audit W-1, repo audit §5f.6).

After this change the agents run as a separate system user, `archon`. It has its own
Claude credential, a fine-grained GitHub token for the factory repos only, its own
`~/.archon` (run DB, worktrees) and its own clones. File modes and ACLs keep it out of
everything else. The cron jobs stay `asiri`: they need the secrets for backups, ntfy,
deploy probes and merging. They reach the factory through one sudo rule that can only
run a root-owned wrapper *as archon*.

```
cron (asiri, secrets.env) ──sudo -n -u archon──▶ /usr/local/bin/archon-as-archon ──env -i, no_new_privs──▶ archon CLI (archon)
                                                  (validates argv, maps               ├─ Claude: its own setup-token
                                                   /mnt/ext-fast/<p> ─▶                ├─ GitHub: fine-grained PAT, factory repos only
                                                   ~archon/repos/<p>)                  └─ ~archon/.archon: DB, worktrees, workflows
archon-serve.service (system unit, User=archon, NoNewPrivileges, ProtectHome)
```

**Running the installers (since 2026-10-04): no password.** After a one-time
`sudo ops/host/archon-user/install.sh --install-sudo-ops` (with the password; see
"Passwordless sudo" below), the owner and the assistant run every `install.sh`
form in this file as `sudo -n /usr/local/sbin/archon-user-install <args>`, and
`ops/host/install.sh` as `sudo -n /usr/local/sbin/archon-host-install`. Both run
a root-owned snapshot of `ops/`, not the checkout; after an approved ops update,
refresh it first with `sudo -n /usr/local/sbin/archon-ops-promote`. Anything as
archon is `sudo -n -u archon -H bash -c '…'`, also without a password.
The commands below use the entrypoints; `sudo ops/host/archon-user/install.sh …` from the checkout still works, with the password.

Nothing changes until the owner runs `install.sh --cutover`. The flag
(`ARCHON_RUN_AS`, default `asiri`) keeps every cron script byte-for-byte on today's
path. `install.sh --rollback` goes back in one step.

## Owner steps

Run everything from the live checkout, `/mnt/ext-fast/interstellarai.net`. Steps 1–4
can be done while the factory runs; they change nothing it uses.

### (a) Create the GitHub token for archon

Since 2026-10-06 archon acts as its own GitHub machine user, **`alexsiri7-factory`**, a
collaborator (Write) on the repos in `ops/cron/archon-projects.txt`. Its token is a
**classic** PAT of that account with scopes `repo` and `workflow` (fine-grained tokens
only reach repos their own account owns, so they cannot serve a collaborator). Install it
with `--set-gh-token` as below. With its own identity GitHub tells factory work from the
owner's, and `ops/cron/ops-self-update.sh` lets ops changes from the owner's own pull
requests through without `--approve`; the factory's still wait for it.

The fine-grained setup below is how it was before, on the owner's account:

archon gets its own GitHub token, not a copy of yours. To create it:

1. Signed in to GitHub as `alexsiri7`, open
   <https://github.com/settings/personal-access-tokens/new>. (The long way: your avatar →
   Settings → Developer settings → Personal access tokens → **Fine-grained tokens** →
   **Generate new token**.)
2. Fill in the form:

   | Field | Value |
   |---|---|
   | Token name | `archon-factory@interstellar` |
   | Expiration | 1 year. Put a reminder in your calendar; `verify.sh` fails once it expires. |
   | Resource owner | `alexsiri7` |
   | Repository access | **Only select repositories**: `un-reminder`, `cosmic-match`, `word-coach-annie`, `filmduel`, `reli`, `kindred`, `lachesis`, `interstellarai.net`, `musenmingle`, `zoomies`, `catscape`, `dibs`, `kith`. This is the list in `ops/cron/archon-projects.txt`. **Not `Archon`**: `archon-update.sh` pushes its upstream-sync branches to that fork. Alternatively **All repositories**, so new projects need no token edit; then opt in, see "An all-repositories token" below. |
   | Permissions → Repository permissions | **Contents: Read and write** · **Pull requests: Read and write** · **Issues: Read and write** · **Workflows: Read and write** · Actions: Read-only · Checks: Read-only · Commit statuses: Read-only · Metadata: Read-only (mandatory, preselected) · everything else: No access |
   | Workflows (a repository permission) | **Read and write** since 2026-10-04 (see "Decisions" below). Without it every push that touches `.github/workflows/` is refused. |
   | Permissions → Account permissions | none |

3. Click **Generate token**. The page shows the token once, starting `github_pat_`.
   Copy it and keep the tab open until step (c) has accepted it. The token is not stored
   anywhere else, and a lost one is simply regenerated (the token's page → **Regenerate token**).

#### An all-repositories token (owner opt-in)

With **All repositories** the token can also write `alexsiri7/Archon`, and `verify.sh`,
`--set-gh-token` and `--cutover` then FAIL by default. If that is deliberate (so new
repos need no token edit), record the decision once:

```bash
sudo -n /usr/local/sbin/archon-user-install --allow-all-repos-token      # writes ALLOW_ALL_REPOS_TOKEN=1 to /etc/archon-user/config
sudo -n /usr/local/sbin/archon-user-install --no-allow-all-repos-token   # undo: the fork check FAILs again
```

The check then reports WARN: "owner opted in to an all-repositories token; a hijacked
agent could push to the Archon fork". What that costs: `archon-update.sh` merges the
upstream release tag into the live checkout locally and only *pushes* to the fork; it
never builds or pulls the fork's branches. So a push there does not reach this host by
itself. It could still vandalise the fork, or pre-create the next `upstream-sync-<version>`
branch so that the weekly update refuses to push and stops. Do not pull or check out the
fork's branches without reading them. The file is root-owned; archon can read it, not
change it.

### (b) Prepare (idempotent, safe while the factory runs)

```bash
ops/host/archon-user/install.sh --dry-run        # preview, as asiri
sudo -n /usr/local/sbin/archon-user-install
```

This creates the user and tightens permissions (home 0750, secret dirs 0700, ACL deny on
every other mount entry, NTFS `umask=077`). It copies the toolchains (about 12 GB onto
`/mnt/ext-fast`, a few minutes) and installs the wrapper, sudoers drop-in and system unit.
The unit is installed but not started. It prints `already done` for anything already in
place. Re-run it after adding a project or a top-level directory under `/mnt/ext-fast`,
or to resync the toolchains.

It adds asiri to group `archon`, so asiri can read the factory's logs. Your running
shells do not see the new group until you log out and back in, or run `newgrp archon` in
the shell you run `verify.sh` from. Until then `verify.sh` warns "asiri not (yet) in
group archon".

If step 4 says `/mnt/steam-slow busy`, remount it when no backup is running
(`sudo umount /mnt/steam-slow && sudo mount /mnt/steam-slow`) or reboot. `--cutover`
refuses while the DB backups there are world-readable.

### (c) Credentials

**GitHub.** Run the command below, then paste the `github_pat_…` from (a) at the `token:`
prompt and press Enter. Nothing is echoed while you paste. It logs archon's `gh` in with
the token and runs gh-probe, which should print PASS for every factory repo:

```bash
sudo -n /usr/local/sbin/archon-user-install --set-gh-token
```

**Claude.** First create a token for archon, then hand it over:

1. In a normal terminal, as asiri, run `claude setup-token`. Do not run it inside a Claude
   Code session (the `!` prefix or an agent's shell): it needs an interactive terminal and
   a browser.
2. It opens a browser (or prints a URL to open). Sign in with the Claude account the
   factory should bill to and approve.
3. Back in the terminal it prints a long token starting `sk-ant-oat01-`. Copy all of it;
   it is shown once. It is not saved for asiri, and running `setup-token` again simply makes
   a new one.
4. Run the command below, paste the token at the `token:` prompt and press Enter (not
   echoed). It writes `/mnt/ext-fast/archon-home/.config/archon-user/claude.env` (0600,
   archon's) and runs one real `claude -p` request as archon:

   ```bash
   sudo -n /usr/local/sbin/archon-user-install --set-claude-token
   ```

`claude setup-token` prints a one-year token that can only make model requests. It
cannot fetch the account's claude.ai connectors (Drive, mail), so none of them reach a
factory session. That is why it is used instead of `claude auth login`. If you prefer a
full login anyway, run
`sudo -u archon -H /mnt/ext-fast/archon-home/.local/bin/claude auth login`. The
connectors are then still switched off by `ENABLE_CLAUDEAI_MCP_SERVERS=false` (wrapper and
unit) and `disableClaudeAiConnectors` (archon's `~/.claude/settings.json`), and
`verify.sh` checks that `claude mcp list` shows none.

Readiness check (as asiri). It should show 0 FAIL, plus WARNs saying "not cut over yet".
`--live` runs one real one-line Claude run through the factory path. It is the only check
of the Agent SDK path as archon, so do not skip it. `--cutover` runs the same smoke again
before it switches anything:

```bash
ops/host/archon-user/verify.sh --live
```

### (d) Cut over

```bash
sudo -n /usr/local/sbin/archon-user-install --drain      # launching crons skip their ticks; runs in flight finish as asiri
ARCHON_RUN_AS=asiri archon workflow runs --all --status running    # repeat until empty
ARCHON_RUN_AS=asiri archon workflow runs --all --status paused     # CI waits clear on their own in minutes
sudo -n /usr/local/sbin/archon-user-install --cutover
```

`--cutover` does the following, in order:

1. Refuses if anything is not ready:
   - less than 500 MB free on `/` (prepare also needs 20 GB on `/mnt/ext-fast`);
   - no user or wrapper, or missing sudoers or unit;
   - no Claude credential, or a failing gh probe;
   - NTFS still world-readable;
   - the flag not on `drain`;
   - runs still `running`/`paused` in asiri's DB, or `archon workflow run` processes alive.

   `--force` skips the drain check only. Paused runs left behind then never resume; issue-pickup re-queues their issues after its stuck timeout.
2. Clones every factory repo into `/mnt/ext-fast/archon-home/repos/` as archon. Then runs one real `archon-assist` run as archon (`FACTORY-OK`). If that fails, nothing is switched.
3. Stops and disables asiri's user `archon-serve.service`, then enables the system unit (`User=archon`) and waits for `127.0.0.1:3090` to answer 200. If it does not, it puts the old server back and stops.
4. Points `~/.bun/bin/archon` at `ops/cron/lib/archon-shim/archon`, so a manual `archon …` by the owner also goes to the factory user and never starts a second, stale factory as asiri.
5. Switches the crontab's self-update line to `ops/cron/ops-self-update.sh` (see "The ops repo" below).
6. Writes `ARCHON_RUN_AS=archon` into `~/.config/archon-cron/run-as`.
7. Runs `verify.sh`.

The new run DB starts empty. Run history before the cutover stays readable with
`ARCHON_RUN_AS=asiri archon workflow runs --all`, which is asiri's DB and read-only in
practice.

### (e) Verify

```bash
ops/host/archon-user/verify.sh            # exit 0 = all PASS
ops/host/archon-user/verify.sh --live     # plus one real one-line Claude run through the factory path
sudo -n /usr/local/sbin/archon-user-install --status
systemctl status archon-serve.service     # Main PID … bun, user archon
ps -o user,pid,cmd -C bun                 # factory runs: user archon
tail -f ~/.local/state/archon-cron/logs/issue-pickup.log
```

`verify.sh` checks the following:

- **Host.** The flag. The server unit runs as archon, asiri's unit is stopped, the server answers 200. The shim link and the crontab line. sudo lets asiri run the wrapper, and anything else, as archon without a password, but never with `-E`. As root it allows only the three ops entrypoints, and `sudo -n /bin/true` as root is refused. The entrypoints are root 0755, and the ops snapshot is root-only and not behind the live checkout's `ops/` (WARN if it is). The probes use `sudo -k`, which ignores a cached `sudo` password for that call, so a recent `sudo` in the same terminal cannot make them pass or fail.
- **Owner side.** The modes of the home, the secret dirs and the secret files. asiri is in group `archon`. A warning for `safe.directory = *`.
- **Archon side** (`archon-as-archon selftest`, run as archon):
  - archon is in no extra groups and has no sudo.
  - Every named secret path is unreachable, e.g. `secrets.env`, `consolidated-db.env`, `~/.config/{personal-ops,gh,opencode,rclone}`, `~/.railway`, `~/.ssh`, `~/.claude*`, `~/.archon`, `~/backups`, `/mnt/nas`, the NAS mirror, `personal-ops`, `archon-playground/security`, `/mnt/steam-slow/backups`, `/etc/shadow`.
  - A sweep of `/home /mnt /media /srv /var/backups`, plus every top-level entry of the mounts (archon cannot list them itself), finds nothing readable outside the allowlist. Debian's own backups in `/var/backups` are skipped by exact name: `dpkg.status*`, `dpkg.arch*`, `dpkg.diversions*`, `dpkg.statoverride*`, `apt.extended_states*`, `alternatives.tar*`. They are world-readable on every Ubuntu host and hold package lists. Anything else there, such as `passwd`/`group`/`shadow` backups, is still flagged. None existed on 2026-09-26.
  - Leftovers in `/tmp` are listed as WARN. `/mnt/ext-fast/.tmp-root` (the NVMe source of `/tmp`) is exempt from the sweep and the listability probe, and must be a 1777 root:root directory (FAIL otherwise).
  - archon can write its own tree but not the engine or the owner's clones.
  - The environment of every archon process is free of secret-looking variables.
  - All toolchains are present.
  - There are no claude.ai connectors.
- **Credentials.** A real Claude request as archon. The gh token is a fine-grained PAT (`github_pat_`). A write probe, creating a ref at the all-zero sha, which can never succeed, answers 422 on every factory repo and 403/404 on the Archon fork. That measures the token's grant; `.permissions.push` would only show the owner's role. A 422 on the fork is a FAIL, or a WARN after `install.sh --allow-all-repos-token` (see (a)).
- **Factory path.** `archon doctor`. The cron's own `archon` (shim → wrapper) lists runs from archon's DB. A `--dry-run` of `archon-assist` through the wrapper works (no provider call). With `--live`, one real run.

### (f) Roll back (one step)

```bash
sudo -n /usr/local/sbin/archon-user-install --rollback
```

This sets the flag to `asiri`, restores `~/.bun/bin/archon`, and stops the system unit.
It then re-enables asiri's user unit and checks health, and reports runs still going as
archon; they finish there. The user, its home and DB, the sudoers drop-in, ACLs, modes
and fstab are left alone. None of them affect asiri mode, so a second cutover is quick.
The emergency form, without the script:

```bash
echo ARCHON_RUN_AS=asiri > ~/.config/archon-cron/run-as
sudo systemctl disable --now archon-serve.service && systemctl --user enable --now archon-serve.service
```

Removing it entirely:

- `sudo rm /etc/sudoers.d/archon-user /usr/local/bin/archon-as-archon /etc/systemd/system/archon-serve.service`
- `sudo rm -r /usr/local/sbin/archon-{user-install,host-install,ops-promote} /usr/local/lib/archon-ops`
- `sudo userdel archon` (its home `/mnt/ext-fast/archon-home` is kept until you delete it)
- `sudo setfacl -x u:archon <paths>` (or leave the ACLs; they name a user that no longer exists)

## Living with it

- **Running archon by hand.** `archon workflow …` as asiri goes through the shim to the factory user; the wrapper refuses anything outside the verbs in its header. Anything else: `sudo -n -u archon -H bash -c '…'`, no password since `--install-sudo-ops` (for instance `sudo -n -u archon -H bash -c 'cd ~/repos/reli && ~/.bun/bin/archon workflow list'`). That shell gets sudo's reset environment, not the wrapper's allowlist, so do not start factory runs that way; use `archon workflow run …` (the shim) for those. Do not use the `CLAUDECODE=0 bun /mnt/ext-fast/archon/packages/cli/src/cli.ts workflow run …` form from `archon-playground/AGENTS.md` after the cutover. It runs the agent as asiri, with every secret in reach, against the old DB.
- **Global workflow overrides** live in `/mnt/ext-fast/archon-home/.archon/workflows/`. They are owned by asiri, readable by archon and not writable by it. `~/.archon/workflows` is no longer read.
- **Adding a project.**
  1. Add it to `ops/cron/archon-projects.txt`.
  2. Add the repo to the PAT (GitHub → the token → Edit). Not needed with an all-repositories token.
  3. Once the change is on main, ops-self-update fast-forwards to it (by itself for your own pull request, otherwise after `ops/cron/ops-self-update.sh --approve`) and then runs `sudo -n /usr/local/sbin/archon-ops-promote` and `sudo -n /usr/local/sbin/archon-user-install` itself, which rewrites `/etc/archon-user/projects`, the list the wrapper accepts, from the promoted snapshot. Nothing to type.
  4. The wrapper clones it on first use.
- **Toolchains.** Toolchains are copies, owned by archon, so the factory cannot alter the owner's. Claude updates itself as archon, and bun is upgraded for both users by `tool-freshness.sh --apply`. Everything else (gh, JDK, Android SDK, rustup, Flutter, Playwright, uv): re-run `sudo -n /usr/local/sbin/archon-user-install` after upgrading the owner's copy. The copy is written *by archon* (`runuser`; rsync's receiving side runs as archon), so a symlink archon planted in its home cannot redirect a root write.
- **Never run git as asiri inside `/mnt/ext-fast/archon-home`.** git executes hooks and config (`core.fsmonitor`, `core.hooksPath`) from the repository, which archon controls. asiri's `~/.gitconfig` has `safe.directory = *`, which switches off git's own guard against exactly that; `verify.sh` warns about it. Read files there, but run git as archon: `sudo -u archon -H git -C … log`.
- **Logs.** Cron logs are unchanged (`~/.local/state/archon-cron/logs`, and `.archon-logs/` in the owner's clones, written by the cron's own redirect). Archon's own run logs and artifacts are under `/mnt/ext-fast/archon-home/.archon/workspaces/`. They are group-readable to asiri, who is in group `archon`.

### The ops repo (interstellarai.net)

The factory has push access to this repo. The crontab runs `ops/cron` as asiri straight
out of its `main` every 10 minutes, and `ops/host` is what the owner runs as root.
GitHub cannot tell the factory's token from the owner: both act as `alexsiri7`, and
branch protection's admin bypass covers both. So, under `ARCHON_RUN_AS=archon`, two local
gates apply:

- `pr-maintenance-cron.sh` never auto-merges an `interstellarai.net` PR that touches `ops/**` or `.github/**`. It logs `not auto-merged: … needs a human merge`. Merge those yourself after reading them.
- `ops/cron/ops-self-update.sh`, the crontab's self-update, fast-forwards the live checkout as before unless the incoming range touches `ops/**`. In that case it holds the update and sends one ntfy per commit. Release it at the console as asiri:

  ```bash
  ops/cron/ops-self-update.sh --approve    # shows the ops/ diff, asks y/N, records the sha, fast-forwards
  ```

  After a fast-forward (either way) whose range changes `ops/host/**` or `ops/cron/archon-projects.txt`, it then runs `sudo -n /usr/local/sbin/archon-ops-promote` and, if that succeeded, `sudo -n /usr/local/sbin/archon-user-install` itself (#182). Each result goes to `ops-self-update.log`; a failure sends one ntfy with the command and exit code and leaves the checkout where it is, so run that command by hand. `--dry-run` prints what a tick would do without doing it.

  Changes outside `ops/` (the website, the workers) flow as before. They are the factory's job and deploy through CI, not through this host.

### The owner's main account as a paced fallback

While the factory account is rate limited, runs may go to the owner's **main** Claude
account instead, never past a pace: the weekly cap in force is 65% × the share of main's
7-day window elapsed (6.5% after a tenth of the week, 65% by the reset), and the 5-hour
window stops at 60%. Off until the owner turns it on.

1. In a normal terminal on interstellar, `claude setup-token`, signed in as the **main**
   account. Then `sudo -n /usr/local/sbin/archon-user-install --set-claude-token --account main`
   and paste it. That writes `~archon/.config/archon-user/claude-main.env`, creates
   `~archon/.claude-main` (no connectors, the plan-usage plugin, and
   `budget-guard.json` `{ "enabled": true, "weeklyCapPercent": 65, "fiveHourCapPercent": 60, "pace": true }`),
   and probes main once.
2. Turn it on, as asiri: `echo ARCHON_MAIN_ACCOUNT=on > ~/.config/archon-cron/main-account`
   (`off`, or deleting the file, turns it off at the next tick).

How it decides, per launch (`ops/cron/lib/main-account.sh`, called from
`quota-pause.sh` and the shim): only while the factory is held; then main's
`plan-usage.json` (refreshed when older than 30 minutes by the wrapper's `fuel-probe`, one
1-token haiku request whose rate-limit headers carry the account-wide windows, since the
owner's own use elsewhere never reaches it and headless sessions never write it; `lachesis-report`
uses the same probe for the factory, and for main only while it is turned on) must be under the paced caps from that same
`budget-guard.json`. The shim then hands the wrapper `--account main`, which uses
main's token and `CLAUDE_CONFIG_DIR=~/.claude-main`, so the plugin's paced guard also stops
a session that crosses the cap mid-run. To change the caps, edit that `budget-guard.json`
(as archon); a token renewal keeps it.

Known gaps: Archon's run DB does not record the account, so `lachesis-report` reports every
run's usage against the factory account (fuel itself is reported per account); and a run on
main that hits main's real limit (the owner's own use took it to 100%) holds the factory too,
until main's reset.

## Decisions (and why)

- **Separate system user, not a container or bubblewrap.** Ubuntu 24.04 restricts unprivileged user namespaces, and the toolchains (Android SDK, Flutter, Playwright, rustup) would all need mounting into a sandbox. A second Unix user with ACLs is standard, auditable with `ls`/`getfacl`, and survives upgrades. `no_new_privs` (wrapper) and the systemd hardening (server) come on top.
- **The factory gets its own clones** (`/mnt/ext-fast/archon-home/repos/<project>`) instead of group write on the owner's `/mnt/ext-fast/<project>`. Group write would let archon plant `.git/config` or hooks that the owner's git (cron `git fetch`, interactive sessions, `safe.directory = *`) then runs as asiri. It would also make the live ops checkout, which cron executes, writable by the agent. The wrapper maps the owner paths the cron scripts already use, so no call site changed. As a side effect, pr-review and triage no longer check out PR heads in the owner's working clones.
- **The wrapper runs as archon, not root.** A bug in it therefore costs at most what archon already has. It is root-owned so neither side can change it. Arguments are never evaluated as shell; each verb has a fixed grammar. `--workflow-source`, `--config`, `--stubs`, `--folder`, `--exec-code` and unknown flags are refused. The directory must be a listed project. The environment is `env -i` plus an allowlist. `--cwd` is dropped after mapping, so archon's process reads `archon workflow run <name> …` exactly like before. Together with the sudo parent's argv, every `pgrep` guard in the cron scripts matches unchanged; `archon-as-archon.bats` tests each pattern.
- **Fresh run DB for archon.** asiri's `archon.db` holds absolute worktree paths in asiri's home, and `credential-key` encrypts whatever the old DB stored. Neither is carried over, which is why the cutover drains first.
- **Claude: `setup-token`, not a copy of `~/.claude/.credentials.json`.** A fresh credential can be revoked on its own and carries no connectors.
- **GitHub: Workflows: Read and write (since 2026-10-04).** Until then the token had no Workflows permission, so the factory could not push changes under `.github/workflows/`. The cost was too high: 130 of 199 recent factory runs failed when their pushes were refused, and every CI-file fix landed on the owner. What granting it reopens: a hijacked agent can push a branch whose workflow runs on `push`/`pull_request` with the repo's Actions secrets (Railway and deploy tokens) and send them out. No merge is needed for that, so branch protection and the human-merge gate for `ops/**` and `.github/**` (which covers `interstellarai.net` only) do not stop it. Narrow it per repo with environment-scoped secrets and required reviewers on deploy environments. `lib/ship-breaker.sh` still parks an issue at once on GitHub's workflow-scope push refusal; that should now stay dormant, and it is kept for a token regenerated without the permission. "Actions: Read and write" would also let `archon-assist` re-run jobs itself; it stays read-only, since pipeline-health already re-runs failed CI as asiri.
- **Passwordless sudo for the owner, never a writable path for root.** See "Passwordless sudo" below.
- **Merging stays with asiri's gh** (`pr-maintenance-cron.sh`). The factory's PAT could merge as well, since contents and pull-requests write allow it; the ops-repo gates above are local for that reason.
- **Home on `/mnt/ext-fast`.** `/` is small and was 100% full on 2026-09-26. Toolchains are non-snap copies (uv binary, Flutter SDK checkout): snaps refuse homes outside `/home` without `snap set system homedirs`, and fail under `no_new_privs`.
- **NTFS `umask=077`.** Checked on 2026-09-26: no service user reads `/mnt/steam-*`. Ollama's models are in `/usr/share/ollama`, no dolt server is running, and the mounts hold the DB backups plus personal files. `uid=1000`, i.e. asiri, keeps full access.
- **ACL deny (`u:archon:---`) rather than `chmod o-rwx`** on the mount entries. It shuts out exactly one user, changes nothing for asiri or anything else that reads those paths, and `setfacl -x u:archon` undoes it. `/mnt/ext-fast` itself becomes traverse-only for archon, so it cannot list names it was not told. The NTFS mounts (`fuseblk`, no ACLs) get `umask=077` in fstab instead.

## Passwordless sudo

Installed by `install.sh --install-sudo-ops` (also part of step 7 of a plain
`install.sh`). The owner runs it once with the password, from the live checkout:

```bash
sudo /mnt/ext-fast/interstellarai.net/ops/host/archon-user/install.sh --install-sudo-ops
```

It installs the three entrypoints, bootstraps the snapshot from the live
checkout (the same checks as a promote), then installs the sudoers drop-in
(`visudo -c`, rolled back on failure). After that:

| As asiri, no password | Runs |
|---|---|
| `sudo -n -u archon -H <anything>` | anything as archon (NOSETENV: `sudo -E` is refused, sudo's env_reset always applies) |
| `sudo -n /usr/local/sbin/archon-user-install [args]` | the snapshot's `ops/host/archon-user/install.sh` as root |
| `sudo -n /usr/local/sbin/archon-host-install [args]` | the snapshot's `ops/host/install.sh` as root |
| `sudo -n /usr/local/sbin/archon-ops-promote [--status]` | refreshes the snapshot from the live checkout |
| `sudo -n systemctl restart archon-serve.service` | (as before) |

**Why a snapshot.** archon can push to this repo. ops-self-update pulls
`origin/main` into the live checkout and holds `ops/**` changes for review. A
NOPASSWD rule that ran anything under `/mnt/ext-fast/interstellarai.net`, or
anything else asiri or archon can write, would let the factory reach root. So
root only runs `/usr/local/lib/archon-ops/releases/<sha>/ops/…`:

- The snapshot is root:root, with dirs 0755 and files 0644/0755, and has no symlinks or ACLs.
- `current` is a root-owned symlink to the promoted release.
- Each entrypoint checks every path component from `/` to every file of `current`, and every directory on the PATH it hands over. Then it `exec`s the installer from `/` under `env -i` with a fixed PATH. So test hooks like `ARCHON_USER_INSTALL_SANDBOX` or `HOST_INSTALL_SUDOERS_D` cannot reach it. The scripts also ignore those hooks whenever they run as root.

**Promotion.** `archon-ops-promote`:

- writes `git archive HEAD ops/` (the committed content, not the working tree) into a new `releases/<sha>`;
- flips `current` atomically;
- keeps the last 5 releases.

It refuses unless both of these hold:

- nothing under `ops/` is modified or untracked in the live checkout;
- `HEAD` is reachable from `refs/remotes/origin/main`. That means HEAD is what ops-self-update fast-forwarded to, which for an `ops/**` change means you approved it.

git never runs as root. It runs as the checkout's owner, with `env -i`, `GIT_CONFIG_NOSYSTEM`, no global config, `core.hooksPath=/dev/null`, `core.fsmonitor=false` and `safe.directory`. Root checks the tar stream before extracting it: only regular files and directories under `ops/`. After an ops PR merges, ops-self-update fast-forwards the live checkout (by itself for the owner's pull request; a factory commit waits for `ops/cron/ops-self-update.sh --approve`). When that range changes `ops/host/**` or `ops/cron/archon-projects.txt`, it then runs the promote and `archon-user-install` itself, in that order (#182); nothing to type unless it ntfys a failure. `archon-host-install` is still yours to run when a change needs it:

```bash
sudo -n /usr/local/sbin/archon-host-install      # only for changes to ops/host/install.sh's part
```

`--status` shows the promoted sha, the releases, the live HEAD and whether it can
be promoted. It also warns when `ARCHON_RUN_AS` is not `archon`, since the review
gate in ops-self-update only holds `ops/**` changes under archon.

**What a root run of the installers still trusts.** The audit of 2026-10-04 found these. None of them is writable by archon.

- **The owner's files under `/home/asiri`**, all of them asiri's. As root, the installers:
  - read `~/.archon/config.yaml` and `~/.archon/workflows/*.yaml`, as data;
  - read the toolchain sources (`~/.bun`, `~/.local/bin`, `~/.rustup`, `~/Android/Sdk`, …), and copy them for archon;
  - write the run-as flag, `~/.bun/bin/archon` and `archon-link.prev`;
  - chmod the secret dirs and files.

  A compromised asiri could swap these, but it can already promote.
- **`/mnt/ext-fast/archon` (the engine) and `/mnt/ext-fast/.tmp-root`.** Root only links to the engine (`/usr/local/lib/archon-user/bin/archon`, archon's `~/.bun/bin/archon`) and never executes it. Factory runs execute it as archon, and the cutover's drain check runs it as asiri. Root creates and chmods `.tmp-root` in asiri-owned `/mnt/ext-fast`.
- **Archon's home.** Every write there (steps 5 and 6, `--set-claude-token`) is done *as archon*. Root only reads and stats there, and compares toolchain copies after checking they are regular files, not symlinks. The one exception is `~/.archon/workflows`, which is asiri-owned by design. Root creates that directory and copies an owner's override into it only when the target does not exist yet, and refuses when it sees a symlink on the way. A race between that check and the write remains. That directory was only nominally protected anyway, since archon owns its parent and can rename it.
- **Output of commands run as archon** (gh-probe, `workflow runs --json`, the smoke run). Root only greps it or parses it as JSON with `python3 -c`, always from `/`, so the cwd cannot plant a module.
- **The root-owned wrapper and `safe-reboot`.** They run as root (`safe-reboot status`) or as archon via `runuser`, as before.

## What the workflows needed secrets for (audit)

These were grepped for `secrets.env|railway|psql|SUPABASE|CLOUDFLARE|wrangler|DATABASE_URL|_DB_URL|ntfy|REQUESTY|SENTRY_AUTH|rclone|consolidated-db|personal-ops|.ssh|credential`:

- `/mnt/ext-fast/archon/.archon/{workflows,commands}` (sdlc pack, defaults, legacy)
- `~/.archon/workflows` (`archon-architect`, `archon-pr-maintenance`, `archon-triage-issue`)
- each project's `.archon/`

| Where | What | Decision |
|---|---|---|
| sdlc pack (ship, deliver, review, pr, validate, implement), defaults, the three global overrides | Mentions only in "never record credentials" instructions and review checklists. No secret is read. | Nothing to do |
| `archon-smart-pr-review` (legacy; the crons use `archon-review`) | Optional ntfy MCP node, enabled only when `.archon/mcp/ntfy.json` exists. It exists in no repo. | Stays off. Notifications stay on the asiri side (crons + `NTFY_TOPIC`). |
| `archon-create-issue` (legacy, not fired by any cron) | Prompt text suggests `psql $DATABASE_URL`. No URL is provided. | Dropped: archon has no DB URL. |
| Prod-deploy / main-CI / staging checks, DB backups, restore test, Muse & Mingle digest | Live in the asiri crons (`pipeline-health-cron.sh`, `backup-dbs.sh`, `restore-test.sh`, `musenmingle-digest.sh`), not in workflows. The `archon-ship` runs they start get only the issue text. | Stay asiri-side, unchanged |
| Provider keys (Requesty / opencode) | `DEFAULT_AI_ASSISTANT=claude`, and every tier is Claude. opencode/minimax/pi providers appear only in `test-workflows/`. | Not given to archon |
| Project `.env` files | None exist in the owner's clones. Worktrees never had them, and Archon strips a target repo's `.env` anyway. | Nothing to do |

## Residual risks (not closed here)

- **The factory token can change CI workflows** (Workflows: Read and write, see "Decisions"). A pushed branch can run a modified workflow with the repo's Actions secrets before any human looks.
- **A fully compromised asiri session can still reach root.** It can commit to the live checkout, move `refs/remotes/origin/main` locally (or push), and promote. The snapshot protects root from *archon*, which cannot write the live checkout, not from asiri.

- **The factory token can merge and push to every factory repo.** That is what the factory is for, and a merge there deploys to prod through CI. Branch protection, required checks and the trust gate (`lib/trust.sh`) remain the controls.
- **Network egress is open.** archon can send out what it can read: its repos, its own two tokens.
- **Leftovers in `/tmp`.** World-readable files other users leave there are readable (WARN in `verify.sh`, which lists the first 20). asiri's umask is 002; `umask 027` in `~/.profile` would stop new ones. pipeline-health's `/tmp` autoclean does not tidy them: it removes only known build-artifact names and asiri's *directories* idle for 3 days, never regular files (the crons keep state files such as `/tmp/.archon-active-runs.*` there). To shut archon out of the ones already there without deleting anything, run as asiri:

  ```bash
  find /tmp -mindepth 1 -maxdepth 1 -user "$USER" ! -type l -perm /o=rwx -exec chmod -R o-rwx {} +
  ```

  Delete what you no longer need by hand.
- **An all-repositories token** (only after `install.sh --allow-all-repos-token`). It can write `alexsiri7/Archon` and any repo you create later. See (a).
- **New directories under `/mnt/ext-fast` are world-readable by default.** Re-run `install.sh` after creating one. `verify.sh`'s sweep flags any it can read.
- **Process arguments are visible** to all users (`/proc` has no `hidepid`). No cron passes a secret on a command line (`lib/pg-backup.sh` uses the `PG*` environment).
- **A local kernel exploit** is out of scope. `no_new_privs` removes setuid binaries as a route; this is not a VM.

## Files

| File | Installed as | Purpose |
|---|---|---|
| `install.sh` | — | prepare / `--set-gh-token` / `--set-claude-token` / `--[no-]allow-all-repos-token` / `--drain` / `--cutover` / `--rollback` / `--status` / `--dry-run` |
| `archon-as-archon` | `/usr/local/bin/archon-as-archon` (root 0755) | the wrapper |
| `fuel_probe.py` | `/usr/local/lib/archon-user/fuel_probe.py` (root 0644) | the `fuel-probe` verb's rate-limit-header probe (#165) |
| `sudoers-archon-user` | `/etc/sudoers.d/archon-user` (0440) | asiri → archon: the wrapper, and `NOPASSWD:NOSETENV: ALL`; asiri → root: `systemctl restart archon-serve.service` and the three entrypoints below |
| `../archon-ops/archon-ops` | `/usr/local/sbin/archon-{user-install,host-install,ops-promote}` (root 0755, three copies) | run the snapshot's installers; promote the snapshot (`/usr/local/lib/archon-ops`) |
| `archon-serve.service` | `/etc/systemd/system/archon-serve.service` | the server as archon |
| `verify.sh` | — | the checks above |
| `../../cron/lib/run-as.sh`, `../../cron/lib/archon-shim/archon` | — | the flag and the owner-side `archon` |
| `../../cron/ops-self-update.sh` | crontab `*/10` | ops self-update with the approval gate |

Also written by `install.sh`:

- `/etc/archon-user/projects`
- `/etc/archon-user/config`, owner opt-ins (`ALLOW_ALL_REPOS_TOKEN=1`), only by `--allow-all-repos-token`
- `/usr/local/lib/archon-user/bin/archon`, a symlink to the engine's CLI
- `/mnt/ext-fast/archon-home/{.archon/config.yaml,.archon/.env,.gitconfig,.claude/settings.json}`
- `/mnt/ext-fast/archon-home/.cargo/config.toml`: `build-dir` under `~/.cache/cargo-build/{workspace-path-hash}` for every cargo build archon runs, including `git worktree add /tmp/x && cargo test`, which the per-worktree config (#131) never reaches; `/tmp` is on the slow root SSD (#133). A worktree's own `.cargo/config.toml` still wins. `worktree-trim` removes build dirs nothing wrote to for 2 days; `verify.sh` (selftest) WARNs if the config is missing.
- Nothing, but relied on: `/tmp` is a bind of `/mnt/ext-fast/.tmp-root` (root:root 1777) since `ops/host/install.sh` step 11 ([../README.md](../README.md#tmp-on-the-nvme)). `install.sh`'s ACL step skips `.tmp-root` (`BASE_ALLOW`), since a deny ACL there would shut archon out of `/tmp`; the selftest allows exactly that path and FAILs unless it is a 1777 root:root directory. `worktree-trim` also removes archon-owned top-level entries of `/tmp` and `~/tmp` (its `TMPDIR`) that nothing wrote to for 12 hours, skipping any a live archon process has its cwd in, sockets, and `claude-*`/`tmux-*`/`ssh-*`/`pulse-*`/`dbus-*`/`systemd-*`/`snap-*`; `worktree-trim --tmp-only` does only that, with no `gh` calls, and `pipeline-health-cron.sh` runs it every tick (`check_archon_tmp_trim`).
- `/mnt/ext-fast/archon-home/.config/archon-user/claude.env`, the token, mode 0600

## Tests

```bash
bunx bats ops/cron/tests/archon-as-archon.bats ops/cron/tests/run-as.bats ops/cron/tests/archon-user-install.bats ops/cron/tests/archon-ops.bats
bunx bats ops/cron/tests/                   # whole suite: flag off must change nothing
shellcheck -x -P SCRIPTDIR ops/host/archon-user/{install.sh,verify.sh,archon-as-archon} ops/host/archon-ops/archon-ops ops/cron/lib/run-as.sh ops/cron/ops-self-update.sh
visudo -c -f ops/host/archon-user/sudoers-archon-user     # works without root
```
