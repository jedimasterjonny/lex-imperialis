#!/usr/bin/env python3
"""Read-only UniFi Network reports for the lexmechanic sweep.

    unifi.py health
    unifi.py events [--since YYYY-MM-DD]
    unifi.py ping

Authenticates with the unpoller key. The URL and key come out of the vault via
bin/vault-var.sh, which needs .venv and .vault_pass in the checkout holding this
script, and stay in this process's memory: nothing is written to disk and the
key is never printed or sent anywhere a redirect points. Every printed line is
scrubbed of MACs, WireGuard keys, and public, link-local and MAC-derived
addresses; prom.py imports the same scrub. system-log/all is the only event
history the API keeps, and the only call that sends a body; the per-category
system-log endpoints, stat/event and stat/alarm all 404.
"""

import argparse
import ipaddress
import json
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

LONDON = ZoneInfo("Europe/London")
REPO = Path(__file__).resolve().parents[4]
DOTTED = r"(?:\d{1,3}\.){3}\d{1,3}(?!\d|\.\d)"
IPV4 = re.compile(rf"(?<![\d.]){DOTTED}")
# Hex-and-colon lookarounds. The last group may be empty only after "::", and a
# colon may follow when nothing hex does ("2a00::1: refused", "::ffff:1.1.1.1:443").
IPV6 = re.compile(
    rf"(?<![0-9a-f:])(?:[0-9a-f]{{0,4}}:){{2,7}}(?:{DOTTED}"
    r"|[0-9a-f]{1,4}(?![0-9a-f]|:[0-9a-f:])|(?<=::)(?![0-9a-f:]))",
    re.IGNORECASE,
)
# No colon in the lookbehind, so "mac:aa:…" still starts at "aa"; the lookahead
# stops a match ending one group short ("ac:aa:bb:cc:dd:ee" of "mac:aa:…:ff").
MAC = re.compile(
    r"(?<![0-9a-f])(?:[0-9a-f]{2}([:-])(?:[0-9a-f]{2}\1){4}[0-9a-f]{2}"
    r"|[0-9a-f]{4}\.[0-9a-f]{4}\.[0-9a-f]{4}|[0-9a-f]{12})(?![:.-]?[0-9a-f])",
    re.IGNORECASE,
)
WG_KEY = re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=")
GIGABIT = 1000
PAGE = 1000
DEFAULT_DAYS = 21
SYSTEM_LOG = "/proxy/network/v2/api/site/default/system-log/all"
HANG_HINT = "`unifi.py ping` tells a hung Network app from a console fault"


def address(match: re.Match) -> str:
    try:
        ip = ipaddress.ip_address(match[0])
    except ValueError:
        return match[0]
    if isinstance(ip, ipaddress.IPv6Address):
        # IPv4-mapped, 6to4 and Teredo addresses embed an IPv4 one; an EUI-64
        # interface ID (ff:fe in its middle) embeds the MAC.
        v4 = ip.ipv4_mapped or ip.sixtofour or (ip.teredo or (None, None))[1]
        if v4:
            return "<addr>" if v4.is_private else "PUBLIC"
        if ip.is_private and ip.packed[11:13] == b"\xff\xfe":
            return "<addr>"
    if not ip.is_private:
        return "PUBLIC"
    return "<addr>" if ip.is_link_local else match[0]


