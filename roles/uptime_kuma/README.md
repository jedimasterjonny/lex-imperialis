# uptime_kuma

[Uptime Kuma](https://github.com/louislam/uptime-kuma) as a Podman quadlet on the
host network: a second watch on the fleet's services, with the status page and
per-monitor history the Prometheus/Alertmanager pair does not keep. The
monitors, notifications and status pages are entered in its UI and live in its
database; this role stands the server up and declares nothing about what it
watches.

## Host network, LAN bind

`Network=host` so its monitors resolve and reach their targets exactly as the
host does — LAN names, the WireGuard tunnel — like `blackbox_exporter` beside
it. The UI binds `uptime_kuma_listen_host`:`uptime_kuma_listen_port`, loopback
by default; a host that fronts it for a browser binds the LAN address and opens
the port itself. No published port, so caddy on another host fronts it through
`caddy_proxied_hosts`, which is how it gets the fleet's wildcard cert.

## Database

`UPTIME_KUMA_DB_TYPE=sqlite` in the unit skips the first-run database page: the
choice is written to `db-config.json` in the volume on every start, and the
`slim` image carries no embedded MariaDB, so SQLite is the only local option.
The first visit still creates the admin account.

`/app/data` is the `uptime-kuma-data` named volume, `:U` so rootful podman hands
it to the image's `node` user. It holds the database — every monitor, status
page and notification — and on `auspex` nothing copies it: the host runs no
`podman_backup`, and unlike the TSDB beside it this is hand-entered, not derived.

## Contract

- The `slim-rootless` image: no Chromium (no real-browser monitors) and no
  apprise, and the process runs as `node`. `verify` asserts the user, since a
  bump onto the non-rootless tag would run it as root with everything else
  still green.
- `DropCapability=all` and `NoNewPrivileges`. No `NET_RAW`, so ping monitors
  cannot work; HTTP, TCP and DNS ones can.
- The healthcheck is the image's own `extra/healthcheck` binary — shipped, but
  not declared as a `HEALTHCHECK` the OCI export keeps — named in the unit at
  the 5m backstop cadence with `HealthOnFailure=kill`. It reads the same bind
  the server does and exits 0 on any HTTP answer, so a fresh instance's setup
  redirect passes it. Monitoring is the blackbox probe of the UI from the
  scraper (`prometheus_probe_targets`), which raises `ProbeDown`.
- `TZ` is `Europe/London` and `verify` asserts the zone the container resolved.

## Variables

- `uptime_kuma_listen_host`, `uptime_kuma_listen_port` — what the UI binds.
  Loopback by default; two variables because the server reads two environment
  variables.
- `uptime_kuma_timezone` — the server's default timezone, which notifications
  and the log are stamped in.

The image (`uptime_kuma_image`) is pinned by digest; renovate bumps it.
