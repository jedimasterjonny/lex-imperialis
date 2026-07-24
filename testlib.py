"""Shared verify-harness primitives for the role pytest suites.

Three helpers the wordpress/caddy/arr suites all build on: an HTTP probe over the
target's loopback, a poll/retry loop, and a podman container-posture assertion.
Each suite keeps only its own role constants; everything they share lives here.
"""

from __future__ import annotations

import json
import time
from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:
    from collections.abc import Callable

    from conftest import Target


class HttpResult(NamedTuple):
    """A curl probe's outcome: status plus whichever of headers/body was read."""

    status: int
    headers: dict[str, str]
    body: str


def _parse_head(text: str) -> tuple[int, dict[str, str]]:
    """Parse a curl header dump into (status, {lowercased-name: value})."""
    lines = text.splitlines()
    parts = lines[0].split() if lines else []
    code = parts[1:2]
    status = int(code[0]) if code and code[0].isdigit() else 0
    headers = {}
    for line in lines[1:]:
        if not line.strip():
            break
        name, sep, value = line.partition(":")
        if sep:
            headers[name.strip().lower()] = value.strip()
    return status, headers


def http_probe(
    host: Target,
    path: str = "/",
    *,
    host_header: str | None = None,
    port: int | None = None,
    body: bool = False,
) -> HttpResult:
    """GET path on the target's loopback via curl, following no redirects.

    host_header and port set the request's Host header and destination port.
    Returns HttpResult(status, headers, body): with body=False the response
    headers are captured (body ""); with body=True the response body is captured
    (headers {}). The two modes mirror the old http_head/http_body split -- header
    mode discards the body (-o /dev/null) so a binary asset can't corrupt header
    parsing, body mode appends the status with -w and never reads headers.
    """
    hdr = "-H 'Host: " + host_header + "' " if host_header else ""
    netloc = "127.0.0.1" + (":" + str(port) if port else "")
    url = "'http://" + netloc + path + "'"
    if body:
        cmd = "curl -sS -w '\\n%{http_code}' " + hdr + url
        text, _, code = host.run(cmd).stdout.rpartition("\n")
        return HttpResult(int(code) if code.strip().isdigit() else 0, {}, text)
    cmd = "curl -sS -o /dev/null -D - " + hdr + url
    status, headers = _parse_head(host.run(cmd).stdout)
    return HttpResult(status, headers, "")


def wait_for[T](fn: Callable[[], T | None], tries: int, delay: int, fail: str) -> T:
    """Poll fn() until it returns non-None, mirroring the verify's until/retries/delay.

    Returns that value; raises AssertionError(fail) once tries run out.
    """
    for _ in range(tries):
        result = fn()
        if result is not None:
            return result
        time.sleep(delay)
    raise AssertionError(fail)


def assert_posture(host: Target, name: str, caps: list[str], field: str = "EffectiveCaps") -> None:
    """Assert container `name`'s hardening posture.

    `field` (EffectiveCaps or BoundingCaps) sorted equals `caps` sorted, and
    no-new-privileges is set.
    """
    container = json.loads(host.run("podman inspect " + name).stdout)[0]
    assert sorted(container.get(field) or []) == sorted(caps)
    assert "no-new-privileges" in (container["HostConfig"].get("SecurityOpt") or [])
