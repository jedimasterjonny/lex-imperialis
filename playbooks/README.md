# playbooks

One play per fleet host, each the host's full spec; `make` defaults
`PLAY=scholam`. Dry-run a host with `make check PLAY=<host>`; the
operator applies with `make apply PLAY=<host>`. Names are 40K-themed, not
descriptive:

- **scholam** (`this_host`) — the control host, molecule runner, and
  workstation; runs the `arbites` timer.
- **solar** — the main homelab server: NFS client, the arr media stack behind
  caddy, plus grafana, homepage, monitoring agents, and backups.
- **auspex** — a Raspberry Pi 5 on Raspberry Pi OS aarch64, the only non-x86_64
  and only Debian host, and the whole of the monitoring stack: Prometheus scrapes
  the fleet, holds the TSDB on its NVMe and evaluates every rule, blackbox_exporter
  probes the public sites, solar's services and the NAS's NFS port, and
  Alertmanager notifies.
- **rogue-trader** — the Hetzner VPS serving the public WordPress site.

`vars/` holds spec a play reads with `vars_files:` instead of carrying inline:
solar's homepage dashboard, which alone runs several times the length of the
rest of that play. Still the host's spec, just not in the way of it.

## site.yml

The whole fleet in one run — the `arbites` timer's entry point and
`make apply PLAY=site`. Imports the host plays with `scholam` last, so a
reconcile run never restarts its own timer mid-apply.

Both entry points reach it through `bin/fleet-apply.sh`, which shards this same
file by host with `--limit` so the remote hosts converge at once and `scholam`
still goes last. Run in series the four plays cost their sum — ansible's forks
never come into a single-host play — and the controller spends most of that idle
on serial SSH round trips. site.yml stays the one declaration of what the fleet
is; only the sharding is the driver's.

The fail-fast cascade is what the sharding drops, deliberately. Ansible sums
failed and unreachable hosts, so a play that loses every host aborts the run: a
host that could not converge took every play imported after it with it, which is
what quietly stopped `scholam` converging whenever an earlier host was broken.
Sharded, each host is attempted on its own. The run still exits non-zero, so
`arbites` never writes `last_applied` and the fleet is re-applied in full every
fifteen minutes until the broken host is fixed. A host still joins this file only
once its play converges green — until then it runs by hand, `make apply
PLAY=<host>` — and it must be in `arbites`'s `known_hosts` first, or its connect
fails the same way.
