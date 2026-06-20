# homepage

[Homepage](https://gethomepage.dev) as a Podman quadlet container, behind caddy.

## Behind caddy

No published port. The container joins `caddy.network` and drops
`/etc/caddy/sites/homepage.caddy`, so caddy serves it at `homepage.<domain>`
under the wildcard vhost. caddy must be applied first (it owns the network and
the sites dir).

Homepage v1 validates the `Host` header against `HOMEPAGE_ALLOWED_HOSTS`; the
unit allows the proxy vhost plus the loopback `host:port` the liveness probe
sends. `LOG_TARGETS=stdout` keeps logs off the config mount.

## Config

`/etc/homepage` is bind-mounted read-write at `/app/config`, `:Z`-relabelled so
the container can write it on the SELinux-enforcing fleet — homepage seeds the
scaffolding it requires on first boot, and crash-loops if the mount is read-only.
Ansible owns only `settings.yaml` (the title); the operator adds `services.yaml`,
`widgets.yaml` and `bookmarks.yaml` directly — service widgets carry API keys,
kept out of this public repo (as recyclarr's config is). The container runs as
the `homepage` host id (`homepage_uid`, PUID/PGID), which owns the dir.

The container carries a podman healthcheck against `/api/healthcheck` (status
only, no restart on failure).

## Variables

- `homepage_domain` — vhost domain; follows `caddy_domain`.
- `homepage_title` — dashboard title, rendered into `settings.yaml`.
- `homepage_timezone` — container timezone for date/time display.
- `homepage_uid` — host id the container runs as and that owns `/etc/homepage`.

The image (`homepage_image`) is pinned by digest; renovate bumps it.
