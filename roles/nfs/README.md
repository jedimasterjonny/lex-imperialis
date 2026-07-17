# nfs

NFS client: each entry in `nfs_shares` (`name`, `server`, `export`;
per-host, empty by default) mounts `server:export` at `/nfs/<name>` with an
fstab entry. Options are pinned for the NAS link — v4.1 (the NAS rejects 4.2),
1 MiB rsize/wsize, `hard` so a stalled server retries instead of returning I/O
errors, `noatime`, `_netdev`.

CI coverage: the billable full-VM tier (`hetzner`) runs on openSUSE Leap 16, but
the fleet runs this on Tumbleweed; validate Tumbleweed-side behaviour locally
with `make test-vm` (the libvirt tier's Tumbleweed VM).
