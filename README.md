# Lex Imperialis

As it is written in the Lex Imperialis, so shall it be deployed.

## Founding of the Imperium

I have had infrastructure as code for my home fleet spanning back to my early post-graduate days, when it was bash and badly written notes.

Over the years, this repository has existed in many disjointed, fragmented guises: bash, Terraform, Puppet, k3s, simple docker-compose. But there's only been one constant throughout: Ansible. It's long in the tooth, and grey in the hair, but I've been orchestrating my machines with Ansible for well over 10 years now, and I plan to continue until it's EoL (or I am).

### The Claude Chapter

With the advent of Claude, I've been able to unify my various repositories into one mono-repo, and address a lot of the long-standing issues that have been sitting on my `ansible.txt` for longer than I care to remember.

This has a side effect I never considered before I began: having an IaC repo that captures every facet of the fleet gives Claude instant, deep knowledge of the entire deployment footprint. It can deploy, debug, and drive the stack expertly, having access to every API key and secret it needs, merely by being launched from inside this repository.

## The Fleet

- `scholam` — Beelink Mini S13 — Development box
- `solar` — Beelink Mini S13 — Media server
- `administratum` — Synology DS413+ NAS
  - `scriptorum` — 24TB SHR1 HDD array
  - `astropath` — 380GB RAID1 NVMe array
- `rogue-trader` — Hetzner VPS

## The Stack

Tumbleweed on the Beelinks, Leap 16 on the VPS, DSM on the NAS. Workloads are rootful podman quadlets, bar the NAS, where Docker Compose is what DSM offers.

Backends publish no host port at all: they sit on caddy's network and drop a snippet into `/etc/caddy/sites/`, and a DNS-01 wildcard issues their certs, so an internal service gets TLS without ever facing the internet. plex is the exception — host-networked, and reached directly. Container state is a named volume, never a host bind mount, so `podman_backup` can restic every volume to the NAS weekly and `restic check` the repository afterwards.

`solar` runs the media stack — prowlarr, sonarr, radarr, lidarr, beets, recyclarr, plex, transmission — with media over NFSv4 from the NAS. Everything that talks to a tracker is netns-confined to the wireguard container: the tunnel drops, their network drops with it.

`rogue-trader` serves the public WordPress site behind the same caddy role and joins the fleet over WireGuard, which carries both its scrape and its backup.

Monitoring sits off the hosts it watches — Prometheus and blackbox_exporter on the NAS, Alertmanager and Grafana on `solar`, node_exporter on the openSUSE hosts, cadvisor on `solar` and `rogue-trader`. Liveness is a blackbox probe over the network; a container's own healthcheck exists only to restart it when stuck, and anything that must not be killed mid-flight — a plex transcode, a beets import — carries none at all.

zypper updates run unattended and staggered: `solar` Monday as the canary, the VPS midweek, `scholam` last, so one bad rolling snapshot cannot brick the fleet in a single night.

## Layout

- `roles/` — where the work is. Each ships a README covering its variables and contracts.
- `playbooks/` — one play per host, and the play is that host's spec: its `roles:` and `vars:` are the whole story. `site.yml` is the fleet in one run.
- `terraform/` — OpenTofu for the cloud edge: Cloudflare zones, the Hetzner firewall, the GCP projects behind the site and keyless CI. Remote state in HCP, applied on merge.
- `jonnyoc-site/` — Hugo source for the personal site, built and deployed to Firebase Hosting by CI.

## Running plays

`make check PLAY=<host>` dry-runs a host (`--check --diff`); `make apply PLAY=<host>` is the real thing. `PLAY=site` is the fleet in one run, `scholam` last so a run never restarts its own timer mid-apply. Both decrypt the vault from `.vault_pass`; tasks that render secrets set `no_log`, so `--diff` stays clean. Check mode is best-effort — an unguarded `command` still runs.

The standing exception is `gitops_reconcile`: a root timer on `scholam` that pulls `origin/main` every 15 minutes and, when it has advanced, applies `site.yml` — so a merged change reaches the fleet with no manual apply. It tracks `origin/main` alone, never a local branch. `touch /var/lib/gitops-reconcile/pause` holds it; `systemctl disable --now gitops-reconcile.timer` stops it.

