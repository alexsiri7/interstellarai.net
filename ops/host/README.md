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

## What install.sh does

| Step | Files | Effect |
|---|---|---|
| 1. sudoers | `/etc/sudoers.d/archon-cron` (0440) from [`sudoers-archon-cron`](sudoers-archon-cron) | `asiri` may run, NOPASSWD, exactly the eight command shapes the weekly job uses (below). Validated with `visudo -c -f` before it is copied and with `visudo -c` on the whole sudoers set after; rolled back if the latter fails. No `ALL`. |
| 2. journald | `/etc/systemd/journald.conf.d/50-cap.conf` | `SystemMaxUse=500M` (was uncapped, 2.5G), then `systemctl restart systemd-journald`. |
| 3. unattended-upgrades | `/etc/apt/apt.conf.d/52-archon-updates` | Adds `${distro_id}:${distro_codename}-updates` to `Allowed-Origins` (the stock `50unattended-upgrades` only takes `-security`, which is why 95 packages were sitting upgradable), `Remove-Unused-Dependencies "true"`, `Automatic-Reboot "true"` at `05:45` — after every Sunday cron job (`system-maintenance.sh` 04:00, the backup restore test 04:30, `pipeline-health-cron.sh --trim` 05:00) has finished, so a reboot never cuts one off. apt.conf lists merge across files, so `50unattended-upgrades` is left alone. Also asserts `APT::Periodic::Unattended-Upgrade` is `1`. |
| 4. snap | — | `snap set system refresh.retain=2` and `snap remove --revision=N name` for every revision `snap list --all` marks `disabled` (20 on 2026-09-19). |
| 5. smartmontools | `/etc/smartd.conf`, `/usr/local/bin/smartd-ntfy` (0755) from [`smartd-ntfy`](smartd-ntfy) | Installs the package, one `DEVICESCAN` line: all checks, offline testing and attribute autosave on, spun-down disks left alone (`-n standby,q`), short self-test daily 02:00 and long self-test Saturdays 03:00, every alert delivered through `smartd-ntfy` (`-m root -M exec`). `systemctl enable --now smartd`. |
| 6. NodeSource | `/etc/apt/sources.list.d/nodesource.sources` (backup kept alongside) | Rewrites `node_20.x` (or any other line) to `node_24.x` in the Suites/URIs (Node 20 is EOL, 24 is the current LTS line), `apt-get update`, `apt-get install -y nodejs`. |
| 7. reboot | — | Prints whether `/var/run/reboot-required` exists (and which packages set it). |

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
/usr/bin/apt-get -y -o Dpkg::Options::=--force-confold upgrade
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

Per run: apt update/upgrade/autoremove with the `apt list --upgradable` count
logged before and after; every disabled snap revision removed; journal vacuumed
to 500M; `smartctl -H` on each `disk` from `lsblk` (loop devices excluded;
`SYSTEM_MAINT_SMART_SKIP="sda ..."` leaves a disk out) with an urgent ntfy for
anything not `PASSED`; and while `/var/run/reboot-required` exists, one ntfy
per running kernel ("reboot pending; auto-reboot at 05:45"), remembered in
`~/.archon/pipeline-health-state/system-maintenance-reboot-notified` and
cleared once the file goes away. The run summary lands in
`~/.archon/pipeline-health-state/system-maintenance-status` (same shape as
`db-backup-status`), and `pipeline-health-cron.sh` (`check_system_maintenance`)
ntfys once when that reads `failed` or no successful run landed in 8 days.

Log: `/tmp/system-maintenance.log`. Run by hand: `ops/cron/system-maintenance.sh`.

Auto-reboot: `Automatic-Reboot` is acted on by unattended-upgrades itself, on
its daily run (`apt-daily-upgrade.timer`, 06:00 ± 1h) — when it finds
`/var/run/reboot-required` it schedules the reboot for the next 05:45. Archon
survives that: it runs as lingering user systemd services plus cron, no docker.

## Revoke

```
sudo rm /etc/sudoers.d/archon-cron
```

That is the whole grant; the next weekly run then fails loud (`sudo -n refused`)
and ntfys. The other pieces are plain config: delete
`/etc/systemd/journald.conf.d/50-cap.conf`, `/etc/apt/apt.conf.d/52-archon-updates`,
`/usr/local/bin/smartd-ntfy`, or `apt-get purge smartmontools`, as needed.
The NodeSource change is a one-way version bump; the pre-change file is kept as
`nodesource.sources.bak-<date>`.

## Tests

```
bunx bats ops/cron/tests/system-maintenance.bats ops/cron/tests/pipeline-health-system-maintenance.bats
shellcheck ops/host/install.sh ops/host/smartd-ntfy ops/cron/system-maintenance.sh
visudo -c -f ops/host/sudoers-archon-cron
```

`install.sh` itself can only be exercised with `--dry-run` without root.
