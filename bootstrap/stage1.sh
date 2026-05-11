#!/usr/bin/env bash
# Stage 1: minimal manual bootstrap for a fresh openSUSE Tumbleweed lab box.
#
# Run as root on the box ONCE. Idempotent — safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "stage1.sh must run as root (use sudo)." >&2
  exit 1
fi

echo "==> Refreshing zypper repos and installing base packages"
zypper --non-interactive refresh
zypper --non-interactive install python3 python3-pip git sudo openssh

echo "==> Ensuring 'ansible' user exists"
if ! id ansible &>/dev/null; then
  # New user: -G sets the initial supplementary group list.
  useradd -m -s /bin/bash -G wheel ansible
  echo "Created user 'ansible'."
else
  # Existing user: -a appends to current supplementary groups (omitting -a would replace them).
  usermod -aG wheel ansible
  echo "User 'ansible' already existed; ensured wheel membership."
fi

echo "==> Granting 'wheel' group passwordless sudo"
cat > /etc/sudoers.d/wheel-nopasswd <<'EOF'
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/wheel-nopasswd

echo "==> Setting up SSH directory for ansible user"
install -d -o ansible -g users -m 0700 /home/ansible/.ssh
touch /home/ansible/.ssh/authorized_keys
chown ansible:users /home/ansible/.ssh/authorized_keys
chmod 0600 /home/ansible/.ssh/authorized_keys

echo "==> Enabling and starting sshd"
systemctl enable --now sshd

echo
echo "==> Stage 1 complete."
echo
echo "Next: append your SSH public key to:"
echo "    /home/ansible/.ssh/authorized_keys"
echo
echo "Then from your local machine, verify:"
echo "    ssh ansible@scholam"
