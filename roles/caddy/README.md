# caddy

Reverse proxy for the fleet's containers: one podman quadlet on
`caddy.network`, a wildcard vhost (`caddy_wildcard`, default on) and/or
explicit public site blocks, plus a `http://localhost` health endpoint
answering 204 — which the container's own podman healthcheck probes (status
only, no restart on failure). Anything matching no site — an unknown subdomain
or a foreign `Host` — gets a 404, not Caddy's default empty 200.

## Snippet contract

Backend roles drop `/etc/caddy/sites/<role>.caddy` containing named-matcher +
`handle` pairs:

```
@app host app.home.arpa
handle @app {
	reverse_proxy app:8080
}
```

The Caddyfile imports every snippet inside a single wildcard vhost — one
wildcard cert, so service names never reach the public CT logs. Matcher
names must be unique across snippets, hosts derive from `caddy_domain`, and
backends sit on `caddy.network` to resolve by container name. Set
`caddy_wildcard: false` on a host with no such backends.

## Public sites

A role serving its own public domain (an apex, not a wildcard subdomain) drops
a full site block at `/etc/caddy/sites-public/<role>.caddy`, imported at the
top level:

```
emmasedit.com, www.emmasedit.com {
	reverse_proxy app:80
}
```

The block author picks the scheme: an `http://` prefix stays off ACME, while a
bare (HTTPS) address is certified by the global `acme_dns` via DNS-01 (so the
cert is issued before any A record points here) — which needs
`caddy_cloudflare_api_token` scoped to that zone, or issuance fails at startup.

## TLS

Gated on `caddy_cloudflare_api_token`:

- **Set** — the vhost is `*.<caddy_domain>`, certified via DNS-01 through
  the cloudflare module in `ghcr.io/caddybuilds/caddy-cloudflare`.
- **Empty** — the default: the same vhost on plain HTTP
  (`http://*.<caddy_domain>`).

## Hardening

The container runs `NoNewPrivileges` and drops every capability except
`NET_BIND_SERVICE`, which it needs to bind `:80`/`:443`.

## Production setup

In the vault:

- `caddy_domain` — a Cloudflare zone.
- `caddy_cloudflare_api_token` — scoped to that zone: Zone→Read, DNS→Edit.

Point wildcard DNS for `*.<caddy_domain>` at the host. A malformed token
stops caddy at startup.
