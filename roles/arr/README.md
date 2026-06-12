# arr

Media automation stack: podman quadlets on `caddy.network`, every webui
proxied at `<app>.<arr_domain>` via the caddy snippet contract. Config
lives in per-app named volumes; media lives under the NAS-backed
`arr_data_root`, one dir per data type, mounted at `/data`. Unit changes
bounce only the apps they touch.

## Apps

- **radarr / sonarr / lidarr** — the importers; mount the whole data tree,
  so imports hardlink from `downloads` into the libraries on one
  filesystem.
- **prowlarr** — indexer management; talks only to the other apps' APIs,
  no media mount.
- **beets** — mounts `music` only, co-writing lidarr's library.
- **plex** — mounts the libraries read-only, passes `/dev/dri` through for
  hardware transcoding, and publishes its port on the host for native
  clients.
- **recyclarr** — TRaSH-guides sync over the importers' APIs; no media
  mount, no webui. Its config stays operator-managed in its volume, keeping
  the arr API keys it holds out of the repo.
- **transmission** — mounts `downloads` only, keeping the libraries out of
  the torrent client's reach; netns-confined to the tunnel (below).
- **wireguard** — owns the tunnel netns; no media.

## Least privilege

Every app runs as its own host uid. The importers, beets and plex carry
the shared `arr` group; the rest get a per-app group, so a misbehaving
container can't write outside its app's files. lscr.io images drop their
service to `PUID`/`PGID`; recyclarr runs under quadlet `User=`.

Data dirs are setgid `2775`, each owned by the app that fills it; with
`UMASK=002` files land group-writable, so the rw apps co-write and
hardlink across each other's output. plex's membership is read-only —
`:ro` mounts enforce it.

## Transmission behind WireGuard

The wireguard container owns the network namespace; transmission joins it
via `Network=container:wireguard` and has no network of its own.

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