def scrub(text: str) -> str:
    """Mask MACs, WireGuard keys, and public, link-local or MAC-derived addresses.

    >>> scrub("aa-bb-cc-dd-ee-ff, aabb.ccdd.eeff, mac_aabbccddeeff_x")
    '<mac>, <mac>, mac_<mac>_x'
    >>> scrub("to 1.1.1.1. from 192.0.2.1, fe80::1, fw 7.1.66.15869")
    'to PUBLIC. from 192.0.2.1, <addr>, fw 7.1.66.15869'
    >>> scrub("::ffff:192.0.2.1 fd00::1 fd00::200:ff:fe00:1")
    '<addr> fd00::1 <addr>'
    >>> scrub("::ffff:1.1.1.1:443, 2a00::1: refused")
    'PUBLIC:443, PUBLIC: refused'
    >>> scrub("ip6_2a00:1::1 src_mac:aa:bb:cc:dd:ee:ff")
    'ip6_PUBLIC src_mac:<mac>'
    >>> scrub("via:2a00:1::1")  # a hex-ending word is masked with the address
    'viPUBLIC'
    >>> scrub("6to4 2002:101:101::1 teredo 2001:0:4136:e378:8000:63bf:3fff:fdd2")
    '6to4 PUBLIC teredo <addr>'
    >>> scrub("peer " + "k" * 43 + "=")
    'peer <key>'
    """
    for pattern in (IPV6, IPV4):
        text = pattern.sub(address, text)
    return WG_KEY.sub("<key>", MAC.sub("<mac>", text))


def say(*parts: object) -> None:
    print(scrub(" ".join(map(str, parts))))


def ver(value: object) -> str:
    """Pass a dotted version through, which scrub() would read as an address.

    >>> ver("4.0.21.123"), ver("aa:bb:cc:dd:ee:ff")
    ('4.0.21.123', '<mac>')
    """
    text = str(value)
    return text if re.fullmatch(r"[\d.]+", text) else scrub(text)


def since(value: str) -> datetime:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        msg = f"{value!r} is not YYYY-MM-DD"
        raise argparse.ArgumentTypeError(msg)
    try:
        day = datetime.strptime(value, "%Y-%m-%d").replace(tzinfo=LONDON)
    except ValueError as e:
        raise argparse.ArgumentTypeError(str(e)) from e
    if day > datetime.now(LONDON):
        msg = f"{value} is in the future"
        raise argparse.ArgumentTypeError(msg)
    return day


def vault(name: str) -> str:
    for need in (".venv", ".vault_pass"):
        if not (REPO / need).exists():
            sys.exit(f"no {need} in {REPO}: symlink the main checkout's into it")
    # vault-var.sh dies with "Ansible requires blocking IO" unless stdin is
    # closed and stderr is not the caller's terminal.
    out = subprocess.run(  # noqa: S603 -- fixed argv, no shell
        [REPO / "bin/vault-var.sh", name],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode:
        # Only the error lines: a YAML traceback can quote a vault line.
        errors = [
            line
            for line in out.stderr.splitlines()
            if line.startswith(("[ERROR]", "vault-var.sh:"))
        ]
        sys.exit(f"vault-var.sh {name} failed: {' '.join(errors) or 'no [ERROR]'}")
    return out.stdout.strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_: object) -> None:
        """Refuse, so urllib raises the 3xx and the key never follows it."""


