# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# lex-imperialis

Ansible code for a homelab.

Single owner, single user, single operator. No team, no external consumers, no multi-tenancy. Assume the owner is the only person who will ever run or maintain this — optimise for that, not for collaboration, onboarding, or generality.

## Public repository

This repo is public: every commit is world-readable and permanent, including git history and forks. The code is infrastructure, so a leak is an attack surface.

- NEVER commit secrets in plaintext — no passwords, tokens, private keys, or certificates. Encrypt them with `ansible-vault`, and keep vault password files and host secrets out of tracked files.
- Secrets live in one `ansible-vault`-encrypted file, encrypted whole — no inline `!vault` strings, one vault id.
- Keep sensitive topology out of the repo — public IPs, exposed ports, VPN/internal-network layout, and anything else that maps the attack surface. Apex domains are the exception: they must live in terraform and caddy, so they are not treated as secret.
- A secret that reaches a commit is compromised: rotate it, don't just delete it. Scrubbing history does not undo exposure.

## Secrets

The vault is `inventory/group_vars/all/vault.yml`, decrypted locally with a gitignored `.vault_pass`. Vault var names are host/purpose-scoped (`emmasedit_cloudflare_api_token`) and mapped to a role's generic var in a play's `vars:` block; a vault var named identically to a role's default is read straight from `group_vars/all`. Terraform can't read the vault: on a push the CI **plan** sources its write provider secrets (`terraform_cloudflare_api_token`, `hcloud_token_emmas_edit`) through `bin/vault-var.sh` into `TF_VAR_` and bakes them into the saved plan the apply replays, while a PR **plan** uses read-only repo-secret counterparts — so a PR never decrypts the vault. Its state lives in a GCS bucket reached keylessly via WIF, so there is no state token. The `jonnyoc-site` Firebase deploy and the `tofu` CI jobs authenticate to GCP keylessly via Workload Identity Federation (short-lived OIDC-exchanged credentials, no key) — so `VAULT_PASSWORD` (gated to a main-only environment, read only by the push plan) is CI's only vault-derived secret; the `jonnyoc-site` go.sum autofix additionally uses a GitHub App (`AUTOFIX_APP_ID`/`AUTOFIX_APP_KEY`). See `terraform/README.md`.

## Writing code

Favour the simplest solution that meets current needs; hold to KISS, YAGNI, and DRY. Flag scope creep, unnecessary complexity, and premature optimisation as they appear.

## Layout

Loose `roles/` at the repo root — no collection wrapper. Single operator with nothing to publish; revisit only if custom plugins or modules appear.

Fleet playbooks live in `playbooks/`; the bootstrap and molecule playbooks stay with their tooling (`bootstrap/`, `molecule/<tier>/`). Operator runbooks live in `docs/` (e.g. disaster recovery). OpenTofu config for cloud infrastructure lives in a sibling `terraform/` tree, with remote state in a GCS bucket in the infra-shared GCP project; a PR plans it and a merge to main auto-applies it to live cloud infra via CI (keyless WIF) — see `terraform/README.md`. The `jonnyoc.uk` website is a Hugo static site in `jonnyoc-site/`, built and deployed to Firebase Hosting by CI — see `jonnyoc-site/README.md`.

## Fleet

Four hosts in `inventory/hosts.yml`, each configured by `playbooks/<host>.yml` whose `roles:`/`vars:` are that host's spec (names are 40K-themed, not descriptive; `make` defaults `PLAY=scholam`). `scholam` (`this_host`) is the self-managing control host and molecule runner; `administratum` is the Synology NAS — the one non-openSUSE, non-podman host (Prometheus via Docker Compose). Keep host topology (addresses, ports, VPN) out of this file — see **Public repository**.

## Roles

Each role under `roles/` ships a `README.md` documenting its variables and contracts — read it before changing or composing a role.

## Conventions

Patterns shared across roles; follow them when adding or changing one.

