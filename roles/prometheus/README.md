# prometheus

Prometheus as a single Docker container, deployed from a templated compose
project with `community.docker.docker_compose_v2`. It scrapes itself, the
`node_exporter` targets in `prometheus_node_targets`, the `cadvisor` targets
in `prometheus_cadvisor_targets`, and the `alertmanager` targets in
`prometheus_alertmanager_targets` — to which it also routes alerts.

## Target: administratum (Synology)

The role's host is the NAS, not a fleet openSUSE node, which shapes it:

- **docker_compose_v2, not docker_container** — the NAS has the `docker compose`
  CLI but no Docker SDK for Python (and no `pip`), so the module that shells out
  to the CLI is the one that works.
- **No `become`** — sudo needs a password there; the deploy runs as the
  `docker`-group user. The task prepends `/usr/local/bin` to `PATH` for the DSM
  `docker`.
- **`network_mode: host`** — the container resolves and routes to scrape targets
  exactly as the host does, and serves on the host's `:9090`. No LAN address need
  enter this public repo.
- **Data dir `0755`, container runs as the deploy user** — no sudo on the NAS to
  chown the bind mount to the image's default `nobody` (65534), so the container
  runs as the deploy user (`prometheus_run_user`, the connecting user's `uid:gid`),
  which owns the dir. Migrating an existing `0777` deployment: stop the container,
  `chown -R <uid>:<gid>` the data dir as root once (the running container recreates
  its files as `nobody` under `0777`, so the chown only sticks while it is stopped),
  then apply.

## Variables

- `prometheus_project_dir` — where `compose.yaml` + `prometheus.yml` are written.
- `prometheus_data_dir` — host path bind-mounted as the TSDB (`/prometheus`).
- `prometheus_run_user` — `uid:gid` the container runs as; owns the `0755` data
  dir. Defaults to the connecting user (root under molecule, the deploy user on the
  NAS).
- `prometheus_node_targets` — list of `host:9100` scrape targets.
- `prometheus_cadvisor_targets` — list of `host:8080` scrape targets, scraped at
  30s to match cadvisor's housekeeping interval. Container series get a `container`
  label mirrored from cadvisor's `name` so the Docker-monitoring Grafana dashboard,
  which groups by `container`, renders.
- `prometheus_alertmanager_targets` — list of `host:9093` Alertmanager targets,
  both scraped and sent alerts. Scraping gives `up{job="alertmanager"}`, so a
  dead Alertmanager trips `InstanceDown` in Prometheus — but delivering that
  alert needs a live Alertmanager, so the `Watchdog` deadman heartbeat is what
  surfaces a wholly dead one. Empty configures no alerting and no scrape job;
  non-empty adds the `alerting` block and loads the shipped rule files.
- `prometheus_probe_targets` — blackbox probe targets: each entry is
  `{module, targets}`, pairing a prober module with the full URLs to run it against
  (the same module may appear in several entries). Each URL is handed to the
  `blackbox_exporter` (the `blackbox_exporter` role) via `?target=` and relabelled
  into the `instance` label, so the scrape hits the exporter, not the target; the
  entry's `module` rides along as `__param_module`. Empty adds no `blackbox` job.
- `prometheus_blackbox_address` — `host:port` of the `blackbox_exporter` the
  `blackbox` job scrapes; the exporter's loopback listen address on this host.
- `prometheus_security_opt_extra` — extra compose `security_opt` entries, appended
  to the `no-new-privileges` the template hardcodes (alongside `cap_drop: ALL`);
  empty in production.

## Blackbox probing

When `prometheus_probe_targets` is set, the role adds a `blackbox` job: for each
URL it scrapes the `blackbox_exporter` at `prometheus_blackbox_address` with
`?target=<url>&module=<the entry's module>` and `metrics_path: /probe`, so
Prometheus records `probe_success` and `probe_ssl_earliest_cert_expiry` per target
end-to-end. The exporter itself is the `blackbox_exporter` role, co-located on the
NAS.

The module is per target, not per job, because not every target answers `2xx`: an
auth-walled endpoint answers `401`, which still proves the daemon is serving. It
therefore goes in an entry naming a module whose `valid_status_codes` accept that,
and the module reaches the constructed scrape URL as `__param_module`.

A probe here is also how a *containerised* service is monitored on this fleet — the
network probe is the liveness alert, the container's healthcheck only a restart
backstop. See `CLAUDE.md`.

## Alerting

When `prometheus_alertmanager_targets` is set, the role adds the `alerting` block
and a `rule_files` glob, mounts its `files/rules/` at `/etc/prometheus/rules`, and
routes alerts to the targets. The shipped rules are `InstanceDown` (a target
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
not reach the NAS through the NFS exports); the `memory` group's `MemoryLow`
(`MemAvailable` under 10% for 15m — `FilesystemSpaceLow`'s threshold and window, for
the other exhaustible resource. `MemAvailable` has already netted off reclaimable
cache, so crossing it is real pressure, not a full-looking cache); the `hardware` group's
`HostCpuTemperatureHigh` (a CPU held above 95C for 15m, off
`node_hwmon_temp_celsius` scoped to `platform_coretemp_0` — the
chip only the two N150 boxes export, so the other two hosts raise nothing); the
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
one fault. The six oneshots that emit a `*_success` metric are excluded: each already
has a `*Failed` rule with a richer description and the right severity, and `group_by`
is on `alertname`, so without the exclusion one fault would raise two alerts); the
`maintenance` group's `autoupdate` pair
`AutoupdateFailed` / `AutoupdateOverdue` (an unattended `zypper` run that failed or
has not completed in over 9 days) plus the WordPress-update rules
`WordpressUpdateAvailable` (an update awaiting a hand — a major, or anything not
opted into auto-update) and the update-check pair `WordpressUpdateCheckFailed` /
`WordpressUpdateCheckOverdue` (a six-hourly update check that errored or has not
completed in over a day) and the cron pair `WordpressCronFailed` /
`WordpressCronOverdue` (the 5-minute wp-cron run that hard-failed or has not run
in over an hour); the `gitops` group's `GitopsReconcileFailed` /
`GitopsReconcileStale` (an unattended fleet reconcile that failed or has not completed
in over 2 hours); the `music` group's `BeetsPipelineLidarrRejected`
(an album beets matched but lidarr refused) and `BeetsPipelineQuarantineBacklog` (a
standing pile of no-match albums awaiting hand-processing); the `monitoring` group's
`PrometheusRuleEvaluationFailing` (a rule group erroring at evaluation, so its rules
have silently stopped producing series) and `PrometheusConfigReloadFailed` (a config
or rule file Prometheus rejected at reload, leaving it on the previous config) — the
two ways an unattended `gitops_reconcile` deploy of these very files fails silently,
both read off the `prometheus` self-scrape job; and the `watchdog`
group's always-firing `Watchdog` (`vector(1)`, no `for:`), whose silence at the
deadman receiver signals a broken Prometheus -> Alertmanager -> heartbeat
pipeline. The backup, dump,
update, cron, and reconcile outcome pairs, and the music backlog gauges, all read an
`ExecStopPost`-written metric off node_exporter's textfile collector; the
WordPress update gauge and its check pair read the same collector, but from a
metric `wp-update-check.sh` writes itself rather than via an `ExecStopPost` hook. The
rules sit
in a directory mount, so a changed rule reaches the container — but, like a config
change, only a recreate makes Prometheus reload it.

A changed `prometheus.yml` recreates the container. The config is bind-mounted as
a single file; Ansible's atomic write gives it a new inode that the pinned mount
never sees, so a hot `/-/reload` reads the stale config — only a recreate
re-resolves the mount. The TSDB is a directory mount, so it survives.
