# smartmon

SMART disk health as node_exporter textfile metrics — the early warning a
btrfs scrub cannot give: scrub finds corruption after the fact, where wear and
error counters move before a disk dies. Daily (`smartmon.timer` →
`smartmon.sh`), every device `smartctl --scan` finds is read with `smartctl -aj`
and published as:

- `smartmon_device_healthy{device}` — the firmware's overall verdict. A scanned
  device smartctl cannot assess reads 0, not absent: no verdict is not health.
- `smartmon_nvme_percentage_used{device}` / `smartmon_nvme_media_errors{device}`
  — the NVMe health log's spec-defined endurance and error counters. ATA wear
  attributes are vendor-specific and deliberately not parsed; an ATA disk is
  covered by the verdict alone.
- `smartmon_devices_checked` — the denominator that tells clean apart from a
  broken scan, which `SmartDevicesDisappeared` reads.

An `ExecStopPost` hook writes `smartmon_success` /
`smartmon_last_run_timestamp_seconds` to a separate `smartmon-run.prom`, so a
crash mid-read records its failure without zeroing verdicts it never measured.
A device whose report arrives truncated fails the whole run into that pair;
one whose report arrives empty reads unhealthy.

`smartmon_textfile_dir` must match the `node_exporter` role's
`node_exporter_textfile_directory`, or both files fall outside the collector's
glob and every rule matches an empty vector — `ScheduledJobMetricMissing` is
what catches that, and `TextfileScrapeError` a file that lands in the glob
malformed. `smartmon_oncalendar` sets the cadence the alert windows are sized
against, and `smartmon_script` / `smartmon_metric_script` where the reader and
its hook install — `/usr/local/sbin`, root-only like the other oneshots.

The `prometheus` role's `hardware` group alerts: `SmartDeviceUnhealthy` (the
verdict), `NvmeWearHigh` (endurance nearly spent), `NvmeMediaErrorsIncreasing`
(the earliest pre-failure signal — the verdict often stays green while these
climb), `SmartDevicesDisappeared`, and the `SmartmonFailed` /
`SmartmonOverdue` pair.

The smartmontools package ships its own poller, which Debian's postinst enables
and starts — a second SMART daemon sweeping every 30 minutes and mailing root —
so the role stops and disables the packaged unit on both distributions
(`smartmon_smartd_unit`, its one distribution branch).

Wired onto `scholam`, `solar` and `auspex` — the hosts with physical disks.
`rogue-trader` is excluded: a Hetzner Cloud virtio disk exposes no SMART.
The NAS monitors its own disks through DSM.
