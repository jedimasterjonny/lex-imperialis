# prometheus_agent

Prometheus in **agent mode** as a Podman quadlet on the host network: it scrapes,
and forwards every sample by `remote_write` to a Prometheus elsewhere. It keeps
no TSDB, answers no queries, and evaluates no rules.

## What it deliberately does not do

Agent mode rejects `alerting` and `rule_files` **by name at startup** — *"field
alerting is not allowed in agent mode"*. So neither is a degradation here, each is
a container that will not boot. Alert routing and rule evaluation stay with the
Prometheus holding the TSDB this writes into, which is also where the retention
those rules need lives: `MicroOSBuildStale` reads a fortnight back, and this agent
holds four hours.

The split is therefore inherent, not a preference. Scraping and notification sit
on this host; storage and evaluation sit on the receiver.

## The receiver's side

`prometheus_agent_remote_write_url` points at a Prometheus started with
`--web.enable-remote-write-receiver` (the `prometheus` role's
`prometheus_remote_write_receiver`). That receiver should also set
`prometheus_out_of_order_time_window` to at least this agent's WAL retention
(`--storage.agent.retention.max-time`, 4h by default). Without it the buffer is
notional: the agent holds samples while the receiver is unreachable, but the
receiver's own head keeps advancing and compacting every 2h, so on reconnect
anything older than its last persisted block is rejected as out of bounds and
dropped with no error either end reports. Size the two together.

## No external labels

None are set, and none should be. Any `external_labels` entry joins every series
and severs continuity with the history already stored under the old label set,
leaving two disjoint halves either side of a cutover. The `job` and `instance`
labels this produces are byte-identical to those of a Prometheus scraping the
same targets directly, so moving scraping onto an agent is invisible in the data.

## A dead agent is silence

If the agent stops, samples stop arriving and almost every rule on the receiver
matches an *empty vector* rather than firing: `== 0` and `time() - <gauge> > N`
both match nothing on an empty vector. The receiver therefore needs an
`absent()`-based rule on this agent's self-scrape; a rule on
`prometheus_remote_storage_samples_failed_total` catches only *partial* failure,
since under total failure the counter never arrives either.

## Variables

- `prometheus_agent_remote_write_url` — the `/api/v1/write` endpoint samples go
  to. No default and asserted non-empty: agent mode refuses to start without at
  least one `remote_write`, so an unset value is a crash-looping container.
- `prometheus_agent_listen_address` — the agent's own web bind, loopback by
  default. It serves no query API worth exposing, and its only scraper is itself.
  Its self-scrape therefore lands as `instance="127.0.0.1:9090"`; exposing 9090 on
  the LAN for a prettier label would be a worse trade.
- `prometheus_agent_retention_max_time` — how long the WAL buffers samples the
  receiver has not taken (`--storage.agent.retention.max-time`), 4h. Set rather
  than inherited, because it is half of a pair: the receiver's
  `prometheus_out_of_order_time_window` must be at least this, or a backlog
  replayed after an outage is refused as out of bounds and dropped with no error
  at either end. A digest bump could move an unpinned default out from under that
  agreement silently. Change one, change the other.
- `prometheus_agent_node_targets` — `host:9100` scrape targets.
- `prometheus_agent_cadvisor_targets` — `host:8080` targets, scraped at 30s to
  match cadvisor's housekeeping interval, and the one job with
  `honor_timestamps: false`. Container series get `container` and
  `image` rebuilt from the cgroup id for the Grafana docker dashboard.

  cadvisor exports an explicit timestamp per sample and advances it only for a
  cgroup that saw activity, so an idle container re-serves the identical sample —
  same value, same millisecond — every scrape. Honoured, those repeats are
  rejected as out-of-order and the series gains no point: measured here at 37% of
  cadvisor's timestamped series and ~130 samples/s across three targets, with
  `prometheus_target_scrapes_sample_out_of_order_total` climbing steadily.
  Stamping at scrape time drops that to zero. The cost is the sub-scrape-interval
  precision of cadvisor's own clock, which nothing on this fleet reads.
- `prometheus_agent_alertmanager_targets` — `host:9093` targets, **scraped only**.
  An agent routes nothing; the scrape is what yields `up{job="alertmanager"}` and
  the notification counters `AlertmanagerNotificationsFailing` reads.
- `prometheus_agent_probe_targets` — blackbox probe targets, each entry pairing a
  prober `module` with the `targets` to run it against.
- `prometheus_agent_blackbox_address` — the co-located `blackbox_exporter`'s
  loopback bind, which must match that role's `blackbox_exporter_listen_address`.

The image (`prometheus_agent_image`) is pinned by digest; renovate bumps it. It is
the same image as `roles/prometheus` — agent mode is a flag, not a build — pinned
separately because renovate keys on each role's own `vars/main.yml`.

## Self-scrape job name

`job_name: prometheus_agent`, not `prometheus`. The receiving server self-scrapes
under `job="prometheus"` at `instance="localhost:9090"`, and this agent binds the
same address; sharing the name merges two processes into one series and leaves
`PrometheusRuleEvaluationFailing` reading a blend of both.

## Testing

The incus scenario proves agent mode at runtime rather than trusting the flag:
agent mode publishes the `prometheus_agent_*` metric family and keeps **no** TSDB
head, so `verify` asserts both — a server-mode process that started because `Exec=`
lost `--agent` fails the second assertion even if it somehow passed the first. It
also asserts the config carries neither block agent mode refuses, that every job
registers, that the blackbox module survives as `__param_module`, the container's
security posture, and that the quadlet's `Image` still carries a digest.

Note the tier: only x86_64 is exercised, and the host this runs on is aarch64.