- **Container workloads are podman quadlets.** Template `*.container`/`*.network` units into `/etc/containers/systemd/` (the `podman` role creates that dir and must run first), then end the role with `meta: flush_handlers` then a `systemd_service: started` — the unit exists only after the daemon-reload, and the explicit start covers a no-change converge.
- **Reload-then-restart is one handler.** A quadlet unit exists only after a daemon-reload, so fold `daemon_reload: true` into the role's restart handler (`state: restarted` with `daemon_reload: true`) rather than a separate, fleet-shared `Reload systemd` handler. Same-named handlers across roles collapse to the last-loaded definition: a shared `Reload systemd` (or `Restart caddy`) redefined by a later role reorders *after* this role's restart at its mid-play flush, so the container is recreated from the stale generated unit (molecule misses it — the role runs alone). Name every restart handler role-uniquely — `Restart caddy for <role>` when a backend notifies caddy.
- **Container data is a named volume, not a host bind mount.** A container's mutable backing store is a podman named volume (`<role>-config`/`<role>-data`), referenced `Volume=<name>:/path` and auto-created on start — no `.volume` unit; podman labels it `container_file_t`, so no `:Z`, and `podman_backup` captures every volume. Bind mounts are reserved for: read-only Ansible-rendered config (`/etc/<role>`, config-as-code) mounted `ro,Z`, so podman relabels it `container_file_t` on each start — the path's policy-default label (`httpd_config_t` for `/etc/caddy`) is unreadable to `container_t` under enforcing SELinux, and an autorelabel resets it there; a read-only config file or directory mounted on top of the volume, `ro,Z` or plain `ro`; the NFS media share; and host introspection (`/`, `/sys`, the podman socket).
- **`vars/` vs `defaults/`.** `vars/main.yml` holds renovate-pinned refs (image digests, version/revision pins, with `# renovate:` comments) plus role-internal constants that are not tunables; `defaults/main.yml` holds tunables and empty-string placeholders for vault secrets, which degrade so molecule runs with no vault.
- **Secrets** render to a 0600 `EnvironmentFile` (referenced from the quadlet) with `no_log: true` — never into the world-readable unit.
- **caddy snippet contract.** Backends never edit the Caddyfile: an internal service drops `/etc/caddy/sites/<role>.caddy`, a public one drops `/etc/caddy/sites-public/<role>.caddy`; backends sit on `caddy.network` and publish no host port (only caddy publishes 80/443).
- **Health: probe over the network, exec only to restart.** A podman `HealthCmd` is a full OCI exec into the container (namespaces, seccomp compile, SELinux transition), costing whole CPU-seconds on the fleet's hardware where the request it wraps costs microseconds — so it is never the monitor. Monitoring is a blackbox network probe from the exporter (`prometheus_probe_targets`), which raises `ProbeDown`. The container's healthcheck exists only to restart a wedged container (`HealthOnFailure=kill`), so it runs at a backstop cadence, sized to the host's headroom — 5m on solar, tighter on a box with cycles to spare. Keep an exec check as a service's *only* check just where nothing off the host can reach it, or where what it asserts is only observable from inside the container's netns. Never `HealthOnFailure=kill` a container that can be mid-transcode or mid-import. When a check's cadence is what drives a restart-rate alert, say so where the interval is set — that coupling is otherwise invisible.
- **No `meta/dependencies`** — role ordering is enforced by the play and each molecule `converge.yml`.
- **No tags** — don't introduce them.
- **`validate:`** guards configs that can lock out a host (sshd `sshd -t`, sudoers `visudo -cf`).

## Commit hygiene

Every commit MUST be 100% clean: it contains **only** the changes required for its stated purpose, and nothing else.

- No whitespace changes — no trailing whitespace, re-indentation, or blank-line churn.
- No formatting or style changes unrelated to the commit.
- No incidental edits, reordering, renames, or "while I was here" fixes.
- If the diff shows a line you did not intend to touch, revert that line before committing.

Spot an unrelated problem? Leave it alone and flag it separately — never fold it into an unrelated commit.

Name branches `type/short-desc` — `type` is the Conventional Commits type, `short-desc` a kebab-case summary.

Before merge, reshape the branch into a sequence of logical, self-contained commits — squash fixups, split unrelated changes, reorder as needed. Each resulting commit must stay clean and green.

Integrate with a merge commit — always `--no-ff`, never fast-forward or squash — so each branch lands as one attributable unit. Per-branch history stays linear and clean; the default branch is deliberately not linear, carrying one merge commit per branch.

## Commit messages

Conventional Commits. Two project specifics:

- `scope` is the role name — mandatory except for cross-cutting changes, never an issue identifier.
- Extra type `ops` for operating the fleet — wiring a role onto a host, CI/CD, backups, recovery, and standing up the monitoring stack — distinct from `build` (build tooling, dependencies, version). Authoring a capability inside a role is `feat`, not `ops`, even a monitoring one (an alert rule, a metric, a scrape target, container hardening, config-as-code): `feat` writes the role, `ops` deploys it.

## Bisect safety

The git tree MUST be bisect-safe at all times: every commit — on every branch, work in progress included — passes lint and tests, so `git bisect` is always reliable. Never commit red.

- Splitting work across commits is fine — add a feature in one commit, its tests in the next — provided each commit is itself green.

## Test tiers

A role's molecule scenarios are the contract CI runs against:

- `default` — incus container; the preferred tier, run locally and free on the CI runner.
- `leap` — incus container on the openSUSE Leap 16 image; the free, routine Leap check for the `LEAP_ROLES` subset, since the rest of the fleet is Tumbleweed.
- `libvirt` — local full-boot VM (`qemu:///system`); only where a container can't fully exercise the role.
- `hetzner` — the full-VM tier's CI form, a real Hetzner Cloud VM (Hetzner can't nest KVM, so the VM is the machine); bills money.

