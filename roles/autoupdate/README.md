# autoupdate

Unattended weekly updates. A oneshot service runs `zypper --non-interactive` on
a per-host schedule (`autoupdate_oncalendar`, default `Mon *-*-* 03:00:00` plus a
0–2 h jitter) and reboots after a successful run so a new kernel takes effect —
`dup` on rolling Tumbleweed, `patch` on Leap (`autoupdate_zypper_command`). The
fleet sets it per host to different days so one bad rolling snapshot cannot brick
every host in a single night. `zypper`'s 102/103 "reboot/restart recommended"
codes count as success; a real failure skips the reboot, leaving the system up
for inspection.

An `ExecStopPost` hook writes each run's outcome to
`autoupdate_textfile_dir/autoupdate.prom` — `autoupdate_success` (1/0, from
systemd's `$SERVICE_RESULT`, which 102/103 keep at success) and
`autoupdate_last_run_timestamp_seconds`. node_exporter scrapes that file (its
`node_exporter_textfile_directory` must match), and the `prometheus` role's
`AutoupdateFailed` / `AutoupdateOverdue` rules surface a failed or overdue update
before the host silently drifts unpatched.
