# bootstrap

One-shot, operator-run entry points that take a host to the point Ansible — or
molecule — can manage it. All three are idempotent.

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

Provisions the persistent Hetzner VM serving the public site: uploads the SSH
key and creates the server with a cloud-init that installs the tunnel tooling.
Its cloud firewall lives in `terraform/` (`firewall-rogue-trader.tf`), not here.
Provision-once — `user_data` applies only on first boot, so a re-run is a no-op.
Requires the operator's `~/.ssh/id_ed25519.pub` locally — that public key is
uploaded and authorised on the server. Run from the repo root, with the vault
for the hcloud token:

```bash
ansible-playbook bootstrap/rogue-trader.yml \
  -e @inventory/group_vars/all/vault.yml --vault-password-file .vault_pass
```

`user_data` is served from the metadata endpoint for the life of the server, so
nothing secret goes in it — a key written there is readable by every process and
container on the box forever, revocable only by rebuilding. The tunnel config is
therefore placed by hand over the Hetzner console after provisioning: write
`rogue_trader_wireguard_conf` to `/etc/wireguard/wg0.conf` (0600 root:root) and
`systemctl enable --now wg-quick@wg0`.

The closing VPN smoke test needs that placement plus router-side peer state this
play doesn't own, so it can time out despite a successful provision.
