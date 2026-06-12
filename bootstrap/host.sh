#!/usr/bin/env bash
# Take a fresh Tumbleweed install to the point Ansible can take over from the
# control host: the ansible account the plays connect as (key-only, NOPASSWD
# sudo) and sshd. Run as root on the new machine; idempotent, so re-running is
# safe:
#   curl -fsSL https://raw.githubusercontent.com/jedimasterjonny/lex-imperialis/main/bootstrap/host.sh | bash
#
# Everything else — owner account, sudo policy, base packages, dotfiles — is
# the common role's job; this stays at what Ansible needs to connect at all.
set -euo pipefail

keys_url=https://github.com/jedimasterjonny.keys

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root." >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

zypper --non-interactive install --no-recommends curl openssh python3 sudo

# The account plays connect as; the locked password makes it key-only.
id ansible >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/ansible --user-group --shell /bin/bash ansible

# NOPASSWD so plays escalate unattended; validate keeps a broken policy from
# ever reaching disk and locking out sudo.
echo 'ansible ALL=(ALL:ALL) NOPASSWD: ALL' >"$tmp"
visudo -cf "$tmp"
install -o root -g root -m 0440 "$tmp" /etc/sudoers.d/ansible

# The operator's keys open the ansible account; validate the fetch so a bad
# response can never land as an empty or garbage authorized_keys.
curl -fsSL "$keys_url" >"$tmp"
ssh-keygen -lf "$tmp" >/dev/null
install -d -o ansible -g ansible -m 0700 /home/ansible/.ssh
install -o ansible -g ansible -m 0600 "$tmp" /home/ansible/.ssh/authorized_keys

systemctl enable --now sshd.service

echo
echo "Done. From the control host: add this machine to the inventory and run the play."
