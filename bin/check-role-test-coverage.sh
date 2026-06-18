#!/usr/bin/env bash
# Enforce the per-role test-coverage rule: every role must ship an incus
# (default) or libvirt molecule scenario, or both. A libvirt scenario implies a
# hetzner scenario — its CI realisation on a real VM, since Hetzner Cloud cannot
# nest KVM.
#
# Roles in the Leap-16 subset additionally must ship a molecule/leap scenario
# (incus container, Leap image), so they stay guaranteed green on the Leap host.
set -euo pipefail

roles_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/roles"

# Roles guaranteed green on openSUSE Leap 16, the Leap server's baseline.
leap_roles="autoupdate caddy cadvisor common firewalld motd node_exporter podman podman_backup sshd wordpress"

status=0
for role_path in "$roles_dir"/*/; do
	[ -d "$role_path" ] || continue
	role="$(basename "$role_path")"
	molecule_dir="${role_path}molecule"

	if [ ! -d "$molecule_dir/default" ] && [ ! -d "$molecule_dir/libvirt" ]; then
		echo "ERROR: role '$role' ships no test; add a molecule/default (incus) or molecule/libvirt scenario." >&2
		status=1
	fi

	if [ -d "$molecule_dir/libvirt" ] && [ ! -d "$molecule_dir/hetzner" ]; then
		echo "ERROR: role '$role' has a libvirt scenario but no molecule/hetzner (its CI realisation on a real VM)." >&2
		status=1
	fi
done

for role in $leap_roles; do
	if [ ! -d "$roles_dir/$role/molecule/leap" ]; then
		echo "ERROR: role '$role' is in the Leap-16 subset but ships no molecule/leap scenario." >&2
		status=1
	fi
done

exit "$status"