class UniFi:
    def __init__(self) -> None:
        self.url = vault("unpoller_url").rstrip("/")
        self.key = vault("unpoller_api_key")
        if not self.url.startswith("https://"):
            sys.exit("unpoller_url is not https://")
        if not self.key.isprintable():
            sys.exit("unpoller_api_key is not printable")
        # The console's certificate is self-signed.
        ctx = ssl._create_unverified_context()  # noqa: S323, SLF001
        self.opener = urllib.request.build_opener(
            NoRedirect, urllib.request.HTTPSHandler(context=ctx)
        )

    def call(self, path: str, body: dict | None = None, timeout: int = 120) -> dict:
        if body is not None and not path.startswith(SYSTEM_LOG):
            msg = f"refusing to send a body to {path}: only system-log reads take one"
            raise ValueError(msg)
        req = urllib.request.Request(  # noqa: S310 -- https enforced in __init__
            self.url + path,
            data=None if body is None else json.dumps(body).encode(),
            headers={
                "X-API-Key": self.key,
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        with self.opener.open(req, timeout=timeout) as resp:
            return json.load(resp)

    def stat(self, what: str) -> list[dict]:
        return self.call(f"/proxy/network/api/s/default/stat/{what}")["data"]


def when(ms: float) -> str:
    return datetime.fromtimestamp(ms / 1000, LONDON).strftime("%m-%d %H:%M %Z")


def print_ports(device: dict, on_port: dict) -> None:
    """Print the device's up ports that carry errors or link below gigabit."""
    counters = ("rx_errors", "tx_errors", "rx_dropped", "tx_dropped")
    for port in device.get("port_table", []):
        if not port.get("up"):
            continue
        errs = {k: port[k] for k in counters if port.get(k)}
        full = port.get("full_duplex", True)
        if errs or port.get("speed", GIGABIT) < GIGABIT or not full:
            client = on_port.get((device["mac"], port.get("port_idx")), "")
            link = f"{port.get('speed')}M{'' if full else ' HALF'}"
            boot = " since device boot" if errs else ""
            say(f"   p{port.get('port_idx')} {link} {client:24s} {errs}{boot}")


def client_name(c: dict) -> str:
    return c.get("name") or c.get("hostname") or "unnamed"


def report_health(u: UniFi, _a: argparse.Namespace) -> None:
    s = u.stat("sysinfo")[0]
    print(
        f"Network {ver(s.get('version'))} on console "
        f"{ver(s.get('console_display_version'))},",
        scrub(
            f"app up {s.get('uptime', 0) / 3600:.1f}h, "
            f"update_available={s.get('update_available')}"
        ),
    )
    keys = ("latency", "drops", "num_user", "num_disconnected")
    for h in u.stat("health"):
        detail = {k: h[k] for k in keys if k in h}
        say(f"  {h['subsystem']:5s} {h.get('status')} {detail}")
    clients = u.stat("sta")
    wired = [c for c in clients if c.get("is_wired")]
    on_port = {(c.get("sw_mac"), c.get("sw_port")): client_name(c) for c in wired}
    for d in u.stat("device"):
        ss = d.get("sys_stats", {})
        total = ss.get("mem_total")
        mem = f"{round(100 * ss['mem_used'] / total)}%" if total else "n/a"
        temps = [round(t["value"], 1) for t in d.get("temperatures", [])]
        print(
            scrub(f"== {d['name']}"),
            f"fw={ver(d.get('version'))}",
            scrub(
                f"upgradable={d.get('upgradable')} "
                f"up={d.get('uptime', 0) / 86400:.0f}d "
                f"load15={ss.get('loadavg_15')} mem={mem} "
                f"temp={temps or d.get('general_temperature')}"
            ),
        )
        print_ports(d, on_port)
    say(f"clients: {len(wired)} wired, {len(clients) - len(wired)} wireless")


def timed_out(e: BaseException | None) -> bool:
    return isinstance(e, TimeoutError) or isinstance(
        getattr(e, "reason", None), TimeoutError
    )


def probe(u: UniFi, path: str) -> BaseException | None:
    t0 = time.monotonic()
    try:
        u.call(path, timeout=10)
    except (OSError, ValueError) as e:
        say(f"{path:24s} {time.monotonic() - t0:5.1f}s FAILED {type(e).__name__}: {e}")
        return e
    say(f"{path:24s} {time.monotonic() - t0:5.1f}s answered")
    return None


def report_ping(u: UniFi, _a: argparse.Namespace) -> None:
    console = probe(u, "/api/system")
    app = probe(u, "/proxy/network/status")
    if console is None and timed_out(app):
        say("Network app hang: the console answers and the app times out")


def namer(clients: list[dict], wan_ip: str | None) -> Callable[[dict | None], str]:
    """Name an endpoint: the gateway's own WAN, a client, LAN, or its scrubbed value."""
    by_ip, lan64 = {}, set()
    for c in clients:
        for ip in [c.get("ip"), *c.get("ipv6_addresses", [])]:
            if ip:
                by_ip[ip] = client_name(c)
                if ":" in ip:
                    lan64.add(ipaddress.ip_network(f"{ip}/64", strict=False))

    def name(param: dict | None) -> str:
        value = str((param or {}).get("name"))
        if value == wan_ip:
            return "own WAN"
        if value in by_ip:
            return scrub(by_ip[value])
        # A client's global IPv6 /64 is the LAN's, whichever address it uses now.
        try:
            if ipaddress.ip_network(f"{value}/64", strict=False) in lan64:
                return "LAN"
        except ValueError:
            pass
        return scrub(value)

    return name


def fetch_events(u: UniFi, since_ms: int, until_ms: int) -> list[dict]:
    rows: dict[str, dict] = {}
    page = 0
    while True:
        body = {
            "timestampFrom": since_ms,
            "timestampTo": until_ms,
            "pageNumber": page,
            "pageSize": PAGE,
        }
        resp = u.call(f"{SYSTEM_LOG}?page_number={page}&page_size={PAGE}", body)
        data = resp.get("data", [])
        rows.update((r["id"], r) for r in data)
        pages, total = resp.get("total_page_count"), resp.get("total_element_count")
        page += 1
        if not data or pages is None or page >= pages:
            break
    if pages is None:
        say("WARNING: no total_page_count, so only the first page was read")
    if len(rows) != total:
        say(f"WARNING: read {len(rows)} distinct events, the API counts {total}")
    return sorted(rows.values(), key=lambda r: r["timestamp"])


def print_security(rows: list[dict], name: Callable[[dict | None], str]) -> None:
    seen = Counter()
    for r in rows:
        if not r["key"].startswith("THREAT"):
            continue
        p = r["parameters"]
        src = name(p.get("SRC_CLIENT") or p.get("SRC_IP"))
        dst = name(p.get("DST_CLIENT") or p.get("DST_IP"))
        seen[src, dst, r["severity"]] += 1
        if "PUBLIC" not in (src, dst):
            say(
                f"  internal security event {when(r['timestamp'])} {src} -> {dst} "
                f"({r['severity']}): have the operator open it in the console"
            )
    say("== security events by endpoint")
    for (src, dst, sev), n in seen.most_common(15):
        say(f"  {n:4d} {src} -> {dst} {sev}")


def report_events(u: UniFi, a: argparse.Namespace) -> None:
    start, end = int(a.start * 1000), int(a.end * 1000)
    say(f"window: {when(start)} .. {when(end)}")
    rows = fetch_events(u, start, end)
    wan_ip = next(
        (h.get("wan_ip") for h in u.stat("health") if h["subsystem"] == "wan"), None
    )
    name = namer(u.stat("sta"), wan_ip)
    say(f"{len(rows)} events")
    for (cat, key), n in Counter((r["category"], r["key"]) for r in rows).most_common():
        say(f"  {n:5d} {cat:16s} {key}")
    days = Counter(when(r["timestamp"])[:5] for r in rows)
    say("== per day:", " ".join(f"{d}:{n}" for d, n in days.items()))
    print_security(rows, name)
    for category in ("VPN", "UNIFI_DEVICES", "AUDIT"):
        hits = Counter()
        for r in rows:
            if r["category"] == category:
                p = r["parameters"]
                # Every admin is the same API user, so AUDIT names where it came from.
                where = p.get("IP") if category == "AUDIT" else None
                who = name(where or p.get("CLIENT") or p.get("DEVICE"))
                if where:
                    who += f" via {(p.get('PLATFORM') or {}).get('name')}"
                hits[r["key"], who] += 1
        summary = ", ".join(f"{k} {who} x{n}" for (k, who), n in hits.most_common(10))
        say(f"== {category}:", summary or "none")
    wired = Counter(
        name(r["parameters"].get("CLIENT"))
        for r in rows
        if r["key"] == "CLIENT_DISCONNECTED_WIRED_2"
    )
    say("== wired disconnects:", dict(wired.most_common(8)))


REPORTS = {"health": report_health, "events": report_events, "ping": report_ping}


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--since", type=since, help="window start, YYYY-MM-DD London")
    ap.add_argument("report", choices=REPORTS)
    a = ap.parse_args()
    a.end = time.time()
    a.start = (
        a.since or datetime.now(LONDON) - timedelta(days=DEFAULT_DAYS)
    ).timestamp()
    try:
        REPORTS[a.report](UniFi(), a)
    except (TimeoutError, urllib.error.URLError) as e:
        sys.exit(scrub(f"{e} ({HANG_HINT})"))


if __name__ == "__main__":
    main()
