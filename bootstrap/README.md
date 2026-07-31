# bootstrap

One-shot, operator-run entry points that take a host to the point Ansible — or
molecule — can manage it. `host.sh` and `incus.yml` are idempotent, and so is
`rogue-trader.yml` except on its rebuild path, which re-images the disk every
time it runs. `rogue-trader.bu` is a config, not an entry point.

## host.sh

Run as root on a fresh Tumbleweed install, before it joins the inventory:

```bash
curl -fsSL https://raw.githubusercontent.com/jedimasterjonny/lex-imperialis/main/bootstrap/host.sh | bash
```

Installs the minimum for the control host to connect — the key-only,
NOPASSWD-sudo `ansible` account (seeded with the operator's GitHub keys) and
sshd. Both lockout-risk inputs are validated before they land (`visudo -cf`,
`ssh-keygen -lf`), so a bad sudoers policy or a failed key fetch aborts rather
than locking out the host. Everything past "Ansible can log in and escalate" is
the `common` role.

## incus.yml

Sets up the molecule test runner — the one host molecule can't provision
itself, since it needs incus to launch the default-tier containers — by
applying the `incus` role to `localhost`:

```bash
ansible-playbook bootstrap/incus.yml --ask-become-pass
```

## rogue-trader.yml

Creates a Hetzner VM from the MicroOS snapshot `packer/` builds, compiling
`rogue-trader.bu` into the `user_data` Ignition reads at first boot. Its cloud
firewall lives in `terraform/` (`firewall-rogue-trader.tf`), not here.
Provision-once — `user_data` applies only on first boot, so a re-run is a no-op.
Run from the repo root, with the vault for the hcloud token:

```bash
ansible-playbook bootstrap/rogue-trader.yml \
  -e @inventory/group_vars/all/vault.yml --vault-password-file .vault_pass
```

Needs `butane` on PATH (the `dev` role installs it) — the play compiles the
config on every run, `--check` included. `--check` dry-runs it end to end
against the live API without creating anything. The image is selected by its
`custom_image=microos-containerhost` label rather than by id, so nothing here
carries a snapshot reference that rots.

Nothing secret enters `user_data`: the metadata endpoint serves it for the life
of the server. `roles/wireguard_client` places the tunnel key over SSH during
the converge instead.

On the create path the play ends where sshd answers on the public address, with
the box holding its name, the `ansible` account and sudo, and nothing else.
Against a server that already exists it does not wait at all. `server_type` is
passed only when creating — the module resizes on any difference, and this
play's default is smaller than production.

### The OS move — rebuilding in place

rogue-trader is a `cx33` and Hetzner no longer sells the `cx` line, so the box
cannot be recreated; it is re-imaged, keeping its id, its IP and its firewall
attachment. Hetzner takes fresh `user_data` on a rebuild, so the Ignition config
compiled here is what first-boots.

```bash
ansible-playbook bootstrap/rogue-trader.yml \
  -e @inventory/group_vars/all/vault.yml --vault-password-file .vault_pass \
  -e rogue_trader_state=rebuild
```

**Unexercised through this play, and it destroys the disk.** It also leaves the
box unreachable — no inbound 22 on the cloud firewall, no tunnel until the
converge, and no console password for `root` or `ansible` — so it needs a
temporary firewall rule merged first, a converge driven at the public address,
and the volumes restored afterwards. The sequence is the rogue-trader section of
[`docs/disaster-recovery.md`](../docs/disaster-recovery.md); follow it rather
than this file.

### Spikes

The same play creates a differently-named throwaway to rehearse against:

```bash
ansible-playbook bootstrap/rogue-trader.yml \
  -e @inventory/group_vars/all/vault.yml --vault-password-file .vault_pass \
  -e rogue_trader_name=rogue-trader-spike
```

The name reaches `/etc/hostname` through the compiled Ignition, so first-boot
logs are attributable. **It does not survive the converge**: `roles/common` sets
the hostname from `common_hostname`, which `playbooks/rogue-trader.yml` pins to
`rogue-trader`, and `restic_backup` derives every repo name from `hostname` at
timer time — so a spike converged with that play unchanged backs up into
production's repos on the shared astropath export. Converging one needs at least
its own `common_hostname`, its own WireGuard identity and its own exporter bind
addresses.

A spike also gets **no cloud firewall** — `firewall-rogue-trader.tf` attaches to
rogue-trader by id — so it is a public box with everything open, running caddy
and WordPress once converged. Delete it when done: `hcloud server delete
rogue-trader-spike`.

## rogue-trader.bu

Butane source for the Ignition config `rogue-trader.yml` compiles and passes as
`user_data`. MicroOS ships no cloud-init, so this is the whole of first boot.

Its scope is `host.sh`'s — the `ansible` account, its key, NOPASSWD sudo, sshd —
plus `/etc/hostname`, so the box is named before Ansible reaches it. The file
itself argues the rest; read it rather than this.

The compiled `.ign` is never committed. Two gates stand between a bad config and
a box that cannot be logged into: `butane --strict --check`
(`bin/butane-lint.sh`) on the file as written, and `jinja-syntax` on its
templating. The document that actually ships is validated at provision time, by
the play's own compile.
