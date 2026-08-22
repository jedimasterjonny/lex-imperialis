# node_exporter

Prometheus [node_exporter](https://github.com/prometheus/node_exporter) as a
podman quadlet on the host network, exporting host metrics on
`{{ node_exporter_listen_address }}` (default `:9100`).

The container runs with `--pid=host` and a read-only bind of `/` at `/host`
(`--path.rootfs=/host`) so it reports the host, not itself.

It drops every Linux capability (`DropCapability=all`) and bars privilege
escalation (`NoNewPrivileges=true`). Host introspection reads world-readable
`/proc`, `/sys`, and the `/host` bind and needs nothing back; the sole exception
is `CAP_SYS_TIME`, re-added for the timex collector (see below).

It also runs as a **non-root** user, which the upstream image supplies (`USER
nobody`) rather than this role. Treat that as load-bearing, not incidental: the
container mounts the host D-Bus system bus (see the systemd collector below) and
systemd authorises Manager calls by uid, so an unprivileged caller is refused
`StartTransientUnit` while root would get arbitrary code execution as root on the
host. Because the property comes from the image, an upstream change could drop it
silently — so `verify` asserts the user explicitly.

## Exposure

`node_exporter_listen_address` controls the bind. A public host sets it to a
private IP (e.g. a WireGuard address) so the exporter never listens on its
public interface; pair that with a source-scoped `firewalld` rule. Opening
`9100/tcp` for the scraper is the playbook's job, not the role's.

When that address belongs to a VPN interface, set `node_exporter_after` to its
unit (e.g. `wg-quick@wg0.service`) so the exporter starts after the interface
and the bind can't race the address at boot.

## Textfile collector

The role creates `node_exporter_textfile_directory` (default
`/var/lib/node_exporter/textfile_collector`) and points the textfile collector at
it through the read-only `/host` bind. Batch jobs drop a world-readable `*.prom`
file there.

`templates/run-metric.sh.j2` is the shared `ExecStopPost` hook those jobs use,
publishing a scheduled unit's `<name>_success` and
`<name>_last_run_timestamp_seconds`. A consuming role symlinks it into its own
`templates/` under the name it installs and sets four vars on that template task:
`run_metric_textfile_dir`, `run_metric_name` (the family prefix),
`run_metric_file` (the `.prom` basename, which is not always the metric name —
inquisition writes `inquisition-run.prom`), and `run_metric_description` (prose
for the `HELP` lines). `autoupdate`, `inquisition`, `restic_backup`, `smartmon`
and `wordpress` (cron and db-dump) consume it; `arbites` keeps its own script,
as it publishes a third metric.

The hook is not a convenience copy of what systemd already knows. A
`Persistent=no` timer loses `LastTriggerUSec` across a reboot, and a successful
autoupdate reboots the host from its own `ExecStartPost` — so on every fleet host
the last recorded autoupdate run predates that host's boot while systemd reports
the timer as never triggered. This file is the only surviving record, which is
what the closing `sync` protects.

## Systemd collector

`--collector.systemd` with `--collector.systemd.enable-restarts-metrics` exports
`node_systemd_service_restart_total` per `*.service` unit (`unit-include` filters
out mounts, scopes, and timers), feeding Prometheus's `ServiceRestartStorm` alert.
The collector reads the host D-Bus system bus, so the container binds the host's
`/run/dbus/system_bus_socket` read-only at `/var/run/dbus/system_bus_socket` (the
path the bus library dials; the image has no `/var/run` symlink) and adds
`--security-opt=label=disable` —
the enforcing fleet otherwise denies `container_t` the socket connect (the same
trade-off cadvisor makes for the podman socket). Reads use the default,
non-private bus connection, which systemd serves to any uid, so the exporter
stays unprivileged.

## Timex collector

The default `timex` collector exports `node_timex_sync_status` (the kernel's
NTP-sync flag), feeding Prometheus's `ClockNotSynchronised` alert. It reads
`adjtimex(2)`, which the default seccomp profile gates behind `CAP_SYS_TIME`, so
the container adds that capability (`AddCapability=CAP_SYS_TIME`); without it the
collector fails and the metric never appears. The exporter only reads the clock —
the capability does also permit setting it, an accepted trade-off for the signal.
