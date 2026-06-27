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
- **beets** — mounts the whole tree (`data: root`) to catalog the music
  library and screen `downloads` into staging for lidarr to import.
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

## Music pipeline

beets screens each completed music download before lidarr imports it, so a
no-match album never reaches the library. lidarr owns acquisition and the final
import; beets owns the tags, lidarr owns the filenames and folder layout
(`renameTracks` ON). beets tags a **copy**, not the download, so the torrent keeps
seeding the original. The screening beets is a stateless tagger — it keeps no library
(the wrapper hands `beet import` a throwaway scratch DB under `/tmp`, discarded each
run); the only standing beets DB is Stage A's catalog (`/config/musiclibrary.blb`).

`beets-pipeline.timer` runs `beets-pipeline.sh` every
`arr_beets_pipeline_oncalendar` (10 min), inside the beets container (POSIX `sh`;
paths stay `/data/...`), in two phases:

1. **Screen each download once.** For each *settled* album folder under
   `arr_beets_download_dir` (untouched for `arr_beets_stable_minutes`), copy it to
   `arr_beets_staging_dir` and `beet import` the copy. A match is left staged for
   phase 2; a no-match copy goes to `arr_beets_quarantine_dir`. A
   `/config/pipeline/screened` marker (kept while the download is on disk) stops
   re-screening; the download itself is never touched. The phase is skipped when
   MusicBrainz is unreachable or 5xx, so an outage can't mass-quarantine matchable
   albums. Loose single files (not in a folder) aren't screened — handle by hand.
2. **Drive staged copies into lidarr.** The wrapper POSTs `DownloadedAlbumsScan`
   `importMode: Move`, so lidarr moves the copy into the library, renaming and
   organising it. A 2xx is *queued*, not *imported*, so it re-pokes until the staged
   copy has emptied of audio (lidarr moved it out), then drops the now-empty dir. A
   copy lidarr keeps queuing but never imports (unmonitored
   artist, profile mismatch) or 4xx-rejects goes to `<quarantine>/lidarr-rejected`
   after `arr_beets_poke_cap` ticks; a 5xx or unreachable lidarr is transient and
   never counts against the cap.

The lidarr key is read at runtime from the 0600 `/etc/arr/lidarr.env` the lidarr
container already uses (`EnvironmentFile=-`), passed in via `podman exec --env
LIDARR__AUTH__APIKEY` (no value) so it never reaches the exec argv; the non-secret
URL is templated into the script. A failed *run* surfaces via node_exporter's
`beets-pipeline.service` unit state; the screening *backlog* does not (a
quarantine-everything run still exits 0), so an `ExecStopPost` hook
(`arr_beets_metric_script`) publishes `beets_pipeline_quarantine_albums` (no-match,
awaiting hand-processing) and `beets_pipeline_lidarr_rejected_albums` (matched but
lidarr refused) as node_exporter textfile gauges (`arr_beets_metric_textfile_dir`)
for the prometheus role to alert on.

### Runtime lidarr invariants (not codified — set via the lidarr API)

The pipeline depends on lidarr settings this role does not manage:

- **Completed-download handling OFF** — beets must screen an album before lidarr
  commits, so lidarr cannot auto-import (ARR-AUDIT §G).
- **`renameTracks` ON** — lidarr renames and organises each `importMode: Move`
  import into `Artist/Album`, so the staged copy leaves staging and lands in the
  library with a consistent layout. With it off, lidarr drops the files flat in the
  artist folder and the wrapper's "did it move?" check still works, but the library
  loses its album structure — so this one is load-bearing for layout.
- **Download client "remove completed" OFF** — keep lidarr from removing the
  torrent; the pipeline never relies on lidarr touching the download.

Codifying these in-app settings is ARR-AUDIT §H (the arr-config layer), out of
scope here.

### Quarantine re-injection

Hand-process a quarantined album in place, then move it into
`arr_beets_staging_dir`; phase 2 finds it there and hands it to lidarr (phase 2 keeps
no state — the import is detected by the copy emptying of audio once lidarr moves it).
Don't move it back under `arr_beets_download_dir`: its screened marker would skip it.

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
