# docker_prune

The docker-side reciprocal of the `podman` role's weekly image-prune timer. A
single pinned `docker:cli` container, deployed from a templated compose project
with `community.docker.docker_compose_v2`, self-schedules `docker image prune
-af` — so superseded image pulls (renovate digest bumps of the NAS stacks) don't
accumulate.

The `podman` role installs a systemd timer; the NAS has no such lever, so the
container is the schedule. busybox `crond` runs one weekly crontab entry
(Saturday 06:00, the podman timer's slot) that prunes over the mounted Docker
socket. Because the schedule lives inside the container, the Ansible converge is
a no-op after the first — nothing re-fires on reapply.

## Target: administratum (Synology)

Shaped by the same host as the `prometheus`/`blackbox_exporter` stacks, and
mirrors them:

- **docker_compose_v2, not docker_container** — the NAS has the `docker compose`
  CLI but no Docker SDK for Python, so the module that shells out to the CLI is
  the one that works.
- **No `become`** — sudo needs a password there; the deploy runs as the
  `docker`-group user, with `/usr/local/bin` prepended to `PATH` for the DSM
  `docker`.

## Variables

- `docker_prune_project_dir` — where `compose.yaml` is written.
- `docker_prune_schedule` — five-field crontab schedule for the prune; Saturday
  06:00 by default.
- `docker_prune_security_opt_extra` — extra compose `security_opt` entries,
  appended to the `no-new-privileges` the template hardcodes (alongside
  `cap_drop: ALL`); empty in production.

## Contract

- Weekly `docker image prune -af` — all unused images, forced — faithful to the
  podman role's `podman image prune --all --force`. A fired job echoes what it
  reclaimed to the container's stdout (`docker logs docker_prune`).
- The schedule fires on the wall clock but, unlike the podman timer's
  `Persistent=true`, busybox crond has no missed-run catch-up: a run due while
  the (always-on) NAS is down is skipped, not deferred to next boot.
- **`network_mode: none`** — the prune reaches dockerd through the socket alone,
  a filesystem path, so the container gets no network egress.
- The Docker socket is bind-mounted read-write (pruning mutates) and is the
  container's real privilege — root-equivalent on the host, the same power the
  podman side's root systemd unit holds. `cap_drop: ALL` + `no-new-privileges`
  harden the crond/CLI process; they do not (and cannot) fence the socket.
- `cap_add: SETGID` — the one capability kept back from `cap_drop: ALL`: busybox
  crond needs it to fork its scheduled job, which otherwise silently never runs
  (mechanism in `compose.yaml.j2`).
