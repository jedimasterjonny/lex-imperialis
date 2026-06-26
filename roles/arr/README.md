# arr

Media automation stack as rootful podman quadlets. Each webui is proxied at
`<app>.<arr_domain>` via the caddy snippet contract — except host-networked
apps (plex), reached directly. Config lives in per-app named volumes; media
lives under the NAS-backed `arr_data_root` as `media/<type>` libraries beside a
sibling `downloads`. `arr_enabled` picks which apps a host runs (default: all),
so the stack can come up one container at a time. Unit changes bounce only the
apps they touch.

Each webui app carries a podman liveness healthcheck against its own endpoint —
status only, no restart on failure; flaresolverr (no webui) is probed the same
way at its browserless `/health`, recyclarr (no endpoint) is the exception, and
wireguard's probe (below) instead force-restarts the tunnel.

## Apps

- **radarr / sonarr / lidarr** — the importers; mount the whole data tree,
  so imports hardlink from `downloads` into the libraries on one
  filesystem.
- **prowlarr** — indexer management; talks only to the other apps' APIs,
  no media mount.
- **flaresolverr** — Cloudflare-challenge solver for prowlarr; a
  headless-browser proxy with no media mount and, being an unauthenticated
  URL-fetcher, no proxy snippet — prowlarr reaches it by container name on
  `caddy.network`.
- **beets** — mounts the whole tree (`data: root`) so it hardlink-imports
  from `downloads` into lidarr's music library.
- **plex** — host-networked (so GDM/DLNA discovery works; not proxied),
  mounts the libraries read-only at their native flat paths (`/movies`,
  `/tv`, `/music`) to match its restored database, passes `/dev/dri` through
  for hardware transcoding, and gets a tmpfs `/transcode`.
- **recyclarr** — TRaSH-guides sync over the importers' APIs; no media
  mount, no webui. Its TRaSH config stays operator-managed in its volume; the
  importer API keys it talks to are repo-owned (see **API keys**).
- **transmission** — mounts `downloads` only, keeping the libraries out of
  the torrent client's reach; netns-confined to the tunnel (below).
- **wireguard** — owns the tunnel netns; no media.

## Least privilege

Every app runs as its own host uid. The importers, beets, transmission and
plex carry the shared `arr` group; the rest get a per-app group. The harder
boundary is the mount — a container can't reach what it never mounts. lscr.io
images drop their service to `PUID`/`PGID`; recyclarr runs under quadlet
`User=`. flaresolverr keeps the image's own non-root user with no host account —
it patches its bundled chromedriver in place under `/app`, writable only to that
user, and mounts nothing on the host.

Data dirs are setgid `2775`, each owned by the app that fills it; with
`UMASK=002` files land group-writable, so the rw apps co-write and
hardlink across each other's output. plex's membership is read-only —
`:ro` mounts enforce it.

## Music library catalog

A `beets-library.timer` runs `beets-library.sh` daily (`arr_beets_library_oncalendar`):
an incremental `beet import -A` then `beet update` over `arr_beets_music_dir`, so
the standing catalog (`/config/musiclibrary.blb` in the beets volume) tracks what
lidarr adds. Catalog only — `import -A` adds albums as-is, `plugins: []` disables
the image config's write-capable hooks, and write/copy/move are off, so no media
file is ever touched. Import runs before update so a transient `update` failure
can't block new additions.

The catalog config renders to `arr_beets_config_dir` on the host and bind-mounts
read-only into beets at `/config/managed`; the script `podman exec`s into the
running container so every path is `/data/...`. It skips cleanly when beets is
down (so a boot-time catch-up can't fail the unit). The oneshot is ordered
`After=beets.service` and the timer is `Persistent=true`. The container's own
`beet web` UI keeps using its default `/config` config, untouched.

## API keys

The Servarr apps (radarr, sonarr, lidarr, prowlarr) take their API key from the
repo, not a self-generated `config.xml` value. `arr_api_keys` (vault-sourced)
renders each app's key to a 0600 `/etc/arr/<app>.env`, which the unit reads as
`<APP>__AUTH__APIKEY` — the key never touches the world-readable unit, and the
env value overrides the config-file key at runtime. An empty key leaves the app
to generate its own, so molecule converges with no vault. Vault replaces the
whole dict; seed it with each app's current key so prowlarr and recyclarr keep
working across the cutover.

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
- **Auto-recovery** — wireguard carries a healthcheck (`ping` through wg0);
  sustained failure kills the container so systemd's `Restart=on-failure`
  rebuilds it and PartOf bounces transmission into the fresh netns. The
  template forces it off when `arr_wireguard_conf` is empty, so the blackhole
  isn't restart-looped.
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
