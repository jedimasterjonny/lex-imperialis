# node_exporter

Prometheus [node_exporter](https://github.com/prometheus/node_exporter) as a
podman quadlet on the host network, exporting host metrics on
`{{ node_exporter_listen_address }}` (default `:9100`).

The container runs with `--pid=host` and a read-only bind of `/` at `/host`
(`--path.rootfs=/host`) so it reports the host, not itself.

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
file there; `podman_backup` uses this to export its last run's outcome.

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
