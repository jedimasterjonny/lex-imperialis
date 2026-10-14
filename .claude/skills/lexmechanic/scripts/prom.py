#!/usr/bin/env python3
"""Read-only Prometheus reports for the lexmechanic sweep.

    prom.py --prom http://auspex:<port> [--since YYYY-MM-DD] REPORT

REPORT is one of: now alerts jobs reboots probes fs restarts. Prometheus keeps
UTC; everything here prints Europe/London, the clock the fleet, the schedule and
the operator all use. Range queries are chunked because the API refuses more
than 11,000 points per series. Output goes through unifi.py's scrub.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta

from unifi import DEFAULT_DAYS, LONDON, say, scrub, since

MAX_POINTS = 10_000
LIST_MOUNTS_UP_TO = 3
LIST_STARTS_UP_TO = 12
# Labels that identify nothing useful in a report, or that the public-repo habit
# keeps out of output (addresses, MACs, serials, controller URLs).
NOISY = {
    "__name__",
    "alertname",
    "alertstate",
    "job",
    "severity",
    "mac",
    "ip",
    "port_ip",
    "port_mac",
    "bssid",
    "serial",
    "source",
    "site_name",
}
TEXTFILE_SUCCESS = (
    '{__name__=~".+_success",__name__!~"probe_success|node_scrape_collector_success"}'
)
LOCAL_FS = (
    "node_filesystem_avail_bytes"
    '{fstype!~"tmpfs|ramfs|overlay|squashfs|vfat|efivarfs|fuse.*"}'
)


class Prom:
    def __init__(self, base: str) -> None:
        self.base = base.rstrip("/") + "/api/v1/"

    def get(self, path: str, params: dict | None = None) -> dict:
        url = (
            self.base + path + ("?" + urllib.parse.urlencode(params) if params else "")
        )
        try:
            with urllib.request.urlopen(url, timeout=300) as resp:  # noqa: S310 -- main() enforces http(s)
                return json.load(resp)["data"]
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")[:400]
            sys.exit(scrub(f"Prometheus HTTP {e.code} on {path}: {body}"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            sys.exit(scrub(f"Prometheus {path}: {type(e).__name__}: {e}"))

    def query(self, expr: str, at: float | None = None) -> list[dict]:
        params = {"query": expr} | ({"time": at} if at else {})
        return [r for r in self.get("query", params)["result"] if finite(r["value"])]

    def range(self, expr: str, start: float, end: float, step: int) -> list[dict]:
        """Run a range query in chunks small enough for the API's point cap."""
        merged: dict[str, dict] = {}
        while start < end:
            stop = min(end, start + step * MAX_POINTS)
            params = {"query": expr, "start": start, "end": stop, "step": step}
            for series in self.get("query_range", params)["result"]:
                key = json.dumps(series["metric"], sort_keys=True)
                entry = merged.setdefault(
                    key, {"metric": series["metric"], "values": []}
                )
                entry["values"] += filter(finite, series["values"])
            start = stop + step
        return list(merged.values())


def finite(sample: list) -> bool:
    # The API spells its only non-finite values these ways.
    return sample[1] not in {"NaN", "+Inf", "-Inf"}


def when(ts: float, fmt: str = "%m-%d %H:%M %Z") -> str:
    return datetime.fromtimestamp(float(ts), LONDON).strftime(fmt)


def prom_url(value: str) -> str:
    if not value.lower().startswith(("http://", "https://")):
        msg = f"{value!r} needs an http:// or https:// scheme"
        raise argparse.ArgumentTypeError(msg)
    return value


def labels(metric: dict) -> str:
    return " ".join(f"{k}={v}" for k, v in sorted(metric.items()) if k not in NOISY)


def clusters(items: list[tuple[float, str]], gap: float) -> list[list[tuple]]:
    """Group (time, label) pairs in time order, split at gaps over `gap` s."""
    groups: list[list[tuple]] = []
    for item in sorted(items):
        if groups and item[0] - groups[-1][-1][0] <= gap:
            groups[-1].append(item)
        else:
            groups.append([item])
    return groups


