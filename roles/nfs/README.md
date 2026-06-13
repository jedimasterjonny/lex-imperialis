# nfs

NFS client: each entry in `nfs_shares` (`name`, `server`, `export`;
per-host, empty by default) mounts `server:export` at `/nfs/<name>` with an
fstab entry. Options are pinned for the NAS link — v4.1 (the NAS rejects 4.2),
1 MiB rsize/wsize, `hard` so a stalled server retries instead of returning I/O
errors, `noatime`, `_netdev`.
