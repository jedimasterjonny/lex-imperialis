# caddy

Reverse proxy for the fleet's containers: one podman quadlet on
`caddy.network`, one wildcard vhost, plus a `http://localhost` health
endpoint answering 204.

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
backends sit on `caddy.network` to resolve by container name.

## TLS

Gated on `caddy_cloudflare_api_token`:

- **Set** — the vhost is `*.<caddy_domain>`, certified via DNS-01 through
  the cloudflare module in `ghcr.io/caddybuilds/caddy-cloudflare`.
- **Empty** — the default: the same vhost on plain HTTP
  (`http://*.<caddy_domain>`).

## Production setup

In the vault:

- `caddy_domain` — a Cloudflare zone.
- `caddy_cloudflare_api_token` — scoped to that zone: Zone→Read, DNS→Edit.

Point wildcard DNS for `*.<caddy_domain>` at the host. A malformed token
stops caddy at startup.
