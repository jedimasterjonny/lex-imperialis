# libvirt

Libvirt VM host backing the molecule libvirt tier: modular daemons, the
default NAT network, the owner in the `libvirt` group for sudo-less
`qemu:///system`, and a cached Tumbleweed qcow2.

- **Daemons** — modular and socket-activated; libvirtd is deprecated, and
  the daemons don't activate each other, so each one is enabled explicitly.
- **Default network** — always autostarted, activated only where
  `libvirt_default_network_active` holds: the molecule tier's minimal-VM
  kernel can't start a libvirt network (no htb qdisc), so that tier defers
  activation to the full-kernel hetzner VM.
- **Image cache** — a weekly timer re-fetches the cloud qcow2 only when the
  published sha256 changes and swaps it in by atomic rename, so a failed
  download never corrupts the cached copy.
