"""Caddy edge security and enumeration hardening.

The edge checks run against the uninstalled instance; the enumeration and
pingback checks need a real author with a published post, so they install the
site -- collected last (this file sorts last, and the enumeration section is
defined last) so every check above sees the uninstalled instance.
"""

import pytest

from testlib import http_probe, wait_for
from wphelpers import DOMAIN

UPLOADS = "/wp-content/uploads/2026/07"

# Plant webshells across every vector the apache drop-in must cover -- a dropped
# .php, the evil.php/x.jpg PATH_INFO form, and an attacker .htaccess AddType on a
# .png -- plus a genuine media file. The marker 42*42 = 1764 must never return.
PLANT_CMD = (
    "podman exec wordpress sh -c '"
    "d=/var/www/html" + UPLOADS + "; "
    'mkdir -p "$d"; '
    'printf "<?php echo 42*42; ?>" > "$d/evil.php"; '
    'printf "AddType application/x-httpd-php .png\\n" > "$d/.htaccess"; '
    'printf "<?php echo 42*42; ?>" > "$d/shell.png"; '
    'printf "genuine-media" > "$d/photo.png"'
    "'"
)

WEBSHELLS = [UPLOADS + "/evil.php", UPLOADS + "/evil.php/x.jpg", UPLOADS + "/shell.png"]


# --- caddy edge, uninstalled instance ---


@pytest.fixture(scope="module")
def homepage(host):
    # caddy stamps the security headers on every response, so they ride the
    # install redirect too. molecule runs wordpress_tls:false, so no HSTS.
    def ready():
        r = http_probe(host, "/", host_header=DOMAIN)
        return (r.status, r.headers) if r.status in (200, 301, 302) else None

    return wait_for(ready, tries=60, delay=5, fail="wordpress did not answer through the proxy")


def test_security_headers(homepage):
    _, headers = homepage
    assert headers.get("x-content-type-options") == "nosniff"
    assert headers.get("referrer-policy") == "strict-origin-when-cross-origin"
    assert "camera=()" in headers.get("permissions-policy", "")


def test_php_banner_stripped(homepage):
    _, headers = homepage
    assert "x-powered-by" not in headers


@pytest.mark.parametrize("path", ["/readme.html", "/license.txt"])
def test_version_disclosure_blocked(host, path):
    assert http_probe(host, path, host_header=DOMAIN).status == 404


@pytest.fixture(scope="module")
def uploads_planted(host):
    host.run(PLANT_CMD)


@pytest.mark.parametrize("path", WEBSHELLS)
def test_webshell_not_executed(host, uploads_planted, path):
    r = http_probe(host, path, host_header=DOMAIN, body=True)
    assert r.status in (200, 403, 404)
    assert "1764" not in r.body


def test_legitimate_media_serves(host, uploads_planted):
    # Disabling PHP must not over-block: a genuine media file still serves.
    r = http_probe(host, UPLOADS + "/photo.png", host_header=DOMAIN, body=True)
    assert "genuine-media" in r.body


@pytest.fixture(scope="module")
def static_asset(host):
    def ready():
        r = http_probe(host, "/wp-includes/images/blank.gif", host_header=DOMAIN)
        return r.headers if r.status == 200 else None

    return wait_for(ready, tries=30, delay=5, fail="the static asset did not answer 200")


def test_static_cache_header(static_asset):
    cache_control = static_asset.get("cache-control", "")
    assert "immutable" in cache_control
    assert "31536000" in cache_control


def test_install_page_renders(host):
    # Proves the whole chain: caddy proxies, wordpress serves PHP, and it reached
    # the database -- a failed connection answers 500, not the install form.
    def ready():
        body = http_probe(host, "/wp-admin/install.php", host_header=DOMAIN, body=True).body
        return body if "WordPress" in body else None

    assert "WordPress" in wait_for(
        ready, tries=30, delay=5, fail="the install page did not render through the database"
    )


# --- enumeration and pingback hardening: installs the site, so this runs last ---


@pytest.fixture(scope="module")
def site_installed(host):
    # The enumeration checks need a real author with a published post -- a fresh
    # install's admin and sample post. Guarded, so a repeat verify skips it.
    # Pretty permalinks make ?author=N resolve to the /author/<slug>/ archive it
    # leaks on the live site.
    if host.run("/usr/local/bin/wp core is-installed").returncode != 0:
        host.run(
            "/usr/local/bin/wp core install "
            "--url=http://" + DOMAIN + " --title=molecule "
            "--admin_user=molecule_admin --admin_password=molecule-admin-pw "
            "--admin_email=admin@wordpress.home.arpa --skip-email",
            timeout=180,
        )
    host.run("/usr/local/bin/wp rewrite structure '/%postname%/' --hard", timeout=120)


def test_rest_denies_user_enumeration(host, site_installed):
    # A stock install answers this 200 with the admin's login slug; the mu-plugin
    # unsets the route so it 404s. The ?rest_route form dispatches through
    # index.php, so the 404 proves the unset, not a missing rewrite rule.
    assert http_probe(host, "/?rest_route=/wp/v2/users", host_header=DOMAIN).status == 404


@pytest.fixture(scope="module")
def author_probe(host, site_installed):
    r = http_probe(host, "/?author=1", host_header=DOMAIN)
    return r.status, r.headers


def test_author_probe_redirects(author_probe):
    status, _ = author_probe
    assert status in (301, 302)


def test_author_probe_hides_slug(author_probe):
    # Stock WordPress 301s ?author=1 to /author/<slug>/, disclosing the username;
    # the mu-plugin redirects home before that, so the location leaks no slug.
    _, headers = author_probe
    assert "/author/" not in headers.get("location", "")


@pytest.fixture(scope="module")
def sample_post(host, site_installed):
    def ready():
        r = http_probe(host, "/hello-world/", host_header=DOMAIN)
        return (r.status, r.headers) if r.status == 200 else None

    return wait_for(ready, tries=10, delay=3, fail="the sample post did not answer 200")


def test_sample_post_answers(sample_post):
    status, _ = sample_post
    assert status == 200


def test_pingback_stripped(sample_post):
    # Stock WordPress advertises the pingback endpoint via X-Pingback on singular
    # posts; the mu-plugin strips it so the vector is not advertised.
    _, headers = sample_post
    assert "x-pingback" not in headers
