# incus

Incus on this host, which doubles as the molecule test runner: the
default-tier containers launch here, so `bootstrap/incus.yml` applies this
role before molecule can run — the one host it cannot set up for itself.

- **Packages** — `incus_packages`, the daemon and its CLI tooling.
- **Init** — `incus admin init --preseed`, guarded on the bridge already
  existing: run-once, not reconciling — preseed edits do not converge an
  initialised host.
- **Network** — the preseed creates a NAT bridge (`incus_bridge`, IPv4 only)
  that firewalld permanently trusts, so instances reach the host's DHCP and
  DNS.
- **Instance veths** — `conf.d/incus.conf` leaves `veth*` unmanaged by
  NetworkManager. A stopped instance returns its interface to the host netns
  renamed `vethXXXXXXXX`, and NM claiming that orphan strands it in the
  default firewalld zone, one per instance destroyed, until a reboot.
- **Storage** — btrfs pool on the fleet (`incus_storage_driver` at
  `incus_storage_source`); molecule's non-btrfs VMs override to a source-less
  `dir` pool, so the btrfs default is not molecule-tested.
- **Image cache** — a weekly timer (`incus_image_refresh_script`,
  `incus_image_refresh_oncalendar`) caches the Tumbleweed cloud image
  (`incus_image_source`, aliased `incus_image_alias`) in the local store and
  refreshes it as the source rolls, so container launches never wait on the
  remote.
- **CI coverage** — the billable full-VM tier (`hetzner`) runs on openSUSE
  Leap 16, but the fleet runs this on Tumbleweed; validate Tumbleweed-side
  behaviour locally with `make test-vm` (the libvirt tier's Tumbleweed VM).
