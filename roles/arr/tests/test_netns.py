"""Tunnel netns isolation, secret-file perms, and data-directory ownership.

None of these depend on a pristine music library, so it is safe that this file
sorts after the beets suites. The egress negative assertion is the point: a real
request from the confined client must die inside the dead-tunnel netns.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

from arrhelpers import ARR_GROUP, DATA_ROOT

if TYPE_CHECKING:
    from conftest import Target

# roles/arr/vars/main.yml: wireguard plus every enabled app that joins its netns.
NETNS_APPS = [
    "wireguard",
    "radarr",
    "sonarr",
    "lidarr",
    "prowlarr",
    "flaresolverr",
    "transmission",
]

# roles/arr/molecule/default/molecule.yml: arr_api_keys keys (the Servarr apps).
SERVARR = ["radarr", "sonarr", "lidarr", "prowlarr"]

# roles/arr/defaults/main.yml: arr_data_dirs -> owning app.
DATA_DIRS = [
    ("media/movies", "radarr"),
    ("media/tv", "sonarr"),
    ("media/music", "lidarr"),
    ("downloads", "transmission"),
]

# roles/arr/templates/recyclarr-{movies,tv}.yml.j2: the !secret key each config
# references.
RECYCLARR_CONFIGS = [("movies", "radarr"), ("tv", "sonarr")]

# curl's exit code for a --max-time abort: the dead tunnel swallows the packets.
CURL_TIMEOUT_EXIT = 28


@pytest.fixture(scope="module")
def wg_netns(host: Target) -> str:
    return host.run("podman exec wireguard readlink /proc/self/ns/net").stdout.strip()


# The proxy waits already prove each webui path skips the tunnel; here prove the
# shared namespace identity across wireguard and every app that joins it.
@pytest.mark.parametrize("app", NETNS_APPS)
def test_netns_shared(host: Target, wg_netns: str, app: str) -> None:
    ns = host.run("podman exec " + app + " readlink /proc/self/ns/net").stdout.strip()
    assert ns == wg_netns


def test_tunnel_default_route_via_wg0(host: Target) -> None:
    res = host.run("podman exec wireguard ip route get 1.1.1.1")
    assert "dev wg0" in res.stdout


# Route via wg0 is necessary but not sufficient — a real request from transmission
# (the confined client that must never leak) must die inside the netns: curl 28,
# wg0 swallowing the packets past the blackhole tunnel molecule converges with.
def test_egress_blocked_past_dead_tunnel(host: Target) -> None:
    res = host.run("podman exec transmission curl --max-time 5 -sS https://1.1.1.1", timeout=30)
    assert res.returncode == CURL_TIMEOUT_EXIT


def test_wireguard_carries_healthcheck(host: Target) -> None:
    cmd = "grep -q '^HealthCmd=' /etc/containers/systemd/wireguard.container"
    assert host.run(cmd).returncode == 0


# --- transmission RPC auth ---


# The creds render to a 0600 EnvironmentFile (USER/PASS turn auth on in the image).
def test_transmission_creds_file_private(host: Target) -> None:
    res = host.run("stat -c '%a %U' /etc/arr/transmission.env")
    assert res.stdout.strip() == "600 root"


def test_transmission_rpc_requires_auth(host: Target) -> None:
    cmd = (
        "podman exec transmission "
        "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9091/transmission/rpc/"
    )
    assert host.run(cmd).stdout.strip() == "401"


# --- Servarr API keys ---


# Each key is injected via a 0600 EnvironmentFile so it never lands in the
# world-readable unit; prove the file is locked down and the container gets the key.
@pytest.mark.parametrize("app", SERVARR)
def test_servarr_keyfile_private(host: Target, app: str) -> None:
    res = host.run("stat -c '%a %U' /etc/arr/" + app + ".env")
    assert res.stdout.strip() == "600 root"


@pytest.mark.parametrize("app", SERVARR)
def test_servarr_key_injected(host: Target, app: str) -> None:
    res = host.run("podman exec " + app + " printenv " + app.upper() + "__AUTH__APIKEY")
    assert len(res.stdout.strip()) > 0


# --- recyclarr config and secrets ---


# Config renders to the host and bind-mounts read-only into the container; cat from
# inside proves the bind resolves and the User=3007 process can read it.
@pytest.mark.parametrize(("name", "secret"), RECYCLARR_CONFIGS)
def test_recyclarr_config_references_secret(host: Target, name: str, secret: str) -> None:
    out = host.run("podman exec recyclarr sh -c 'cat /config/configs/" + name + ".yml'").stdout
    assert "!secret " + secret + "_api_key" in out


# test -r as the container user proves secrets.yml is readable without dumping keys.
def test_recyclarr_secrets_readable_in_container(host: Target) -> None:
    assert host.run("podman exec recyclarr sh -c 'test -r /config/secrets.yml'").returncode == 0


def test_recyclarr_secrets_file_private(host: Target) -> None:
    res = host.run("stat -c '%a %U' /etc/arr/recyclarr/secrets.yml")
    assert res.stdout.strip() == "600 recyclarr"


# --- media write permissions ---


# exec defaults to container root (bypasses file perms) — drop beets to the service
# account so the write exercises the shared group; plex is read-only media and cannot.
def test_media_write_permissions(host: Target) -> None:
    beets = host.run(
        "podman exec --user abc beets sh -c "
        "'touch /data/media/music/.probe && rm /data/media/music/.probe'"
    )
    plex = host.run("podman exec plex touch /movies/.probe")
    assert beets.returncode == 0
    assert plex.returncode != 0


# --- data directory ownership ---


@pytest.mark.parametrize(("subdir", "owner"), DATA_DIRS)
def test_data_dir_ownership(host: Target, subdir: str, owner: str) -> None:
    res = host.run("stat -c '%U %G %F' " + DATA_ROOT + "/" + subdir)
    assert res.stdout.strip() == owner + " " + ARR_GROUP + " directory"
