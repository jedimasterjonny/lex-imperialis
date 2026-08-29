# blackbox_exporter

Prometheus [blackbox_exporter](https://github.com/prometheus/blackbox_exporter)
as a Podman quadlet on the host network. It probes targets on demand at `/probe`;
the co-located scraper drives it (the `blackbox` job in `prometheus`) with
one `target=` per probed URL — the public sites and the fleet's internal services
— so a scrape yields `probe_success` for each, plus the TLS
`probe_ssl_earliest_cert_expiry` for the HTTPS targets. This role stands up the
exporter only — the targets and the scrape job live with the scraper.

## Co-location is a requirement, not a convenience

The exporter proxies to whatever `target=` it is handed, so exposing it would
hand anyone on the network an HTTP client running on this host. It binds
`127.0.0.1:9115` and is therefore only reachable by a scraper on the same
machine: `prometheus_blackbox_address` must match
`blackbox_exporter_listen_address`, and the two roles must land on the same host.

`Network=host` so the exporter resolves and routes to probe targets exactly as
the host does.

## Variables

- `blackbox_exporter_image` — the pinned image; renovate's image manager bumps
  the tag. In `vars/`, not a tunable.
- `blackbox_exporter_config_dir` — where `blackbox.yml` is written, and the
  directory bind-mounted read-only into the container.
- `blackbox_exporter_listen_address` — address the exporter binds `/probe` and
  `/metrics` on; loopback by default so it is not exposed on the LAN.
- `blackbox_exporter_modules` — prober modules rendered into `blackbox.yml`. Four
  by default. Two are HTTP, both following redirects (the redirect zones answer 3xx
  before the final 2xx) and probing over IPv4: `http_2xx`, and `http_2xx_or_401`,
  which additionally accepts a `401`. The latter is for an auth-walled endpoint,
  where the `401` is itself proof the daemon is up and serving — accepting it keeps
  that service's credentials off the exporter. `tcp_connect` is a bare
  connect for a host serving the fleet something other than HTTP: its one use is
  the NAS's NFS port, which is the only signal the fleet has that the NAS is up now
  that Prometheus no longer runs there and dies with it. `tcp_ssh_banner` reads
  the peer's SSH banner rather than merely connecting, for rogue-trader's storage
  box gateway: that listener is socket-activated, so a bare connect is answered
  from systemd's backlog and reports success whatever state the proxy behind it
  is in. A TCP probe measures no certificate, so
  `probe_ssl_earliest_cert_expiry` stays absent or zero and
  `ProbeSSLCertExpiringSoon`'s non-zero guard keeps it quiet. The scraper picks the
  module per target group; see `prometheus`'s `prometheus_probe_targets`.

## Contract

- The exporter is stateless — no data volume; only the `ro,Z` config bind mount.
- `DropCapability=all` and `NoNewPrivileges`: the HTTP prober opens ordinary
  sockets and needs no capability. (The ICMP prober would need `CAP_NET_RAW`; it
  is not used.) The image sets no `USER`, so the container runs as root — which is
  why `verify` asserts `EffectiveCaps` as well as `BoundingCaps`, where a non-root
  container's effective set is empty regardless of the drop and asserting on it
  would be a check that cannot fail.
- The config **directory** is mounted, not the file. A single-file bind mount pins
  an inode, so Ansible's atomic write left the container reading the old config
  until it was recreated — the trap the compose deployment worked around. With a
  directory mount the restart handler suffices, and since the exporter reads its
  config only at start, that restart is what applies a change.
- No podman healthcheck. The co-located Prometheus scrapes it and
  `BlackboxExporterDown` alerts on that, so a network probe already monitors it —
  an exec check would add a restart backstop and nothing else.
