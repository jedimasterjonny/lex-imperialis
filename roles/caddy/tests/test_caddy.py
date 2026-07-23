"""Caddy edge behaviour, the DNS-01 config branch, and container hardening.

Tests run in definition order: the health check gates the edge probes the way
the old verify's until/retries wait did.
"""

import base64
from pathlib import Path

import jinja2
import pytest

from testlib import assert_posture, http_probe, wait_for

# roles/caddy/defaults/main.yml: caddy_domain (molecule runs the default)
DOMAIN = "home.arpa"
# Shape matters: the cloudflare module format-checks the token (35-50 chars of
# [A-Za-z0-9_-]) at validate time and never calls the API, so a dummy is safe.
DUMMY_TOKEN = "molecule-dummy-token-molecule-dummy-token"
PROBE = "/etc/caddy/Caddyfile.dns01-probe"


def test_health_endpoint_answers(host):
    def ready():
        return http_probe(host, host_header="localhost").status == 204 or None

    wait_for(ready, tries=30, delay=2, fail="caddy health endpoint did not answer 204")


# No backend snippets are registered, so the wildcard vhost's catch-all handle
# answers 404 rather than Caddy's default empty 200.
def test_wildcard_404s_unregistered_subdomain(host):
    assert http_probe(host, host_header="probe." + DOMAIN).status == 404


# A foreign Host matches no site block; the http:// catch-all answers 404.
def test_foreign_host_404s(host):
    assert http_probe(host, host_header="nonexistent.example").status == 404


# Renovate bumps the image unattended; catch a build that drops the DNS-01
# plugin before it reaches the fleet.
def test_cloudflare_dns_module_compiled(host):
    res = host.run("podman exec caddy caddy list-modules")
    assert "dns.providers.cloudflare" in res.stdout


@pytest.fixture(scope="module")
def dns01_probe(host):
    # The token-set branch (global acme_dns + TLS wildcard vhost) never renders
    # in converge -- the token is empty -- so its syntax goes unproven. Render it
    # with a dummy token/domain and park it beside the live Caddyfile (the bind
    # mount makes it reachable in-container). Only truthiness fires the {% if %}
    # gate; the file itself references {env.*}. Serving it live would trigger a
    # real DNS-01 provision, so it is validated out-of-band. jinja is configured
    # to ansible's template defaults so the render matches what the role ships.
    src = (Path(__file__).parent.parent / "templates" / "Caddyfile.j2").read_text()
    env = jinja2.Environment(
        trim_blocks=True, keep_trailing_newline=True, undefined=jinja2.StrictUndefined
    )
    rendered = env.from_string(src).render(
        caddy_cloudflare_api_token=DUMMY_TOKEN,
        caddy_domain="molecule.example",
        caddy_wildcard=True,
    )
    b64 = base64.b64encode(rendered.encode()).decode()
    host.run("printf '%s' " + b64 + " | base64 -d > " + PROBE)


def test_dns01_branch_renders_acme_dns(host, dns01_probe):
    assert "acme_dns cloudflare" in host.run("cat " + PROBE).stdout


def test_dns01_caddyfile_valid(host, dns01_probe):
    res = host.run(
        "podman exec --env CLOUDFLARE_API_TOKEN=" + DUMMY_TOKEN + " caddy "
        "caddy validate --adapter caddyfile --config " + PROBE
    )
    assert res.returncode == 0


# A non-zero exit proves curl resolves in the image or the 204 endpoint broke.
def test_healthcheck_passes(host):
    assert host.run("podman healthcheck run caddy", timeout=60).returncode == 0


# The checks above prove the add-back set is sufficient; assert the posture
# directly so a regression that widens it fails here, not in production.
def test_caddy_capabilities(host):
    assert_posture(host, "caddy", ["CAP_NET_BIND_SERVICE"])