def episodes(times: list, gap: float) -> list[list[float]]:
    """Collapse sample times into [start, end] runs, split at gaps over `gap` s.

    >>> episodes([0, 60, 120, 600, 660], 120)
    [[0.0, 120.0], [600.0, 660.0]]
    """
    runs = clusters([(float(t), "") for t in times], gap)
    return [[run[0][0], run[-1][0]] for run in runs]


def report_now(p: Prom, _a: argparse.Namespace) -> None:
    alerts = p.get("alerts")["alerts"]
    live = [a for a in alerts if a["labels"]["alertname"] != "Watchdog"]
    for alert in live:
        lab = alert["labels"]
        active = when(datetime.fromisoformat(alert["activeAt"]).timestamp())
        say(alert["state"], lab["alertname"], labels(lab), "since", active)
    if not live:
        say("nothing active but Watchdog")


def report_alerts(p: Prom, a: argparse.Namespace) -> None:
    # Series that differ only in a NOISY label share a row, so merge their times.
    states: dict[tuple, dict] = defaultdict(dict)
    for series in p.range('ALERTS{alertname!="Watchdog"}', a.start, a.end, 60):
        m = series["metric"]
        times = states[m["alertname"], labels(m)].setdefault(m["alertstate"], [])
        times.extend(v[0] for v in series["values"])
    say("== fired (episodes, total minutes, first .. last)")
    for (name, lab), st in sorted(states.items()):
        if eps := episodes(st.get("firing", []), 120):
            total = sum(e - s + 60 for s, e in eps) / 60
            span = f"{when(eps[0][0])} .. {when(eps[-1][1])}"
            say(f"{name:32s} {lab}  n={len(eps)} {total:.0f}m  {span}")
    say("== pending only, never fired")
    for (name, lab), st in sorted(states.items()):
        if "firing" not in st and (eps := episodes(st.get("pending", []), 120)):
            span = f"{when(eps[0][0])} .. {when(eps[-1][1])}"
            say(f"{name:32s} {lab}  n={len(eps)}  {span}")


def report_jobs(p: Prom, a: argparse.Namespace) -> None:
    say("== textfile jobs now (value, hours since last run)")
    for r in p.query(TEXTFILE_SUCCESS):
        name, inst = r["metric"]["__name__"], r["metric"]["instance"]
        stem = name.removesuffix("_success")
        last = p.query(f'{stem}_last_run_timestamp_seconds{{instance="{inst}"}}')
        age = (
            f"{(time.time() - float(last[0]['value'][1])) / 3600:.1f}h"
            if last
            else "n/a"
        )
        say(f"{name:34s} {inst:18s} {r['value'][1]}  {age}")
    say("== episodes at 0 in the window")
    for series in p.range(TEXTFILE_SUCCESS + " == 0", a.start, a.end, 60):
        eps = episodes([v[0] for v in series["values"]], 120)
        runs = [f"{when(s)} +{(e - s) / 60 + 1:.0f}m" for s, e in eps]
        say(series["metric"]["__name__"], series["metric"]["instance"], runs)


def report_reboots(p: Prom, a: argparse.Namespace) -> None:
    uname = p.query("node_uname_info")
    kernels = {r["metric"]["instance"]: r["metric"]["release"] for r in uname}
    for series in p.range("node_boot_time_seconds", a.start, a.end, 60):
        inst = series["metric"]["instance"]
        boots = sorted({round(float(v[1])) for v in series["values"]})
        recent = [when(b, "%a %m-%d %H:%M %Z") for b in boots if b >= a.start]
        say(f"{inst:20s} {kernels.get(inst, '?'):28s} {recent}")


