# grafana

Grafana as a Podman quadlet container, behind caddy, provisioned with a
Prometheus datasource and the canned **Node Exporter Full** dashboard
([grafana.com 1860](https://grafana.com/grafana/dashboards/1860)).

## Behind caddy

No published port. The container joins `caddy.network` and drops
`/etc/caddy/sites/grafana.caddy`, so caddy serves it at `grafana.<domain>` under
the wildcard vhost. caddy must be applied first (it owns the network and the
sites dir).

## Provisioning

- **Datasource** — `provisioning/datasources/prometheus.yml`, a default
  Prometheus at `grafana_prometheus_url` with a fixed `uid: prometheus`.
- **Dashboards** — `provisioning/dashboards/default.yml` points at
  `/etc/grafana/dashboards`, where the role fetches the 1860 JSON from
  grafana.com at the pinned `grafana_node_exporter_dashboard_revision` and mounts
  it read-only. Its `ds_prometheus` datasource variable auto-selects the default
  datasource.

State lives in the `grafana-data` named volume, handed to the image's `grafana`
user (472) with `:U`.

## Variables

- `grafana_prometheus_url` — Prometheus datasource URL (default datasource).
- `grafana_admin_password` — admin password, vault-sourced, rendered `no_log`
  into `/etc/grafana/env`. Empty leaves the image default (`admin`/`admin`).
- `grafana_domain` — vhost domain; follows `caddy_domain`.

The image (`grafana_image`) is pinned by digest and the dashboard revision
(`grafana_node_exporter_dashboard_revision`) by a custom datasource in
`renovate.json`; renovate bumps both.
