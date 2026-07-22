"""Shared constants and HTTP helpers for the wordpress verify suite.

The suite runs on the controller and cannot read the play's vars, so the
converge/defaults values it needs are duplicated here (kept in sync by hand).
HTTP is exercised with the instance's own curl against caddy on 127.0.0.1 with
the site's Host header, following no redirects -- the same edge path the old
`uri`-module verify drove.
"""

import time

# roles/wordpress/molecule/default/converge.yml: wordpress_domains[0]
DOMAIN = "wordpress.home.arpa"
# roles/wordpress/defaults/main.yml: wordpress_textfile_dir
TEXTFILE_DIR = "/var/lib/node_exporter/textfile_collector"
# roles/wordpress/defaults/main.yml: wordpress_db_name
DB_NAME = "wordpress"


def _parse_head(text):
    """Parse a curl header dump into (status, {lowercased-name: value})."""
    lines = text.splitlines()
    parts = lines[0].split() if lines else []
    status = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
    headers = {}
    for line in lines[1:]:
        if not line.strip():
            break
        name, sep, value = line.partition(":")
        if sep:
            headers[name.strip().lower()] = value.strip()
    return status, headers


def http_head(host, path, timeout=60):
    """GET path, follow no redirects; return (status, headers).

    Discards the body (-o /dev/null) so binary assets can't corrupt header
    parsing; -D - dumps the response headers to stdout.
    """
    cmd = (
        "curl -sS -o /dev/null -D - -H 'Host: " + DOMAIN + "' "
        "'http://127.0.0.1" + path + "'"
    )
    return _parse_head(host.run(cmd, timeout=timeout).stdout)


def http_body(host, path, timeout=60):
    """GET path, follow no redirects; return (status, body) for a text response.

    curl -w appends the status after the body in one request; split it back off.
    """
    cmd = (
        "curl -sS -w '\\n%{http_code}' -H 'Host: " + DOMAIN + "' "
        "'http://127.0.0.1" + path + "'"
    )
    body, _, code = host.run(cmd, timeout=timeout).stdout.rpartition("\n")
    return (int(code) if code.strip().isdigit() else 0), body


def wait_for(fn, tries, delay, fail):
    """Poll fn() until it returns non-None, mirroring the verify's until/retries/
    delay. Returns that value; raises AssertionError(fail) once tries run out."""
    for _ in range(tries):
        result = fn()
        if result is not None:
            return result
        time.sleep(delay)
    raise AssertionError(fail)
