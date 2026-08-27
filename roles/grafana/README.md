# grafana

Grafana as a Podman quadlet container, behind caddy, provisioned with a
Prometheus datasource and canned dashboards: **Node Exporter Full**
([1860](https://grafana.com/grafana/dashboards/1860)), **Docker monitoring**
([15798](https://grafana.com/grafana/dashboards/15798)), **Blackbox Exporter**
([16124](https://grafana.com/grafana/dashboards/16124)), and unpoller's
**USG** ([11313](https://grafana.com/grafana/dashboards/11313)), **USW**
([11312](https://grafana.com/grafana/dashboards/11312)) and **UAP**
([11314](https://grafana.com/grafana/dashboards/11314)) Insights.

## Behind caddy

No published port. The container joins `caddy.network` and drops
`/etc/caddy/sites/grafana.caddy`, so caddy serves it at `grafana.<domain>` under
the wildcard vhost. caddy must be applied first (it owns the network and the
sites dir).

## Provisioning

- **Datasource** — `provisioning/datasources/prometheus.yml`, a default
  Prometheus at `grafana_prometheus_url`, with `grafana_datasource_uid` as its
  `uid`. That is a constant rather than a tunable because the dashboards are
  rewritten to point at it — see below.
- **Dashboards** — `provisioning/dashboards/default.yml` points at
  `/etc/grafana/dashboards`, where the role writes each `grafana_dashboards` entry
  fetched from grafana.com at its pinned revision, and mounts the directory
  read-only.
- **The datasource placeholder is rewritten on the way in.** A grafana.com export
  names its datasource with an `__inputs` placeholder — `${DS_PROMETHEUS}` — which
  the UI's import form substitutes and the **file provisioner does not**, so the
  dashboard provisions pointing at a variable it never declares. It still lists and
  still opens, so nothing short of reading a panel notices. The role rewrites those
  to `grafana_datasource_uid`. All three unpoller dashboards carry them, and so
  does 15798 — **Docker monitoring** had been provisioning broken until this
  landed. Upper case only, deliberately; the task's comment says why.

State lives in the `grafana-data` named volume, handed to the image's `grafana`
user (472) with `:U`.

The container's podman healthcheck against `/api/health` is the restart backstop, not
the monitor (see `roles/CLAUDE.md`); monitoring is the blackbox probe of the same endpoint.

## Hardening

The container runs `NoNewPrivileges` and drops every capability. The image runs
non-root as its own user (472) on an unprivileged port, so it adds none back.

## Variables

- `grafana_prometheus_url` — Prometheus datasource URL (default datasource).
- `grafana_admin_password` — admin password, vault-sourced, rendered `no_log`
  into `/etc/grafana/env`. Empty leaves the image default (`admin`/`admin`).
  **First-init only**: it is read when Grafana creates the admin user, so setting
  it later re-renders the env file and restarts the container while the running
  instance keeps the password it already has. Changing a live one also needs
  `podman exec grafana grafana cli admin reset-admin-password <new>`.
- `grafana_domain` — vhost domain; follows `caddy_domain`.

The image (`grafana_image`) is pinned by digest and each dashboard revision
(`grafana_dashboards`) by a custom datasource in `renovate.json`; renovate bumps
all of them.