def report_probes(p: Prom, a: argparse.Namespace) -> None:
    starts = []
    say("== per target: minutes down, episodes")
    down = p.range("probe_success == 0", a.start, a.end, 60)
    for series in sorted(down, key=lambda s: s["metric"]["instance"]):
        inst = series["metric"]["instance"]
        eps = episodes([v[0] for v in series["values"]], 120)
        say(f"{inst[:64]:64s} down={len(series['values'])}m episodes={len(eps)}")
        starts += [(s, f"{inst}({(e - s) / 60 + 1:.0f}m)") for s, e in eps]
    say("== episode starts within 2 min of each other (many targets = shared cause)")
    for group in clusters(starts, 120):
        hits = [hit for _, hit in group]
        say(f"{when(group[0][0])}  {len(hits):2d}  {' '.join(hits)[:150]}")


def fs_key(m: dict) -> str | tuple:
    """Key a filesystem by device, or an NFS export by its path.

    A btrfs subvolume or MicroOS bind mount shares its host's device; an NFS
    export is one share whichever host mounts it, by whatever server name.
    """
    if m["fstype"].startswith("nfs"):
        return m["device"].split(":", 1)[1]
    return m["instance"], m["device"]


def by_fs(results: list[dict]) -> dict:
    return {fs_key(r["metric"]): float(r["value"][1]) for r in results}


def report_fs(p: Prom, a: argparse.Namespace) -> None:
    size = by_fs(p.query("node_filesystem_size_bytes"))
    before = by_fs(p.query(LOCAL_FS, a.start))
    groups = defaultdict(list)
    for r in p.query(LOCAL_FS):
        m = r["metric"]
        groups[fs_key(m)].append((m["instance"], m["mountpoint"], float(r["value"][1])))
    lines = []
    for fs, rows in groups.items():
        free, total, was = rows[0][2], size.get(fs), before.get(fs)
        mounts = sorted({row[1] for row in rows}, key=len)
        many = f"{mounts[0]} (+{len(mounts) - 1} more)"
        mount = " ".join(mounts) if len(mounts) <= LIST_MOUNTS_UP_TO else many
        label = fs if isinstance(fs, str) else mount
        delta = f"{(free - was) / 1e9:+.1f}G" if was is not None else "n/a"
        on = " ".join(sorted({row[0] for row in rows}))
        size_s = f"{total / 1e9:7.0f}G ({100 * free / total:4.1f}%)" if total else "n/a"
        line = f"{label:36s} {size_s} free={free / 1e9:8.1f}G change={delta:>8s}"
        lines.append((mounts[0], f"{line}  on {on}"))
    for _, line in sorted(lines):
        say(line)


def report_restarts(p: Prom, a: argparse.Namespace) -> None:
    # A restart is a new container, so a new cgroup id and a new series: one
    # max_over_time over the window holds every start a scrape saw.
    window = f"{max(1, round(a.end - a.start))}s"
    expr = f'max_over_time(container_start_time_seconds{{container!=""}}[{window}])'
    starts = defaultdict(set)
    for r in p.query(expr, a.end):
        m, t = r["metric"], round(float(r["value"][1]))
        if t >= a.start:
            starts[m["instance"].split(":")[0], m["container"]].add(t)
    for (host, name), ts in sorted(starts.items(), key=lambda kv: -len(kv[1])):
        times = sorted(ts)
        shown = ", ".join(when(t) for t in times[:LIST_STARTS_UP_TO])
        more = " ..." if len(times) > LIST_STARTS_UP_TO else ""
        say(f"{host:14s} {name[:30]:30s} {len(times):3d}  {shown}{more}")


REPORTS = {
    "now": report_now,
    "alerts": report_alerts,
    "jobs": report_jobs,
    "reboots": report_reboots,
    "probes": report_probes,
    "fs": report_fs,
    "restarts": report_restarts,
}


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--prom", required=True, type=prom_url, help="base URL")
    ap.add_argument("--since", type=since, help="window start, YYYY-MM-DD London")
    ap.add_argument("report", choices=REPORTS)
    a = ap.parse_args()
    a.end = time.time()
    a.start = (
        a.since or datetime.now(LONDON) - timedelta(days=DEFAULT_DAYS)
    ).timestamp()
    say(f"window: {when(a.start)} .. {when(a.end)}")
    REPORTS[a.report](Prom(a.prom), a)


if __name__ == "__main__":
    main()
