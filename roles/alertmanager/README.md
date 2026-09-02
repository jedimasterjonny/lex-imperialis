# alertmanager

[Alertmanager](https://github.com/prometheus/alertmanager) as a Podman quadlet on
the host network, serving `:9093`. Prometheus sits beside it on the same host and
both routes alerts here and scrapes it, from the one
`prometheus_alertmanager_targets` list — one Alertmanager at one address, so it
carries one `instance` label. Opening the port is the playbook's job, not the
role's.

## Config

`alertmanager.yml` is Ansible-rendered to `/etc/alertmanager` and bind-mounted
read-only with `:Z`, so podman relabels it `container_file_t` on each start and
the container reads it regardless of the host's ambient SELinux label. Every
alert routes to the `default` receiver; the always-firing `Watchdog` takes two
dedicated routes — a `continue: true` leg to `default` that periodically
exercises the Discord webhook (cadence and rationale live with the route), then
on to the `deadman` receiver:

- With `alertmanager_discord_webhook_url` set, the `default` receiver posts to the
  `proclamator` webhook via a `discord_configs` entry whose `webhook_url_file`
  points at a 0600 file holding the URL — the secret stays out of the
  world-readable config.
- With `alertmanager_deadman_ping_url` set, the `deadman` receiver carries a
  `webhook_configs` entry whose `url_file` points at a 0600 file holding the
  hc-ping URL; every beat POSTs to it (`send_resolved` off, or a resolved POST
  would read as a healthy beat and mask an outage). The deadman route inherits
  the parent's 5m `group_interval` — the beat, as Alertmanager never repeats a
  group faster than that — and overrides only `repeat_interval` to `4m` so every
  flush re-sends. The healthchecks.io check must track this cadence: period 5m,
  grace 10m. Retune both halves together or the check flaps — and the grace must
  also absorb the inhibition's mute of a short healed Discord blip.
- Empty (the default), the matching receiver is null: its route fires nothing.
  This keeps molecule self-contained, so set the URLs on the real host.

Both files are written whatever their variable holds, so clearing one in the
vault empties it on the next apply — the revoked URL leaves the host instead of
sitting superseded but readable — and the config, which references a file only
while its variable is set, is left pointing at nothing.

The image's default command already targets `/etc/alertmanager/alertmanager.yml`
and `/alertmanager`, so the unit overrides no `Exec`. State (silences, the
notification log) lives in the `alertmanager-data` named volume, handed to the
image's `nobody` user (65534) with `:U`.

The container's podman healthcheck against `/-/healthy` is the restart backstop, not
the monitor (see `roles/CLAUDE.md`). Alertmanager needs no blackbox probe: Prometheus
already scrapes it, so `InstanceDown` covers it, and a total outage trips the
Watchdog deadman — an alert routed through Alertmanager cannot report Alertmanager.
That same scrape feeds `AlertmanagerNotificationsFailing` (prometheus role), which
watches Discord delivery in particular — and cannot page over the channel that is
failing, so an `inhibit_rules` entry suppresses the `Watchdog` while it fires,
and the deadman reports the failure out-of-band (why with the inhibit block;
mechanics and windows with the rule).

A second `inhibit_rules` entry collapses an uplink outage to one page: while
`HomeUplinkDown` fires, `ProbeDown` and `WireguardTunnelDown` are suppressed,
since a LAN with no internet is the single cause behind every one of them.
`InstanceDown` is left alone — the host really is unreachable, and it is the one
alert still naming a host. The cost is that a LAN-side `ProbeDown` is muted for
the outage's duration and pages once it ends.

## Hardening

The container runs `NoNewPrivileges` and drops every capability. The image runs
non-root as `nobody` (65534) on an unprivileged port, so it adds none back.

## Variables

- `alertmanager_discord_webhook_url` — Discord incoming-webhook URL, vault-sourced,
  rendered `no_log` into `/etc/alertmanager/discord_webhook_url`. Empty leaves a
  null receiver.
- `alertmanager_deadman_ping_url` — healthchecks.io hc-ping heartbeat URL the
  `Watchdog` alert pings, vault-sourced, rendered `no_log` into
  `/etc/alertmanager/deadman_url`. A bearer token: anyone with it can spoof the
  beat and silence the alarm. Empty leaves the `deadman` receiver null.

The image (`alertmanager_image`) is pinned by digest; renovate bumps it.
