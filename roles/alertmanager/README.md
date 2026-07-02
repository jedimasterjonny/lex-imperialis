# alertmanager

[Alertmanager](https://github.com/prometheus/alertmanager) as a Podman quadlet on
the host network, serving `:9093`. Prometheus on the NAS pushes alerts to it over
the LAN; opening the port for that scraper is the playbook's job, not the role's.

## Config

`alertmanager.yml` is Ansible-rendered to `/etc/alertmanager` and bind-mounted
read-only. Every alert routes to the `default` receiver, except the always-firing
`Watchdog`, which a dedicated route sends to the `deadman` receiver:

- With `alertmanager_discord_webhook_url` set, the `default` receiver carries a
  `discord_configs` entry whose `webhook_url_file` points at a 0600 file holding
  the URL — the secret stays out of the world-readable config.
- With `alertmanager_deadman_ping_url` set, the `deadman` receiver carries a
  `webhook_configs` entry whose `url_file` points at a 0600 file holding the
  hc-ping URL; every beat POSTs to it (`send_resolved` off, or a resolved POST
  would read as a healthy beat and mask an outage). The Watchdog route inherits
  the parent's 5m `group_interval` — the beat, as Alertmanager never repeats a
  group faster than that — and overrides only `repeat_interval` to `4m` so every
  flush re-sends. The healthchecks.io check must track this cadence: period 5m,
  grace 10m. Retune both halves together or the check flaps.
- Empty (the default), the matching receiver is null: its route fires nothing.
  This keeps molecule self-contained, so set the URLs on the real host.

The image's default command already targets `/etc/alertmanager/alertmanager.yml`
and `/alertmanager`, so the unit overrides no `Exec`. State (silences, the
notification log) lives in the `alertmanager-data` named volume, handed to the
image's `nobody` user (65534) with `:U`.

The container carries a podman healthcheck against `/-/healthy` (status only, no
restart on failure).

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
