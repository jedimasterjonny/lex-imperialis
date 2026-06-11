# arr

## Transmission behind WireGuard

The wireguard container owns the network namespace; transmission joins it via
`Network=container:wireguard` and has no network of its own.

- **Namespace owner** — wireguard sits on `caddy.network` with
  `NetworkAlias=transmission`, carries `NET_ADMIN` and
  `net.ipv4.conf.all.src_valid_mark=1`, and bind-mounts
  `/etc/wireguard/wg0.conf` read-only into wg-quick's conf dir.
- **Routing split** — wg-quick's `suppress_prefixlength 0` policy rule pushes
  only default-route traffic into wg0: peers and trackers ride the tunnel,
  while the podman subnet resolves from the main table, so caddy proxies the
  webui at the `transmission` alias without touching the VPN.
- **Lifecycle** — transmission is `Requires`/`After`/`PartOf` the wireguard
  service: it starts after the tunnel exists and restarts whenever wireguard
  does. A config change notifies `Restart wireguard`; PartOf carries
  transmission with it.
- **Kill-switch** — with `arr_wireguard_conf` empty, the role generates a
  blackhole config: random keys, `AllowedIPs = 0.0.0.0/0`, a TEST-NET
  endpoint. wg0 comes up with a dead default route, so torrent traffic cannot
  leak from first boot. The real config arrives whole from vault via
  `arr_wireguard_conf`, installed under `no_log`. Molecule converges and
  verifies the blackhole state.
- **Kernel module** — persisted via `/etc/modules-load.d/wireguard.conf`,
  modprobed only when `/sys/module/wireguard` is absent. The molecule
  instance is unprivileged with no kmod; prepare loads the module on the host
  instead.
- **Blast radius** — transmission mounts `/data/downloads` only and runs
  under its own per-app group; the setgid downloads dir hands its files to
  the shared group, so the importers can hardlink them while the media
  libraries stay out of transmission's reach.
