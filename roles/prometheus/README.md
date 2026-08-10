# prometheus

Prometheus as a single Docker container, deployed from a templated compose
project with `community.docker.docker_compose_v2`. The TSDB and the rule
evaluator: it accepts the fleet's samples over remote-write, evaluates the
shipped rules against them, and routes what fires to the Alertmanager targets in
`prometheus_alertmanager_targets`.

**It scrapes nothing but itself.** The fleet's `node`, `cadvisor`, `blackbox` and
`alertmanager` jobs belong to the `prometheus_agent` role, which scrapes them
beside the exporters and writes here. Adding any of them back gives every one of
those series two writers, so each sample is ingested twice — the reason the
molecule scenario asserts the job set is exactly `["prometheus"]`.

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
- `prometheus_retention_time` — how long the TSDB keeps samples, rendered into
  `prometheus.yml` rather than passed as `--storage.tsdb.retention.time`, which
  the pinned Prometheus marks deprecated. Set past the 15d default because
  `MicroOSBuildStale` reads a fortnight back.
- `prometheus_run_user` — `uid:gid` the container runs as; owns the `0755` data
  dir. Defaults to the connecting user (root under molecule, the deploy user on the
  NAS).
- `prometheus_alertmanager_targets` — list of `host:9093` Alertmanager targets
  alerts are *routed* to. Routing only: the agent co-located with Alertmanager
  scrapes it over loopback, and a scrape from here as well would give the one
  Alertmanager two `instance` labels, so `InstanceDown` would fire on whichever
  network path blipped rather than on Alertmanager being down. `up{job="alertmanager"}`
  therefore arrives over remote-write like everything else — and since delivering
  an alert about Alertmanager needs a live Alertmanager, the `Watchdog` deadman is
  what surfaces a wholly dead one. Empty configures no alerting and loads no
  rules; non-empty adds the `alerting` block and the shipped rule files.
- `prometheus_remote_write_receiver` — accept remote-write pushes
  (`--web.enable-remote-write-receiver`), so a Prometheus in agent mode elsewhere
  writes into this TSDB. Off by default, and worth knowing before it is turned on:
  the endpoint carries no authentication, so anything that can reach the port can
  inject series.
- `prometheus_out_of_order_time_window` — `storage.tsdb.out_of_order_time_window`.
  Empty leaves Prometheus's default of no out-of-order ingestion, which quietly
  makes a writing agent's WAL buffer notional: the agent holds samples while this
  server is unreachable, but this server's own self-scrape keeps its head
  advancing and compacting every 2h, so on reconnect anything older than the last
  persisted block is rejected as out of bounds and dropped. Set it to the agent's
  `prometheus_agent_retention_max_time`, which that role sets explicitly for this
  reason rather than inheriting a compiled-in default a digest bump could move.
  Change one and change the other.
- `prometheus_security_opt_extra` — extra compose `security_opt` entries, appended
  to the `no-new-privileges` the template hardcodes (alongside `cap_drop: ALL`);
  empty in production.

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
one fault. The eight oneshots that emit a `*_success` metric are excluded: each already
has a `*Failed` rule with a richer description and the right severity, and `group_by`
is on `alertname`, so without the exclusion one fault would raise two alerts); the
`maintenance` group's `autoupdate` pair
`AutoupdateFailed` / `AutoupdateOverdue` (an unattended `zypper` run that failed or
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
exporter is scraped) plus the WordPress-update rules
`WordpressUpdateAvailable` (an update awaiting a hand — a major, or anything not
opted into auto-update) and the update-check pair `WordpressUpdateCheckFailed` /
`WordpressUpdateCheckOverdue` (a six-hourly update check that errored or has not
completed in over a day) and the cron pair `WordpressCronFailed` /
`WordpressCronOverdue` (the 5-minute wp-cron run that hard-failed or has not run
in over an hour); the `arbites` group's `ArbitesFailed` /
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
metric `wp-update-check.sh` writes itself rather than via an `ExecStopPost` hook. The
rules sit
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

A changed `prometheus.yml` recreates the container. The config is bind-mounted as
a single file; Ansible's atomic write gives it a new inode that the pinned mount
never sees, so a hot `/-/reload` reads the stale config — only a recreate
re-resolves the mount. The TSDB is a directory mount, so it survives.
