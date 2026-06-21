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
