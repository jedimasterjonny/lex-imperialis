# wordpress

WordPress as rootful podman quadlets — the `wordpress` (Apache/PHP) container,
its `wordpress-db` mariadb database, and a `wordpress-redis` object cache —
proxied at `wordpress.<wordpress_domain>` via the caddy snippet contract. Core
and uploads persist in the `wordpress-html` volume, the database in
`wordpress-db`. Targets openSUSE Leap 16.

## Database

`wordpress-db` runs the official mariadb image and creates `wordpress_db_name`
and `wordpress_db_user` on first init from the credentials file. wordpress
`Requires`/`After` it, so the database unit starts first; wordpress reconnects
until mariadb accepts connections, so a cold first boot self-heals.

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
step is installing and enabling the Redis Object Cache plugin in wp-admin; it
reads the constants and connects with no further config. wordpress only `Wants`
the cache — if it is down the plugin's drop-in degrades to WordPress's default
in-process cache.

## Behind Caddy

Caddy terminates TLS and forwards plain HTTP to `wordpress:80`. The official
image already trusts `X-Forwarded-Proto`, so WordPress detects HTTPS behind the
proxy and stops emitting `http://` URLs. The snippet routes
`wordpress.<wordpress_domain>`; point wildcard DNS for it at the host.

## Deploy

Wire it after `podman` and `caddy` on a Leap host, and set the passwords in the
vault:

```yaml
roles:
  - common
  - sshd
  - firewalld
  - podman
  - caddy
  - wordpress
```
