"""Container runtime and hardening posture (asserts against the uninstalled
molecule instance -- the enumeration checks that install the site live in
test_web.py, which collects last)."""

import json
import time

import pytest

MU_PLUGIN = "/var/www/html/wp-content/mu-plugins/wordpress-hardening.php"

CONTAINERS = ["wordpress-redis", "wordpress-db", "wordpress"]

# The minimal add-back set each container's image needs; a regression that
# re-widens the caps or drops no-new-privileges must fail here. wordpress-redis
# keeps none (podman reports EffectiveCaps null -> []).
CAPS = {
    "wordpress-redis": [],
    "wordpress-db": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SETGID", "CAP_SETUID"],
    "wordpress": [
        "CAP_CHOWN",
        "CAP_DAC_OVERRIDE",
        "CAP_FOWNER",
        "CAP_NET_BIND_SERVICE",
        "CAP_SETGID",
        "CAP_SETUID",
    ],
}


@pytest.fixture(scope="module")
def config_extra(host):
    return host.run("podman exec wordpress printenv WORDPRESS_CONFIG_EXTRA").stdout


@pytest.mark.parametrize("unit", CONTAINERS)
def test_container_running(host, unit):
    assert host.run("systemctl is-active " + unit).stdout.strip() == "active"


# The split env files keep MARIADB_ROOT_PASSWORD out of the web container: it
# reaches only wordpress-db (db.env). printenv exits 0 when the variable is
# present, 1 when absent -- assert the exact code so a podman failure (125-127)
# fails rather than false-passing as "absent" while a reintroduced leak goes
# unseen.
@pytest.mark.parametrize("name,expected_rc", [("wordpress", 1), ("wordpress-db", 0)])
def test_mariadb_root_password_isolation(host, name, expected_rc):
    res = host.run("podman exec " + name + " printenv MARIADB_ROOT_PASSWORD")
    assert res.returncode == expected_rc


def test_redis_cache_answers(host):
    res = host.run("podman exec wordpress-redis redis-cli ping")
    assert res.stdout.strip() == "PONG"


def test_redis_host_wired(config_extra):
    assert "WP_REDIS_HOST" in config_extra
    assert "wordpress-redis" in config_extra


def test_wp_cron_disabled(config_extra):
    assert "DISABLE_WP_CRON" in config_extra


def test_wp_cli_reports_core_version(host):
    res = host.run("/usr/local/bin/wp core version", timeout=120)
    assert res.returncode == 0
    assert len(res.stdout.strip()) > 0


def test_mu_plugin_mounted(host):
    assert host.run("podman exec wordpress test -f " + MU_PLUGIN).returncode == 0


# The mu-plugin loads on every request, so a syntax error takes the whole site
# down; lint it inside the container.
def test_mu_plugin_valid_php(host):
    assert host.run("podman exec wordpress php -l " + MU_PLUGIN).returncode == 0


@pytest.mark.parametrize("name", CONTAINERS)
def test_container_capabilities(host, name):
    container = json.loads(host.run("podman inspect " + name).stdout)[0]
    effective = sorted(container.get("EffectiveCaps") or [])
    assert effective == sorted(CAPS[name])
    assert "no-new-privileges" in (container["HostConfig"].get("SecurityOpt") or [])


# HealthCmd is a full OCI exec; run it directly to prove each add-back set keeps
# the container healthy, retrying like the verify's until/retries.
@pytest.mark.parametrize("name", CONTAINERS)
def test_container_healthcheck(host, name):
    for _ in range(12):
        res = host.run("podman healthcheck run " + name, timeout=60)
        if res.returncode == 0:
            return
        time.sleep(10)
    assert res.returncode == 0
