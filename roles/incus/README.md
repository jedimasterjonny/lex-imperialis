# incus

Incus on this host, which doubles as the molecule test runner: the
default-tier containers launch here, so `bootstrap/incus.yml` applies this
role before molecule can run — the one host it cannot set up for itself.

- **Init** — `incus admin init --preseed`, guarded on the bridge already
  existing: run-once, not reconciling — preseed edits do not converge an
  initialised host.
- **Network** — the preseed creates a NAT bridge (IPv4 only) that firewalld
  permanently trusts, so instances reach the host's DHCP and DNS.
- **Storage** — btrfs pool on the fleet; molecule's non-btrfs VMs override
  to a `dir` pool, so the btrfs default is not molecule-tested.
- **Image cache** — a weekly timer caches the Tumbleweed cloud image in
  the local store and refreshes it as the source rolls, so container
  launches never wait on the remote.
