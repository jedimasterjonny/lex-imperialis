# wireguard_reresolve

Keeps a WireGuard tunnel up across a home WAN-IP change. WireGuard resolves
`Endpoint=` only at startup, so a dynamic-IP gateway reboot strands the tunnel on
the stale address. A `wireguard-reresolve.timer` runs a oneshot every
`wireguard_reresolve_interval` (`1min`): once the peer's latest handshake is
older than `wireguard_reresolve_stale_seconds` (150), it re-resolves the
`Endpoint` hostname — read from `/etc/wireguard/<iface>.conf`, since
`wg showconf` only reports the resolved IP — against
`wireguard_reresolve_resolver` (`1.1.1.1`) and, on a changed address, runs
`wg set … endpoint`. The resolver is queried directly because a downed tunnel
takes its DNS with it. A healthy tunnel rehandshakes within the threshold, so
the timer no-ops.

Variables in `defaults/main.yml`: `wireguard_reresolve_interface`,
`wireguard_reresolve_resolver`, `wireguard_reresolve_stale_seconds`,
`wireguard_reresolve_interval`.

## openresolv under enforcing SELinux

wg-quick's `DNS=` line runs openresolv, which manages state under
`/run/resolvconf` and rewrites `/etc/resolv.conf`. openSUSE confines wg-quick to
`wireguard_t`, which the base policy allows neither, so under enforcing SELinux
`wg-quick up` is denied and tears the tunnel down at boot. The role grants the
access in two pieces:

- A `tmpfiles.d` drop-in pre-creates `/run/resolvconf`, which the filecon in the
  module below labels `wg_resolvconf_run_t` — a private type — before wg-quick runs.
- A local CIL policy module (`files/wireguard-reresolve.cil`, loaded with
  `semodule`) grants `wireguard_t` manage on that private type (so the grant is
  scoped to the resolvconf tree, not a blanket over `var_run_t`) plus write on
  `net_conf_t` for `resolv.conf`. Its install is gated on
  `ansible_selinux.status == 'enabled'`, a no-op on the SELinux-less molecule
  containers whose shared kernel would otherwise take the change host-wide.

The tunnel-under-enforcing behaviour is exercised on the `libvirt`/`hetzner` VM
tiers — a container can host neither a real `wg0` nor enforcing SELinux; the
`default`/`leap` container tiers only check the drop-in installs and the runtime
directory materialises.
