# autoupdate

Unattended weekly updates. A oneshot service runs `autoupdate_update_command` on
a per-host schedule (`autoupdate_oncalendar`, default `Mon *-*-* 03:00:00` plus a
0–2 h jitter) and reboots after a successful run so a new kernel takes effect —
`zypper dup` on Tumbleweed and `transactional-update dup` on MicroOS, whose root
is read-only. The fleet sets the schedule per host to different days so one bad
rolling snapshot cannot brick every host in a single night. `zypper`'s 102/103
"reboot/restart recommended" codes count as success; a real failure skips the
reboot, leaving the system up for inspection.

A failed run retries hourly, three times (`Restart=on-failure`, `RestartSec=1h`,
bounded by `StartLimitBurst=4` over a `StartLimitIntervalSec=1d` window that
resets before the next weekly run). This exists for the one failure mode a
retry actually fixes: a mirror serving repo metadata ahead of the RPMs it
indexes, which aborts the whole commit with "Some packages could not be
provided" and would otherwise leave the host unpatched for seven days over a lag
that clears in hours. `AutoupdateFailed`'s `for:` is set longer than the 3 h the
burst spans, so a run still healing itself does not page — change one and change
the other.

`autoupdate_transactional`, derived from `ansible_facts['distribution']`, selects
the transactional command and stops and masks the distribution's own
`transactional-update.timer`, which would otherwise update and reboot daily,
writing none of the metrics below.

An `ExecStopPost` hook writes each run's outcome to
`autoupdate_textfile_dir/autoupdate.prom` — `autoupdate_success` (1/0 from
`$SERVICE_RESULT`) and `autoupdate_last_run_timestamp_seconds`. node_exporter
scrapes that file (its `node_exporter_textfile_directory` must match), and the
`prometheus` role's `AutoupdateFailed` / `AutoupdateOverdue` rules surface a
failed or overdue update.

No fleet host runs MicroOS yet — the branch goes live with the `packer/` rebuild
— and no molecule tier boots it, so **the takeover is unproven until it runs on a
real host**. No container ships `transactional-update.timer`, so no scenario can
catch the stop-before-mask ordering being reversed; that rests on measurement.
