# unpoller

[unpoller](https://github.com/unpoller/unpoller) as a Podman quadlet on the host
network. It polls the UniFi controller's API on its own schedule and exports the
result as Prometheus metrics: the UniFi hardware runs no exporter of its own, so
nothing else on the fleet can see it. The scrape job and targets live with the
scraper (the `unpoller` job in `prometheus`), which keeps only
`unpoller_device_*`, `unpoller_prometheus_*` and `unpoller_site_disconnected`;
this role stands up the poller only.

## Co-location is a requirement, not a convenience

The poller holds the controller's API key in its environment, so it binds
`127.0.0.1:9130` and is reachable only by a scraper on the same machine:
`prometheus_unpoller_targets` must name that loopback address, and the two roles
must land on the same host.

`Network=host` so the poller reaches the controller exactly as the host does.

## The API key is passphrase-grade

A UniFi Network API key is not a read-only telemetry token. The integration API
returns WiFi passphrases in plaintext to any holder, so the key is a credential of
the same weight as the controller's admin password. It is rendered to a 0600
`EnvironmentFile` with `no_log`, never into the world-readable quadlet, and the
molecule scenario asserts both the mode and that the file is what reaches the
container's environment.

## Configuration is environment variables, not a config file

unpoller maps each config field to `UP_<PATH>` from its `xml` struct tags
(`golift.io/cnfg`), overlaying the example `up.conf` the image ships at
`/etc/unpoller/up.conf`. Everything this deployment sets fits in the environment
file the API key already requires, so no config file is rendered and nothing is
mounted.

Three of those variables are load-bearing beyond their own setting. Two disable
what that shipped `up.conf` leaves on — the InfluxDB output and `save_speedtest`;
the env file says why for each. The third, `UP_UNIFI_DEFAULT_API_KEY`, is
exclusive of user/pass auth: unpoller sends it as `X-API-Key` and never logs in,
so the `user`/`pass` the shipped config still carries are inert while it is set.

## Variables

- `unpoller_url` — controller URL, no path after the host. Vaulted rather than set
  in a play: it is a private-network address and this repo is public.
- `unpoller_api_key` — the Network API key, minted in the controller's admin
  settings. Empty placeholder so the role degrades and molecule runs with no vault.
- `unpoller_listen_address` — what `/metrics` binds. Loopback by default, and see
  above for why it must stay there.
- `unpoller_verify_ssl` — verify the controller's TLS certificate. False, because a
  UniFi gateway serves its own self-signed cert; stated rather than inherited,
  since it is a trust decision.
- `unpoller_interval` — how often the poller refreshes the cache it serves.
  Upstream decouples this from the scrape cadence, so it is what actually drives
  API calls against the controller.

## Contract

- The poller is stateless — no data volume, no bind mount, nothing but the
  environment file.
- `DropCapability=all` and `NoNewPrivileges`. The distroless image sets no `USER`,
  so the container runs as root — which is why `verify` asserts `EffectiveCaps` as
  well as `BoundingCaps`, where a non-root container's effective set is empty
  regardless of the drop and asserting on it would be a check that cannot fail.
- **`HealthCmd=none`.** No published image carries a `HEALTHCHECK`, though
  upstream's `Dockerfile` declares one: the release is built by goreleaser to OCI
  media types, and `HEALTHCHECK` is a Docker-only config extension BuildKit drops on
  that export path — `podman inspect` reports `Config.Healthcheck` as null. The
  directive stays as a guard against upstream changing exporter, since an inherited
  check would be an OCI exec every 30 seconds on a Raspberry Pi to assert what the
  co-located scrape already reports — and a poller frozen on a stale snapshot passes
  an exec check anyway (below). `verify` asserts the directive in the unit, not the
  container's healthcheck, which is empty whether or not the quadlet disables it.
- **A green scrape does not mean a healthy poll.** `/metrics` is served from a
  snapshot refreshed in the background, so a revoked key or an unreachable
  controller leaves `up{job="unpoller"}` green and every `unpoller_*` series frozen at
  its last good value. `unpoller_prometheus_cache_age_seconds` is the staleness
  signal — `-1` until a poll has ever succeeded — and `UnpollerPollOverdue` in the
  `prometheus` role alerts on it. Not `unpoller_controller_up`, which upstream
  writes only on a *successful* fetch, so it never reads `0` for the failure worth
  alerting on. `verify` asserts the gauge and its `-1`, so the alert cannot lose
  its input silently.
