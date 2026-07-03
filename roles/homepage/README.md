# homepage

[Homepage](https://gethomepage.dev) as a Podman quadlet container, behind caddy.

## Behind caddy

No published port. The container joins `caddy.network` and drops a full site
block at `/etc/caddy/sites-public/homepage.caddy`, so caddy serves it at the
apex `homepage_domain` and certifies it through the global `acme_dns` (DNS-01).
caddy must be applied first (it owns the network and the sites-public dir).
`homepage_tls: false` drops the block to plain HTTP for molecule, which has no
token. The block sets `X-Content-Type-Options: nosniff` and `Referrer-Policy` on
every response, and on the TLS vhost adds a one-year `Strict-Transport-Security`
header — without `includeSubDomains`, since this is the fleet apex and would
otherwise pin every sibling subdomain to HTTPS.

Homepage v1 validates the `Host` header against `HOMEPAGE_ALLOWED_HOSTS`; the
unit allows the apex vhost plus the loopback `host:port` the liveness probe
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
config-as-code without shadowing the seeded data. Root owns the mode-0644 file;
the container reads it as its own id (`homepage_uid`, PUID/PGID) over the `:ro`
bind regardless of host owner.

The container carries a podman healthcheck against `/api/healthcheck` (status
only, no restart on failure).

## Hardening

The container runs `NoNewPrivileges` and drops every capability, adding back only
`CHOWN` (the entrypoint chowns the config volume to `homepage_uid`) and
`SETUID`/`SETGID` (its `su-exec` drop to that id). It binds `:3000`, so it needs
no `NET_BIND_SERVICE`. A renovate image bump that needs a new capability surfaces
as a failed healthcheck.

## Variables

- `homepage_domain` — apex domain homepage serves at; follows `caddy_domain`.
- `homepage_tls` — front the apex with an `acme_dns` cert (needs caddy's `caddy_cloudflare_api_token`); `false` serves plain HTTP (molecule).
- `homepage_title` — dashboard title, rendered into `settings.yaml`.
- `homepage_timezone` — container timezone for date/time display.
- `homepage_uid` — host id the container runs as (PUID/PGID).

The image (`homepage_image`) is pinned by digest; renovate bumps it.
