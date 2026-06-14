# podman_backup

Weekly restic backup of this host's podman volumes to
`<podman_backup_root>/<hostname>-podman-backup` (default root `/nfs/astropath`,
the astropath NFS share). A systemd timer (Wednesday 01:00, persistent — clear of
every other scheduled job) quiesces the quadlet container units, snapshots every
volume with restic, restarts the units (via a trap, so they return even if the
backup fails), then prunes to `podman_backup_keep_weekly` / `_keep_monthly`.

The repo is unencrypted (`--insecure-no-password`): the NAS share is trusted.
Assumes `podman` is installed and the `nfs` role has mounted the target.
