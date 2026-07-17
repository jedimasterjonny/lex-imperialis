# grafana

Grafana as a Podman quadlet container, behind caddy, provisioned with a
Prometheus datasource and canned dashboards: **Node Exporter Full**
([grafana.com 1860](https://grafana.com/grafana/dashboards/1860)), **cadvisor**
([grafana.com 19792](https://grafana.com/grafana/dashboards/19792)), and
**Blackbox Exporter**
([grafana.com 16124](https://grafana.com/grafana/dashboards/16124)).

## Behind caddy

No published port. The container joins `caddy.network` and drops
`/etc/caddy/sites/grafana.caddy`, so caddy serves it at `grafana.<domain>` under
the wildcard vhost. caddy must be applied first (it owns the network and the
sites dir).

## Provisioning

- **Datasource** — `provisioning/datasources/prometheus.yml`, a default
  Prometheus at `grafana_prometheus_url` with a fixed `uid: prometheus`.
- **Dashboards** — `provisioning/dashboards/default.yml` points at
  `/etc/grafana/dashboards`, where the role fetches each `grafana_dashboards`
  entry from grafana.com at its pinned revision and mounts the directory
  read-only. Each dashboard's datasource variable auto-selects the default
  datasource.

State lives in the `grafana-data` named volume, handed to the image's `grafana`
user (472) with `:U`.

The container's podman healthcheck against `/api/health` is the restart backstop, not
the monitor (see `CLAUDE.md`); monitoring is the blackbox probe of the same endpoint.

## Hardening

The container runs `NoNewPrivileges` and drops every capability. The image runs
non-root as its own user (472) on an unprivileged port, so it adds none back.

## Variables

- `grafana_prometheus_url` — Prometheus datasource URL (default datasource).
- `grafana_admin_password` — admin password, vault-sourced, rendered `no_log`
  into `/etc/grafana/env`. Empty leaves the image default (`admin`/`admin`).
- `grafana_domain` — vhost domain; follows `caddy_domain`.

The image (`grafana_image`) is pinned by digest and each dashboard revision
(`grafana_dashboards`) by a custom datasource in `renovate.json`; renovate bumps
all of them.