## Testing

Molecule, four tiers — three free, one billed:

- `default` — incus container on Tumbleweed. `make test ROLE=<role>`
- `leap` — incus container on Leap 16, for the roles the VPS also runs. `make test-leap ROLE=<role>`
- `libvirt` — full-boot VM, where a container can't exercise the role. `make test-vm ROLE=<role>`
- `hetzner` — the VM tier's CI form on a real Hetzner VM, since Hetzner cannot nest KVM. `make test-hetzner ROLE=<role>`

Every role ships a container or VM scenario — a VM scenario implies a Hetzner one — and a pre-commit hook fails the commit if it does not. Create and destroy are shared per tier in `molecule/`; converge and verify live with the role. A scenario's second converge must report zero changed, so idempotence is a gate rather than an aspiration.

## CI

GitHub Actions workflows:

- `lint` — the pre-commit set (yamllint, ansible-lint, shellcheck, the tofu gates, file hygiene, test coverage) on every PR and every push to `main`, plus a gitleaks scan of the checked-out commit; the hook alone sees only the staged index, which is empty on a fresh checkout.
- `molecule` — the role tests. A discover job diffs the PR: a changed role runs whichever tiers it ships, a change outside `roles/` is exercised through the `motd` harness, and a docs-only change runs nothing.
- `terraform` — `tofu plan` on a PR, applied to live cloud infrastructure on merge.
- `firebase` — the Hugo site: a preview channel per PR, the live channel on merge.

Actions are pinned by commit SHA. `VAULT_PASSWORD` is the only secret in CI: it unlocks the in-repo vault, which carries the tokens the billed test tier and the terraform runs need — Hetzner, Cloudflare, and HCP. GCP authenticates keylessly through Workload Identity Federation, so nothing else is stored.

## Secrets

Everything lives in one `ansible-vault` file, `inventory/group_vars/all/vault.yml` — encrypted whole, one vault id, no inline `!vault` strings — opened with a gitignored `.vault_pass`. Vault variables are scoped by host and purpose, and mapped onto a role's generic variable in the play's `vars:`; one named identically to a role's default is picked up from `group_vars/all` with no wiring at all.

OpenTofu cannot read a vault, so its tokens are sourced through `bin/vault-var.sh` into `TF_VAR_`/`TF_TOKEN_` at run time.

On a host, a secret is rendered into a 0600 `EnvironmentFile` that the quadlet references rather than into the world-readable unit, and the task that writes it sets `no_log`.

## Bootstrap and recovery

Three one-shot entry points in `bootstrap/`, all idempotent:

- `host.sh` — run as root on a fresh Tumbleweed install, before the host joins the inventory. Installs sshd and the key-only `ansible` account `scholam` connects as; everything past "Ansible can log in and escalate" belongs to the `common` role.
- `incus.yml` — sets up the molecule runner, the one host molecule cannot provision for itself.
- `rogue-trader.yml` — creates the Hetzner VM and joins it to the home VPN at first boot.

Recovery walks the same path: re-bootstrap the host, run its play to rebuild everything declarative, then restore its podman volumes from the restic repository on the NAS. `docs/disaster-recovery.md` covers it host by host, along with what the backup does and does not hold. `.vault_pass` is the one thing the repo cannot give you back — it comes from the password manager.

## Working with Claude

`CLAUDE.md` is the house style: quadlets, named volumes, the caddy snippet contract, health probes, commit and branch conventions. It is what keeps a generated role indistinguishable from a hand-written one.

Authoring runs through the skills in `.claude/skills/`, each handing to the next:

- `ansible-author` — drafts the role against the `ansible` MCP server and the Red Hat good practices.
- `refine` — design review, then a simplify and code-review loop, then lint and molecule, then the docs.
- `branch-finaliser` — curates the branch into clean, bisect-safe commits and opens the PR.
- `unattended-author` — chains all three and carries them through to a merge gated on a real apply.

## Licence

GPL-3.0. See `LICENSE`.
