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
- **Data dir `0777`** — the image runs as `nobody` (65534) and there is no sudo
  to chown the bind mount to it.

## Variables

- `prometheus_project_dir` — where `compose.yaml` + `prometheus.yml` are written.
- `prometheus_data_dir` — host path bind-mounted as the TSDB (`/prometheus`).
- `prometheus_node_targets` — list of `host:9100` scrape targets.
- `prometheus_cadvisor_targets` — list of `host:8080` scrape targets, scraped at
  30s to match cadvisor's housekeeping interval.
- `prometheus_alertmanager_targets` — list of `host:9093` Alertmanager targets,
  both scraped and sent alerts. Scraping gives `up{job="alertmanager"}`, so a
  dead Alertmanager trips `InstanceDown` in Prometheus — but delivering that
  alert needs a live Alertmanager, so the `Watchdog` deadman heartbeat is what
  surfaces a wholly dead one. Empty configures no alerting and no scrape job;
  non-empty adds the `alerting` block and loads the shipped rule files.
- `prometheus_security_opt_extra` — extra compose `security_opt` entries, appended
  to the `no-new-privileges` the template hardcodes (alongside `cap_drop: ALL`);
  empty in production.

## Alerting

When `prometheus_alertmanager_targets` is set, the role adds the `alerting` block
and a `rule_files` glob, mounts its `files/rules/` at `/etc/prometheus/rules`, and
routes alerts to the targets. The shipped rules are `InstanceDown` (a target
unreachable for 5m); the `backups` group — the `podman_backup` pair
`PodmanBackupFailed` (`podman_backup_success == 0`) and `PodmanBackupOverdue` (the
last-run timestamp gone stale) plus the matching `wordpress` db-dump pair
`WordpressDbDumpFailed` / `WordpressDbDumpOverdue`; `FilesystemSpaceLow` (a
node_exporter filesystem under 10% free for 15m); `ServiceRestartStorm` (a systemd
unit that auto-restarted more than three times in 15m, off node_exporter's
`node_systemd_service_restart_total` counter — covers quadlet containers and every
other service alike, suppressed for the first 15m of uptime so boot restart
churn isn't a false storm); the `maintenance` group's `autoupdate` pair
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
standing pile of no-match albums awaiting hand-processing); and the `watchdog`
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
