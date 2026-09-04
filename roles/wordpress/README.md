# wordpress

WordPress as rootful podman quadlets — the `wordpress` (Apache/PHP) container,
its `wordpress-db` mariadb database, and a `wordpress-valkey` object cache —
served at its own `wordpress_domains` via a caddy public site block. Core
and uploads persist in the `wordpress-html` volume, the database in
`wordpress-db`; each container self-heals via a healthcheck.

`wordpress_timezone` renders as `TZ=` into both env files. The site's own
timezone is a database option, so it moves log timestamps and mariadb's `NOW()`,
not the times the site displays.

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

## Critical CSS alerting

`wordpress-boost.timer` runs `/usr/local/sbin/wp-boost.sh` every six
hours — offset 20 minutes from the update check so the two `wp` containers don't
start on the same tick — reading Jetpack Boost's `critical_css_state`, its
`critical_css_suggest_regenerate` flag and the stored `jb_store_css` posts into
`wordpress_textfile_dir/wordpress-boost.prom` as `wordpress_boost_installed`,
`wordpress_boost_critical_css_generated`,
`wordpress_boost_critical_css_updated_timestamp_seconds`,
`wordpress_boost_critical_css_providers{status="success|error"}`,
`wordpress_boost_critical_css_stored_bytes` and
`wordpress_boost_critical_css_regenerate_suggested` — Boost's own regenerate
flag, set on a plugin toggle, theme switch or page save and cleared by a
regeneration — alongside the usual
`wordpress_boost_success` / `_last_run_timestamp_seconds` pair. A failed
check carries the last-good values forward, as the update check does.

Boost's free tier generates critical CSS in the browser, so nothing on the host
can regenerate it: the role reports, and `WordpressBoostCriticalCssMissing` /
`WordpressBoostCriticalCssStale` clear when the operator regenerates from the
Boost admin page. Both cover a state `status` alone hides — a plugin update
resets it while the previously stored CSS is still served, and it reads
`generated` even when individual providers failed. The error count is published
without a rule: a provider whose pages carry no external stylesheet fails every
run. The role does not manage the plugin, so `wordpress_boost_installed` is 0 on
a WordPress host without Boost and `WordpressBoostCriticalCssMissing` gates on
it; `WordpressBoostCriticalCssStale` gates on
`wordpress_boost_critical_css_generated` instead, so a never-generated install
raises one alert rather than two. `WordpressBoostCriticalCssRegenerateSuggested`
relays Boost's own regenerate flag once it has stood a week: the two rules
above can't see it, since the state stays `generated` and the timestamp recent,
and a page save alone sets it, so anything shorter would fire on every content
edit. `WordpressBoostFailed` /
`WordpressBoostOverdue` cover the check itself — the script always exits 0, so
the overdue rule is what catches a stopped timer or a deleted script.

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

`wordpress-valkey` runs valkey as a pure object cache — memory capped at
`wordpress_valkey_maxmemory` with LRU eviction, no volume, no persistence. The
role pre-wires `WP_REDIS_HOST`/`WP_REDIS_PORT`/`WP_REDIS_GRACEFUL` into wp-config,
so on a fresh install the only manual step is installing and enabling the Redis
Object Cache plugin (via `wp`, below, or wp-admin). Without graceful the drop-in
`wp_die()`s on an unreachable cache; with it wordpress only `Wants` the cache and
an outage costs speed, not the site.

Those constants only land on a fresh, role-generated config — a migrated install
keeps its own and the role never rewrites it. Set `WP_REDIS_GRACEFUL` there
(`wp config set WP_REDIS_GRACEFUL true --raw`) before repointing `WP_REDIS_HOST`.
`wp redis status` shows the connection; nothing alerts on a silent fallback.

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
`X-Pingback` header (XML-RPC itself stays on for Jetpack). It also pins Jetpack
Boost's concatenated CSS/JS to Boost's static cache: behind Cloudflare the
plugin's loopback 404 tester never reaches the origin, and every Boost update
deletes the option a hand fix left set, so without the
`jetpack_boost_minify_use_static_cache_urls` filter the bundles silently fall
back to PHP delivery at `/_jb_static/`. Point DNS for each name at the host.

`wordpress_origin_pull` adds Cloudflare's Authenticated Origin Pulls to the
block: `client_auth` in `require_and_verify` mode against the published origin
pull CA (`files/`, deployed to `/etc/caddy/cloudflare-origin-pull-ca.pem`,
expires 2029-11-01), so the origin refuses any handshake that did not come from
the edge. An origin firewall scoped to Cloudflare's ranges cannot do that —
every Cloudflare account shares them, so a leaked origin IP is enough to proxy
past the zone's WAF and rate limit. Caddy also enforces SNI/Host agreement once
client auth is configured. It needs `wordpress_tls` — asserted, because caddy
will not parse TLS policies on an `http://` site and an unparsable Caddyfile
crash-loops every site on the host — and the zone's `tls_client_auth` setting
live first: on here while the edge still sends no certificate takes the site
down, 520 on every request.

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
on `:80`); `wordpress-valkey` starts as the `valkey` user and keeps none. A
renovate image bump that needs a new capability surfaces as a failed healthcheck.

An apache drop-in (`files/uploads-no-exec.conf`, mounted into `conf-enabled/`)
sets `php_admin_flag engine off` and `AllowOverride None` on `wp-content/uploads`,
so a webshell uploaded into the writable docroot can't execute and no attacker
`.htaccess` can re-enable it. Enforced in apache, not the caddy edge, because an
attacker `.htaccess` `AddType` would slip a `.png` webshell past any edge rule.

## Deploy

Wire it after `podman` and `caddy`. Set `wordpress_domains` to the public names,
the DB passwords in the vault, and — for TLS (`wordpress_tls`, the default) —
caddy's `caddy_cloudflare_api_token` scoped to that zone; set
`wordpress_tls: false` for plain HTTP instead. Behind Cloudflare, turn the
zone's `tls_client_auth` setting on — not the similarly named per-hostname
`origin_tls_client_auth` enablement, which sends no certificate — and only then
set `wordpress_origin_pull`.

```yaml
roles:
  - common
  - sshd
  - firewalld
  - podman
  - caddy
  - wordpress
```
