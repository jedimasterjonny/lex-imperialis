# wordpress

WordPress as rootful podman quadlets — the `wordpress` (Apache/PHP) container,
its `wordpress-db` mariadb database, and a `wordpress-redis` object cache —
served at its own `wordpress_domains` via a caddy public site block. Core
and uploads persist in the `wordpress-html` volume, the database in
`wordpress-db`; each container self-heals via a healthcheck. Targets openSUSE
Leap 16.

## Database

`wordpress-db` runs the official mariadb image and creates `wordpress_db_name`
and `wordpress_db_user` on first init from `db.env`. wordpress
`Requires`/`After` it, so the database unit starts first; wordpress reconnects
until mariadb accepts connections, so a cold first boot self-heals.
`MARIADB_AUTO_UPGRADE` runs `mariadb-upgrade` when the image is a newer major
than the data dir, so a renovate mariadb bump migrates the system tables on the
next restart with no manual step.

## Database backups

That in-place upgrade can fail — `HealthOnFailure=kill` + `Restart=on-failure`
then restart-loops the database — and `podman_backup`'s only net is a cold raw
`/var/lib/mysql` copy a newer engine may refuse to mount. So
`wordpress-db-dump.timer` runs `/usr/local/bin/wp-db-dump` daily: a `mariadb-dump
--single-transaction --databases` of `wordpress_db_name`, authenticating as
`wordpress_db_user` from `app.env`, into the `wordpress-db-dump`
volume — never the docroot — which `podman_backup`'s restic sweep then captures
alongside the raw datadir. The dump is engine-portable SQL;
`docs/disaster-recovery.md` covers loading it to recover from a broken upgrade.
Run `wp-db-dump` by hand to dump on demand.

An `ExecStopPost` hook on the service writes each run's outcome to
`wordpress_textfile_dir/wordpress-db-dump.prom` — `wordpress_db_dump_success`
(1/0, from systemd's `$SERVICE_RESULT`) and
`wordpress_db_dump_last_run_timestamp_seconds`. node_exporter scrapes that file (its
`node_exporter_textfile_directory` must match), and the `prometheus` role's
`WordpressDbDumpFailed` / `WordpressDbDumpOverdue` rules turn a failed or stale DR
dump into an alert — without it the wrapper's keep-the-last-good-dump-on-failure
behaviour hides a broken dump until the disaster it exists to cover.

## Update alerting

`wordpress-update-check.timer` runs `/usr/local/sbin/wp-update-check.sh` every six
hours: through the `wp` wrapper it counts the pending core, plugin, theme, and
translation updates — translations summed across the core, plugin, and theme
language scopes, matching wp-admin's Updates screen — and writes them to
`wordpress_textfile_dir/wordpress-updates.prom` as
`wordpress_updates_available{type="core|plugins|themes|translations"}`, alongside
`wordpress_update_check_success` (1/0) and
`wordpress_update_check_last_run_timestamp_seconds`. A failed check still publishes:
success flips to 0 and the last-good counts carry forward, so a transient wp-cli or
wordpress.org blip neither masks a pending update nor resets its alert window.
node_exporter scrapes the file (its `node_exporter_textfile_directory` must match),
and the `prometheus` role's `WordpressUpdateAvailable` rule alerts per type once an
update has been pending for a day — long enough for WordPress's own minor-core
auto-updates to clear first. `WordpressUpdateCheckFailed` /
`WordpressUpdateCheckOverdue` cover a check that errored or stopped running, so a
broken checker can't mask a real pending update. The role only reports updates;
apply them with `wp core update`, `wp plugin update` (and so on) or through wp-admin.

## Secrets

`wordpress_db_password` and `wordpress_db_root_password` are vault-sourced and
rendered into two `0600`, `no_log` files under `/etc/wordpress`: `db.env` carries
every `MARIADB_*` value (root password included) and is read only by the
`wordpress-db` quadlet, while `app.env` carries the `WORDPRESS_DB_*` creds the web
container, the `wp` cli, and the dump authenticate with.
Both are read via `EnvironmentFile=`/`--env-file`, so no password reaches a
world-readable unit file, and the split keeps `MARIADB_ROOT_PASSWORD` out of the
web container's environment — a webshell there can't read it. Left empty, the
stack stays uninitialised. MariaDB sets the passwords only on first init —
rotating one means an in-container `ALTER USER` or resetting the `wordpress-db`
volume.

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

An `ExecStopPost` hook on the service writes each run's outcome to
`wordpress_textfile_dir/wordpress-cron.prom` — `wordpress_cron_success` (1/0, from
systemd's `$SERVICE_RESULT`) and `wordpress_cron_last_run_timestamp_seconds`.
node_exporter scrapes that file (its `node_exporter_textfile_directory` must
match), and the `prometheus` role's `WordpressCronFailed` / `WordpressCronOverdue`
rules alert on a run that hard-failed or a timer that has stopped firing — so a
silently stalled cron surfaces instead of scheduled posts and tasks quietly
ceasing.

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
generator meta for the same reason, narrows the user-disclosure surface —
denying anonymous `/wp-json/wp/v2/users` enumeration and redirecting `?author=N`
and the `/author/<slug>/` archives home before they leak a login slug — and
neuters the XML-RPC pingback vector by stripping its methods and their
`X-Pingback` header (XML-RPC itself stays on for Jetpack). Point DNS for each
name at the host.

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

An apache drop-in (`files/uploads-no-exec.conf`, mounted into `conf-enabled/`)
sets `php_admin_flag engine off` and `AllowOverride None` on `wp-content/uploads`,
so a webshell uploaded into the writable docroot can't execute and no attacker
`.htaccess` can re-enable it. Enforced in apache, not the caddy edge, because an
attacker `.htaccess` `AddType` would slip a `.png` webshell past any edge rule.

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
