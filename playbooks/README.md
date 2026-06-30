# playbooks

One play per fleet host, each the host's full spec; `make` defaults
`PLAY=scholam`. Dry-run a host with `make check PLAY=<host>`; the
operator applies with `make apply PLAY=<host>`. Names are 40K-themed, not
descriptive:

- **scholam** (`this_host`) — the control host, molecule runner, and
  workstation; runs the `gitops_reconcile` timer.
- **solar** — the main homelab server: NFS client, the arr media stack behind
  caddy, plus grafana, homepage, monitoring agents, and backups.
- **administratum** — the Synology NAS, the one non-openSUSE host: runs only
  Prometheus, unprivileged, via Docker Compose.
- **rogue-trader** — the Hetzner VPS serving the public WordPress site.

## site.yml

The whole fleet in one run — the `gitops_reconcile` timer's entry point and
`make apply PLAY=site`. Imports the host plays with `scholam` last, so a
reconcile run never restarts its own timer mid-apply.
