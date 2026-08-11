# autoupdate

Unattended weekly updates. A oneshot service runs `autoupdate_update_command` on
a per-host schedule (`autoupdate_oncalendar`, default `Mon *-*-* 03:00:00` plus a
0–2 h jitter) and reboots after a successful run so a new kernel takes effect —
`zypper dup` on Tumbleweed, `transactional-update dup` on MicroOS, whose root is
read-only, and `apt-get update` then `apt-get dist-upgrade` on Debian. The fleet
sets the schedule per host to different days so one bad update cannot brick every
host in a single night. `zypper`'s 102/103 "reboot/restart recommended" codes
count as success; a real failure skips the reboot, leaving the system up for
inspection.

`autoupdate_update_command` is a list, one `ExecStart=` per element, because
`zypper dup` refreshes its own metadata and `apt-get dist-upgrade` does not.
`Type=oneshot` runs them in order and aborts on the first failure, so the
refresh gates the upgrade. The Debian arm carries `--force-confold` and
`--force-confdef`, and the unit sets `DEBIAN_FRONTEND=noninteractive`
unconditionally — inert under zypper, and without it a changed conffile prompts
and hangs the unit until `TimeoutStartSec` on a host with nobody at the console.

A failed run retries hourly, three times (`Restart=on-failure`, `RestartSec=1h`,
bounded by `StartLimitBurst=4` over a `StartLimitIntervalSec=1d` window that
resets before the next weekly run). This exists for the one failure mode a
retry actually fixes: a mirror serving repo metadata ahead of the RPMs it
indexes, which aborts the whole commit with "Some packages could not be
provided" and would otherwise leave the host unpatched for seven days over a lag
that clears in hours. `AutoupdateFailed`'s `for:` is set longer than the 3 h the
burst spans, so a run still healing itself does not page — change one and change
the other.

`autoupdate_transactional` and `autoupdate_debian`, derived from
`ansible_facts`, select the command. `autoupdate_masked_timers` names the
distribution's own update timers, which are stopped and masked so exactly one
thing updates a host — `transactional-update.timer` on MicroOS,
`apt-daily.timer` and `apt-daily-upgrade.timer` on Debian, nothing on
Tumbleweed. Left armed they would update and reboot daily, writing none of the
metrics below. Both Debian timers are masked rather than only the upgrade one:
the metadata prefetch that costs is what `common`'s `apt: update_cache` already
does on every converge.

**On a Raspberry Pi the weekly `dist-upgrade` can flash the boot EEPROM.**
`rpi-eeprom-update.service` is enabled by the image and runs `-a` at every boot,
so a staged `rpi-eeprom` plus this role's own `ExecStartPost` reboot writes
firmware unattended on a headless board — and a failed flash is not a failed
service, it is a board that does not boot. Accepted rather than held: `auspex` is
stateless by design and its documented recovery is a card reflash, so the
recovery cost is bounded and the alternative is a host whose firmware silently
never moves. `apt-mark hold rpi-eeprom` is the lever if that trade stops looking
right.

An `ExecStopPost` hook writes each run's outcome to
`autoupdate_textfile_dir/autoupdate.prom` — `autoupdate_success` (1/0 from
`$SERVICE_RESULT`) and `autoupdate_last_run_timestamp_seconds`. node_exporter
scrapes that file (its `node_exporter_textfile_directory` must match), and the
`prometheus` role's `AutoupdateFailed` / `AutoupdateOverdue` rules surface a
failed or overdue update.

rogue-trader is where the transactional arm runs, and the only place that arm's
command is proven: no molecule tier boots MicroOS, so the scenario pins the
selector against shadowed facts and nothing more. The stop-before-mask ordering
is no longer unproven, though — the Debian platform ships both apt timers active,
so it exercises the two tasks for real.
