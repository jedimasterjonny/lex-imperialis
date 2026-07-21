# blackbox_exporter

Prometheus [blackbox_exporter](https://github.com/prometheus/blackbox_exporter)
as a single Docker container, deployed from a templated compose project with
`community.docker.docker_compose_v2`. It probes targets on demand at `/probe`;
Prometheus drives it (the `blackbox` job in the `prometheus` role) with one
`target=` per probed URL — the public sites and the fleet's internal services — so
a scrape yields `probe_success` for each, plus the TLS
`probe_ssl_earliest_cert_expiry` for the HTTPS targets. This role stands up the
exporter only — the targets and the scrape job live in `prometheus`.

## Target: administratum (Synology)

Co-located with Prometheus on the NAS, and shaped by the same host, so it mirrors
the `prometheus` role:

- **docker_compose_v2, not docker_container** — the NAS has the `docker compose`
  CLI but no Docker SDK for Python, so the module that shells out to the CLI is
  the one that works.
- **No `become`** — sudo needs a password there; the deploy runs as the
  `docker`-group user, with `/usr/local/bin` prepended to `PATH` for the DSM
  `docker`.
- **`network_mode: host`** — the exporter resolves and routes to probe targets
  exactly as the host does. No LAN address need enter this public repo.
- **Loopback listen address** — the exporter proxies to any `target=` it is
  handed, so it must not be reachable off-host. It binds `127.0.0.1:9115`, where
  only the co-located Prometheus scrapes it.

## Variables

- `blackbox_exporter_project_dir` — where `compose.yaml` + `blackbox.yml` are
  written.
- `blackbox_exporter_listen_address` — address the exporter binds `/probe` and
  `/metrics` on; loopback by default so it is not exposed on the LAN.
- `blackbox_exporter_modules` — prober modules rendered into `blackbox.yml`. Two by
  default, both following redirects (the redirect zones answer 3xx before the final
  2xx) and probing over IPv4: `http_2xx`, and `http_2xx_or_401`, which additionally
  accepts a `401`. The latter is for an auth-walled endpoint, where the `401` is
  itself proof the daemon is up and serving — accepting it keeps that service's
  credentials off the exporter. Prometheus picks the module per target group; see
  the `prometheus` role's `prometheus_probe_targets`.
- `blackbox_exporter_security_opt_extra` — extra compose `security_opt` entries,
  appended to the `no-new-privileges` the template hardcodes (alongside
  `cap_drop: ALL`); empty in production.

## Contract

- The exporter is stateless — no data volume; only the `ro` config bind mount.
- `cap_drop: ALL` and `no-new-privileges`: the HTTP prober opens ordinary
  sockets and needs no capability. (The ICMP prober would need `CAP_NET_RAW`; it
  is not used.)
- A changed `blackbox.yml` recreates the container. The config is bind-mounted as
  a single file; Ansible's atomic write gives it a new inode the pinned mount
  never sees, so only a recreate re-resolves it.
