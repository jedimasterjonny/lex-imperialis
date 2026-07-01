# alertmanager

[Alertmanager](https://github.com/prometheus/alertmanager) as a Podman quadlet on
the host network, serving `:9093`. Prometheus on the NAS pushes alerts to it over
the LAN; opening the port for that scraper is the playbook's job, not the role's.

## Config

`alertmanager.yml` is Ansible-rendered to `/etc/alertmanager` and bind-mounted
read-only. It routes every alert to one `default` receiver:

- With `alertmanager_discord_webhook_url` set, the receiver carries a
  `discord_configs` entry whose `webhook_url_file` points at a 0600 file holding
  the URL — the secret stays out of the world-readable config.
- Empty (the default), the receiver is null: the route fires nothing. This keeps
  molecule self-contained, so set the URL on the real host.

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

The image (`alertmanager_image`) is pinned by digest; renovate bumps it.
