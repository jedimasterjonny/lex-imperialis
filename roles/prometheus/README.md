# prometheus

Prometheus as a rootful podman quadlet, and the whole of the fleet's monitoring
in one process: it scrapes every exporter directly, stores the samples, evaluates
the shipped rules against them, and routes what fires to the Alertmanager targets
in `prometheus_alertmanager_targets`.

One process deliberately. This ran split for a while — an agent beside the
exporters remote-writing to a server on the NAS — which bought nothing and cost a
WAL, an out-of-order ingestion window paired by hand across two roles on two
hosts, an unauthenticated receiver endpoint, and two alerts whose only job was to
watch the split. Scraper and TSDB on one host need none of it.

## Target: auspex (Raspberry Pi OS)

- **Host network** — the container resolves and routes to scrape targets exactly
  as the host does, and reaches the co-located `blackbox_exporter`,
  `node_exporter` and `cadvisor` over loopback. Prometheus binds
  `prometheus_listen_address`, not every interface.
- **The TSDB is the `prometheus-data` named volume**, mounted `:U`. Rootful
  podman creates a volume root-owned and the image's `nobody` could not write it.
  `:U` is a recursive chown, so it walks every block in the retention window at
  each start — seconds on NVMe at a year of the fleet's ~17k series, and worth
  re-measuring before retention grows much past that.
- **That volume lands on the NVMe**, because the `podman` role mounts auspex's
  whole store there (`podman_storage_device`). A year of TSDB on the SD card would
  wear it out. The mount is `nofail`, so its absence is silent —
  `ContainerStoreMountMissing` is what says so.
- **No backup, and no redundancy.** The TSDB sat on a RAID1 pair with a monthly
  scrub and SMART mail; it now sits on one consumer NVMe with neither. Accepted:
  it is derived data, so losing it costs dashboards, not recovery.
- **4 GB of RAM.** The head is trivial at this series count, but a year of
  retention invites a long-range Grafana query that is not.
  `--storage.tsdb.retention.size` is the lever if it ever bites.

## Variables

- `prometheus_config_dir` — where `prometheus.yml` and `rules/` are rendered, and
  bind-mounted `ro,Z` into the container at the same path.
- `prometheus_listen_address` — what the web endpoint binds. Loopback by default;
  auspex binds the LAN so Grafana on solar can reach it.
- `prometheus_self_target` — what the self-scrape aims at, and so the `instance`
  label on the only series reporting whether the rule evaluator is itself healthy.
  Defaults to the bind address, which is right while that is loopback; a host
  binding the LAN sets a hostname instead: `192.168.x.x:9090` is a poor label to
  title an alert with, and while `--web.listen-address` would accept a name, making
  the bind depend on name resolution at boot is a fragility the label does not
  need. The same bind-an-address, scrape-by-name split `node_exporter` and
  `cadvisor` already have.
- `prometheus_retention_time` — how long the TSDB keeps samples, rendered into
  `prometheus.yml` rather than passed as `--storage.tsdb.retention.time`, which
  the pinned Prometheus marks deprecated. Set past the 15d default because
  `MicroOSBuildStale` reads a fortnight back; auspex sets `1y`.
- `prometheus_alertmanager_targets` — `host:9093` Alertmanager targets, used
  twice over: the `alerting` block routes there, and the `alertmanager` scrape job
  scrapes the same addresses for `up{job="alertmanager"}` and the delivery
  counters `AlertmanagerNotificationsFailing` reads. One var because there is one
  Alertmanager at one address — scraping it from anywhere else would give it a
  second `instance` label, and `InstanceDown` would then fire on whichever network
  path blipped rather than on Alertmanager being down. Delivering an alert about
  Alertmanager needs a live Alertmanager, so the `Watchdog` deadman is what
  surfaces a wholly dead one. Empty configures no alerting and loads no rules.
