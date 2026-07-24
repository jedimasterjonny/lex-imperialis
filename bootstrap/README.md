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
key and creates the server with a cloud-init that joins it to the home VPN as a
split tunnel at first boot. Its cloud firewall lives in `terraform/`
(`firewall-rogue-trader.tf`), not here. Provision-once —
`user_data` applies only on first boot, so a re-run won't re-render the tunnel
config on a live server. Requires the operator's `~/.ssh/id_ed25519.pub`
locally — that public key is uploaded and authorised on the server. Run from
the repo root, with the vault for the hcloud token and tunnel config:

```bash
ansible-playbook bootstrap/rogue-trader.yml \
  -e @inventory/group_vars/all/vault.yml --vault-password-file .vault_pass
```

The closing VPN smoke test needs router-side peer state this play doesn't own,
so it can time out despite a successful provision.
