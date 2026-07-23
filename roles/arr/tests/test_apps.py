"""App reachability, account drop, capability posture, and healthchecks.

This file collects first (name sorts ahead of the beets suites), so the posture
assertions run before the beets sequences that mutate the music library. The
proxied-answer waits are defined first so they warm each app up before the
posture and healthcheck checks that follow.
"""

import pytest

from arrhelpers import ARR_GID, DOMAIN
from testlib import assert_posture, http_probe, wait_for

# roles/arr/vars/main.yml: apps with a port and no host network reach caddy on
# caddy.network, so the proxy answers for them at <app>.<DOMAIN>.
PROXIED = ["radarr", "sonarr", "lidarr", "prowlarr", "beets", "transmission"]

# roles/arr/vars/main.yml: portless apps (no proxy snippet) — assert the unit.
PORTLESS = ["flaresolverr", "recyclarr", "wireguard"]

# roles/arr/vars/main.yml: arr_apps[app].uid; the gid is arr_gid for apps in
# arr_media_access (the shared media group), else the app's own uid.
ACCOUNTS = {
    "radarr": (1038, ARR_GID),
    "sonarr": (1039, ARR_GID),
    "lidarr": (1037, ARR_GID),
    "prowlarr": (3004, 3004),
    "beets": (1040, ARR_GID),
    "plex": (3006, ARR_GID),
    "transmission": (1041, ARR_GID),
    "wireguard": (3009, 3009),
}

# The minimal capability set each app keeps over the template's DropCapability=all
# baseline. lscr.io images start as root and drop internally, so EffectiveCaps
# reflects the add-back; flaresolverr and recyclarr run as a non-root user whose
# EffectiveCaps are always empty regardless of the drop, so only BoundingCaps has
# teeth — assert whichever field is meaningful per app (matches the old verify).
POSTURE = {
    "radarr": ("EffectiveCaps", ["CAP_CHOWN", "CAP_KILL", "CAP_SETGID", "CAP_SETUID"]),
    "sonarr": ("EffectiveCaps", ["CAP_CHOWN", "CAP_KILL", "CAP_SETGID", "CAP_SETUID"]),
    "lidarr": ("EffectiveCaps", ["CAP_CHOWN", "CAP_KILL", "CAP_SETGID", "CAP_SETUID"]),
    "prowlarr": ("EffectiveCaps", ["CAP_CHOWN", "CAP_KILL", "CAP_SETGID", "CAP_SETUID"]),
    "transmission": (
        "EffectiveCaps",
        ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_KILL", "CAP_SETGID", "CAP_SETUID"],
    ),
    "beets": (
        "EffectiveCaps",
        ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_KILL", "CAP_SETGID", "CAP_SETUID"],
    ),
    "plex": (
        "EffectiveCaps",
        ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_KILL", "CAP_SETGID", "CAP_SETUID"],
    ),
    "wireguard": (
        "EffectiveCaps",
        ["CAP_CHOWN", "CAP_NET_ADMIN", "CAP_SETGID", "CAP_SETUID"],
    ),
    "flaresolverr": ("BoundingCaps", []),
    "recyclarr": ("BoundingCaps", []),
}

# roles/arr/vars/main.yml: apps carrying a healthcheck, minus wireguard (its
# blackhole tunnel is meant to fail, so its check is never run here).
HEALTHCHECK = ["radarr", "sonarr", "lidarr", "prowlarr", "flaresolverr", "transmission"]


@pytest.mark.parametrize("app", PROXIED)
def test_proxied_app_answers(host, app):
    def ready():
        code = http_probe(host, host_header=app + "." + DOMAIN).status
        return code if code in (200, 301, 302, 401) else None

    wait_for(ready, tries=30, delay=2, fail=app + " did not answer through the proxy")


# Plex uses host networking, so it is not on caddy.network and the proxy snippet
# skips it; prove it is up by hitting its host port directly.
def test_hostnet_plex_answers(host):
    def ready():
        return http_probe(host, path="/identity", port=32400).status == 200 or None

    wait_for(ready, tries=40, delay=3, fail="plex did not answer 200 on its host port")


@pytest.mark.parametrize("app", PORTLESS)
def test_portless_app_active(host, app):
    assert host.run("systemctl is-active " + app).stdout.strip() == "active"


# lscr.io images drop their service to PUID:PGID as the abc account.
@pytest.mark.parametrize("app,uid,gid", [(a, u, g) for a, (u, g) in ACCOUNTS.items()])
def test_app_account_drop(host, app, uid, gid):
    res = host.run("podman exec " + app + " sh -c 'id -u abc && id -g abc'")
    assert res.stdout.split() == [str(uid), str(gid)]


# recyclarr has no service account to read — quadlet User= sets its identity and
# exec inherits it, so a bare id reads what it actually runs as.
def test_recyclarr_account(host):
    res = host.run("podman exec recyclarr sh -c 'id -u && id -g'")
    assert res.stdout.split() == ["3007", "3007"]


@pytest.mark.parametrize("app", list(POSTURE))
def test_app_posture(host, app):
    field, caps = POSTURE[app]
    assert_posture(host, app, caps, field=field)


# The old verify derived its loops from arr_apps selectors, so a newly-added app
# entered every check automatically; these hardcoded lists need explicit drift
# guards instead. Derive the deployed set from the instance (its quadlet units,
# minus caddy's — the converge's caddy role, see converge.yml) and fail any list
# that falls out of sync with it.
@pytest.fixture(scope="module")
def deployed(host):
    out = host.run("ls /etc/containers/systemd").stdout
    apps = {f[: -len(".container")] for f in out.split() if f.endswith(".container")}
    apps.discard("caddy")
    return apps


def test_posture_covers_every_app(deployed):
    assert set(POSTURE) == deployed


def test_reachability_covers_every_app(deployed):
    assert set(PROXIED) | set(PORTLESS) | {"plex"} == deployed


def test_account_check_covers_every_lscr_app(host, deployed):
    out = host.run("grep -l '^Image=lscr.io/' /etc/containers/systemd/*.container").stdout
    lscr = {p.rsplit("/", 1)[1][: -len(".container")] for p in out.split()}
    assert set(ACCOUNTS) == lscr & deployed


def test_healthcheck_covers_every_checked_app(host, deployed):
    out = host.run("grep -l '^HealthCmd=' /etc/containers/systemd/*.container").stdout
    checked = {p.rsplit("/", 1)[1][: -len(".container")] for p in out.split()}
    checked &= deployed
    # wireguard is excluded from the run-them checks: its blackhole tunnel is
    # meant to fail (its HealthCmd presence is asserted in test_netns instead).
    checked.discard("wireguard")
    assert set(HEALTHCHECK) == checked


# HealthCmd is a full OCI exec; run it directly to prove the command resolves in
# the image and the endpoint answers, retrying like the verify's until/retries.
@pytest.mark.parametrize("app", HEALTHCHECK)
def test_app_healthcheck_passes(host, app):
    def ready():
        return host.run("podman healthcheck run " + app, timeout=60).returncode == 0 or None

    wait_for(ready, tries=12, delay=10, fail=app + " healthcheck did not pass")