- `prometheus_node_targets` — `host:9100` node_exporter scrape targets.
- `prometheus_cadvisor_targets` — `host:8080` cadvisor scrape targets, scraped at
  cadvisor's own 30s housekeeping interval rather than the global 15s, and with
  `honor_timestamps: false`: cadvisor stamps each sample itself and only advances
  the stamp for a cgroup that saw activity, so an idle container re-serves an
  identical sample that would be rejected as out-of-order and store no point at
  all. The job's `metric_relabel_configs` rebuild the `container` and `image`
  labels the Grafana 15798 dashboard groups by out of the cgroup id.
- `prometheus_probe_targets` — blackbox probe targets: each entry pairs a prober
  module with the URLs to run it against, so the module is per target rather than
  per job, and the same module may appear more than once.
- `prometheus_blackbox_address` — `host:port` of the blackbox_exporter the
  `blackbox` job scrapes. Must match the `blackbox_exporter` role's
  `blackbox_exporter_listen_address`: two independent defaults on co-located
  roles, agreeing at the exporter's loopback bind.

## Alerting

When `prometheus_alertmanager_targets` is set, the role adds the `alerting` block
and a `rule_files` glob, copies its `files/rules/` into `rules/` under
`prometheus_config_dir` — which the quadlet mounts whole — and routes alerts to
the targets. The shipped rules are `InstanceDown` (a target
unreachable for 5m, the `blackbox` job excluded — its targets share one exporter,
so `up == 0` there is not a down target); the `probes` group — `BlackboxExporterDown`
(that exporter unreachable, aggregated to one alert so it doesn't fan out per
target), `ProbeDown` (a probe target that stopped answering with a status its module
accepts, for 5m) and
`ProbeSSLCertExpiringSoon` (its TLS cert under 14 days from expiry, guarded on a
non-zero expiry so a probe that measured no cert doesn't trip it), the latter two
off the `blackbox` probe job; the `backups` group — the `podman_backup` pair
`PodmanBackupFailed` (`podman_backup_success == 0`) and `PodmanBackupOverdue` (the
last-run timestamp gone stale), the matching `home_backup` pair `HomeBackupFailed`
/ `HomeBackupOverdue`, plus the `wordpress` db-dump pair `WordpressDbDumpFailed` /
`WordpressDbDumpOverdue`; the `filesystem` group —
`FilesystemSpaceLow` (a node_exporter filesystem under 10% free for 15m) and
`FilesystemReadOnly` (one the kernel remounted read-only after an I/O error — the
host stays up and probes stay green while every write fails. node_exporter hosts
only: `ro` is a client-side mount option, so unlike `FilesystemSpaceLow` this does
not reach the NAS through the NFS exports) and `ContainerStoreMountMissing`
(nothing mounted at `/var/lib/containers` from an NVMe, so podman — and this
Prometheus's own TSDB — is writing to the SD card underneath the mount point.
`nofail` is what makes that possible and what makes it silent; the device matcher
is load-bearing, since a mount from the wrong device is the same fault. `absent()`
carries only the equality matchers, so it names no host, and it also fires when
that host's node_exporter is down, alongside `InstanceDown`); the `memory` group's `MemoryLow`
(`MemAvailable` under 10% for 15m — `FilesystemSpaceLow`'s threshold and window, for
the other exhaustible resource. `MemAvailable` has already netted off reclaimable
cache, so crossing it is real pressure, not a full-looking cache); the `hardware` group's
`HostCpuTemperatureHigh` (a CPU held past its class's limit for 15m, off
`node_hwmon_temp_celsius` — one rule, two branches, because the fleet has two
thermal classes: `platform_coretemp_0` above 95C for the N150 boxes against their
105C Tjmax, and `thermal_thermal_zone0` above 80C for the Pi, which soft-throttles
there. Hosts exporting neither chip raise nothing); the
`time` group's `ClockNotSynchronised` (`node_timex_sync_status == 0` for 30m — a
node_exporter host whose clock is no longer NTP-synced); the
`services` group — `ServiceRestartStorm` (a systemd
unit that auto-restarted more than three times in 15m, off node_exporter's
`node_systemd_service_restart_total` counter — covers quadlet containers and every
other service alike, suppressed for the first 15m of uptime so boot restart
churn isn't a false storm) and `WireguardTunnelDown` (the same counter, but named to
`wireguard.service` and firing on the second restart: a dead tunnel raises nothing
else, since the arr apps sharing its netns answer on loopback and keep probing
green, so the restart cycle its healthcheck kill drives is the only signal) and
`AlertmanagerNotificationsFailing` (Alertmanager failing to deliver to Discord, the
only receiver that carries alerts — the `Watchdog` deadman routes to its own receiver,
so it stays green through a Discord-only failure, which nothing else sees. The alert
is itself routed to Discord, so a total outage surfaces it only on recovery) and
`SystemdUnitFailed` (the catch-all: any unit in the `failed` state for 15m, off
`node_systemd_unit_state`. It keys on the terminal failed state where the two rules
above key on the restart counter — flapping but alive — so they never double-report
one fault. The eight oneshots that emit a `*_success` metric are excluded: each already
has a `*Failed` rule with a richer description and the right severity, and `group_by`
is on `alertname`, so without the exclusion one fault would raise two alerts); the
`maintenance` group's `autoupdate` pair
`AutoupdateFailed` / `AutoupdateOverdue` (an unattended update run that failed or
has not completed in over 9 days) and its transactional counterpart
`MicroOSBuildStale` (a MicroOS host whose `node_os_version` build datestamp has not
advanced in a fortnight — two update cycles that changed nothing, most likely a
health-checker rollback to the previous snapshot after a failed boot, held 3h to
outlast the update timer's own jitter. Nothing else
sees that: `transactional-update` exits 0 and the metric is written before the
reboot, onto `@/var`, which no rollback reverts, so the pair above stays satisfied
by a run that was undone, while the old snapshot keeps every probe and unit green.
Staleness rather than the obvious regression because a rollback returns the host to
the build it was already running, and the failed boot is gone well before the
exporter is scraped) and `AutoupdatePackageHeld` (a package locked or held on any
host, which `AutoupdateFailed` and `AutoupdateOverdue` read as healthy: an update
that skips a locked package still exits 0 and advances its timestamp. Published by
the update run itself, so it cannot fire before the update it suppressed has run,
and does not clear on its own until the next one) and `AutoupdatePackagesUncleaned`
(packages nothing needs that the post-update cleanup left installed —
`class="unneeded"` means its own removal failed or, on MicroOS, never ran, and
`class="orphaned"` means no repository offers them, which is deliberately never
removed unattended. Published by the same hook on the same weekly cadence, so it
too clears only on the next run) plus the WordPress-update rules
`WordpressUpdateAvailable` (an update awaiting a hand — a major, or anything not
opted into auto-update) and the update-check pair `WordpressUpdateCheckFailed` /
`WordpressUpdateCheckOverdue` (a six-hourly update check that errored or has not
completed in over a day) and the cron pair `WordpressCronFailed` /
`WordpressCronOverdue` (the 5-minute wp-cron run that hard-failed or has not run
in over an hour) and the Jetpack Boost rules `WordpressBoostCriticalCssMissing`
(critical CSS Boost reports ungenerated, gated on `wordpress_boost_installed`
since the `wordpress` role does not manage the plugin),
`WordpressBoostCriticalCssStale` (generated over 30 days ago, gated instead on
`wordpress_boost_critical_css_generated` so a never-generated install — which
carries `updated` 0 — raises one alert rather than two) and the check pair
`WordpressBoostFailed` / `WordpressBoostOverdue`, the latter the only rule that
catches a stopped timer, since the check always exits 0 by design and its last
textfile keeps reading healthy. The permanently failing-provider count
deliberately carries no rule; the `arbites` group's `ArbitesFailed` /
`ArbitesStale` (an unattended fleet reconcile that failed or has not completed
in over 2 hours); the `drift` group's `ContainerDigestDrift` /
`UnmanagedContainerRunning` / `QuadletNotRunning` / `QuadletUnpinned` (the
inquisition's four classes — a running container off its quadlet's pin, a
container no quadlet declares, a quadlet declared but not running, a quadlet
pinned by tag alone), `QuadletsDisappeared` (nothing inspected at all, which
absent offender families otherwise render indistinguishable from clean) and the
`InquisitionFailed` / `InquisitionOverdue` pair (every `for:` spans at least
two of the hourly runs); the `music` group's `BeetsPipelineLidarrRejected`
(an album beets matched but lidarr refused) and `BeetsPipelineQuarantineBacklog` (a
standing pile of no-match albums awaiting hand-processing); the `monitoring` group's
`PrometheusRuleEvaluationFailing` (a rule group erroring at evaluation, so its rules
have silently stopped producing series) and `PrometheusConfigReloadFailed` (a config
or rule file Prometheus rejected at reload, leaving it on the previous config) — the
two ways an unattended `arbites` deploy of these very files fails silently,
both read off the `prometheus` self-scrape job — and `ScheduledJobMetricMissing`
(a host running one of the eight oneshots `SystemdUnitFailed` excludes while
publishing no matching `*_success` metric. That exclusion is only sound while the
metric exists: `== 0` and `time() - <gauge> > N` both match nothing on an empty
vector, so a family that stops being written disables its own `*Failed` and
`*Overdue` rules and is already exempt from the catch-all. Keyed on
`node_systemd_unit_state` rather than `absent()`, so it fires per host — the unit's
presence is exact ground truth for which hosts owe the metric, and carries no
topology — and it reports which family broke. Its roster and `SystemdUnitFailed`'s
exclusion regex are the same eight units held in two syntaxes, so the scenario
asserts the two sets are equal); and the `watchdog`
group's always-firing `Watchdog` (`vector(1)`, no `for:`), whose silence at the
deadman receiver signals a broken Prometheus -> Alertmanager -> heartbeat
pipeline. The backup, dump,
update, cron, reconcile, and drift-check outcome pairs, and the music backlog gauges,
all read an `ExecStopPost`-written metric off node_exporter's textfile collector — the
drift payload the offender rules read is written by the check itself; the
WordPress update gauge and its check pair read the same collector, but from a
metric `wp-update-check.sh` writes itself rather than via an `ExecStopPost` hook;
the autoupdate hold gauge comes from an `ExecStartPost` hook on the update unit,
so it is written before that run's reboot rather than after it. The rules sit
in a directory mount, so a changed rule reaches the container — but, like a config
change, only a recreate makes Prometheus reload it.

`tests/alerts_test.yml` holds `promtool test rules` cases, run by the `promtool-test`
pre-commit hook on a change to either the rules or the tests. They point at the
shipped `files/rules/alerts.yml`, so an expression is driven through both polarities
of the fault it names, with `for:`, labels and annotations evaluated. The division is
deliberate: `promtool check rules` only proves a file parses, and a rule that can
never fire parses perfectly, while the molecule scenario proves the rules load in a
real Prometheus — the deployment half rather than the semantic one. The tests live
outside `files/` so neither the `promtool` hook's glob nor the rules directory mount
picks them up.

Every rule in `alerts.yml` has cases, and the `alert-test-coverage` hook
(`bin/check-alert-test-coverage.py`) fails the commit if a new one arrives without
them — or if a case names a rule that no longer exists, which promtool passes
without comment whenever that case expects no alerts. Keep each `eval_time` a
multiple of the file's `evaluation_interval` — promtool floors an off-grid one
silently, and an assertion that lands a step early passes while meaning something
else.

A changed `prometheus.yml` or rule file restarts the container, via the role's
own handler. Prometheus reads both only at start, and nothing here fires a hot
`/-/reload`; the quadlet mounts the config *directory*, so the single-file inode
trap the previous compose deployment carried does not apply. The TSDB is a named
volume, so it survives the restart — and the molecule scenario's `side_effect`
proves the change actually reaches the running process rather than just the disk.
