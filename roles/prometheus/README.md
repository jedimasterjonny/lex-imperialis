# prometheus

Prometheus as a single Docker container, deployed from a templated compose
project with `community.docker.docker_compose_v2`. It scrapes itself and the
`node_exporter` targets in `prometheus_node_targets`.

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

A changed `prometheus.yml` is hot-reloaded via `/-/reload`
(`--web.enable-lifecycle`); the container is not restarted.
