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
  scrub and SMART mail; it now sits on one consumer NVMe with no scrub or
  redundancy — the SMART half is the `smartmon` role's daily check. Accepted:
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
the targets.

The rules are in `files/rules/alerts.yml`, grouped by concern: `availability`,
`probes`, `backups`, `filesystem`, `memory`, `hardware`, `time`, `services`,
`maintenance`, `arbites`, `drift`, `music`, `monitoring` and `watchdog`. Where a
threshold or a `for:` window was calibrated against a measurement or a past
failure, the comment above that rule records it. That file is the roster, and the
molecule scenario asserts the set Prometheus loaded matches it exactly.

The outcome rules read textfile metrics off node_exporter rather than systemd
state, written by an `ExecStopPost` hook on each unit — bar the drift payload and
the WordPress update and Jetpack Boost metrics, which the checks write themselves,
and the autoupdate hold and cleanup gauges, from an `ExecStartPost` hook so they
land before that run's reboot. That layer is what `SystemdUnitFailed`'s exclusions
rest on, and `ScheduledJobMetricMissing` is what notices a family that stops being
written — which would otherwise disable its own `*Failed` and `*Overdue` rules
silently.

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
without comment whenever that case expects no alerts. It also holds
`SystemdUnitFailed`'s exclusion roster and `ScheduledJobMetricMissing`'s clause
list to the same set of units. Keep each `eval_time` a
multiple of the file's `evaluation_interval` — promtool floors an off-grid one
silently, and an assertion that lands a step early passes while meaning something
else.

A changed `prometheus.yml` or rule file restarts the container, via the role's
own handler. Prometheus reads both only at start, and nothing here fires a hot
`/-/reload`; the quadlet mounts the config *directory*, so the single-file inode
trap the previous compose deployment carried does not apply. The TSDB is a named
volume, so it survives the restart — and the molecule scenario's `side_effect`
proves the change actually reaches the running process rather than just the disk.
