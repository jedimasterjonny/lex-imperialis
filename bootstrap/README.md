# bootstrap

One-shot, operator-run entry points that take a host to the point Ansible — or
molecule — can manage it. `host.sh` and `incus.yml` are idempotent, and so is
`rogue-trader.yml` except on its rebuild path, which re-images the disk every
time it runs. `rogue-trader.bu` and `auspex-user-data.yaml` are configs, not
entry points: each is delivered to a first boot rather than run by hand.

## host.sh

Run as root on a fresh Tumbleweed install, before it joins the inventory:

```bash
curl -fsSL https://raw.githubusercontent.com/jedimasterjonny/lex-imperialis/main/bootstrap/host.sh | bash
```

Installs the minimum for the control host to connect — the key-only,
NOPASSWD-sudo `ansible` account (seeded with the two fleet admin keys, inlined
from `common_ansible_authorized_keys` rather than fetched from GitHub) and
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

**It destroys the disk, and has been exercised only on a throwaway.** It also leaves the
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

## auspex-user-data.yaml

The cloud-init seed auspex first-boots from — a Raspberry Pi 5 on Raspberry Pi
OS. The image ships `datasource_list: [NoCloud, None]` with
`seedfrom: file:///boot/firmware`, so this goes on the card's FAT partition as
`user-data`, beside the `meta-data` already there.

Its scope is `host.sh`'s — the key-only, NOPASSWD-sudo `ansible` account and
sshd — plus the owner account and `/etc/hostname`. The file itself argues the
rest; read it rather than this.

It ends by retiring its own provisioners: the last `runcmd` entries purge
`cloud-init`, `rpi-cloud-init-mods` and `systemd-timesyncd` — chrony's rival —
and drop the sshd drop-in the run wrote, so a converged auspex carries no trace
of first boot. Verified against trixie's package before writing: cloud-init's
prerm stops no unit, so the purge cannot kill the run that issues it.

Hand-written rather than emitted by Raspberry Pi Imager's customisation pane,
which writes the same kind of file but sets no `uid` and no `primary_group`: the
owner lands on uid 1000 with a per-user group where the fleet pins 1026 and
`users`, and changing either on a live account needs an offline root console.

**Do not let Imager apply its own customisation on top.** Answering yes to
"Would you like to apply OS customisation settings?" overwrites `user-data` —
putting the uid back and restoring `manage_etc_hosts`, whose `127.0.1.1 auspex`
entry makes the co-located Prometheus resolve its own scrape targets — the
exporters and its own `auspex:9090` — to loopback, where none of them bind. `dd`
and balenaEtcher never ask.

Rewriting the seed on a card needs a fresh `instance-id` in `meta-data`, or
cloud-init treats the boot as a resume and skips it; keep that file's
`dsmode: local`, without which user-data waits for the network.

`ansible` is deliberately not `system: true`. cloud-init appends `-m` only for
non-system users and maps `homedir` to `--home`, which sets the path without
creating it — so a system account gets no home for `ssh_authorized_keys` to land
in. `host.sh` passes `--system --create-home` together, which cloud-init has no
way to express.

Both accounts are key-only, as `roles/common` manages no password. `jonny`
therefore cannot `sudo` at all — `common`'s `wheel` drop-in grants own-password
sudo — so `ansible@auspex` is the admin path. Set a password by hand if the
console matters: `ssh ansible@auspex 'sudo passwd jonny'`.

Provision-once in the way that bites: `cc_users_groups` creates accounts, it does
not migrate them, so editing this file on a booted card achieves nothing. auspex
is stateless by design and its recovery is a reflash — see
[`docs/disaster-recovery.md`](../docs/disaster-recovery.md).

First boot resizes the card and reboots once. Then:

```bash
ssh ansible@auspex
id jonny                  # uid=1026(jonny) gid=100(users)
getent hosts auspex       # the LAN address, not 127.0.1.1
```

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
