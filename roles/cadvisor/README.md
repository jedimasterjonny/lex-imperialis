# cadvisor

[cAdvisor](https://github.com/google/cadvisor) as a podman quadlet on the host
network, exporting per-container metrics on `{{ cadvisor_listen_ip }}:{{ cadvisor_port }}`
(default `:8080`).

The container is unprivileged. `--cgroupns=host` and read-only binds of `/`
(`/rootfs`) and `/sys` let it read every container's cgroup, filesystem, and
machine stats rather than only its own. The role enables `podman.socket` and
mounts it read-only so cadvisor's native podman factory labels containers by
`name` and `image`; without it containers show only as cgroup ids.

`--security-opt=label=disable` lifts SELinux `container_t` confinement. On an
enforcing host it otherwise denies the inotify watch on `/sys/fs/cgroup` (which
crashes cadvisor) and the write to the podman socket. A non-enforcing host (e.g.
the incus molecule container) ignores it.

OOM-event detection is off: it reads `/dev/kmsg`, which an unprivileged container
cannot, so `container_oom_events_total` stays flat. The rest of the collectors
are unaffected.

## Tuning

cAdvisor is heavyweight at its defaults. The role lengthens
`--housekeeping_interval` to 30s (from 1s), sets `--store_container_labels=false`,
and `--disable_metrics` drops the high-cardinality collectors the dashboard does
not read (`percpu`, `process`, `sched`, the per-protocol network counters, …),
keeping `cpu`, `cpuLoad`, `memory`, `network`, `disk`, `diskIO`, and `oom_event`.

## Exposure

`cadvisor_listen_ip` controls the bind. A public host sets it to a private IP
(e.g. a WireGuard address) so cadvisor never listens on its public interface;
pair that with a source-scoped `firewalld` rule. Opening the port for the
scraper is the playbook's job, not the role's.

When that address belongs to a VPN interface, set `cadvisor_after` to its unit
(e.g. `wg-quick@wg0.service`) so cadvisor starts after the interface and the bind
can't race the address at boot.

The image (`cadvisor_image`) is pinned by digest; renovate bumps it.
