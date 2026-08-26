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

Homepage validates the `Host` header against `HOMEPAGE_ALLOWED_HOSTS` on the
dashboard and the API routes, 400ing an unlisted vhost; static assets and the
auth routes are exempt. The unit lists only the apex vhost — the loopback
`host:port` the healthcheck sends is seeded into the allowlist regardless.
`LOG_TARGETS=stdout` keeps logs off the config mount.

The built-in auth gate stays off: `HOMEPAGE_AUTH_ENABLED=true` alone turns it
on, and without a signing secret, an external URL and a credential it is a
sign-in page nothing can log into. Both health signals hit `/api/healthcheck`,
which the gate exempts, so a lockout would read as green — hence the molecule
scenario asserting the dashboard root itself answers 200 with redirects
unfollowed.

## Config

`/app/config` is the `homepage-config` named volume: homepage seeds the
scaffolding it requires there on first boot (and crash-loops if it can't write
it). A named volume keeps that off a host bind mount and lets `podman_backup`
capture it.

The dashboard itself is config-as-code. Ansible renders `settings.yaml`,
`services.yaml`, `widgets.yaml` and `bookmarks.yaml` (`homepage_configs`) to
`/etc/homepage` and mounts each read-only as a single file on top of the volume,
so they never shadow the seeded data. Root owns the mode-0644 files; the
container reads them as its own id (`homepage_uid`, PUID/PGID) over the `:ro`
binds regardless of host owner.

The three content files are pass-throughs — `homepage_services`,
`homepage_widgets` and `homepage_bookmarks` serialised as-is — because a
dashboard is a host's spec, not a role's: the fleet's tiles live in
`playbooks/solar.yml`, as prometheus's probe targets live in `playbooks/auspex.yml`.
A host that declares none gets an empty dashboard, not homepage's shipped
examples. Every render is `sort_keys=False`: homepage lays groups and tiles out
in file order, and `settings.yaml`'s `layout:` orders the groups, so an
alphabetising dumper silently rewrites the dashboard. The scenario asserts that
order survives.

`href` is what the browser opens, so it is the URL the service is used over;
`siteMonitor` is fetched by the homepage container, so it takes the internal
container address — no hairpin DNS, no TLS, and no dependency on caddy, which
every `href` already goes through. Homepage's ICMP `ping:` cannot be used at all
here: the container drops `CAP_NET_RAW`. None of this is monitoring — the alert
for each tile is auspex's blackbox probe.

The container's podman healthcheck against `/api/healthcheck` is the restart backstop,
not the monitor (see `roles/CLAUDE.md`); monitoring is the blackbox probe of the same
endpoint, which — homepage serving the apex — exercises caddy on the way through.

## Service widgets

A tile's `widget:` block reads the service's own API, so it needs a credential —
which this public repo cannot hold in plaintext, and which must not land in the
mode-0644 configs either. Homepage substitutes `{{HOMEPAGE_VAR_<NAME>}}` in any
config file with the environment variable of that name, so `homepage_secrets`
renders to a 0600 `EnvironmentFile` at `/etc/homepage/env` that the unit reads,
exactly as `roles/arr` delivers `arr_api_keys`; the dashboard itself holds only
the placeholder. Keys are bare (`SONARR_KEY`) — the role adds the
`HOMEPAGE_VAR_` prefix homepage matches on, and a name it does not carry is a
placeholder homepage leaves untouched, so the widget fails rather than the
render. The scenario asserts both ends: the credential is in the container's
environment and is *not* in `services.yaml`.

Widget URLs follow `siteMonitor`'s reasoning, not `href`'s — homepage fetches
them itself, from the container. `arr_api_keys` and the transmission RPC
credentials are the same vault values `roles/arr` configures the services with,
so a rotation there is a rotation here. Values are read as literal env lines: a
credential containing `#`, a quote or a newline will not survive.

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
- `homepage_theme`, `homepage_color`, `homepage_header_style`, `homepage_status_style` — presentation, rendered into `settings.yaml`.
- `homepage_services`, `homepage_widgets`, `homepage_bookmarks` — the dashboard's content, serialised into the matching config file.
- `homepage_layout` — per-group style and columns, keyed by the group names in `homepage_services`; declaration order is the dashboard's group order.
- `homepage_timezone` — container timezone; carried for uniformity, since the dashboard clock is client-side.
- `homepage_uid` — host id the container runs as (PUID/PGID).
- `homepage_secrets` — widget credentials, keyed by the bare name the configs reference as `{{HOMEPAGE_VAR_<NAME>}}`; rendered to the 0600 `/etc/homepage/env`.

The image (`homepage_image`) is pinned by digest; renovate bumps it.
