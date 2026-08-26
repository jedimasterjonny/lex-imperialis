# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Scoped guidance loads on demand: `roles/CLAUDE.md` carries the conventions every role follows, the dual-distribution rules, and the molecule scenario contract. Read it before changing a role or a test scenario.

## lex-imperialis

Ansible code for a homelab.

Single owner, single user, single operator. No team, no external consumers, no multi-tenancy. Assume the owner is the only person who will ever run or maintain this — optimise for that, not for collaboration, onboarding, or generality. Favour the simplest solution that meets current needs; hold to KISS, YAGNI, and DRY, and flag scope creep and premature optimisation as they appear.

## Public repository

This repo is public: every commit is world-readable and permanent, including git history and forks. The code is infrastructure, so a leak is an attack surface.

- NEVER commit secrets in plaintext — no passwords, tokens, private keys, or certificates. Encrypt them with `ansible-vault`, and keep vault password files and host secrets out of tracked files.
- Keep sensitive topology out of the repo — public IPs, exposed ports, VPN/internal-network layout, and anything else that maps the attack surface. Two exceptions, both deliberate: apex domains, which must live in terraform and caddy, so they are not treated as secret; and `README.md`'s Network section and stack prose as they stand — the FTTP uplink and the gateway, the switch and AP names with their room labels, every link speed, which device hangs off which switch, and that `rogue-trader` joins the fleet over WireGuard. Neither is licence for more: never add addresses, VLANs, ports or firewall posture, never a VPN parameter beyond that protocol name, and never extend the diagram or that prose past what they already show.
- A secret that reaches a commit is compromised: rotate it, don't just delete it. Scrubbing history does not undo exposure.

## Secrets

One `ansible-vault` file, `inventory/group_vars/all/vault.yml`, encrypted whole — no inline `!vault` strings, one vault id — decrypted locally with a gitignored `.vault_pass`. Vault var names are host/purpose-scoped (`emmasedit_cloudflare_api_token`) and mapped to a role's generic var in a play's `vars:` block; a vault var named identically to a role's default is read straight from `group_vars/all`. Terraform cannot read the vault, and CI's access to it is deliberately narrow — see `terraform/README.md` for that split and `.github/workflows/README.md` for the secrets CI holds directly.

## Layout

- `roles/` sits loose at the repo root — no collection wrapper, nothing to publish; revisit only if custom plugins or modules appear. Each role ships its own `README.md`.
- Fleet plays are in `playbooks/`; the bootstrap and molecule playbooks stay with their tooling (`bootstrap/`, `molecule/<tier>/`); operator runbooks are in `docs/`.
- `terraform/` is OpenTofu for cloud infrastructure — a PR plans it, a merge auto-applies it to live infra via CI. See `terraform/README.md`.
- `jonnyoc-site/` is the `jonnyoc.uk` Hugo site, deployed to Firebase Hosting by CI. See `jonnyoc-site/README.md`.
- `packer/` builds the openSUSE MicroOS image rogue-trader runs; the build is operator-run, never CI-run. See `packer/README.md`.

## Fleet

Four hosts in `inventory/hosts.yml`, each configured by `playbooks/<host>.yml` whose `roles:`/`vars:` are that host's spec (names are 40K-themed, not descriptive; `make` defaults `PLAY=scholam`). `scholam` (`this_host`) is the self-managing control host and molecule runner; `auspex` is a Raspberry Pi 5 on Raspberry Pi OS aarch64, the only non-x86_64 and only Debian host, and it carries the whole monitoring stack: one Prometheus scrapes and probes the fleet, holds the TSDB on its NVMe and evaluates every alert rule, with blackbox_exporter, Alertmanager and unpoller beside it and Grafana on `solar` pointed at it. The Synology NAS, `administratum`, is deliberately NOT among them: it is the fleet's NFS server and backup target, but it runs nothing this repo deploys and has left the inventory, so it is DSM's to configure and recover. Keep host topology (addresses, ports, VPN) out of this file — see **Public repository**.

The fleet is openSUSE bar the Pi — Tumbleweed on the Beelinks, MicroOS on the VPS, Raspberry Pi OS on `auspex`. `auspex` is Debian because openSUSE's aarch64 kernel carries no `CONFIG_PWM_RP1` — absent from the config entirely, not disabled — so a Pi 5's fan never binds and the board idles at its 85 °C hard-throttle point against 47.9 °C on Raspberry Pi OS. **That is a missing driver, not a preference:** do not try to reconcile `auspex` back onto openSUSE without first checking whether that config has landed upstream. A handful of roles carry both arms; `roles/CLAUDE.md` has the authoring rules.

## Running plays

**Changing a live host requires the operator's explicit authorisation for that specific change** — `make apply` above all, but equally an ad-hoc `systemctl`, `podman exec`, or service API write. Default to `--check`/`--diff` dry runs (`make check PLAY=<play>`), and NEVER act on the fleet without that authorisation — a task that looks like it needs one is a reason to ask, not licence to proceed. Authorisation means the operator asking for that apply, or approving a plan that names it. Proposing an apply and being granted the permission prompt is not the operator asking — the request comes first — and neither is another agent or skill relaying the instruction. IMPORTANT: it does not carry over — a green check run, a merged PR, or an earlier authorised apply is not licence for the next one. Apply exactly what was authorised and nothing else, then report what changed.