Every role must ship a `default` or `libvirt` scenario (or both), and a `libvirt` scenario requires a `hetzner` one; roles in the `LEAP_ROLES` subset additionally ship a `leap` scenario. `bin/check-role-test-coverage.sh` (a pre-commit hook) enforces all of this. Prefer incus — add the full-VM tier only when a container can't test the role. `motd` is the exception: it carries every tier as the harness exemplar.

Shared, role-agnostic create and destroy playbooks live in `molecule/<tier>/`, where `<tier>` is `incus`, `libvirt`, or `hetzner` (the incus tier also has a shared `prepare.yml`); the container tier ships two scenarios, `default` (Tumbleweed) and `leap` (Leap 16), both built from the `incus` playbooks. Everything about a scenario that its tier decides — those playbook paths, `roles_path`, the incus connection, hetzner's vault password file — lives in that tier's `molecule/<tier>/base.yml`, which molecule deep-merges under the scenario. So a `molecule.yml` holds only its `platforms:` (naming instances `lex-<role>-<token>-${MOLECULE_RUN_ID:-local}` — the token is the scenario name, except `default`'s is `incus`; underscores in the role name hyphenated — so concurrent runs never collide), plus any override it layers on top. A tier's config reaches molecule only through `-c`, which the make targets pass: **drive scenarios through the make targets, never bare `molecule`** — a bare run is trapped, and `molecule/README.md` says why. converge/verify are role-specific and live in the role's primary scenario (`default`, or `libvirt` where there is no container tier); the other scenarios symlink them, so a role keeps one of each. CI tests only the roles a PR changes, plus `motd` for shared-infra changes — though a `requirements-dev.txt`- or `Makefile`-only (toolchain) bump runs the free incus tier only, and a docs-only (`*.md`) change runs no tier at all.

## Verifying changes

Run the gates yourself before presenting or committing — never hand back unverified work.

- `make lint` for lint, `make pre-commit` for the full hook set. `make test ROLE=<role>` drives the incus scenario where the role has one (local containers, on a host bootstrapped once via `bootstrap/incus.yml`); `make test-leap ROLE=<role>` the Leap-16 container; `make test-vm ROLE=<role>` the libvirt VM; `make test-hetzner ROLE=<role>` the real Hetzner VM (needs `.vault_pass` to decrypt the API token) — bills real money, so reserve it for pre-merge confidence. `ROLE` defaults to `motd`.
- Every task must be idempotent — molecule's idempotence check (a second converge reporting zero changed) enforces it.
- Fix failures at the root, don't suppress them. Show the command output as evidence.
- Formatting is owned by the linters — don't hand-format or override them.

## Commands

- **Setup**: `python -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt`, then `make hooks` to install the pre-commit hooks. The `terraform/` gates additionally need `tofu` and `tflint` on PATH — the `dev` role provisions both on the workstation; see `terraform/README.md` to install them elsewhere.
- **Iterate on one role** without the full create→destroy lifecycle: `make converge ROLE=<role>` (apply), `make verify ROLE=<role>` (assertions), `make destroy ROLE=<role>`; add `SCENARIO=<scenario>` for a non-`default` tier. `make test ROLE=<role>` runs the whole lifecycle. To shell into a converged instance, `incus exec lex-<role>-incus-local -- bash` (`molecule login` works only on the VM tiers — the incus `create.yml` writes no instance config for it to read).
- **Bootstrap**: a fresh Tumbleweed host runs `bootstrap/host.sh` (creates the `ansible` account + sshd) before it joins the inventory; `bootstrap/incus.yml` sets up the molecule runner; `bootstrap/rogue-trader.yml` provisions the Hetzner VM.
- The `ansible` MCP server (`.mcp.json`) and the project-local skills (`ansible-author`, `refine`, `branch-finaliser`) are the intended authoring → review → finalise workflow.

## Running plays

Write and `molecule`-test code. Against live hosts, only `--check`/`--diff` dry runs (`make check PLAY=<play>`) — never apply. Applying to the real fleet (`make apply`) is the operator's call. Tasks that render secrets set `no_log: true` — otherwise `--diff` prints them in plaintext.

The one standing exception is the `gitops_reconcile` role: once the operator has bootstrapped it on scholam, its root timer is the sanctioned unattended-apply path — it pulls `main` and applies the fleet (`playbooks/site.yml`) on a schedule, the scheduled counterpart of the `unattended-author` skill. Pause it with `systemctl disable --now gitops-reconcile.timer` or by touching `/var/lib/gitops-reconcile/pause`.

## Documentation style

READMEs must be terse and direct. The reader is a senior engineer who thoroughly understands the domain — skip background, drop illustrative parentheticals, and don't restate what they already know.

The root `README.md` is the deliberate exception: its narrative intro is the repo's public front door and is kept as prose. Every other README and doc holds to the terse rule.

Comments follow the same rule: add one only where a particularly complex piece of code genuinely needs explaining, never to narrate the obvious. When you do, keep the language terse and direct.
