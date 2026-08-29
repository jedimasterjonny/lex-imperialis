# Roles

Conventions shared across roles; follow them when adding or changing one. Each
role's own `README.md` documents its variables and contracts — read that before
changing or composing a role.

## Conventions

- **Container workloads are podman quadlets.** Template `*.container`/`*.network` units into `/etc/containers/systemd/` (the `podman` role creates that dir and must run first), then end the role with `meta: flush_handlers` then a `systemd_service: started` — the unit exists only after the daemon-reload, and the explicit start covers a no-change converge.
- **Reload-then-restart is one handler.** A quadlet unit exists only after a daemon-reload, so fold `daemon_reload: true` into the role's restart handler (`state: restarted` with `daemon_reload: true`) rather than a separate, fleet-shared `Reload systemd` handler. Same-named handlers across roles collapse to the last-loaded definition: a shared `Reload systemd` (or `Restart caddy`) redefined by a later role reorders *after* this role's restart at its mid-play flush, so the container is recreated from the stale generated unit (molecule misses it — the role runs alone). Name every restart handler role-uniquely — `Restart caddy for <role>` when a backend notifies caddy.
- **Enable a timer with `daemon_reload: true`.** It picks up a changed unit before the enable, and does not itself report changed, so the task stays idempotent. A oneshot timer needs no restart handler — there is nothing to restart, and the next tick reads the new unit.
- **Container data is a named volume, not a host bind mount.** A container's mutable backing store is a podman named volume (`<role>-config`/`<role>-data`), referenced `Volume=<name>:/path` and auto-created on start — no `.volume` unit; podman labels it `container_file_t`, so no `:Z`, and `podman_backup` captures every volume. Bind mounts are reserved for: read-only Ansible-rendered config (`/etc/<role>`, config-as-code) mounted `ro,Z` where the path's policy-default label is unreadable to `container_t` under enforcing SELinux (`httpd_config_t` for `/etc/caddy`) — podman relabels it `container_file_t` on each start, undoing any autorelabel — or plain `ro` where that default label is already readable (grafana's `/etc/grafana`); a read-only config file or directory mounted on top of the volume, `ro,Z` or plain `ro`; the NFS media share; and host introspection (`/`, `/sys`, the podman socket).
- **`vars/` vs `defaults/`.** `vars/main.yml` holds renovate-pinned refs (image digests, version/revision pins, with `# renovate:` comments) plus role-internal constants that are not tunables; `defaults/main.yml` holds tunables and empty-string placeholders for vault secrets, which degrade so molecule runs with no vault.
- **Assert a container's timezone, don't assume it.** Every container that takes a `TZ=` gets `Europe/London`, and the scenario asserts the zone it *resolved* (`date +%Z`) — never the `TZ=` the unit declares, which only re-reads what Ansible just wrote. `Etc/UTC` needed no tzdata; a named zone does, and an image without it falls back to UTC in silence, leaving the container exactly where the zone was meant to move it from. Skip the assertion only where nothing formats a human-read time from the zone — homepage renders its dashboard client-side, so it carries the value and its defaults say why nothing checks it.
- **Secrets** render to a 0600 `EnvironmentFile` (referenced from the quadlet) with `no_log: true` — never into the world-readable unit.
- **caddy snippet contract.** Backends never edit the Caddyfile: an internal service drops `/etc/caddy/sites/<role>.caddy`, a public one drops `/etc/caddy/sites-public/<role>.caddy`; backends sit on `caddy.network` and publish no host port (only caddy publishes 80/443).
- **Health: probe over the network, exec only to restart.** A podman `HealthCmd` is a full OCI exec into the container (namespaces, seccomp compile, SELinux transition), costing whole CPU-seconds on the fleet's hardware where the request it wraps costs microseconds — so it is never the monitor. Monitoring is a blackbox network probe from the exporter (`prometheus_probe_targets`), which raises `ProbeDown`. The container's healthcheck exists only to restart a wedged container (`HealthOnFailure=kill`), so it runs at a backstop cadence, sized to the host's headroom — 5m on solar, tighter on a box with cycles to spare. Keep an exec check as a service's *only* check just where nothing off the host can reach it, or where what it asserts is only observable from inside the container's netns. Never `HealthOnFailure=kill` a container that can be mid-transcode or mid-import. When a check's cadence is what drives a restart-rate alert, say so where the interval is set — that coupling is otherwise invisible.
- **A script in a role's `files/` must be committed executable.** The shellcheck hook selects on `types: [shell]`, which `identify` takes from the extension, or for an extensionless script from the shebang — and it reads that shebang only on files marked executable, so an extensionless `0644` script tags as plain text: shellcheck skips it and the run still prints `Passed` off the other files. Verify with `git ls-files -s`. Ansible sets the installed mode from the task, so the repo bit costs nothing.
- **Guard a package task on the installed set where the host pays for the check.** `common` reads it once with `package_facts`, ahead of every later role's install in the play, as it already refreshes apt's lists; each install in a role `rogue-trader` runs is then `when:` the package is missing. The check is the expensive half — on a transactional host the zypper module answers it inside `transactional-update run`, snapshotting the root and dropping it again, 5.3s per already-installed package against ~1s to read the whole rpm database once. Ten of them ran on `rogue-trader` every apply, 22% of its play. A role no transactional host runs is left unguarded: there the check is an rpm query rather than a root snapshot, so the guard buys nothing. Every install here is `state: present`, so guarding on presence is what `state: present` already means; a `state: latest` could not be guarded this way. Fall back with `| default({})` so a role converging alone under molecule, with no `common` before it, still installs — and invert that for a removal (`is not defined or … in …`), which must also fail towards doing the work. `common` and `firewalld` are deliberately unguarded: `package_facts` reports installed package names, never the *provides* that satisfy them, and both declare a generic `python3-*` name that openSUSE resolves to a flavour package (`python313-selinux`, `python313-firewall`) — so the guard could never fire, and naming the flavour outright is exactly what `ansible.cfg`'s pinned interpreter exists to avoid. Guard a list only where every name in it is a real package.
- **No `meta/dependencies`** — role ordering is enforced by the play and each molecule `converge.yml`.
- **No tags** — don't introduce them.
- **`validate:`** guards configs that can lock out a host (sshd `sshd -t`, sudoers `visudo -cf`).

## Two distributions

Six roles carry both arms: `stow`, `common`, `podman`, `firewalld`,
`autoupdate` and `smartmon`. Everything else is single-OS and should stay that
way — this is a tax, not a direction.

`prometheus` is the one role that is neither and is easy to file wrongly: it
branches on nothing and deploys only to the Debian host, so it is single-OS and
its scenario runs that one arm. But the *alert rules* it ships are evaluated for
the whole fleet, so they must cover both distributions — which is why the update
alerts read a build datestamp and a `*_success` metric rather than naming a
package manager.

`sshd` is the other way round: it branches on nothing either, but deploys to
every host, so its scenario carries both platforms with no arm behind either.
What differs is the ground under it — the `sshd` unit name resolving through
Debian's `ssh.service` alias, and each distribution's own config reading the
drop-in directory before its settings.

- **Install with `ansible.builtin.package`, not `community.general.zypper`,** in a role auspex runs. On openSUSE it dispatches to the zypper module, whose `disable_recommends` already defaults true, so the swap is behaviour-preserving. It has no `update_cache`: `common` refreshes apt's lists ahead of its own install, and so ahead of every later role in the play.
- **Branch in `defaults/main.yml`, derived from `ansible_facts`** — following `autoupdate_transactional`. Not per-OS task files, and not `vars/Debian.yml`, which would outrank a play's own vars. Prefer a default that makes the OS-specific tasks skip themselves (`common_disabled_repos` is `[]` on Debian, so the four zypper tasks loop over nothing) over a `when:` on each. A **rendered script** is the exception: it may branch in Jinja on that same fact where the arms differ in more than a command line. `autoupdate-holds.sh.j2` reads holds, and `autoupdate-cleanup.sh.j2` the packages nothing needs, from two tools whose output needs two different parses each; hoisting those into a defaults ternary would bury shell pipelines in a folded YAML scalar, where `bin/shellcheck-jinja.sh` no longer lints them.
- **Test both arms in the role's existing `default` scenario**, as a second `platforms:` entry on `images:debian/13/cloud` with `groups: [debian]` — not a second scenario. Gate verify on `'debian' in group_names` rather than gathering facts, and spell out what each distribution should have: an assertion that recomputes the role's own derived expression asserts nothing.
- **Assume nothing a minimal Debian image ships.** `/etc/containers/containers.conf.d` and `/etc/modprobe.d` both had to be created; `template` does not make a parent, so it fails outright rather than landing somewhere inert.

## Molecule scenarios

A role's scenarios live in `roles/<role>/molecule/<scenario>/` and are the
contract CI runs against. `molecule/README.md` documents the three tiers and the
shared create/destroy playbooks they draw on.

- **Coverage.** Every role ships a `default` (incus container) or `libvirt`
  (full-boot VM) scenario, or both, and a `libvirt` scenario requires a
  `hetzner` one — the VM tier's CI form, on a real Hetzner Cloud VM, which bills
  money. `bin/check-role-test-coverage.sh` (a pre-commit hook) enforces this.
  Prefer incus; add the full-VM tier only when a container can't exercise the
  role. `motd` is the exception: it carries every tier as the harness exemplar.
- **A `molecule.yml` holds only its `platforms:`**, plus any override it layers
  on top. Everything a tier decides — the shared create/destroy paths,
  `roles_path`, the incus connection, hetzner's SSH transfer method — lives in
  that tier's `molecule/<tier>/base.yml`, which molecule deep-merges underneath.
- **Name instances `lex-<role>-<token>-${MOLECULE_RUN_ID:-local}`**, where the
  token is the scenario name except `default`'s, which is `incus`, and
  underscores in the role name are hyphenated. Concurrent runs then never
  collide.
- **converge and verify live in the role's primary scenario** — `default`, or
  `libvirt` where there is no container tier. The other scenarios symlink them,
  so a role keeps one of each.
- **CI derives the tiers to run from the changed paths** — see
  `.github/workflows/README.md`.
