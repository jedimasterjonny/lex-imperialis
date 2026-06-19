# wordpress

WordPress as rootful podman quadlets — the `wordpress` (Apache/PHP) container,
its `wordpress-db` mariadb database, and a `wordpress-redis` object cache —
served at its own `wordpress_domains` via a caddy public site block. Core
and uploads persist in the `wordpress-html` volume, the database in
`wordpress-db`; each container self-heals via a healthcheck. Targets openSUSE
Leap 16.

## Database

`wordpress-db` runs the official mariadb image and creates `wordpress_db_name`
and `wordpress_db_user` on first init from the credentials file. wordpress
`Requires`/`After` it, so the database unit starts first; wordpress reconnects
until mariadb accepts connections, so a cold first boot self-heals.
`MARIADB_AUTO_UPGRADE` runs `mariadb-upgrade` when the image is a newer major
than the data dir, so a renovate mariadb bump migrates the system tables on the
next restart with no manual step.

## Secrets

`wordpress_db_password` and `wordpress_db_root_password` are vault-sourced and
rendered into `/etc/wordpress/wordpress.env` (`0600`, `no_log`), which the
database and web quadlets read via `EnvironmentFile=` so the passwords never
reach the world-readable unit files. Left empty, the stack stays uninitialised. MariaDB
sets the passwords only on first init — rotating one means an in-container
`ALTER USER` or resetting the `wordpress-db` volume.

## Object cache

`wordpress-redis` runs redis as a pure object cache — memory capped at
`wordpress_redis_maxmemory` with LRU eviction, no volume, no persistence. The
role pre-wires `WP_REDIS_HOST`/`WP_REDIS_PORT` into wp-config, so the only manual
step is installing and enabling the Redis Object Cache plugin (via `wp`, below,
or wp-admin); it reads the constants and connects with no further config.
wordpress only `Wants` the cache — if it is down the plugin's drop-in degrades to
WordPress's default in-process cache.

## Scheduled tasks

`DISABLE_WP_CRON` takes wp-cron off visitor page-loads; a `wordpress-cron.timer`
runs `wp cron event run --due-now` every 5 minutes instead, so scheduled tasks
fire on a fixed cadence regardless of traffic. On a migrated install set it in
wp-config directly (`wp config set DISABLE_WP_CRON true --raw`) — the bundled
constant only lands on a fresh, role-generated config.

## Behind Caddy

Caddy forwards plain HTTP to `wordpress:80`, terminating TLS at the edge when
`wordpress_tls` is set. The official image already trusts `X-Forwarded-Proto`,
so WordPress detects HTTPS behind the proxy and stops emitting `http://` URLs. The role writes a
`sites-public/wordpress.caddy` block routing every name in `wordpress_domains`;
with `wordpress_tls` (default) the caddy global `acme_dns` certifies them via
DNS-01. The block sets `X-Content-Type-Options: nosniff`, `Referrer-Policy`, and
a `Permissions-Policy` on every response, strips the upstream `X-Powered-By`, and
on the TLS vhost adds a one-year `Strict-Transport-Security` header with
`includeSubDomains`. Static assets (matched by extension) carry a one-year
immutable `Cache-Control`; `readme.html` and `license.txt` 404 so they can't
leak the core version. A read-only must-use plugin
(`files/wordpress-hardening.php`, mounted at `wp-content/mu-plugins/`) drops the
generator meta for the same reason. Point DNS for each name at the host.

## wp-cli

`/usr/local/bin/wp` runs the official `wordpress:cli` image against the live
stack — the web container's volumes, the database credentials, and the network —
so `wp <command>` manages the site. Rootful podman, so run it as root. Turn on
the object cache with:

```bash
wp plugin install redis-cache --activate
wp redis enable
```

## Hardening

Each container runs `NoNewPrivileges` and drops every capability, adding back
only what its image needs: `wordpress-db` keeps `CHOWN`/`DAC_OVERRIDE` (datadir
ownership) and `SETUID`/`SETGID` (the entrypoint's drop to the mysql user);
`wordpress` also keeps `FOWNER` (unpacking core) and `NET_BIND_SERVICE` (apache
on `:80`); `wordpress-redis` keeps none. A renovate image bump that needs a new
capability surfaces as a failed healthcheck.

## Deploy

Wire it after `podman` and `caddy` on a Leap host. Set `wordpress_domains` to
the public names, the DB passwords in the vault, and — for TLS (`wordpress_tls`,
the default) — caddy's `caddy_cloudflare_api_token` scoped to that zone; set
`wordpress_tls: false` for plain HTTP instead.

```yaml
roles:
  - common
  - sshd
  - firewalld
  - podman
  - caddy
  - wordpress
```
