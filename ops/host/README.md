# ops/host

One-time setup for the archon build host (Ubuntu 24.04, user `asiri`), and the
sudo grant that lets the weekly `ops/cron/system-maintenance.sh` do host upkeep
without a password. Everything here is applied by one command, run once:

```
sudo ops/host/install.sh
```

Preview first, as any user (prints every command and every file it would write,
changes nothing):

```
ops/host/install.sh --dry-run
```

The script is idempotent: every step prints what it did or `already done`, so
re-running after a partial failure is safe. It needs the repo checkout to read
`sudoers-archon-cron` and `smartd-ntfy` from, nothing else. Afterwards make sure
the cron line is installed (`crontab ops/cron/crontab`, see `../cron/README.md`)
and, since NodeSource moved to Node 24, restart the archon user services once as
`asiri`: `systemctl --user restart archon-serve.service`.

Running the factory's agent sessions as the unprivileged `archon` user (its own
Claude and GitHub credentials, no access to the owner's secrets) is a separate,
later step with its own script and cutover: [`archon-user/README.md`](archon-user/README.md).

## What install.sh does

| Step | Files | Effect |
|---|---|---|
| 1. sudoers | `/etc/sudoers.d/archon-cron` (0440) from [`sudoers-archon-cron`](sudoers-archon-cron) | `asiri` may run, NOPASSWD, exactly the eight command shapes the weekly job uses (below). Validated with `visudo -c -f` before it is copied, with `visudo -c` on the whole existing sudoers set before it is installed (a pre-existing problem fails the step without installing, see Troubleshooting), and with `visudo -c` again after; rolled back if that last one fails. No `ALL`. |
| 2. journald | `/etc/systemd/journald.conf.d/50-cap.conf` | `SystemMaxUse=500M` (was uncapped, 2.5G), then `systemctl restart systemd-journald`. |
| 3. unattended-upgrades | `/etc/apt/apt.conf.d/52-archon-updates` | Adds `${distro_id}:${distro_codename}-updates` to `Allowed-Origins` (the stock `50unattended-upgrades` only takes `-security`, which is why 95 packages were sitting upgradable), `Remove-Unused-Dependencies "true"`, and `Automatic-Reboot "false"`: until 2026-09-27 this was `"true"` at 05:45, which rebooted on whatever day a reboot became pending, through live Claude sessions and jobs (2026-09-26). The safe-reboot gate (step 8) reboots instead. apt.conf lists merge across files, so `50unattended-upgrades` is left alone. Asserts with `apt-config dump` that `-updates` is allowed and `Automatic-Reboot` is off, and that `APT::Periodic::Unattended-Upgrade` is `1`. |
| 4. snap | — | `snap set system refresh.retain=2` and `snap remove --revision=N name` for every revision `snap list --all` marks `disabled` (20 on 2026-09-19). |
| 5. smartmontools | `/etc/smartd.conf`, `/usr/local/bin/smartd-ntfy` (0755) from [`smartd-ntfy`](smartd-ntfy) | Installs the package, one `DEVICESCAN` line: all checks, offline testing and attribute autosave on, spun-down disks left alone (`-n standby,q`), short self-test daily 02:00 and long self-test Saturdays 03:00, every alert delivered through `smartd-ntfy` (`-m root -M exec`). `systemctl enable --now smartd`. |
| 6. NodeSource | `/etc/apt/sources.list.d/nodesource.sources` (backup kept alongside) | Rewrites `node_20.x` (or any other line) to `node_24.x` in the Suites/URIs (Node 20 is EOL, 24 is the current LTS line), `apt-get update`, `apt-get install -y nodejs`. |
| 7. reboot | — | Prints whether `/var/run/reboot-required` exists (and which packages set it), and the gate's current decision. |
| 8. safe-reboot | `/usr/local/sbin/safe-reboot` (0755) from [`safe-reboot/safe-reboot`](safe-reboot/safe-reboot); `/etc/systemd/system/safe-reboot.{service,timer}`, `safe-reboot-restore.service`; `/var/lib/safe-reboot/` | The reboot gate (every 15 min) and the restore after boot, see [Safe reboot](#safe-reboot) below. `systemctl enable --now safe-reboot.timer`, `systemctl enable safe-reboot-restore.service` (runs at the next boot). |
| 9. systemd-oomd | `/etc/systemd/system/user@.service.d/20-oomd-pressure-limit.conf` from [`20-oomd-pressure-limit.conf`](20-oomd-pressure-limit.conf) | `ManagedOOMMemoryPressure=auto` for every `user@<uid>.service`, i.e. systemd-oomd no longer kills anything in a user manager on memory pressure. Ubuntu's `/usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf` sets `kill` at 50%; this drop-in sorts after it and overrides it. Why off rather than a higher limit: on this host the pressure is reclaim waiting on writeback to the root SSD while builds fill the page cache, with 57 GB available: #132's 80% limit was passed at 96% on 2026-09-27 and oomd killed the tmux scope running claude (42 processes). A real out-of-memory is still the kernel OOM killer's. The users with a user manager here are asiri (1000) and gdm (120); the archon factory runs in system units (no linger), so it is unaffected either way. Swap-based kills stay as Ubuntu ships them (`ManagedOOMSwap=auto` on `-.slice`, i.e. off). `daemon-reload` and `systemctl restart systemd-oomd` (kills nothing); never a restart of `user@1000`. Asserts `systemctl show user@1000.service -p ManagedOOMMemoryPressure` is `auto` and that `oomctl` no longer lists `user@1000.service` under Memory Pressure Monitored CGroups. `vm.min_free_kbytes` is left at the kernel default: free memory was ~4 GB when the stall hit, far above the watermarks, so a larger reserve would not have moved it. |
| 10. sysctl | `/etc/sysctl.d/60-dirty-bytes.conf` from [`60-dirty-bytes.conf`](60-dirty-bytes.conf) | `vm.dirty_background_bytes=268435456` (256 MiB), `vm.dirty_bytes=1073741824` (1 GiB) instead of 10% / 20% of 62 GB RAM, then `sysctl -p` and an assert. |

### smartd-ntfy

smartd runs as root and calls the script with the event in `SMARTD_*` variables.
The script reads `NTFY_TOPIC` out of `/home/asiri/.config/archon-cron/secrets.env`
(root can read the 0600 file) and posts an `urgent` ntfy. The file is grepped,
not sourced: root must never execute something `asiri` can edit. A missing
topic or a failed post is logged with `logger -t smartd-ntfy` (see
`journalctl -t smartd-ntfy`). To test the hook without waiting for a disk to
fail, temporarily add `-M test` to the `DEVICESCAN` line and restart smartd:
it sends one test alert per device on startup.

## The weekly job

`ops/cron/system-maintenance.sh` runs Sundays 04:00 as `asiri` (crontab line
`0 4 * * 0`). Every privileged command is `sudo -n <full path> <fixed args>`, so
when the sudoers file is missing or a command shape drifts, sudo answers
`a password is required` immediately instead of hanging on a prompt; the step is
logged as failed, the run ntfys and exits 1. The exact grants:

```
/usr/bin/apt-get update
/usr/bin/apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
/usr/bin/apt-get -y autoremove
/usr/bin/journalctl --vacuum-size=*
/usr/bin/snap remove --revision=* *
/usr/bin/snap set system refresh.retain=2
/usr/sbin/smartctl -H /dev/*
/usr/sbin/smartctl -A /dev/*
```

(sudoers `*` matches spaces too, so these are the narrowest useful shapes, not
exact-argument matches. `-A` is granted for by-hand attribute dumps under the
same rules; the job itself only runs `-H`.)

**Why `full-upgrade`, not `upgrade`:** `apt-get upgrade` never installs a new
package or removes an old one, so any update whose dependencies changed is
"kept back" and stays that way every week. The first real run (2026-09-19)
took the host from 95 upgradable to 28, of which 23 were stuck exactly like
that: nvidia-driver-595 595.84 -> 595.91 pulls in `nvidia-firmware-595-*`,
`linux-firmware` split into `linux-firmware-*` sub-packages, fwupd 1.9 -> 2.0
needs `libfwupd3`, and one old `linux-modules-nvidia-595-open-<kernel>` has to
go. `full-upgrade` resolves all of those; the remaining 5 were phased updates,
which both commands leave alone (no `Always-Include-Phased-Updates` override is
set, and none should be).

**The sudoers grant changed with it (2026-09-19):** a host set up before then
has the old `... upgrade` shape in `/etc/sudoers.d/archon-cron`, so the weekly
job's `full-upgrade` call is refused (`sudo -n refused`, step `apt` failed,
ntfy). Re-run once:

