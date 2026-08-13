# playbooks

One play per fleet host, each the host's full spec; `make` defaults
`PLAY=scholam`. Dry-run a host with `make check PLAY=<host>`; the
operator applies with `make apply PLAY=<host>`. Names are 40K-themed, not
descriptive:

- **scholam** (`this_host`) — the control host, molecule runner, and
  workstation; runs the `arbites` timer.
- **solar** — the main homelab server: NFS client, the arr media stack behind
  caddy, plus grafana, homepage, monitoring agents, and backups.
- **administratum** — the Synology NAS, the one host without podman. The NFS
  server and the backup target; the only thing this play still manages is the
  weekly Docker image prune. Its Prometheus stack is stopped by hand and removed
  separately — dropping a role from a play does not remove it from the host.
- **auspex** — a Raspberry Pi 5 on Raspberry Pi OS aarch64, the only non-x86_64
  and only Debian host, and the whole of the monitoring stack: Prometheus scrapes
  the fleet, holds the TSDB on its NVMe and evaluates every rule, blackbox_exporter
  probes the public sites, solar's services and the NAS's NFS port, and
  Alertmanager notifies.
- **rogue-trader** — the Hetzner VPS serving the public WordPress site.

## site.yml

The whole fleet in one run — the `arbites` timer's entry point and
`make apply PLAY=site`. Imports the host plays with `scholam` last, so a
reconcile run never restarts its own timer mid-apply.

Order is not cosmetic. Ansible sums failed and unreachable hosts, so a play that
loses every host aborts the run: a host that cannot converge takes the plays
imported after it with it, `arbites` never writes `last_applied`, and the fleet
is re-applied in full every fifteen minutes while `scholam` quietly stops
converging. So a host joins this file only once its play converges green — until
then it runs by hand, `make apply PLAY=<host>` — and it must be in `arbites`'s
`known_hosts` first, or the connect fails and produces that same stall.
