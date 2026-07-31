# autoupdate

Unattended weekly updates. A oneshot service runs `autoupdate_update_command` on
a per-host schedule (`autoupdate_oncalendar`, default `Mon *-*-* 03:00:00` plus a
0–2 h jitter) and reboots after a successful run so a new kernel takes effect —
`zypper dup` on rolling Tumbleweed, `zypper patch` on Leap, and
`transactional-update dup` on MicroOS, whose root is read-only. The fleet sets
the schedule per host to different days so one bad rolling snapshot cannot brick
every host in a single night. `zypper`'s 102/103 "reboot/restart recommended"
codes count as success; a real failure skips the reboot, leaving the system up
for inspection.

`autoupdate_transactional`, derived from `ansible_facts['distribution']`, selects
the transactional command.

An `ExecStopPost` hook writes each run's outcome to
`autoupdate_textfile_dir/autoupdate.prom` — `autoupdate_success` (1/0 from
`$SERVICE_RESULT`) and `autoupdate_last_run_timestamp_seconds`. node_exporter
scrapes that file (its `node_exporter_textfile_directory` must match), and the
`prometheus` role's `AutoupdateFailed` / `AutoupdateOverdue` rules surface a
failed or overdue update.

No fleet host runs MicroOS yet — the branch goes live with the `packer/` rebuild
— and no molecule tier boots it, so verify pins the selector's third branch by
resolving the defaults against a MicroOS fact rather than on a host.
