# common

Owner account and base tooling for every host: the account mirrors the
local Tumbleweed install (uid 1000 by default, group `users`, wheel),
no password managed, plus `bash-suse` dotfiles via the stow role.

Wheel sudo authenticates with the member's own password — the drop-in
overrides SUSE's vendor-default `targetpw` — and is `visudo`-validated so
a broken policy never lands.

Also sets each host's hostname from the required `common_hostname`.

Sets the SELinux mode from `common_selinux_mode` (default `enforcing`) via
`ansible.posix.selinux`, so the fleet's mode is config-as-code rather than the OS
default: a no-op on the Tumbleweed hosts (already enforcing), it flips the Leap
host that defaults permissive — a live `permissive`→`enforcing` transition, so no
reboot. Gated on `ansible_selinux.status == 'enabled'`, so the SELinux-less
molecule containers skip it.

That module imports `python3-selinux`, which `common_packages` carries — so
`Install base packages` must stay ahead of it. **On MicroOS that ordering is not
enough**: the install lands in a new snapshot, so the image has to ship the
binding already. `packer/stage2-provision.yml` reads `common_packages` for that.

Creates `/var/lib/pcrlock.d`. `sdbootutil-update-predictions.service` runs after
every snapper snapshot and its `ExecStartPre` fails without that directory, which
only a TPM2 LUKS enrolment would otherwise create — so an unenrolled TPM2 host
raises `SystemdUnitFailed` on its next zypper transaction.

`common_blacklisted_modules` bars kernel modules via
`/etc/modprobe.d/common-blacklist.conf` — `blacklist` plus `install
<module> /bin/false` — and unloads any already live rather than leaving
them until the next boot. The drop-in renders unconditionally, so
emptying the list reclaims the modules instead of leaving a stale file
barring them. The list unloads in order: a holder must precede what it
holds, `iwlmvm` before `iwlwifi`.

The unload is the untested, unpreviewed half: it is skipped under
`--check`, no molecule tier can exercise it (a container unloads
nothing), and it does not reach a module baked into the initramfs, which
the role does not regenerate.
