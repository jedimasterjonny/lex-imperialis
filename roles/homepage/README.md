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

`/app/config` is the `homepage-config` named volume: homepage seeds the
scaffolding it requires there on first boot (and crash-loops if it can't write
it), then the operator adds `services.yaml`, `widgets.yaml` and `bookmarks.yaml`
directly — service widgets carry API keys, kept out of this public repo (as
recyclarr's config is). A named volume keeps that operator data off a host bind
mount and lets `podman_backup` capture it.

Ansible owns only `settings.yaml` (the title), rendered to `/etc/homepage` and
mounted read-only as a single file on top of the volume, so it stays
config-as-code without shadowing the seeded data. The container runs as the
`homepage` host id (`homepage_uid`, PUID/PGID), which owns that file.

The container carries a podman healthcheck against `/api/healthcheck` (status
only, no restart on failure).

## Variables

- `homepage_domain` — vhost domain; follows `caddy_domain`.
- `homepage_title` — dashboard title, rendered into `settings.yaml`.
- `homepage_timezone` — container timezone for date/time display.
- `homepage_uid` — host id the container runs as and that owns `settings.yaml`.

The image (`homepage_image`) is pinned by digest; renovate bumps it.