```
sudo ops/host/install.sh
```

Step 1 compares the installed file with `sudoers-archon-cron` and replaces it
when they differ (same `visudo -c` checks and rollback as a first install);
every other step reports `already done`.

Per run: apt update/full-upgrade/autoremove with the `apt list --upgradable`
count logged before and after; when anything is still upgradable afterwards,
`apt-get -s full-upgrade` (read-only, not through sudo) is parsed and the run
logs which packages are *kept back* (a hold or unsatisfiable deps: stuck until
someone looks) and which are merely *deferred by phasing* (Ubuntu's staged
rollout, left alone by apt's default and by design). The kept-back set also
lands in the status file as `last_run_kept_back=a,b` (empty when none) — it
does not fail the run. Every disabled snap revision removed; journal vacuumed
to 500M; `smartctl -H` on each `disk` from `lsblk` (loop devices excluded;
`SYSTEM_MAINT_SMART_SKIP="sda ..."` leaves a disk out) with an urgent ntfy for
anything not `PASSED`; and while `/var/run/reboot-required` exists, one ntfy
per running kernel ("reboot pending; safe-reboot reboots in the next idle 02:30-06:30 window"), remembered in
`~/.archon/pipeline-health-state/system-maintenance-reboot-notified` and
cleared once the file goes away. The run summary lands in
`~/.archon/pipeline-health-state/system-maintenance-status` (same shape as
`db-backup-status`), and `pipeline-health-cron.sh` (`check_system_maintenance`)
ntfys once when that reads `failed` or no successful run landed in 8 days.

Log: `/tmp/system-maintenance.log`. Run by hand: `ops/cron/system-maintenance.sh`.

Reboots: unattended-upgrades installs updates daily (`apt-daily-upgrade.timer`,
06:00 ± 1h) but no longer reboots; when an update needs one it creates
`/var/run/reboot-required` and the safe-reboot gate takes it from there.

## Safe reboot

Why: on 2026-09-26 unattended-upgrades' `Automatic-Reboot` rebooted at 05:45 on the
day a reboot became pending and killed interactive Claude sessions and a long job;
the shutdown then sat 5 minutes in `(sd-sync) waiting for writeback`. Reboots stay
automatic, but only when nothing is going on, and what was running comes back.

**The gate** (`safe-reboot.timer` → `safe-reboot gate`, every 15 minutes, as root)
does nothing unless `/var/run/reboot-required` exists **and** the local time is in the
window **02:30–06:30**. Then it reboots unless something is busy:

| Blocker | Kind | How it is detected |
|---|---|---|
| **hold file** `~asiri/.config/safe-reboot/hold` | hard | exists (any content; its first line is quoted in the ntfy). Create it to veto reboots (`mkdir -p ~/.config/safe-reboot && touch ~/.config/safe-reboot/hold`), `rm` it to allow them again. It lives in the owner's 0700 config dir, so the `archon` user cannot set or clear it. |
| a cron job that must not be cut off | hard | `pgrep -f` on `ops/cron/{backup-dbs,restore-test,system-maintenance,archon-update}.sh` and `pipeline-health-cron.sh --trim` (none of them takes a lock). |
| apt / dpkg | hard | `dpkg`, `apt`, `apt-get`, `aptitude`, `/usr/bin/unattended-upgrade`, `apt.systemd.daily` running (not the `unattended-upgrade-shutdown` daemon). |
| archon runs | soft | `running` or `paused` runs in the run DB of the user `~asiri/.config/archon-cron/run-as` names: `asiri`/`drain` → asiri's CLI (`bun …/cli.ts workflow runs --all --status …`, as asiri, clean env, `CLAUDECODE=0`, the shape `archon-user/install.sh --cutover` uses); `archon` → `archon-as-archon workflow runs` as archon (the `--rollback` shape). A query that fails counts as busy. Plus any `archon workflow run` process. |
| a Claude session working | soft | any `*.jsonl` under any user's `~/.claude/projects/` modified in the last 30 minutes. A `claude` process by itself is not busy: sessions sit idle in tmux for hours. |

Resumable long jobs (the NAS mirror, rclone) never block: they are restarted afterwards.

When nothing blocks it:
1. writes `/var/lib/safe-reboot/restore/meta` (boot id, previous flag), then sets the
   run-as flag to `drain` the way `archon-user/install.sh --drain` does (same file
   format, 0600, written as asiri via mktemp + mv), with `safe-reboot` in the comment
   line. A `drain` already in place (the owner's, or a cutover in progress) is left
   untouched and restored as `drain`.
2. re-checks archon (a cron tick may have launched a run in between); if busy, puts the
   flag back and waits for the next tick.
3. records the owner's running user services that would not come back by themselves
   (unit file in `~/.config/systemd/user` or transient, not enabled, not
   `archon-serve`): a transient unit (e.g. `cloud-mirror-firstrun` from `systemd-run`)
   is mapped to the persistent unit with the same `ExecStart` (`cloud-mirror.service`),
   else its unit file is saved and re-created as a runtime unit;
4. records every live interactive Claude CLI session from `~/.claude/sessions/<pid>.json`
   (pid and start time checked; the factory's `sdk-ts` sessions are skipped): session
   id, cwd, tmux session/window name (from the pane id), and `--permission-mode` /
   `--model` / `--effort` / `--dangerously-skip-permissions` from its command line;
5. ntfys "Rebooting", runs `sync` (up to 15 min, so the shutdown does not stall on
   writeback) and `systemctl reboot`. If the reboot command fails, the flag is put back
   and it ntfys; a recorded reboot that still has not happened 20 minutes later is
   undone on the next tick.

**Deadline.** A reboot pending for more than **72 hours** (counted from the first tick
that saw it, kept in `/var/lib/safe-reboot/pending-since`) ignores the *soft*
blockers: the first tick in the window sends an urgent ntfy "Forcing reboot … in
~15 min", the next tick at least 10 minutes later reboots. The hold file, the cron jobs
and apt/dpkg are never overridden. From 07:00, one ntfy a day while a reboot is pending:
"reboot pending since X; blocked by Y" (Y from the last in-window tick).

**Restore** (`safe-reboot-restore.service`, once per boot after `network-online.target`
and `user@1000.service`; a no-op after a boot the gate did not cause):
1. waits for asiri's (lingering) user manager;
2. starts the archon server where the recorded flag says it runs: the system
   `archon-serve.service` (User=archon) under `archon`, asiri's user unit otherwise,
   and waits for `127.0.0.1:3090` to answer 200;
3. puts the flag back to its recorded value, only if it still is the `drain` the gate
   wrote (a flag changed by hand in between is left alone);
4. starts the recorded user services with `--no-block`;
5. recreates each Claude session as a tmux window (same session and window name, the
   recorded cwd) and types `unset CLAUDECODE …; claude --resume <id> <flags>` into its
   login shell: the session is back at its prompt, idle, and the pane survives claude
   exiting. The first tmux server is started through `systemd-run --user -M asiri@` so
   it lives in asiri's user manager, not in the oneshot's cgroup;
6. ntfys "back up after reboot; restored X; health Y" (archon-serve HTTP code, flag,
   failed system/user units, free space on `/`, and under `archon` the PASS/FAIL count
   of `archon-user/verify.sh`); priority high when something is off. The recorded state
   moves to `/var/lib/safe-reboot/restored.last`.

Commands:

```
safe-reboot status                  # any user: what the gate would do now and why (changes nothing, sends nothing)
safe-reboot restore --dry-run       # what the restore would do from the recorded state
mkdir -p ~/.config/safe-reboot && touch ~/.config/safe-reboot/hold   # veto (as asiri); rm it to allow again
journalctl -u safe-reboot.service -u safe-reboot-restore.service
systemctl list-timers safe-reboot.timer
```

As asiri, `status` asks archon's run DB through the same `sudo -n -u archon
archon-as-archon` door the cron scripts use, but cannot read the archon user's
`~/.claude`; `sudo safe-reboot status` sees everything. If `safe-reboot-restore`
did not run after a reboot, the next gate tick puts the flag back (only the flag)
and ntfys. Window, deadline and paths are
`SAFE_REBOOT_*` variables at the top of the script (e.g. a
`systemctl edit safe-reboot.service` drop-in with `Environment=SAFE_REBOOT_WINDOW=01:00-05:00`).

## Troubleshooting

**Step 1 fails with `pre-existing sudoers problem`** — `visudo -c` rejects the
sudoers set as it already is, before `archon-cron` is added, so installing on
top would only make the post-install check fail for the wrong reason. The step
prints visudo's own output and then every file in `/etc/sudoers.d` that is not
mode 0440 owned by root; visudo refuses the *whole* set for any one such file
(the 2026-09-19 install hit an unrelated `/etc/sudoers.d/gc-resize` at 0644,
and the old message blamed `archon-cron`). Fix the named file and re-run:

```
sudo chmod 0440 /etc/sudoers.d/<file>     # or: sudo rm /etc/sudoers.d/<file>
sudo visudo -c                            # must print only "parsed OK" lines
sudo ops/host/install.sh
```

`--dry-run` as a normal user cannot read `/etc/sudoers`, so it skips this
baseline and says so; `sudo ops/host/install.sh --dry-run` runs it.

**Step 1 fails with `combined sudoers failed visudo -c after install`** — the
baseline passed, so the fault is in `archon-cron` itself (or in how it combines
with the rest); the file has already been removed and visudo's output is
printed above the error. `sudo` keeps working. Check
`visudo -c -f ops/host/sudoers-archon-cron` and the printed output.

## Revoke

```
sudo rm /etc/sudoers.d/archon-cron
```

That is the whole grant; the next weekly run then fails loud (`sudo -n refused`)
and ntfys. The other pieces are plain config: delete
`/etc/systemd/journald.conf.d/50-cap.conf`, `/etc/apt/apt.conf.d/52-archon-updates`,
`/usr/local/bin/smartd-ntfy`, or `apt-get purge smartmontools`, as needed.
The safe reboot: `systemctl disable --now safe-reboot.timer && systemctl disable safe-reboot-restore.service`
(then nothing reboots by itself: set `Automatic-Reboot "true"` in `52-archon-updates` if you
want the old behaviour back). oomd / sysctl: delete
`/etc/systemd/system/user@.service.d/20-oomd-pressure-limit.conf` (then `daemon-reload`,
`restart systemd-oomd`; Ubuntu's pressure kill at 50% is back) or `/etc/sysctl.d/60-dirty-bytes.conf` (then `sysctl vm.dirty_ratio=20
vm.dirty_background_ratio=10`).
The NodeSource change is a one-way version bump; the pre-change file is kept as
`nodesource.sources.bak-<date>`.

## Tests

```
bunx bats ops/cron/tests/host-install.bats ops/cron/tests/system-maintenance.bats ops/cron/tests/pipeline-health-system-maintenance.bats ops/cron/tests/safe-reboot.bats
shellcheck ops/host/install.sh ops/host/smartd-ntfy ops/host/safe-reboot/safe-reboot ops/cron/system-maintenance.sh
visudo -c -f ops/host/sudoers-archon-cron
```

`host-install.bats` runs step 1 of `install.sh` as a normal user through the
`HOST_INSTALL_SUDOERS_D=<dir>` test hook (sandboxed `sudoers.d`, root check
skipped, stops after step 1) with `visudo` and `install` stubbed on `PATH`.
The other steps can only be exercised with `--dry-run` without root.
`safe-reboot.bats` runs the gate and the restore as a normal user
(`SAFE_REBOOT_TEST=1`, every path a `SAFE_REBOOT_*` override) against stubbed
`bun`, `pgrep`, `systemctl`, `systemd-run`, `tmux`, `curl` and reboot command.