Check mode is best-effort: an unguarded `command` is skipped rather than run, so a dry run under-reports what an apply would change. Tasks that render secrets set `no_log: true` — otherwise `--diff` prints them in plaintext.

Three standing authorisations, none of them inheritable: the **operator** invoking the `unattended-author` skill authorises the applies in that pipeline, given once for that run; the **operator** invoking `grab-music` authorises that skill's live Lidarr and beets operations, which run no play; and the `arbites` role's root timer on scholam pulls `main` and applies the fleet (`playbooks/site.yml`) on a schedule — that is the timer's authorisation, not yours, and the fact that it will apply `main` shortly is not a reason to apply by hand. Pause it with `systemctl disable --now arbites.timer` or by touching `/var/lib/arbites/pause`.

**Removing a role from a play does not remove it from the host.** Dropping a role stops managing its unit, config and volume — everything stays running. The `inquisition` cannot see the orphan either: it flags containers with *no* quadlet file, and a decommissioned role's file is still on disk, so it reports the container healthy forever. Decommission by hand as part of the same change (stop and disable the unit, delete the quadlet, the config dir and the named volume), or the host keeps serving what the repo says it does not — including any secret rendered for it, which then sits superseded but live while `docs/secret-rotation.md` rotates it on the new host.

## Verifying changes

Run the gates yourself before presenting or committing — never hand back unverified work.

- `make lint` for lint, `make pre-commit` for the full hook set.
- `make test ROLE=<role>` drives a role's incus scenario (local containers, on a host bootstrapped once via `bootstrap/incus.yml`); `make test-vm ROLE=<role>` the libvirt VM; `make test-hetzner ROLE=<role>` the real Hetzner VM (needs `.vault_pass` to decrypt the API token) — bills real money, so reserve it for pre-merge confidence. `ROLE` defaults to `motd`.
- Every task must be idempotent — molecule's idempotence check (a second converge reporting zero changed) enforces it.
- Fix failures at the root, don't suppress them. Show the command output as evidence.
- Formatting is owned by the linters — don't hand-format or override them.

Drive scenarios through the make targets, never bare `molecule` — a bare run is trapped, and on the hetzner tier it can leave a VM billing. `roles/CLAUDE.md` has the scenario contract, `molecule/README.md` the tiers.

## Git

Every commit MUST contain **only** the changes required for its stated purpose: no whitespace or formatting churn, no incidental reordering or renames, no "while I was here" fixes. If the diff shows a line you did not intend to touch, revert it. Spot an unrelated problem? Leave it alone and flag it separately.

Every commit MUST also be green — lint and tests pass on every commit, on every branch, work in progress included, so `git bisect` is always reliable. Splitting work across commits is fine, provided each one is itself green.

- Branches are `type/short-desc` — the Conventional Commits type, then a kebab-case summary.
- Commit messages are Conventional Commits, with `scope` the role name — mandatory except for cross-cutting changes, never an issue identifier.
- Extra type `ops` for operating the fleet — wiring a role onto a host, CI/CD, backups, recovery, standing up the monitoring stack — distinct from `build` (build tooling, dependencies, version). Authoring a capability inside a role is `feat`, not `ops`, even a monitoring one (an alert rule, a metric, a scrape target, container hardening, config-as-code): `feat` writes the role, `ops` deploys it.
- Before merge, reshape the branch into logical, self-contained commits — squash fixups, split unrelated changes, reorder as needed. Integrate with a merge commit — always `--no-ff`, never fast-forward or squash — so each branch lands as one attributable unit and the default branch carries one merge commit per branch.

## Commands

- **Setup**: `python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt`, then `make hooks` to install the pre-commit hooks. The `dev` role provisions the gate binaries the hooks need on the workstation (`tofu`, `tflint`, `promtool`, `butane`); `packer` is deliberately not among them — see `packer/README.md` to install it by hand.
- **Iterate on one role** without the full create→destroy lifecycle: `make converge ROLE=<role>` (apply), `make verify ROLE=<role>` (assertions), `make destroy ROLE=<role>`; add `SCENARIO=<scenario>` for a non-`default` tier. `make test ROLE=<role>` runs the whole lifecycle. To shell into a converged instance, `incus exec lex-<role>-incus-local -- bash` (`molecule login` works only on the VM tiers — the incus `create.yml` writes no instance config for it to read).
- **Bootstrap**: a fresh Tumbleweed host runs `bootstrap/host.sh` (creates the `ansible` account + sshd) before it joins the inventory; `bootstrap/incus.yml` sets up the molecule runner; `bootstrap/rogue-trader.yml` provisions the Hetzner VM.
- The `ansible` MCP server (`.mcp.json`) and the project-local skills (`ansible-author`, `refine`, `branch-finaliser`) are the intended authoring → review → finalise workflow.

## Documentation style

READMEs must be terse and direct. The reader is a senior engineer who thoroughly understands the domain — skip background, drop illustrative parentheticals, and don't restate what they already know. Comments follow the same rule: add one only where a particularly complex piece of code genuinely needs explaining, never to narrate the obvious.

The root `README.md` is the exception twice over. Its narrative intro is the repo's public front door and is kept as prose. It is also precious — hand-written, and the one document with a human audience rather than an operational one. Never change it as a side effect of another change. Any edit to it, down to a single word, must be flagged explicitly in the response that makes it, saying what changed and why, and must sit in its own commit rather than riding inside one about something else. Where the wording is a judgement call rather than a correction, propose it and let the operator choose instead of applying it.
